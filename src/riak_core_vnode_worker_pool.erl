%%
%% Copyright (c) 2007-2011 Basho Technologies, Inc.  All Rights Reserved.
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

%% @doc This is a wrapper around a poolboy pool, that implements a
%% queue. That is, this process maintains a queue of work, and checks
%% workers out of a poolboy pool to consume it.
%%
%% The workers it uses send two messages to this process.
%%
%% The first message is at startup, the bare atom
%% `worker_started'. This is a clue to this process that a worker was
%% just added to the poolboy pool, so a checkout request has a chance
%% of succeeding. This is most useful after an old worker has exited -
%% `worker_started' is a trigger guaranteed to arrive at a time that
%% will mean an immediate poolboy:checkout will not beat the worker
%% into the pool.
%%
%% The second message is when the worker finishes work it has been
%% handed, the two-tuple, `{checkin, WorkerPid}'. This message gives
%% this process the choice of whether to give the worker more work or
%% check it back into poolboy's pool at this point. Note: the worker
%% should *never* call poolboy:checkin itself, because that will
%% confuse (or cause a race) with this module's checkout management.
-module(riak_core_vnode_worker_pool).

-behaviour(gen_statem).

%% API
-export([start_link/5, start_link/6, stop/2,
         shutdown_pool/2, handle_work/3, worker_started/1,
         checkin_worker/2]).

%% gen_statem callbacks
-export([init/1, terminate/3, code_change/4,
         callback_mode/0]).

%% gen_statem states
-export([ready/3, queue/3, shutdown/3]).

%% ========
%% API
%% ========

start_link(WorkerMod, PoolSize, VNodeIndex, WorkerArgs,
           WorkerProps) ->
    start_link(WorkerMod, PoolSize, VNodeIndex, WorkerArgs,
               WorkerProps, []).

start_link(WorkerMod, PoolSize, VNodeIndex, WorkerArgs,
           WorkerProps, Opts) ->
    gen_statem:start_link(?MODULE,
                          [WorkerMod, PoolSize, VNodeIndex, WorkerArgs,
                           WorkerProps, Opts],
                          []).

% #1 cast
handle_work(Pid, Work, From) ->
    gen_statem:cast(Pid, {work, Work, From}).

% #2 cast
worker_started(Pid) ->
    gen_statem:cast(Pid, worker_start).

% #3 cast
checkin_worker(Pid, WorkerPid) ->
    gen_statem:cast(Pid, {checkin, WorkerPid}).

% #4 call
stop(Pid, Reason) ->
    gen_statem:stop(Pid, Reason, infinity).

% #5 call
%% wait for all the workers to finish any current work
-spec shutdown_pool(pid(), integer()) -> ok |
                                         {error, vnode_shutdown}.

shutdown_pool(Pid, Wait) ->
    gen_statem:call(Pid, {shutdown, Wait}, infinity).

%% ========================
%% ========
%% State, Mode, Init, Terminate
%% ========
%% ========================

-record(state,
        {queue  :: queue:queue() | list(), pool  :: pid(),
         monitors = []  :: list(),
         queue_strategy = fifo  :: fifo | filo,
         shutdown  :: undefined | {pid(), reference()}}).

callback_mode() -> [state_functions, state_enter].

init([WorkerMod, PoolSize, VNodeIndex, WorkerArgs,
      WorkerProps, Opts]) ->
    {ok, Pid} = poolboy:start_link([{worker_module,
                                     riak_core_vnode_worker},
                                    {worker_args,
                                     [VNodeIndex, WorkerArgs, WorkerProps,
                                      self()]},
                                    {worker_callback_mod, WorkerMod},
                                    {size, PoolSize}, {max_overflow, 0}]),
    DefaultStrategy = application:get_env(riak_core,
                                          queue_worker_strategy, fifo),
    State = case proplists:get_value(strategy, Opts,
                                     DefaultStrategy)
                of
              fifo ->
                  #state{pool = Pid, queue = queue:new(),
                         queue_strategy = fifo};
              filo ->
                  #state{pool = Pid, queue = [], queue_strategy = filo}
            end,
    {ok, ready, State}.

% #4 call
terminate(_Reason, _StateName, #state{pool = Pool}) ->
    %% stop poolboy
    poolboy:stop(Pool),
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%% ========================
%% ========
%% States
%% ========
%% ========================

%% ready
%% ========

%% enter
ready(enter, _, State) -> {keep_state, State};
%% #1
ready(cast, {work, Work, From} = Msg,
      #state{pool = Pool, monitors = Monitors} = State) ->
    case poolboy:checkout(Pool, false) of
      full -> {next_state, queue, in(Msg, State)};
      Pid when is_pid(Pid) ->
          NewMonitors = monitor_worker(Pid, From, Work, Monitors),
          riak_core_vnode_worker:handle_work(Pid, Work, From),
          {next_state, ready, State#state{monitors = NewMonitors}}
    end;
%% #2
ready(cast, worker_start, State) ->
    worker_started(State, ready);
%% #3
ready(cast, {checkin, WorkerPid}, State) ->
    checkin(State, WorkerPid);
%% #5
ready({call, From}, {shutdown, Wait}, State) ->
    %% change to shutdown state with a state_timeout of 'Wait' ms, force after timeout expires
    {next_state, shutdown, State#state{shutdown = From},
     [{state_timeout, Wait, force_shutdown}]};
%% info EXIT signal of erlang:monitor(process, Worker)
ready(info, {'DOWN', _Ref, _Type, Pid, Info}, State) ->
    {ok, NewState} = exit_worker(State, Pid, Info),
    {keep_state, NewState}.

%% queueing
%% ========

%% enter
queue(enter, _, State) -> {keep_state, State};
queue(cast, {work, _Work, _From} = Msg, State) ->
    {next_state, queue, in(Msg, State)};
%% #2
queue(cast, worker_start, State) ->
    worker_started(State, queue);
%% #3
queue(cast, {checkin, WorkerPid}, State) ->
    checkin(State, WorkerPid);
%% #5
queue({call, From}, {shutdown, Wait}, State) ->
    %% change to shutdown state with a state_timeout of 'Wait' ms, force after timeout expires
    {next_state, shutdown, State#state{shutdown = From},
     [{state_timeout, Wait, force_shutdown}]};
%% info EXIT signal of erlang:monitor(process, Worker)
queue(info, {'DOWN', _Ref, _Type, Pid, Info}, State) ->
    {ok, NewState} = exit_worker(State, Pid, Info),
    {keep_state, NewState}.

%% shutdown
%% ========

%% enter
shutdown(enter, _,
         #state{monitors = Monitors, shutdown = From} = State) ->
    discard_queued_work(State),
    case Monitors of
      [] -> {stop_and_reply, shutdown, [{reply, From, ok}]};
      _ -> {keep_state, State#state{queue = new(State)}}
    end;
%% force shutdown timeout
shutdown(state_timeout, _,
         #state{monitors = Monitors, shutdown = FromOrigin}) ->
    %% we've waited too long to shutdown, time to force the issue.
    _ = [riak_core_vnode:reply(From,
                               {error, vnode_shutdown})
         || {_, _, From, _} <- Monitors],
    {stop_and_reply, shutdown,
     [{reply, FromOrigin, {error, vnode_shutdown}}]};
%% #1
shutdown(cast, {work, _Work, From}, State) ->
    riak_core_vnode:reply(From, {error, vnode_shutdown}),
    {keep_state, State};
%% #2
shutdown(cast, worker_start, State) ->
    worker_started(State, shutdown);
%% #3
shutdown(cast, {checkin, Pid},
         #state{pool = Pool, monitors = Monitors0,
                shutdown = From} =
             State) ->
    Monitors = demonitor_worker(Pid, Monitors0),
    poolboy:checkin(Pool, Pid),
    case Monitors of
      [] -> %% work all done, time to exit!
          {stop_and_reply, shutdown, [{reply, From, ok}]};
      _ -> {keep_state, State#state{monitors = Monitors}}
    end;
%% #5
shutdown({call, From}, {shutdown, _Wait}, State) ->
    %% duplicate shutdown call
    {keep_state, State,
     [{reply, From, {error, vnode_shutdown}}]};
%% info EXIT signal of erlang:monitor(process, Worker)
shutdown(info, {'DOWN', _Ref, _, Pid, Info}, State) ->
    {ok, NewState} = exit_worker(State, Pid, Info),
    {keep_state, NewState}.

%% ========================
%% ========
%% Internal Helper Functions
%% ========
%% ========================

%% Keep track of which worker we pair with what work/from and monitor the
%% worker. Only active workers are tracked
monitor_worker(Worker, From, Work, Monitors) ->
    case lists:keyfind(Worker, 1, Monitors) of
      {Worker, Ref, _OldFrom, _OldWork} ->
          %% reuse old monitor and just update the from & work
          lists:keyreplace(Worker, 1, Monitors,
                           {Worker, Ref, From, Work});
      false ->
          Ref = erlang:monitor(process, Worker),
          [{Worker, Ref, From, Work} | Monitors]
    end.

demonitor_worker(Worker, Monitors) ->
    case lists:keyfind(Worker, 1, Monitors) of
      {Worker, Ref, _From, _Work} ->
          erlang:demonitor(Ref),
          lists:keydelete(Worker, 1, Monitors);
      false ->
          %% not monitored?
          Monitors
    end.

discard_queued_work(State) ->
    case out(State) of
      {{value, {work, _Work, From}}, Rem} ->
          riak_core_vnode:reply(From, {error, vnode_shutdown}),
          discard_queued_work(State#state{queue = Rem});
      {empty, _Empty} -> ok
    end.

in(Msg,
   State = #state{queue_strategy = fifo, queue = Q}) ->
    State#state{queue = queue:in(Msg, Q)};
in(Msg,
   State = #state{queue_strategy = filo, queue = Q}) ->
    State#state{queue = [Msg | Q]}.

out(#state{queue_strategy = fifo, queue = Q}) ->
    queue:out(Q);
out(#state{queue_strategy = filo, queue = []}) ->
    {empty, []};
out(#state{queue_strategy = filo, queue = [Msg | Q]}) ->
    {{value, Msg}, Q}.

new(#state{queue_strategy = fifo}) -> queue:new();
new(#state{queue_strategy = filo}) -> [].

worker_started(#state{pool = Pool,
                      monitors = Monitors} =
                   State,
               StateName) ->
    %% a new worker just started - if we have work pending, try to do it
    case out(State) of
      {{value, {work, Work, From}}, Rem} ->
          case poolboy:checkout(Pool, false) of
            full -> {next_state, queue, State};
            Pid when is_pid(Pid) ->
                NewMonitors = monitor_worker(Pid, From, Work, Monitors),
                riak_core_vnode_worker:handle_work(Pid, Work, From),
                {next_state, queue,
                 State#state{queue = Rem, monitors = NewMonitors}}
          end;
      {empty, _} ->
          {next_state, 
	   %% If we are in state queueing with nothing in the queue,
	   %% move to the ready state so that the next incoming job
	   %% checks out the new worker from poolboy.
	   if StateName==queue -> ready; true -> StateName end, State}
    end.

checkin(#state{pool = Pool, monitors = Monitors} =
            State,
        Worker) ->
    case out(State) of
      {{value, {work, Work, From}}, Rem} ->
          %% there is outstanding work to do - instead of checking
          %% the worker back in, just hand it more work to do
          NewMonitors = monitor_worker(Worker, From, Work,
                                       Monitors),
          riak_core_vnode_worker:handle_work(Worker, Work, From),
          {next_state, queue,
           State#state{queue = Rem, monitors = NewMonitors}};
      {empty, Empty} ->
          NewMonitors = demonitor_worker(Worker, Monitors),
          poolboy:checkin(Pool, Worker),
          {next_state, ready,
           State#state{queue = Empty, monitors = NewMonitors}}
    end.

exit_worker(#state{monitors = Monitors} = State, Pid,
            Info) ->
    %% remove the listing for the dead worker
    case lists:keyfind(Pid, 1, Monitors) of
      {Pid, _, From, Work} ->
          riak_core_vnode:reply(From,
                                {error, {worker_crash, Info, Work}}),
          NewMonitors = lists:keydelete(Pid, 1, Monitors),
          %% trigger to do more work will be 'worker_start' message
          %% when poolboy replaces this worker (if not a 'checkin' or 'handle_work')
          {ok, State#state{monitors = NewMonitors}};
      false -> {ok, State}
    end.
