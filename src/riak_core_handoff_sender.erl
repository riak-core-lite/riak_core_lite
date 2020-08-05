%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007-2012 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc send a partition's data via TCP-based handoff

-module(riak_core_handoff_sender).

-export([start_link/4]).

-include("riak_core_vnode.hrl").

-include("riak_core_handoff.hrl").

-define(ACK_COUNT, 1000).

%% can be set with env riak_core, handoff_timeout
-define(TCP_TIMEOUT, 60000).

%% can be set with env riak_core, handoff_status_interval
%% note this is in seconds
-define(STATUS_INTERVAL, 2).

-define(LOG_INFO(Str, Args),
        logger:info("~p transfer of ~p from ~p ~p to ~p ~p "
                    "failed "
                      ++ Str,
                    [Type, Module, SrcNode, SrcPartition, TargetNode,
                     TargetPartition]
                      ++ Args)).

-define(LOG_FAIL(Str, Args),
        logger:error("~p transfer of ~p from ~p ~p to ~p ~p "
                     "failed "
                       ++ Str,
                     [Type, Module, SrcNode, SrcPartition, TargetNode,
                      TargetPartition]
                       ++ Args)).

%% Accumulator for the visit item HOF
-record(ho_acc,
        {ack  :: non_neg_integer(),
         error  :: ok | {error, any()}, filter  :: function(),
         module  :: module(), parent  :: pid(), socket  :: any(),
         src_target  :: {non_neg_integer(), non_neg_integer()},
         stats  :: #ho_stats{},
         total_objects  :: non_neg_integer(),
         total_bytes  :: non_neg_integer(),
         use_batching  :: boolean(), item_queue  :: [binary()],
         item_queue_length  :: non_neg_integer(),
         item_queue_byte_size  :: non_neg_integer(),
         acksync_threshold  :: non_neg_integer(),
         acksync_timer  :: timer:tref() | undefined,
         type  :: ho_type(), notsent_acc  :: term(),
         notsent_fun  :: function() | undefined}).

%%%===================================================================
%%% API
%%%===================================================================

start_link(TargetNode, Module, {Type, Opts}, Vnode) ->
    Pid = spawn_link(fun () ->
                             start_fold(TargetNode, Module, {Type, Opts}, Vnode)
                     end),
    {ok, Pid}.

%%%===================================================================
%%% Private
%%%===================================================================

