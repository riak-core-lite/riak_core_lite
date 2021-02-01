%% -------------------------------------------------------------------
%%
%% Riak: A lightweight, decentralized key-value store.
%%
%% Copyright (c) 2007-2015 Basho Technologies, Inc.  All Rights Reserved.
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
-module(riak_core).

-export([stop/0,
	 stop/1,
	 join/1,
	 join/4,
	 staged_join/1,
	 remove/1,
	 down/1,
	 leave/0,
	 remove_from_cluster/1]).

-export([vnode_modules/0, health_check/1]).

-export([register/1, register/2]).

-export([stat_mods/0, stat_prefix/0]).

-export([add_guarded_event_handler/3,
	 add_guarded_event_handler/4]).

-export([delete_guarded_event_handler/3]).

-export([wait_for_application/1, wait_for_service/1]).

-compile({no_auto_import, [{register, 2}]}).

-define(WAIT_PRINT_INTERVAL, 60 * 1000).

-define(WAIT_POLL_INTERVAL, 100).

%% @doc Stop the riak core lite application and the calling process.
-spec stop() -> ok.

stop() -> stop("riak stop requested").

-ifdef(TEST).

%% @doc Stop the riak core lite application with a given reason without halting
%%      the node for testing purposes.
%% @param Reason Reason to be logged on stop.
%% @returns `ok'.
-spec stop(Reason :: term()) -> ok.

stop(Reason) ->
    logger:notice("~p", [Reason]),
    % if we're in test mode, we don't want to halt the node, so instead
    % we just stop the application.
    application:stop(riak_core).

-else.

%% @doc Stop the riak core lite application with a given reason.
%% @param Reason Reason to be logged on stop.
%% @returns `ok'.
-spec stop(Reason :: term()) -> ok.

stop(Reason) ->
    % we never do an application:stop because that makes it very hard
    %  to really halt the runtime, which is what we need here.
    logger:notice("~p", [Reason]),
    init:stop().

-endif.

%% @doc Join the ring found on the specified remote node.
%% @param Node Remote node owning the ring to join.
%% @returns `ok' on successful join, `{error, Reason}' otherwise.
-spec join(Node :: node()) -> ok |
			      {error,
			       self_join |
			       not_reachable |
			       unable_to_get_join_ring |
			       node_still_starting |
			       not_single_node |
			       different_ring_sizes}.

join(Node) -> join(Node, false).

%% @doc Join the remote cluster without automatically claiming ring
%%      ownership. Used to stage a join in the newer plan/commit
%%      approach to cluster administration.
%% @param Node Remote node with the ring to join.
%% @returns `ok' on successful join, `{error, Reason}' otherwise.
%% @see riak_core_claimant.
-spec staged_join(Node :: node()) -> ok |
				     {error,
				      self_join |
				      not_reachable |
				      unable_to_get_join_ring |
				      node_still_starting |
				      not_single_node |
				      different_ring_sizes}.

staged_join(Node) -> join(Node, false).

%% @doc Like {@link join/1} with a flag indicaiting automatically claiming ring
%%      ownership.
%% @param Auto Boolean indicating if the node automatically claims ring
%%        ownership.
-spec join(NodeStr :: atom() | string(),
	   Auto :: boolean()) -> ok |
				 {error,
				  self_join |
				  not_reachable |
				  unable_to_get_join_ring |
				  node_still_starting |
				  not_single_node |
				  different_ring_sizes}.

join(NodeStr, Auto) when is_list(NodeStr) ->
    join(riak_core_util:str_to_node(NodeStr), Auto);
join(Node, Auto) when is_atom(Node) ->
    join(node(), Node, Auto).

%% @doc Like {@link join/2} with the joining node as an additional parameter.
%%      Check if a self-join is happening, and assures the joining node is the
%%      local node.
%% @param JoiningNode Node that joins the cluster.
-spec join(JoiningNode :: node(), JoinedNode :: node(),
	   Auto :: boolean()) -> ok |
				 {error,
				  self_join |
				  not_reachable |
				  unable_to_get_join_ring |
				  node_still_starting |
				  not_single_node |
				  different_ring_sizes}.

