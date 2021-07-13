%% -------------------------------------------------------------------
%%
%% Copyright (c) 2011 Basho Technologies, Inc.
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

-module(riak_core_handoff_listener_sup).

-behaviour(supervisor).

%% beahvior functions
-export([start_link/0, init/1]).

-define(CHILD(I, Type),
        {I,
         {I, start_link, []},
         permanent,
         brutal_kill,
         Type,
         [I]}).

%% @doc Begin the supervisor, init/1 will be called
%% @see supervisor:start_link/3.
-spec start_link() -> {ok, pid()} |
                      {error,
                       {already_started, pid()} |
                       {shutdown | reason} |
                       term()} |
                      ignore.

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @private
%% @doc Callback for {@link supervisor:start_link/3}. Starts the
%%      {@link riak_core_handoff_listener} as its supervised child.
%% @see riak_core_handoff_listener:start_link/0.
%% @returns Parameters to start the supervised child.
-spec init([]) -> {ok,
                   {{one_for_one, 10, 10},
                    [{riak_core_handoff_listener,
                      {riak_core_handoff_listener, start_link, []}, permanent,
                      brutal_kill, worker,
                      [riak_core_handoff_listener]}, ...]}}.

init([]) ->
    {ok,
     {{one_for_one, 10, 10},
      [?CHILD(riak_core_handoff_listener, worker)]}}.
