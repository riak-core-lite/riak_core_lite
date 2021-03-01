%% -------------------------------------------------------------------
%%
%% riak_handoff_listener: entry point for TCP-based handoff
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

%% @doc entry point for TCP-based handoff

-module(riak_core_handoff_listener).

-behaviour(gen_nb_server).

-export([start_link/0]).

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-export([get_handoff_ip/0,
         sock_opts/0,
         new_connection/2]).

-record(state,
        {ipaddr :: string(), portnum :: integer()}).

-type state() :: #state{}.

-type sock_opts() :: binary |
                     {packet, integer()} |
                     {reuseaddr, boolean()} |
                     {backlog, integer()}.

%% @doc Start the handoff listener listening on the configered ip and port.
%% @see gen_nb_server:start_link/4.
-spec start_link() -> {ok, pid()} | {error, any()}.

start_link() ->
    PortNum = application:get_env(riak_core,
                                  handoff_port,
                                  undefined),
    IpAddr = application:get_env(riak_core,
                                 handoff_ip,
                                 undefined),
    gen_nb_server:start_link(?MODULE,
                             IpAddr,
                             PortNum,
                             [IpAddr, PortNum]).

%% @doc Return the IP address this server is listening to.
-spec get_handoff_ip() -> string().

get_handoff_ip() ->
    gen_server:call(?MODULE, handoff_ip, infinity).

%% @doc Callback for {@link gen_nb_server:start_link/4}. Sets the IP address and
%%      port number in the state.
%% @param Params List of prameters. Takes two elements: `IpAddr :: string()' and
%%        `PortNum :: integer()'.
%% @returns `{ok, State}'
-spec init(Params :: [any()]) -> {ok, state()}.

init([IpAddr, PortNum]) ->
    register(?MODULE, self()),
    {ok, #state{portnum = PortNum, ipaddr = IpAddr}}.

%% @doc Socket options.
%% @returns Current socket options. currently they are fixed with
%%          `[binary, {packet, 4}, {reuseaddr, true}, {backlog, 64}]'.
-spec sock_opts() -> [sock_opts()].

sock_opts() ->
    [binary, {packet, 4}, {reuseaddr, true}, {backlog, 64}].

%% @doc Callback for {@link gen_nb_server:call/3}.
-spec handle_call(Msg :: handoff_ip | handoff_port,
		  From :: {pid(), term()}, State :: state()) -> {reply,
								 {ok,
								  string() |
								  integer()},
								 state()}.

handle_call(handoff_ip, _From,
	    State = #state{ipaddr = I}) ->
    {reply, {ok, I}, State};
handle_call(handoff_port, _From,
	    State = #state{portnum = P}) ->
    {reply, {ok, P}, State}.

%% @doc Callback for {@link gen_nb_server:cast/2}. Not implemented.
-spec handle_cast(Msg :: term(),
		  State :: state()) -> {noreply, state()}.

handle_cast(_Msg, State) -> {noreply, State}.

%% @doc Callback for {@link gen_nb_server}. Not implemented.
-spec handle_info(Info :: term(),
		  State :: state()) -> {noreply, state()}.

handle_info(_Info, State) -> {noreply, State}.

%% @doc Callback for {@link gen_nb_serer}. Not implemented.
-spec terminate(Reason :: term(),
		State :: state()) -> ok.

terminate(_Reason, _State) -> ok.

%% @doc Callback for {@link gen_nb_server}. Not implemented.
-spec code_change(OldVsn :: term(), State :: state(),
		  Extra :: term()) -> {ok, state()}.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%% @doc Try opening a new inbound connection. If it cannot be opened, close the
%%      socket. Otherwise Set the socket for {@link riak_core_handoff_receiver}.
%% @param Socket Socket the new connection is requested on.
%% @param State Current state.
%% @return `{ok, State}'.
-spec new_connection(Socket :: inet:socket(),
		     State :: state()) -> {ok, state()}.

new_connection(Socket, State) ->
    case riak_core_handoff_manager:add_inbound() of
        {ok, Pid} ->
            ok = gen_tcp:controlling_process(Socket, Pid),
            ok = riak_core_handoff_receiver:set_socket(Pid, Socket),
            {ok, State};
        {error, _Reason} ->
            %% STATS
            %%            riak_core_stat:update(rejected_handoffs),
            gen_tcp:close(Socket),
            {ok, State}
    end.
