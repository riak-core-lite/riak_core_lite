%% -------------------------------------------------------------------
%%
%% Copyright (c) 2014-2015 Basho Technologies, Inc.
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
%% @doc This module encapsulates the command line interface for the
%% "new" cluster commands:
%%
%% status, partition-count, partitions, partition-id, partition-index
%%
%% The "old" command implementations for join, leave, plan, commit,
%% etc are in `riak_core_console.erl'

-module(riak_core_cluster_cli).

-behaviour(clique_handler).

-export([
    register_cli/0,
    status/3,
    partition_count/3,
    partitions/3,
    partition/3
]).

-include_lib("kernel/include/logger.hrl").
-define(CLUSTER_CMD,                    ["riak", "admin", "cluster"]).
-define(CLUSTER_STATUS_CMD,             ["riak", "admin", "cluster", "status"]).
-define(CLUSTER_PARTITION_CMD,          ["riak", "admin", "cluster", "partition"]).
-define(CLUSTER_PARTITIONS_CMD,         ["riak", "admin", "cluster", "partitions"]).
-define(CLUSTER_PARTITION_COUNT_CMD,    ["riak", "admin", "cluster", "partition-count"]).
-define(CLUSTER_LOCATION_CMD,           ["riak", "admin", "cluster", "location"]).
-define(LOCK_CMD,                       ["riak", "admin", "cluster", "lock"]).
-define(LOCK_STATUS_CMD,                ["riak", "admin", "cluster", "lock", "status"]).
-define(LOCK_RELEASE_CMD,               ["riak", "admin", "cluster", "lock", "release"]).
-define(LOCK_ACQUIRE_CMD,               ["riak", "admin", "cluster", "lock", "acquire"]).

register_cli() ->
    register_all_usage(),
    register_all_commands().

register_all_usage() ->
    clique:register_usage(?CLUSTER_CMD,                 cluster_usage()),
    clique:register_usage(?CLUSTER_STATUS_CMD,          status_usage()),
    clique:register_usage(?CLUSTER_PARTITION_CMD,       partition_usage()),
    clique:register_usage(?CLUSTER_PARTITIONS_CMD,      partitions_usage()),
    clique:register_usage(?CLUSTER_PARTITION_COUNT_CMD, partition_count_usage()),
    clique:register_usage(?CLUSTER_LOCATION_CMD,        location_usage()),
    clique:register_usage(?LOCK_CMD,                    lock_usage()),
    clique:register_usage(?LOCK_STATUS_CMD,             lock_status_usage()),
    clique:register_usage(?LOCK_RELEASE_CMD,            lock_release_usage()),
    clique:register_usage(?LOCK_ACQUIRE_CMD,            lock_acquire_usage()).

register_all_commands() ->
    lists:foreach(fun(Args) -> apply(clique, register_command, Args) end,
                  [status_register(), partition_count_register(),
                   partitions_register(), partition_register(), location_register(),
                   lock_status_register(), lock_acquire_register(), lock_release_register()
                  ]).

%%%
%% Lock
%%%

lock_usage() ->
    [
     "riak admin cluster lock <sub-command>\n\n",
     "  Sub-commands:\n",
     "    acquire          Acquire a lock on a cluster\n",
     "    release          Release a lock on a cluster\n",
     "    status           Display status of current lock\n\n",
     "  Use --help after a sub-command for more details.\n"
    ].

lock_status_usage() ->
    [
     "riak admin cluster lock status\n\n",
     "  Displays current lock on cluster.\n\n"
    ].

lock_release_usage() ->
    [
     "riak admin cluster lock release <Ticket>\n\n",
     "  Releases the current lock when passed the correct <Ticket>\n\n"
    ].

lock_acquire_usage() ->
    [
     "riak admin cluster lock acquire <Ticket> <Description>\n\n",
     "  Acquires a lock on a cluster if currently not locked.\n\n"
    ].

lock_status_register() ->
    [?LOCK_STATUS_CMD,
     [],
     [],
     fun lock_status/3].

lock_status(_, _, _) ->
    try
        case riak_core_claimant:cluster_lock_status() of
            {ok, {Ticket, Description, Timestamp}} ->
                [clique_status:list(["Cluster has a lock:\n",
                                    io_lib:format("Ticket:      ~s~n", [Ticket]),
                                    io_lib:format("Description: ~s~n", [Description]),
                                    io_lib:format("Acquired:    ~s~n", [format_utc_timestamp(Timestamp)])
                                   ])];
            {ok, undefined} ->
                [clique_status:text("Cluster does not have a lock.")];
            {error, ring_not_ready} ->
                make_alert(["Ring is not ready, please try again soon."]);
            {error, timed_out} ->
                make_alert(["Timed out while attempting to release lock.",
                           "The lock may still successfully be released.",
                           "Ensure all nodes are up and check lock status."]);

            {error, Error1} ->
                ?LOG_ERROR("Getting lock status failed: ~p", [Error1]),
                make_alert("Getting lock status failed, see log for details")

        end
    catch
        Exception:Reason ->
            ?LOG_ERROR("Getting lock status failed ~p:~p", [Exception, Reason]),
            make_alert("Getting lock status failed, see log for details")
    end.

lock_acquire_register() ->
    [?LOCK_ACQUIRE_CMD ++ ['*', '*'], %% Ticket, Description
     [],
     [],
     fun lock_acquire/3].

lock_acquire([_, _, _, _, _, TicketStr, DescriptionStr], _, _) ->
    Ticket = convert_string(TicketStr),
    Description = convert_string(DescriptionStr),
    try
        %% TODO aef- make actions blocking if possible with some timeout
        case riak_core_claimant:acquire_cluster_lock(Ticket, Description) of
            %% 1 is pending
            {ok, lock_acquired} ->
                [clique_status:list([
                                    "Cluster has a lock:\n",
                                    io_lib:format("Ticket:      ~s~n", [TicketStr]),
                                    io_lib:format("Description: ~s~n", [DescriptionStr])
                                ])];
            {error, lock_unavailable} ->
                make_alert("Cluster already has lock.");
            {error, ring_not_ready} ->
                make_alert(["Ring is not ready, please try again soon."]);
            {error, ticket_too_long} ->
                make_alert("Ticket must be less than 51 characters.");
            {error, description_too_long} ->
                make_alert("Description must be less than 151 characters.");
            {error, timed_out} ->
                make_alert(["Timed out while attempting to acquire lock.",
                            "The lock may still successfully be acquired.",
                            "Ensure all nodes are up and check lock status."]);
            {error, Error1} ->
                ?LOG_ERROR("Acquiring lock failed ~p", [Error1]),
                make_alert("Acquiring lock failed, see log for details.")
        end
    catch
        Exception:Reason ->
            ?LOG_ERROR("Acquiring lock failed ~p ~p", [Exception, Reason]),
            make_alert("Acquiring lock failed, see log for details.")
  end.

lock_release_register() ->
    [?LOCK_RELEASE_CMD ++ ['*'], %% Ticket
     [],
     [],
     fun lock_release/3].

lock_release([_, _, _, _, _, TicketStr], _, _) ->
    Ticket = convert_string(TicketStr),
    try
        case riak_core_claimant:release_cluster_lock(Ticket) of
            {ok, no_lock} ->
                [clique_status:text("No lock exists on the cluster.")];
            {ok, lock_released} ->
                [clique_status:text("Lock has been released")];
            {error, ring_not_ready} ->
                make_alert(["Ring is not ready, please try again soon."]);
            {error, timed_out} ->
                make_alert(["Timed out while attempting to release lock.",
                            "The lock may still successfully be released.",
                            "Ensure all nodes are up and check lock status."]);
            {error, wrong_ticket} ->
                make_alert(
                  ["Ticket does not match current lock."]
                 );
            {error, Error1} ->
                ?LOG_ERROR("Releasing lock failed ~p", [Error1]),
                make_alert("Releasing lock failed, see log for details.")
        end
    catch
        Exception:Reason ->
            ?LOG_ERROR("Releasing lock failed ~p ~p", [Exception, Reason]),
            make_alert("Releasing lock failed, see log for details.")
  end.

-spec convert_string(list()) -> unicode:chardata()|unexpected_string_input.
convert_string(InputText) ->
    case unicode:characters_to_binary(InputText) of
        CharData when is_binary(CharData) ->
            CharData;
        _ ->
            unexpected_string_input
    end.

format_utc_timestamp(TS) ->
    {{Year,Month,Day}, {Hour,Minute,_Second}} = calendar:now_to_universal_time(TS),
    Mstr = element(Month,{"Jan","Feb","Mar","Apr","May","Jun","Jul",
                          "Aug","Sep","Oct","Nov","Dec"}),
    io_lib:format("~2w ~s ~4w ~2w:~2..0w", [Day,Mstr,Year,Hour,Minute]).

%%%
%% Cluster status
%%%

status_register() ->
    [?CLUSTER_STATUS_CMD,
     [],                                  % KeySpecs
     [],                                  % FlagSpecs
     fun status/3].                       % Implementation callback.

cluster_usage() ->
    [
     "riak admin cluster <sub-command>\n\n",
     "  Display cluster-related status and settings.\n\n",
     "  Sub-commands:\n",
     "    status           Display a summary of cluster status\n",
     "    partition        Map partition IDs to indexes\n",
     "    partitions       Display partitions on a node\n",
     "    partition-count  Display ring size or node partition count\n\n",
     "    location         Set node location\n\n",
     "    lock             Manage the global cluster lock\n\n",
     "  Use --help after a sub-command for more details.\n"
    ].

status_usage() ->
    ["riak admin cluster status\n\n",
     "  Display a summary of cluster status information.\n"].

future_claim_percentage([], _Ring, _Node) ->
    "--";
future_claim_percentage(_Changes, Ring, Node) ->
    FutureRingSize = riak_core_ring:future_num_partitions(Ring),
    NextIndices = riak_core_ring:future_indices(Ring, Node),
    io_lib:format("~5.1f", [length(NextIndices) * 100 / FutureRingSize]).

claim_percent(Ring, Node) ->
    RingSize = riak_core_ring:num_partitions(Ring),
    Indices = riak_core_ring:indices(Ring, Node),
    io_lib:format("~5.1f", [length(Indices) * 100 / RingSize]).

status(_CmdBase, [], []) ->
    {ok, Ring} = riak_core_ring_manager:get_my_ring(),
    RingStatus = riak_core_status:ring_status(),
    %% {Claimant, RingReady, Down, MarkedDown, Changes} = RingStatus
    %%
    %% Group like statuses together
    AllStatus = lists:keysort(2, riak_core_ring:all_member_status(Ring)),

    Rows = [ format_status(Node, Status, Ring, RingStatus) ||
      {Node, Status} <- AllStatus ],

    Table = clique_status:table(Rows),

    T0 = clique_status:text("---- Cluster Status ----"),
    T1 = clique_status:text(io_lib:format("Ring ready: ~p~n", [element(2, RingStatus)])),
    T2 = clique_status:text(
           "Key: (C) = Claimant; availability marked with '!' is unexpected"),
    [T0,T1,Table,T2].

format_status(Node, Status, Ring, RingStatus) ->
  NodesLocations = riak_core_ring:get_nodes_locations(Ring),
  HasLocationInCluster = riak_core_location:has_location_set_in_cluster(NodesLocations),
  format_status(Node, Status, Ring, RingStatus, HasLocationInCluster, NodesLocations).

format_status(Node, Status, Ring, RingStatus, false, _) ->
  {Claimant, _RingReady, Down, MarkedDown, Changes} = RingStatus,
  [{node, is_claimant(Node, Claimant)},
   {status, Status},
   {avail, node_availability(Node, Down, MarkedDown)},
   {ring, claim_percent(Ring, Node)},
   {pending, future_claim_percentage(Changes, Ring, Node)}];
format_status(Node, Status, Ring, RingStatus, true, NodesLocations) ->
  Row = format_status(Node, Status, Ring, RingStatus, false, NodesLocations),
  Row ++ [{location, riak_core_location:get_node_location(Node, NodesLocations)}].

is_claimant(Node, Node) ->
    " (C) " ++ atom_to_list(Node) ++ " ";
is_claimant(Node, _Other) ->
    "     " ++ atom_to_list(Node) ++ " ".

node_availability(Node, Down, MarkedDown) ->
    case {lists:member(Node, Down), lists:member(Node, MarkedDown)} of
         {false, false} -> "  up   ";
         {true,  true } -> " down  ";
         {true,  false} -> " down! ";
         {false, true } -> "  up!  "
    end.

%%%
%% cluster partition-count
%%%

partition_count_register() ->
    [?CLUSTER_PARTITION_COUNT_CMD,
     [],                                           % KeySpecs
     [{node, [{shortname, "n"}, {longname, "node"},
              {typecast,
               fun clique_typecast:to_node/1}]}],% FlagSpecs
     fun partition_count/3].                       % Implementation callback

partition_count_usage() ->
    ["riak admin cluster partition-count [--node node]\n\n",
     "  Display the number of partitions (ring-size) for the entire\n",
     "  cluster or the number of partitions on a specific node.\n\n",
     "Options\n",
     "  -n <node>, --node <node>\n",
     "      Display the handoffs on the specified node.\n",
     "      This flag can currently take only one node and be used once\n"
    ].

partition_count(_CmdBase, [], [{node, Node}]) ->
    {ok, Ring} = riak_core_ring_manager:get_my_ring(),
    Indices = riak_core_ring:indices(Ring, Node),
    Row = [[{node, Node}, {partitions, length(Indices)}, {pct, claim_percent(Ring, Node)}]],
    [clique_status:table(Row)];
partition_count(_CmdBase, [], []) ->
    {ok, Ring} = riak_core_ring_manager:get_my_ring(),
    [clique_status:text(
         io_lib:format("Cluster-wide partition-count: ~p",
                       [riak_core_ring:num_partitions(Ring)]))].

%%%
%% cluster partitions
%%%

partitions_register() ->
    [?CLUSTER_PARTITIONS_CMD,
     [],                                           % KeySpecs
     [{node, [{shortname, "n"}, {longname, "node"},
              {typecast,
               fun clique_typecast:to_node/1}]}],% FlagSpecs
     fun partitions/3].                            % Implementation callback


partitions_usage() ->
    ["riak admin cluster partitions [--node node]\n\n",
     "  Display the partitions on a node. Defaults to local node.\n\n",
     "Options\n",
     "  -n <node>, --node <node>\n",
     "      Display the handoffs on the specified node.\n",
     "      This flag can currently take only one node and be used once\n"
    ].

partitions(_CmdBase, [], [{node, Node}]) ->
    partitions_output(Node);
partitions(_CmdBase, [], []) ->
    partitions_output(node()).

partitions_output(Node) ->
    {ok, Ring} = riak_core_ring_manager:get_my_ring(),
    RingSize = riak_core_ring:num_partitions(Ring),
    {Primary, Secondary, Stopped} = riak_core_status:partitions(Node, Ring),
    T0 = clique_status:text(io_lib:format("Partitions owned by ~p:", [Node])),
    Rows = generate_rows(RingSize, primary, Primary)
           ++ generate_rows(RingSize, secondary, Secondary)
           ++ generate_rows(RingSize, stopped, Stopped),
    Table = clique_status:table(Rows),
    [T0, Table].

generate_rows(_RingSize, Type, []) ->
    [[{type, Type}, {index, "--"}, {id, "--"}]];
generate_rows(RingSize, Type, Ids) ->
    %% Build a list of proplists, one for each partition id
    [
      [ {type, Type}, {index, I},
        {id, hash_to_partition_id(I, RingSize)} ]
    || I <- Ids ].

%%%
%% cluster partition id=0
%% cluster partition index=576460752303423500
%%%

partition_register() ->
    [?CLUSTER_PARTITION_CMD,
     [{id,    [{typecast, fun list_to_integer/1}]},
      {index, [{typecast, fun list_to_integer/1}]}], % KeySpecs
     [],                                             % FlagSpecs
     fun partition/3].                               % Implementation callback

partition_usage() ->
    ["riak admin cluster partition id=0\n",
     "riak admin cluster partition index=228359630832953580969325755111919221821\n\n",
     "  Display the id for the provided index, or index for the ",
     "specified id.\n"].

partition(_CmdBase, [{index, Index}], []) when Index >= 0 ->
    id_out(index, Index);
partition(_CmdBase, [{id, Id}], []) when Id >= 0 ->
    id_out(id, Id);
partition(_CmdBase, [{Op, Value}], []) ->
    [make_alert(["ERROR: The given value ", integer_to_list(Value),
                " for ", atom_to_list(Op), " is invalid."])];
partition(_CmdBase, [], []) ->
    clique_status:usage().

id_out(InputType, Number) ->
    {ok, Ring} = riak_core_ring_manager:get_my_ring(),
    RingSize = riak_core_ring:num_partitions(Ring),
    [id_out1(InputType, Number, Ring, RingSize)].

id_out1(index, Index, Ring, RingSize) ->
    case riak_core_ring_util:hash_is_partition_boundary(Index, RingSize) of
        true ->
            Owner = riak_core_ring:index_owner(Ring, Index),
            clique_status:table([
                [{index, Index},
                 {id, hash_to_partition_id(Index, RingSize)},
                 {node, Owner}]]);
        false ->
            make_alert(["ERROR: Index ", integer_to_list(Index),
                        " isn't a partition boundary value."])
    end;
id_out1(id, Id, Ring, RingSize) when Id < RingSize ->
    Idx = partition_id_to_hash(Id, RingSize),
    Owner = riak_core_ring:index_owner(Ring, Idx),
    clique_status:table([[{index, Idx}, {id, Id}, {node, Owner}]]);
id_out1(id, Id, _Ring, _RingSize) ->
    make_alert(["ERROR: Id ", integer_to_list(Id), " is invalid."]).


%%%
%% Location
%%%
location_usage() ->
  ["riak admin cluster location <new_location> [--node node]\n\n",
   "  Set the node location parameter\n\n",
   "Options\n",
   "  -n <node>, --node <node>\n",
   "      Set node location for the specified node.\n"
  ].

location_register() ->
  [?CLUSTER_LOCATION_CMD ++ ['*'],
   [], % KeySpecs
   [{node, [{shortname, "n"}, {longname, "node"},
            {typecast, fun clique_typecast:to_node/1}]}], % FlagSpecs
    fun stage_set_location/3].                            % Implementation callback

stage_set_location([_, _, _, _, Location], _, Flags) ->
  Node = proplists:get_value(node, Flags, node()),
  try
    case riak_core_claimant:set_node_location(Node, Location) of
      ok ->
        [clique_status:text(
          io_lib:format("Success: staged changing location of node ~p to ~s~n",
                        [Node, Location]))];
      {error, not_member} ->
        make_alert(
          io_lib:format("Failed: ~p is not a member of the cluster.~n", [Node])
        )
    end
  catch
    Exception:Reason ->
      ?LOG_ERROR("Setting node location failed ~p:~p", [Exception, Reason]),
      make_alert("Setting node location failed, see log for details~n")
  end.


%%%
%% Internal
%%%

make_alert(Iolist) ->
    Text = [clique_status:text(Iolist)],
    {exit_status, 1, [clique_status:alert(Text)]}.

hash_to_partition_id(Hash, RingSize) ->
    riak_core_ring_util:hash_to_partition_id(Hash, RingSize).

partition_id_to_hash(Id, RingSize) ->
    riak_core_ring_util:partition_id_to_hash(Id, RingSize).

