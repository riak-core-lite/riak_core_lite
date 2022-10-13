%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007-2014 Basho Technologies, Inc.
%% Copyright (c) 2020-2022 Workday, Inc.
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
-module(riak_core_ring_util).

-export([assign/2,
         check_ring/0,
         check_ring/1,
         check_ring/2,
         hash_to_partition_id/2,
         partition_id_to_hash/2,
         hash_is_partition_boundary/2,
         uncovered_preflists/1
]).

-export([
    uncovered_preflists/3,
    uncovered_preflists/4,
    find_stochastic_chunks/3,
    find_stochastic_chunks/4
]). %% for testing in the field, only

-export_type([partition_id/0]).

-ifdef(TEST).
-ifdef(EQC).
-export([prop_ids_are_boundaries/0, prop_reverse/0,
         prop_monotonic/0, prop_only_boundaries/0]).

-include_lib("eqc/include/eqc.hrl").
-endif.
-include_lib("eunit/include/eunit.hrl").
-endif.

-type partition_id() :: non_neg_integer().
%% This integer represents a value in the range [0, ring_size)

%% @doc Forcibly assign a partition to a specific node
assign(Partition, ToNode) ->
    F = fun(Ring, _) ->
                {new_ring, riak_core_ring:transfer_node(Partition, ToNode, Ring)}
        end,
    {ok, _NewRing} = riak_core_ring_manager:ring_trans(F, undefined),
    ok.

%% @doc Check the local ring for any preflists that do not satisfy n_val
check_ring() ->
    {ok, R} = riak_core_ring_manager:get_my_ring(),
    check_ring(R).

check_ring(Ring) ->
    check_ring(Ring, default_nval()).

%% @private
default_nval() ->
    {ok, Props} = application:get_env(riak_core, default_bucket_props),
    {n_val, Nval} = lists:keyfind(n_val, 1, Props),
    Nval.


%% @doc Check a ring for any preflists that do not satisfy n_val
check_ring(Ring, Nval) ->
    Preflists = riak_core_ring:all_preflists(Ring, Nval),
    lists:foldl(fun(PL,Acc) ->
                        PLNodes = lists:usort([Node || {_,Node} <- PL]),
                        case length(PLNodes) of
                            Nval ->
                                Acc;
                            _ ->
                                ordsets:add_element(PL, Acc)
                        end
                end, [], Preflists).

-spec hash_to_partition_id(chash:index() | chash:index_as_int(),
                           riak_core_ring:ring_size()) ->
                                  riak_core_ring:partition_id().
%% @doc Map a key hash (as binary or integer) to a partition ID [0, ring_size)
hash_to_partition_id(CHashKey, RingSize) when is_binary(CHashKey) ->
    <<CHashInt:160/integer>> = CHashKey,
    hash_to_partition_id(CHashInt, RingSize);
hash_to_partition_id(CHashInt, RingSize) ->
    CHashInt div chash:ring_increment(RingSize).

-spec partition_id_to_hash(riak_core_ring:partition_id(), pos_integer()) ->
                                  chash:index_as_int().
%% @doc Identify the first key hash (integer form) in a partition ID [0, ring_size)
partition_id_to_hash(Id, RingSize) ->
    Id * chash:ring_increment(RingSize).


-spec hash_is_partition_boundary(chash:index() | chash:index_as_int(),
                                 pos_integer()) ->
                                        boolean().
%% @doc For user-facing tools, indicate whether a specified hash value
%% is a valid "boundary" value (first hash in some partition)
hash_is_partition_boundary(CHashKey, RingSize) when is_binary(CHashKey) ->
    <<CHashInt:160/integer>> = CHashKey,
    hash_is_partition_boundary(CHashInt, RingSize);
hash_is_partition_boundary(CHashInt, RingSize) ->
    CHashInt rem chash:ring_increment(RingSize) =:= 0.

%%
%% @param UpNodes list of currently running nodes
%% @returns set of preflists that are uncovered if only UpNodes are running
%% @doc
%% Return the set of preflists that are uncovered if only the supplied list of
%% nodes are running.  If this list is empty, then the cluster is available for
%% reads and writes if all nodes in UpNodes are available.
%% @end
%%
-spec uncovered_preflists([node()]) -> [riak_core_apl:preflist()].
uncovered_preflists(UpNodes) ->
    uncovered_preflists(UpNodes, default_nval(), 1).

