%% -------------------------------------------------------------------
%%
%% Copyright (c) 2012 Basho Technologies, Inc.  All Rights Reserved.
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

-module(riak_core_repair).
-export([gen_filter/5,
         gen_range/3,
         gen_range_map/3]).

-include("riak_core_handoff.hrl").

-type hash_range()
    :: 
        {lt, non_neg_integer()} |
        {gte, non_neg_integer()} |
        {between, {gte, non_neg_integer()}, {lt, non_neg_integer()}} |
        {either, {gte, non_neg_integer()}, {lt, non_neg_integer()}}.
-type range_map() :: #{term() => hash_range()}.

%% ===================================================================
%% Public API
%% ===================================================================

%% @doc Generate a `Filter' fun to use during partition repair.
%%
%%      `Target' - Partition under repair.
%%
%%      `Ring' - The ring to use for repair.
%%
%%      `NValMap' - A map from bucket to `n_val', only custom buckets
%%      have entries, everything else uses default.
%%
%%      `DefaultN' - The default `n_val'.
gen_filter(Target, Ring, NValMap, DefaultN, InfoFun) ->
    RangeMap = riak_core_repair:gen_range_map(Target, Ring, NValMap),
    Default = riak_core_repair:gen_range(Target, Ring, DefaultN),
    fun(BKey) ->
            {Bucket, <<Hash:160/integer>>} = InfoFun(BKey),
            case maps:get(Bucket, RangeMap, Default) of
                {lt, HighHash} ->
                    Hash < HighHash;
                {gte, LowHash} ->
                    Hash > LowHash;
                {between, {gte, LowHash}, {lt, HighHash}} ->
                    Hash >= LowHash andalso Hash < HighHash;
                {either, {gte, LowHash}, {lt, HighHash}} ->
                    Hash >= LowHash orelse Hash < HighHash
            end
    end.

%% @doc Generate the hash `Range' for a given `Target' partition and
%%      `NVal'.
%%
%% Note: The type of NVal should be pos_integer() but dialyzer says
%%       success typing is integer() and I don't have time for games.
-spec gen_range(
    index(), riak_core_ring:riak_core_ring(), integer()) ->
        hash_range().
gen_range(Target, Ring, NVal) ->
    CH = riak_core_ring:chash(Ring),
    [LowPredecessor|RestPredecessors] =
        lists:reverse(
            lists:map(
                fun({I, _N}) -> I end,
                chash:predecessors(
                    <<Target:160/integer>>,
                    CH,
                    NVal + 1 % predecessors includes itself
                )
            )
        ),
    case Target of
        0 ->
            {gte, LowPredecessor};
        _ ->
            {A, B} =
                lists:splitwith(
                    fun(PB) -> PB > 0 end,
                    [LowPredecessor|RestPredecessors]
                ),
            case {A, B} of
                {_A, []} ->
                    {
                        between,
                        {gte, LowPredecessor},
                        {lt, Target}
                    };
                {[], _B} ->
                    {lt, Target};
                {A, _B} ->
                    {
                        either,
                        {gte, LowPredecessor},
                        {lt, Target}
                    }
            end
    end.

%% @doc Generate the map from bucket `B' to hash `Range' that a key
%%      must fall into to be included for repair on the `Target'
%%      partition.
-spec gen_range_map(
    index(),
    riak_core_ring:riak_core_ring(),
    list({term(), pos_integer()})) -> range_map().
gen_range_map(Target, Ring, NValList) ->
    Ns = lists:usort(lists:map(fun({_B, N}) -> N end, NValList)),
    NToRange = lists:map(fun(N) -> {N, gen_range(Target, Ring, N)} end, Ns),
    maps:from_list(
        lists:map(
            fun({B, N}) ->
                {_N, Range} = lists:keyfind(N, 1, NToRange), {B, Range}
            end,
            NValList
        )
    ).