join(Node, Node, _) -> {error, self_join};
join(_, Node, Auto) -> join(node(), Node, false, Auto).

%% @doc Like {@link join/3} with a flag to mark a rejoin. Check if the remote
%%      node is reachable.
%% @param Rejoin Boolean to mark if this is a rejoin.
-spec join(JoiningNode :: node(), JoinedNode :: node(),
	   Rejoin :: boolean(), Auto :: boolean()) -> ok |
						      {error,
						       not_reachable |
						       unable_to_get_join_ring |
						       node_still_starting |
						       not_single_node |
						       different_ring_sizes}.

join(_, Node, Rejoin, Auto) ->
    case net_adm:ping(Node) of
	pang -> {error, not_reachable};
	pong -> standard_join(Node, Rejoin, Auto)
    end.

%% @private
%% @doc Retrieve the remote ring via RPC.
%% @param Node Remote node which got the ring.
%% @returns The remote ring or `badrpc, rpc_process_down' if the rpc fails.
%% @see riak_core_util:safe_rpc/4.
-spec get_other_ring(Node :: node()) -> {ok,
					 riak_core_ring:riak_core_ring()} |
					{badrpc, rpc_process_down}.

get_other_ring(Node) ->
    riak_core_util:safe_rpc(Node,
			    riak_core_ring_manager,
			    get_raw_ring,
			    []).

%% @private
%% @doc Join the ring of the given node locally and distribute the new ring.
%% @param Node Remote node wich got the ring.
%% @param Rejoin Boolean indicating if this is a rejoin.
%% @param Auto Boolean indicating if this node automatically claims ring
%%        ownership.
%% @returns `ok' on successful join, `{error, Reason}' otherwise.
-spec standard_join(Node :: node(), Rejoin :: boolean(),
		    Auto :: boolean()) -> ok |
					  {error,
					   not_reachable |
					   unable_to_get_join_ring |
					   node_still_starting |
					   not_single_node |
					   different_ring_sizes}.

standard_join(Node, Rejoin, Auto) when is_atom(Node) ->
    case net_adm:ping(Node) of
	pong ->
	    case get_other_ring(Node) of
		{ok, Ring} -> standard_join(Node, Ring, Rejoin, Auto);
		_ -> {error, unable_to_get_join_ring}
	    end;
	pang -> {error, not_reachable}
    end.

%% @private
%% @doc `init:get_status/0' will return a 2-tuple reflecting the init
%% status on this node; the first element is one of `starting',
%% `started', or `stopping'. We only want to allow join actions if all
%% applications have finished starting to avoid ring status race
%% conditions.
-spec init_complete(Status :: {init:internal_status(),
			       term()}) -> boolean().

init_complete({started, _}) -> true;
init_complete(_) -> false.

%% @private
%% @doc Like {@link standard_join/3} with the remote ring already as a
%%      parameter.
%% @param Ring Ring retrieved from the remote node.
-spec standard_join(Node :: node(),
		    Ring :: riak_core_ring:riak_core_ring(),
		    Rejoin :: boolean(), Auto :: boolean()) -> ok |
							       {error,
								node_still_starting |
								not_single_node |
								different_ring_sizes}.

