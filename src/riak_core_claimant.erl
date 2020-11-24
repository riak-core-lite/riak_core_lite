%% -------------------------------------------------------------------
%%
%% Copyright (c) 2012-2015 Basho Technologies, Inc.  All Rights Reserved.
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

-module(riak_core_claimant).

-behaviour(gen_server).

%% API
-export([start_link/0]).

-export([leave_member/1, remove_member/1,
         force_replace/2, replace/2, resize_ring/1,
         abort_resize/0, plan/0, commit/0, clear/0,
         ring_changed/2]).

-export([reassign_indices/1]). % helpers for claim sim

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-type action() :: leave | remove | {replace, node()} |
                  {force_replace, node()} | {resize, integer()} |
                  abort_resize.

-type
     riak_core_ring() :: riak_core_ring:riak_core_ring().

%% A tuple representing a given cluster transition:
%%   {Ring, NewRing} where NewRing = f(Ring)
-type ring_transition() :: {riak_core_ring(),
                            riak_core_ring()}.

-type change() :: {node(), action()}.

-type leave_request_error() :: not_member |
                               only_member | already_leaving.

-type remove_request_error() :: is_claimant |
                                not_member | only_member.

-type replace_request_error() :: not_member |
                                 already_leaving | already_replacement |
                                 invalid_replacement.

-type force_replace_request_error() :: not_member |
                                       is_claimant | already_replacement |
                                       invalid_replacement.

-type resize_request_error() :: same_size |
                                single_node | pending_changes.

-type resize_abort_request_error() :: not_resizing.

-type request_error() :: leave_request_error() |
                         remove_request_error() | replace_request_error() |
                         force_replace_request_error() |
                         resize_request_error() | resize_abort_request_error().

-type commit_error() :: nothing_planned |
                        invalid_resize_claim | ring_not_ready | plan_changed.

-type log() :: fun((atom(), term()) -> ok).

-type next() :: [{integer(), term(), term(), [module()],
                  awaiting | complete}].

-record(state,
        {last_ring_id,
         %% The set of staged cluster changes
         changes  :: [change()],
         %% Ring computed during the last planning stage based on
         %% applying a set of staged cluster changes. When commiting
         %% changes, the computed ring must match the previous planned
         %% ring to be allowed.
         next_ring  :: riak_core_ring() | undefined,
         %% Random number seed passed to remove_node to ensure the
         %% current randomized remove algorithm is deterministic
         %% between plan and commit phases
         seed  :: erlang:timestamp()}).

-type state() :: #state{}.

-define(ROUT(S, A),
        ok).%%-define(ROUT(S,A),?debugFmt(S,A)).
            %%-define(ROUT(S,A),io:format(S,A)).

%%%===================================================================
%%% API
%%%===================================================================


-ifdef(TEST).

-export([stop/0]).

stop() ->
    gen_server:call(claimant(), stop).

-endif.

%% @doc Spawn and register the riak_core_claimant server
-spec start_link() -> {ok, pid()} | ignore |
                      {error, {already_started, pid()} | term()}.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [],
                          []).

%% @doc Determine how the cluster will be affected by the staged changes,
%%      returning the set of pending changes as well as a list of ring
%%      modifications that correspond to each resulting cluster transition
%%      (eg. the initial transition that applies the staged changes, and
%%      any additional transitions triggered by later rebalancing).
%% @returns `{ok, Changes, NextRings}' if the plan can be generated,
%%          `{error, Reason}' otherwise.
-spec plan() -> {error,
                 ring_not_ready | invalid_resize_claim} |
                {ok, [change()], [riak_core_ring()]}.

plan() -> gen_server:call(claimant(), plan, infinity).

%% @doc Commit the set of staged cluster changes, returning true on success.
%%      A commit is only allowed to succeed if the ring is ready and if the
%%      current set of changes matches those computed by the most recent
%%      call to plan/0.
%% @returns `ok' if the plan is committed successfully, `{error, Reason}' or
%%          just `error' otherwise.
-spec commit() -> ok | error | {error, commit_error()}.

commit() ->
    gen_server:call(claimant(), commit, infinity).

%% @doc Stage a request for `Node' to leave the cluster. If committed, `Node'
%%      will handoff all of its data to other nodes in the cluster and then
%%      shutdown.
%% @param Node Node to leave the cluster.
%% @returns `ok' If the staging was successful, `{error, Reason}' otherwise.
-spec leave_member(Node :: node()) -> ok |
                                      {error, leave_request_error()}.

leave_member(Node) -> stage(Node, leave).

%% @doc Stage a request for `Node' to be forcefully removed from the cluster.
%%      If committed, all partitions owned by `Node' will immediately be
%%      re-assigned to other nodes. No data on `Node' will be transfered to
%%      other nodes, and all replicas on `Node' will be lost.
%% @param Node Node to be removed from the cluster.
%% @returns `ok' if the staging was successful, `{error, Reason}' otherwise.
-spec remove_member(Node :: node()) -> ok |
                                       {error, remove_request_error()}.

remove_member(Node) -> stage(Node, remove).

%% @doc Stage a request for `Node' to be replaced by `NewNode'. If committed,
%%      `Node' will handoff all of its data to `NewNode' and then shutdown.
%%      The current implementation requires `NewNode' to be a fresh node that
%%      is joining the cluster and does not yet own any partitions of its own.
%% @param Node Node to be replaced.
%% @param NewNode Node to replace the old node.
%% @returns `ok' if the staging was successful, `{error, Reason}' otherwise.
-spec replace(Node :: node(), NewNode :: node()) -> ok |
                                                    {error,
                                                     replace_request_error()}.

replace(Node, NewNode) ->
    stage(Node, {replace, NewNode}).

%% @doc Stage a request for `Node' to be forcefully replaced by `NewNode'.
%%      If committed, all partitions owned by `Node' will immediately be
%%      re-assigned to `NewNode'. No data on `Node' will be transfered,
%%      and all replicas on `Node' will be lost. The current implementation
%%      requires `NewNode' to be a fresh node that is joining the cluster
%%      and does not yet own any partitions of its own.
%% @param Node Node to be replaced.
%% @param NewNode Node to replace the old node.
%% @returns `ok' if the staging was successful, `{error, Reason}' otherwise.
-spec force_replace(Node :: node(),
                    NewNode :: node()) -> ok |
                                          {error, replace_request_error()}.

force_replace(Node, NewNode) ->
    stage(Node, {force_replace, NewNode}).

%% @doc Stage a request to resize the ring. If committed, all nodes
%%      will participate in resizing operation. Unlike other operations,
%%      the new ring is not installed until all transfers have completed.
%%      During that time requests continue to be routed to the old ring.
%%      After completion, the new ring is installed and data is safely
%%      removed from partitons no longer owner by a node or present
%%      in the ring.
%% @param NewRingSize Number of partitions the ring should be resized to.
%% @returns `ok' if the staging was successful, `{error, Reason}' otherwise.
-spec resize_ring(integer()) -> ok |
                                {error, resize_request_error()}.

resize_ring(NewRingSize) ->
    %% use the node making the request. it will be ignored
    stage(node(), {resize, NewRingSize}).

%% @doc Stage a request to abort a resize operation. If committed, the installed
%%      ring will stay the same.
%% @returns `ok' if the staging was successful, `{error, Reason}' otherwise.
-spec abort_resize() -> ok |
                        {error, resize_abort_request_error()}.

abort_resize() -> stage(node(), abort_resize).

-spec pending_close(riak_core_ring(), any()) -> ok.
pending_close(Ring, RingID) ->
    gen_server:call(?MODULE, {pending_close, Ring, RingID}).

%% @doc Stage a request to set a new location for the given node.
-spec set_node_location(node(), string()) -> ok | {error, atom()}.
set_node_location(Node, Location) ->
    stage(Node, {set_location, Location}).