start_fold_(TargetNode, Module, Type, Opts, ParentPid,
            SrcNode, SrcPartition, TargetPartition) ->
    %% Give workers one more chance to abort or get a lock or whatever.
    FoldOpts = maybe_call_handoff_started(Module,
                                          SrcPartition),
    Filter = get_filter(Opts),
    [_Name, Host] = string:tokens(atom_to_list(TargetNode),
                                  "@"),
    {ok, Port} = get_handoff_port(TargetNode),
    TNHandoffIP = case get_handoff_ip(TargetNode) of
                    error -> Host;
                    {ok, "0.0.0.0"} -> Host;
                    {ok, Other} -> Other
                  end,
    SockOpts = [binary, {packet, 4}, {header, 1},
                {active, false}],
    {ok, Socket} = gen_tcp:connect(TNHandoffIP, Port,
                                   SockOpts, 15000),
    RecvTimeout = get_handoff_receive_timeout(),
    %% We want to ensure that the node we think we are talking to
    %% really is the node we expect.
    %% The remote node will reply with PT_MSG_VERIFY_NODE if it
    %% is the correct node or close the connection if not.
    %% If the node does not support this functionality we
    %% print an error and keep going with our fingers crossed.
    TargetBin = term_to_binary(TargetNode),
    VerifyNodeMsg = <<(?PT_MSG_VERIFY_NODE):8,
                      TargetBin/binary>>,
    ok = gen_tcp:send(Socket, VerifyNodeMsg),
    case gen_tcp:recv(Socket, 0, RecvTimeout) of
      {ok, [?PT_MSG_VERIFY_NODE | _]} -> ok;
      {ok, [?PT_MSG_UNKNOWN | _]} ->
          logger:warning("Could not verify identity of peer ~s.",
                         [TargetNode]),
          ok;
      {error, timeout} -> exit({shutdown, timeout});
      {error, closed} -> exit({shutdown, wrong_node})
    end,
    %% Piggyback the sync command from previous releases to send
    %% the vnode type across.  If talking to older nodes they'll
    %% just do a sync, newer nodes will decode the module name.
    %% After 0.12.0 the calls can be switched to use PT_MSG_SYNC
    %% and PT_MSG_CONFIGURE
    VMaster = list_to_atom(atom_to_list(Module) ++
                             "_master"),
    ModBin = atom_to_binary(Module, utf8),
    Msg = <<(?PT_MSG_OLDSYNC):8, ModBin/binary>>,
    ok = gen_tcp:send(Socket, Msg),
    AckSyncThreshold = application:get_env(riak_core,
                                           handoff_acksync_threshold, 25),
    %% Now that handoff_concurrency applies to both outbound and
    %% inbound conns there is a chance that the receiver may
    %% decide to reject the senders attempt to start a handoff.
    %% In the future this will be part of the actual wire
    %% protocol but for now the sender must assume that a closed
    %% socket at this point is a rejection by the receiver to
    %% enforce handoff_concurrency.
    case gen_tcp:recv(Socket, 0, RecvTimeout) of
      {ok, [?PT_MSG_OLDSYNC | <<"sync">>]} -> ok;
      {error, timeout} -> exit({shutdown, timeout});
      {error, closed} -> exit({shutdown, max_concurrency})
    end,
    RemoteSupportsBatching =
        remote_supports_batching(TargetNode),
    logger:info("Starting ~p transfer of ~p from ~p ~p "
                "to ~p ~p",
                [Type, Module, SrcNode, SrcPartition, TargetNode,
                 TargetPartition]),
    M = <<(?PT_MSG_INIT):8, TargetPartition:160/integer>>,
    ok = gen_tcp:send(Socket, M),
    StartFoldTime = os:timestamp(),
    Stats = #ho_stats{interval_end =
                          future_now(get_status_interval())},
    UnsentAcc0 = get_notsent_acc0(Opts),
    UnsentFun = get_notsent_fun(Opts),
    Req = riak_core_util:make_fold_req(fun visit_item/3,
                                       #ho_acc{ack = 0, error = ok,
                                               filter = Filter, module = Module,
                                               parent = ParentPid,
                                               socket = Socket,
                                               src_target =
                                                   {SrcPartition,
                                                    TargetPartition},
                                               stats = Stats, total_bytes = 0,
                                               total_objects = 0,
                                               use_batching =
                                                   RemoteSupportsBatching,
                                               item_queue = [],
                                               item_queue_length = 0,
                                               item_queue_byte_size = 0,
                                               acksync_threshold =
                                                   AckSyncThreshold,
                                               type = Type,
                                               notsent_acc = UnsentAcc0,
                                               notsent_fun = UnsentFun},
                                       false, FoldOpts),
    %% IFF the vnode is using an async worker to perform the fold
    %% then sync_command will return error on vnode crash,
    %% otherwise it will wait forever but vnode crash will be
    %% caught by handoff manager.  I know, this is confusing, a
    %% new handoff system will be written soon enough.
    AccRecord0 = case
                   riak_core_vnode_master:sync_command({SrcPartition,
                                                        SrcNode},
                                                       Req, VMaster, infinity)
                     of
                   #ho_acc{} = Ret -> Ret;
                   Ret ->
                       logger:error("[handoff] Bad handoff record: ~p", [Ret]),
                       Ret
                 end,
    %% Send any straggler entries remaining in the buffer:
    AccRecord = send_objects(AccRecord0#ho_acc.item_queue,
                             AccRecord0),
    if AccRecord == {error, vnode_shutdown} ->
           ?LOG_INFO("because the local vnode was shutdown", []),
           throw({be_quiet, error,
                  local_vnode_shutdown_requested});
       true ->
           ok                     % If not #ho_acc, get badmatch below
    end,
    #ho_acc{error = ErrStatus, module = Module,
            parent = ParentPid, total_objects = TotalObjects,
            total_bytes = TotalBytes, stats = FinalStats,
            acksync_timer = TRef, notsent_acc = NotSentAcc} =
        AccRecord,
    _ = timer:cancel(TRef),
    case ErrStatus of
      ok ->
          %% One last sync to make sure the message has been received.
          %% post-0.14 vnodes switch to handoff to forwarding immediately
          %% so handoff_complete can only be sent once all of the data is
          %% written.  handle_handoff_data is a sync call, so once
          %% we receive the sync the remote side will be up to date.
          logger:debug("~p ~p Sending final sync",
                       [SrcPartition, Module]),
          ok = gen_tcp:send(Socket, <<(?PT_MSG_SYNC):8>>),
          case gen_tcp:recv(Socket, 0, RecvTimeout) of
            {ok, [?PT_MSG_SYNC | <<"sync">>]} ->
                logger:debug("~p ~p Final sync received",
                             [SrcPartition, Module]);
            {error, timeout} -> exit({shutdown, timeout})
          end,
          FoldTimeDiff = end_fold_time(StartFoldTime),
          ThroughputBytes = TotalBytes / FoldTimeDiff,
          ok =
              logger:info("~p transfer of ~p from ~p ~p to ~p ~p "
                          "completed: sent ~p bytes in ~p of ~p "
                          "objects in ~p seconds (~p/second)",
                          [Type, Module, SrcNode, SrcPartition, TargetNode,
                           TargetPartition, TotalBytes,
                           FinalStats#ho_stats.objs, TotalObjects, FoldTimeDiff,
                           ThroughputBytes]),
          case Type of
            repair -> ok;
            resize ->
                gen_fsm_compat:send_event(ParentPid,
                                          {resize_transfer_complete,
                                           NotSentAcc});
            _ ->
                gen_fsm_compat:send_event(ParentPid, handoff_complete)
          end;
      {error, ErrReason} ->
          if ErrReason == timeout -> exit({shutdown, timeout});
             true -> exit({shutdown, {error, ErrReason}})
          end
    end.