standard_join(Node, Ring, Rejoin, Auto) ->
    {ok, MyRing} = riak_core_ring_manager:get_raw_ring(),
    InitComplete = init_complete(init:get_status()),
    SameSize = riak_core_ring:num_partitions(MyRing) =:=
		   riak_core_ring:num_partitions(Ring),
    Singleton = [node()] =:=
		    riak_core_ring:all_members(MyRing),
    case {InitComplete, Rejoin or Singleton, SameSize} of
	{false, _, _} -> {error, node_still_starting};
	{_, false, _} -> {error, not_single_node};
	{_, _, false} -> {error, different_ring_sizes};
	_ ->
	    Ring2 = riak_core_ring:add_member(node(), Ring, node()),
	    Ring3 = riak_core_ring:set_owner(Ring2, node()),
	    Ring4 = riak_core_ring:update_member_meta(node(),
						      Ring3,
						      node(),
						      gossip_vsn,
						      2),
	    Ring5 = Ring4,
	    Ring6 = maybe_auto_join(Auto, node(), Ring5),
	    riak_core_ring_manager:set_my_ring(Ring6),
	    riak_core_gossip:send_ring(Node, node())
    end.

%% @private
%% @doc Set the Status of the node to autojoin if the `Auto'-flag is `true'.
%% @param Auto Boolean indicating if this node is auto-joining.
%% @param Node Node that is joining.
%% @param Ring Ring the node is joining.
%% @returns The updated ring.
-spec maybe_auto_join(Auto :: boolean(), Node :: node(),
		      Ring ::
			  riak_core_ring:riak_core_ring()) -> riak_core_ring:riak_core_ring().

maybe_auto_join(false, _Node, Ring) -> Ring;
maybe_auto_join(true, Node, Ring) ->
    riak_core_ring:update_member_meta(Node,
				      Ring,
				      Node,
				      '$autojoin',
				      true).

%% @doc Remove a node from the cluster and cause all owned partitions to be
%%      redistributed.
%% @param Node Node to be removed.
%% @returns `ok' if the removal was successful or `{error, Reason}' otherwise.
-spec remove(Node :: node()) -> ok |
				{error, not_member | only_member}.

remove(Node) ->
    {ok, Ring} = riak_core_ring_manager:get_raw_ring(),
    case {riak_core_ring:all_members(Ring),
	  riak_core_ring:member_status(Ring, Node)}
	of
	{_, invalid} -> {error, not_member};
	{[Node], _} -> {error, only_member};
	_ -> standard_remove(Node)
    end.

%% @private
%% @doc Remove the given node from the cluster and redistribute all partitions
%%      owned by this node.
%% @param Node Node that is to be removed.
%% @returns `ok'.
-spec standard_remove(Node :: node()) -> ok.

standard_remove(Node) ->
    riak_core_ring_manager:ring_trans(fun (Ring2, _) ->
					      Ring3 =
						  riak_core_ring:remove_member(node(),
									       Ring2,
									       Node),
					      Ring4 =
						  riak_core_ring:ring_changed(node(),
									      Ring3),
					      {new_ring, Ring4}
				      end,
				      []),
    ok.

%% @doc Mark a downed node as downed on the ring.
%% @param Node Node that is down.
%% @returns `ok' if the transition was successful, `{error, Reason}' otherwise.
-spec down(Node :: node()) -> ok |
			      {error, is_up | not_member | only_member}.

down(Node) ->
    {ok, Ring} = riak_core_ring_manager:get_raw_ring(),
    case net_adm:ping(Node) of
	pong -> {error, is_up};
	pang ->
	    case {riak_core_ring:all_members(Ring),
		  riak_core_ring:member_status(Ring, Node)}
		of
		{_, invalid} -> {error, not_member};
		{[Node], _} -> {error, only_member};
		_ ->
		    riak_core_ring_manager:ring_trans(fun (Ring2, _) ->
							      Ring3 =
								  riak_core_ring:down_member(node(),
											     Ring2,
											     Node),
							      Ring4 =
								  riak_core_ring:ring_changed(node(),
											      Ring3),
							      {new_ring, Ring4}
						      end,
						      []),
		    ok
	    end
    end.

%% @doc Leave the cluster with the local node.
%% @returns `ok' if the leave was successful, `{error, Reason}' otherwise.
-spec leave() -> ok |
		 {error, not_member | only_member | already_leaving}.

