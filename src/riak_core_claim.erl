%% -------------------------------------------------------------------
%%
%% riak_core: Core Riak Application
%%
%% Copyright (c) 2007-2015 Basho Technologies, Inc.  All Rights Reserved.
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

%% @doc The default functions used for claiming partition ownership.  Generally,
%%      a wants_claim function should return either {yes, Integer} or 'no' where
%%      Integer is the number of additional partitions wanted by this node.  A
%%      choose_claim function should return a riak_core_ring with more
%%      partitions claimed by this node than in the input ring.

%% The usual intention for partition ownership assumes relative heterogeneity of
%% capacity and connectivity.  Accordingly, the standard claim functions attempt
%% to maximize "spread" -- expected distance between partitions claimed by each
%% given node.  This is in order to produce the expectation that for any
%% reasonably short span of consecutive partitions, there will be a minimal
%% number of partitions owned by the same node.

%% The exact amount that is considered tolerable is determined by the
%% application env variable "target_n_val".  The functions in riak_core_claim
%% will ensure that all sequences up to target_n_val long contain no repeats if
%% at all possible.  The effect of this is that when the number of nodes in the
%% system is smaller than target_n_val, a potentially large number of partitions
%% must be moved in order to safely add a new node.  After the cluster has grown
%% beyond that size, a minimal number of partitions (1/NumNodes) will generally
%% be moved.

%% If the number of nodes does not divide evenly into the number of partitions,
%% it may not be possible to perfectly achieve the maximum spread constraint.
%% In that case, Riak will minimize the cases where the constraint is violated
%% and they will all exist near the origin point of the ring.

-module(riak_core_claim).

-type ring() :: riak_core_ring:riak_core_ring().

-export([claim/1,
         claim/3,
         claim_until_balanced/2,
         claim_until_balanced/4]).

-export([default_wants_claim/1,
         default_wants_claim/2,
         default_choose_claim/1,
         default_choose_claim/2,
         default_choose_claim/3,
         never_wants_claim/1,
         never_wants_claim/2,
         random_choose_claim/1,
         random_choose_claim/2,
         random_choose_claim/3]).

-export([wants_claim_v2/1,
         wants_claim_v2/2,
         choose_claim_v2/1,
         choose_claim_v2/2,
         choose_claim_v2/3,
         claim_rebalance_n/2,
         claim_diversify/3,
         claim_diagonal/3,
         wants/1,
         wants_owns_diff/2,
         meets_target_n/2,
         diagonal_stripe/2]).

-define(DEF_TARGET_N, 4).

%% @doc Run the claim algorithm for the complete ring.
%% @param Ring Ring the algorithm is run on.
%% @returns The ring after the claim algorithm has been applied.
-spec claim(Ring :: ring()) -> ring().

claim(Ring) -> claim(Ring, want, choose).

%% @doc Run the claim algorithm for the complete ring.
%% @param Ring Ring the algorithm is run on.
%% @param Mode1 ignored.
%% @param Mode2 ignored.
%% @returns The ring after the claim algorithm has been applied.
-spec claim(Ring :: ring(), Mode1 :: any(),
	    Mode2 :: any()) -> ring().

claim(Ring, _, _) ->
    Members = riak_core_ring:claiming_members(Ring),
    lists:foldl(fun (Node, Ring0) ->
                        claim_until_balanced(Ring0, Node, want, choose)
                end,
                Ring,
                Members).

%% @doc Apply the claim algorithm until a given node owns enough partitions.
%% @param Ring Ring the algorithm is applied to.
%% @param Node Node name of the node to be balanced.
%% @returns The balanced ring.
-spec claim_until_balanced(Ring :: ring(),
			   Node :: term()) -> ring().

claim_until_balanced(Ring, Node) ->
    claim_until_balanced(Ring, Node, want, choose).

%% @doc Apply the claim algorithm until a given node owns enough partitions.
%% @param Ring Ring the algorithm is applied to.
%% @param Node Node name of the node to be balanced.
%% @param want Fixed guard.
%% @param choose Fixed guard
%% @returns The balanced ring.
-spec claim_until_balanced(Ring :: ring(),
			   Node :: term(), want, choose) -> ring().

claim_until_balanced(Ring, Node, want, choose) ->
    NeedsIndexes = wants_claim_v2(Ring, Node),
    case NeedsIndexes of
        no -> Ring;
        {yes, _NumToClaim} ->
            NewRing = choose_claim_v2(Ring, Node),
            claim_until_balanced(NewRing, Node, want, choose)
    end.

%% ===================================================================
%% Claim Function Implementations
%% ===================================================================

%% @doc Choose a partition at random for the local node.
%% @param Ring Ring to claim on.
%% @returns Updated ring.
-spec default_choose_claim(Ring :: ring()) -> ring().

default_choose_claim(Ring) ->
    default_choose_claim(Ring, node()).