%% @doc Clear the current set of staged transfers
%% @returns `ok'.
-spec clear() -> ok.

clear() -> gen_server:call(claimant(), clear, infinity).

%% @doc This function is called as part of the ring reconciliation logic
%%      triggered by the gossip subsystem. This is only called on the one
%%      node that is currently the claimant. This function is the top-level
%%      entry point to the claimant logic that orchestrates cluster state
%%      transitions. The current code path:
%%          riak_core_gossip:reconcile/2
%%          --> riak_core_ring:ring_changed/2
%%          -----> riak_core_ring:internal_ring_changed/2
%%          --------> riak_core_claimant:ring_changed/2
%% @returns The ring with the changes applied to.
-spec ring_changed(Node :: node(),
                   Ring :: riak_core_ring()) -> riak_core_ring().

ring_changed(Node, Ring) ->
    internal_ring_changed(Node, Ring).

%%%===================================================================
%%% Claim sim helpers until refactor
%%%===================================================================

%% @doc Assign indies owned by replaced nodes to the nodes replacing them.
%% @param CState Ring on whihc the indices are to be reassigned.
%% @returns `{Changed, NewRing}', indicating if there has been changes and the
%%          resulting ring.
-spec reassign_indices(CState ::
                           riak_core_ring:riak_core_ring()) -> {boolean(),
                                                                riak_core_ring()}.

reassign_indices(CState) ->
    reassign_indices(CState, [], erlang:timestamp(),
                     fun no_log/2).

%%%===================================================================
%%% Internal API helpers
%%%===================================================================

%% @private
%% @doc Stage the given action to be executed with the next commit.
%% @param Node Node requesting the stage.
%% @param Action Action to be staged.
%% @returns `ok' if the staging was successful, `{error, Reason}' otherwise.
-spec stage(Node :: node(), Action :: action()) -> ok |
                                                   {error, request_error()}.

stage(Node, Action) ->
    gen_server:call(claimant(), {stage, Node, Action},
                    infinity).

%% @private
%% @doc Retrieve a reference to the current claimant.
%% @returns CUrrent claimant.
-spec claimant() -> {module(), term()}.

claimant() ->
    {ok, Ring} = riak_core_ring_manager:get_my_ring(),
    {?MODULE, riak_core_ring:claimant(Ring)}.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @doc Callback for gen_server.
%% @see gen_server:start_link/3
%% @see gen_server:start_link/4.
-spec init(Args :: []) -> {ok, state()}.

