%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007-2012 Basho Technologies, Inc.  All Rights Reserved.
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

%% @doc incoming data handler for TCP-based handoff

-module(riak_core_handoff_receiver).

-include("riak_core_handoff.hrl").

-behaviour(gen_server).

-export([start_link/0,
         set_socket/2,
         supports_batching/0]).

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(state,
        {sock :: port() | undefined,
         peer :: term(),
         recv_timeout_len :: non_neg_integer(),
         vnode_timeout_len :: non_neg_integer(),
         partition :: non_neg_integer() | undefined,
         vnode_mod = riak_kv_vnode :: module(),
         vnode :: pid() | undefined,
         count = 0 :: non_neg_integer()}).

-type state() :: #state{}.

%% set the TCP receive timeout to five minutes to be conservative.
-define(RECV_TIMEOUT, 300000).

%% set the timeout for the vnode to process the handoff_data msg to 60s
-define(VNODE_TIMEOUT, 60000).

%% @doc Starts the receiver server.
%% @see gen_server:start_link/3.
-spec start_link() -> {ok, pid()} |
                      ignore |
                      {error, {already_started, pid()} | term()}.

start_link() -> gen_server:start_link(?MODULE, [], []).

%% @doc Set the socket to listen to.
%% @param Pid Process ID of the receiver.
%% @param Socket Socket to listen to.
%% @returns `ok'.
-spec set_socket(Pid :: pid(),
                 Socket :: inet:socket()) -> ok.

set_socket(Pid, Socket) ->
    gen_server:call(Pid, {set_socket, Socket}).

%% @doc CHeck if the receiver supports batching. Currently every receiver
%%      supports batching.
-spec supports_batching() -> true.

supports_batching() -> true.

%% @doc Callback for {@link gen_server:start_link/3}. Sets the default timeouts.
-spec init([]) -> {ok, state()}.

init([]) ->
    {ok,
     #state{recv_timeout_len =
                application:get_env(riak_core,
                                    handoff_receive_timeout,
                                    ?RECV_TIMEOUT),
            vnode_timeout_len =
                application:get_env(riak_core,
                                    handoff_receive_vnode_timeout,
                                    ?VNODE_TIMEOUT)}}.

%% @doc Callback for {@link gen_server:call/3}.
-spec handle_call(Msg :: {set_socket, inet:socket()},
                  From :: {pid(), term()}, State :: state()) -> {reply,
                                                                 ok, state()}.

handle_call({set_socket, Socket0}, _From, State) ->
    SockOpts = [{active, once}, {packet, 4}, {header, 1}],
    ok = inet:setopts(Socket0, SockOpts),
    Peer = safe_peername(Socket0, inet),
    Socket = Socket0,
    {reply, ok, State#state{sock = Socket, peer = Peer}}.

%% @doc Callback for {@link gen_server}. Handles tcp messages.
-spec handle_info(Msg :: term(),
                  State :: state()) -> {stop, normal, state()} |
                                       {noreply, state(), non_neg_integer()}.

handle_info({tcp_closed, _Socket},
            State = #state{partition = Partition, count = Count,
                           peer = Peer}) ->
    logger:info("Handoff receiver for partition ~p exited "
                "after processing ~p objects from ~p",
                [Partition, Count, Peer]),
    {stop, normal, State};
handle_info({tcp_error, _Socket, Reason},
            State = #state{partition = Partition, count = Count,
                           peer = Peer}) ->
    logger:info("Handoff receiver for partition ~p exited "
                "after processing ~p objects from ~p: "
                "TCP error ~p",
                [Partition, Count, Peer, Reason]),
    {stop, normal, State};
handle_info({tcp, Socket, Data}, State) ->
    [MsgType | MsgData] = Data,
    case catch process_message(MsgType, MsgData, State) of
        {'EXIT', Reason} ->
            logger:error("Handoff receiver for partition ~p exited "
                         "abnormally after processing ~p objects "
                         "from ~p: ~p",
                         [State#state.partition,
                          State#state.count,
                          State#state.peer,
                          Reason]),
            {stop, normal, State};
        NewState when is_record(NewState, state) ->
            inet:setopts(Socket, [{active, once}]),
            {noreply, NewState, State#state.recv_timeout_len}
    end;
handle_info(timeout, State) ->
    logger:error("Handoff receiver for partition ~p timed "
                 "out after processing ~p objects from "
                 "~p.",
                 [State#state.partition,
                  State#state.count,
                  State#state.peer]),
    {stop, normal, State}.

%% @private
%% @doc Process incoming tcp messages. If the message leads to an error,
%%      {@link erlang:exit/1} is called.
%% @param MsgType Code for the type of message.
%% @param MsgData Binary encoding of data.
%% @param State Current state.
%% @returns The updated state after the message has been processed.
-spec process_message(MsgType :: integer(),
                      MsgData :: binary(), State :: state()) -> state().

process_message(?PT_MSG_INIT, MsgData,
                State = #state{vnode_mod = VNodeMod, peer = Peer}) ->
    <<Partition:160/integer>> = MsgData,
    logger:info("Receiving handoff data for partition "
                "~p:~p from ~p",
                [VNodeMod, Partition, Peer]),
    {ok, VNode} =
        riak_core_vnode_master:get_vnode_pid(Partition,
                                             VNodeMod),
    Data = [{mod_src_tgt, {VNodeMod, undefined, Partition}},
            {vnode_pid, VNode}],
    riak_core_handoff_manager:set_recv_data(self(), Data),
    State#state{partition = Partition, vnode = VNode};
process_message(?PT_MSG_BATCH, MsgData, State) ->
    lists:foldl(fun (Obj, StateAcc) ->
                        process_message(?PT_MSG_OBJ, Obj, StateAcc)
                end,
                State,
                binary_to_term(MsgData));
process_message(?PT_MSG_OBJ, MsgData,
                State = #state{vnode = VNode, count = Count,
                               vnode_timeout_len = VNodeTimeout}) ->
    try riak_core_vnode:handoff_data(VNode,
                                     MsgData,
                                     VNodeTimeout)
    of
        ok -> State#state{count = Count + 1};
        E = {error, _} -> exit(E)
    catch
        exit:{timeout, _} ->
            exit({error,
                  {vnode_timeout,
                   VNodeTimeout,
                   size(MsgData),
                   binary:part(MsgData, {0, min(size(MsgData), 128)})}})
    end;
process_message(?PT_MSG_OLDSYNC, MsgData,
                State = #state{sock = Socket}) ->
    gen_tcp:send(Socket, <<(?PT_MSG_OLDSYNC):8, "sync">>),
    <<VNodeModBin/binary>> = MsgData,
    VNodeMod = binary_to_atom(VNodeModBin, utf8),
    State#state{vnode_mod = VNodeMod};
process_message(?PT_MSG_SYNC, _MsgData,
                State = #state{sock = Socket}) ->
    gen_tcp:send(Socket, <<(?PT_MSG_SYNC):8, "sync">>),
    State;
process_message(?PT_MSG_VERIFY_NODE, ExpectedName,
                State = #state{sock = Socket, peer = Peer}) ->
    case binary_to_term(ExpectedName) of
        _Node when _Node =:= node() ->
            gen_tcp:send(Socket, <<(?PT_MSG_VERIFY_NODE):8>>),
            State;
        Node ->
            logger:error("Handoff from ~p expects us to be ~s "
                         "but we are ~s.",
                         [Peer, Node, node()]),
            exit({error, {wrong_node, Node}})
    end;
process_message(?PT_MSG_CONFIGURE, MsgData, State) ->
    ConfProps = binary_to_term(MsgData),
    State#state{vnode_mod =
                    proplists:get_value(vnode_mod, ConfProps),
                partition = proplists:get_value(partition, ConfProps)};
process_message(_, _MsgData,
                State = #state{sock = Socket}) ->
    gen_tcp:send(Socket,
                 <<(?PT_MSG_UNKNOWN):8, "unknown_msg">>),
    State.

%% @doc Callback for {@link gen_server:cast/2}. Not implemented.
-spec handle_cast(Msg :: term(),
                  State :: state()) -> {noreply, state()}.

handle_cast(_Msg, State) -> {noreply, State}.

%% @doc Callback for {@link gen_server:stop/1}. Not implemented.
-spec terminate(Reason :: term(),
                State :: state()) -> ok.

terminate(_Reason, _State) -> ok.

%% @doc Callback for {@link gen_server}. Not implemented.
-spec code_change(OldVsn :: term() | {down, term()},
                  State :: state(), Extra :: term()) -> {ok, state()}.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%% @private
%% @doc Transforms a socket to a safe peername via a module's callback function.
%% @param Skt Socket to create the peername for.
%% @param Module Module creating the peername.
%% @returns Tuple containing the IP address as a string and port as an integer.
-spec safe_peername(Skt :: inet:socket(),
                    Module :: module()) -> {string(), integer()} |
                                           {unknown, unknown}.

safe_peername(Skt, Module) ->
    case Module:peername(Skt) of
        {ok, {Host, Port}} -> {inet_parse:ntoa(Host), Port};
        _ ->
            {unknown,
             unknown}                  % Real info is {Addr, Port}
    end.
