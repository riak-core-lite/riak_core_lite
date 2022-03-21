
%% -------------------------------------------------------------------
%%
%% A dummey gen_event listener for testing.
%%
%% Copyright (c) 2015 Basho Technologies, Inc.  All Rights Reserved.
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

-module(dummy_evt).

-behaviour(gen_event).

%%% ------------------------------------------------------------------
%%% gen_event Function Exports
%%% ------------------------------------------------------------------

-export([code_change/3]).
-export([handle_call/2]).
-export([handle_event/2]).
-export([handle_info/2]).
-export([init/1]).
-export([terminate/2]).

-record(state, {}).

%%% ------------------------------------------------------------------
%%% gen_event Function Definitions
%%% ------------------------------------------------------------------

init(_) ->
    {ok, #state{}}.

handle_event(_Event, State) ->
    {ok, State}.

handle_call(_Request, State) ->
    Reply = ok,
    {ok, Reply, State}.

handle_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