leave() ->
    Node = node(),
    {ok, Ring} = riak_core_ring_manager:get_raw_ring(),
    case {riak_core_ring:all_members(Ring),
	  riak_core_ring:member_status(Ring, Node)}
	of
	{_, invalid} -> {error, not_member};
	{[Node], _} -> {error, only_member};
	{_, valid} -> standard_leave(Node);
	{_, _} -> {error, already_leaving}
    end.

%% @private
%% @doc Mark a node as leaving to be removed in the future.
%% @param Node Leaving node.
%% @returns `ok'.
-spec standard_leave(Node :: node()) -> ok.

standard_leave(Node) ->
    riak_core_ring_manager:ring_trans(fun (Ring2, _) ->
					      Ring3 =
						  riak_core_ring:leave_member(Node,
									      Ring2,
									      Node),
					      {new_ring, Ring3}
				      end,
				      []),
    ok.

%% @doc Cause all partitions owned by ExitingNode to be taken over
%%      by other nodes.
%% @param ExitingNode Exiting node.
%% @returns `ok' if the removal was successful or `{error, Reason}' otherwise.
-spec remove_from_cluster(ExitingNode :: atom()) -> ok |
						    {error,
						     not_member | only_member}.

remove_from_cluster(ExitingNode)
    when is_atom(ExitingNode) ->
    remove(ExitingNode).

%% @doc Retrieve list of all vnode modules.
%% @returns List of tuple containing app name and vnode modules registered with
%%          the application.
-spec vnode_modules() -> [{atom(), module()}].

vnode_modules() ->
    case application:get_env(riak_core, vnode_modules) of
	undefined -> [];
	{ok, Mods} -> Mods
    end.

%% @doc Retrieve list of all stat modules.
%% @returns List of tuple containing application name and stat module name
%%          registered with the application.
-spec stat_mods() -> [{atom(), module()}].

%% TODO Are stats still used?
stat_mods() ->
    case application:get_env(riak_core, stat_mods) of
	undefined -> [];
	{ok, Mods} -> Mods
    end.

%% @doc Find the health-check module for a given app name.
%% @param App Name of the application the health-check module should be returned
%%        for.
%% @returns Module name of the health-check module or `undefined'.
-spec health_check(App :: atom()) -> mfa() | undefined.

health_check(App) ->
    case application:get_env(riak_core, health_checks) of
	undefined -> undefined;
	{ok, Mods} ->
	    case lists:keyfind(App, 1, Mods) of
		false -> undefined;
		{App, MFA} -> MFA
	    end
    end.

%% @private
%% @doc Get the application name if not supplied, first by get_application
%% then by searching by module name.
-spec get_app(App :: atom(),
	      Module :: module()) -> atom().

get_app(undefined, Module) ->
    {ok, App} = case application:get_application(self()) of
		    {ok, AppName} -> {ok, AppName};
		    undefined -> app_for_module(Module)
		end,
    App;
get_app(App, _Module) -> App.

%% @doc Register a riak_core application.
%% @param Props List of properties for the app.
%% @returns `ok'.
-spec register(Props :: [term()]) -> ok.

register(Props) -> register(undefined, Props).

%% @doc Register a named riak_core application.
%% @param App Name of the application.
%% @param Props List of application properties.
%% @returns `ok'.
-spec register(App :: atom(), Props :: [term()]) -> ok.

register(_App, []) ->
    %% Once the app is registered, do a no-op ring trans
    %% to ensure the new fixups are run against
    %% the ring.
    {ok, _R} = riak_core_ring_manager:ring_trans(fun (R,
						      _A) ->
							 {new_ring, R}
						 end,
						 undefined),
    riak_core_ring_events:force_sync_update(),
    ok;
register(App, [{vnode_module, VNodeMod} | T]) ->
    register_mod(get_app(App, VNodeMod),
		 VNodeMod,
		 vnode_modules),
    register(App, T);
register(App, [{health_check, HealthMFA} | T]) ->
    register_metadata(get_app(App, HealthMFA),
		      HealthMFA,
		      health_checks),
    register(App, T).

%% @doc Register a module in a role for an application-
%% @param App APplication name.
%% @param Module Module to register.
%% @param Type Role of the module.
%% @returns `ok'.
-spec register_mod(App :: atom(), Module :: module(),
		   Type :: atom()) -> ok.