start_fold(TargetNode, Module, {Type, Opts},
           ParentPid) ->
    SrcNode = node(),
    SrcPartition = get_src_partition(Opts),
    TargetPartition = get_target_partition(Opts),
    try start_fold_(TargetNode, Module, Type, Opts,
                    ParentPid, SrcNode, SrcPartition, TargetPartition)
    catch
      exit:{shutdown, max_concurrency} ->
          %% Need to fwd the error so the handoff mgr knows
          exit({shutdown, max_concurrency});
      exit:{shutdown, timeout} ->
          %% A receive timeout during handoff
          %% STATS
          %%             riak_core_stat:update(handoff_timeouts),
          ?LOG_FAIL("because of TCP recv timeout", []),
          exit({shutdown, timeout});
      exit:{shutdown, {error, Reason}} ->
          ?LOG_FAIL("because of ~p", [Reason]),
          gen_fsm_compat:send_event(ParentPid,
                                    {handoff_error, fold_error, Reason}),
          exit({shutdown, {error, Reason}});
      {be_quiet, Err, Reason} ->
          gen_fsm_compat:send_event(ParentPid,
                                    {handoff_error, Err, Reason});
      Err:Reason:Stacktrace ->
          ?LOG_FAIL("because of ~p:~p ~p",
                    [Err, Reason, Stacktrace]),
          gen_fsm_compat:send_event(ParentPid,
                                    {handoff_error, Err, Reason})
    end.

start_visit_item_timer() ->
    Ival = case application:get_env(riak_core,
                                    handoff_receive_timeout, undefined)
               of
             TO when is_integer(TO) -> erlang:max(1000, TO div 3);
             _ -> 60 * 1000
           end,
    timer:send_interval(Ival, tick_send_sync).