%% @doc Choose a partition for a given node at random.
%% @param Ring Ring to claim on.
%% @param Node Node to claim for.
%% @returns Updated ring.
-spec default_choose_claim(Ring :: ring(),
			   Node :: term()) -> ring().

default_choose_claim(Ring, Node) ->
    choose_claim_v2(Ring, Node).

%% @doc Choose a partition for a given node according to the given parameters.
%% @param Ring Ring to claim on.
%% @param Node Node to claim for.
%% @param Params Parameters to consider.
%% @returns Updated ring.
-spec default_choose_claim(Ring :: ring(),
			   Node :: term(), Params :: [term()]) -> ring().

default_choose_claim(Ring, Node, Params) ->
    choose_claim_v2(Ring, Node, Params).

%% @doc Want a partition if we currently have less than floor(ringsize/nodes).
%% @param Ring Ring to claim on.
%% @returns `{yes, Difference}' or `no'.
-spec default_wants_claim(Ring :: ring()) -> {yes,
					      integer()} |
					     no.

default_wants_claim(Ring) ->
    default_wants_claim(Ring, node()).

%% @doc Like {@link default_wants_claim/1} with a given node.
%% @param Node Node to decide balance for.
-spec default_wants_claim(Ring :: ring(),
			  Node :: term()) -> {yes, integer()} | no.

default_wants_claim(Ring, Node) ->
    wants_claim_v2(Ring, Node).

%% @doc Decide if the local node needs more partitions.
%% @param Ring Ring to claim on.
%% @returns `{yes, Difference}' or `no'.
-spec wants_claim_v2(Ring :: ring()) -> {yes,
					 integer()} |
					no.

wants_claim_v2(Ring) -> wants_claim_v2(Ring, node()).

%% @doc Like {@link wants_claim_v2/1} for another node.
%% @param Node Node to decide balance for.
-spec wants_claim_v2(Ring :: ring(),
		     Node :: term()) -> {yes, integer()} | no.

wants_claim_v2(Ring, Node) ->
    Active = riak_core_ring:claiming_members(Ring),
    Owners = riak_core_ring:all_owners(Ring),
    Counts = get_counts(Active, Owners),
    NodeCount = erlang:length(Active),
    RingSize = riak_core_ring:num_partitions(Ring),
    Avg = RingSize div NodeCount,
    Count = proplists:get_value(Node, Counts, 0),
    case Count < Avg of
        false -> no;
        true -> {yes, Avg - Count}
    end.

%% @doc Provide default choose parameters if none given
-spec default_choose_params() -> [term()].

default_choose_params() -> default_choose_params([]).

%% @doc Provide default NVal if it is not contained in the given parameters.
%% @param Params List of claim parameters.
%% @returns List of claim parameters containing target NVal.
-spec default_choose_params(Params ::
				term()) -> [term()].

default_choose_params(Params) ->
    case proplists:get_value(target_n_val, Params) of
        undefined ->
            TN = application:get_env(riak_core,
                                     target_n_val,
                                     ?DEF_TARGET_N),
            [{target_n_val, TN} | Params];
        _ -> Params
    end.

%% @doc Choose a partition the local node should claim.
%% @param Ring Ring to claim on.
%% @returns Updated ring.
-spec choose_claim_v2(Ring :: ring()) -> ring().

choose_claim_v2(Ring) -> choose_claim_v2(Ring, node()).

%% @doc Like {@link choose_claim_v2/1} with a specified node.
%% @param Node Specified node that claims a partition.
-spec choose_claim_v2(Ring :: ring(),
		      Node :: term()) -> ring().

choose_claim_v2(Ring, Node) ->
    Params = default_choose_params(),
    choose_claim_v2(Ring, Node, Params).

%% @doc Like {@link choose_claim_v2/2} with specified parameters.
%% @param Params0 Claim parameter list.
-spec choose_claim_v2(Ring :: ring(), Node :: term(),
		      Params0 :: [term()]) -> ring().

