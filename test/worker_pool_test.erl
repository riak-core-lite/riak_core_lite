%% -------------------------------------------------------------------
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
-module(worker_pool_test).

-behaviour(riak_core_vnode_worker).

-export([init_worker/3, handle_work/3]).

init_worker(_VnodeIndex, DoReply, _WorkerProps) ->
    {ok, DoReply}.

handle_work(Work, _From, false = DoReply) ->
    Work(),
    {noreply, DoReply};
handle_work(Work, _From, true = DoReply) ->
    Work(),
    {reply, ok, DoReply}.

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

receive_result(N) ->
    receive
        {N, ok} when N rem 2 /= 0 -> true;
        {N, {error, {worker_crash, _, _}}} when N rem 2 == 0 ->
            true
        after 0 -> timeout
    end.

deadlock_test() ->
    {ok, Pool} =
        riak_core_vnode_worker_pool:start_link(?MODULE,
                                               1,
                                               10,
                                               true,
                                               []),
    CoordinatorLoop = spawn_link(fun () ->
                                         Worker1 = receive
                                                       {worker_init, W} -> W
                                                   end,
                                         Root = receive
                                                    {wait_for_worker, W2} -> W2
                                                end,
                                         Root ! continue,
                                         Root = receive
                                                    {die_in_the_pool, W3} -> W3
                                                end,
                                         Worker1 ! continue,
                                         receive {ready_to_crash} -> ok end,
                                         % let the worker actually crash
                                         timer:sleep(50),
                                         Root ! continue,
                                         receive finish_test -> ok end,
                                         Root ! finish_test
                                 end),
    riak_core_vnode_worker_pool:handle_work(Pool,
                                            fun () ->
                                                    CoordinatorLoop !
                                                        {worker_init, self()},
                                                    receive continue -> ok end
                                            end,
                                            {server, 1, self()}),
    CoordinatorLoop ! {wait_for_worker, self()},
    receive continue -> ok end,
    riak_core_vnode_worker_pool:handle_work(Pool,
                                            fun () ->
                                                    CoordinatorLoop !
                                                        {ready_to_crash},
                                                    erlang:error(-1)
                                            end,
                                            {server, 1, self()}),
    % now we have to wait a bit
    % because handle_work is a cast and there is no way to check when it's in the queue
    timer:sleep(50),
    CoordinatorLoop ! {die_in_the_pool, self()},
    receive continue -> ok end,
    % this should not cause a deadlock
    riak_core_vnode_worker_pool:handle_work(Pool,
                                            fun () ->
                                                    CoordinatorLoop !
                                                        finish_test
                                            end,
                                            {server, 1, self()}),
    receive finish_test -> ok end,
    unlink(Pool),
    ok = riak_core_vnode_worker_pool:stop(Pool, normal),
    ok = wait_for_process_death(Pool).

simple_reply_worker_pool() ->
    {ok, Pool} =
        riak_core_vnode_worker_pool:start_link(?MODULE,
                                               3,
                                               10,
                                               true,
                                               []),
    [riak_core_vnode_worker_pool:handle_work(Pool,
                                             fun () ->
                                                     timer:sleep(10),
                                                     1 / (N rem 2)
                                             end,
                                             {server, N, self()})
     || N <- lists:seq(1, 10)],
    timer:sleep(200),
    %% make sure we got all replies
    [?assertEqual(true, (receive_result(N)))
     || N <- lists:seq(1, 10)],
    unlink(Pool),
    ok = riak_core_vnode_worker_pool:stop(Pool, normal),
    ok = wait_for_process_death(Pool).

simple_noreply_worker_pool() ->
    {ok, Pool} =
        riak_core_vnode_worker_pool:start_link(?MODULE,
                                               3,
                                               10,
                                               false,
                                               []),
    [riak_core_vnode_worker_pool:handle_work(Pool,
                                             fun () ->
                                                     timer:sleep(10),
                                                     1 / (N rem 2)
                                             end,
                                             {server, N, self()})
     || N <- lists:seq(1, 10)],
    timer:sleep(200),
    %% make sure that the non-crashing work calls receive timeouts
    [?assertEqual(timeout, (receive_result(N)))
     || N <- lists:seq(1, 10), N rem 2 == 1],
    [?assertEqual(true, (receive_result(N)))
     || N <- lists:seq(1, 10), N rem 2 == 0],
    unlink(Pool),
    ok = riak_core_vnode_worker_pool:stop(Pool, normal),
    ok = wait_for_process_death(Pool).

shutdown_pool_empty_success() ->
    {ok, Pool} =
        riak_core_vnode_worker_pool:start_link(?MODULE,
                                               3,
                                               10,
                                               false,
                                               []),
    unlink(Pool),
    ok = riak_core_vnode_worker_pool:shutdown_pool(Pool,
                                                   100),
    ok = wait_for_process_death(Pool),
    ok.

shutdown_pool_worker_finish_success() ->
    {ok, Pool} =
        riak_core_vnode_worker_pool:start_link(?MODULE,
                                               3,
                                               10,
                                               false,
                                               []),
    riak_core_vnode_worker_pool:handle_work(Pool,
                                            fun () -> timer:sleep(50) end,
                                            {server, 1, self()}),
    unlink(Pool),
    ok = riak_core_vnode_worker_pool:shutdown_pool(Pool,
                                                   100),
    ok = wait_for_process_death(Pool),
    ok.

shutdown_pool_force_timeout() ->
    {ok, Pool} =
        riak_core_vnode_worker_pool:start_link(?MODULE,
                                               3,
                                               10,
                                               false,
                                               []),
    riak_core_vnode_worker_pool:handle_work(Pool,
                                            fun () -> timer:sleep(100) end,
                                            {server, 1, self()}),
    unlink(Pool),
    {error, vnode_shutdown} =
        riak_core_vnode_worker_pool:shutdown_pool(Pool, 50),
    ok = wait_for_process_death(Pool),
    ok.

shutdown_pool_duplicate_calls() ->
    {ok, Pool} =
        riak_core_vnode_worker_pool:start_link(?MODULE,
                                               3,
                                               10,
                                               false,
                                               []),
    riak_core_vnode_worker_pool:handle_work(Pool,
                                            fun () -> timer:sleep(100) end,
                                            {server, 1, self()}),
    unlink(Pool),
    %% request shutdown a bit later a second time
    spawn_link(fun () ->
                       timer:sleep(30),
                       {error, vnode_shutdown} =
                           riak_core_vnode_worker_pool:shutdown_pool(Pool, 50)
               end),
    {error, vnode_shutdown} =
        riak_core_vnode_worker_pool:shutdown_pool(Pool, 50),
    ok = wait_for_process_death(Pool),
    ok.

pool_test_() ->
    {setup,
     fun () -> error_logger:tty(false) end,
     fun (_) -> error_logger:tty(true) end,
     [fun simple_reply_worker_pool/0,
      fun simple_noreply_worker_pool/0,
      fun shutdown_pool_empty_success/0,
      fun shutdown_pool_worker_finish_success/0,
      fun shutdown_pool_force_timeout/0,
      fun shutdown_pool_duplicate_calls/0,
      fun deadlock_test/0]}.

wait_for_process_death(Pid) ->
    wait_for_process_death(Pid, is_process_alive(Pid)).

wait_for_process_death(Pid, true) ->
    wait_for_process_death(Pid, is_process_alive(Pid));
wait_for_process_death(_Pid, false) -> ok.

-endif.