register_mod(App, Module, Type) when is_atom(Type) ->
    case Type of
	vnode_modules ->
	    riak_core_vnode_proxy_sup:start_proxies(Module)
    end,
    case application:get_env(riak_core, Type) of
	undefined ->
	    application:set_env(riak_core, Type, [{App, Module}]);
	{ok, Mods} ->
	    application:set_env(riak_core,
				Type,
				lists:usort([{App, Module} | Mods]))
    end.

%% @doc Register metadata for an application.
%% @param App Name of the application.
%% @param Value Value of the metadata.
%% @param Type Type of the metadata.
%% @returns `ok'.
-spec register_metadata(App :: atom(), Value :: term(),
			Type :: atom()) -> ok.

register_metadata(App, Value, Type) ->
    case application:get_env(riak_core, Type) of
	undefined ->
	    application:set_env(riak_core, Type, [{App, Value}]);
	{ok, Values} ->
	    application:set_env(riak_core,
				Type,
				lists:usort([{App, Value} | Values]))
    end.

%% @doc Adds an event handler to a gen_event instance.
%% @param HandlerMod Module acting as ???.
%% @param Handler Module acting as the event handler.
%% @param Args Arguments for the handler initialization.
%% @returns `ok' if the adding was successful, `{error, Reason}' otherwise.
%% @see add_guarded_event_handler/4.
-spec add_guarded_event_handler(HandlerMod :: module(),
				Handler :: module() | {module(), term()},
				Args :: [term()]) -> ok |
						     {error, Reason :: term()}.

add_guarded_event_handler(HandlerMod, Handler, Args) ->
    add_guarded_event_handler(HandlerMod,
			      Handler,
			      Args,
			      undefined).

%% @doc Add a "guarded" event handler to a gen_event instance.
%%      A guarded handler is implemented as a supervised gen_server
%%      (riak_core_eventhandler_guard) that adds a supervised handler in its
%%      init() callback and exits when the handler crashes so it can be
%%      restarted by the supervisor.
%% @param HandlerMod
%% @param Handler
%% @param Args
%% @param ExitFun
%% @returns `ok' if the adding was successful, `{error, Reason}' otherwise.
-spec add_guarded_event_handler(HandlerMod :: module(),
				Handler :: module() | {module(), term()},
				Args :: [term()],
				ExitFun :: fun((module() | {module(), term()},
						term()) -> any()) |
					   undefined) -> ok |
							 {error,
							  Reason :: term()}.

add_guarded_event_handler(HandlerMod, Handler, Args,
			  ExitFun) ->
    riak_core_eventhandler_sup:start_guarded_handler(HandlerMod,
						     Handler,
						     Args,
						     ExitFun).

%% @doc Delete a guarded event handler from a gen_event instance.
%%
%%      Args is an arbitrary term which is passed as one of the arguments to
%%      Module:terminate/2.
%%
%%      The return value is the return value of Module:terminate/2. If the
%%      specified event handler is not installed, the function returns
%%      {error,module_not_found}. If the callback function fails with Reason,
%%      the function returns {'EXIT',Reason}.
-spec delete_guarded_event_handler(HandlerMod ::
				       module(),
				   Handler :: module() | {module(), term()},
				   Args :: term()) -> term().

delete_guarded_event_handler(HandlerMod, Handler,
			     Args) ->
    riak_core_eventhandler_sup:stop_guarded_handler(HandlerMod,
						    Handler,
						    Args).

