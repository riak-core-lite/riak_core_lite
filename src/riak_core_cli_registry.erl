%% -------------------------------------------------------------------
%%
%% Copyright (c) 2014 Basho Technologies, Inc.
%% Copyright (c) 2025 Workday, Inc.
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
%% @doc This module tracks registrations for clique integrations.

-module(riak_core_cli_registry).

-define(CLI_MODULES, [
                      riak_core_cluster_cli,
                      riak_core_handoff_cli
                     ]).

-export([
         register_node_finder/0,
         register_cli/0,
         load_schema/0
        ]).

-spec register_node_finder() -> true.
register_node_finder() ->
    F = fun() ->
                {ok, MyRing} = riak_core_ring_manager:get_my_ring(),
                riak_core_ring:all_members(MyRing)
        end,
    clique:register_node_finder(F).

-spec register_cli() -> ok.
register_cli() ->
    clique:register(?CLI_MODULES),
    clique:register_config(["vnode_overload_threshold"], fun set_vnode_proxy_overload_config/2),
    clique:register_config(["vnode_check_request_interval"], fun set_vnode_proxy_overload_config/2),
    clique:register_config(["vnode_check_interval"], fun set_vnode_proxy_overload_config/2),
    register_config_whitelist().

set_vnode_proxy_overload_config([Key], ValueStr) when Key =:= "vnode_overload_threshold";
                                                      Key =:= "vnode_check_request_interval";
                                                      Key =:= "vnode_check_interval" ->
    Key1 = list_to_atom(Key),
    Value = list_to_integer(ValueStr),
    ProxySpecs = supervisor:which_children(riak_core_vnode_proxy_sup),
    [
        {ok, Value} = riak_core_vnode_proxy:update_overload_config({Mod, Index}, Key1, Value)
        || {{Mod, Index},_,_,_} <- ProxySpecs
    ],

    "".

-spec register_config_whitelist() -> ok.
register_config_whitelist() ->
    ok = clique:register_config_whitelist(["vnode_overload_threshold",
                                           "vnode_check_request_interval",
                                           "vnode_check_interval"]).

-spec load_schema() -> ok.
load_schema() ->
    case application:get_env(riak_core, schema_dirs) of
        {ok, Directories} ->
            ok = clique_config:load_schema(Directories);
        _ ->
            ok = clique_config:load_schema([code:lib_dir()])
    end.
