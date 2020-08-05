%%% @author Russell Brown <russell@wombat.me>
%%% @copyright (C) 2017, Russell Brown
%%% @doc
%%%
%%% @end
%%% Created :  5 Jun 2017 by Russell Brown <russell@wombat.me>

-module(riak_core_claim_statem).

-ifdef(PROPER).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(CLAIMANT, node_0).

-compile(export_all).

%Entry Eunit
claim_test_()->
    {timeout, 120,
        ?_assert(proper:quickcheck(prop_claim(with_ring_size(5)),[{numtests, 5000}] ))}.

%% -- State ------------------------------------------------------------------
-record(state,
        {
          ring_size,
          nodes=[?CLAIMANT] :: [atom()], %% nodes that have been added
          node_counter=1 :: non_neg_integer(), %% to aid with naming nodes
          ring = undefined,
          committed_nodes = []
        }).

%% @doc run the statem with a ring of size `math:pow(`N', 2)'.
-spec with_ring_size(pos_integer()) -> proper_statem:symbolic_state().
with_ring_size(N) ->
    RingSize = trunc(math:pow(2, N)),
    #state{ring_size=RingSize, ring=riak_core_ring:fresh(RingSize, ?CLAIMANT)}.

%% @doc Returns the state in which each test case starts. (Unless a different
%%      initial state is supplied explicitly to, e.g. commands/2.)
-spec initial_state_data() -> proper_statem:symbolic_state().
initial_state_data() ->
    #state{}.

initial_state(_S) ->
    starting.

starting(S) ->
    [{planning, {call, ?MODULE, add_node, add_node_args(S)}}].

planning(S) ->
    [{planning, {call, ?MODULE, add_node, add_node_args(S)}},
     {planning, {call, ?MODULE, leave_node, leave_node_args(S)}}%,
     %{claiming, {call, ?MODULE, claim, claim_args(S)}} %TODO 
    ].

claiming(S) ->
    [{planning, {call, ?MODULE, add_node, add_node_args(S)}},
     {planning, {call, ?MODULE, leave_node, leave_node_args(S)}}].

%% -- Operations -------------------------------------------------------------

