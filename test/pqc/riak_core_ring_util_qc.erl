-module(riak_core_ring_util_qc).
-ifdef(TEST).
-ifdef(PROPER).

-compile(export_all).
-export([prop_ids_are_boundaries/0,
         prop_reverse/0,
         prop_monotonic/0,
         prop_only_boundaries/0]).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(QC_OUT(P),
        proper:on_output(fun(Str, Args) ->
                              io:format(user, Str, Args) end, P)).
-define(TEST_TIME_SECS, 5).

-define(HASHMAX, 1 bsl 160 - 1).
-define(RINGSIZEEXPMAX, 11).
-define(RINGSIZE(X), (1 bsl X)).%% We'll generate powers of 2 with choose()
                                %% and convert that to a ring size with this macro
-define(PARTITIONSIZE(X), ((1 bsl 160) div (X))).

ids_are_boundaries_test_() ->
    {timeout, ?TEST_TIME_SECS+5, [?_assert(test_ids_are_boundaries() =:= true)]}.

test_ids_are_boundaries() ->
    test_ids_are_boundaries(?TEST_TIME_SECS).
%TODO check time sec
test_ids_are_boundaries(_TestTimeSecs) ->
        proper:quickcheck(?QC_OUT(prop_ids_are_boundaries()), [{numtests, 5000}]).

reverse_test_() ->
    {timeout, ?TEST_TIME_SECS+5, [?_assert(test_reverse() =:= true)]}.

test_reverse() ->
    test_reverse(?TEST_TIME_SECS).
%TODO check time sec
test_reverse(_TestTimeSecs) ->
        proper:quickcheck(prop_reverse(), [{numtests, 5000}]).


monotonic_test_() ->
    {timeout, ?TEST_TIME_SECS+5, [?_assert(test_monotonic() =:= true)]}.

test_monotonic() ->
    test_monotonic(?TEST_TIME_SECS).

test_monotonic(_TestTimeSecs) ->
        proper:quickcheck(?QC_OUT(prop_monotonic()), [{numtests, 5000}]).


%% `prop_only_boundaries' should run a little longer: not quite as
%% fast, need to scan a larger portion of hash space to establish
%% correctness
only_boundaries_test_() ->
    {timeout, ?TEST_TIME_SECS+15, [?_assert(test_only_boundaries() =:= true)]}.

test_only_boundaries() ->
    test_only_boundaries(?TEST_TIME_SECS+10).

test_only_boundaries(_TestTimeSecs) ->
        proper:quickcheck(prop_only_boundaries(), [{numtests, 5000}]).

%% Partition IDs should map to hash values which are partition boundaries
prop_ids_are_boundaries() ->
    ?FORALL(RingPower, choose(2, ?RINGSIZEEXPMAX),
            ?FORALL(PartitionId, choose(0, ?RINGSIZE(RingPower) - 1),
                    begin
                        RingSize = ?RINGSIZE(RingPower),
                        BoundaryHash =
                            riak_core_ring_util:partition_id_to_hash(PartitionId,
                                                                     RingSize),
                        equals(true,
                               riak_core_ring_util:hash_is_partition_boundary(BoundaryHash,
                                                                              RingSize))
                    end
                   )).

%% Partition IDs should map to hash values which map back to the same partition IDs
prop_reverse() ->
    ?FORALL(RingPower, choose(2, ?RINGSIZEEXPMAX),
            ?FORALL(PartitionId, choose(0, ?RINGSIZE(RingPower) - 1),
                    begin
                        RingSize = ?RINGSIZE(RingPower),
                        BoundaryHash =
                            riak_core_ring_util:partition_id_to_hash(PartitionId,
                                                                     RingSize),
                        equals(PartitionId,
                               riak_core_ring_util:hash_to_partition_id(
                                 BoundaryHash, RingSize))
                    end
                   )).

%% For any given hash value, any larger hash value maps to a partition
%% ID of greater or equal value.
prop_monotonic() ->
    ?FORALL(RingPower, choose(2, ?RINGSIZEEXPMAX),
            ?FORALL(HashValue, choose(0, ?HASHMAX - 1),
                    ?FORALL(GreaterHash, choose(HashValue + 1, ?HASHMAX),
                            begin
                                RingSize = ?RINGSIZE(RingPower),
                                LowerPartition =
                                    riak_core_ring_util:hash_to_partition_id(HashValue,
                                                                             RingSize),
                                GreaterPartition =
                                    riak_core_ring_util:hash_to_partition_id(GreaterHash,
                                                                             RingSize),
                                LowerPartition =< GreaterPartition
                            end
                           ))).

%% Hash values which are listed in the ring structure are boundary
%% values
ring_to_set({_RingSize, PropList}) ->
    ordsets:from_list(lists:map(fun({Hash, dummy}) -> Hash end, PropList)).

find_near_boundaries(RingSize, PartitionSize) ->
    ?LET({Id, Offset}, {choose(1, RingSize-1), choose(-(RingSize*2), (RingSize*2))},
         Id * PartitionSize + Offset).

prop_only_boundaries() ->
    ?FORALL(RingPower, choose(2, ?RINGSIZEEXPMAX),
            ?FORALL({HashValue, BoundarySet},
                    {frequency([
                               {5, choose(0, ?HASHMAX)},
                               {2, find_near_boundaries(?RINGSIZE(RingPower),
                                                        ?PARTITIONSIZE(?RINGSIZE(RingPower)))}]),
                     ring_to_set(chash:fresh(?RINGSIZE(RingPower), dummy))},
                     begin
                         RingSize = ?RINGSIZE(RingPower),
                         HashIsInRing = ordsets:is_element(HashValue, BoundarySet),
                         HashIsPartitionBoundary =
                             riak_core_ring_util:hash_is_partition_boundary(HashValue,
                                                                            RingSize),
                         equals(HashIsPartitionBoundary, HashIsInRing)
                     end
                   )).

-endif.
-endif.