visit_item(K, V,
           Acc0 = #ho_acc{acksync_threshold = AccSyncThreshold}) ->
    %% Eventually, a vnode worker proc will be doing this fold, but we don't
    %% know the pid of that proc ahead of time.  So we have to start the
    %% timer some time after the fold has started execution on that proc
    %% ... like now, perhaps.
    Acc = case get(is_visit_item_timer_set) of
            undefined ->
                put(is_visit_item_timer_set, true),
                {ok, TRef} = start_visit_item_timer(),
                Acc0#ho_acc{acksync_timer = TRef};
            _ -> Acc0
          end,
    receive
      tick_send_sync ->
          visit_item2(K, V, Acc#ho_acc{ack = AccSyncThreshold})
      after 0 -> visit_item2(K, V, Acc)
    end.

%% When a tcp error occurs, the ErrStatus argument is set to {error, Reason}.
%% Since we can't abort the fold, this clause is just a no-op.
visit_item2(_K, _V,
            Acc = #ho_acc{error = {error, _Reason}}) ->
    %% When a TCP error occurs, #ho_acc.error is set to {error, Reason}.
    throw(Acc);
visit_item2(K, V,
            Acc = #ho_acc{ack = _AccSyncThreshold,
                          acksync_threshold = _AccSyncThreshold}) ->
    #ho_acc{module = Module, socket = Sock,
            src_target = {SrcPartition, TargetPartition},
            stats = Stats} =
        Acc,
    RecvTimeout = get_handoff_receive_timeout(),
    M = <<(?PT_MSG_OLDSYNC):8, "sync">>,
    NumBytes = byte_size(M),
    Stats2 = incr_bytes(Stats, NumBytes),
    Stats3 = maybe_send_status({Module, SrcPartition,
                                TargetPartition},
                               Stats2),
    case gen_tcp:send(Sock, M) of
      ok ->
          case gen_tcp:recv(Sock, 0, RecvTimeout) of
            {ok, [?PT_MSG_OLDSYNC | <<"sync">>]} ->
                Acc2 = Acc#ho_acc{ack = 0, error = ok, stats = Stats3},
                visit_item2(K, V, Acc2);
            {error, Reason} ->
                Acc#ho_acc{ack = 0, error = {error, Reason},
                           stats = Stats3}
          end;
      {error, Reason} ->
          Acc#ho_acc{ack = 0, error = {error, Reason},
                     stats = Stats3}
    end;
visit_item2(K, V, Acc) ->
    #ho_acc{filter = Filter, module = Module,
            total_objects = TotalObjects,
            use_batching = UseBatching, item_queue = ItemQueue,
            item_queue_length = ItemQueueLength,
            item_queue_byte_size = ItemQueueByteSize,
            notsent_fun = NotSentFun, notsent_acc = NotSentAcc} =
        Acc,
    case Filter(K) of
      true ->
          case Module:encode_handoff_item(K, V) of
            corrupted ->
                {Bucket, Key} = K,
                logger:warning("Unreadable object ~p/~p discarded",
                               [Bucket, Key]),
                Acc;
            BinObj ->
                case UseBatching of
                  true ->
                      ItemQueue2 = [BinObj | ItemQueue],
                      ItemQueueLength2 = ItemQueueLength + 1,
                      ItemQueueByteSize2 = ItemQueueByteSize +
                                             byte_size(BinObj),
                      Acc2 = Acc#ho_acc{item_queue_length = ItemQueueLength2,
                                        item_queue_byte_size =
                                            ItemQueueByteSize2},
                      %% Unit size is bytes:
                      HandoffBatchThreshold = application:get_env(riak_core,
                                                                  handoff_batch_threshold,
                                                                  1024 * 1024),
                      case ItemQueueByteSize2 =< HandoffBatchThreshold of
                        true -> Acc2#ho_acc{item_queue = ItemQueue2};
                        false -> send_objects(ItemQueue2, Acc2)
                      end;
                  _ ->
                      #ho_acc{ack = Ack, socket = Sock,
                              src_target = {SrcPartition, TargetPartition},
                              stats = Stats, total_objects = TotalObjects,
                              total_bytes = TotalBytes} =
                          Acc,
                      M = <<(?PT_MSG_OBJ):8, BinObj/binary>>,
                      NumBytes = byte_size(M),
                      Stats2 = incr_bytes(incr_objs(Stats), NumBytes),
                      Stats3 = maybe_send_status({Module, SrcPartition,
                                                  TargetPartition},
                                                 Stats2),
                      case gen_tcp:send(Sock, M) of
                        ok ->
                            Acc#ho_acc{ack = Ack + 1, error = ok,
                                       stats = Stats3,
                                       total_bytes = TotalBytes + NumBytes,
                                       total_objects = TotalObjects + 1};
                        {error, Reason} ->
                            Acc#ho_acc{error = {error, Reason}, stats = Stats3}
                      end
                end
          end;
      false ->
          NewNotSentAcc = handle_not_sent_item(NotSentFun,
                                               NotSentAcc, K),
          Acc#ho_acc{error = ok, total_objects = TotalObjects + 1,
                     notsent_acc = NewNotSentAcc}
    end.