%% @hidden
uncovered_preflists(Nodes, NVal, Min) ->
    case riak_core_ring_manager:get_my_ring() of
        {ok, Ring} ->
            uncovered_preflists(Nodes, Ring, NVal, Min);
        Error ->
            Error
    end.

%% @private
uncovered_preflists(Nodes, Ring, NVal, Min) ->
    AllPreflists = riak_core_ring:all_preflists(Ring, NVal),
    filter_uncovered_preflists(Nodes, AllPreflists, Min).

%% @private
%% Return true if there are at least Min-many nodes from Nodes in the supplied PrefList
%% e.g., [{index1, node1}, {index2, node2}, {index3, node3}], [node1, node5, node7, node8], 1 -> true, whereas
%%       [{index1, node1}, {index2, node2}, {index3, node3}], [node4, node5, node7, node8], 1 -> false
covers(Nodes, PrefList, CMin) ->
    InNodes = [IndexNode || {_Index, Node} = IndexNode <- PrefList, lists:member(Node, Nodes)],
    length(InNodes) >= CMin.

%% @private
%% Return the set of pref lists from PrefLists that are not "covered by", i.e.,
%% don't have Min-many indices owned by, any of the supplied set of Nodes.
%% Note.  If the returned list is empty, then every pref list is covered by
%% the supplied set of nodes, i.e., every key has a replica on at least Min-many
%% nodes in the supplied set of nodes.
filter_uncovered_preflists(Nodes, PrefLists, CMin) ->
    [PrefList || PrefList <- PrefLists, not covers(Nodes, PrefList, CMin)].

%%
%% FOR INTERNAL/DIAGNOSTIC USE ONLY
%%
%% Find a set of chunks (i.e., a partitioning of the nodes in the ring), such that
%% for every chunk, C and set of nodes in the Ring, N, there are at least CMin replicas
%% in N - C (given a specific NVal, almost always 3).
%%
%% @hidden
find_stochastic_chunks(Ring, NVal, CMin) ->
    Nodes = riak_core_ring:all_members(Ring),
    find_stochastic_chunks(Ring, NVal, CMin, length(Nodes)).

%% @hidden
find_stochastic_chunks(_Ring, NVal, CMin, K) when NVal < 1 orelse K < 1 orelse CMin < 1 orelse CMin >= NVal->
    {error, badarg};
find_stochastic_chunks(Ring, NVal, CMin, K) ->
    Nodes = riak_core_ring:all_members(Ring),
    PrefLists = riak_core_ring:all_preflists(Ring, NVal),
    AllNodes = shuffle_list(Nodes),
    {ok, find_chunks_dfs({PrefLists, CMin, K, AllNodes}, AllNodes, [])}.

%% @private
shuffle_list(L) ->
    RandMax = 4294967295, %% 2^32 - 1, to keep the int non-boxed
    RandomZipList = lists:sort([{rand:uniform(RandMax), E} || E <- L]),
    [E || {_, E} <- RandomZipList].

%% @private
find_chunks_dfs(_Fixed, [] = _CandidateNodes, Chunks) ->
    Chunks;
find_chunks_dfs(Fixed, CandidateNodes, Chunks) ->
    {Chunk, RestCandidateNodes} = find_chunk_dfs(Fixed, CandidateNodes),
    NewChunks = [Chunk | Chunks],
    find_chunks_dfs(Fixed, RestCandidateNodes, NewChunks).

%% @private
find_chunk_dfs({_PrefLists, _CMin, K, AllNodes} = Fixed, CandidateNodes) ->
    find_chunk_dfs(Fixed, CandidateNodes, K, AllNodes, []).

%% @private
find_chunk_dfs(_Fixed, [], _K, _Nodes, Chunk) ->
    {Chunk, []};
find_chunk_dfs(_Fixed, CandidateNodes, 0, _Nodes, Chunk) ->
    {Chunk, CandidateNodes};