choose_claim_v2(Ring, Node, Params0) ->
    Params = default_choose_params(Params0),
    %% Active::[node()]
    Active = riak_core_ring:claiming_members(Ring),
    %% Owners::[{index(), node()}]
    Owners = riak_core_ring:all_owners(Ring),
    %% Counts::[node(), non_neg_integer()]
    Counts = get_counts(Active, Owners),
    RingSize = riak_core_ring:num_partitions(Ring),
    NodeCount = erlang:length(Active),
    %% Deltas::[node(), integer()]
    Deltas = get_deltas(RingSize,
                        NodeCount,
                        Owners,
                        Counts),
    {_, Want} = lists:keyfind(Node, 1, Deltas),
    TargetN = proplists:get_value(target_n_val, Params),
    AllIndices = lists:zip(lists:seq(0, length(Owners) - 1),
			   [Idx || {Idx, _} <- Owners]),
    EnoughNodes = (NodeCount > TargetN) or
                      (NodeCount == TargetN) and (RingSize rem TargetN =:= 0),
    case EnoughNodes of
        true ->
            %% If we have enough nodes to meet target_n, then we prefer to
            %% claim indices that are currently causing violations, and then
            %% fallback to indices in linear order. The filtering steps below
            %% will ensure no new violations are introduced.
            Violated = lists:flatten(find_violations(Ring,
                                                     TargetN)),
            Violated2 = [lists:keyfind(Idx, 2, AllIndices)
                         || Idx <- Violated],
            Indices = Violated2 ++ AllIndices -- Violated2;
        false ->
            %% If we do not have enough nodes to meet target_n, then we prefer
            %% claiming the same indices that would occur during a
            %% re-diagonalization of the ring with target_n nodes, falling
            %% back to linear offsets off these preferred indices when the
            %% number of indices desired is less than the computed set.
            Padding = lists:duplicate(TargetN, undefined),
            Expanded = lists:sublist(Active ++ Padding, TargetN),
            PreferredClaim = riak_core_claim:diagonal_stripe(Ring,
                                                             Expanded),
            PreferredNth = [begin
                                {Nth, Idx} = lists:keyfind(Idx, 2, AllIndices),
                                Nth
                            end
                            || {Idx, Owner} <- PreferredClaim, Owner =:= Node],
            Offsets = lists:seq(0,
                                RingSize div length(PreferredNth)),
            AllNth = lists:sublist([(X + Y) rem RingSize
                                    || Y <- Offsets, X <- PreferredNth],
                                   RingSize),
            Indices = [lists:keyfind(Nth, 1, AllIndices)
                       || Nth <- AllNth]
    end,
    %% Filter out indices that conflict with the node's existing ownership
    Indices2 = prefilter_violations(Ring,
                                    Node,
                                    AllIndices,
                                    Indices,
                                    TargetN,
                                    RingSize),
    %% Claim indices from the remaining candidate set
    Claim = select_indices(Owners,
                           Deltas,
                           Indices2,
                           TargetN,
                           RingSize),
    Claim2 = lists:sublist(Claim, Want),
    NewRing = lists:foldl(fun (Idx, Ring0) ->
                                  riak_core_ring:transfer_node(Idx, Node, Ring0)
                          end,
                          Ring,
                          Claim2),
    RingChanged = [] /= Claim2,
    RingMeetsTargetN = meets_target_n(NewRing, TargetN),
    case {RingChanged, EnoughNodes, RingMeetsTargetN} of
        {false, _, _} ->
            %% Unable to claim, fallback to re-diagonalization
            sequential_claim(Ring, Node, TargetN);
        {_, true, false} ->
            %% Failed to meet target_n, fallback to re-diagonalization
            sequential_claim(Ring, Node, TargetN);
        _ -> NewRing
    end.

%% @private for each node in owners return a tuple of owner and delta
%% where delta is an integer that expresses how many nodes the owner
%% needs it's ownership to change by. A positive means the owner needs
%% that many more partitions, a negative means the owner can lose that
%% many paritions.
-spec get_deltas(RingSize :: pos_integer(),
		 NodeCount :: pos_integer(),
		 Owners :: [{Index :: non_neg_integer(), node()}],
		 Counts :: [{node(), non_neg_integer()}]) -> Deltas ::
								 [{node(),
								   integer()}].

get_deltas(RingSize, NodeCount, Owners, Counts) ->
    Avg = RingSize / NodeCount,
    %% the most any node should own
    Max = ceiling(RingSize / NodeCount),
    ActiveDeltas = [{Member,
                     Count,
                     normalise_delta(Avg - Count)}
                    || {Member, Count} <- Counts],
    BalancedDeltas = rebalance_deltas(ActiveDeltas,
                                      Max,
                                      RingSize),
    add_default_deltas(Owners, BalancedDeltas, 0).

%% @private a node can only claim whole partitions, but if RingSize
%% rem NodeCount /= 0, a delta will be a float. This function decides
%% if that float should be floored or ceilinged
-spec normalise_delta(float()) -> integer().

normalise_delta(Delta) when Delta < 0 ->
    %% if the node has too many (a negative delta) give up the most
    %% you can (will be rebalanced)
    ceiling(abs(Delta)) * -1;
normalise_delta(Delta) ->
    %% if the node wants partitions, ask for the fewest for least
    %% movement
    trunc(Delta).

