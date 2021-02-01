%% -------------------------------------------------------------------
%%
%% riak_core: Core Riak Application
%%
%% Copyright (c) 2007-2010 Basho Technologies, Inc.  All Rights Reserved.
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

-module(riak_core_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

%% @doc Callback to start the riak_core_lite application. This starts all
%%      neccessary processes and needs to be executed before operating the
%%      system.
%% @param StartType ignored.
%% @param StartArgs ignored.
%% Returns `{ok, Pid}' if the start was succesful, otherwise `{error, Reason}'.
-spec start(StartType :: application:start_type(),
	    StartArgs :: term()) -> {ok, pid()} | {error, term()}.

start(_StartType, _StartArgs) ->
    ok = validate_ring_state_directory_exists(),
    start_riak_core_sup().

%% @doc Callback to stop the riak_core_lite application.
%% @param State ignored.
%% @returns `ok'.
-spec stop(State :: term()) -> ok.

stop(_State) ->
    logger:info("Stopped application riak_core", []),
    ok.

%% @doc Start all application dependencies and try to read the ring directory.
%% @returns `ok' if the directory exists and can be written to.
%% @throws {error, invalid_ring_state_dir}
-spec validate_ring_state_directory_exists() -> ok.

validate_ring_state_directory_exists() ->
    riak_core_util:start_app_deps(riak_core),
    {ok, RingStateDir} = application:get_env(riak_core,
					     ring_state_dir),
    case filelib:ensure_dir(filename:join(RingStateDir,
					  "dummy"))
	of
	ok -> ok;
	{error, RingReason} ->
	    logger:critical("Ring state directory ~p does not exist, "
			    "and could not be created: ~p",
			    [RingStateDir,
			     riak_core_util:posix_error(RingReason)]),
	    throw({error, invalid_ring_state_dir})
    end.

%% @doc Start the riak_core supervisor and register the ring event handler.
%% @returns `{ok, Pid}' when the start was successful, `{error, Reason}'
%%          otherwise.
%% @see riak_core_sup:init/1.
-spec start_riak_core_sup() -> {ok, pid()} |
			       {error, term()}.

start_riak_core_sup() ->
    %% Spin up the supervisor; prune ring files as necessary
    case riak_core_sup:start_link() of
	{ok, Pid} ->
	    ok = register_applications(),
	    ok = add_ring_event_handler(),
	    {ok, Pid};
	{error, Reason} -> {error, Reason}
    end.

%% @doc Currently NoOp.
-spec register_applications() -> ok.

register_applications() -> ok.

%% @doc Add a standard handler to ring events.
-spec add_ring_event_handler() -> ok.

add_ring_event_handler() ->
    ok =
	riak_core_ring_events:add_guarded_handler(riak_core_ring_handler,
						  []).
