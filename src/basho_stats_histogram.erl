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
-module(basho_stats_histogram).

-export([new/3, update/2, update_all/2, quantile/2,
	 counts/1, observations/1, summary_stats/1]).

-ifdef(EQC).

-export([prop_count/0, prop_quantile/0]).

-endif.

-include("stats.hrl").

-record(hist,
	{n = 0, min, max, bin_scale, bin_step, bins, capacity,
	 stats}).

%% ===================================================================
%% Public API
%% ===================================================================

new(MinVal, MaxVal, NumBins) ->
    #hist{min = MinVal, max = MaxVal,
	  bin_scale = NumBins / (MaxVal - MinVal),
	  bin_step = (MaxVal - MinVal) / NumBins,
	  bins = gb_trees:empty(), capacity = NumBins,
	  stats = basho_stats_sample:new()}.

%%
%% Update the histogram with a new observation.
%%
%% NOTE: update/2 caps values within #hist.min and #hist.max;
%% if you provide a value outside those boundaries the first or last
%% bin, respectively, get updated and the histogram is consequently
%% skewed.
%%
update(Value, Hist) ->
    Bin = which_bin(Value, Hist),
    case gb_trees:lookup(Bin, Hist#hist.bins) of
      {value, Counter} -> ok;
      none -> Counter = 0
    end,
    Hist#hist{n = Hist#hist.n + 1,
	      bins = gb_trees:enter(Bin, Counter + 1, Hist#hist.bins),
	      stats =
		  basho_stats_sample:update(Value, Hist#hist.stats)}.

update_all(Values, Hist) ->
    lists:foldl(fun (Value, H) -> update(Value, H) end,
		Hist, Values).

%%
%% Estimate the quantile from the histogram. Quantile should be a value
%% between 0 and 1. Returns 'NaN' if the histogram is currently empty.
%%
quantile(_Quantile, #hist{n = 0}) -> 'NaN';
quantile(Quantile, Hist)
    when Quantile > 0; Quantile < 1 ->
    %% Sort out how many complete samples we need to satisfy the
    %%requested quantile
    MaxSamples = Quantile * Hist#hist.n,
    %% Now iterate over the bins, until we have gathered enough samples
    %% to satisfy the request. The resulting bin is an estimate.
    Itr = gb_trees:iterator(Hist#hist.bins),
    case quantile_itr(gb_trees:next(Itr), 0, MaxSamples) of
      max -> Hist#hist.max;
      EstBin ->
	  %% We have an estimated bin -- determine the lower bound of said
	  %% bin
	  Hist#hist.min + EstBin / Hist#hist.bin_scale
    end.

%%
%% Get the counts for each bin in the histogram
%%
counts(Hist) ->
    [bin_count(I, Hist)
     || I <- lists:seq(0, Hist#hist.capacity - 1)].

%%
%% Number of observations that are present in this histogram
%%
observations(Hist) -> Hist#hist.n.

%%
%% Return basic summary stats for this histogram
%%
summary_stats(Hist) ->
    basho_stats_sample:summary(Hist#hist.stats).

%% ===================================================================
%% Internal functions
%% ===================================================================

which_bin(Value, Hist) ->
    Bin = trunc((Value - Hist#hist.min) *
		  Hist#hist.bin_scale),
    Lower = Hist#hist.min + Bin * Hist#hist.bin_step,
    Upper = Hist#hist.min + (Bin + 1) * Hist#hist.bin_step,
    if Value > Upper ->
	   erlang:min(Bin + 1, Hist#hist.capacity - 1);
       Value =< Lower -> erlang:max(Bin - 1, 0);
       Value == Hist#hist.max -> Hist#hist.capacity - 1;
       true -> Bin
    end.

quantile_itr(none, _Samples, _MaxSamples) -> max;
quantile_itr({Bin, Counter, Itr2}, Samples,
	     MaxSamples) ->
    Samples2 = Samples + Counter,
    if Samples2 < MaxSamples ->
	   %% Not done yet, move to next bin
	   quantile_itr(gb_trees:next(Itr2), Samples2, MaxSamples);
       true ->
	   %% We only need some of the samples in this bin; we make
	   %% the assumption that values within the bin are uniformly
	   %% distributed.
	   Bin + (MaxSamples - Samples) / Counter
    end.

bin_count(Bin, Hist) ->
    case gb_trees:lookup(Bin, Hist#hist.bins) of
      {value, Count} -> Count;
      none -> 0
    end.

%% ===================================================================
%% Unit Tests
%% ===================================================================

-ifdef(EUNIT).

simple_test() ->
    %% Pre-calculated tests
    [7, 0] = counts(update_all([10, 10, 10, 10, 10, 10, 14],
			       new(10, 18, 2))).

-ifdef(EQC).

qc_count_check(Min, Max, Bins, Xs) ->
    LCounts = counts(update_all(Xs, new(Min, Max, Bins))),
    RCounts = basho_stats_utils:r_run(Xs,
				      ?FMT("hist(x, seq(~w,~w,length.out=~w), plot=FALSE)"
					   "$counts",
					   [Min, Max, Bins + 1])),
    case LCounts == RCounts of
      true -> true;
      _ ->
	  io:format("LCounts ~p, RCounts ~p~n",
		    [LCounts, RCounts]),
	  false
    end.

prop_count() ->
    ?FORALL({Min, Bins, Xlen},
	    {choose(0, 99), choose(2, 20), choose(2, 100)},
	    (?LET(Max, (choose(Min + 1, 100)),
		  (?LET(Xs, (vector(Xlen, choose(Min, Max))),
			(?WHENFAIL(begin
				     io:format("Min ~p, Max ~p, Bins ~p, Xs ~w~n",
					       [Min, Max, Bins, Xs]),
				     Command =
					 (?FMT("hist(x, seq(~w,~w,length.out=~w), plot=FALSE)"
					       "$counts",
					       [Min, Max, Bins + 1])),
				     InputStr = [integer_to_list(I) || I <- Xs],
				     io:format(?FMT("x <- c(~s)\n",
						    [string:join(InputStr,
								 ",")])),
				     io:format(?FMT("write(~s, ncolumns=1,file=stdout())\n",
						    [Command]))
				   end,
				   (qc_count_check(Min, Max, Bins, Xs))))))))).

qc_count_test() -> true = eqc:quickcheck(prop_count()).

qc_quantile_check(Q, Min, Max, Bins, Xs) ->
    Hist = new(Min, Max, Bins),
    LCounts = counts(update_all(Xs, Hist)),
    Lq = quantile(Q * 0.01, update_all(Xs, Hist)),
    [Rq] = basho_stats_utils:r_run(Xs,
				   ?FMT("quantile(x, ~4.2f, type=4)",
					[Q * 0.01])),
    case abs(Lq - Rq) < 1 of
      true -> true;
      false ->
	  ?debugMsg("----\n"),
	  ?debugFmt("Q: ~p Min: ~p Max: ~p Bins: ~p\n",
		    [Q, Min, Max, Bins]),
	  ?debugFmt("Lq: ~p != Rq: ~p\n", [Lq, Rq]),
	  ?debugFmt("Xs: ~w\n", [Xs]),
	  false
    end.

prop_quantile() ->
    %% Loosey-goosey checking of the quantile estimation
    %%    against R's more precise method.
    %%
    %% To ensure a minimal level of accuracy,
    %%  we ensure that we have between 50-200 bins
    %% and between 100-500 data points.
    %%
    %% TODO: Need to nail down the exact error bounds
    %%
    %% XXX since we try to generate the quantile from the histogram, not the
    %% original data, our results and Rs don't always agree and this means the
    %% test will occasionally fail. There's not an easy way to fix this.
    ?FORALL({Min, Bins, Xlen, Q},
	    {choose(1, 99), choose(50, 200), choose(100, 500),
	     choose(0, 100)},
	    (?LET(Max, (choose(Min + 1, 100)),
		  (?LET(Xs, (vector(Xlen, choose(Min, Max))),
			(?WHENFAIL(begin
				     io:format("Min ~p, Max ~p, Bins ~p, Q ~p, Xs ~w~n",
					       [Min, Max, Bins, Q, Xs]),
				     Command =
					 (?FMT("quantile(x, ~4.2f, type=4)",
					       [Q * 0.01])),
				     InputStr = [integer_to_list(I) || I <- Xs],
				     io:format(?FMT("x <- c(~s)\n",
						    [string:join(InputStr,
								 ",")])),
				     io:format(?FMT("write(~s, ncolumns=1,file=stdout())\n",
						    [Command]))
				   end,
				   (qc_quantile_check(Q, Min, Max, Bins,
						      Xs))))))))).

qc_quantile_test() ->
    true = eqc:quickcheck(prop_quantile()).

-endif.

-endif.
