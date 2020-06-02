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
-module(basho_stats_rv).

-export([uniform/0, exponential/1, poisson/1, normal/2]).

%% ====================================================================
%% Public API
%% ====================================================================

%%
%% Generates a uniformly-distributed random variable (wrapper for convenience)
%%
uniform() ->
    rand:uniform().

%%
%% Generates an exponential-distributed random variable, using inverse function
%%
exponential(Lambda) ->
    -math:log(rand:uniform()) / Lambda.

%%
%% Generates a Poisson-distributed random variable by summing exponential rvs
%% (May be slow!!).
%%
poisson(Lambda) ->
    poisson_rv_loop(Lambda, 0.0, -1).

%%
%% Generates a Normal-distributed random variable, using Box-Muller method
%%
normal(Mean, Sigma) ->
    Rv1 = rand:uniform(),
    Rv2 = rand:uniform(),
    Rho = math:sqrt(-2 * math:log(1 - Rv2)),
    Rho * math:cos(2 * math:pi() * Rv1) * Sigma + Mean.

%% ====================================================================
%% Internal functions
%% ====================================================================

poisson_rv_loop(Lambda, Sum, N) when Sum < Lambda ->
    poisson_rv_loop(Lambda, Sum - math:log(rand:uniform()), N + 1);
poisson_rv_loop(_Lambda, _Sum, N) ->
    N.