handle_not_sent_item(undefined, _, _) -> undefined;
handle_not_sent_item(NotSentFun, Acc, Key)
    when is_function(NotSentFun) ->
    NotSentFun(Key, Acc).

send_objects([], Acc) -> Acc;
send_objects(ItemsReverseList, Acc) ->
    Items = lists:reverse(ItemsReverseList),
    #ho_acc{ack = Ack, module = Module, socket = Sock,
            src_target = {SrcPartition, TargetPartition},
            stats = Stats, total_objects = TotalObjects,
            total_bytes = TotalBytes,
            item_queue_length = NObjects} =
        Acc,
    ObjectList = term_to_binary(Items),
    M = <<(?PT_MSG_BATCH):8, ObjectList/binary>>,
    NumBytes = byte_size(M),
    Stats2 = incr_bytes(incr_objs(Stats, NObjects),
                        NumBytes),
    Stats3 = maybe_send_status({Module, SrcPartition,
                                TargetPartition},
                               Stats2),
    case gen_tcp:send(Sock, M) of
      ok ->
          Acc#ho_acc{ack = Ack + 1, error = ok, stats = Stats3,
                     total_objects = TotalObjects + NObjects,
                     total_bytes = TotalBytes + NumBytes, item_queue = [],
                     item_queue_length = 0, item_queue_byte_size = 0};
      {error, Reason} ->
          Acc#ho_acc{error = {error, Reason}, stats = Stats3}
    end.

get_handoff_ip(Node) when is_atom(Node) ->
    case riak_core_util:safe_rpc(Node,
                                 riak_core_handoff_listener, get_handoff_ip, [],
                                 infinity)
        of
      {badrpc, _} -> error;
      Res -> Res
    end.

get_handoff_port(Node) when is_atom(Node) ->
    case catch
           riak_core_gen_server:call({riak_core_handoff_listener,
                                      Node},
                                     handoff_port, infinity)
        of
      {'EXIT', _} ->
          %% Check old location from previous release
          riak_core_gen_server:call({riak_kv_handoff_listener,
                                     Node},
                                    handoff_port, infinity);
      Other -> Other
    end.

get_handoff_receive_timeout() ->
    application:get_env(riak_core, handoff_timeout,
                        ?TCP_TIMEOUT).

end_fold_time(StartFoldTime) ->
    EndFoldTime = os:timestamp(),
    timer:now_diff(EndFoldTime, StartFoldTime) / 1000000.

%% @private
%%
%% @doc Produce the value of `now/0' as if it were called `S' seconds
%% in the future.
-spec future_now(pos_integer()) -> erlang:timestamp().

future_now(S) ->
    {Megas, Secs, Micros} = os:timestamp(),
    {Megas, Secs + S, Micros}.

