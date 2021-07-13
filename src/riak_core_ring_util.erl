%% -------------------------------------------------------------------
%%
%% riak_core: Core Riak Application
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
-module(riak_core_ring_util).

-export([assign/2,
         check_ring/0,
         check_ring/1,
         check_ring/2,
         hash_to_partition_id/2,
         partition_id_to_hash/2,
         hash_is_partition_boundary/2]).

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

-endif.

%% @doc Forcibly assign a partition to a specific node
assign(Partition, ToNode) ->
    F = fun (Ring, _) ->
                {new_ring,
                 riak_core_ring:transfer_node(Partition, ToNode, Ring)}
        end,
    {ok, _NewRing} = riak_core_ring_manager:ring_trans(F,
                                                       undefined),
    ok.

%% @doc Check the local ring for any preflists that do not satisfy n_val
check_ring() ->
    {ok, R} = riak_core_ring_manager:get_my_ring(),
    check_ring(R).

check_ring(Ring) ->
    {ok, Nval} = application:get_env(riak_core,
                                     target_n_val),
    check_ring(Ring, Nval).

%% @doc Check a ring for any preflists that do not satisfy n_val
check_ring(Ring, Nval) ->
    Preflists = riak_core_ring:all_preflists(Ring, Nval),
    lists:foldl(fun (PL, Acc) ->
                        PLNodes = lists:usort([Node || {_, Node} <- PL]),
                        case length(PLNodes) of
                            Nval -> Acc;
                            _ -> ordsets:add_element(PL, Acc)
                        end
                end,
                [],
                Preflists).

-spec hash_to_partition_id(chash:index() |
                           chash:index_as_int(),
                           riak_core_ring:ring_size()) -> riak_core_ring:partition_id().

%% @doc Map a key hash (as binary or integer) to a partition ID [0, ring_size)
hash_to_partition_id(CHashKey, RingSize)
    when is_binary(CHashKey) ->
    <<CHashInt:160/integer>> = CHashKey,
    hash_to_partition_id(CHashInt, RingSize);
hash_to_partition_id(CHashInt, RingSize) ->
    CHashInt div chash:ring_increment(RingSize).

-spec
     partition_id_to_hash(riak_core_ring:partition_id(),
                          pos_integer()) -> chash:index_as_int().

%% @doc Identify the first key hash (integer form) in a partition ID [0, ring_size)
partition_id_to_hash(Id, RingSize) ->
    Id * chash:ring_increment(RingSize).

-spec hash_is_partition_boundary(chash:index() |
                                 chash:index_as_int(),
                                 pos_integer()) -> boolean().

%% @doc For user-facing tools, indicate whether a specified hash value
%% is a valid "boundary" value (first hash in some partition)
hash_is_partition_boundary(CHashKey, RingSize)
    when is_binary(CHashKey) ->
    <<CHashInt:160/integer>> = CHashKey,
    hash_is_partition_boundary(CHashInt, RingSize);
hash_is_partition_boundary(CHashInt, RingSize) ->
    CHashInt rem chash:ring_increment(RingSize) =:= 0.

%% ===================================================================
%% EUnit tests
%% ===================================================================
-ifdef(TEST).

%% Use pure unit tests to make certain that binary hashes
%% are handled.

%% Partition boundaries are reversable.
reverse_test() ->
    IntIndex = riak_core_ring_util:partition_id_to_hash(31,
                                                        32),
    HashIndex = <<IntIndex:160>>,
    ?assertEqual(31,
                 (riak_core_ring_util:hash_to_partition_id(HashIndex,
                                                           32))),
    ?assertEqual(0,
                 (riak_core_ring_util:hash_to_partition_id(<<0:160>>,
                                                           32))).

%% Index values somewhere in the middle of a partition can be mapped
%% to partition IDs.
partition_test() ->
    IntIndex = riak_core_ring_util:partition_id_to_hash(20,
                                                        32)
                   + chash:ring_increment(32) div 3,
    HashIndex = <<IntIndex:160>>,
    ?assertEqual(20,
                 (riak_core_ring_util:hash_to_partition_id(HashIndex,
                                                           32))).

%% Index values divisible by partition size are boundary values, others are not
boundary_test() ->
    BoundaryIndex =
        riak_core_ring_util:partition_id_to_hash(15, 32),
    ?assert((riak_core_ring_util:hash_is_partition_boundary(<<BoundaryIndex:160>>,
                                                            32))),
    ?assertNot((riak_core_ring_util:hash_is_partition_boundary(<<(BoundaryIndex
                                                                      +
                                                                      32):160>>,
                                                               32))),
    ?assertNot((riak_core_ring_util:hash_is_partition_boundary(<<(BoundaryIndex
                                                                      -
                                                                      32):160>>,
                                                               32))),
    ?assertNot((riak_core_ring_util:hash_is_partition_boundary(<<(BoundaryIndex
                                                                      +
                                                                      1):160>>,
                                                               32))),
    ?assertNot((riak_core_ring_util:hash_is_partition_boundary(<<(BoundaryIndex
                                                                      -
                                                                      1):160>>,
                                                               32))),
    ?assertNot((riak_core_ring_util:hash_is_partition_boundary(<<(BoundaryIndex
                                                                      +
                                                                      2):160>>,
                                                               32))),
    ?assertNot((riak_core_ring_util:hash_is_partition_boundary(<<(BoundaryIndex
                                                                      +
                                                                      10):160>>,
                                                               32))).

-endif. % TEST
