%%
%% Copyright (c) 2007-2010 Basho Technologies, Inc.  All Rights Reserved.
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
-module(riak_core_vnode).

-behaviour(gen_fsm_compat).

-include("riak_core_vnode.hrl").

-export([start_link/3,
         start_link/4,
         wait_for_init/1,
         send_command/2,
         send_command_after/2]).

-export([init/1,
         started/2,
         started/3,
         active/2,
         active/3,
         handle_event/3,
         handle_sync_event/4,
         handle_info/3,
         terminate/3,
         code_change/4]).

-export([reply/2]).

-export([get_mod_index/1,
         get_modstate/1,
         set_forwarding/2,
         trigger_handoff/2,
         trigger_handoff/3,
         trigger_delete/1,
         core_status/1,
         handoff_error/3]).

-export([cast_finish_handoff/1,
         send_an_event/2,
         send_req/2,
         send_all_proxy_req/2,
         cancel_handoff/1,
         handoff_complete/1,
         resize_transfer_complete/2,
         handoff_data/3,
         unregistered/1]).

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

-export([test_link/2, current_state/1]).

-endif.

-ifdef(PULSE).

-compile(export_all).

-compile({parse_transform, pulse_instrument}).

-compile({pulse_replace_module,
          [{gen_fsm_compat, pulse_gen_fsm},
           {gen_server, pulse_gen_server}]}).

-endif.

-define(NORMAL_REASON(R),
        R == normal orelse
            R == shutdown orelse
                is_tuple(R) andalso element(1, R) == shutdown).

-export_type([vnode_opt/0, pool_opt/0]).

-type vnode_opt() :: pool_opt().

-type pool_opt() :: {pool, WorkerModule :: module(),
                     PoolSize :: pos_integer(), WorkerArgs :: [term()]}.

-callback init([partition()]) -> {ok,
                                  ModState :: term()} |
                                 {ok, ModState :: term(), [vnode_opt()]} |
                                 {error, Reason :: term()}.

-callback handle_command(Request :: term(),
                         Sender :: sender(), ModState :: term()) -> continue |
                                                                    {reply,
                                                                     Reply ::
                                                                         term(),
                                                                     NewModState ::
                                                                         term()} |
                                                                    {noreply,
                                                                     NewModState ::
                                                                         term()} |
                                                                    {async,
                                                                     Work ::
                                                                         function(),
                                                                     From ::
                                                                         sender(),
                                                                     NewModState ::
                                                                         term()} |
                                                                    {stop,
                                                                     Reason ::
                                                                         term(),
                                                                     NewModState ::
                                                                         term()}.

-callback handle_coverage(Request :: term(),
                          keyspaces(), Sender :: sender(),
                          ModState :: term()) -> continue |
                                                 {reply, Reply :: term(),
                                                  NewModState :: term()} |
                                                 {noreply,
                                                  NewModState :: term()} |
                                                 {async, Work :: function(),
                                                  From :: sender(),
                                                  NewModState :: term()} |
                                                 {stop, Reason :: term(),
                                                  NewModState :: term()}.

-callback handle_exit(pid(), Reason :: term(),
                      ModState :: term()) -> {noreply,
                                              NewModState :: term()} |
                                             {stop, Reason :: term(),
                                              NewModState :: term()}.

-callback handoff_starting(handoff_dest(),
                           ModState :: term()) -> {boolean(),
                                                   NewModState :: term()}.

-callback handoff_cancelled(ModState :: term()) -> {ok,
                                                    NewModState :: term()}.

-callback handoff_finished(handoff_dest(),
                           ModState :: term()) -> {ok, NewModState :: term()}.

-callback handle_handoff_command(Request :: term(),
                                 Sender :: sender(),
                                 ModState :: term()) -> {reply, Reply :: term(),
                                                         NewModState ::
                                                             term()} |
                                                        {noreply,
                                                         NewModState ::
                                                             term()} |
                                                        {async,
                                                         Work :: function(),
                                                         From :: sender(),
                                                         NewModState ::
                                                             term()} |
                                                        {forward,
                                                         NewModState ::
                                                             term()} |
                                                        {drop,
                                                         NewModState ::
                                                             term()} |
                                                        {stop, Reason :: term(),
                                                         NewModState :: term()}.

-callback handle_handoff_data(binary(),
                              ModState :: term()) -> {reply,
                                                      ok |
                                                      {error, Reason :: term()},
                                                      NewModState :: term()}.

-callback encode_handoff_item(Key :: term(),
                              Value :: term()) -> corrupted | binary().

-callback is_empty(ModState :: term()) -> {boolean(),
                                           NewModState :: term()} |
                                          {false, Size :: pos_integer(),
                                           NewModState :: term()}.

-callback terminate(Reason :: term(),
                    ModState :: term()) -> ok.

-callback delete(ModState :: term()) -> {ok,
                                         NewModState :: term()}.

%% This commands are not executed inside the VNode, instead they are
%% part of the vnode_proxy contract.
%%
%% The vnode_proxy will drop requests in an overload situation, when
%% his happens one of the two handle_overload_* commands in the
%% vnode module is called. This call happens **from the vnode proxy**
%%
%% These calls are wrapped in a catch() meaning that when they don't
%% exist they will quietly fail. However the catch is hugely expensive
%% leading to the sitaution that when there already is a overload
%% the vnode proxy gets even worst overloaded.
%%
%% This is pretty bad since the proxy is supposed to protect against
%% exactly this overload.
%%
%% So yea sorry, you're going to be forced to implement them, if nothing
%% else just nop them out.
%%
%% BUT DO NOT call expensive functions from them there is a special hell
%% for people doing that! (it's called overflowing message queue hell and is
%% really nasty!)
-callback handle_overload_command(Request :: term(),
                                  Sender :: sender(), Idx :: partition()) -> ok.

-callback handle_overload_info(Request :: term(),
                               Idx :: partition()) -> ok.

%% handle_exit/3 is an optional behaviour callback that can be implemented.
%% It will be called in the case that a process that is linked to the vnode
%% process dies and allows the module using the behaviour to take appropriate
%% action. It is called by handle_info when it receives an {'EXIT', Pid, Reason}
%% message and the function signature is: handle_exit(Pid, Reason, State).
%%
%% It should return a tuple indicating the next state for the fsm. For a list of
%% valid return types see the documentation for the gen_fsm_compat handle_info callback.
%%
%% Here is what the spec for handle_exit/3 would look like:
%% -spec handle_exit(pid(), atom(), term()) ->
%%                          {noreply, term()} |
%%                          {stop, term(), term()}