%% @private
%%
%% @doc Check if the given timestamp `TS' has elapsed.
-spec is_elapsed(erlang:timestamp()) -> boolean().

is_elapsed(TS) -> os:timestamp() >= TS.

%% @private
%%
%% @doc Increment `Stats' byte count by `NumBytes'.
-spec incr_bytes(ho_stats(),
                 non_neg_integer()) -> NewStats :: ho_stats().

incr_bytes(Stats = #ho_stats{bytes = Bytes},
           NumBytes) ->
    Stats#ho_stats{bytes = Bytes + NumBytes}.

incr_objs(Stats) -> incr_objs(Stats, 1).

%% @private
%%
%% @doc Increment `Stats' object count by NObjs:
-spec incr_objs(ho_stats(),
                non_neg_integer()) -> NewStats :: ho_stats().

incr_objs(Stats = #ho_stats{objs = Objs}, NObjs) ->
    Stats#ho_stats{objs = Objs + NObjs}.

%% @private
%%
%% @doc Check if the interval has elapsed and if so send handoff stats
%%      for `ModSrcTgt' to the manager and return a new stats record
%%      `NetStats'.
-spec maybe_send_status({module(), non_neg_integer(),
                         non_neg_integer()},
                        ho_stats()) -> NewStats :: ho_stats().

maybe_send_status(ModSrcTgt,
                  Stats = #ho_stats{interval_end = IntervalEnd}) ->
    case is_elapsed(IntervalEnd) of
      true ->
          Stats2 = Stats#ho_stats{last_update = os:timestamp()},
          riak_core_handoff_manager:status_update(ModSrcTgt,
                                                  Stats2),
          #ho_stats{interval_end =
                        future_now(get_status_interval())};
      false -> Stats
    end.

get_status_interval() ->
    application:get_env(riak_core, handoff_status_interval,
                        ?STATUS_INTERVAL).

get_src_partition(Opts) ->
    proplists:get_value(src_partition, Opts).

get_target_partition(Opts) ->
    proplists:get_value(target_partition, Opts).

get_notsent_acc0(Opts) ->
    proplists:get_value(notsent_acc0, Opts).

get_notsent_fun(Opts) ->
    case proplists:get_value(notsent_fun, Opts) of
      none -> fun (_, _) -> undefined end;
      Fun -> Fun
    end.

-spec get_filter(proplists:proplist()) -> predicate().

get_filter(Opts) ->
    case proplists:get_value(filter, Opts) of
      none -> fun (_) -> true end;
      Filter -> Filter
    end.

%% @private
%%
%% @doc check if the handoff reciever will accept batching messages
%%      otherwise fall back to the slower, object-at-a-time path

remote_supports_batching(Node) ->
    case catch rpc:call(Node, riak_core_handoff_receiver,
                        supports_batching, [])
        of
      true ->
          logger:debug("remote node supports batching, enabling"),
          true;
      _ ->
          %% whatever the problem here, just revert to the old behavior
          %% which shouldn't matter too much for any single handoff
          logger:debug("remote node doesn't support batching"),
          false
    end.

%% @private
%% @doc The optional call to handoff_started/2 allows vnodes
%% one last chance to abort the handoff process and to supply options
%% to be passed to the ?FOLD_REQ if not aborted.the function is passed
%% the source vnode's partition number because the callback does not
%% have access to the full vnode state at this time. In addition the
%% worker pid is passed so the vnode may use that information in its
%% decision to cancel the handoff or not e.g. get a lock on behalf of
%% the process.
maybe_call_handoff_started(Module, SrcPartition) ->
    case lists:member({handoff_started, 2},
                      Module:module_info(exports))
        of
      true ->
          WorkerPid = self(),
          case Module:handoff_started(SrcPartition, WorkerPid) of
            {ok, FoldOpts} -> FoldOpts;
            {error, max_concurrency} ->
                %% Handoff of that partition is busy or can't proceed. Stopping with
                %% max_concurrency will cause this partition to be retried again later.
                exit({shutdown, max_concurrency});
            {error, Error} -> exit({shutdown, Error})
          end;
      false ->
          %% optional callback not implemented, so we carry on, w/ no addition fold options
          []
    end.