init([]) ->
    schedule_tick(),
    {ok, #state{changes = [], seed = erlang:timestamp()}}.

%% @doc Callback for gen_server.
%% @see gen_server:call/2.
%% @see gen_server:call/3.
-spec handle_call(Call :: term(),
                  From :: {pid(), term()}, State :: state()) -> {reply,
                                                                 term(),
                                                                 state()}.

handle_call(clear, _From, State) ->
    State2 = clear_staged(State), {reply, ok, State2};
handle_call({stage, Node, Action}, _From, State) ->
    {ok, Ring} = riak_core_ring_manager:get_raw_ring(),
    {Reply, State2} = maybe_stage(Node, Action, Ring,
                                  State),
    {reply, Reply, State2};
handle_call(plan, _From, State) ->
    {ok, Ring} = riak_core_ring_manager:get_raw_ring(),
    case riak_core_ring:ring_ready(Ring) of
      false ->
          Reply = {error, ring_not_ready}, {reply, Reply, State};
      true ->
          {Reply, State2} = generate_plan(Ring, State),
          {reply, Reply, State2}
    end;
handle_call(commit, _From, State) ->
    {Reply, State2} = commit_staged(State),
    {reply, Reply, State2};
handle_call(_Request, _From, State) ->
    Reply = ok, {reply, Reply, State}.

%% @doc Callback for gen_server. Not implemented.
%% @see gen_server:cast/2.
-spec handle_cast(Msg :: term(),
                  State :: state()) -> {noreply, state()}.

handle_cast(_Msg, State) -> {noreply, State}.

%% @doc Callback for gen_server.
%% @see gen_server.
-spec handle_info(Info :: term(),
                  State :: state()) -> {noreply, state()}.

handle_info(tick, State) ->
    State2 = tick(State), {noreply, State2};
handle_info(reset_ring_id, State) ->
    State2 = State#state{last_ring_id = undefined},
    {noreply, State2};
handle_info(_Info, State) -> {noreply, State}.

%% @doc Callback for gen_server. Not implemented.
%% @see gen_server:stop/1.
%% @see gen_server:stop/2.
-spec terminate(Reason :: term(),
                State :: state()) -> ok.

terminate(_Reason, _State) -> ok.

%% @doc Callback for gen_server. Not implemented.
%% @see gen_server.
-spec code_change(OldVsn :: term() | {down, term()},
                  State :: state(), Extra :: term()) -> {ok, state()}.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% @private
%% @doc Verify that a cluster change request is valid and add it to
%%      the list of staged changes.
-spec maybe_stage(Node :: node(), Action :: action(),
                  Ring :: riak_core_ring(), State :: state()) -> {ok |
                                                                  {error,
                                                                   request_error()},
                                                                  state()}.

maybe_stage(Node, Action, Ring,
            State = #state{changes = Changes}) ->
    case valid_request(Node, Action, Changes, Ring) of
      true ->
          Changes2 = orddict:store(Node, Action, Changes),
          Changes3 = filter_changes(Changes2, Ring),
          State2 = State#state{changes = Changes3},
          {ok, State2};
      Error -> {Error, State}
    end.

%% @private
%% @doc Determine how the staged set of cluster changes will affect
%%      the cluster. See {@link plan/0} for additional details.
-spec generate_plan(Ring :: riak_core_ring(),
                    State :: state()) -> {{ok, [change()],
                                           [riak_core_ring()]} |
                                          {error, invalid_resize_claim},
                                          state()}.

generate_plan(Ring,
              State = #state{changes = Changes}) ->
    Changes2 = filter_changes(Changes, Ring),
    Joining = [{Node, join}
               || Node <- riak_core_ring:members(Ring, [joining])],
    AllChanges = lists:ukeysort(1, Changes2 ++ Joining),
    State2 = State#state{changes = Changes2},
    generate_plan(AllChanges, Ring, State2).

%% @private
%% @see generate_plan/2.
-spec generate_plan(Changes :: [change()],
                    Ring :: riak_core_ring(), State :: state()) -> {{ok,
                                                                     [change()],
                                                                     [riak_core_ring()]} |
                                                                    {error,
                                                                     invalid_resize_claim},
                                                                    state()}.

generate_plan([], _, State) ->
    %% There are no changes to apply
    {{ok, [], []}, State};
generate_plan(Changes, Ring,
              State = #state{seed = Seed}) ->
    case compute_all_next_rings(Changes, Seed, Ring) of
      {error, invalid_resize_claim} ->
          {{error, invalid_resize_claim}, State};
      {ok, NextRings} ->
          {_, NextRing} = hd(NextRings),
          State2 = State#state{next_ring = NextRing},
          Reply = {ok, Changes, NextRings},
          {Reply, State2}
    end.

%% @private
%% @doc Commit the set of staged cluster changes. See {@link commit/0}
%%      for additional details.
-spec commit_staged(State :: state()) -> {ok | error,
                                          state()} |
                                         {{error, commit_error()}, state()}.

commit_staged(State = #state{next_ring = undefined}) ->
    {{error, nothing_planned}, State};
commit_staged(State) ->
    case maybe_commit_staged(State) of
      {ok, _} ->
          State2 = State#state{next_ring = undefined,
                               changes = [], seed = erlang:timestamp()},
          {ok, State2};
      not_changed -> {error, State};
      {not_changed, Reason} -> {{error, Reason}, State}
    end.

%% @private
%% @see commit_staged/1.
-spec maybe_commit_staged(State :: state()) -> {ok,
                                                riak_core_ring()} |
                                               not_changed |
                                               {not_changed,
                                                invalid_resize_claim |
                                                ring_not_ready | plan_changed}.

maybe_commit_staged(State) ->
    riak_core_ring_manager:ring_trans(fun maybe_commit_staged/2,
                                      State).

%% @private
%% @see maybe_commit_staged/1.
-spec maybe_commit_staged(Ring :: riak_core_ring(),
                          State :: state()) -> {new_ring, riak_core_ring()} |
                                               ignore |
                                               {ignore,
                                                invalid_resize_claim |
                                                ring_not_ready | plan_changed}.

maybe_commit_staged(Ring,
                    State = #state{changes = Changes, seed = Seed}) ->
    Changes2 = filter_changes(Changes, Ring),
    case compute_next_ring(Changes2, Seed, Ring) of
      {error, invalid_resize_claim} ->
          {ignore, invalid_resize_claim};
      {ok, NextRing} ->
          maybe_commit_staged(Ring, NextRing, State)
    end.

%% @private
%% @see maybe_commit_staged/2.
-spec maybe_commit_staged(Ring :: riak_core_ring(),
                          NextRing :: riak_core_ring(),
                          State :: state()) -> {new_ring, riak_core_ring()} |
                                               ignore |
                                               {ignore,
                                                ring_not_ready | plan_changed}.

maybe_commit_staged(Ring, NextRing,
                    #state{next_ring = PlannedRing}) ->
    Claimant = riak_core_ring:claimant(Ring),
    IsReady = riak_core_ring:ring_ready(Ring),
    IsClaimant = Claimant == node(),
    IsSamePlan = same_plan(PlannedRing, NextRing),
    case {IsReady, IsClaimant, IsSamePlan} of
      {false, _, _} -> {ignore, ring_not_ready};
      {_, false, _} -> ignore;
      {_, _, false} -> {ignore, plan_changed};
      _ ->
          NewRing = riak_core_ring:increment_vclock(Claimant,
                                                    NextRing),
          {new_ring, NewRing}
    end.

%% @private
%% @doc Clear the current set of staged transfers. Since `joining' nodes
%%      are determined based on the node's actual state, rather than a
%%      staged action, the only way to clear pending joins is to remove
%%      the `joining' nodes from the cluster. Used by the public API
%%      call {@link clear/0}.
-spec clear_staged(State :: state()) -> state().

clear_staged(State) ->
    remove_joining_nodes(),
    State#state{changes = [], seed = erlang:timestamp()}.

%% @private
-spec remove_joining_nodes() -> {ok, riak_core_ring()} |
                                not_changed.

remove_joining_nodes() ->
    riak_core_ring_manager:ring_trans(fun remove_joining_nodes/2,
                                      ok).

%% @private
%% @doc Removes nodes that are currently joining from the ring. Used as a
%%      callback for {@link riak_core_ring_manager:ring_trans()}.
%% @param Ring Ring to remove nodes from.
%% @param Args ignored, exists to conform to the callback function form.
%% @returns `new_ring, Ring' if the removal can be done, `ignore' if this is not
%%          the claimant or there are no joining nodes.
-spec remove_joining_nodes(Ring :: riak_core_ring(),
                           Args :: any()) -> {new_ring, riak_core_ring()} |
                                             ignore.

remove_joining_nodes(Ring, _) ->
    Claimant = riak_core_ring:claimant(Ring),
    IsClaimant = Claimant == node(),
    Joining = riak_core_ring:members(Ring, [joining]),
    AreJoining = Joining /= [],
    case IsClaimant and AreJoining of
      false -> ignore;
      true ->
          NewRing = remove_joining_nodes_from_ring(Claimant,
                                                   Joining, Ring),
          {new_ring, NewRing}
    end.

%% @private
%% @doc Helper for remove_joining_nodes/2.
%% @see remove_joining_nodes/2.
-spec remove_joining_nodes_from_ring(Claimant :: term(),
                                     Joining :: [node()],
                                     Ring ::
                                         riak_core_ring()) -> riak_core_ring().

remove_joining_nodes_from_ring(Claimant, Joining,
                               Ring) ->
    NewRing = lists:foldl(fun (Node, RingAcc) ->
                                  riak_core_ring:set_member(Claimant, RingAcc,
                                                            Node, invalid,
                                                            same_vclock)
                          end,
                          Ring, Joining),
    NewRing2 = riak_core_ring:increment_vclock(Claimant,
                                               NewRing),
    NewRing2.

%% @private
%% @doc Check if the given request is valid for the current state.
%% @param Node Node involved in the action.
%% @param Action Requested action.
%% @param Changes List of changes staged.
%% @param Ring Ring action should be taken on.
%% @returns `true' if the request is valid, `{error, Reason}' otherwise.
%% @see valid_leave_request/2.
%% @see valid_remove_request/2.
%% @see valid_replace_request/4.
%% @see valid_force_replace_request/4.
%% @see valid_resize_request/3.
%% @see valid_resize_abort_request/1.
-spec valid_request(Node :: node(), Action :: action(),
                    Changes :: [change()],
                    Ring :: riak_core_ring()) -> true |
                                                 {error, request_error()}.

valid_request(Node, Action, Changes, Ring) ->
    case Action of
      leave -> valid_leave_request(Node, Ring);
      remove -> valid_remove_request(Node, Ring);
      {replace, NewNode} ->
          valid_replace_request(Node, NewNode, Changes, Ring);
      {force_replace, NewNode} ->
          valid_force_replace_request(Node, NewNode, Changes,
                                      Ring);
      {resize, NewRingSize} ->
          valid_resize_request(NewRingSize, Changes, Ring);
      abort_resize -> valid_resize_abort_request(Ring)
    end.

%% @private
%% @doc Check if a leave request is valid. A leave request is valid if the
%%      leaving node is valid, a mamber, not the only member, and not already
%%      leaving.
%% @param Node Node to leave.
%% @param Ring Riing the node should leave from.
%% @returns `true' if the request is valid, `{error, Reason}' otherwise.
%% @see leave_member/1.
-spec valid_leave_request(Node :: node(),
                          Ring :: riak_core_ring()) -> true |
                                                       {error,
                                                        leave_request_error()}.

valid_leave_request(Node, Ring) ->
    case {riak_core_ring:all_members(Ring),
          riak_core_ring:member_status(Ring, Node)}
        of
      {_, invalid} -> {error, not_member};
      {[Node], _} -> {error, only_member};
      {_, valid} -> true;
      {_, joining} -> true;
      {_, _} -> {error, already_leaving}
    end.

%% @private
%% @doc Check if a remove request is valid. A remove request is valid if the
%%      removed node is not the claimant, is a member, and is not the only
%%      member.
%% @param Node Node to be removed.
%% @param Ring Ring to remove the node from.
%% @returns `true' if the request is valid, `{error, Reason}' otherwise.
%% @see remove_member/1.
-spec valid_remove_request(Node :: node(),
                           Ring :: riak_core_ring()) -> true |
                                                        {error,
                                                         remove_request_error()}.

valid_remove_request(Node, Ring) ->
    IsClaimant = Node == riak_core_ring:claimant(Ring),
    case {IsClaimant, riak_core_ring:all_members(Ring),
          riak_core_ring:member_status(Ring, Node)}
        of
      {true, _, _} -> {error, is_claimant};
      {_, _, invalid} -> {error, not_member};
      {_, [Node], _} -> {error, only_member};
      _ -> true
    end.

%% @private
%% @doc Check if a replace request is valid. A replace request is valid if the
%%      node to be replaced is a member, not already leaving or being replaced,
%%      and if the new node is freshly joining.
%% @param Node Node to be replaced.
%% @param NewNode Node to replace the old node.
%% @param Changes Changes to determine currently staged replacements.
%% @param Ring Ring to replace the node on.
%% @returns `true' if the request is valid, `{error, Reason}' otherwise.
%% @see replace/2.
-spec valid_replace_request(Node :: node(),
                            NewNode :: node(), Changes :: [change()],
                            Ring :: riak_core_ring()) -> true |
                                                         {error,
                                                          replace_request_error()}.

valid_replace_request(Node, NewNode, Changes, Ring) ->
    AlreadyReplacement = lists:member(NewNode,
                                      existing_replacements(Changes)),
    NewJoining = (riak_core_ring:member_status(Ring,
                                               NewNode)
                    == joining)
                   and not orddict:is_key(NewNode, Changes),
    case {riak_core_ring:member_status(Ring, Node),
          AlreadyReplacement, NewJoining}
        of
      {invalid, _, _} -> {error, not_member};
      {leaving, _, _} -> {error, already_leaving};
      {_, true, _} -> {error, already_replacement};
      {_, _, false} -> {error, invalid_replacement};
      _ -> true
    end.

%% @private
%% @doc Check if a force replace request is valid. A force replace request is
%%      valid if the node to be replaced is a member, not the claimant, not
%%      already being replaced, and if the new node is freshly joining.
%% @param Node Node to be replaced.
%% @param NewNode Node to replace the old node.
%% @param Changes Changes to determine currently staged replacements.
%% @param Ring Ring to replace the node on.
%% @returns `true' if the request is valid, `{error, Reason}' otherwise.
%% @see force_replace/2.
-spec valid_force_replace_request(Node :: node(),
                                  NewNode :: node(), Changes :: [change()],
                                  Ring :: riak_core_ring()) -> true |
                                                               {error,
                                                                force_replace_request_error()}.

valid_force_replace_request(Node, NewNode, Changes,
                            Ring) ->
    IsClaimant = Node == riak_core_ring:claimant(Ring),
    AlreadyReplacement = lists:member(NewNode,
                                      existing_replacements(Changes)),
    NewJoining = (riak_core_ring:member_status(Ring,
                                               NewNode)
                    == joining)
                   and not orddict:is_key(NewNode, Changes),
    case {IsClaimant,
          riak_core_ring:member_status(Ring, Node),
          AlreadyReplacement, NewJoining}
        of
      {true, _, _, _} -> {error, is_claimant};
      {_, invalid, _, _} -> {error, not_member};
      {_, _, true, _} -> {error, already_replacement};
      {_, _, _, false} -> {error, invalid_replacement};
      _ -> true
    end.

%% @private
%% @doc Check if a resize request is valid. A resize request is valid if the new
%%      size differs from the old one, there is more than one node on the ring,
%%      and there are no pending changes. Restrictions preventing resize along
%%      with other operations are temporary.
%% @param NewRingSize Number of partitions after the resize operation.
%% @param Changes List of changes to check for pending changes.
%% @param Ring Ring to resize.
%% @returns `true' if the request is valid, `{error, Reason}' otherwise.
%% @see resize_ring/1.
-spec valid_resize_request(NewRingSize :: pos_integer(),
                           Changes :: [change()],
                           Ring :: riak_core_ring()) -> true |
                                                        {error,
                                                         resize_request_error()}.

valid_resize_request(NewRingSize, [], Ring) ->
    IsResizing = riak_core_ring:num_partitions(Ring) =/=
                   NewRingSize,
    NodeCount = length(riak_core_ring:all_members(Ring)),
    Changes = length(riak_core_ring:pending_changes(Ring)) >
                0,
    case {IsResizing, NodeCount, Changes} of
      {true, N, false} when N > 1 -> true;
      {false, _, _} -> {error, same_size};
      {_, 1, _} -> {error, single_node};
      {_, _, true} -> {error, pending_changes}
    end.

%% @doc Check if a resize abort request is valid. A resize abort request is
%%      valid if the ring is actually resizing and not in post resize state.
%% @param Ring Ring to abort the resize on.
%% @returns `true' if the request is valid, `{error, Reason}' otherwise.
%% @see abort_resize/0.
-spec valid_resize_abort_request(Ring ::
                                     riak_core_ring()) -> true |
                                                          {error,
                                                           resize_abort_request_error()}.

valid_resize_abort_request(Ring) ->
    IsResizing = riak_core_ring:is_resizing(Ring),
    IsPostResize = riak_core_ring:is_post_resize(Ring),
    case IsResizing andalso not IsPostResize of
      true -> true;
      false -> {error, not_resizing}
    end.

%% @private
%% Validating node member status
valid_set_location_request(_Location, Node, Ring) ->
    case riak_core_ring:member_status(Ring, Node) of
        valid ->
            true;
        joining ->
            true;
        invalid ->
            {error, not_member};
        _ ->
            true
    end.

%% @private
%% @doc Filter out any staged changes that are no longer valid. Changes
%%      can become invalid based on other staged changes, or by cluster
%%      changes that bypass the staging system.
-spec filter_changes(Changes :: [change()],
                     Ring :: riak_core_ring()) -> [change()].

filter_changes(Changes, Ring) ->
    orddict:filter(fun (Node, Change) ->
                           filter_changes_pred(Node, Change, Changes, Ring)
                   end,
                   Changes).

%% @private
%% @doc Predicate function for {@link filter_changes/2}.
-spec filter_changes_pred(Node :: node(),
                          Action :: action(), Changes :: [change()],
                          Ring :: riak_core_ring()) -> boolean().

filter_changes_pred(Node, {Change, NewNode}, Changes,
                    Ring)
    when (Change == replace) or (Change == force_replace) ->
    IsMember = riak_core_ring:member_status(Ring, Node) /=
                 invalid,
    IsJoining = riak_core_ring:member_status(Ring, NewNode)
                  == joining,
    NotChanging = not orddict:is_key(NewNode, Changes),
    IsMember and IsJoining and NotChanging;
filter_changes_pred(Node, _, _, Ring) ->
    IsMember = riak_core_ring:member_status(Ring, Node) /=
                 invalid,
    IsMember.

%% @private
%% @doc Compute nodes staged to replace another node.
-spec existing_replacements(Changes ::
                                [change()]) -> [node()].

existing_replacements(Changes) ->
    [Node
     || {_, {Change, Node}} <- Changes,
        (Change == replace) or (Change == force_replace)].

%% @private
%% @doc Determine if two rings have logically equal cluster state.
-spec same_plan(RingA :: riak_core_ring(),
                RingB :: riak_core_ring()) -> boolean().

same_plan(RingA, RingB) ->
    riak_core_ring:all_member_status(RingA) ==
      riak_core_ring:all_member_status(RingB)
      andalso
      riak_core_ring:all_owners(RingA) ==
        riak_core_ring:all_owners(RingB)
        andalso
        riak_core_ring:pending_changes(RingA) ==
          riak_core_ring:pending_changes(RingB).

%% @private
%% @doc Schedule a tick to be send to the claimant.
-spec schedule_tick() -> reference().

schedule_tick() ->
    Tick = application:get_env(riak_core, claimant_tick,
                               10000),
    erlang:send_after(Tick, ?MODULE, tick).

%% @private
%% @doc Execute one claimant tick.
-spec tick(State :: state()) -> state().

tick(State = #state{last_ring_id = LastID}) ->
    case riak_core_ring_manager:get_ring_id() of
      LastID -> schedule_tick(), State;
      RingID ->
          {ok, Ring} = riak_core_ring_manager:get_raw_ring(),
          maybe_force_ring_update(Ring),
          schedule_tick(),
          State#state{last_ring_id = RingID}
    end.

%% @private
%% @doc Force a ring update if this is the ring's claimant and the ring is
%%      ready.
-spec maybe_force_ring_update(Ring ::
                                  riak_core_ring()) -> ok.

maybe_force_ring_update(Ring) ->
    IsClaimant = riak_core_ring:claimant(Ring) == node(),
    IsReady = riak_core_ring:ring_ready(Ring),
    %% Do not force if we have any joining nodes unless any of them are
    %% auto-joining nodes. Otherwise, we will force update continuously.
    JoinBlock = are_joining_nodes(Ring) andalso
                  auto_joining_nodes(Ring) == [],
    case IsClaimant and IsReady and not JoinBlock of
      true -> do_maybe_force_ring_update(Ring);
      false -> ok
    end.

%% @private
%% @doc Force the ring update.
-spec do_maybe_force_ring_update(Ring ::
                                     riak_core_ring()) -> ok.

do_maybe_force_ring_update(Ring) ->
    case compute_next_ring([], erlang:timestamp(), Ring) of
      {ok, NextRing} ->
          case same_plan(Ring, NextRing) of
            false ->
                logger:warning("Forcing update of stalled ring"),
                riak_core_ring_manager:force_update();
            true -> ok
          end;
      _ -> ok
    end.

%% =========================================================================
%% Claimant rebalance/reassign logic
%% =========================================================================

%% @private
%% @doc Compute a list of all next rings after applying the changes.
-spec compute_all_next_rings(Changes :: [change()],
                             Seed :: erlang:timestamp(),
                             Ring :: riak_core_ring()) -> {ok,
                                                           [ring_transition()]} |
                                                          {error,
                                                           invalid_resize_claim}.

compute_all_next_rings(Changes, Seed, Ring) ->
    compute_all_next_rings(Changes, Seed, Ring, []).

%% @private
%% @doc Compute a list of all next rings after applying the changes.
-spec compute_all_next_rings(Changes :: [change()],
                             Seed :: erlang:timestamp(),
                             Ring :: riak_core_ring(),
                             Acc :: [ring_transition()]) -> {ok,
                                                             [ring_transition()]} |
                                                            {error,
                                                             invalid_resize_claim}.

compute_all_next_rings(Changes, Seed, Ring, Acc) ->
    case compute_next_ring(Changes, Seed, Ring) of
      {error, invalid_resize_claim} = Err -> Err;
      {ok, NextRing} ->
          Acc2 = [{Ring, NextRing} | Acc],
          case not same_plan(Ring, NextRing) of
            true ->
                FutureRing = riak_core_ring:future_ring(NextRing),
                compute_all_next_rings([], Seed, FutureRing, Acc2);
            false -> {ok, lists:reverse(Acc2)}
          end
    end.

%% @private
%% @doc Compute the next ring by applying all staged changes.
-spec compute_next_ring(Changes :: [change()],
                        Seed :: erlang:timestamp(),
                        Ring :: riak_core_ring()) -> {ok, riak_core_ring()} |
                                                     {error,
                                                      invalid_resize_claim}.

compute_next_ring(Changes, Seed, Ring) ->
    Replacing = [{Node, NewNode}
                 || {Node, {replace, NewNode}} <- Changes],
    Ring2 = apply_changes(Ring, Changes),
    {_, Ring3} = maybe_handle_joining(node(), Ring2),
    {_, Ring4} = do_claimant_quiet(node(), Ring3, Replacing,
                                   Seed),
    {Valid, Ring5} = maybe_compute_resize(Ring, Ring4),
    case Valid of
      false -> {error, invalid_resize_claim};
      true -> {ok, Ring5}
    end.

%% @private
%% @doc Return the resized ring if it is valid.
-spec maybe_compute_resize(Orig :: riak_core_ring(),
                           MbResized :: riak_core_ring()) -> {true,
                                                              riak_core_ring()} |
                                                             {false,
                                                              riak_core_ring()}.

maybe_compute_resize(Orig, MbResized) ->
    OrigSize = riak_core_ring:num_partitions(Orig),
    NewSize = riak_core_ring:num_partitions(MbResized),
    case OrigSize =/= NewSize of
      false -> {true, MbResized};
      true ->
          validate_resized_ring(compute_resize(Orig, MbResized))
    end.

%% @private
%% @doc Adjust resized ring and schedule first resize transfers.
%% Because riak_core_ring:resize/2 modifies the chash structure
%% directly the ring calculated in this plan (`Resized') is used
%% to determine the future ring but the changes are applied to
%% the currently installed ring (`Orig') so that the changes to
%% the chash are not committed to the ring manager
-spec compute_resize(Orig :: riak_core_ring(),
                     Resized :: riak_core_ring()) -> riak_core_ring().

compute_resize(Orig, Resized) ->
    %% need to operate on balanced, future ring (apply changes determined by claim)
    CState0 = riak_core_ring:future_ring(Resized),
    Type = case riak_core_ring:num_partitions(Orig) <
                  riak_core_ring:num_partitions(Resized)
               of
             true -> larger;
             false -> smaller
           end,
    %% Each index in the original ring must perform several transfers
    %% to properly resize the ring. The first transfer for each index
    %% is scheduled here. Subsequent transfers are scheduled by vnode
    CState1 = lists:foldl(fun ({Idx, _} = IdxOwner,
                               CStateAcc) ->
                                  %% indexes being abandoned in a shrinking ring have
                                  %% no next owner
                                  NextOwner = try
                                                riak_core_ring:index_owner(CStateAcc,
                                                                           Idx)
                                              catch
                                                error:{badmatch, false} -> none
                                              end,
                                  schedule_first_resize_transfer(Type, IdxOwner,
                                                                 NextOwner,
                                                                 CStateAcc)
                          end,
                          CState0, riak_core_ring:all_owners(Orig)),
    riak_core_ring:set_pending_resize(CState1, Orig).

%% @private
%% @doc determine the first resize transfer a partition should perform with
%% the goal of ensuring the transfer will actually have data to send to the
%% target.
-spec schedule_first_resize_transfer(Type :: smaller |
                                             atom(),
                                     IdxOwner :: {integer(), node()},
                                     Owner :: node(),
                                     Resized ::
                                         riak_core_ring()) -> riak_core_ring().

schedule_first_resize_transfer(smaller,
                               {Idx, _} = IdxOwner, none, Resized) ->
    %% partition no longer exists in shrunk ring, first successor will be
    %% new owner of its data
    Target = hd(riak_core_ring:preflist(<<Idx:160/integer>>,
                                        Resized)),
    riak_core_ring:schedule_resize_transfer(Resized,
                                            IdxOwner, Target);
schedule_first_resize_transfer(_Type,
                               {Idx, Owner} = IdxOwner, Owner, Resized) ->
    %% partition is not being moved during expansion, first predecessor will
    %% own at least a portion of its data
    Target = hd(chash:predecessors(Idx - 1,
                                   riak_core_ring:chash(Resized))),
    riak_core_ring:schedule_resize_transfer(Resized,
                                            IdxOwner, Target);
schedule_first_resize_transfer(_,
                               {Idx, _Owner} = IdxOwner, NextOwner, Resized) ->
    %% partition is being moved during expansion, schedule transfer to partition
    %% on new owner since it will still own some of its data
    riak_core_ring:schedule_resize_transfer(Resized,
                                            IdxOwner, {Idx, NextOwner}).

%% @private
%% @doc verify that resized ring was properly claimed (no owners are the dummy
%%      resized owner) in both the current and future ring
-spec validate_resized_ring(Ring ::
                                riak_core_ring()) -> {boolean(),
                                                      riak_core_ring()}.

validate_resized_ring(Ring) ->
    FutureRing = riak_core_ring:future_ring(Ring),
    Owners = riak_core_ring:all_owners(Ring),
    FutureOwners = riak_core_ring:all_owners(FutureRing),
    Members = riak_core_ring:all_members(Ring),
    FutureMembers = riak_core_ring:all_members(FutureRing),
    Invalid1 = [{Idx, Owner}
                || {Idx, Owner} <- Owners,
                   not lists:member(Owner, Members)],
    Invalid2 = [{Idx, Owner}
                || {Idx, Owner} <- FutureOwners,
                   not lists:member(Owner, FutureMembers)],
    case Invalid1 ++ Invalid2 of
      [] -> {true, Ring};
      _ -> {false, Ring}
    end.

%% @private
%% @doc Apply the given changes to the ring.
-spec apply_changes(Ring :: riak_core_ring(),
                    Changes :: [change()]) -> riak_core_ring().

apply_changes(Ring, Changes) ->
    NewRing = lists:foldl(fun ({Node, Cmd}, RingAcc2) ->
                                  RingAcc3 = change({Cmd, Node}, RingAcc2),
                                  RingAcc3
                          end,
                          Ring, Changes),
    NewRing.

%% @private
%% @doc Apply a change to the ring.
-spec change(Change :: {action(), node()},
             Ring :: riak_core_ring()) -> riak_core_ring().

change({join, Node}, Ring) ->
    Ring2 = riak_core_ring:add_member(Node, Ring, Node),
    Ring2;
change({leave, Node}, Ring) ->
    Members = riak_core_ring:all_members(Ring),
    lists:member(Node, Members) orelse
      throw(invalid_member),
    Ring2 = riak_core_ring:leave_member(Node, Ring, Node),
    Ring2;
change({remove, Node}, Ring) ->
    Members = riak_core_ring:all_members(Ring),
    lists:member(Node, Members) orelse
      throw(invalid_member),
    Ring2 = riak_core_ring:remove_member(Node, Ring, Node),
    Ring2;
change({{replace, _NewNode}, Node}, Ring) ->
    %% Just treat as a leave, reassignment happens elsewhere
    Ring2 = riak_core_ring:leave_member(Node, Ring, Node),
    Ring2;
change({{force_replace, NewNode}, Node}, Ring) ->
    Indices = riak_core_ring:indices(Ring, Node),
    Reassign = [{Idx, NewNode} || Idx <- Indices],
    Ring2 = riak_core_ring:add_member(NewNode, Ring,
                                      NewNode),
    Ring3 = riak_core_ring:change_owners(Ring2, Reassign),
    Ring4 = riak_core_ring:remove_member(Node, Ring3, Node),
    case riak_core_ring:is_resizing(Ring4) of
      true ->
          replace_node_during_resize(Ring4, Node, NewNode);
      false -> Ring4
    end;
change({{resize, NewRingSize}, _Node}, Ring) ->
    riak_core_ring:resize(Ring, NewRingSize);
change({abort_resize, _Node}, Ring) ->
    riak_core_ring:set_pending_resize_abort(Ring);
change({{set_location, Location}, Node}, Ring) ->
    riak_core_ring:set_node_location(Node, Location, Ring).

%%noinspection ErlangUnboundVariable
%% @private
%% @doc Update claimant with changed ring.
-spec internal_ring_changed(Node :: node(),
                            CState :: riak_core_ring()) -> riak_core_ring().

internal_ring_changed(Node, CState) ->
    {Changed, CState5} = do_claimant(Node, CState,
                                     fun log/2),
    inform_removed_nodes(Node, CState, CState5),
    %% Start/stop converge and rebalance delay timers
    %% (converge delay)
    %%   -- Starts when claimant changes the ring
    %%   -- Stops when the ring converges (ring_ready)
    %% (rebalance delay)
    %%   -- Starts when next changes from empty to non-empty
    %%   -- Stops when next changes from non-empty to empty
    %%
    IsClaimant = riak_core_ring:claimant(CState5) =:= Node,
    WasPending = [] /=
                   riak_core_ring:pending_changes(CState),
    IsPending = [] /=
                  riak_core_ring:pending_changes(CState5),
    %% Outer case statement already checks for ring_ready
    case {IsClaimant, Changed} of
      {true, true} ->
          %% STATS
          %%            riak_core_stat:update(converge_timer_end),
          %% STATS
          %%            riak_core_stat:update(converge_timer_begin);
          ok;
      {true, false} ->
          %% STATS
          %%            riak_core_stat:update(converge_timer_end);
          ok;
      _ -> ok
    end,
    case {IsClaimant, WasPending, IsPending} of
      {true, false, true} ->
          %% STATS
          %%            riak_core_stat:update(rebalance_timer_begin);
          ok;
      {true, true, false} ->
          %% STATS
          %%            riak_core_stat:update(rebalance_timer_end);
          ok;
      _ -> ok
    end,
    %% Set cluster name if it is undefined
    case {IsClaimant, riak_core_ring:cluster_name(CState5)}
        of
      {true, undefined} ->
          ClusterName = {Node, erlang:timestamp()},
          {_, _} =
              riak_core_util:rpc_every_member(riak_core_ring_manager,
                                              set_cluster_name, [ClusterName],
                                              1000),
          ok;
      _ ->
          ClusterName = riak_core_ring:cluster_name(CState5), ok
    end,
    case Changed of
      true ->
          CState6 = riak_core_ring:set_cluster_name(CState5,
                                                    ClusterName),
          riak_core_ring:increment_vclock(Node, CState6);
      false -> CState5
    end.

%% @private
%% @doc Tell newly exiting nodes to shut down.
-spec inform_removed_nodes(Node :: node(),
                           OldRing :: riak_core_ring(),
                           NewRing :: riak_core_ring()) -> ok.

inform_removed_nodes(Node, OldRing, NewRing) ->
    CName = riak_core_ring:cluster_name(NewRing),
    Exiting = riak_core_ring:members(OldRing, [exiting]) --
                [Node],
    Invalid = riak_core_ring:members(NewRing, [invalid]),
    Changed =
        ordsets:intersection(ordsets:from_list(Exiting),
                             ordsets:from_list(Invalid)),
    %% Tell exiting node to shutdown.
    _ = [riak_core_ring_manager:refresh_ring(ExitingNode,
                                             CName)
         || ExitingNode <- Changed],
    ok.

%% @private
%% @doc Do claimant wihout logging.
%% @see do_claimant/3.
-spec do_claimant_quiet(Node :: node(),
                        CState :: riak_core_ring(),
                        Replacing :: orddict:orddict(node(), node()),
                        Seed :: erlang:timestamp()) -> {boolean(),
                                                        riak_core_ring()}.

do_claimant_quiet(Node, CState, Replacing, Seed) ->
    do_claimant(Node, CState, Replacing, Seed,
                fun no_log/2).

%% @private
%% @doc Rebalance the ring.
-spec do_claimant(Node :: node(),
                  CState :: riak_core_ring(), Log :: log()) -> {boolean(),
                                                                riak_core_ring()}.

do_claimant(Node, CState, Log) ->
    do_claimant(Node, CState, [], erlang:timestamp(), Log).

%% @private
%% @doc Rebalance the ring.
-spec do_claimant(Node :: node(),
                  CState :: riak_core_ring(),
                  Replacing :: orddict:orddict(node(), node()),
                  Seed :: erlang:timestamp(), Log :: log()) -> {boolean(),
                                                                riak_core_ring()}.

do_claimant(Node, CState, Replacing, Seed, Log) ->
    AreJoining = are_joining_nodes(CState),
    {C1, CState2} = maybe_update_claimant(Node, CState),
    {C2, CState3} = maybe_handle_auto_joining(Node,
                                              CState2),
    case AreJoining of
      true ->
          %% Do not rebalance if there are joining nodes
          Changed = C1 or C2,
          CState5 = CState3;
      false ->
          {C3, CState4} = maybe_update_ring(Node, CState3,
                                            Replacing, Seed, Log),
          {C4, CState5} = maybe_remove_exiting(Node, CState4),
          Changed = C1 or C2 or C3 or C4
    end,
    {Changed, CState5}.

%% @private
%% @doc Set a new claimant on the ring if necessary.
-spec maybe_update_claimant(Node :: node(),
                            CState :: riak_core_ring()) -> {boolean(),
                                                            riak_core_ring()}.

maybe_update_claimant(Node, CState) ->
    Members = riak_core_ring:members(CState,
                                     [valid, leaving]),
    Claimant = riak_core_ring:claimant(CState),
    NextClaimant = hd(Members ++ [undefined]),
    ClaimantMissing = not lists:member(Claimant, Members),
    case {ClaimantMissing, NextClaimant} of
      {true, Node} ->
          %% Become claimant
          CState2 = riak_core_ring:set_claimant(CState, Node),
          CState3 =
              riak_core_ring:increment_ring_version(Claimant,
                                                    CState2),
          {true, CState3};
      _ -> {false, CState}
    end.

%% @private
%% @doc Update the ring if the conditions are right.
-spec maybe_update_ring(Node :: node(),
                        CState :: riak_core_ring(),
                        Replacing :: orddict:orddict(node(), node()),
                        Seed :: erlang:timestamp(), Log :: log()) -> {boolean(),
                                                                      riak_core_ring()}.

maybe_update_ring(Node, CState, Replacing, Seed, Log) ->
    Claimant = riak_core_ring:claimant(CState),
    case Claimant of
      Node ->
          case riak_core_ring:claiming_members(CState) of
            [] ->
                %% Consider logging an error/warning here or even
                %% intentionally crashing. This state makes no logical
                %% sense given that it represents a cluster without any
                %% active nodes.
                {false, CState};
            _ ->
                Resizing = riak_core_ring:is_resizing(CState),
                {Changed, CState2} = update_ring(Node, CState,
                                                 Replacing, Seed, Log,
                                                 Resizing),
                {Changed, CState2}
          end;
      _ -> {false, CState}
    end.

%% @private
%% @doc Set nodes as invalid on the ring that are exiting.
-spec maybe_remove_exiting(Node :: node(),
                           CState :: riak_core_ring()) -> {boolean(),
                                                           riak_core_ring()}.

maybe_remove_exiting(Node, CState) ->
    Claimant = riak_core_ring:claimant(CState),
    case Claimant of
      Node ->
          %% Change exiting nodes to invalid, skipping this node.
          Exiting = riak_core_ring:members(CState, [exiting]) --
                      [Node],
          Changed = Exiting /= [],
          CState2 = lists:foldl(fun (ENode, CState0) ->
                                        ClearedCS =
                                            riak_core_ring:clear_member_meta(Node,
                                                                             CState0,
                                                                             ENode),
                                        riak_core_ring:set_member(Node,
                                                                  ClearedCS,
                                                                  ENode,
                                                                  invalid,
                                                                  same_vclock)
                                end,
                                CState, Exiting),
          {Changed, CState2};
      _ -> {false, CState}
    end.

%% @private
%% @doc Check if there are nodes joining the ring.
-spec are_joining_nodes(CState ::
                            riak_core_ring()) -> boolean().

are_joining_nodes(CState) ->
    Joining = riak_core_ring:members(CState, [joining]),
    Joining /= [].

%% @private
%% @doc Compute all auto-joining nodes.
-spec auto_joining_nodes(CState ::
                             riak_core_ring()) -> [node()].

auto_joining_nodes(CState) ->
    Joining = riak_core_ring:members(CState, [joining]),
    %%    case application:get_env(riak_core, staged_joins, true) of false -> Joining; true ->
    [Member
     || Member <- Joining,
        riak_core_ring:get_member_meta(CState, Member,
                                       '$autojoin')
          ==
          true].%%    end.

%% @private
%% @doc Handle join of all auto-joining nodes.
-spec maybe_handle_auto_joining(Node :: node(),
                                CState :: riak_core_ring()) -> {boolean(),
                                                                riak_core_ring()}.

maybe_handle_auto_joining(Node, CState) ->
    Auto = auto_joining_nodes(CState),
    maybe_handle_joining(Node, Auto, CState).

%% @private
%% @doc Handle join of joining nodes.
-spec maybe_handle_joining(Node :: node(),
                           CState :: riak_core_ring()) -> {boolean(),
                                                           riak_core_ring()}.

maybe_handle_joining(Node, CState) ->
    Joining = riak_core_ring:members(CState, [joining]),
    maybe_handle_joining(Node, Joining, CState).

%% @private
%% @doc Add joining nodes as valid members to the ring if possible.
-spec maybe_handle_joining(Node :: node(),
                           Joining :: [node()],
                           CState :: riak_core_ring()) -> {boolean(),
                                                           riak_core_ring()}.

maybe_handle_joining(Node, Joining, CState) ->
    Claimant = riak_core_ring:claimant(CState),
    case Claimant of
      Node ->
          Changed = Joining /= [],
          CState2 = lists:foldl(fun (JNode, CState0) ->
                                        riak_core_ring:set_member(Node, CState0,
                                                                  JNode, valid,
                                                                  same_vclock)
                                end,
                                CState, Joining),
          {Changed, CState2};
      _ -> {false, CState}
    end.

%% @private
%% @doc Apply changes to the ring.
-spec update_ring(CNode :: node(),
                  CState :: riak_core_ring(),
                  Replacing :: orddict:orddict(node(), node()),
                  Seed :: erlang:timestamp(), Log :: log(),
                  Resizing :: boolean()) -> {boolean(), riak_core_ring()}.

update_ring(CNode, CState, Replacing, Seed, Log,
            false) ->
    Next0 = riak_core_ring:pending_changes(CState),
    ?ROUT("Members: ~p~n",
          [riak_core_ring:members(CState,
                                  [joining, valid, leaving, exiting,
                                   invalid])]),
    ?ROUT("Updating ring :: next0 : ~p~n", [Next0]),
    %% Remove tuples from next for removed nodes
    InvalidMembers = riak_core_ring:members(CState,
                                            [invalid]),
    Next2 = lists:filter(fun (NInfo) ->
                                 {Owner, NextOwner, _} =
                                     riak_core_ring:next_owner(NInfo),
                                 not lists:member(Owner, InvalidMembers) and
                                   not lists:member(NextOwner, InvalidMembers)
                         end,
                         Next0),
    CState2 = riak_core_ring:set_pending_changes(CState,
                                                 Next2),
    %% Transfer ownership after completed handoff
    {RingChanged1, CState3} = transfer_ownership(CState2,
                                                 Log),
    ?ROUT("Updating ring :: next1 : ~p~n",
          [riak_core_ring:pending_changes(CState3)]),
    %% Ressign leaving/inactive indices
    {RingChanged2, CState4} = reassign_indices(CState3,
                                               Replacing, Seed, Log),
    ?ROUT("Updating ring :: next2 : ~p~n",
          [riak_core_ring:pending_changes(CState4)]),
    %% Rebalance the ring as necessary. If pending changes exist ring
    %% is not rebalanced
    Next3 = rebalance_ring(CNode, CState4),
    Log(debug,
        {"Pending ownership transfers: ~b~n",
         [length(riak_core_ring:pending_changes(CState4))]}),
    %% Remove transfers to/from down nodes
    Next4 = handle_down_nodes(CState4, Next3),
    NextChanged = Next0 /= Next4,
    Changed = NextChanged or RingChanged1 or RingChanged2,
    case Changed of
      true ->
          OldS = ordsets:from_list([{Idx, O, NO}
                                    || {Idx, O, NO, _, _} <- Next0]),
          NewS = ordsets:from_list([{Idx, O, NO}
                                    || {Idx, O, NO, _, _} <- Next4]),
          Diff = ordsets:subtract(NewS, OldS),
          _ = [Log(next, NChange) || NChange <- Diff],
          ?ROUT("Updating ring :: next3 : ~p~n", [Next4]),
          CState5 = riak_core_ring:set_pending_changes(CState4,
                                                       Next4),
          CState6 = riak_core_ring:increment_ring_version(CNode,
                                                          CState5),
          {true, CState6};
      false -> {false, CState}
    end;
update_ring(CNode, CState, _Replacing, _Seed, _Log,
            true) ->
    {Installed, CState1} =
        maybe_install_resized_ring(CState),
    {Aborted, CState2} =
        riak_core_ring:maybe_abort_resize(CState1),
    Changed = Installed orelse Aborted,
    case Changed of
      true ->
          CState3 = riak_core_ring:increment_ring_version(CNode,
                                                          CState2),
          {true, CState3};
      false -> {false, CState}
    end.

%% @private
%% @doc Install the ring if the resize process is completed.
-spec maybe_install_resized_ring(CState ::
                                     riak_core_ring()) -> {boolean(),
                                                           riak_core_ring()}.

maybe_install_resized_ring(CState) ->
    case riak_core_ring:is_resize_complete(CState) of
      true -> {true, riak_core_ring:future_ring(CState)};
      false -> {false, CState}
    end.

%% @private
%% @doc Assign partitions to new owners.
-spec transfer_ownership(CState :: riak_core_ring(),
                         Log :: log()) -> {boolean(), riak_core_ring()}.

transfer_ownership(CState, Log) ->
    Next = riak_core_ring:pending_changes(CState),
    %% Remove already completed and transfered changes
    Next2 = lists:filter(fun (NInfo = {Idx, _, _, _, _}) ->
                                 {_, NewOwner, S} =
                                     riak_core_ring:next_owner(NInfo),
                                 not
                                   ((S == complete) and
                                      (riak_core_ring:index_owner(CState, Idx)
                                         =:= NewOwner))
                         end,
                         Next),
    CState2 = lists:foldl(fun (NInfo = {Idx, _, _, _, _},
                               CState0) ->
                                  case riak_core_ring:next_owner(NInfo) of
                                    {_, Node, complete} ->
                                        Log(ownership, {Idx, Node, CState0}),
                                        riak_core_ring:transfer_node(Idx, Node,
                                                                     CState0);
                                    _ -> CState0
                                  end
                          end,
                          CState, Next2),
    NextChanged = Next2 /= Next,
    RingChanged = riak_core_ring:all_owners(CState) /=
                    riak_core_ring:all_owners(CState2),
    Changed = NextChanged or RingChanged,
    CState3 = riak_core_ring:set_pending_changes(CState2,
                                                 Next2),
    {Changed, CState3}.

%% @private
%% @doc Assign indices owned by replaced nodes to the one replacing them.
-spec reassign_indices(CState :: riak_core_ring(),
                       Replacing :: orddict:orddict(node(), node()),
                       Seed :: erlang:timestamp(), Log :: log()) -> {boolean(),
                                                                     riak_core_ring()}.

reassign_indices(CState, Replacing, Seed, Log) ->
    Next = riak_core_ring:pending_changes(CState),
    Invalid = riak_core_ring:members(CState, [invalid]),
    CState2 = lists:foldl(fun (Node, CState0) ->
                                  remove_node(CState0, Node, invalid, Replacing,
                                              Seed, Log)
                          end,
                          CState, Invalid),
    CState3 = case Next of
                [] ->
                    Leaving = riak_core_ring:members(CState, [leaving]),
                    lists:foldl(fun (Node, CState0) ->
                                        remove_node(CState0, Node, leaving,
                                                    Replacing, Seed, Log)
                                end,
                                CState2, Leaving);
                _ -> CState2
              end,
    Owners1 = riak_core_ring:all_owners(CState),
    Owners2 = riak_core_ring:all_owners(CState3),
    RingChanged = Owners1 /= Owners2,
    NextChanged = Next /=
                    riak_core_ring:pending_changes(CState3),
    {RingChanged or NextChanged, CState3}.

%% @private
-spec rebalance_ring(CNode :: node(),
                     CState :: riak_core_ring()) -> next().

rebalance_ring(CNode, CState) ->
    Next = riak_core_ring:pending_changes(CState),
    rebalance_ring(CNode, Next, CState).

%% @private
%% @doc Run the claim algorithm and compute the differing indices with ld and
%%      new owners.
-spec rebalance_ring(CNode :: node(), Next :: next(),
                     CState :: riak_core_ring()) -> next().

rebalance_ring(_CNode, [], CState) ->
    CState2 = riak_core_claim:claim(CState),
    Owners1 = riak_core_ring:all_owners(CState),
    Owners2 = riak_core_ring:all_owners(CState2),
    Owners3 = lists:zip(Owners1, Owners2),
    Next = [{Idx, PrevOwner, NewOwner, [], awaiting}
            || {{Idx, PrevOwner}, {Idx, NewOwner}} <- Owners3,
               PrevOwner /= NewOwner],
    Next;
rebalance_ring(_CNode, Next, _CState) -> Next.

%% @private
%% @doc Compute List of indices owned by down nodes and their replacements.
-spec handle_down_nodes(CState :: riak_core_ring(),
                        Next :: next()) -> next().

handle_down_nodes(CState, Next) ->
    LeavingMembers = riak_core_ring:members(CState,
                                            [leaving, invalid]),
    DownMembers = riak_core_ring:members(CState, [down]),
    Next2 = [begin
               OwnerLeaving = lists:member(O, LeavingMembers),
               NextDown = lists:member(NO, DownMembers),
               case OwnerLeaving and NextDown of
                 true ->
                     Active = riak_core_ring:active_members(CState) -- [O],
                     RNode = lists:nth(rand:uniform(length(Active)), Active),
                     {Idx, O, RNode, Mods, Status};
                 _ -> T
               end
             end
             || T = {Idx, O, NO, Mods, Status} <- Next],
    Next3 = [T
             || T = {_, O, NO, _, _} <- Next2,
                not lists:member(O, DownMembers),
                not lists:member(NO, DownMembers)],
    Next3.

%% @private
%% @doc Assigns all indices owned by a given node to a new node.
-spec reassign_indices_to(Node :: node(),
                          NewNode :: node(),
                          Ring :: riak_core_ring()) -> riak_core_ring().

reassign_indices_to(Node, NewNode, Ring) ->
    Indices = riak_core_ring:indices(Ring, Node),
    Reassign = [{Idx, NewNode} || Idx <- Indices],
    Ring2 = riak_core_ring:change_owners(Ring, Reassign),
    Ring2.

%% @private
%% @doc Remove a node and compute replacements.
-spec remove_node(CState :: riak_core_ring(),
                  Node :: node(), Status :: invalid | leaving,
                  Replacing :: orddict:orddict(node(), node()),
                  Seed :: erlang:timestamp(),
                  Log :: log()) -> riak_core_ring().

remove_node(CState, Node, Status, Replacing, Seed,
            Log) ->
    Indices = riak_core_ring:indices(CState, Node),
    remove_node(CState, Node, Status, Replacing, Seed, Log,
                Indices).

%% @private
%% @doc Remove a node and compute replacements.
-spec remove_node(CState :: riak_core_ring(),
                  Node :: node(), Status :: invalid | leaving,
                  Replacing :: orddict:orddict(node(), node()),
                  Seed :: erlang:timestamp(), Log :: log(),
                  Indices :: [integer()]) -> riak_core_ring().

remove_node(CState, _Node, _Status, _Replacing, _Seed,
            _Log, []) ->
    CState;
remove_node(CState, Node, Status, Replacing, Seed, Log,
            Indices) ->
    CStateT1 = riak_core_ring:change_owners(CState,
                                            riak_core_ring:all_next_owners(CState)),
    case orddict:find(Node, Replacing) of
      {ok, NewNode} ->
          CStateT2 = reassign_indices_to(Node, NewNode, CStateT1);
      error ->
          CStateT2 =
              riak_core_gossip:remove_from_cluster(CStateT1, Node,
                                                   Seed)
    end,
    Owners1 = riak_core_ring:all_owners(CState),
    Owners2 = riak_core_ring:all_owners(CStateT2),
    Owners3 = lists:zip(Owners1, Owners2),
    RemovedIndices = case Status of
                       invalid -> Indices;
                       leaving -> []
                     end,
    Reassign = [{Idx, NewOwner}
                || {Idx, NewOwner} <- Owners2,
                   lists:member(Idx, RemovedIndices)],
    Next = [{Idx, PrevOwner, NewOwner, [], awaiting}
            || {{Idx, PrevOwner}, {Idx, NewOwner}} <- Owners3,
               PrevOwner /= NewOwner,
               not lists:member(Idx, RemovedIndices)],
    _ = [Log(reassign, {Idx, NewOwner, CState})
         || {Idx, NewOwner} <- Reassign],
    %% Unlike rebalance_ring, remove_node can be called when Next is non-empty,
    %% therefore we need to merge the values. Original Next has priority.
    Next2 = lists:ukeysort(1,
                           riak_core_ring:pending_changes(CState) ++ Next),
    CState2 = riak_core_ring:change_owners(CState,
                                           Reassign),
    CState3 = riak_core_ring:set_pending_changes(CState2,
                                                 Next2),
    CState3.

%% @private
%% @doc Replace a node while respecting an ongoing resize operation.
-spec replace_node_during_resize(CState0 ::
                                     riak_core_ring(),
                                 Node :: node(),
                                 NewNode :: node()) -> riak_core_ring().

replace_node_during_resize(CState0, Node, NewNode) ->
    PostResize = riak_core_ring:is_post_resize(CState0),
    CState1 = replace_node_during_resize(CState0, Node,
                                         NewNode, PostResize),
    riak_core_ring:increment_ring_version(riak_core_ring:claimant(CState1),
                                          CState1).

%% @private
%% @doc Replace a node while respecting an ongoing resize operation.
-spec replace_node_during_resize(CStat0 ::
                                     riak_core_ring(),
                                 Node :: node(), NewNode :: node(),
                                 PostResize :: boolean()) -> riak_core_ring().

replace_node_during_resize(CState0, Node, NewNode,
                           false) -> %% ongoing xfers
    %% for each of the indices being moved from Node to NewNode, reschedule resize
    %% transfers where the target is owned by Node.
    CState1 =
        riak_core_ring:reschedule_resize_transfers(CState0,
                                                   Node, NewNode),
    %% since the resized chash is carried directly in state vs. being rebuilt via next
    %% list, perform reassignment
    {ok, FutureCHash} =
        riak_core_ring:resized_ring(CState1),
    FutureCState = riak_core_ring:set_chash(CState1,
                                            FutureCHash),
    ReassignedFuture = reassign_indices_to(Node, NewNode,
                                           FutureCState),
    ReassignedCHash =
        riak_core_ring:chash(ReassignedFuture),
    riak_core_ring:set_resized_ring(CState1,
                                    ReassignedCHash);
replace_node_during_resize(CState, Node, _NewNode,
                           true) -> %% performing cleanup
    %% we are simply deleting data at this point, no reason to do that on either node
    NewNext = [{I, N, O, M, S}
               || {I, N, O, M, S}
                      <- riak_core_ring:pending_changes(CState),
                  N =/= Node],
    riak_core_ring:set_pending_changes(CState, NewNext).

-spec no_log(any(), any()) -> ok.

no_log(_, _) -> ok.

-spec log(Type :: debug | ownership | reassign | next |
                  any(),
          {Idx :: integer(), NewOwner :: node(),
           CState :: riak_core_ring()}) -> ok.

log(debug, {Msg, Args}) -> logger:debug(Msg, Args);
log(ownership, {Idx, NewOwner, CState}) ->
    Owner = riak_core_ring:index_owner(CState, Idx),
    logger:debug("(new-owner) ~b :: ~p -> ~p~n",
                 [Idx, Owner, NewOwner]);
log(reassign, {Idx, NewOwner, CState}) ->
    Owner = riak_core_ring:index_owner(CState, Idx),
    logger:debug("(reassign) ~b :: ~p -> ~p~n",
                 [Idx, Owner, NewOwner]);
log(next, {Idx, Owner, NewOwner}) ->
    logger:debug("(pending) ~b :: ~p -> ~p~n",
                 [Idx, Owner, NewOwner]);
log(_, _) -> ok.
