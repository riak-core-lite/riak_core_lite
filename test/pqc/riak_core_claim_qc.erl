-module(riak_core_claim_qc).
-ifdef(TEST).
-ifdef(PROPER).

-compile(export_all).
-export([prop_claim_ensures_unique_nodes/1, prop_wants/0, prop_wants_counts/0, eqc_check/2]).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(QC_OUT(P),
        proper:on_output(fun(Str, Args) -> io:format(user, Str, Args) end, P)).

-define(POW_2(N), trunc(math:pow(2, N))).

eqc_check(File, Prop) ->
    {ok, Bytes} = file:read_file(File),
    CE = binary_to_term(Bytes),
    proper:check(Prop, CE).

test_nodes(Count) ->
    [node() | [list_to_atom(lists:concat(["n_", N])) || N <- lists:seq(1, Count-1)]].

test_nodes(Count, StartNode) ->
    [list_to_atom(lists:concat(["n_", N])) || N <- lists:seq(StartNode, StartNode + Count)].

property_claim_ensures_unique_nodes_v2_test_() ->
    Prop = ?QC_OUT(prop_claim_ensures_unique_nodes(choose_claim_v2)),
    {timeout, 120, fun() -> ?_assert(proper:quickcheck(Prop, [{numtests, 5000}])) end}.

property_claim_ensures_unique_nodes_adding_groups_v2_test_() ->
    Prop = ?QC_OUT(prop_claim_ensures_unique_nodes_adding_groups(choose_claim_v2)),
    {timeout, 120, fun() -> ?_assert(proper:quickcheck(Prop, [{numtests, 5000}])) end}.

property_claim_ensures_unique_nodes_adding_singly_v2_test_() ->
    Prop = ?QC_OUT(prop_claim_ensures_unique_nodes_adding_singly(choose_claim_v2)),
    {timeout, 120, fun() -> ?_assert(proper:quickcheck(Prop, [{numtests, 5000}])) end}.

prop_claim_ensures_unique_nodes(ChooseFun) ->
    %% NOTE: We know that this doesn't work for the case of {_, 3}.
    %% NOTE2: uses undocumented "double_shrink", is expensive, but should get
    %% around those case where we shrink to a non-minimal case because
    %% some intermediate combinations of ring_size/node have no violations
    ?FORALL({PartsPow, NodeCount}, {choose(4, 9), choose(4, 15)},
                begin
                Nval = 3,
                TNval = Nval + 1,
                _Params = [{target_n_val, TNval}],

                Partitions = ?POW_2(PartsPow),
                [Node0 | RestNodes] = test_nodes(NodeCount),

                R0 = riak_core_ring:fresh(Partitions, Node0),
                RAdded = lists:foldl(fun(Node, Racc) ->
                                             riak_core_ring:add_member(Node0, Racc, Node)
                                     end, R0, RestNodes),

                Rfinal = riak_core_claim:claim(RAdded, {?MODULE, wants_claim_v2}, {?MODULE, ChooseFun}),

                Preflists = riak_core_ring:all_preflists(Rfinal, Nval),
                ImperfectPLs = orddict:to_list(
                           lists:foldl(fun(PL, Acc) ->
                                               PLNodes = lists:usort([N || {_, N} <- PL]),
                                               case length(PLNodes) of
                                                   Nval ->
                                                       Acc;
                                                   _ ->
                                                       ordsets:add_element(PL, Acc)
                                               end
                                       end, [], Preflists)),

                ?WHENFAIL(
                   begin
                       io:format(user, "{Partitions, Nodes} {~p, ~p}~n",
                                 [Partitions, NodeCount]),
                       io:format(user, "Owners: ~p~n",
                                 [riak_core_ring:all_owners(Rfinal)])
                   end,
                   conjunction([{meets_target_n,
                                 equals({true, []},
                                    riak_core_claim:meets_target_n(Rfinal, TNval))},
                                {perfect_preflists, equals([], ImperfectPLs)},
                                {balanced_ring, balanced_ring(Partitions, NodeCount, Rfinal)}]))
            end).


