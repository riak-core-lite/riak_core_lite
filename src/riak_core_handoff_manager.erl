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

%% Copyright (c) 2007-2012 Basho Technologies, Inc.  All Rights Reserved.
-module(riak_core_handoff_manager).

-behaviour(gen_server).

%% gen_server api
-export([start_link/0,
         init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

%% exclusion api
-export([add_exclusion/2,
         get_exclusions/1,
         remove_exclusion/2]).

%% handoff api
-export([add_outbound/6,
         add_outbound/7,
         add_inbound/0,
         xfer/3,
         kill_xfer/3,
         status/0,
         status/1,
         status_update/2,
         set_concurrency/1,
         get_concurrency/0,
         set_recv_data/2,
         kill_handoffs/0,
         kill_handoffs_in_direction/1,
         handoff_change_enabled_setting/2]).

-include("riak_core_handoff.hrl").

-export_type([ho_type/0]).

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

-endif.

-record(state,
        {excl, handoffs = [] :: [handoff_status()]}).

-type state() :: #state{}.

%% this can be overridden with riak_core handoff_concurrency
-define(HANDOFF_CONCURRENCY, 2).

-define(HO_EQ(HOA, HOB),
        HOA#handoff_status.mod_src_tgt ==
            HOB#handoff_status.mod_src_tgt
            andalso
            HOA#handoff_status.timestamp ==
                HOB#handoff_status.timestamp).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Start the handoff manager server.
%% @see gen_server:start_link/4.
-spec start_link() -> {ok, pid()} |
                      ignore |
                      {error, term()}.

start_link() ->
    gen_server:start_link({local, ?MODULE},
                          ?MODULE,
                          [],
                          []).

%% @doc Callback for {@link gen_server:start_link/4}. The initial state has no
%%      exclusions or handoffs set.
-spec init([]) -> {ok, state()}.

init([]) ->
    {ok, #state{excl = sets:new(), handoffs = []}}.

%% @doc Like {@link add_outbound/7} where source and target index are the same.
%% @param HOType Handoff type to add.
%% @param Module VNode module handling the handoff.
%% @param Idx Index to hand off.
%% @param Node Node owning the new target index.
%% @param VnodePid Process id of the node handing off the index.
%% @param Opts List of handoff options.
%% @returns `{ok, Sender}' if the handoff was added successfully,
%%          `{error, max_concurrency}' if no more concurrent handoffs can be
%%          added.
-spec add_outbound(HOType :: ho_type(),
		   Module :: module(), Idx :: index(), Node :: node(),
		   VnodePid :: pid(), Opts :: [term()]) -> {ok, pid()} |
							   {error,
							    max_concurrency}.

add_outbound(HOType, Module, Idx, Node, VnodePid,
             Opts) ->
    add_outbound(HOType,
                 Module,
                 Idx,
                 Idx,
                 Node,
                 VnodePid,
                 Opts).

%% @doc Add an outbound handoff from the source index to the target index.
%% @param HOType Handoff type to add.
%% @param Module VNode module handling the handoff.
%% @param SrcIdx Index to hand off.
%% @param TaragetIdx Index to handoff to.
%% @param Node Node owning the new target index.
%% @param VnodePid Process id of the node handing off the index.
%% @param Opts List of handoff options.
%% @returns `{ok, Sender}' if the handoff was added successfully,
%%          `{error, max_concurrency}' if no more concurrent handoffs can be
%%          added.
-spec add_outbound(HOType :: ho_type(),
		   Module :: module(), SrcIdx :: index(),
		   TargetIdx :: index(), Node :: node(), VnodePid :: pid(),
		   Opts :: [{atom(), term()}]) -> {ok, pid()} |
						  {error, max_concurrency}.

add_outbound(HOType, Module, SrcIdx, TargetIdx, Node,
	     VnodePid, Opts) ->
    case application:get_env(riak_core,
                             disable_outbound_handoff)
        of
        {ok, true} -> {error, max_concurrency};
        _ ->
            gen_server:call(?MODULE,
                            {add_outbound,
                             HOType,
                             Module,
                             SrcIdx,
                             TargetIdx,
                             Node,
                             VnodePid,
                             Opts},
                            infinity)
    end.

%% @doc Add an inbound handoff. Starts a receiver process.
%% @return `{ok, Receiver}' if the receiver could be started,
%%          `{error, max_concurrency}' if no additional handoffs can be handled.
-spec add_inbound() -> {ok, pid()} |
		       {error, max_concurrency}.

add_inbound() ->
    case application:get_env(riak_core,
                             disable_inbound_handoff)
        of
        {ok, true} -> {error, max_concurrency};
        _ -> gen_server:call(?MODULE, {add_inbound}, infinity)
    end.

%% @doc Initiate a transfer from `SrcPartition' to `TargetPartition'
%%      for the given `Module' using the `FilterModFun' filter.
%% @param PartitionOwner Tuple of the source partition index and owner.
%% @param ModPartitions Tuple of target module and partition index.
%% @param FilterModFun Module and function name of a filter function to use.
%% @returns `ok'.
-spec xfer(PartitionOwner :: {index(), node()},
	   ModPartitions :: mod_partition(),
	   FilterModFun :: {module(), atom()}) -> ok.

xfer({SrcPartition, SrcOwner},
     {Module, TargetPartition}, FilterModFun) ->
    %% NOTE: This will not work with old nodes
    ReqOrigin = node(),
    gen_server:cast({?MODULE, SrcOwner},
                    {send_handoff,
                     repair,
                     Module,
                     {SrcPartition, TargetPartition},
                     ReqOrigin,
                     FilterModFun}).

%% @doc Associate `Data' with the inbound handoff `Recv'.
%% @param Recv Process ID of the handoff receiver.
%% @param Data Data to associate with the receiver.
%% @returns `ok'.
-spec set_recv_data(Recv :: pid(),
		    Data :: proplists:proplist()) -> ok.

set_recv_data(Recv, Data) ->
    gen_server:call(?MODULE,
                    {set_recv_data, Recv, Data},
                    infinity).

%% @doc Get the list of all handoff status.
%% @returns All handof_status in the current state.
-spec status() -> [handoff_status()].

status() -> status(none).

%% @doc Get the list of all handoff status containing the given key-value pair.
%% @param Filter A key-value pair that is necessary to consider a handoff status
%%        part of the status. If `none' is given, nothing is filtered out.
%% @returns The filtered list of handoff status.
-spec status(Filter :: none |
		       {term(), term()}) -> [handoff_status()].

status(Filter) ->
    gen_server:call(?MODULE, {status, Filter}, infinity).

%% @doc Send status updates `Stats' to the handoff manager for a
%%      particular handoff identified by `ModSrcTgt'.
%% @param ModSrcTgt Module, source and target index identifying the handoff.
%% @param Stats Handoff stats.
%% @returns `ok'.
-spec status_update(ModSrcTgt :: mod_src_tgt(),
		    Stats :: ho_stats()) -> ok.

status_update(ModSrcTgt, Stats) ->
    gen_server:cast(?MODULE,
		    {status_update, ModSrcTgt, Stats}).

%% @doc Set a new limit of concurrent handoffs. If the limit is less then the
%%      current number of concurrent handoffs, some are discarded.
%% @param Limit Maximum number of concurrent handoffs.
%% @returns `ok'.
-spec set_concurrency(Limit :: integer()) -> ok.

set_concurrency(Limit) ->
    gen_server:call(?MODULE,
                    {set_concurrency, Limit},
                    infinity).

-spec get_concurrency() -> integer().

get_concurrency() ->
    gen_server:call(?MODULE, get_concurrency, infinity).

%% @doc Kill the transfer of `ModSrcTarget' with `Reason'.
%% @param SrcNode Node reqeusting to kill the transfer.
%% @param ModSrcTarget Tupel of module, source and target index that identifies
%%        the handoff.
%% @param Reason Term giving a reason for the termination.
%% @returns `ok'.
-spec kill_xfer(SrcNode :: node(),
		ModSrcTarget :: mod_src_tgt(), Reason :: any()) -> ok.

kill_xfer(SrcNode, ModSrcTarget, Reason) ->
    gen_server:cast({?MODULE, SrcNode},
		    {kill_xfer, ModSrcTarget, Reason}).

%% @doc Kill all handoffs.
%% @returns `ok'.
-spec kill_handoffs() -> ok.

kill_handoffs() -> set_concurrency(0).

%% @doc Kill all handoffs in the given direction
%% @param Direction Determines if `inbound' or `outbound' handoffs are killed.
%% @returns `ok'.
-spec kill_handoffs_in_direction(inbound |
				 outbound) -> ok.

kill_handoffs_in_direction(Direction) ->
    gen_server:call(?MODULE,
                    {kill_in_direction, Direction},
                    infinity).

%% @doc Add a handoff exclusion for a given module and source index.
%% @param Module Module to add the exception for.
%% @param Index Index to add the exception for.
%% @returns `ok'.
-spec add_exclusion(Module :: module(),
		    Index :: index()) -> ok.

add_exclusion(Module, Index) ->
    gen_server:cast(?MODULE,
		    {add_exclusion, {Module, Index}}).

%% @doc Remove a handoff exclusion for the given module and index.
%% @param Module MOdule identifying the exclusion.
%% @param Index INdex identifying the exclusion.
%% @returns `ok'.
-spec remove_exclusion(Module :: module(),
		       Index :: index()) -> ok.

remove_exclusion(Module, Index) ->
    gen_server:cast(?MODULE,
		    {del_exclusion, {Module, Index}}).

%% @doc Get all indices for which an exclusion on a module exists.
%% @param Module Module to get exclusions for.
%% @returns List of indices.
-spec get_exclusions(Module :: module()) -> {ok,
					     [index()]}.

get_exclusions(Module) ->
    gen_server:call(?MODULE,
                    {get_exclusions, Module},
                    infinity).

%%%===================================================================
%%% Callbacks
%%%===================================================================

%% @doc Callback for {@link gen_server:call/3}.
-spec handle_call(Msg :: {get_exclusions, module()} |
                         {add_outbound, ho_type(), module(), index(), index(),
                          node(), pid(), [{atom(), term()}]} |
                         {add_inbound} |
                         {set_recv_data, pid(), proplists:proplist()} |
                         {xfer_status, handoff_status()} |
                         {status, none | {term(), term()}} |
                         {set_concurrency, integer()} |
                         get_concurrency |
                         {kill_in_direction, inound | outbound},
                  From :: {pid(), term()}, State :: state()) -> {reply,
                                                                 term(),
                                                                 state()}.

handle_call({get_exclusions, Module}, _From,
	    State = #state{excl = Excl}) ->
    Reply = [I
	     || {M, I} <- sets:to_list(Excl), M =:= Module],
    {reply, {ok, Reply}, State};
handle_call({add_outbound,
             Type,
             Mod,
             SrcIdx,
             TargetIdx,
             Node,
             Pid,
             Opts},
            _From, State = #state{handoffs = HS}) ->
    case send_handoff(Type,
                      {Mod, SrcIdx, TargetIdx},
                      Node,
                      Pid,
                      HS,
                      Opts)
        of
        {ok,
         Handoff = #handoff_status{transport_pid = Sender}} ->
            HS2 = HS ++ [Handoff],
            {reply, {ok, Sender}, State#state{handoffs = HS2}};
        {false,
         _ExistingHandoff = #handoff_status{transport_pid =
                                                Sender}} ->
            {reply, {ok, Sender}, State};
        Error -> {reply, Error, State}
    end;
handle_call({add_inbound}, _From,
	    State = #state{handoffs = HS}) ->
    case receive_handoff() of
        {ok,
         Handoff = #handoff_status{transport_pid = Receiver}} ->
            HS2 = HS ++ [Handoff],
            {reply, {ok, Receiver}, State#state{handoffs = HS2}};
        Error -> {reply, Error, State}
    end;
handle_call({set_recv_data, Recv, Data}, _From,
            State = #state{handoffs = HS}) ->
    case lists:keyfind(Recv,
                       #handoff_status.transport_pid,
                       HS)
        of
        false ->
            throw({error,
                   "set_recv_data called for non-existing "
                   "receiver",
                   Recv,
                   Data});
        #handoff_status{} = H ->
            H2 = H#handoff_status{mod_src_tgt =
                                      proplists:get_value(mod_src_tgt, Data),
                                  vnode_pid =
                                      proplists:get_value(vnode_pid, Data)},
            HS2 = lists:keyreplace(Recv,
                                   #handoff_status.transport_pid,
                                   HS,
                                   H2),
            {reply, ok, State#state{handoffs = HS2}}
    end;
handle_call({xfer_status, Xfer}, _From,
	    State = #state{handoffs = HS}) ->
    TP = Xfer#handoff_status.transport_pid,
    case lists:keyfind(TP,
                       #handoff_status.transport_pid,
                       HS)
        of
        false -> {reply, not_found, State};
        _ -> {reply, in_progress, State}
    end;
handle_call({status, Filter}, _From,
	    State = #state{handoffs = HS}) ->
    Status = lists:filter(filter(Filter),
			  [build_status(HO) || HO <- HS]),
    {reply, Status, State};
handle_call({set_concurrency, Limit}, _From,
            State = #state{handoffs = HS}) ->
    application:set_env(riak_core,
                        handoff_concurrency,
                        Limit),
    case Limit < erlang:length(HS) of
        true ->
            %% Note: we don't update the state with the handoffs that we're
            %% keeping because we'll still get the 'DOWN' messages with
            %% a reason of 'max_concurrency' and we want to be able to do
            %% something with that if necessary.
            {_Keep, Discard} = lists:split(Limit, HS),
            _ = [erlang:exit(Pid, max_concurrency)
                 || #handoff_status{transport_pid = Pid} <- Discard],
            {reply, ok, State};
        false -> {reply, ok, State}
    end;
handle_call(get_concurrency, _From, State) ->
    Concurrency = get_concurrency_limit(),
    {reply, Concurrency, State};
handle_call({kill_in_direction, Direction}, _From,
	    State = #state{handoffs = HS}) ->
    %% TODO (atb): Refactor this to comply with max_concurrency logspam PR's exit codes
    %% NB. As-is this handles worker termination the same way as set_concurrency;
    %%     no state update is performed here, we let the worker DOWNs mark them
    %%     as dead rather than trimming here.
    Kill = [H
	    || H = #handoff_status{direction = D} <- HS,
	       D =:= Direction],
    _ = [erlang:exit(Pid, max_concurrency)
	 || #handoff_status{transport_pid = Pid} <- Kill],
    {reply, ok, State}.

%% @doc Callback for {@link gen_server:cast/2}.
-spec handle_cast(Msg :: term(), state()) -> {noreply,
					      state()}.

handle_cast({del_exclusion, {Mod, Idx}},
	    State = #state{excl = Excl}) ->
    Excl2 = sets:del_element({Mod, Idx}, Excl),
    {noreply, State#state{excl = Excl2}};
handle_cast({add_exclusion, {Mod, Idx}},
	    State = #state{excl = Excl}) ->
    %% Note: This function used to trigger a ring event after adding an
    %% exclusion to ensure that an exiting node would eventually shutdown
    %% after all vnodes had finished handoff. This behavior is now handled
    %% by riak_core_vnode_manager:maybe_ensure_vnodes_started
    Excl2 = sets:add_element({Mod, Idx}, Excl),
    {noreply, State#state{excl = Excl2}};
handle_cast({status_update, ModSrcTgt, StatsUpdate},
	    State = #state{handoffs = HS}) ->
    case lists:keyfind(ModSrcTgt,
                       #handoff_status.mod_src_tgt,
                       HS)
        of
        false ->
            logger:error("status_update for non-existing handoff ~p",
                         [ModSrcTgt]),
            {noreply, State};
        HO ->
            Stats2 = update_stats(StatsUpdate,
                                  HO#handoff_status.stats),
            HO2 = HO#handoff_status{stats = Stats2},
            HS2 = lists:keyreplace(ModSrcTgt,
                                   #handoff_status.mod_src_tgt,
                                   HS,
                                   HO2),
            {noreply, State#state{handoffs = HS2}}
    end;
handle_cast({send_handoff,
             Type,
             Mod,
             {Src, Target},
             ReqOrigin,
             {Module, FilterFun} = FMF},
            State = #state{handoffs = HS}) ->
    Filter = Module:FilterFun(Target),
    %% TODO: make a record?
    {ok, VNode} = riak_core_vnode_manager:get_vnode_pid(Src,
                                                        Mod),
    case send_handoff(Type,
                      {Mod, Src, Target},
                      ReqOrigin,
                      VNode,
                      HS,
                      {Filter, FMF},
                      ReqOrigin,
                      [])
        of
        {ok, Handoff} ->
            HS2 = HS ++ [Handoff],
            {noreply, State#state{handoffs = HS2}};
        _ -> {noreply, State}
    end;
handle_cast({kill_xfer, ModSrcTarget, Reason}, State) ->
    HS = State#state.handoffs,
    HS2 = kill_xfer_i(ModSrcTarget, Reason, HS),
    {noreply, State#state{handoffs = HS2}}.

%% @doc Callback for {@link gen_server} handling incoming messages that are not
%%      a call or cast.
%% @returns `{noreply, State}'.
-spec handle_info({'DOWN', reference(), process, pid(),
		   term()},
		  state()) -> {noreply, state()}.

handle_info({'DOWN', Ref, process, _Pid, Reason},
            State = #state{handoffs = HS}) ->
    case lists:keytake(Ref,
                       #handoff_status.transport_mon,
                       HS)
        of
        {value,
         #handoff_status{mod_src_tgt = {M, S, I},
                         direction = Dir, vnode_pid = Vnode, vnode_mon = VnodeM,
                         req_origin = Origin},
         NewHS} ->
            WarnVnode = case Reason of
                            %% if the reason the handoff process died was anything other
                            %% than 'normal' we should log the reason why as an error
                            normal -> false;
                            X
                                when X == max_concurrency orelse
                                         element(1, X) == shutdown andalso
                                             element(2, X) == max_concurrency ->
                                logger:info("An ~w handoff of partition ~w ~w was "
                                            "terminated\n                        "
                                            "             for reason: ~w~n",
                                            [Dir, M, I, Reason]),
                                true;
                            _ ->
                                logger:error("An ~w handoff of partition ~w ~w was "
                                             "terminated\n                        "
                                             "             for reason: ~w~n",
                                             [Dir, M, I, Reason]),
                                true
                        end,
            %% if we have the vnode process pid, tell the vnode why the
            %% handoff stopped so it can clean up its state
            case WarnVnode andalso is_pid(Vnode) of
                true ->
                    riak_core_vnode:handoff_error(Vnode, 'DOWN', Reason);
                _ ->
                    case Origin of
                        none -> ok;
                        _ ->
                            %% Use proplist instead so it's more
                            %% flexible in future, or does
                            %% capabilities nullify that?
                            Msg = {M, S, I},
                            riak_core_vnode_manager:xfer_complete(Origin, Msg)
                    end,
                    ok
            end,
            %% No monitor on vnode for receiver
            if VnodeM /= undefined -> demonitor(VnodeM);
               true -> ok
            end,
            %% removed the handoff from the list of active handoffs
            {noreply, State#state{handoffs = NewHS}};
        false ->
            case lists:keytake(Ref, #handoff_status.vnode_mon, HS)
                of
                {value,
                 #handoff_status{mod_src_tgt = {M, _, I},
                                 direction = Dir, transport_pid = Trans,
                                 transport_mon = TransM},
                 NewHS} ->
                    %% In this case the vnode died and the handoff
                    %% sender must be killed.
                    logger:error("An ~w handoff of partition ~w ~w was "
                                 "terminated because the vnode died",
                                 [Dir, M, I]),
                    demonitor(TransM),
                    exit(Trans, vnode_died),
                    {noreply, State#state{handoffs = NewHS}};
                _ -> {noreply, State}
            end
    end.

%% @doc Callback for {@link gen_server:stop/1}. Not implemented.
-spec terminate(Reason :: term(),
		State :: state()) -> ok.

terminate(_Reason, _State) -> ok.

%% @doc Callback for {@link gen_server}. Not implemented.
-spec code_change(OldVsn :: term(), State :: state(),
		  Extra :: term()) -> {ok, state()}.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%%===================================================================
%%% Private
%%%===================================================================

%% @private
%% @doc Build a status list from a `handoff_status' record.
%% @param HO Handoff status record.
%% @returns `{status_v2, StatusEntries}'.
-spec build_status(HO ::
		       handoff_status()) -> {status_v2, [{atom(), term()}]}.

build_status(HO) ->
    #handoff_status{mod_src_tgt = {Mod, SrcP, TargetP},
		    src_node = SrcNode, target_node = TargetNode,
		    direction = Dir, status = Status, timestamp = StartTS,
		    transport_pid = TPid, type = Type} =
	HO,
    {status_v2,
     [{mod, Mod},
      {src_partition, SrcP},
      {target_partition, TargetP},
      {src_node, SrcNode},
      {target_node, TargetNode},
      {direction, Dir},
      {status, Status},
      {start_ts, StartTS},
      {sender_pid, TPid},
      {stats, calc_stats(HO)},
      {type, Type}]}.

%% @private
%% @doc Retrieve statistics from a handoff status.
%% @param HO Handoff status.
%% @returns List of statistics or `no_stats'.
-spec calc_stats(HO :: handoff_status()) -> [{atom(),
					      term()}] |
					    no_stats.

calc_stats(#handoff_status{stats = Stats,
			   timestamp = StartTS, size = Size}) ->
    case dict:find(last_update, Stats) of
        error -> no_stats;
        {ok, LastUpdate} ->
            Objs = dict:fetch(objs, Stats),
            Bytes = dict:fetch(bytes, Stats),
            CalcSize = get_size(Size),
            Done = calc_pct_done(Objs, Bytes, CalcSize),
            ElapsedS = timer:now_diff(LastUpdate, StartTS) /
                           1000000,
            ObjsS = round(Objs / ElapsedS),
            BytesS = round(Bytes / ElapsedS),
            [{objs_total, Objs},
             {objs_per_s, ObjsS},
             {bytes_per_s, BytesS},
             {last_update, LastUpdate},
             {size, CalcSize},
             {pct_done_decimal, Done}]
    end.

%% @private
%% @doc Get actual size from a size entry.
-spec get_size(Size :: {function(), dynamic} |
		       {non_neg_integer(), bytes | objects}) -> {integer(),
								 bytes |
								 objects} |
								undefined.

get_size({F, dynamic}) -> F();
get_size(S) -> S.

%% @private
%% @doc Calculate percentage of completed handoffs?
-spec calc_pct_done(Objs :: integer(),
		    Bytes :: integer(),
		    Size :: undefined |
			    {integer(), objects | bytes}) -> float() |
							     undefined.

calc_pct_done(Objs, _, {Size, objects}) -> Objs / Size;
calc_pct_done(_, Bytes, {Size, bytes}) -> Bytes / Size;
calc_pct_done(_, _, undefined) -> undefined.

%% @private
%% @doc Create a filter function from a key value pair.
-spec filter(Filter :: none | {}) -> fun(({status_v2,
					   handoff_status()}) -> boolean()).

filter(none) -> fun (_) -> true end;
filter({Key, Value} = _Filter) ->
    fun ({status_v2, Status}) ->
            case proplists:get_value(Key, Status) of
                Value -> true;
                _ -> false
            end
    end.

%% @private
%% @doc Generate a resize tranfer filter function.
%% @param Ring Ring affected by the transfer.
%% @param Module Module involved in the handoff.
%% @param Src Source index.
%% @param Target Target index.
%% @returns Filter function.
-spec resize_transfer_filter(Ring ::
				 riak_core_ring:riak_core_ring(),
			     Module :: module(), Src :: index(),
			     Target :: index()) -> fun((term()) -> boolean()).

resize_transfer_filter(Ring, Module, Src, Target) ->
    fun (K) ->
            {_, Hashed} = Module:object_info(K),
            riak_core_ring:is_future_index(Hashed,
                                           Src,
                                           Target,
                                           Ring)
    end.

%% @private
%% @doc Create a filter function that filters for unsent indices.
%% @param Ring Ring the transfer takes place on.
%% @param Module Module involved in the handoff.
%% @param Src Source index of the handoffs.
%% @returns Function filtering for unsent indices.
-spec resize_transfer_notsent_fun(Ring ::
				      riak_core_ring:riak_core_ring(),
				  Module :: module(),
				  Src :: index()) -> fun((term(),
							  [index()]) -> boolean()).

resize_transfer_notsent_fun(Ring, Module, Src) ->
    Shrinking = riak_core_ring:num_partitions(Ring) >
                    riak_core_ring:future_num_partitions(Ring),
    {NValMap, DefaultN} = case Shrinking of
                              false -> {undefined, undefined};
                              true ->
                                  {ok, DefN} = application:get_env(riak_core,
                                                                   target_n_val),
                                  {Module:nval_map(Ring), DefN}
                          end,
    fun (Key, Acc) ->
            record_seen_index(Ring,
                              Shrinking,
                              NValMap,
                              DefaultN,
                              Module,
                              Src,
                              Key,
                              Acc)
    end.

-spec record_seen_index(Ring ::
			    riak_core_ring:riak_core_ring(),
			Shrinking :: boolean(),
			NValMap :: [{term(), integer()}], DefaultN :: integer(),
			Module :: module(), Src :: index(), Key :: term(),
			Seen ::
			    ordsets:ordset(index())) -> ordsets:ordset(index()).

record_seen_index(Ring, Shrinking, NValMap, DefaultN,
		  Module, Src, Key, Seen) ->
    {Bucket, Hashed} = Module:object_info(Key),
    CheckNVal = case Shrinking of
                    false -> undefined;
                    true -> proplists:get_value(Bucket, NValMap, DefaultN)
                end,
    case riak_core_ring:future_index(Hashed,
                                     Src,
                                     CheckNVal,
                                     Ring)
        of
        undefined -> Seen;
        FutureIndex -> ordsets:add_element(FutureIndex, Seen)
    end.

%% @private
%% @doc Retrieve the maximum number of concurrent handoffs.
-spec get_concurrency_limit() -> integer().

get_concurrency_limit() ->
    application:get_env(riak_core,
                        handoff_concurrency,
                        ?HANDOFF_CONCURRENCY).

%% @doc Check if the concurrency limit is reached.
%% @returns `true' if handoff_concurrency (inbound + outbound) hasn't yet been
%%          reached.
-spec handoff_concurrency_limit_reached() -> boolean().

handoff_concurrency_limit_reached() ->
    Receivers =
	supervisor:count_children(riak_core_handoff_receiver_sup),
    Senders =
	supervisor:count_children(riak_core_handoff_sender_sup),
    ActiveReceivers = proplists:get_value(active,
					  Receivers),
    ActiveSenders = proplists:get_value(active, Senders),
    get_concurrency_limit() =<
        ActiveReceivers + ActiveSenders.

%% @private
%% @doc Like {@link send_handoff/8} without filters or an origin node.
-spec send_handoff(HOType :: ho_type(),
		   ModSourceTarget :: {module(), index(), index()},
		   Node :: node(), Pid :: pid(), HS :: list(),
		   Opts :: [{atom(), term()}]) -> {ok, handoff_status()} |
						  {error, max_concurrency} |
						  {false, handoff_status()}.

send_handoff(HOType, ModSrcTarget, Node, Pid, HS,
             Opts) ->
    send_handoff(HOType,
                 ModSrcTarget,
                 Node,
                 Pid,
                 HS,
                 {none, none},
                 none,
                 Opts).

%% @private
%% @doc Start a handoff process for the given `Mod' from
%%      `Src'/`VNode' to `Target'/`Node' using the given `Filter'
%%      function which is a predicate applied to the key.  The
%%      `Origin' is the node this request originated from so a reply
%%      can't be sent on completion.
%% @param HOType Type of the handoff.
%% @param MST Triple of the module, source index and target index the handoff
%%        affects.
%% @param Node Target node of the handoff.
%% @param Vnode Process id of the source node.
%% @param HS List of handoff status.
%% @param FilterTuple Tuple of filter predicate and filter function in a module.
%% @param Origin Node requesting the hadoff.
%% @param Opts List of options for the handoff.
%% @returns `{ok, NewHandoff}' if the handoff is should happen,
%%          `{false, CurrentHandoff}' if the handoff should not happen,
%%          `{error, max_concurrency}' if the concurrency limit is reached.
-spec send_handoff(HOType :: ho_type(),
		   MST :: {Mod :: module(), Src :: index(),
			   Target :: index()},
		   Node :: node(), Vnode :: pid(), HS :: list(),
		   FilterTuple :: {Filter :: predicate() | none,
				   FilterModFun :: {module(), atom()} | none},
		   Origin :: node(), Opts :: [{atom(), term()}]) -> {ok,
								     handoff_status()} |
								    {error,
								     max_concurrency} |
								    {false,
								     handoff_status()}.

send_handoff(HOType, {Mod, Src, Target}, Node, Vnode,
	     HS, {Filter, FilterModFun}, Origin, Opts) ->
    case handoff_concurrency_limit_reached() of
        true -> {error, max_concurrency};
        false ->
            ShouldHandoff = case lists:keyfind({Mod, Src, Target},
                                               #handoff_status.mod_src_tgt,
                                               HS)
                                of
                                false -> true;
                                Handoff = #handoff_status{target_node = Node,
                                                          vnode_pid = Vnode} ->
                                    {false, Handoff};
                                #handoff_status{transport_pid = Sender} ->
                                    %% found a running handoff with a different vnode
                                    %% source or a different target node, kill the current
                                    %% one and the new one will start up
                                    erlang:exit(Sender,
                                                resubmit_handoff_change),
                                    true
                            end,
            case ShouldHandoff of
                true ->
                    VnodeM = monitor(process, Vnode),
                    %% start the sender process
                    BaseOpts = [{src_partition, Src},
                                {target_partition, Target}],
                    case HOType of
                        repair ->
                            HOFilter = Filter,
                            HOAcc0 = undefined,
                            HONotSentFun = undefined;
                        resize ->
                            {ok, Ring} = riak_core_ring_manager:get_my_ring(),
                            HOFilter = resize_transfer_filter(Ring,
                                                              Mod,
                                                              Src,
                                                              Target),
                            HOAcc0 = ordsets:new(),
                            HONotSentFun = resize_transfer_notsent_fun(Ring,
                                                                       Mod,
                                                                       Src);
                        _ ->
                            HOFilter = none,
                            HOAcc0 = undefined,
                            HONotSentFun = undefined
                    end,
                    HOOpts = [{filter, HOFilter},
                              {notsent_acc0, HOAcc0},
                              {notsent_fun, HONotSentFun}
                              | BaseOpts],
                    {ok, Pid} =
                        riak_core_handoff_sender_sup:start_sender(HOType,
                                                                  Mod,
                                                                  Node,
                                                                  Vnode,
                                                                  HOOpts),
                    PidM = monitor(process, Pid),
                    Size = validate_size(proplists:get_value(size, Opts)),
                    %% successfully started up a new sender handoff
                    {ok,
                     #handoff_status{transport_pid = Pid,
                                     transport_mon = PidM, direction = outbound,
                                     timestamp = os:timestamp(),
                                     src_node = node(), target_node = Node,
                                     mod_src_tgt = {Mod, Src, Target},
                                     vnode_pid = Vnode, vnode_mon = VnodeM,
                                     status = [], stats = dict:new(),
                                     type = HOType, req_origin = Origin,
                                     filter_mod_fun = FilterModFun,
                                     size = Size}};
                %% handoff already going, just return it
                AlreadyExists = {false, _CurrentHandoff} ->
                    AlreadyExists
            end
    end.

%% @doc Spawn a receiver process.
%% @returns `{ok, Status}' if the handoff receiver could be started,
%%          `{error, max_concurrency}' if the concurrency limit is reached.
-spec receive_handoff() -> {ok, handoff_status()} |
			   {error, max_concurrency}.

receive_handoff() ->
    case handoff_concurrency_limit_reached() of
        true -> {error, max_concurrency};
        false ->
            {ok, Pid} =
                riak_core_handoff_receiver_sup:start_receiver(),
            PidM = monitor(process, Pid),
            %% successfully started up a new receiver
            {ok,
             #handoff_status{transport_pid = Pid,
                             transport_mon = PidM, direction = inbound,
                             timestamp = os:timestamp(),
                             mod_src_tgt = {undefined, undefined, undefined},
                             src_node = undefined, target_node = undefined,
                             status = [], stats = dict:new(),
                             req_origin = none}}
    end.

%% @private
%% @doc Update a stats dictionary with a new stats record.
%% @param StatsUpdate handoff stats record containing new information.
%% @param Stats Stats dictionary to update.
%% @returns Updated stats dictionary.
-spec update_stats(StatsUpdate :: ho_stats(),
		   Stats :: dict:dict(term(), term())) -> dict:dict(term(),
								    term()).

update_stats(StatsUpdate, Stats) ->
    #ho_stats{last_update = LU, objs = Objs,
	      bytes = Bytes} =
	StatsUpdate,
    Stats2 = dict:update_counter(objs, Objs, Stats),
    Stats3 = dict:update_counter(bytes, Bytes, Stats2),
    dict:store(last_update, LU, Stats3).

%% @private
%% @doc Check if a size object is valid, i.e. for objects and bytes the integer
%%      is positive and for dynamic size the function is a function.
%% @returns Validated size or `undefined'.
-spec validate_size(Size :: {function(), dynamic} |
			    {integer(), bytes | objects}) -> function() |
							     {integer(),
							      bytes | objects} |
							     undefined.

validate_size(Size = {N, U})
    when is_number(N) andalso
             N > 0 andalso (U =:= bytes orelse U =:= objects) ->
    Size;
validate_size(Size = {F, dynamic})
    when is_function(F) ->
    Size;
validate_size(_) -> undefined.

%% @private
%% @doc Kill and remove _each_ xfer associated with `ModSrcTarget'
%%      with `Reason'.  There might be more than one because repair
%%      can have two simultaneous inbound xfers.
%% @param ModSrcTarget Triple of module, source and target index to identify the
%%        handoff.
%% @param Reason Reason to kill the transfer.
%% @param HS Handoff status to remove the transfer from.
%% @returns Handoff status with the transfer removed.
-spec kill_xfer_i(ModSrcTarget :: mod_src_tgt(),
		  Reason :: term(), HS :: [tuple()]) -> [tuple()].

kill_xfer_i(ModSrcTarget, Reason, HS) ->
    case lists:keytake(ModSrcTarget,
                       #handoff_status.mod_src_tgt,
                       HS)
        of
        false -> HS;
        {value, Xfer, HS2} ->
            #handoff_status{mod_src_tgt =
                                {Mod, SrcPartition, TargetPartition},
                            type = Type, target_node = TargetNode,
                            src_node = SrcNode, transport_pid = TP} =
                Xfer,
            Msg = "~p transfer of ~p from ~p ~p to ~p ~p "
                  "killed for reason ~p",
            case Type of
                undefined -> ok;
                _ ->
                    logger:info(Msg,
                                [Type,
                                 Mod,
                                 SrcNode,
                                 SrcPartition,
                                 TargetNode,
                                 TargetPartition,
                                 Reason])
            end,
            exit(TP, {kill_xfer, Reason}),
            kill_xfer_i(ModSrcTarget, Reason, HS2)
    end.

%% @private
%% @doc Change the application setting to enable or disable handoffs in the
%%      given direction.
%% @param EnOrDis Enable or disable handoffs.
%% @param Direction Direction of the handoffs to enable or disable.
%% @returns `ok'.
-spec handoff_change_enabled_setting(EnOrDis :: enable |
                                                disable,
                                     Direction :: inbound |
                                                  outbound |
                                                  both) -> ok.

handoff_change_enabled_setting(EnOrDis, Direction) ->
    SetFun = case EnOrDis of
                 enable -> fun handoff_enable/1;
                 disable -> fun handoff_disable/1
             end,
    case Direction of
        inbound -> SetFun(inbound);
        outbound -> SetFun(outbound);
        both ->
            SetFun(inbound),
            SetFun(outbound)
    end.

%% @private
%% @doc Enable handoffs in the given direction.
%% @param Direction Enable inbound or outbound handoffs.
-spec handoff_enable(Direction :: inbound |
				  outbound) -> ok.

handoff_enable(inbound) ->
    application:set_env(riak_core,
                        disable_inbound_handoff,
                        false);
handoff_enable(outbound) ->
    application:set_env(riak_core,
                        disable_outbound_handoff,
                        false).

%% @private
%% @doc Disable handoffs in the given direction.
%% @param Direction Disable inbound or outbound handoffs.
%% @returns `ok'.
-spec handoff_disable(Direction :: inbound |
				   outbound) -> ok.

handoff_disable(inbound) ->
    application:set_env(riak_core,
                        disable_inbound_handoff,
                        true),
    kill_handoffs_in_direction(inbound);
handoff_disable(outbound) ->
    application:set_env(riak_core,
                        disable_outbound_handoff,
                        true),
    kill_handoffs_in_direction(outbound).

%%%===================================================================
%%% Tests
%%%===================================================================

-ifdef(TEST).

handoff_test_() ->
    {spawn,
     {setup,
      %% called when the tests start and complete...
      fun () ->
	      {ok, ManPid} = start_link(),
	      {ok, RSupPid} =
		  riak_core_handoff_receiver_sup:start_link(),
	      {ok, SSupPid} =
		  riak_core_handoff_sender_sup:start_link(),
	      [ManPid, RSupPid, SSupPid]
      end,
      fun (PidList) ->
	      lists:foreach(fun (Pid) -> exit(Pid, kill) end, PidList)
      end,
      %% actual list of test
      [?_test((simple_handoff())),
       ?_test((config_disable()))]}}.

simple_handoff() ->
    ?assertEqual([], (status())),
    %% clear handoff_concurrency and make sure a handoff fails
    ?assertEqual(ok, (set_concurrency(0))),
    ?assertEqual({error, max_concurrency}, (add_inbound())),
    ?assertEqual({error, max_concurrency},
                 (add_outbound(ownership,
                               riak_kv_vnode,
                               0,
                               node(),
                               self(),
                               []))),
    %% allow for a single handoff
    ?assertEqual(ok, (set_concurrency(1))),
    %% done
    ok.

config_disable() ->
    %% expect error log
    error_logger:tty(false),
    ?assertEqual(ok, (handoff_enable(inbound))),
    ?assertEqual(ok, (handoff_enable(outbound))),
    ?assertEqual(ok, (set_concurrency(2))),
    ?assertEqual([], (status())),
    Res = add_inbound(),
    ?assertMatch({ok, _}, Res),
    {ok, Pid} = Res,
    ?assertEqual(1, (length(status()))),
    Ref = monitor(process, Pid),
    CatchDownFun = fun () ->
                           receive
                               {'DOWN', Ref, process, Pid, max_concurrency} ->
                                   ok;
                               Other -> {error, unexpected_message, Other}
                               after 1000 ->
                                         {error, timeout_waiting_for_down_msg}
                           end
                   end,
    ?assertEqual(ok, (handoff_disable(inbound))),
    ?assertEqual(ok, (CatchDownFun())),
    %% We use wait_until because it's possible that the handoff manager process
    %% could get our call to status/0 before it receives the 'DOWN' message,
    %% so we periodically retry the call for a while until we get the answer we
    %% expect, or until we time out.
    Status0 = fun () -> length(status()) =:= 0 end,
    ?assertEqual(ok, (wait_until(Status0, 500, 1))),
    ?assertEqual({error, max_concurrency}, (add_inbound())),
    ?assertEqual(ok, (handoff_enable(inbound))),
    ?assertEqual(ok, (handoff_enable(outbound))),
    ?assertEqual(0, (length(status()))),
    ?assertMatch({ok, _}, (add_inbound())),
    ?assertEqual(1, (length(status()))),
    error_logger:tty(true).

%% Copied from riak_test's rt.erl:
wait_until(Fun, Retry, Delay) when Retry > 0 ->
    Res = Fun(),
    case Res of
        true -> ok;
        _ when Retry == 1 -> {fail, Res};
        _ ->
            timer:sleep(Delay),
            wait_until(Fun, Retry - 1, Delay)
    end.

-endif.
