-module(riak_core_claim_util_qc).

-ifdef(TEST).

-ifdef(PROPER).

-include_lib("proper/include/proper.hrl").

-include_lib("eunit/include/eunit.hrl").

%-compile(export_all).

property_adjacency_summary_test_() ->
    {timeout,
     120,
     ?_test((proper:quickcheck(prop_adjacency_summary(),
                               [{numtest, 5000}])))}.

longer_list(K, G) ->
    ?SIZED(Size,
           (proper_types:resize(trunc(K * Size),
                                list(proper_types:resize(Size, G))))).

%% Compare directly constructing the adjacency matrix against
%% one using prepend/fixup.
prop_adjacency_summary() ->
    ?FORALL({OwnersSeed, S},
            {non_empty(longer_list(40, proper_types:largeint())),
             ?LET(X, (proper_types:int()), (1 + abs(X)))},
            begin
                Owners = [list_to_atom("n" ++
                                           integer_to_list(1 + abs(I) rem S))
                          || I <- OwnersSeed],
                AM = riak_core_claim_util:adjacency_matrix(Owners),
                AS = riak_core_claim_util:summarize_am(AM),
                {Owners2, _DAM2, FixDAM2} = build(Owners),
                AS2 =
                    riak_core_claim_util:summarize_am(dict:to_list(FixDAM2)),
                ?WHENFAIL(begin
                              io:format(user,
                                        "S=~p\nOwners =~p\n",
                                        [S, Owners]),
                              io:format(user, "=== AM ===\n~p\n", [AM]),
                              io:format(user,
                                        "=== FixAM2 ===\n~p\n",
                                        [dict:to_list(FixDAM2)]),
                              io:format(user, "=== AS2 ===\n~p\n", [AS2])
                          end,
                          (proper:conjunction([{owners, Owners == Owners2},
                                               {am2,
                                                lists:sort(AS) ==
                                                    lists:sort(AS2)}])))
            end).

build(Owners) ->
    build(lists:usort(Owners),
          lists:reverse(Owners),
          [],
          dict:new()).

build(_M, [], Owners, DAM) ->
    {Owners,
     DAM,
     riak_core_claim_util:fixup_dam(Owners, DAM)};
build(M, [N | Rest], Owners, DAM) ->
    {Owners1, DAM1} = riak_core_claim_util:prepend(M,
                                                   N,
                                                   Owners,
                                                   DAM),
    build(M, Rest, Owners1, DAM1).

-endif.

-endif.