prop_claim_ensures_unique_nodes_adding_groups(ChooseFun) ->
    %% NOTE: We know that this doesn't work for the case of {_, 3}.
    %% NOTE2: uses undocumented "double_shrink", is expensive, but should get
    %% around those case where we shrink to a non-minimal case because
    %% some intermediate combinations of ring_size/node have no violations
    ?FORALL({PartsPow, BaseNodes, AddedNodes},
            {choose(4, 9), choose(2, 10), choose(2, 5)},
            begin
                Nval = 3,
                TNval = Nval + 1,
                _Params = [{target_n_val, TNval}],

                Partitions = ?POW_2(PartsPow),
                [Node0 | RestNodes] = test_nodes(BaseNodes),
                AddNodes = test_nodes(AddedNodes-1, BaseNodes),
                NodeCount = BaseNodes + AddedNodes,
                %% io:format("Base: ~p~n",[[Node0 | RestNodes]]),
                %% io:format("Added: ~p~n",[AddNodes]),

                R0 = riak_core_ring:fresh(Partitions, Node0),
                RBase = lists:foldl(fun(Node, Racc) ->
                                             riak_core_ring:add_member(Node0, Racc, Node)
                                     end, R0, RestNodes),

                Rinterim = riak_core_claim:claim(RBase, {?MODULE, wants_claim_v2}, {?MODULE, ChooseFun}),
                RAdded = lists:foldl(fun(Node, Racc) ->
                                             riak_core_ring:add_member(Node0, Racc, Node)
                                     end, Rinterim, AddNodes),

                Rfinal = riak_core_claim:claim(RAdded, {?MODULE, wants_claim_v2}, {?MODULE, ChooseFun}),

                Preflists = riak_core_ring:all_preflists(Rfinal, Nval),
                ImperfectPLs = orddict:to_list(
                           lists:foldl(fun(PL, Acc) ->
                                               PLNodes = lists:usort([N || {_, N} <- PL]),
                                               case length(PLNodes) of
                                                   Nval ->
                                                       Acc;
                                                   _ ->
                                                       ordsets:add_element(PL, Acc)
                                               end
                                       end, [], Preflists)),

                ?WHENFAIL(
                   begin
                       io:format(user, "{Partitions, Nodes} {~p, ~p}~n",
                                 [Partitions, NodeCount]),
                       io:format(user, "Owners: ~p~n",
                                 [riak_core_ring:all_owners(Rfinal)])
                   end,
                   conjunction([{meets_target_n,
                                 equals({true, []},
                                 riak_core_claim:meets_target_n(Rfinal, TNval))},
                                {perfect_preflists, equals([], ImperfectPLs)},
                                {balanced_ring, balanced_ring(Partitions, NodeCount, Rfinal)}]))
            end).


prop_claim_ensures_unique_nodes_adding_singly(ChooseFun) ->
    %% NOTE: We know that this doesn't work for the case of {_, 3}.
    %% NOTE2: uses undocumented "double_shrink", is expensive, but should get
    %% around those case where we shrink to a non-minimal case because
    %% some intermediate combinations of ring_size/node have no violations
    ?FORALL({PartsPow, NodeCount}, {choose(4, 9), choose(4, 15)},
            begin
                Nval = 3,
                TNval = Nval + 1,
                Params = [{target_n_val, TNval}],

                Partitions = ?POW_2(PartsPow),
                [Node0 | RestNodes] = test_nodes(NodeCount),

                R0 = riak_core_ring:fresh(Partitions, Node0),
                Rfinal = lists:foldl(fun(Node, Racc) ->
                                             Racc0 = riak_core_ring:add_member(Node0, Racc, Node),
                                             %% TODO which is it? Claim or ChooseFun??
                                             %%claim(Racc0, {?MODULE, wants_claim_v2},
                                             %%             {?MODULE, ChooseFun})
                                             ?MODULE:ChooseFun(Racc0, Node, Params)
                                     end, R0, RestNodes),
                Preflists = riak_core_ring:all_preflists(Rfinal, Nval),
                ImperfectPLs = orddict:to_list(
                           lists:foldl(fun(PL, Acc) ->
                                               PLNodes = lists:usort([N || {_, N} <- PL]),
                                               case length(PLNodes) of
                                                   Nval ->
                                                       Acc;
                                                   _ ->
                                                       ordsets:add_element(PL, Acc)
                                               end
                                       end, [], Preflists)),

                ?WHENFAIL(
                   begin
                       io:format(user, "{Partitions, Nodes} {~p, ~p}~n",
                                 [Partitions, NodeCount]),
                       io:format(user, "Owners: ~p~n",
                                 [riak_core_ring:all_owners(Rfinal)])
                   end,
                   conjunction([{meets_target_n,
                                 equals({true, []},
                                 riak_core_claim:meets_target_n(Rfinal, TNval))},
                                {perfect_preflists, equals([], ImperfectPLs)},
                                {balanced_ring, balanced_ring(Partitions, NodeCount, Rfinal)}]))
            end).



%% @private check that no node claims more than it should
-spec balanced_ring(RingSize::integer(), NodeCount::integer(),
                    riak_core_ring:riak_core_ring()) ->
                           boolean().
balanced_ring(RingSize, NodeCount, Ring) ->
    TargetClaim = riak_core_claim:ceiling(RingSize / NodeCount),
    MinClaim = RingSize div NodeCount,
    AllOwners0 = riak_core_ring:all_owners(Ring),
    AllOwners = lists:keysort(2, AllOwners0),
    {BalancedMax, AccFinal} = lists:foldl(fun({_Part, Node}, {_Balanced, [{Node, Cnt} | Acc]})
                                        when Cnt >= TargetClaim ->
                                             {false, [{Node, Cnt+1} | Acc]};
                                        ({_Part, Node}, {Balanced, [{Node, Cnt} | Acc]}) ->
                                             {Balanced, [{Node, Cnt+1} | Acc]};
                                        ({_Part, NewNode}, {Balanced, Acc}) ->
                                             {Balanced, [{NewNode, 1} | Acc]}
                                     end,
                                     {true, []},
                                     AllOwners),
    BalancedMin = lists:all(fun({_Node, Cnt}) -> Cnt >= MinClaim end, AccFinal),
    case BalancedMax andalso BalancedMin of
        true ->
            true;
        false ->
            {TargetClaim, MinClaim, lists:sort(AccFinal)}
    end.


