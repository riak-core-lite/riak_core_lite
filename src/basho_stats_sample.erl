%% -------------------------------------------------------------------
%%
%% stats: Statistics Suite for Erlang
%%
%% Copyright (c) 2009 Dave Smith (dizzyd@dizzyd.com)
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
-module(basho_stats_sample).

-export([new/0,
         update/2,
         update_all/2,
         count/1,
         min/1,
         mean/1,
         max/1,
         variance/1,
         sdev/1,
         summary/1]).

-include("stats.hrl").

-ifdef(EQC).

-export([prop_main/0]).

-endif.

-record(state, {n = 0, min = 'NaN', max = 'NaN', sum = 0, sum2 = 0}).

%% ===================================================================
%% Public API
%% ===================================================================

new() ->
    #state{}.

update(Value, State) ->
    State#state{n = State#state.n + 1,
                min = nan_min(Value, State#state.min),
                max = nan_max(Value, State#state.max),
                sum = State#state.sum + Value,
                sum2 = State#state.sum2 + Value * Value}.

update_all(Values, State) ->
    lists:foldl(fun (Value, S) ->
                        update(Value, S)
                end,
                State,
                Values).

count(State) ->
    State#state.n.

min(State) ->
    State#state.min.

mean(#state{n = 0}) ->
    'NaN';
mean(State) ->
    State#state.sum / State#state.n.

max(State) ->
    State#state.max.

variance(#state{n = N}) when N < 2 ->
    'NaN';
variance(State) ->
    SumSq = State#state.sum * State#state.sum,
    (State#state.sum2 - SumSq / State#state.n) / (State#state.n - 1).

sdev(State) ->
    case variance(State) of
      'NaN' ->
          'NaN';
      Value ->
          math:sqrt(Value)
    end.

summary(State) ->
    {min(State), mean(State), max(State), variance(State), sdev(State)}.

%% ===================================================================
%% Internal functions
%% ===================================================================

nan_min(V1, 'NaN') ->
    V1;
nan_min('NaN', V1) ->
    V1;
nan_min(V1, V2) ->
    erlang:min(V1, V2).

nan_max(V1, 'NaN') ->
    V1;
nan_max('NaN', V1) ->
    V1;
nan_max(V1, V2) ->
    erlang:max(V1, V2).

%% ===================================================================
%% Unit Tests
%% ===================================================================

-ifdef(EUNIT).

simple_test() ->
    %% A few hand-checked values
    {1, 3.0, 5, 2.5, 1.5811388300841898} = summary(update_all([1, 2, 3, 4, 5], new())),
    {1, 5.5, 10, 15.0, 3.872983346207417} = summary(update_all(lists:seq(1, 10, 3), new())).

empty_test() ->
    {'NaN', 'NaN', 'NaN', 'NaN', 'NaN'} = summary(new()).

-ifdef(EQC).

lists_equal([], []) ->
    true;
lists_equal([V1 | R1], [V2 | R2]) ->
    case abs(V1 - V2) < 0.01 of
      true ->
          lists_equal(R1, R2);
      false ->
          false
    end.

prop_main() ->
    ?FORALL(Xlen,
            choose(2, 100),
            ?LET(Xs,
                 vector(Xlen, int()),
                 lists_equal(basho_stats_utils:r_run(Xs,
                                                     "c(min(x), mean(x), max(x),\n                               "
                                                     "                      var(x), sd(x))"),
                             tuple_to_list(summary(update_all(Xs, new())))))).

qc_test() ->
    true = eqc:quickcheck(prop_main()).

-endif.
-endif.