find_chunk_dfs(Fixed, CandidateNodes, Depth, Nodes, Chunk) ->
    case find_first_covering_candidate(Fixed, Nodes, CandidateNodes) of
        none ->
            {Chunk, CandidateNodes}; %% no children of this node cover the preflist
        {SelectedNode, RestCandidates} ->
            NewNodes = Nodes -- [SelectedNode],
            find_chunk_dfs(Fixed, RestCandidates, Depth - 1, NewNodes, [SelectedNode|Chunk])
    end.

%% @private
find_first_covering_candidate({PrefLists, CMin, _K, _AllNodes} = _Fixed, Nodes, CandidateNodes) ->
    SearchFun = fun(Candidate) ->
        covers_all_preflists(Nodes -- [Candidate], PrefLists, CMin)
    end,
    case lists:search(SearchFun, CandidateNodes) of
        false ->
            none;
        {value, Candidate} ->
            {Candidate, CandidateNodes -- [Candidate]}
    end.

%% @private
covers_all_preflists(Nodes, PrefLists, CMin) ->
    lists:all(
        fun(Preflist) ->
            covers(Nodes, Preflist, CMin)
        end,
        PrefLists
    ).

%% ===================================================================
%% EUnit tests
%% ===================================================================
-ifdef(TEST).

%% The EQC properties below are more comprehensive tests for hashes as
%% integers; use pure unit tests to make certain that binary hashes
%% are handled.

%% Partition boundaries are reversable.
reverse_test() ->
    IntIndex = riak_core_ring_util:partition_id_to_hash(31, 32),
    HashIndex = <<IntIndex:160>>,
    ?assertEqual(31, riak_core_ring_util:hash_to_partition_id(HashIndex, 32)),
    ?assertEqual(0, riak_core_ring_util:hash_to_partition_id(<<0:160>>, 32)).

%% Index values somewhere in the middle of a partition can be mapped
%% to partition IDs.
partition_test() ->
    IntIndex = riak_core_ring_util:partition_id_to_hash(20, 32) +
        chash:ring_increment(32) div 3,
    HashIndex = <<IntIndex:160>>,
    ?assertEqual(20, riak_core_ring_util:hash_to_partition_id(HashIndex, 32)).

%% Index values divisible by partition size are boundary values, others are not
boundary_test() ->
    BoundaryIndex = riak_core_ring_util:partition_id_to_hash(15, 32),
    ?assert(riak_core_ring_util:hash_is_partition_boundary(<<BoundaryIndex:160>>, 32)),
    ?assertNot(riak_core_ring_util:hash_is_partition_boundary(<<(BoundaryIndex + 32):160>>, 32)),
    ?assertNot(riak_core_ring_util:hash_is_partition_boundary(<<(BoundaryIndex - 32):160>>, 32)),
    ?assertNot(riak_core_ring_util:hash_is_partition_boundary(<<(BoundaryIndex + 1):160>>, 32)),
    ?assertNot(riak_core_ring_util:hash_is_partition_boundary(<<(BoundaryIndex - 1):160>>, 32)),
    ?assertNot(riak_core_ring_util:hash_is_partition_boundary(<<(BoundaryIndex + 2):160>>, 32)),
    ?assertNot(riak_core_ring_util:hash_is_partition_boundary(<<(BoundaryIndex + 10):160>>, 32)).

create_ring(RingSize, NumNodes) ->
    SingletonRing = riak_core_ring:fresh(RingSize, 'test@127.0.0.1'),
    application:set_env(riak_core, wants_claim_fun, {riak_core_claim, default_wants_claim}),
    application:set_env(riak_core, choose_claim_fun, {riak_core_claim, default_choose_claim}),
    Commands = generate_commands(NumNodes - 1),
    run_simulator(Commands, SingletonRing).

run_simulator([], Ring) ->
    Ring;
run_simulator([Command|Rest], Ring) ->
    NewRing = riak_core_claim_sim:run([{ring, Ring}, {return_ring, true}, {print, false}, {cmds, [Command]}]),
    run_simulator(Rest, NewRing).