%% @private
%% @doc Find the name of the application the given module is registered for.
%% @param Mod Name of the module.
%% @returns `{ok, App}' when the app is found, `{ok, undefined}' otherwise.
-spec app_for_module(Mod :: module()) -> {ok, atom()}.

app_for_module(Mod) ->
    app_for_module(application:which_applications(), Mod).

%% @private
%% @doc Find the name of the application from the list of applications the given
%%      module is registered for.
%% @param Apps List of application names to search in.
%% @param Mod Name of module to search for.
%% @returns `{ok, App}' when the app is found, `{ok, undefined}' otherwise.
-spec app_for_module(Apps :: [atom()],
		     Mod :: module()) -> {ok, atom()}.

app_for_module([], _Mod) -> {ok, undefined};
app_for_module([{App, _, _} | T], Mod) ->
    {ok, Mods} = application:get_key(App, modules),
    case lists:member(Mod, Mods) of
	true -> {ok, App};
	false -> app_for_module(T, Mod)
    end.

%% @doc Only returns when the given application is registered and periodically
%%      logs state.
%% @param App Name of the application to wait for.
%% @returns `ok' when the app is registered.
-spec wait_for_application(App :: atom()) -> ok.

wait_for_application(App) ->
    wait_for_application(App, 0).

%% @private
%% @doc Helper for {@link wait_for_application/1}.
-spec wait_for_application(App :: atom(),
			   Elapsed :: integer()) -> ok.

wait_for_application(App, Elapsed) ->
    case lists:keymember(App,
			 1,
			 application:which_applications())
	of
	true when Elapsed == 0 -> ok;
	true when Elapsed > 0 ->
	    logger:info("Wait complete for application ~p (~p "
			"seconds)",
			[App, Elapsed div 1000]),
	    ok;
	false ->
	    %% Possibly print a notice.
	    ShouldPrint = Elapsed rem (?WAIT_PRINT_INTERVAL) == 0,
	    case ShouldPrint of
		true ->
		    logger:info("Waiting for application ~p to start\n "
				"                                    "
				"(~p seconds).",
				[App, Elapsed div 1000]);
		false -> skip
	    end,
	    timer:sleep(?WAIT_POLL_INTERVAL),
	    wait_for_application(App,
				 Elapsed + (?WAIT_POLL_INTERVAL))
    end.

%% @doc Only returns when the given service is registered and periodically
%%      logs state.
%% @param Service Name of the service to wait for.
%% @returns `ok' when the service is registered.
-spec wait_for_service(Service :: atom()) -> ok.

wait_for_service(Service) ->
    wait_for_service(Service, 0).

%% @private
%% @doc Helper for {@link wait_for_service/1}.
-spec wait_for_service(Service :: atom(),
		       Elapsed :: integer()) -> ok.

wait_for_service(Service, Elapsed) ->
    case lists:member(Service,
		      riak_core_node_watcher:services(node()))
	of
	true when Elapsed == 0 -> ok;
	true when Elapsed > 0 ->
	    logger:info("Wait complete for service ~p (~p seconds)",
			[Service, Elapsed div 1000]),
	    ok;
	false ->
	    %% Possibly print a notice.
	    ShouldPrint = Elapsed rem (?WAIT_PRINT_INTERVAL) == 0,
	    case ShouldPrint of
		true ->
		    logger:info("Waiting for service ~p to start\n   "
				"                                  (~p "
				"seconds)",
				[Service, Elapsed div 1000]);
		false -> skip
	    end,
	    timer:sleep(?WAIT_POLL_INTERVAL),
	    wait_for_service(Service,
			     Elapsed + (?WAIT_POLL_INTERVAL))
    end.

%% @doc Retrieve the stat prefix.
-spec stat_prefix() -> term().

%% TODO stats are not used anymore, remove?
stat_prefix() ->
    application:get_env(riak_core, stat_prefix, riak).