wants_counts_test() ->
    {timeout, 120,
    ?assert(proper:quickcheck(?QC_OUT((prop_wants_counts())), [{numtests, 5000}]))}.

prop_wants_counts() ->
    ?FORALL({S, Q}, {large_pos(100), large_pos(100000)},
            begin
                Wants = riak_core_claim:wants_counts(S, Q),
                conjunction([{len, S == length(Wants)},
                             {sum, Q == lists:sum(Wants)}])
            end).

wants_test() ->
    {timeout, 120,
    ?_assert(proper:quickcheck(?QC_OUT(prop_wants()), [{numtests, 5000}]))}.

prop_wants() ->
    ?FORALL({NodeStatus, Q},
            {?SUCHTHAT(L, non_empty(list(elements([leaving, joining]))),
                       lists:member(joining, L)),
             ?LET(X, choose(1, 16), trunc(math:pow(2, X)))},
            begin
                R0 = riak_core_ring:fresh(Q, tnode(1)),
                {_, R2, Active} =
                    lists:foldl(
                      fun(S, {I, R1, A1}) ->
                              N = tnode(I),
                              case S of
                                  joining ->
                                      {I+1, riak_core_ring:add_member(N, R1, N), [N|A1]};
                                  _ ->
                                      {I+1, riak_core_ring:leave_member(N, R1, N), A1}
                              end
                      end, {1, R0, []}, NodeStatus),
                Wants = riak_core_claim:wants(R2),

                %% Check any non-claiming nodes are set to 0
                %% Check all nodes are present
                {ActiveWants, InactiveWants} =
                    lists:partition(fun({N, _W}) -> lists:member(N, Active) end, Wants),

                ActiveSum = lists:sum([W || {_, W} <- ActiveWants]),
                InactiveSum = lists:sum([W || {_, W} <- InactiveWants]),
                ?WHENFAIL(
                   begin
                       io:format(user, "NodeStatus: ~p\n", [NodeStatus]),
                       io:format(user, "Active: ~p\n", [Active]),
                       io:format(user, "Q: ~p\n", [Q]),
                       io:format(user, "Wants: ~p\n", [Wants]),
                       io:format(user, "ActiveWants: ~p\n", [ActiveWants]),
                       io:format(user, "InactiveWants: ~p\n", [InactiveWants])
                   end,
                   conjunction([{wants, length(Wants) == length(NodeStatus)},
                                {active, Q == ActiveSum},
                                {inactive, 0 == InactiveSum}]))
            end).

%% Large positive integer between 1 and Max
large_pos(Max) ->
    ?LET(X, largeint(), 1 + (abs(X) rem Max)).


tnode(I) ->
    list_to_atom("n" ++ integer_to_list(I)).

%% Check that no node gained more than it wanted to take
%% Check that none of the nodes took more partitions than allowed
%% Check that no nodes violate target N
check_deltas(Exchanges, Before, After, Q, TN) ->
    conjunction(
      lists:flatten(
        [begin
             Gave = length(OIdxs1 -- OIdxs2), % in original and not new
             Took = length(OIdxs2 -- OIdxs1),
             V1 = count_violations(OIdxs1, Q, TN),
             V2 = count_violations(OIdxs2, Q, TN),
             [{{give, Node, Gave, Give}, Gave =< Give},
              {{take, Node, Took, Take}, Took =< Take},
              {{valid, Node, V1, V2},
               V2 == 0 orelse
               V1 > 0 orelse % check no violations if there were not before
               OIdxs1 == []}] % or the node held no indices so violation was impossible
         end || {{Node, Give, Take, _CIdxs}, {Node, _Want1, OIdxs1}, {Node, _Want2, OIdxs2}} <-
                    lists:zip3(lists:sort(Exchanges), lists:sort(Before), lists:sort(After))])).

count_violations([], _Q, _TN) ->
    0;
count_violations(Idxs, Q, TN) ->
    SOIdxs = lists:sort(Idxs),
    {_, Violations} = lists:foldl(
                        fun(This, {Last, Vs}) ->
                                case Last - This >= TN of
                                    true ->
                                        {This, Vs};
                                    _ ->
                                        {This, Vs + 1}
                                end
                        end, {Q + hd(SOIdxs), 0}, lists:reverse(SOIdxs)),
    Violations.

-endif. % EQC
-endif. % TEST