generate_commands(N) ->
    case rand:uniform(N) of
        1 ->
            [ [{join, N}] ];
        K when N =:= K ->
            [ [{join, generate_nodename(I)}] || I <- lists:seq(1, N)];
        R ->
            [ [{join, generate_nodename(I)} || I <- lists:seq(1, R)], [{join, generate_nodename(I)} || I <- lists:seq(N - R, N)] ]
    end.

generate_nodename(I) ->
    list_to_atom(lists:flatten(io_lib:format("test~p@127.0.0.1", [I]))).

verify_max_nodeset_size(_NodeSets, undefined) ->
    ok;
verify_max_nodeset_size(NodeSets, K) ->
    lists:foreach(
        fun(NodeSet) ->
            ?assert(length(NodeSet) =< K)
        end,
        NodeSets
    ).

verify_random_keys(Ring, CoveringNodeSets, CMin) ->
    RandomKeys = create_random_keys(2048),
    lists:foreach(
        fun(Key) ->
            verify_random_key(Key, Ring, CoveringNodeSets, CMin)
        end,
        RandomKeys
    ).

create_random_keys(N) ->
    [create_random_key(100) || _I <- lists:seq(1, N)].

create_random_key(MaxLen) ->
    list_to_binary([rand:uniform(255) || _ <- lists:seq(1, rand:uniform(MaxLen))]).


verify_random_key(Key, Ring, CoveringNodeSets, CMin) ->
    lists:foreach(
        fun(CoveringNodeSet) ->
            verify_covered(Key, Ring, CoveringNodeSet, CMin)
        end,
        CoveringNodeSets
    ).

verify_covered(Key, Ring, CoveringNodeSet, CMin) ->
    BucketProps = [{chash_keyfun, {riak_core_util, chash_std_keyfun}}],
    DocIdx = riak_core_util:chash_key({<<"test">>, Key}, BucketProps),
    PL = riak_core_apl:get_primary_apl(DocIdx, 3, Ring, CoveringNodeSet),
    ?assert(CMin =< length(PL)).

%% chunks a partition of the members of the ring, and all partitions are "safe"
%% (i.e., their complements all cover the ring)
find_stochastic_chunks_test_() ->
    {timeout, 720, [
        fun() ->
            NVal = 3,
            [begin
                 io:format(user, ".", []),
                 Ring = create_ring(RingSize, NumNodes),
                 case riak_core_ring_util:find_stochastic_chunks(Ring, NVal, CMin, K) of
                     {ok, Chunks} ->
                         verify_max_nodeset_size(Chunks, K),
                         verify_safe_node_partitions(Ring, Chunks, CMin)
                 end
             end || CMin <- lists:seq(1, NVal - 1),
                    RingSize <- [256, 1024],
                    NumNodes <- [8, 16, 32, 64],
                    K <- [8, 16, 24]]
        end
    ]}.

verify_safe_node_partitions(Ring, SafeNodePartitions, CMin) ->
    Nodes = riak_core_ring:all_members(Ring),
    ?assert(is_partitioning(sets:from_list(Nodes), SafeNodePartitions)),
    verify_random_keys(Ring, [Nodes -- Partition || Partition <- SafeNodePartitions], CMin).

%% @private
is_partitioning(N, P) ->
    sets_equal(union(P), N) andalso sets:size(intersection(P)) == 0.

%% @private
union(P) ->
    sets:union([sets:from_list(X) || X <- P]).

%% @private
intersection(P) ->
    sets:intersection([sets:from_list(X) || X <- P]).

sets_equal(A, B) ->
    sets:is_subset(A, B) andalso sets:is_subset(B, A).

-ifdef(EQC).

-define(QC_OUT(P),
        eqc:on_output(fun(Str, Args) ->
                              io:format(user, Str, Args) end, P)).
-define(TEST_TIME_SECS, 5).

-define(HASHMAX, 1 bsl 160 - 1).
-define(RINGSIZEEXPMAX, 11).
-define(RINGSIZE(X), (1 bsl X)). %% We'll generate powers of 2 with choose() and convert that to a ring size with this macro
-define(PARTITIONSIZE(X), ((1 bsl 160) div (X))).

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

-endif. % EQC
-endif. % TEST
