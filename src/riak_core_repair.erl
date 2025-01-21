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
-export([gen_filter/5]).

-include("riak_core_handoff.hrl").

-type hash_range() :: list(non_neg_integer()).
-type range_map() :: #{pos_integer() => hash_range()}.
-type bucketkey() :: term().
-type bucket() :: term().

%% ===================================================================
%% Public API
%% ===================================================================

%% @doc
%% External function to generate filter.  Used to require an NvalMap of
%% bucket -> n_val information as a proplist(), but this is now ignored as
%% n_val information is collected dynamically during the fold.
%% 
%% The InfoFun must take a Bucket/Key and return a Bucket and a hash.
%% 
%% The work is done within gen_filter/6 - as this doesn't require riak_core to
%% be running, and so is simpler to eunit test.
-spec gen_filter(
    index(),
    riak_core_ring:riak_core_ring(),
    any(),
    pos_integer(),
    fun((bucketkey()) -> {bucket(), binary()}))
        -> fun((bucketkey()) -> boolean()).
gen_filter(Target, Ring, _NValMap, DefaultN, InfoFun) ->
    AllN_Types = riak_core_bucket_type:all_n(),
    AllN_Legacy = riak_core_bucket:all_n(Ring),
    AllN = lists:usort(AllN_Types ++ AllN_Legacy),
    RingSize = element(1, riak_core_ring:chash(Ring)),
    RingBits = trunc(math:log2(RingSize)),
    NValFinder = fun nval_finder/1,
    gen_filter(Target, RingBits, DefaultN, AllN, InfoFun, NValFinder).

%% ===================================================================
%% Internal functions
%% ===================================================================

%% @doc
%% Get the nval for a bucket.  Function should handle both typed and untyped
%% buckets
-spec nval_finder(term()) -> false|{n_val, pos_integer()}.
nval_finder(Bucket) ->
    BucketProps = riak_core_bucket:get_bucket(Bucket),
    lists:keyfind(n_val, 1, BucketProps).

%% @doc
%% Generate the filter.  The target will have the data from its NVal
%% predecessors, so that is what we have to match.
%% 
%% The buckets will be learned as we traverse.  Fetching the bucket properties
%% is fast due to cache mechanisms - but not as fast as accessing the process
%% dictionary - and efficiency matters as this may be called >> 1K persec. So
%% whenever the process learns of a new Type or Untyped bucket it should store
%% that n_val information to use again, in a map on the process dictionary.
%% 
%% Note the actual checker cannot be cached against the bucket, as the process
%% may need to apply multiple filters.  Only the hash and the nval will be
%% consistent across multiple filters.
%% 
%% Likewise calls to the InfoFun are not free.  If there are multiple filters
%% to be applied the handoff_sender process should set the last_hash Key in its
%% process dictionary and the answer will not be cached.  Setting it to
%% anything else will keep the hash cached until another Key is discovered
-spec gen_filter(
    index(),
    pos_integer(),
    pos_integer(),
    list(pos_integer()),
    fun((bucketkey()) -> {bucket(), binary()}),
    fun((bucket()) -> false|{n_val, pos_integer()}))
        -> fun((bucketkey()) -> boolean()).
gen_filter(Target, RingBits, DefaultN, AllN, InfoFun, NValFinder) ->
    RangeMap = gen_range_map(Target, RingBits, AllN),
    Default = gen_range(Target, RingBits, DefaultN),
    fun(BKey) ->
        {Bucket, Hash} =
            case get(last_hash) of
                no_cache ->
                    {B, <<H:RingBits/integer, _/bitstring>>} = InfoFun(BKey),
                    {B, H};
                {BKey, B, H} ->
                    {B, H};
                _ ->
                    {B, <<H:RingBits/integer, _/bitstring>>} = InfoFun(BKey),
                    put(last_hash, {BKey, B, H}),
                    {B, H}
            end,
        LookupB = case Bucket of {T, _TB} -> {type, T}; LB -> {bucket, LB} end,
        BucketNValMap =
            case get(nval_bucket_map) of
                BNM when is_map(BNM) ->
                    BNM;
                _ ->
                    maps:new()
            end,
        MembershipChecker =
            case maps:get(LookupB, BucketNValMap, not_cached) of
                not_cached ->
                    case NValFinder(Bucket) of
                        {n_val, N} when is_integer(N) ->
                            put(
                                nval_bucket_map,
                                maps:put(LookupB, {n_val, N}, BucketNValMap)
                            ),
                            maps:get(N, RangeMap, Default);
                        _ ->
                            put(
                                nval_bucket_map,
                                maps:put(LookupB, default, BucketNValMap)
                            ),
                            Default
                    end;
                {n_val, N} when is_integer(N), N > 0 ->
                    maps:get(N, RangeMap, Default);
                _ ->
                    Default
            end,
        lists:member(Hash, MembershipChecker)
    end.

