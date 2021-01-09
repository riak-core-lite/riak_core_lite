%% -------------------------------------------------------------------
%%
%% chash_eqc: QuickCheck tests for the chash module.
%%
%% Copyright (c) 2007-2011 Basho Technologies, Inc.  All Rights Reserved.
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

%% @doc  QuickCheck tests for the chash module

-module(chash_eqc).

-ifdef(PROPER).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(NOTEST, true).
-define(NOASSERT, true).

-define(TEST_ITERATIONS, 5000).
-define(QC_OUT(P),
        proper:on_output(fun(Str, Args) -> io:format(user, Str, Args) end, P)).
-define(RINGTOP, hash:max_integer() - 1).

-export([test/0,
         test/1]).

%%====================================================================
%% eunit test
%%====================================================================

eqc_test_() ->
    {inparallel,
     [{spawn,
       [{setup,
         fun setup/0,
         fun cleanup/1,
         [
          %% Run the quickcheck tests
          {timeout, 60000, % timeout is in msec
           %% Indicate the number of test iterations for each property here
           ?_assertEqual(true,
                         proper:quickcheck(?QC_OUT(prop_chash_next_index()),[{numtests,?TEST_ITERATIONS}]))
          }
         ]
        }
       ]
      }
     ]
    }.

setup() ->
    %% Remove the logger noise.
    error_logger:tty(false),
    %% Uncomment the following lines to send log output to files.
    %% error_logger:logfile({open, "chash_eqc.log"}),

    %% TODO: Perform any required setup
    ok.

cleanup(_) ->
    %% TODO: Perform any required cleanup
    ok.

%% ====================================================================
%% eqc property
%% ====================================================================

%% TODO This test case is deprecated.
prop_chash_next_index() ->
%%     ?FORALL(
%%        {PartitionExponent, Delta},
%%        {g_partition_exponent(), int()},
%%        ?TRAPEXIT(
%%           begin
%%               %% Calculate the number of paritions
%%               NumPartitions = trunc(math:pow(2, PartitionExponent)),
%%               %% Calculate the integer indexes around the ring
%%               %% for the number of partitions.
%%               Inc = ?RINGTOP div NumPartitions,
%%               Indexes = [Inc * X || X <- lists:seq(0, NumPartitions-1)],
%%               %% Create a chash tuple to use for calls to chash:successors/2
%%               %% and chash:next_index/2.
%%               %% The node value is not used and so just use the default
%%               %% localhost node value.
%%               Node = 'riak@127.0.0.1',
%%               CHash = {[{Index, Node} || Index <- Indexes], stale},
%%               %% For each index around the ring add Delta to
%%               %% the index value and collect the results from calling
%%               %% chash:successors/2 and chash:next_index/2 for comparison.
%%               Results =
%%                   [{element(
%%                       1,
%%                       hd(chash:successors(hash:as_binary(((Index + Delta) + ?RINGTOP)
%%                                              rem ?RINGTOP),
%%                                           CHash))),
%%                     chash:next_index((((Index + Delta) + ?RINGTOP) rem ?RINGTOP),
%%                                      CHash)} ||
%%                       Index <- Indexes],
%%               {ExpectedIndexes, ActualIndexes} = lists:unzip(Results),
%%               ?WHENFAIL(
%%                  begin
%%                      io:format("ExpectedIndexes: ~p AcutalIndexes: ~p~n",
%%                                [ExpectedIndexes, ActualIndexes])
%%                  end,
%%                  conjunction(
%%                    [
%%                     {results, equals(ExpectedIndexes, ActualIndexes)}
%%                    ]))
%%           end
%%          )).
    true.

%%====================================================================
%% Generators
%%====================================================================

g_partition_exponent() ->
    choose(1, 12).

%%====================================================================
%% Helpers
%%====================================================================

test() ->
    test(100).

test(N) ->
    proper:quickcheck(numtests(N, prop_chash_next_index())).

% check() ->
%     check(prop_chash_next_index(), current_counterexample()).

-endif. % EQC