%% @private so that we don't end up with an imbalanced ring where one
%% node has more vnodes than it should (e.g. [{n1, 6}, {n2, 6}, {n3,
%% 6}, {n4, 8}, {n5,6} we rebalance the deltas so that select_indices
%% doesn't leave some node not giving up enough partitions
-spec rebalance_deltas([{node(), integer()}],
		       pos_integer(), pos_integer()) -> [{node(), integer()}].

rebalance_deltas(NodeDeltas, Max, RingSize) ->
    AppliedDeltas = [Own + Delta
		     || {_, Own, Delta} <- NodeDeltas],
    case lists:sum(AppliedDeltas) - RingSize of
        0 ->
            [{Node, Delta} || {Node, _Cnt, Delta} <- NodeDeltas];
        N when N < 0 -> increase_keeps(NodeDeltas, N, Max, [])
    end.

%% @private increases the delta for (some) nodes giving away
%% partitions to the max they can keep
-spec increase_keeps(Deltas :: [{node(), integer()}],
		     WantsError :: integer(), Max :: pos_integer(),
		     Acc :: [{node(), integer()}]) -> Rebalanced :: [{node(),
								      integer()}].

increase_keeps(Rest, 0, _Max, Acc) ->
    [{Node, Delta}
     || {Node, _Own, Delta}
	    <- lists:usort(lists:append(Rest, Acc))];
increase_keeps([], N, Max, Acc) when N < 0 ->
    increase_takes(lists:reverse(Acc), N, Max, []);
increase_keeps([{Node, Own, Delta} | Rest], N, Max, Acc)
    when Delta < 0 ->
    WouldOwn = Own + Delta,
    Additive = case WouldOwn + 1 =< Max of
                   true -> 1;
                   false -> 0
               end,
    increase_keeps(Rest,
                   N + Additive,
                   Max,
                   [{Node, Own + Delta + Additive} | Acc]);
increase_keeps([NodeDelta | Rest], N, Max, Acc) ->
    increase_keeps(Rest, N, Max, [NodeDelta | Acc]).

%% @private increases the delta for (some) nodes taking partitions to the max
%% they can ask for
-spec increase_takes(Deltas :: [{node(), integer()}],
		     WantsError :: integer(), Max :: pos_integer(),
		     Acc :: [{node(), integer()}]) -> Rebalanced :: [{node(),
								      integer()}].

increase_takes(Rest, 0, _Max, Acc) ->
    [{Node, Delta}
     || {Node, _Own, Delta}
	    <- lists:usort(lists:append(Rest, Acc))];
increase_takes([], N, _Max, Acc) when N < 0 ->
    [{Node, Delta}
     || {Node, _Own, Delta} <- lists:usort(Acc)];
increase_takes([{Node, Own, Delta} | Rest], N, Max, Acc)
    when Delta > 0 ->
    WouldOwn = Own + Delta,
    Additive = case WouldOwn + 1 =< Max of
                   true -> 1;
                   false -> 0
               end,
    increase_takes(Rest,
                   N + Additive,
                   Max,
                   [{Node, Own, Delta + Additive} | Acc]);
increase_takes([NodeDelta | Rest], N, Max, Acc) ->
    increase_takes(Rest, N, Max, [NodeDelta | Acc]).

%% @doc Check if the given ring can provide enough owners for each node to meet
%%      the target NVal.
%% @param Ring Ring to check.
%% @param TargetN NVal to check.
%% @returns Boolean indicating if the ring meets the requirement.
-spec meets_target_n(Ring :: ring(),
		     TargetN :: pos_integer()) -> boolean().

meets_target_n(Ring, TargetN) ->
    Owners = lists:keysort(1,
			   riak_core_ring:all_owners(Ring)),
    meets_target_n(Owners, TargetN, 0, [], []).

%% @private
%% @doc Helper function for {@link meets_target_n/2}.
-spec meets_target_n(Owners :: [{integer(), term()}],
		     TargetN :: pos_integer(), Index :: non_neg_integer(),
		     First :: [{integer(), term()}],
		     Last :: [{integer(), term()}]) -> boolean().

meets_target_n([{Part, Node} | Rest], TargetN, Index,
	       First, Last) ->
    case lists:keytake(Node, 1, Last) of
        {value, {Node, LastIndex, _}, NewLast} ->
            if Index - LastIndex >= TargetN ->
                   %% node repeat respects TargetN
                   meets_target_n(Rest,
                                  TargetN,
                                  Index + 1,
                                  First,
                                  [{Node, Index, Part} | NewLast]);
               true ->
                   %% violation of TargetN
                   false
            end;
        false ->
            %% haven't seen this node yet
            meets_target_n(Rest,
                           TargetN,
                           Index + 1,
                           [{Node, Index} | First],
                           [{Node, Index, Part} | Last])
    end;
meets_target_n([], TargetN, Index, First, Last) ->
    %% start through end guarantees TargetN
    %% compute violations at wrap around, but don't fail
    %% because of them: handle during reclaim
    Violations = lists:filter(fun ({Node, L, _}) ->
				      {Node, F} = proplists:lookup(Node, First),
				      Index - L + F < TargetN
			      end,
			      Last),
    {true, [Part || {_, _, Part} <- Violations]}.

%% @doc Claim diversify tries to build a perfectly diverse ownership list that
%%      meets target N. It uses wants to work out which nodes want partitions,
%%      but does not honor the counts currently.  The algorithm incrementally
%%      builds the ownership list, updating the adjacency matrix needed to
%%      compute the diversity score as each node is added and uses it to drive
%%      the selection of the next nodes.
%% @param Wants List of Node names and the respective number of partition they
%%        want to claim.
%% @param Owners List of indices and the name of their owning node.
%% @param Params Parameters.
%% @returns New owner list and a list of attributes, in this case `diversified'.
-spec claim_diversify(Wants :: [{term(), integer()}],
		      Owners :: [{integer(), term()}],
		      Params :: [term()]) -> {[{integer(), term()}],
					      [atom()]}.

claim_diversify(Wants, Owners, Params) ->
    TN = proplists:get_value(target_n_val,
                             Params,
                             ?DEF_TARGET_N),
    Q = length(Owners),
    Claiming = [N || {N, W} <- Wants, W > 0],
    {ok, NewOwners, _AM} =
        riak_core_claim_util:construct(riak_core_claim_util:gen_complete_len(Q),
                                       Claiming,
                                       TN),
    {NewOwners, [diversified]}.

%% @doc Claim nodes in seq a,b,c,a,b,c trying to handle the wraparound case to
%%      meet target N
%% @param Wants List of Node names and the respective number of partition they
%%        want to claim.
%% @param Owners List of indices and the name of their owning node.
%% @param Params Parameters.
%% @returns Diagonalized list of owners and a list of attributes, in this case
%%          `diagonalized'.
-spec claim_diagonal(Wants :: [{term(), integer()}],
		     Owners :: [{integer(), term()}],
		     Params :: [term()]) -> {[term()], [atom()]}.

claim_diagonal(Wants, Owners, Params) ->
    TN = proplists:get_value(target_n_val,
                             Params,
                             ?DEF_TARGET_N),
    Claiming = lists:sort([N || {N, W} <- Wants, W > 0]),
    S = length(Claiming),
    Q = length(Owners),
    Reps = Q div S,
    %% Handle the ring wrapround case.  If possible try to pick nodes
    %% that are not within the first TN of Claiming, if enough nodes
    %% are available.
    Tail = Q - Reps * S,
    Last = case S >= TN + Tail of
               true -> % If number wanted can be filled excluding first TN nodes
                   lists:sublist(lists:nthtail(TN - Tail, Claiming), Tail);
               _ -> lists:sublist(Claiming, Tail)
           end,
    {lists:flatten([lists:duplicate(Reps, Claiming), Last]),
     [diagonalized]}.

%% @private fall back to diagonal striping vnodes across nodes in a
%% sequential round robin (eg n1 | n2 | n3 | n4 | n5 | n1 | n2 | n3
%% etc) However, different to `claim_rebalance_n', this function
%% attempts to eliminate tail violations (for example a ring that
%% starts/ends n1 | n2 | ...| n3 | n4 | n1)
-spec sequential_claim(riak_core_ring:riak_core_ring(),
		       node(), integer()) -> riak_core_ring:riak_core_ring().

sequential_claim(Ring, Node, TargetN) ->
    Nodes = lists:usort([Node
			 | riak_core_ring:claiming_members(Ring)]),
    NodeCount = length(Nodes),
    RingSize = riak_core_ring:num_partitions(Ring),
    Overhang = RingSize rem NodeCount,
    HasTailViolation = Overhang > 0 andalso
                           Overhang < TargetN,
    Shortfall = TargetN - Overhang,
    CompleteSequences = RingSize div NodeCount,
    MaxFetchesPerSeq = NodeCount - TargetN,
    MinFetchesPerSeq = ceiling(Shortfall /
                                   CompleteSequences),
    CanSolveViolation = CompleteSequences * MaxFetchesPerSeq
                            >= Shortfall,
    Zipped = case HasTailViolation andalso CanSolveViolation
                 of
                 true ->
                     Partitions = lists:sort([I
                                              || {I, _}
                                                     <- riak_core_ring:all_owners(Ring)]),
                     Nodelist = solve_tail_violations(RingSize,
                                                      Nodes,
                                                      Shortfall,
                                                      MinFetchesPerSeq),
                     lists:zip(Partitions, lists:flatten(Nodelist));
                 false -> diagonal_stripe(Ring, Nodes)
             end,
    lists:foldl(fun ({P, N}, Acc) ->
                        riak_core_ring:transfer_node(P, N, Acc)
                end,
                Ring,
                Zipped).

%% @private every module has a ceiling function
-spec ceiling(float()) -> integer().

ceiling(F) ->
    T = trunc(F),
    case F - T == 0 of
        true -> T;
        false -> T + 1
    end.

%% @private rem_fill increase the tail so that there is no wrap around
%% preflist violation, by taking a `Shortfall' number nodes from
%% earlier in the preflist
-spec solve_tail_violations(integer(), [node()],
			    integer(), integer()) -> [node()].

solve_tail_violations(RingSize, Nodes, Shortfall,
		      MinFetchesPerSeq) ->
    StartingNode = RingSize rem length(Nodes) + 1,
    build_nodelist(RingSize,
                   Nodes,
                   Shortfall,
                   StartingNode,
                   MinFetchesPerSeq,
                   []).

%% @private build the node list by building tail to satisfy TargetN, then removing
%% the added nodes from earlier segments
-spec build_nodelist(integer(), [node()], integer(),
		     integer(), integer(), [node()]) -> [node()].

build_nodelist(RingSize, Nodes, _Shortfall = 0,
	       _NodeCounter, _MinFetchesPerSeq, Acc) ->
    %% Finished shuffling, backfill if required
    ShuffledRing = lists:flatten(Acc),
    backfill_ring(RingSize,
                  Nodes,
                  (RingSize - length(ShuffledRing)) div length(Nodes),
                  Acc);
build_nodelist(RingSize, Nodes, Shortfall, NodeCounter,
	       MinFetchesPerSeq, _Acc = []) ->
    %% Build the tail with sufficient nodes to satisfy TargetN
    NodeCount = length(Nodes),
    LastSegLength = RingSize rem NodeCount + Shortfall,
    NewSeq = lists:sublist(Nodes, 1, LastSegLength),
    build_nodelist(RingSize,
                   Nodes,
                   Shortfall,
                   NodeCounter,
                   MinFetchesPerSeq,
                   NewSeq);
build_nodelist(RingSize, Nodes, Shortfall, NodeCounter,
	       MinFetchesPerSeq, Acc) ->
    %% Build rest of list, subtracting minimum of MinFetchesPerSeq, Shortfall
    %% or (NodeCount - NodeCounter) each time
    NodeCount = length(Nodes),
    NodesToRemove = min(min(MinFetchesPerSeq, Shortfall),
                        NodeCount - NodeCounter),
    RemovalList = lists:sublist(Nodes,
                                NodeCounter,
                                NodesToRemove),
    NewSeq = lists:subtract(Nodes, RemovalList),
    NewNodeCounter = NodeCounter + NodesToRemove,
    build_nodelist(RingSize,
                   Nodes,
                   Shortfall - NodesToRemove,
                   NewNodeCounter,
                   MinFetchesPerSeq,
                   [NewSeq | Acc]).

%% @private Backfill the ring with full sequences
-spec backfill_ring(integer(), [node()], integer(),
		    [node()]) -> [node()].

backfill_ring(_RingSize, _Nodes, _Remaining = 0, Acc) ->
    Acc;
backfill_ring(RingSize, Nodes, Remaining, Acc) ->
    backfill_ring(RingSize,
                  Nodes,
                  Remaining - 1,
                  [Nodes | Acc]).

%% @doc Rebalance the expected load on nodes using a diagonal stripe.
%% @param Ring :: Ring to rebalance.
%% @param Node :: Node to rebalance from.
%% @returns Rebalanced ring.
%% @see diagonal_stripe/2.
-spec claim_rebalance_n(Ring :: ring(),
			Node :: term()) -> ring().

claim_rebalance_n(Ring, Node) ->
    Nodes = lists:usort([Node
			 | riak_core_ring:claiming_members(Ring)]),
    Zipped = diagonal_stripe(Ring, Nodes),
    lists:foldl(fun ({P, N}, Acc) ->
                        riak_core_ring:transfer_node(P, N, Acc)
                end,
                Ring,
                Zipped).

%% @doc Creates a diagonal stripw of the given nodes over the partitions of the
%%      ring.
%% @param Ring Ring on which the stripes are built.
%% @param Nodes Nodes that are to be distributed.
%% @returns List of indices and assigned nodes.
-spec diagonal_stripe(Ring :: ring(),
		      Nodes :: [term()]) -> [{integer(), term()}].

diagonal_stripe(Ring, Nodes) ->
    %% diagonal stripes guarantee most disperse data
    Partitions = lists:sort([I
			     || {I, _} <- riak_core_ring:all_owners(Ring)]),
    Zipped = lists:zip(Partitions,
                       lists:sublist(lists:flatten(lists:duplicate(1 +
                                                                       length(Partitions)
                                                                           div
                                                                           length(Nodes),
                                                                   Nodes)),
                                     1,
                                     length(Partitions))),
    Zipped.

%% @doc Choose a random partition for the local node.
%% @param Ring Ring to claim on.
%% @returns Updated ring.
-spec random_choose_claim(Ring :: ring()) -> ring().

random_choose_claim(Ring) ->
    random_choose_claim(Ring, node()).

%% @doc Like {@link random_choose_claim/1} with a specified node.
%% @param Node Node to choose a partition for.
-spec random_choose_claim(Ring :: ring(),
			  Node :: term()) -> ring().

random_choose_claim(Ring, Node) ->
    random_choose_claim(Ring, Node, []).

%% @doc Like {@link random_choose_claim/2} with specified parameters.
%% @param Params List of parameters, currently ignored.
-spec random_choose_claim(Ring :: ring(),
			  Node :: term(), Params :: [term()]) -> ring().

random_choose_claim(Ring, Node, _Params) ->
    riak_core_ring:transfer_node(riak_core_ring:random_other_index(Ring),
                                 Node,
                                 Ring).

%% @doc For use by nodes that should not claim any partitions.
-spec never_wants_claim(ring()) -> no.

never_wants_claim(_) -> no.

%% @doc For use by nodes that should not claim any partitions.
-spec never_wants_claim(ring(), term()) -> no.

never_wants_claim(_, _) -> no.

%% ===================================================================
%% Private
%% ===================================================================

%% @private
%%
%% @doc Determines indices that violate the given target_n spacing
%% property.
find_violations(Ring, TargetN) ->
    Owners = riak_core_ring:all_owners(Ring),
    Suffix = lists:sublist(Owners, TargetN - 1),
    Owners2 = Owners ++ Suffix,
    %% Use a sliding window to determine violations
    {Bad, _} = lists:foldl(fun (P = {Idx, Owner},
                                {Out, Window}) ->
                                   Window2 = lists:sublist([P | Window],
                                                           TargetN - 1),
                                   case lists:keyfind(Owner, 2, Window) of
                                       {PrevIdx, Owner} ->
                                           {[[PrevIdx, Idx] | Out], Window2};
                                       false -> {Out, Window2}
                                   end
                           end,
                           {[], []},
                           Owners2),
    lists:reverse(Bad).

%% @private
%% @doc Counts up the number of partitions owned by each node.
-spec get_counts([node()],
		 [{integer(), _}]) -> [{node(), non_neg_integer()}].

get_counts(Nodes, Ring) ->
    Empty = [{Node, 0} || Node <- Nodes],
    Counts = lists:foldl(fun ({_Idx, Node}, Counts) ->
                                 case lists:member(Node, Nodes) of
                                     true ->
                                         dict:update_counter(Node, 1, Counts);
                                     false -> Counts
                                 end
                         end,
                         dict:from_list(Empty),
                         Ring),
    dict:to_list(Counts).

%% @private
%% @doc Add default delta values for all owners to the delta list.
-spec add_default_deltas(IdxOwners :: [{integer(),
					term()}],
			 Deltas :: [{term(), integer()}],
			 Default :: integer()) -> [{term(), integer()}].

add_default_deltas(IdxOwners, Deltas, Default) ->
    {_, Owners} = lists:unzip(IdxOwners),
    Owners2 = lists:usort(Owners),
    Defaults = [{Member, Default} || Member <- Owners2],
    lists:ukeysort(1, Deltas ++ Defaults).

%% @private
%% @doc Filter out candidate indices that would violate target_n given a node's
%%      current partition ownership.
-spec prefilter_violations(Ring :: ring(),
			   Node :: term(), AllIndices :: [{term(), integer()}],
			   Indices :: [{term(), integer()}],
			   TargetN :: pos_integer(),
			   RingSize :: non_neg_integer()) -> [{term(),
							       integer()}].

prefilter_violations(Ring, Node, AllIndices, Indices,
		     TargetN, RingSize) ->
    CurrentIndices = riak_core_ring:indices(Ring, Node),
    CurrentNth = [lists:keyfind(Idx, 2, AllIndices)
		  || Idx <- CurrentIndices],
    [{Nth, Idx}
     || {Nth, Idx} <- Indices,
	lists:all(fun ({CNth, _}) ->
			  spaced_by_n(CNth, Nth, TargetN, RingSize)
		  end,
		  CurrentNth)].

%% @private
%% @doc Select indices from a given candidate set, according to two
%% goals.
%%
%% 1. Ensure greedy/local target_n spacing between indices. Note that this
%%    goal intentionally does not reject overall target_n violations.
%%
%% 2. Select indices based on the delta between current ownership and
%%    expected ownership. In other words, if A owns 5 partitions and
%%    the desired ownership is 3, then we try to claim at most 2 partitions
%%    from A.
-spec select_indices(Owners :: [],
		     Deltas :: [{term(), integer()}],
		     Indices :: [{term(), integer()}],
		     TargetN :: pos_integer(),
		     RingSize :: pos_integer()) -> [integer()].

select_indices(_Owners, _Deltas, [], _TargetN,
	       _RingSize) ->
    [];
select_indices(Owners, Deltas, Indices, TargetN,
	       RingSize) ->
    OwnerDT = dict:from_list(Owners),
    {FirstNth, _} = hd(Indices),
    %% The `First' symbol indicates whether or not this is the first
    %% partition to be claimed by this node.  This assumes that the
    %% node doesn't already own any partitions.  In that case it is
    %% _always_ safe to claim the first partition that another owner
    %% is willing to part with.  It's the subsequent partitions
    %% claimed by this node that must not break the target_n invariant.
    {Claim, _, _, _} = lists:foldl(fun ({Nth, Idx},
                                        {Out, LastNth, DeltaDT, First}) ->
                                           Owner = dict:fetch(Idx, OwnerDT),
                                           Delta = dict:fetch(Owner, DeltaDT),
                                           MeetsTN = spaced_by_n(LastNth,
                                                                 Nth,
                                                                 TargetN,
                                                                 RingSize),
                                           case (Delta < 0) and
                                                    (First or MeetsTN)
                                               of
                                               true ->
                                                   NextDeltaDT =
                                                       dict:update_counter(Owner,
                                                                           1,
                                                                           DeltaDT),
                                                   {[Idx | Out],
                                                    Nth,
                                                    NextDeltaDT,
                                                    false};
                                               false ->
                                                   {Out,
                                                    LastNth,
                                                    DeltaDT,
                                                    First}
                                           end
                                   end,
                                   {[], FirstNth, dict:from_list(Deltas), true},
                                   Indices),
    lists:reverse(Claim).

%% @private
%% @doc Determine if two positions in the ring meet target_n spacing.
-spec spaced_by_n(Ntha :: integer(), NthB :: integer(),
		  TargetN :: pos_integer(),
		  RingSize :: pos_integer()) -> boolean().

spaced_by_n(NthA, NthB, TargetN, RingSize) ->
    case NthA > NthB of
        true ->
            NFwd = NthA - NthB,
            NBack = NthB - NthA + RingSize;
        false ->
            NFwd = NthA - NthB + RingSize,
            NBack = NthB - NthA
    end,
    (NFwd >= TargetN) and (NBack >= TargetN).

%% @doc For each node in wants, work out how many more partition each node wants
%%      (positive) or is overloaded by (negative) compared to what it owns.
%% @param Wants List of node names and their target number of partitions.
%% @param Owns List of node names and their actual number of partitions.
-spec wants_owns_diff(Wants :: [{term(), integer()}],
		      Owns :: [{term(), integer()}]) -> [{term(), integer()}].

wants_owns_diff(Wants, Owns) ->
    [case lists:keyfind(N, 1, Owns) of
         {N, O} -> {N, W - O};
         false -> {N, W}
     end
     || {N, W} <- Wants].

%% @doc Given a ring, work out how many partition each wants to be
%%      considered balanced.
%% @param Ring Ring to figure out wants for.
%% @returns List of node names and the number of wanted partitions.
-spec wants(Ring :: ring()) -> [{term(), integer()}].

wants(Ring) ->
    Active =
	lists:sort(riak_core_ring:claiming_members(Ring)),
    Inactive = riak_core_ring:all_members(Ring) -- Active,
    Q = riak_core_ring:num_partitions(Ring),
    ActiveWants = lists:zip(Active,
			    wants_counts(length(Active), Q)),
    InactiveWants = [{N, 0} || N <- Inactive],
    lists:sort(ActiveWants ++ InactiveWants).

%% @private
%% @doc Given a number of nodes and ring size, return a list of
%% desired ownership, S long that add up to Q
-spec wants_counts(S :: non_neg_integer(),
		   Q :: non_neg_integer()) -> [integer()].

wants_counts(S, Q) ->
    Max = roundup(Q / S),
    case S * Max - Q of
        0 -> lists:duplicate(S, Max);
        X ->
            lists:duplicate(X, Max - 1) ++
                lists:duplicate(S - X, Max)
    end.

%% @private
%% @doc Round up to next whole integer - ceil
-spec roundup(float()) -> integer().

roundup(I) when I >= 0 ->
    T = erlang:trunc(I),
    case I - T of
        Neg when Neg < 0 -> T;
        Pos when Pos > 0 -> T + 1;
        _ -> T
    end.

%% ===================================================================
%% Unit tests
%% ===================================================================
-ifdef(TEST).

-compile(export_all).

-include_lib("eunit/include/eunit.hrl").

wants_claim_test() ->
    riak_core_ring_manager:setup_ets(test),
    riak_core_test_util:setup_mockring1(),
    {ok, Ring} = riak_core_ring_manager:get_my_ring(),
    ?assertEqual({yes, 1}, (default_wants_claim(Ring))),
    riak_core_ring_manager:cleanup_ets(test),
    riak_core_ring_manager:stop().

%% @private console helper function to return node lists for claiming
%% partitions
-spec gen_diag(pos_integer(), pos_integer()) -> [Node ::
						     atom()].

gen_diag(RingSize, NodeCount) ->
    Nodes = [list_to_atom(lists:concat(["n_", N]))
	     || N <- lists:seq(1, NodeCount)],
    {HeadNode, RestNodes} = {hd(Nodes), tl(Nodes)},
    R0 = riak_core_ring:fresh(RingSize, HeadNode),
    RAdded = lists:foldl(fun (Node, Racc) ->
                                 riak_core_ring:add_member(HeadNode, Racc, Node)
                         end,
                         R0,
                         RestNodes),
    Diag = diagonal_stripe(RAdded, Nodes),
    {_P, N} = lists:unzip(Diag),
    N.

%% @private call with result of gen_diag/1 only, does the list have
%% tail violations, returns true if so, false otherwise.
-spec has_violations([Node :: atom()]) -> boolean().

has_violations(Diag) ->
    RS = length(Diag),
    NC = length(lists:usort(Diag)),
    Overhang = RS rem NC,
    Overhang > 0 andalso
        Overhang < 4. %% hardcoded target n of 4

-endif.
