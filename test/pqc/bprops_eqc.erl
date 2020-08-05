%% -------------------------------------------------------------------
%%
%% Copyright (c) 2016 Basho Technologies, Inc.  All Rights Reserved.
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
-module(bprops_eqc).

%%
%% This module defines a collection of PROPER state_m commands, for
%% testing the riak_core_bucket module.  In order to understand this
%% test, you should understand PROPER generally, and the PROPER state machine
%% testing framework and callback conventions.
%%
%% TODO This module currently tests a limited subset of the
%%      riak_core_bucket module and makes little attempt to
%%      do negative testing around malformed inputs, etc.
%%      More attention needs to be spent on these tests!
%%

-ifdef(PROPER).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

-type bucket_name() :: binary().
-type orddict() :: orddict:orddict().

-define(NAMES, [<<0>>, <<1>>, <<2>>, <<3>>]).
-define(BPROP_KEYS, [foo, bar, tapas]).
-define(DEFAULT_BPROPS, [{n_val, 3}]).
-define(QC_OUT(P),
   proper:on_output(fun(Str, Args) -> io:format(user, Str, Args) end, P)).


%%
%% The state_m "Model".  This invariant represents what properties
%% should be in which buckets between state transitions.
%%
-record(state, {
    buckets = orddict:new() :: orddict()
}).

%%
%% Eunit entrypoints
%%

bprops_test_() -> 
    {timeout,360,
        ?_assert(proper:quickcheck(?QC_OUT(prop_buckets()), [{numtests, 5000}]))
    }.

%%
%% top level drivers (for testing by hand, typically)
%%

run() ->
    run(100).

run(N) ->
    proper:quickcheck(proper:numtests(N, prop_buckets())).

rerun() ->
    proper:check(proper:show_states(prop_buckets())).

cover() ->
    cover(100).

cover(N) ->
    cover:compile_beam(riak_core_bucket),
    proper:quickcheck(proper:numtests(N, prop_buckets())),
    cover:analyse_to_file(riak_core_bucket, [html]).

%%
command(State) ->
    oneof([{call, ?MODULE, set_bucket, set_bucket_args(State)},
           {call, ?MODULE, get_bucket, get_bucket_args(State)}
    ]).

%%
%% eqc_statem initial model
%%

-spec initial_state() -> proper:symbolic_state().
initial_state() ->
    #state{}.

%%
%% set_bucket command
%%

set_bucket_args(_S) ->
    [bucket_name(), bucket_props()].

set_bucket(Bucket, BProps) ->
    riak_core_bucket:set_bucket(Bucket, BProps).

next_state(#state{buckets=Buckets} = S,_Res,{call,?MODULE, set_bucket, [Bucket, BProps]}) ->
%set_bucket_next(#state{buckets=Buckets} = S, _Res, [Bucket, BProps])
    %%
    %% Get any previously defined properties from the model
    %%
    OldBProps =
        case orddict:find(Bucket, Buckets) of
            {ok, Props} -> Props;
            error -> orddict:from_list(?DEFAULT_BPROPS)
        end,
    S#state{
        buckets = orddict:store(
            Bucket,
            %% add defaults and the bucket name; remove any duplicates
            %% bprops takes precedence over defaults, and name is always set
            %% to bucket
            expected_properties(
                Bucket, OldBProps, BProps
            ),
            Buckets
        )
    };
next_state(S,_Res,{call,?MODULE, get_bucket, [_Bucket]}) ->
    S.

-spec expected_properties(bucket_name(), orddict(), orddict()) -> orddict().
expected_properties(Bucket, OldProps, NewProps) ->
    Props = riak_core_bucket_props:merge(NewProps, OldProps),
    orddict:store(name, Bucket, Props).

eq(A,B)->
        A=:=B.
%%
%% get_bucket command
%%

get_bucket_args(_S) ->
    [bucket_name()].

get_bucket(Bucket) ->
    riak_core_bucket:get_bucket(Bucket).

precondition(_S, {call, ?MODULE, _,_})->
    true.
%get_bucket_post(#state{buckets=Buckets}, [Bucket], Res)
postcondition(#state{buckets=Buckets},{call, ?MODULE, get_bucket, [Bucket]}, Res) ->
    BPropsFind = orddict:find(Bucket, Buckets),
    case {Res, BPropsFind} of
        {error, _} ->
            eq(Res, error);
        {_, {ok, BProps}} ->
            eq(
                orddict:from_list(Res),
                orddict:from_list(BProps)
            );
        {_, error} ->
            eq(
                orddict:from_list(Res),
                orddict:from_list(?DEFAULT_BPROPS ++ [{name, Bucket}])
            )
    end;
    
postcondition(#state{buckets=Buckets},{call,?MODULE, set_bucket, [Bucket, _BProps]}, Res) ->
%set_bucket_post(#state{buckets=Buckets}, [Bucket, _BProps], Res)
    case {Res, orddict:find(Bucket, Buckets)} of
        %% first time bucket has been set
        {ok, error} ->
            true;
        %% bucket has been set before
        {ok, {ok, _OldBProps}} ->
            true;
        %% anything other than ok is a failure
        %% TODO revisit, e.g., generate invalid inputs to force an error
        _ ->
            false
    end.


%% TODO Add more commands here

%%
%% generators
%%

bucket_name() ->
    proper_types:elements(?NAMES).

bucket_props() ->
    proper_types:list(bucket_prop()).

bucket_prop() ->
    oneof(
        [
            {n_val, pos_int()},
            {bucket_prop_name(), bucket_prop_value()}
        ]
    ).

pos_int() ->
    ?LET(N, proper_types:nat(), N + 1).

bucket_prop_name() ->
    proper_types:elements(?BPROP_KEYS).

bucket_prop_value() ->
    proper_types:bool().


%%
%% proper properties
%%

prop_buckets() ->
    ?FORALL(Cmds, commands(?MODULE),
        aggregate(command_names(Cmds),
            ?TRAPEXIT(
                begin
                    {_H, _S, Res} =
                    bucket_eqc_utils:per_test_setup(?DEFAULT_BPROPS,
                                                    fun() ->
                                                        run_commands(?MODULE, Cmds)
                                                    end),
                        aggregate(
                            command_names(Cmds),
                            Res == ok
                        )
                end
            )
        )
    ).

-endif.
