%% -------------------------------------------------------------------
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
-module(riak_core_node_worker_pool_sup).
-behaviour(supervisor).
-include_lib("kernel/include/logger.hrl").
-export([start_link/0, init/1]).
-export([start_pool/5]).
-export([hard_reset_dscp_pool/5]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, PoolType, Args, Type, Timeout),
            {PoolType,
                {I, start_link, Args},
                permanent, Timeout, Type, [I]}).
-define(CHILD(I, PoolType, Args, Type),
            ?CHILD(I, PoolType, Args, Type, 5000)).

-type worker_pool() :: riak_core_node_worker_pool:worker_pool().

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {{one_for_one, 5, 10}, []}}.

%% @doc
%% Start a node_worker_pool - can be either assuredforwardng_pool or
%% a besteffort_pool (which will also be registered as a node_worker_pool for
%% backwards compatability)
-spec start_pool(atom(), pos_integer(), list(), list(), worker_pool()) ->
                        ok | {error, Reason::term()}.
start_pool(WorkerMod, PoolSize, WorkerArgs, WorkerProps, QueueType) ->
    Ref = pool(WorkerMod, PoolSize, WorkerArgs, WorkerProps, QueueType),
    case supervisor:start_child(?MODULE, Ref) of
        {ok, _} -> ok;
        {ok, _, _} -> ok;
        {error, already_present} -> ok;
        {error, {already_started, _}} -> ok;
        {error, OtherErr} -> {error, OtherErr}
    end.

pool(WorkerMod, PoolSize, WorkerArgs, WorkerProps, QueueType) ->
        ?CHILD(riak_core_node_worker_pool,
                QueueType,
                [WorkerMod, PoolSize, WorkerArgs, WorkerProps, QueueType],
                worker).


-define(DSCP_POOLS, [be_pool,af4_pool,af3_pool,af2_pool,af1_pool]).

% @doc
% A hard reset of a dscp pool is tested only on a cluster not running active
% queries.  All query runners should be killed as well the existing pool
% managers
% 
% A new set of pools will be started with the new worker counts.
% 
% This will exit if a dscp pool strategy is not in use, without forcing the
% hard reset.
-spec hard_reset_dscp_pool(
    pos_integer(),
    pos_integer(),
    pos_integer(),
    pos_integer(),
    pos_integer()
) -> 
    ok|{error, unexpected_state}.
hard_reset_dscp_pool(AF1, AF2, AF3, AF4, BE) ->
    {PoolList, PoolMap} =
        element(4, sys:get_state(riak_core_node_worker_pool_sup)),
    case lists:sort(PoolList) == lists:sort(?DSCP_POOLS) of
        true ->
            ?LOG_INFO(
                "Attempting hard reset of dscp node worker pool to sizes: "
                "AF1 ~w AF2 ~w AF3 ~w AF4 ~w BE ~w",
                [AF1, AF2, AF3, AF4, BE]
            ),
            ?LOG_WARNING(
                "Attempt to hard reset dscp pool will cancel will all running "
                "query contributions on this node"
            ),
            true =
                exit(
                    whereis(riak_core_node_worker_pool_sup),
                    kill
                ),
            lists:foreach(
                fun({PoolName, PoolSize}) ->
                    riak_core_node_worker_pool_sup:start_pool(
                        riak_kv_worker,
                        PoolSize,
                        [],
                        [],
                        PoolName
                    )
                end,
                [
                    {af1_pool, AF1},
                    {af2_pool, AF2},
                    {af3_pool, AF3},
                    {af4_pool, AF4},
                    {be_pool, BE}
                ]
            ),
            {_UpdlList, UpdPoolMap} =
                element(4, sys:get_state(riak_core_node_worker_pool_sup)),
            ?LOG_INFO("Pool update complete configuration ~0p", [UpdPoolMap]),
            ok;
        false ->
            ?LOG_ERROR("Pool state not expected for DSCP Pool ~0p", [PoolMap]),
            {error, unexpected_state}
    end.