%% handle_info/2 is an optional behaviour callback too.
%% It will be called in the case when a vnode receives any other message
%% than an EXIT message.
%% The function signature is: handle_info(Info, State).
%% It should return a tuple of the form {ok, NextState}
%%
%% Here is what the spec for handle_info/2 would look like:
%% -spec handle_info(term(), term()) -> {ok, term()}

-define(DEFAULT_TIMEOUT, 60000).

-define(LOCK_RETRY_TIMEOUT, 10000).

%% ========
%% API
%% ========

start_link(Mod, Index, Forward) ->
    start_link(Mod, Index, 0, Forward).

start_link(Mod, Index, InitialInactivityTimeout,
           Forward) ->
    gen_fsm_compat:start_link(?MODULE,
                              [Mod, Index, InitialInactivityTimeout, Forward],
                              []).

%% =========================
%% sync_send_event
%% =========================

%% #1 - State started
wait_for_init(Vnode) ->
    gen_fsm_compat:sync_send_event(Vnode,
                                   wait_for_init,
                                   infinity).

%% =========================
%% send_event
%% =========================

%% #2.1 -
%% Send a command message for the vnode module by Pid -
%% typically to do some deferred processing after returning yourself
send_command(Pid, Request) ->
    gen_fsm_compat:send_event(Pid,
                              #riak_vnode_req_v1{request = Request}).

%% #2.2 -
handoff_error(Vnode, Err, Reason) ->
    gen_fsm_compat:send_event(Vnode,
                              {handoff_error, Err, Reason}).

%% #2.3 - riak_core_vnode_master - send_an_event
send_an_event(VNode, Event) ->
    gen_fsm_compat:send_event(VNode, Event).

%% #2.4 - riak_core_vnode_master - handle_cast/handle_call
%riak_core_vnode_master - command2
%riak_core_vnode_proxy - handle_call
send_req(VNode, Req) ->
    gen_fsm_compat:send_event(VNode, Req).

%% #2.5 - riak:core_handoff_sender - start_fold_
-spec handoff_complete(VNode :: pid()) -> ok.

handoff_complete(VNode) ->
    gen_fsm_compat:send_event(VNode, handoff_complete).

%% #2.6 - riak:core_handoff_sender - start_fold_
-spec resize_transfer_complete(VNode :: pid(),
                               NotSentAcc :: term()) -> ok.

resize_transfer_complete(VNode, NotSentAcc) ->
    gen_fsm_compat:send_event(VNode,
                              {resize_transfer_complete, NotSentAcc}).

%% #2.7 - riak_core_vnode_proxy - handle_cast
unregistered(VNode) ->
    gen_fsm_compat:send_event(VNode, unregistered).

%% =========================
%% sync_send_all_state_event
%% =========================

%% #3.1
get_mod_index(VNode) ->
    gen_fsm_compat:sync_send_all_state_event(VNode,
                                             get_mod_index).

%% #3.2
core_status(VNode) ->
    gen_fsm_compat:sync_send_all_state_event(VNode,
                                             core_status).

%% #3.3 - riak_core_handoff_receiver - process_message
handoff_data(VNode, MsgData, VNodeTimeout) ->
    gen_fsm_compat:sync_send_all_state_event(VNode,
                                             {handoff_data, MsgData},
                                             VNodeTimeout).

%% =========================
%% send_all_state_event
%% =========================

%% #4.1
set_forwarding(VNode, ForwardTo) ->
    gen_fsm_compat:send_all_state_event(VNode,
                                        {set_forwarding, ForwardTo}).

%% #4.2
trigger_handoff(VNode, TargetIdx, TargetNode) ->
    gen_fsm_compat:send_all_state_event(VNode,
                                        {trigger_handoff,
                                         TargetIdx,
                                         TargetNode}).

%% #4.3
trigger_handoff(VNode, TargetNode) ->
    gen_fsm_compat:send_all_state_event(VNode,
                                        {trigger_handoff, TargetNode}).

%% #4.4
trigger_delete(VNode) ->
    gen_fsm_compat:send_all_state_event(VNode,
                                        trigger_delete).

%% #4.5 - riak_core_vnode_manager - handle_vnode_event
cast_finish_handoff(VNode) ->
    gen_fsm_compat:send_all_state_event(VNode,
                                        finish_handoff).

%% #4.6 - riak_core_vnode_manager - handle_vnode_event
cancel_handoff(VNode) ->
    gen_fsm_compat:send_all_state_event(VNode,
                                        cancel_handoff).

%% #4.7 - riak_core_vnode_master - handle_call
send_all_proxy_req(VNode, Req) ->
    gen_fsm_compat:send_all_state_event(VNode, Req).

%% =========================
%% send_event_after
%% =========================

%% #5
%% Sends a command to the FSM that called it after Time
%% has passed.
-spec send_command_after(integer(),
                         term()) -> reference().

send_command_after(Time, Request) ->
    gen_fsm_compat:send_event_after(Time,
                                    #riak_vnode_req_v1{request = Request}).

%% @doc Send a reply to a vnode request.  If
%%      the Ref is undefined just send the reply
%%      for compatibility with pre-0.12 requestors.
%%      If Ref is defined, send it along with the
%%      reply.
%%      NOTE: We *always* send the reply using unreliable delivery.
%%
-spec reply(sender(), term()) -> any().

reply({fsm, ignore_ref, From}, Reply) ->
    riak_core_send_msg:send_event_unreliable(From, Reply);
reply({fsm, Ref, From}, Reply) ->
    riak_core_send_msg:send_event_unreliable(From,
                                             {Ref, Reply});
reply({server, ignore_ref, From}, Reply) ->
    riak_core_send_msg:reply_unreliable(From, Reply);
reply({server, Ref, From}, Reply) ->
    riak_core_send_msg:reply_unreliable(From, {Ref, Reply});
reply(ignore, _Reply) -> ok.

%% ========================
%% ========
%% State, Mode, Init, Terminate
%% ========
%% ========================
-record(state,
        {index :: partition(),
         mod :: module(),
         modstate :: term(),
         forward :: node() | [{integer(), node()}],
         handoff_target = none :: none | {integer(), node()},
         handoff_pid :: pid() | undefined,
         handoff_type ::
             riak_core_handoff_manager:ho_type() | undefined,
         pool_pid :: pid() | undefined,
         pool_config :: tuple() | undefined,
         manager_event_timer :: reference() | undefined,
         inactivity_timeout :: non_neg_integer()}).

init([Module,
      Index,
      InitialInactivityTimeout,
      Forward]) ->
    process_flag(trap_exit, true),
    State = #state{index = Index, mod = Module,
                   forward = Forward,
                   inactivity_timeout = InitialInactivityTimeout},
    {ok, started, State, 0}.

terminate(Reason, _StateName,
          #state{mod = Module, modstate = ModState,
                 pool_pid = Pool}) ->
    %% Shutdown if the pool is still alive and a normal `Reason' is
    %% given - there could be a race on delivery of the unregistered
    %% event and successfully shutting down the pool.
    try case is_pid(Pool) andalso
                 is_process_alive(Pool) andalso (?NORMAL_REASON(Reason))
            of
            true ->
                riak_core_vnode_worker_pool:shutdown_pool(Pool, 60000);
            _ -> ok
        end
    catch
        Type:Reason:Stacktrace ->
            logger:error("Error while shutting down vnode worker "
                         "pool ~p:~p trace : ~p",
                         [Type, Reason, Stacktrace])
    after
        case ModState of
            %% Handoff completed, Module:delete has been called, now terminate.
            {deleted, ModState1} ->
                Module:terminate(Reason, ModState1);
            _ -> Module:terminate(Reason, ModState)
        end
    end.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%% ========================
%% ========
%% States
%% ========
%% ========================

%% started
%% ========
started(timeout,
        State = #state{inactivity_timeout =
                           InitialInactivityTimeout}) ->
    case do_init(State) of
        {ok, State2} ->
            {next_state, active, State2, InitialInactivityTimeout};
        {error, Reason} -> {stop, Reason}
    end.

started(wait_for_init, _From,
        State = #state{inactivity_timeout =
                           InitialInactivityTimeout}) ->
    case do_init(State) of
        {ok, State2} ->
            {reply, ok, active, State2, InitialInactivityTimeout};
        {error, Reason} -> {stop, Reason}
    end.

%%active
%%%%%%%%%%%%
active(timeout,
       State = #state{mod = Module, index = Idx}) ->
    riak_core_vnode_manager:vnode_event(Module,
                                        Idx,
                                        self(),
                                        inactive),
    continue(State);
active(#riak_coverage_req_v1{keyspaces = KeySpaces,
                             request = Request, sender = Sender},
       State) ->
    %% Coverage request handled in handoff and non-handoff.  Will be forwarded if set.
    vnode_coverage(Sender, Request, KeySpaces, State);
active(#riak_vnode_req_v1{sender = Sender,
                          request = {resize_forward, Request}},
       State) ->
    vnode_command(Sender, Request, State);
active(#riak_vnode_req_v1{sender = Sender,
                          request = Request},
       State = #state{handoff_target = HT})
    when HT =:= none ->
    forward_or_vnode_command(Sender, Request, State);
active(#riak_vnode_req_v1{sender = Sender,
                          request = Request},
       State = #state{handoff_type = resize,
                      handoff_target = {HOIdx, HONode}, index = Index,
                      forward = Forward, mod = Module}) ->
    RequestHash = Module:request_hash(Request),
    case RequestHash of
        %% will never have enough information to forward request so only handle locally
        undefined -> vnode_command(Sender, Request, State);
        _ ->
            {ok, R} = riak_core_ring_manager:get_my_ring(),
            FutureIndex = riak_core_ring:future_index(RequestHash,
                                                      Index,
                                                      R),
            case FutureIndex of
                %% request for portion of keyspace currently being transferred
                HOIdx ->
                    vnode_handoff_command(Sender,
                                          Request,
                                          {HOIdx, HONode},
                                          State);
                %% some portions of keyspace already transferred
                _Other when is_list(Forward) ->
                    vnode_resize_command(Sender,
                                         Request,
                                         FutureIndex,
                                         State);
                %% some portions of keyspace not already transferred
                _Other -> vnode_command(Sender, Request, State)
            end
    end;
active(#riak_vnode_req_v1{sender = Sender,
                          request = Request},
       State) ->
    vnode_handoff_command(Sender,
                          Request,
                          State#state.handoff_target,
                          State);
active(handoff_complete, State) ->
    State2 = start_manager_event_timer(handoff_complete,
                                       State),
    continue(State2);
active({resize_transfer_complete, SeenIdxs},
       State = #state{mod = Module, modstate = ModState,
                      handoff_target = Target}) ->
    case Target of
        none -> continue(State);
        _ ->
            %% TODO: refactor similarties w/ finish_handoff handle_event
            {ok, NewModState} = Module:handoff_finished(Target,
                                                        ModState),
            finish_handoff(SeenIdxs,
                           State#state{modstate = NewModState})
    end;
active({handoff_error, _Err, _Reason}, State) ->
    State2 = start_manager_event_timer(handoff_error,
                                       State),
    continue(State2);
active({send_manager_event, Event}, State) ->
    State2 = start_manager_event_timer(Event, State),
    continue(State2);
active({trigger_handoff, TargetNode}, State) ->
    active({trigger_handoff, State#state.index, TargetNode},
           State);
active({trigger_handoff, TargetIdx, TargetNode},
       State) ->
    maybe_handoff(TargetIdx, TargetNode, State);
active(trigger_delete,
       State = #state{mod = Module, modstate = ModState,
                      index = Idx}) ->
    case mark_delete_complete(Idx, Module) of
        {ok, _NewRing} ->
            {ok, NewModState} = Module:delete(ModState),
            logger:debug("~p ~p vnode deleted", [Idx, Module]);
        _ -> NewModState = ModState
    end,
    maybe_shutdown_pool(State),
    riak_core_vnode_manager:unregister_vnode(Idx, Module),
    continue(State#state{modstate =
                             {deleted, NewModState}});
active(unregistered,
       State = #state{mod = Module, index = Index}) ->
    %% Add exclusion so the ring handler will not try to spin this vnode
    %% up until it receives traffic.
    riak_core_handoff_manager:add_exclusion(Module, Index),
    logger:debug("~p ~p vnode excluded and unregistered.",
                 [Index, Module]),
    {stop,
     normal,
     State#state{handoff_target = none,
                 handoff_type = undefined, pool_pid = undefined}}.

active(_Event, _From, State) ->
    Reply = ok,
    {reply,
     Reply,
     active,
     State,
     State#state.inactivity_timeout}.

%% handle_event
%%%%%%%%%%%%%%%%

handle_event({set_forwarding, undefined}, _StateName,
             State = #state{modstate = {deleted, _ModState}}) ->
    %% The vnode must forward requests when in the deleted state, therefore
    %% ignore requests to stop forwarding.
    continue(State);
handle_event({set_forwarding, ForwardTo}, _StateName,
             State) ->
    logger:debug("vnode fwd :: ~p/~p :: ~p -> ~p~n",
                 [State#state.mod,
                  State#state.index,
                  State#state.forward,
                  ForwardTo]),
    State2 = mod_set_forwarding(ForwardTo, State),
    continue(State2#state{forward = ForwardTo});
handle_event(finish_handoff, _StateName,
             State = #state{modstate = {deleted, _ModState}}) ->
    stop_manager_event_timer(State),
    continue(State#state{handoff_target = none});
handle_event(finish_handoff, _StateName,
             State = #state{mod = Module, modstate = ModState,
                            handoff_target = Target}) ->
    stop_manager_event_timer(State),
    case Target of
        none -> continue(State);
        _ ->
            {ok, NewModState} = Module:handoff_finished(Target,
                                                        ModState),
            finish_handoff(State#state{modstate = NewModState})
    end;
handle_event(cancel_handoff, _StateName,
             State = #state{mod = Module, modstate = ModState}) ->
    %% it would be nice to pass {Err, Reason} to the vnode but the
    %% API doesn't currently allow for that.
    stop_manager_event_timer(State),
    case State#state.handoff_target of
        none -> continue(State);
        _ ->
            {ok, NewModState} = Module:handoff_cancelled(ModState),
            continue(State#state{handoff_target = none,
                                 handoff_type = undefined,
                                 modstate = NewModState})
    end;
handle_event({trigger_handoff, TargetNode}, StateName,
             State) ->
    handle_event({trigger_handoff,
                  State#state.index,
                  TargetNode},
                 StateName,
                 State);
handle_event({trigger_handoff, _TargetIdx, _TargetNode},
             _StateName,
             State = #state{modstate = {deleted, _ModState}}) ->
    continue(State);
handle_event(R = {trigger_handoff,
                  _TargetIdx,
                  _TargetNode},
             _StateName, State) ->
    active(R, State);
handle_event(trigger_delete, _StateName,
             State = #state{modstate = {deleted, _}}) ->
    continue(State);
handle_event(trigger_delete, _StateName, State) ->
    active(trigger_delete, State);
handle_event(R = #riak_vnode_req_v1{}, _StateName,
             State) ->
    active(R, State);
handle_event(R = #riak_coverage_req_v1{}, _StateName,
             State) ->
    active(R, State).

%%handle_sync_event
%%%%%%%%%%%%%%%%%%%%

handle_sync_event(current_state, _From, StateName,
                  State) ->
    {reply, {StateName, State}, StateName, State};
handle_sync_event(get_mod_index, _From, StateName,
                  State = #state{index = Idx, mod = Mod}) ->
    {reply,
     {Mod, Idx},
     StateName,
     State,
     State#state.inactivity_timeout};
handle_sync_event({handoff_data, _BinObj}, _From,
                  StateName,
                  State = #state{modstate = {deleted, _ModState}}) ->
    {reply,
     {error, vnode_exiting},
     StateName,
     State,
     State#state.inactivity_timeout};
handle_sync_event({handoff_data, BinObj}, _From,
                  StateName,
                  State = #state{mod = Module, modstate = ModState}) ->
    case Module:handle_handoff_data(BinObj, ModState) of
        {reply, ok, NewModState} ->
            {reply,
             ok,
             StateName,
             State#state{modstate = NewModState},
             State#state.inactivity_timeout};
        {reply, {error, Err}, NewModState} ->
            logger:error("~p failed to store handoff obj: ~p",
                         [Module, Err]),
            {reply,
             {error, Err},
             StateName,
             State#state{modstate = NewModState},
             State#state.inactivity_timeout}
    end;
handle_sync_event(core_status, _From, StateName,
                  State = #state{index = Index, mod = Module,
                                 modstate = ModState, handoff_target = HT,
                                 forward = FN}) ->
    Mode = case {FN, HT} of
               {undefined, none} -> active;
               {undefined, HT} -> handoff;
               {FN, none} -> forward;
               _ -> undefined
           end,
    Status = [{index, Index}, {mod, Module}] ++
                 case FN of
                     undefined -> [];
                     _ -> [{forward, FN}]
                 end
                     ++
                     case HT of
                         none -> [];
                         _ -> [{handoff_target, HT}]
                     end
                         ++
                         case ModState of
                             {deleted, _} -> [deleted];
                             _ -> []
                         end,
    {reply,
     {Mode, Status},
     StateName,
     State,
     State#state.inactivity_timeout}.

%%handle_info
%%%%%%%%%%%%%%

handle_info({'$vnode_proxy_ping', From, Ref, Msgs},
            StateName, State) ->
    riak_core_vnode_proxy:cast(From,
                               {vnode_proxy_pong, Ref, Msgs}),
    {next_state,
     StateName,
     State,
     State#state.inactivity_timeout};
handle_info({'EXIT', Pid, Reason}, _StateName,
            State = #state{mod = Module, index = Index,
                           pool_pid = Pid, pool_config = PoolConfig}) ->
    case Reason of
        Reason when Reason == normal; Reason == shutdown ->
            continue(State#state{pool_pid = undefined});
        _ ->
            logger:error("~p ~p worker pool crashed ~p\n",
                         [Index, Module, Reason]),
            {pool, WorkerModule, PoolSize, WorkerArgs} = PoolConfig,
            logger:debug("starting worker pool ~p with size of "
                         "~p for vnode ~p.",
                         [WorkerModule, PoolSize, Index]),
            {ok, NewPoolPid} =
                riak_core_vnode_worker_pool:start_link(WorkerModule,
                                                       PoolSize,
                                                       Index,
                                                       WorkerArgs,
                                                       worker_props),
            continue(State#state{pool_pid = NewPoolPid})
    end;
handle_info({'DOWN', _Ref, process, _Pid, normal},
            _StateName, State = #state{modstate = {deleted, _}}) ->
    %% these messages are produced by riak_kv_vnode's aae tree
    %% monitors; they are harmless, so don't yell about them. also
    %% only dustbin them in the deleted modstate, because pipe vnodes
    %% need them in other states
    continue(State);
handle_info(Info, _StateName,
            State = #state{mod = Module, modstate = {deleted, _},
                           index = Index}) ->
    logger:info("~p ~p ignored handle_info ~p - vnode "
                "unregistering\n",
                [Index, Module, Info]),
    continue(State);
handle_info({'EXIT', Pid, Reason}, StateName,
            State = #state{mod = Module, modstate = ModState}) ->
    %% A linked processes has died so use the
    %% handle_exit callback to allow the vnode
    %% process to take appropriate action.
    %% If the function is not implemented default
    %% to crashing the process.
    try case Module:handle_exit(Pid, Reason, ModState) of
            {noreply, NewModState} ->
                {next_state,
                 StateName,
                 State#state{modstate = NewModState},
                 State#state.inactivity_timeout};
            {stop, Reason1, NewModState} ->
                {stop, Reason1, State#state{modstate = NewModState}}
        end
    catch
        _ErrorType:undef -> {stop, linked_process_crash, State}
    end;
handle_info(Info, StateName,
            State = #state{mod = Module, modstate = ModState}) ->
    case erlang:function_exported(Module, handle_info, 2) of
        true ->
            {ok, NewModState} = Module:handle_info(Info, ModState),
            {next_state,
             StateName,
             State#state{modstate = NewModState},
             State#state.inactivity_timeout};
        false ->
            {next_state,
             StateName,
             State,
             State#state.inactivity_timeout}
    end.

%% ========================
%% ========
%% Internal Helper Functions
%% ========
%% ========================
do_init(State = #state{index = Index, mod = Module,
                       forward = Forward}) ->
    {ModState, Props} = case Module:init([Index]) of
                            {ok, MS} -> {MS, []};
                            {ok, MS, P} -> {MS, P};
                            {error, R} -> {error, R}
                        end,
    case {ModState, Props} of
        {error, Reason} -> {error, Reason};
        _ ->
            PoolConfig = case lists:keyfind(pool, 1, Props) of
                             {pool, WorkerModule, PoolSize, WorkerArgs} =
                                 PoolCfg ->
                                 logger:debug("starting worker pool ~p with size of "
                                              "~p~n",
                                              [WorkerModule, PoolSize]),
                                 {ok, PoolPid} =
                                     riak_core_vnode_worker_pool:start_link(WorkerModule,
                                                                            PoolSize,
                                                                            Index,
                                                                            WorkerArgs,
                                                                            worker_props),
                                 PoolCfg;
                             _ -> PoolPid = undefined
                         end,
            riak_core_handoff_manager:remove_exclusion(Module,
                                                       Index),
            Timeout = application:get_env(riak_core,
                                          vnode_inactivity_timeout,
                                          ?DEFAULT_TIMEOUT),
            Timeout2 = Timeout + rand:uniform(Timeout),
            State2 = State#state{modstate = ModState,
                                 inactivity_timeout = Timeout2,
                                 pool_pid = PoolPid, pool_config = PoolConfig},
            logger:debug("vnode :: ~p/~p :: ~p~n",
                         [Module, Index, Forward]),
            State3 = mod_set_forwarding(Forward, State2),
            {ok, State3}
    end.

continue(State) ->
    {next_state,
     active,
     State,
     State#state.inactivity_timeout}.

continue(State, NewModState) ->
    continue(State#state{modstate = NewModState}).

%% Active vnodes operate in three states: normal, handoff, and forwarding.
%%
%% In the normal state, vnode commands are passed to handle_command. When
%% a handoff is triggered, handoff_target is set and the vnode
%% is said to be in the handoff state.
%%
%% In the handoff state, vnode commands are passed to handle_handoff_command.
%% However, a vnode may be blocked during handoff (and therefore not servicing
%% commands) if the handoff procedure is blocking (eg. in riak_kv when not
%% using async fold).
%%
%% After handoff, a vnode may move into forwarding state. The forwarding state
%% is a product of the new gossip/membership code and will not occur if the
%% node is running in legacy mode. The forwarding state represents the case
%% where the vnode has already handed its data off to the new owner, but the
%% new owner is not yet listed as the current owner in the ring. This may occur
%% because additional vnodes are still waiting to handoff their data to the
%% new owner, or simply because the ring has yet to converge on the new owner.
%% In the forwarding state, all vnode commands and coverage commands are
%% forwarded to the new owner for processing.
%%
%% The above becomes a bit more complicated when the vnode takes part in resizing
%% the ring, since several transfers with a single vnode as the source are necessary
%% to complete the operation. A vnode will remain in the handoff state, for, potentially,
%% more than one transfer and may be in the handoff state despite there being no active
%% transfers with this vnode as the source. During this time requests that can be forwarded
%% to a partition for which the transfer has already completed, are forwarded. All other
%% requests are passed to handle_handoff_command.
forward_or_vnode_command(Sender, Request,
                         State = #state{forward = Forward, mod = Module,
                                        index = Index}) ->
    Resizing = is_list(Forward),
    RequestHash = case Resizing of
                      true -> Module:request_hash(Request);
                      false -> undefined
                  end,
    case {Forward, RequestHash} of
        %% typical vnode operation, no forwarding set, handle request locally
        {undefined, _} -> vnode_command(Sender, Request, State);
        %% implicit forwarding after ownership transfer/hinted handoff
        {F, _} when not is_list(F) ->
            vnode_forward(implicit,
                          {Index, Forward},
                          Sender,
                          Request,
                          State),
            continue(State);
        %% during resize we can't forward a request w/o request hash, always handle locally
        {_, undefined} -> vnode_command(Sender, Request, State);
        %% possible forwarding during ring resizing
        {_, _} ->
            {ok, R} = riak_core_ring_manager:get_my_ring(),
            FutureIndex = riak_core_ring:future_index(RequestHash,
                                                      Index,
                                                      R),
            vnode_resize_command(Sender,
                                 Request,
                                 FutureIndex,
                                 State)
    end.

vnode_command(_Sender, _Request,
              State = #state{modstate = {deleted, _}}) ->
    continue(State);
vnode_command(Sender, Request,
              State = #state{mod = Module, modstate = ModState,
                             pool_pid = Pool}) ->
    case catch Module:handle_command(Request,
                                     Sender,
                                     ModState)
        of
        {'EXIT', ExitReason} ->
            reply(Sender, {vnode_error, ExitReason}),
            logger:error("~p command failed ~p",
                         [Module, ExitReason]),
            {stop, ExitReason, State#state{modstate = ModState}};
        continue -> continue(State, ModState);
        {reply, Reply, NewModState} ->
            reply(Sender, Reply),
            continue(State, NewModState);
        {noreply, NewModState} -> continue(State, NewModState);
        {async, Work, From, NewModState} ->
            %% dispatch some work to the vnode worker pool
            %% the result is sent back to 'From'
            riak_core_vnode_worker_pool:handle_work(Pool,
                                                    Work,
                                                    From),
            continue(State, NewModState);
        {stop, Reason, NewModState} ->
            {stop, Reason, State#state{modstate = NewModState}}
    end.

vnode_coverage(Sender, Request, KeySpaces,
               State = #state{index = Index, mod = Module,
                              modstate = ModState, pool_pid = Pool,
                              forward = Forward}) ->
    %% Check if we should forward
    case Forward of
        undefined ->
            Action = Module:handle_coverage(Request,
                                            KeySpaces,
                                            Sender,
                                            ModState);
        %% handle coverage requests locally during ring resize
        Forwards when is_list(Forwards) ->
            Action = Module:handle_coverage(Request,
                                            KeySpaces,
                                            Sender,
                                            ModState);
        NextOwner ->
            logger:debug("Forwarding coverage ~p -> ~p: ~p~n",
                         [node(), NextOwner, Index]),
            riak_core_vnode_master:coverage(Request,
                                            {Index, NextOwner},
                                            KeySpaces,
                                            Sender,
                                            riak_core_vnode_master:reg_name(Module)),
            Action = continue
    end,
    case Action of
        continue -> continue(State, ModState);
        {reply, Reply, NewModState} ->
            reply(Sender, Reply),
            continue(State, NewModState);
        {noreply, NewModState} -> continue(State, NewModState);
        {async, Work, From, NewModState} ->
            %% dispatch some work to the vnode worker pool
            %% the result is sent back to 'From'
            riak_core_vnode_worker_pool:handle_work(Pool,
                                                    Work,
                                                    From),
            continue(State, NewModState);
        {PoolName, _Work, _From, NewModState} ->
            logger:error("Worker pools not supported: ~p",
                         [PoolName]),
            {stop,
             not_supported,
             State#state{modstate = NewModState}};
        {stop, Reason, NewModState} ->
            {stop, Reason, State#state{modstate = NewModState}}
    end.

vnode_handoff_command(Sender, Request, ForwardTo,
                      State = #state{mod = Module, modstate = ModState,
                                     handoff_target = HOTarget,
                                     handoff_type = HOType, pool_pid = Pool}) ->
    case Module:handle_handoff_command(Request,
                                       Sender,
                                       ModState)
        of
        {reply, Reply, NewModState} ->
            reply(Sender, Reply),
            continue(State, NewModState);
        {noreply, NewModState} -> continue(State, NewModState);
        {async, Work, From, NewModState} ->
            %% dispatch some work to the vnode worker pool
            %% the result is sent back to 'From'
            riak_core_vnode_worker_pool:handle_work(Pool,
                                                    Work,
                                                    From),
            continue(State, NewModState);
        {forward, NewModState} ->
            forward_request(HOType,
                            Request,
                            HOTarget,
                            ForwardTo,
                            Sender,
                            State),
            continue(State, NewModState);
        {forward, NewReq, NewModState} ->
            forward_request(HOType,
                            NewReq,
                            HOTarget,
                            ForwardTo,
                            Sender,
                            State),
            continue(State, NewModState);
        {drop, NewModState} -> continue(State, NewModState);
        {stop, Reason, NewModState} ->
            {stop, Reason, State#state{modstate = NewModState}}
    end.

%% @private wrap the request for resize forwards, and use the resize
%% target.
forward_request(resize, Request, _HOTarget,
                ResizeTarget, Sender, State) ->
    %% resize op and transfer ongoing
    vnode_forward(resize,
                  ResizeTarget,
                  Sender,
                  {resize_forward, Request},
                  State);
forward_request(undefined, Request, _HOTarget,
                ResizeTarget, Sender, State) ->
    %% resize op ongoing, no resize transfer ongoing, arrive here
    %% via forward_or_vnode_command
    vnode_forward(resize,
                  ResizeTarget,
                  Sender,
                  {resize_forward, Request},
                  State);
forward_request(_, Request, HOTarget, _ResizeTarget,
                Sender, State) ->
    %% normal explicit forwarding during owhership transfer
    vnode_forward(explicit,
                  HOTarget,
                  Sender,
                  Request,
                  State).

vnode_forward(Type, ForwardTo, Sender, Request,
              State) ->
    logger:debug("Forwarding (~p) {~p,~p} -> ~p~n",
                 [Type, State#state.index, node(), ForwardTo]),
    riak_core_vnode_master:command_unreliable(ForwardTo,
                                              Request,
                                              Sender,
                                              riak_core_vnode_master:reg_name(State#state.mod)).

%% @doc during ring resizing if we have completed a transfer to the index that will
%% handle request in future ring we forward to it. Otherwise we delegate
%% to the local vnode like other requests during handoff
vnode_resize_command(Sender, Request, FutureIndex,
                     State = #state{forward = Forward})
    when is_list(Forward) ->
    case lists:keyfind(FutureIndex, 1, Forward) of
        false -> vnode_command(Sender, Request, State);
        {FutureIndex, FutureOwner} ->
            vnode_handoff_command(Sender,
                                  Request,
                                  {FutureIndex, FutureOwner},
                                  State)
    end.

%% This code lives in riak_core_vnode rather than riak_core_vnode_manager
%% because the ring_trans call is a synchronous call to the ring manager,
%% and it is better to block an individual vnode rather than the vnode
%% manager. Blocking the manager can impact all vnodes. This code is safe
%% to execute on multiple parallel vnodes because of the synchronization
%% afforded by having all ring changes go through the single ring manager.
mark_handoff_complete(SrcIdx, Target, SeenIdxs, Mod,
                      resize) ->
    Prev = node(),
    Source = {SrcIdx, Prev},
    TransFun = fun (Ring, _) ->
                       Owner = riak_core_ring:index_owner(Ring, SrcIdx),
                       Status = riak_core_ring:resize_transfer_status(Ring,
                                                                      Source,
                                                                      Target,
                                                                      Mod),
                       case {Owner, Status} of
                           {Prev, awaiting} ->
                               F = fun (SeenIdx, RingAcc) ->
                                           riak_core_ring:schedule_resize_transfer(RingAcc,
                                                                                   Source,
                                                                                   SeenIdx)
                                   end,
                               Ring2 = lists:foldl(F,
                                                   Ring,
                                                   ordsets:to_list(SeenIdxs)),
                               Ring3 =
                                   riak_core_ring:resize_transfer_complete(Ring2,
                                                                           Source,
                                                                           Target,
                                                                           Mod),
                               %% local ring optimization (see below)
                               {set_only, Ring3};
                           _ -> ignore
                       end
               end,
    Result = riak_core_ring_manager:ring_trans(TransFun,
                                               []),
    case Result of
        {ok, _NewRing} -> resize;
        _ -> continue
    end;
mark_handoff_complete(Idx, {Idx, New}, [], Mod, _) ->
    Prev = node(),
    Result = riak_core_ring_manager:ring_trans(fun (Ring,
                                                    _) ->
                                                       Owner =
                                                           riak_core_ring:index_owner(Ring,
                                                                                      Idx),
                                                       {_, NextOwner, Status} =
                                                           riak_core_ring:next_owner(Ring,
                                                                                     Idx,
                                                                                     Mod),
                                                       NewStatus =
                                                           riak_core_ring:member_status(Ring,
                                                                                        New),
                                                       case {Owner,
                                                             NextOwner,
                                                             NewStatus,
                                                             Status}
                                                           of
                                                           {Prev,
                                                            New,
                                                            _,
                                                            awaiting} ->
                                                               Ring2 =
                                                                   riak_core_ring:handoff_complete(Ring,
                                                                                                   Idx,
                                                                                                   Mod),
                                                               %% Optimization. Only alter the local ring without
                                                               %% triggering a gossip, thus implicitly coalescing
                                                               %% multiple vnode handoff completion events. In the
                                                               %% future we should decouple vnode handoff state from
                                                               %% the ring structure in order to make gossip independent
                                                               %% of ring size.
                                                               {set_only,
                                                                Ring2};
                                                           _ -> ignore
                                                       end
                                               end,
                                               []),
    case Result of
        {ok, NewRing} -> NewRing = NewRing;
        _ ->
            {ok, NewRing} = riak_core_ring_manager:get_my_ring()
    end,
    Owner = riak_core_ring:index_owner(NewRing, Idx),
    {_, NextOwner, Status} =
        riak_core_ring:next_owner(NewRing, Idx, Mod),
    NewStatus = riak_core_ring:member_status(NewRing, New),
    case {Owner, NextOwner, NewStatus, Status} of
        {_, _, invalid, _} ->
            %% Handing off to invalid node, don't give-up data.
            continue;
        {Prev, New, _, _} -> forward;
        {Prev, _, _, _} ->
            %% Handoff wasn't to node that is scheduled in next, so no change.
            continue;
        {_, _, _, _} -> shutdown
    end.

finish_handoff(State) -> finish_handoff([], State).

finish_handoff(SeenIdxs,
               State = #state{mod = Module, modstate = ModState,
                              index = Idx, handoff_target = Target,
                              handoff_type = HOType}) ->
    case mark_handoff_complete(Idx,
                               Target,
                               SeenIdxs,
                               Module,
                               HOType)
        of
        continue ->
            continue(State#state{handoff_target = none,
                                 handoff_type = undefined});
        resize ->
            CurrentForwarding = resize_forwarding(State),
            NewForwarding = [Target | CurrentForwarding],
            State2 = mod_set_forwarding(NewForwarding, State),
            continue(State2#state{handoff_target = none,
                                  handoff_type = undefined,
                                  forward = NewForwarding});
        Res when Res == forward; Res == shutdown ->
            {_, HN} = Target,
            %% Have to issue the delete now.  Once unregistered the
            %% vnode master will spin up a new vnode on demand.
            %% Shutdown the async pool beforehand, don't want callbacks
            %% running on non-existant data.
            maybe_shutdown_pool(State),
            {ok, NewModState} = Module:delete(ModState),
            logger:debug("~p ~p vnode finished handoff and deleted.",
                         [Idx, Module]),
            riak_core_vnode_manager:unregister_vnode(Idx, Module),
            logger:debug("vnode hn/fwd :: ~p/~p :: ~p -> ~p~n",
                         [State#state.mod,
                          State#state.index,
                          State#state.forward,
                          HN]),
            State2 = mod_set_forwarding(HN, State),
            continue(State2#state{modstate =
                                      {deleted,
                                       NewModState}, % like to fail if used
                                  handoff_target = none,
                                  handoff_type = undefined, forward = HN})
    end.

maybe_shutdown_pool(#state{pool_pid = Pool}) ->
    case is_pid(Pool) of
        true ->
            %% state.pool_pid will be cleaned up by handle_info message.
            riak_core_vnode_worker_pool:shutdown_pool(Pool, 60000);
        _ -> ok
    end.

resize_forwarding(#state{forward = F})
    when is_list(F) ->
    F;
resize_forwarding(_) -> [].

mark_delete_complete(Idx, Mod) ->
    Result = riak_core_ring_manager:ring_trans(fun (Ring,
                                                    _) ->
                                                       Type =
                                                           riak_core_ring:vnode_type(Ring,
                                                                                     Idx),
                                                       {_, Next, Status} =
                                                           riak_core_ring:next_owner(Ring,
                                                                                     Idx),
                                                       case {Type, Next, Status}
                                                           of
                                                           {resized_primary,
                                                            '$delete',
                                                            awaiting} ->
                                                               Ring3 =
                                                                   riak_core_ring:deletion_complete(Ring,
                                                                                                    Idx,
                                                                                                    Mod),
                                                               %% Use local ring optimization like mark_handoff_complete
                                                               {set_only,
                                                                Ring3};
                                                           {{fallback, _},
                                                            '$delete',
                                                            awaiting} ->
                                                               Ring3 =
                                                                   riak_core_ring:deletion_complete(Ring,
                                                                                                    Idx,
                                                                                                    Mod),
                                                               %% Use local ring optimization like mark_handoff_complete
                                                               {set_only,
                                                                Ring3};
                                                           _ -> ignore
                                                       end
                                               end,
                                               []),
    Result.

maybe_handoff(_TargetIdx, _TargetNode,
              State = #state{modstate = {deleted, _}}) ->
    %% Modstate has been deleted, waiting for unregistered.  No handoff.
    continue(State);
maybe_handoff(TargetIdx, TargetNode,
              State = #state{index = Idx, mod = Module,
                             modstate = ModState,
                             handoff_target = CurrentTarget,
                             handoff_pid = HPid}) ->
    Target = {TargetIdx, TargetNode},
    ExistingHO = is_pid(HPid) andalso
                     is_process_alive(HPid),
    ValidHN = case CurrentTarget of
                  none -> true;
                  Target -> not ExistingHO;
                  _ ->
                      logger:info("~s/~b: handoff request to ~p before "
                                  "finishing handoff to ~p",
                                  [Module, Idx, Target, CurrentTarget]),
                      not ExistingHO
              end,
    case ValidHN of
        true ->
            {ok, R} = riak_core_ring_manager:get_my_ring(),
            Resizing = riak_core_ring:is_resizing(R),
            Primary = riak_core_ring:is_primary(R, {Idx, node()}),
            HOType = case {Resizing, Primary} of
                         {true, _} -> resize;
                         {_, true} -> ownership;
                         {_, false} -> hinted
                     end,
            case Module:handoff_starting({HOType, Target}, ModState)
                of
                {true, NewModState} ->
                    start_handoff(HOType,
                                  TargetIdx,
                                  TargetNode,
                                  State#state{modstate = NewModState});
                {false, NewModState} -> continue(State, NewModState)
            end;
        false -> continue(State)
    end.

start_handoff(HOType, TargetIdx, TargetNode,
              State = #state{mod = Module, modstate = ModState}) ->
    case Module:is_empty(ModState) of
        {true, NewModState} ->
            finish_handoff(State#state{modstate = NewModState,
                                       handoff_type = HOType,
                                       handoff_target =
                                           {TargetIdx, TargetNode}});
        {false, Size, NewModState} ->
            State2 = State#state{modstate = NewModState},
            NewState = start_outbound(HOType,
                                      TargetIdx,
                                      TargetNode,
                                      [{size, Size}],
                                      State2),
            continue(NewState);
        {false, NewModState} ->
            State2 = State#state{modstate = NewModState},
            NewState = start_outbound(HOType,
                                      TargetIdx,
                                      TargetNode,
                                      [],
                                      State2),
            continue(NewState)
    end.

start_outbound(HOType, TargetIdx, TargetNode, Opts,
               State = #state{index = Idx, mod = Module}) ->
    case riak_core_handoff_manager:add_outbound(HOType,
                                                Module,
                                                Idx,
                                                TargetIdx,
                                                TargetNode,
                                                self(),
                                                Opts)
        of
        {ok, Pid} ->
            State#state{handoff_pid = Pid, handoff_type = HOType,
                        handoff_target = {TargetIdx, TargetNode}};
        {error, _Reason} ->
            {ok, NewModState} =
                Module:handoff_cancelled(State#state.modstate),
            State#state{modstate = NewModState}
    end.

%% Individual vnode processes and the vnode manager are tightly coupled. When
%% vnode events occur, the vnode must ensure that the events are forwarded to
%% the vnode manager, which will make a state change decision and send an
%% appropriate message back to the vnode. To minimize blocking, asynchronous
%% messaging is used. It is possible for the vnode manager to crash and miss
%% messages sent by the vnode. Therefore, the vnode periodically resends event
%% messages until an appropriate message is received back from the vnode
%% manager. The event timer functions below implement this logic.
start_manager_event_timer(Event,
                          State = #state{mod = Module, index = Idx}) ->
    riak_core_vnode_manager:vnode_event(Module,
                                        Idx,
                                        self(),
                                        Event),
    stop_manager_event_timer(State),
    T2 = gen_fsm_compat:send_event_after(30000,
                                         {send_manager_event, Event}),
    State#state{manager_event_timer = T2}.

stop_manager_event_timer(#state{manager_event_timer =
                                    undefined}) ->
    ok;
stop_manager_event_timer(#state{manager_event_timer =
                                    T}) ->
    _ = gen_fsm_compat:cancel_timer(T),
    ok.

mod_set_forwarding(_Forward,
                   State = #state{modstate = {deleted, _}}) ->
    State;
mod_set_forwarding(Forward,
                   State = #state{mod = Module, modstate = ModState}) ->
    case lists:member({set_vnode_forwarding, 2},
                      Module:module_info(exports))
        of
        true ->
            NewModState = Module:set_vnode_forwarding(Forward,
                                                      ModState),
            State#state{modstate = NewModState};
        false -> State
    end.

%% ===================================================================
%% Test API
%% ===================================================================

-type state() :: #state{}.

%% @doc Reveal the underlying module state for testing
-spec get_modstate(pid()) -> {atom(), state()}.

get_modstate(Pid) ->
    {_StateName, State} =
        gen_fsm_compat:sync_send_all_state_event(Pid,
                                                 current_state),
    {State#state.mod, State#state.modstate}.

-ifdef(TEST).

%% Start the garbage collection server
test_link(Mod, Index) ->
    gen_fsm_compat:start_link(?MODULE,
                              [Mod, Index, 0, node()],
                              []).

%% Get the current state of the fsm for testing inspection
-spec current_state(pid()) -> {atom(), state()} |
                              {error, term()}.

current_state(Pid) ->
    gen_fsm_compat:sync_send_all_state_event(Pid,
                                             current_state).

wait_for_process_death(Pid) ->
    wait_for_process_death(Pid, is_process_alive(Pid)).

wait_for_process_death(Pid, true) ->
    wait_for_process_death(Pid, is_process_alive(Pid));
wait_for_process_death(_Pid, false) -> ok.

wait_for_state_update(OriginalStateData, Pid) ->
    {_, CurrentStateData} = (?MODULE):current_state(Pid),
    wait_for_state_update(OriginalStateData,
                          CurrentStateData,
                          Pid).

wait_for_state_update(OriginalStateData,
                      OriginalStateData, Pid) ->
    {_, CurrentStateData} = (?MODULE):current_state(Pid),
    wait_for_state_update(OriginalStateData,
                          CurrentStateData,
                          Pid);
wait_for_state_update(_OriginalState, _StateData,
                      _Pid) ->
    ok.

%% ===================================================================
%% Test
%% ===================================================================

pool_death_test() ->
    %% expect error log
    error_logger:tty(false),
    meck:unload(),
    meck:new(test_vnode, [non_strict, no_link]),
    meck:expect(test_vnode,
                init,
                fun (_) -> {ok, [], [{pool, test_pool_mod, 1, []}]}
                end),
    meck:expect(test_vnode,
                terminate,
                fun (_, _) -> normal end),
    meck:new(test_pool_mod, [non_strict, no_link]),
    meck:expect(test_pool_mod,
                init_worker,
                fun (_, _, _) -> {ok, []} end),
    {ok, Pid} = riak_core_vnode:test_link(test_vnode, 0),
    {_, StateData1} = riak_core_vnode:current_state(Pid),
    PoolPid1 = StateData1#state.pool_pid,
    exit(PoolPid1, kill),
    wait_for_process_death(PoolPid1),
    ?assertNot((is_process_alive(PoolPid1))),
    wait_for_state_update(StateData1, Pid),
    {_, StateData2} = riak_core_vnode:current_state(Pid),
    PoolPid2 = StateData2#state.pool_pid,
    ?assertNot((PoolPid2 =:= undefined)),
    exit(Pid, normal),
    wait_for_process_death(Pid),
    meck:validate(test_pool_mod),
    meck:validate(test_vnode),
    % TODO why is a short sleep needed to swallow crash message
    timer:sleep(10),
    error_logger:tty(true).

-endif.