%% --- Operation: preconditions ---
%% @doc add_node_pre/1 - Precondition for generation
%add_node_pre(_From, _To, S=#state{nodes=Nodes}) 
precondition(_F,_T,S=#state{nodes=Nodes}, {call, _, add_node, _}) when
      (S#state.ring_size div length(Nodes)) =< 3  ->
    false;
%add_node_pre(_From, _To, _) ->
precondition(_F,_T,_S, {call, _, add_node, _}) ->
    true;
%% @doc leave_node_pre/1 - Precondition for generation
%leave_node_pre(_From, _To, #state{nodes=Nodes}) when length(Nodes) < 5 ->
precondition(_F,_T,#state{nodes=Nodes},{call,_,leave_node,_}) when length(Nodes) < 5 ->
    false;
%leave_node_pre(_From, _To, _) ->
precondition(_F,_T,_S, {call,_,leave_node,_})->
    true;
%leave_node_pre(_From, _To, #state{nodes=Nodes}, [Node, _Ring]) ->
precondition(_F,_T,#state{nodes=Nodes},{call,_,leave_node,[Node, _Ring]}) ->
    lists:member(Node, Nodes);
precondition(_F,_T,_S,{call,_,leave_node,_}) ->
    false;
% @doc claim_pre/3 - Precondition for generation
%-spec claim_pre(_From, _To, S :: proper:symbolic_state()) -> boolean().
%claim_pre(_From, _To, #state{ring=undefined}) ->
precondition(_F,_T,#state{ring=undefined},{call, _, claim,_}) ->
    false;
%claim_pre(_From, _To, _S) ->
precondition(_F,_T,_S,{call,_ , claim, _}) ->
    true.

%% --- Operation: Next state ---
%% @doc add_node_next - Next state function
% -spec add_node_next(_From, _To, S, Var, Args) -> NewS
%     when S    :: proper:symbolic_state() | proper:dynamic_state(),
%          Var  :: proper:var() | term(),
%          Args :: [term()],
%          NewS :: proper:symbolic_state() | proper:dynamic_state().
%add_node_next(_From, _To, S=#state{node_counter=NC, nodes=Nodes}, Ring, [Node, _RingIn]) ->
next_state_data(_F,_T,S=#state{node_counter=NC, nodes=Nodes}, Ring,
            {call,_, add_node, [Node, _RingIn]}) ->
    S#state{ring=Ring, node_counter=NC+1, nodes=[Node | Nodes]};

%% @doc leave_node_next - Next state function
% -spec leave_node_next(_From, _To, S, Var, Args) -> NewS
%     when S    :: proper:symbolic_state() | proper:dynamic_state(),
%          Var  :: proper:var() | term(),
%          Args :: [term()],
%          NewS :: proper:symbolic_state() | proper:dynamic_state().
next_state_data(_F,_T,S=#state{committed_nodes=Committed, nodes=Nodes},Ring,{call, _, leave_node, [Node, _RingIn]}) ->
    S#state{ring=Ring, committed_nodes=lists:delete(Node , Committed), nodes=lists:delete(Node, Nodes)};

%% @doc claim_next - Next state function
% -spec claim_next(_From, _To, S, Var, Args) -> NewS
%     when S    :: proper:symbolic_state() | proper:dynamic_state(),
%          Var  :: proper:var() | term(),
%          Args :: [term()],
%          NewS :: proper:symbolic_state() | proper:dynamic_state().
%claim_next(_From, _To, S=#state{nodes=Nodes}, NewRing, [_OldRing]) ->
next_state_data(_F,_T,S=#state{nodes=Nodes}, NewRing, {call, _, claim, [_OldRing]}) ->
    S#state{ring=NewRing, committed_nodes=Nodes}.

%% --- Operation: postconditions ---
%% @doc add_node_post - Postcondition for add_node
% -spec add_node_post(_From, _To, S, Args, Res) -> true | term()
%     when S    :: proper:dynamic_state(),
%          Args :: [term()],
%          Res  :: term().
%add_node_post(_Frim, _To, _S, [NodeName, _Ring], NextRing) ->
postcondition(_F,_T,_S,{call,_, add_node, [NodeName, _Ring]}, NextRing) ->
    lists:member(NodeName, riak_core_ring:members(NextRing, [joining]));

%% @doc leave_node_post - Postcondition for leave_node
% -spec leave_node_post(_From, _To, S, Args, Res) -> true | term()
%     when S    :: proper:dynamic_state(),
%          Args :: [term()],
%          Res  :: term().
postcondition(_F,_T,_S,{call,_,leave_node,[NodeName, _Ring]}, NextRing) ->
    lists:member(NodeName, riak_core_ring:members(NextRing, [leaving]));

%% @doc claim_post - Postcondition for claim
% -spec claim_post(_From, _To, S, Args, Res) -> true | term()
%     when S    :: proper:dynamic_state(),
%          Args :: [term()],
%          Res  :: term().
%claim_post(_From, _To, #state{nodes=Nodes}, [_Ring], _NewRing) when length(Nodes) < 4 ->
postcondition(_F,_T,#state{nodes=Nodes}, {call, _, claim, [_Ring]}, _NewRing) when length(Nodes) < 4 -> 
   true;
%claim_post(_From, _To, _S, [_Ring], NewRing) ->
postcondition(_F,_T,_S, {call, _, claim, [_Ring]}, NewRing)->
    Nval = 3,
    TNval = 4,
    Preflists = riak_core_ring:all_preflists(NewRing, Nval),
    ImperfectPLs = orddict:to_list(
                     lists:foldl(fun(PL,Acc) ->
                                         PLNodes = lists:usort([N || {_,N} <- PL]),
                                         case length(PLNodes) of
                                             Nval ->
                                                 Acc;
                                             _ ->
                                                 ordsets:add_element(PL, Acc)
                                         end
                                 end, [], Preflists)),

    case {riak_core_claim:meets_target_n(NewRing, TNval),
          ImperfectPLs,
          riak_core_claim:balanced_ring(ring_size(NewRing),
                                        node_count(NewRing), NewRing)} of
        {{true, []}, [], true} ->
            true;
        {X, Y, Z} ->
            {ring_size(NewRing), node_count(NewRing),
             {{meets_target_n, X},
              {perfect_pls, Y},
              {balanced_ring, Z}}}
    end.

%% --- Operation: main functions ---
%% @doc add_node_args - Argument generator
% -spec add_node_args(From, To, S) -> proper:gen([term()])
%    when From :: proper:state_name(),
%         To   :: proper:state_name(),
%         S    :: proper:symbolic_state().
add_node_args(#state{node_counter=NC, ring=Ring}) ->
    %% TODO consider re-adding removed nodes
    %io:fwrite("~n", NC),
    [list_to_atom("node_" ++ integer_to_list(NC)), Ring].

%% @doc add_node - The actual operation
add_node(NodeName, Ring) ->
    R = riak_core_ring:add_member(?CLAIMANT, Ring, NodeName),
    R.

%% --- Operation: leave_node ---
%% @doc leave_node_args - Argument generator
% -spec leave_node_args(From, To, S) -> proper:gen([term()])
%    when From :: proper:state_name(),
%         To   :: proper:state_name(),
%         S    :: proper:symbolic_state().
leave_node_args(#state{nodes=Nodes, ring=Ring}) ->
    %% TODO consider re-leaveing leaved nodes
    [elements(Nodes), Ring].
%% @doc leave_node - The actual operation
leave_node(NodeName, Ring) ->
    R = riak_core_ring:leave_member(?CLAIMANT, Ring, NodeName),
    R.
%% --- Operation: claim ---
%% @doc claim_args - Argument generator
%-spec claim_args(S :: proper:symbolic_state()) -> proper:gen([term()]).
%claim_args(_From, _To, #state{ring=Ring}) ->
claim_args(#state{ring=Ring}) ->
    [Ring].
%% @doc claim - The actual operation
claim(Ring) ->
    R =riak_core_claim:claim(Ring, {riak_core_claim, wants_claim_v2}, {riak_core_claim, choose_claim_v2}),
    R.

%% -- Property ---------------------------------------------------------------
%% @doc <i>Optional callback</i>, Invariant, checked for each visited state
%%      during test execution.

%% @doc Default generated property
-spec prop_claim(proper_statem:symbolic_state()) -> proper:property().
prop_claim(InitialState) ->
    ?FORALL(Cmds, proper_fsm:commands(?MODULE, {starting, InitialState}), 
            begin
                {_H, {_FinalStateName, S}, Res} = proper_fsm:run_commands(?MODULE, Cmds),
                Ring = S#state.ring,
                aggregate(command_names(Cmds),
                    measure(ring_size, ring_size(Ring),
                        measure(node_count, node_count(Ring),
                           Res == ok)))
            end).

ring_size(undefined) ->
    0;
ring_size(Ring) ->
    riak_core_ring:num_partitions(Ring).

node_count(undefined) ->
    0;
node_count(Ring) ->
    length(riak_core_ring:members(Ring, [joining, valid])).

weight(_From, _To, add_node, _Args) ->
    5;
weight(_, _, _, _) ->
    1.

%% eunit stuff
-define(QC_OUT(P),
        proper:on_output(fun(Str, Args) -> io:format(user, Str, Args) end, P)).

eqc_check(File, Prop) ->
    {ok, Bytes} = file:read_file(File),
    CE = binary_to_term(Bytes),
    proper:check(Prop, CE).

%% Helpers
transfer_ring(Ring) ->
    Owners = riak_core_ring:all_owners(Ring),
    RFinal = lists:foldl(fun({Idx, Owner}, Racc) ->
                                 riak_core_ring:transfer_node(Idx, Owner, Racc) end,
                         Ring, Owners),
    RFinal.



-endif.
