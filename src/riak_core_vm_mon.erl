%% -*- mode: erlang; erlang-indent-level: 4; indent-tabs-mode: nil -*-
%% -------------------------------------------------------------------
%%
%% Copyright (c) 2024 Workday, Inc.
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
%%
%% @doc Reports VM statistics.
%%
%% This is a separate module to allow for future expansion into a `gen_server'
%% monitoring VM stats and reporting when they exceed threshholds, possibly
%% with the ability to shut Riak down gracefully before the VM crashes due to
%% hitting a hard limit.
%%
-module(riak_core_vm_mon).

%% Public API
-export([
    vm_stats/0
]).

%% Public Types
%% Values are just aliases for integer ranges given descriptive names.
-export_type([
    vm_atom_count/0, vm_atom_limit/0, vm_atom_pct/0,
    vm_ets_count/0,  vm_ets_limit/0,  vm_ets_pct/0,
    vm_port_count/0, vm_port_limit/0, vm_port_pct/0,
    vm_proc_count/0, vm_proc_limit/0, vm_proc_pct/0,
    vm_stat_count/0, vm_stat_limit/0, vm_stat_pct/0,
    vm_stats/0
]).

-type vm_stats() :: {
    vm_atom_limit(), vm_atom_count(), vm_atom_pct(),
    vm_ets_limit(),  vm_ets_count(),  vm_ets_pct(),
    vm_port_limit(), vm_port_count(), vm_port_pct(),
    vm_proc_limit(), vm_proc_count(), vm_proc_pct()
}.

-type vm_stat_count()   :: non_neg_integer().
-type vm_stat_limit()   :: pos_integer().
-type vm_stat_pct()     :: 0..100.

-type vm_atom_count()   ::  vm_stat_count().
-type vm_atom_limit()   ::  vm_stat_limit().
-type vm_atom_pct()     ::  vm_stat_pct().
-type vm_ets_count()    ::  vm_stat_count().
-type vm_ets_limit()    ::  vm_stat_limit().
-type vm_ets_pct()      ::  vm_stat_pct().
-type vm_port_count()   ::  vm_stat_count().
-type vm_port_limit()   ::  vm_stat_limit().
-type vm_port_pct()     ::  vm_stat_pct().
-type vm_proc_count()   ::  vm_stat_count().
-type vm_proc_limit()   ::  vm_stat_limit().
-type vm_proc_pct()     ::  vm_stat_pct().

-include_lib("kernel/include/logger.hrl").
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% ===================================================================
%% Public API
%% ===================================================================

-spec vm_stats() -> vm_stats().
%% @doc Returns the current VM stats in a flat tuple.
%%
%% The result tuple contains three values for classes of Atoms, ETS tables,
%% Ports, and Processes, in that order.
%% For each class, the three integers are Limit, Count, and PercentUsed.
%% @end
%% Several approaches have been implemented and timed, with and without
%% caching constant values in the process dictionary; this is the fastest.
vm_stats() ->
    AtomLimit = erlang:system_info(atom_limit),
    AtomCount = erlang:system_info(atom_count),
    EtsLimit  = erlang:system_info(ets_limit),
    EtsCount  = erlang:system_info(ets_count),
    PortLimit = erlang:system_info(port_limit),
    PortCount = erlang:system_info(port_count),
    ProcLimit = erlang:system_info(process_limit),
    ProcCount = erlang:system_info(process_count),
    %% PercentUsed are calculated with a faster integer arithmetic
    %% equivalent of:
    %%  erlang:round((Count * 100) / Limit)
    %% Counter-intuitively, (Limit div 2) is consistently very slightly
    %% faster than (Limit bsr 1); not digging into why but I suspect
    %% parameter range checking.
    AtomPct = (((AtomCount * 100) + (AtomLimit div 2)) div AtomLimit),
    EtsPct  = (((EtsCount  * 100) + (EtsLimit  div 2)) div EtsLimit ),
    PortPct = (((PortCount * 100) + (PortLimit div 2)) div PortLimit),
    ProcPct = (((ProcCount * 100) + (ProcLimit div 2)) div ProcLimit),
    %% Calculating the percentages into discrete values above appears to be
    %% slightly faster than doing it inside the tuple construction.
    %% The difference is small but consistent; not digging further to figure
    %% out why though I suspect JIT inlining behavior to be the root cause.
    {
        AtomLimit, AtomCount, AtomPct, EtsLimit,  EtsCount,  EtsPct,
        PortLimit, PortCount, PortPct, ProcLimit, ProcCount, ProcPct
    }.

%% ===================================================================
%% Tests
%% ===================================================================

-ifdef(TEST).

-define(STATS_LMT_OFF,  0).
-define(STATS_CNT_OFF,  1).
-define(STATS_PCT_OFF,  2).

-define(ATOM_REC_POS,   1).
-define(ETS_REC_POS,    4).
-define(PORT_REC_POS,   7).
-define(PROC_REC_POS,   10).

-define(STATS_LEN,      12).
-define(STATS_REC_POS,  [
    ?ATOM_REC_POS, ?ETS_REC_POS, ?PORT_REC_POS, ?PROC_REC_POS]).

vm_stats_test() ->
    Stats0 = vm_stats(),
    validate_stats(Stats0),

    %% Make some new atoms to ensure the count increases.
    % R will be in the range 100000001..200000000
    % random numbers in atoms will be 9 digits in the range (R+1)..(R*2)
    R = (100000000 + rand:uniform(100000000)),
    NewAtoms = [
        erlang:list_to_atom(lists:concat(
            [?FUNCTION_NAME, "_", [$a + C], "_", (R + rand:uniform(R))]))
        || C <- lists:seq(0, 7)],

    Stats1 = vm_stats(),
    validate_stats(Stats1),
    lists:foreach(
        fun(Pos) ->
            LimP = (Pos + ?STATS_LMT_OFF),
            CntP = (Pos + ?STATS_CNT_OFF),
            PctP = (Pos + ?STATS_PCT_OFF),
            ?assertEqual(
                erlang:element(LimP, Stats1), erlang:element(LimP, Stats0)),
            ?assert(
                erlang:element(CntP, Stats1) >= erlang:element(CntP, Stats0)),
            ?assert(
                erlang:element(PctP, Stats1) >= erlang:element(PctP, Stats0))
        end, ?STATS_REC_POS),

    AtomCntP = (?ATOM_REC_POS + ?STATS_CNT_OFF),
    AtomCnt0 = erlang:element(AtomCntP, Stats0),
    AtomCnt1 = erlang:element(AtomCntP, Stats1),
    ?assertEqual(AtomCnt1, (AtomCnt0 + erlang:length(NewAtoms))).

validate_stats(Stats) ->
    ?assert(erlang:is_tuple(Stats)),
    ?assertEqual(?STATS_LEN, erlang:tuple_size(Stats)),
    lists:foreach(
        fun(Pos) ->
            ?assert(erlang:is_integer(erlang:element(Pos, Stats)))
        end, lists:seq(1, ?STATS_LEN)),
    lists:foreach(
        fun(Pos) ->
            Lmt = erlang:element((Pos + ?STATS_LMT_OFF), Stats),
            Cnt = erlang:element((Pos + ?STATS_CNT_OFF), Stats),
            Pct = erlang:element((Pos + ?STATS_PCT_OFF), Stats),
            ?assert(Lmt > 0),
            ?assert(Cnt >= 0 andalso Lmt >= Cnt),
            ?assert(Pct >= 0 andalso 100 >= Pct)
        end, ?STATS_REC_POS).

-endif. % ?TEST