%% @doc Generate the hash `Range' for a given `Target' partition and
%% `NVal'.
%% Hashes in riak_core are 160-bit integers, but if RingSize = 2 ^ RingBits
%% only RingBits of that hash are interesting.
%% Rather than comparing 160-bit integers or binaries for range equality just
%% do a membership check of a small integer position against a list of nval
%% positions
-spec gen_range(
    index(), pos_integer(), pos_integer()) ->
        hash_range().
gen_range(Target, RingBits, NVal)
        when
            is_integer(Target), Target >= 0,
            is_integer(RingBits), RingBits > 0,
            is_integer(NVal), NVal > 0 ->
    RingSize = 1 bsl RingBits,
    TargetPos = Target bsr (160 - RingBits),
    lists:map(
        fun(I) -> (TargetPos + RingSize - I) rem RingSize end,
        lists:seq(1, NVal)
    ).

%% @doc Generate the map from bucket `B' to hash `Range' that a key
%%      must fall into to be included for repair on the `Target'
%%      partition.
-spec gen_range_map(
    index(),
    pos_integer(),
    list(pos_integer())) -> range_map().
gen_range_map(Target, Ring, NValList) ->
    NToRange = 
        lists:map(fun(N) -> {N, gen_range(Target, Ring, N)} end, NValList),
    maps:from_list(NToRange).


%% ===================================================================
%% Unit tests
%% ===================================================================
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

basic_test() ->
    %% Assume ring size of 64, so 6 bits
    erase(),
    Target54 = 54 bsl 154,
    Source53 = 53 bsl 154,
    RepairGenFun =
        fun(T) ->
            gen_filter(
                T, 6, 3, [4, 5], fun test_hash64_fun/1, fun test_nval_finder/1)
        end,
    Filter54Fun = RepairGenFun(Target54),
    Filter53Fun = RepairGenFun(Source53),
    put(last_hash, no_cache),
    Hash52To53 = <<52:6/integer, 1:1/integer, 0:153/integer>>,
    ?assert(Filter54Fun({{<<"OtherType">>, <<"B1">>}, Hash52To53})),
    ?assertMatch(no_cache, get(last_hash)),
    ?assert(Filter53Fun({{<<"OtherType">>, <<"B1">>}, Hash52To53})),
    NVM = get(nval_bucket_map),
    ?assertMatch(default, maps:get({type, <<"OtherType">>}, NVM)),
    ?assertNot(
        Filter54Fun({{<<"OtherType">>, <<"B1">>},
        <<Target54:160/integer>>})
    ), % Self is not in, must be lt not lte
    Hash49To50 = <<49:6/integer, 1:1/integer, 0:153/integer>>,
    ?assertNot(Filter54Fun({<<"BucketDefault">>, Hash49To50})),
    ?assertNot(Filter54Fun({<<"BucketDefault">>, Hash49To50})),
    ?assertNot(Filter53Fun({<<"BucketDefault">>, Hash49To50})),
    ?assertNot(Filter53Fun({<<"BucketDefault">>, Hash49To50})),
    ?assert(Filter54Fun({<<"BucketN5">>, Hash49To50})),
    ?assert(Filter54Fun({<<"BucketN5">>, Hash49To50})),
    ?assertNot(Filter53Fun({<<"BucketDefault">>, Hash49To50})),
        %check caching doesn't impact results
    put(last_hash, undefined),
    ?assertNot(Filter53Fun({<<"BucketDefault">>, Hash49To50})),
    ?assert(Filter54Fun({<<"BucketN5">>, Hash49To50})),
    ?assert(Filter54Fun({<<"BucketN5">>, Hash49To50})),
    ?assertNot(Filter53Fun({<<"BucketDefault">>, Hash49To50})),
    erase()
    .

wrapping_test() ->
    erase(),
    Target1 = 1 bsl 154,
    Target0 = 0,
    RepairGenFun =
        fun(T) ->
            gen_filter(
                T, 6, 3, [4, 5], fun test_hash64_fun/1, fun test_nval_finder/1)
        end,
    Filter1Fun = RepairGenFun(Target1),
    Filter0Fun = RepairGenFun(Target0),
    put(last_hash, no_cache),
    Hash52To53 = <<52:6/integer, 1:1/integer, 0:153/integer>>,
    Hash00To01 = <<0:6/integer, 1:1/integer, 0:153/integer>>,
    Hash63To00 = <<63:6/integer, 1:1/integer, 0:153/integer>>,
    Hash62To63 = <<62:6/integer, 1:1/integer, 0:153/integer>>,
    Hash61To62 = <<61:6/integer, 1:1/integer, 0:153/integer>>,
    Hash60To61 = <<60:6/integer, 1:1/integer, 0:153/integer>>,
    ?assertNot(Filter1Fun({{<<"TypeN4">>, <<"B1">>}, Hash52To53})),
    ?assertNot(Filter0Fun({{<<"TypeN4">>, <<"B1">>}, Hash52To53})),
    ?assert(Filter1Fun({{<<"TypeN4">>, <<"B2">>}, Hash00To01})),
    ?assertNot(Filter0Fun({{<<"TypeN4">>, <<"B2">>}, Hash00To01})),
    ?assert(Filter1Fun({{<<"TypeN4">>, <<"B3">>}, Hash63To00})),
    ?assert(Filter0Fun({{<<"TypeN4">>, <<"B3">>}, Hash63To00})),
    ?assert(Filter1Fun({{<<"TypeN4">>, <<"B3">>}, Hash62To63})),
    ?assert(Filter0Fun({{<<"TypeN4">>, <<"B3">>}, Hash62To63})),
    ?assert(Filter1Fun({{<<"TypeN4">>, <<"B4">>}, Hash61To62})),
    ?assert(Filter0Fun({{<<"TypeN4">>, <<"B4">>}, Hash61To62})),
    ?assertNot(Filter1Fun({{<<"TypeN4">>, <<"B4">>}, Hash60To61})),
    ?assert(Filter0Fun({{<<"TypeN4">>, <<"B4">>}, Hash60To61})),
    NVM = get(nval_bucket_map),
    ?assertMatch([{type, <<"TypeN4">>}], maps:keys(NVM)),
    erase().

test_nval_finder({<<"TypeN4">>, _}) ->
    {n_val, 4};
test_nval_finder(<<"BucketN5">>) ->
    {n_val, 5};
test_nval_finder(<<"BucketDefault">>) ->
    false;
test_nval_finder(_) ->
    false.

test_hash64_fun({B, H}) ->
    {B, H}.


-endif.