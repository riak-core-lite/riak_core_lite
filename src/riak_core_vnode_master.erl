%% -------------------------------------------------------------------
%%
%% riak_vnode_master: dispatch to vnodes
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

%% @doc dispatch to vnodes

-module(riak_core_vnode_master).

-include("riak_core_vnode.hrl").

-behaviour(gen_server).

-export([start_link/1,
         get_vnode_pid/2,
         start_vnode/2,
         command/3,
         command/4,
         command_unreliable/3,
         command_unreliable/4,
         sync_command/3,
         sync_command/4,
         coverage/5,
         command_return_vnode/4,
         sync_spawn_command/3,
         all_nodes/1,
         reg_name/1]).

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(state, {idxtab, sup_name, vnode_mod}).

-define(LONG_TIMEOUT, 120 * 1000).

%-type riak_vnode_req_v1() :: #riak_vnode_req_v1{}.

-type riak_coverage_req_v1() :: #riak_coverage_req_v1{}.

make_name(VNodeMod, Suffix) ->
    list_to_atom(atom_to_list(VNodeMod) ++ Suffix).

reg_name(VNodeMod) -> make_name(VNodeMod, "_master").

%% Given atom 'riak_kv_vnode_master', return 'riak_kv_vnode'.
vmaster_to_vmod(VMaster) ->
    L = atom_to_list(VMaster),
    list_to_atom(lists:sublist(L, length(L) - 7)).

start_link(VNodeMod) ->
    RegName = reg_name(VNodeMod),
    gen_server:start_link({local, RegName},
                          ?MODULE,
                          [VNodeMod, RegName],
                          []).

start_vnode(Index, VNodeMod) ->
    riak_core_vnode_manager:start_vnode(Index, VNodeMod).

get_vnode_pid(Index, VNodeMod) ->
    riak_core_vnode_manager:get_vnode_pid(Index, VNodeMod).

command(Preflist, Msg, VMaster) ->
    command2(Preflist, Msg, ignore, VMaster, normal).

command_unreliable(Preflist, Msg, VMaster) ->
    command2(Preflist, Msg, ignore, VMaster, unreliable).

command(PrefListOrCmd, Msg, Sender, VMaster) ->
    command2(PrefListOrCmd, Msg, Sender, VMaster, normal).

command_unreliable(PrefListOrCmd, Msg, Sender,
                   VMaster) ->
    command2(PrefListOrCmd,
             Msg,
             Sender,
             VMaster,
             unreliable).

%% Send the command to the preflist given with responses going to Sender
command2([], _Msg, _Sender, _VMaster, _How) -> ok;
command2([{Index, Pid} | Rest], Msg, Sender, VMaster,
         How = normal)
    when is_pid(Pid) ->
    Request = #riak_vnode_req_v1{request = Msg, sender = Sender, index = Index},
    riak_core_vnode:send_req(Pid, Request),
    command2(Rest, Msg, Sender, VMaster, How);
command2([{Index, Pid} | Rest], Msg, Sender, VMaster,
         How = unreliable)
    when is_pid(Pid) ->
    riak_core_send_msg:send_event_unreliable(Pid,
                                             #riak_vnode_req_v1{request = Msg, sender = Sender, index = Index}),
    command2(Rest, Msg, Sender, VMaster, How);
command2([{Index, Node} | Rest], Msg, Sender, VMaster,
         How) ->
    proxy_cast({VMaster, Node},
               #riak_vnode_req_v1{request = Msg, sender = Sender, index = Index},
               How),
    command2(Rest, Msg, Sender, VMaster, How);
command2(DestTuple, Msg, Sender, VMaster, How)
    when is_tuple(DestTuple) ->
    %% Final case, tuple = single destination ... so make a list and
    %% resubmit to this function.
    command2([DestTuple], Msg, Sender, VMaster, How).

%% Send a command to a covering set of vnodes
coverage(Msg, CoverageVNodes, Keyspaces,
         {Type, Ref, From}, VMaster)
    when is_list(CoverageVNodes) ->
    [proxy_cast({VMaster, Node},
                make_coverage_request(Msg,
                                      Keyspaces,
                                      {Type, {Ref, {Index, Node}}, From},
                                      Index))
     || {Index, Node} <- CoverageVNodes];
coverage(Msg, {Index, Node}, Keyspaces, Sender,
         VMaster) ->
    proxy_cast({VMaster, Node},
               make_coverage_request(Msg, Keyspaces, Sender, Index)).

%% Send the command to an individual Index/Node combination, but also
%% return the pid for the vnode handling the request, as `{ok, VnodePid}'.
command_return_vnode({Index, Node}, Msg, Sender,
                     VMaster) ->
    Req = #riak_vnode_req_v1{request = Msg, sender = Sender, index = Index},
    Mod = vmaster_to_vmod(VMaster),
    riak_core_vnode_proxy:command_return_vnode({Mod,
                                                Index,
                                                Node},
                                               Req).

%% Send a synchronous command to an individual Index/Node combination.
%% Will not return until the vnode has returned
sync_command(IndexNode, Msg, VMaster) ->
    sync_command(IndexNode, Msg, VMaster, ?LONG_TIMEOUT).

sync_command({Index, Node}, Msg, VMaster, Timeout) ->
    %% Issue the call to the master, it will update the Sender with
    %% the From for handle_call so that the {reply} return gets
    %% sent here.
    case gen_server:call({VMaster, Node}, {call, {Index, Msg}}, Timeout)
        of
        {vnode_error, {Error, _Args}} -> error(Error);
        {vnode_error, Error} -> error(Error);
        Else -> Else
    end.

%% Send a synchronous spawned command to an individual Index/Node combination.
%% Will not return until the vnode has returned, but the vnode_master will
%% continue to handle requests.
sync_spawn_command({Index, Node}, Msg, VMaster) ->
    case gen_server:call({VMaster, Node}, {spawn, {Index, Msg}}, infinity) of
        {vnode_error, {Error, _Args}} -> error(Error);
        {vnode_error, Error} -> error(Error);
        Else -> Else
    end.

%% Make a request record - exported for use by legacy modules
-spec make_coverage_request(vnode_req(), keyspaces(),
                            sender(), partition()) -> riak_coverage_req_v1().

make_coverage_request(Request, KeySpaces, Sender,
                      Index) ->
    #riak_coverage_req_v1{index = Index,
                          keyspaces = KeySpaces, sender = Sender,
                          request = Request}.

%% Request a list of Pids for all vnodes
%% @deprecated
%% Provided for compatibility with older vnode master API. New code should
%% use riak_core_vnode_manager:all_vnode/1 which returns a mod/index/pid
%% list rather than just a pid list.
all_nodes(VNodeMod) ->
    VNodes = riak_core_vnode_manager:all_vnodes(VNodeMod),
    [Pid || {_Mod, _Idx, Pid} <- VNodes].

%% @private
init([VNodeMod, _RegName]) ->
    {ok, #state{idxtab = undefined, vnode_mod = VNodeMod}}.

proxy_cast(Who, Req) -> proxy_cast(Who, Req, normal).

proxy_cast({VMaster, Node}, Req, How) ->
    do_proxy_cast({VMaster, Node}, Req, How).

do_proxy_cast({VMaster, Node},
              Req = #riak_vnode_req_v1{index = Idx}, How) ->
    Mod = vmaster_to_vmod(VMaster),
    Proxy = riak_core_vnode_proxy:reg_name(Mod, Idx, Node),
    send_an_event(Proxy, Req, How),
    ok;
do_proxy_cast({VMaster, Node},
              Req = #riak_coverage_req_v1{index = Idx}, How) ->
    Mod = vmaster_to_vmod(VMaster),
    Proxy = riak_core_vnode_proxy:reg_name(Mod, Idx, Node),
    send_an_event(Proxy, Req, How),
    ok.

send_an_event(Dest, Event, normal) ->
    riak_core_vnode:send_req(Dest, Event);
send_an_event(Dest, Event, unreliable) ->
    riak_core_send_msg:send_event_unreliable(Dest, Event).

handle_cast({wait_for_service, Service}, State) ->
    case Service of
        undefined -> ok;
        _ ->
            logger:debug("Waiting for service: ~p", [Service]),
            riak_core:wait_for_service(Service)
    end,
    {noreply, State};
handle_cast(Req = #riak_vnode_req_v1{index = Idx},
            State = #state{vnode_mod = Mod}) ->
    Proxy = riak_core_vnode_proxy:reg_name(Mod, Idx),
    riak_core_vnode:send_req(Proxy, Req),
    {noreply, State};
handle_cast(Req = #riak_coverage_req_v1{index = Idx},
            State = #state{vnode_mod = Mod}) ->
    Proxy = riak_core_vnode_proxy:reg_name(Mod, Idx),
    riak_core_vnode:send_req(Proxy, Req),
    {noreply, State}.

handle_call({return_vnode,
             Req = #riak_vnode_req_v1{index = Idx}},
            _From, State = #state{vnode_mod = Mod}) ->
    {ok, Pid} =
        riak_core_vnode_proxy:command_return_vnode({Mod,
                                                    Idx,
                                                    node()},
                                                   Req),
    {reply, {ok, Pid}, State};
handle_call({call, {Index, Message}},
            From, State = #state{vnode_mod = Mod}) ->
    Proxy = riak_core_vnode_proxy:reg_name(Mod, Index),
    Sender = {server, ignore_ref, From},
    riak_core_vnode:send_req(Proxy, #riak_vnode_req_v1{index = Index, request = Message, sender = Sender}),
    {noreply, State};
handle_call({spawn, {Index, Message}},
    From, State = #state{vnode_mod = Mod}) ->
  Proxy = riak_core_vnode_proxy:reg_name(Mod, Index),
  Sender = {server, ignore_ref, From},
  spawn_link(fun () ->
    riak_core_vnode:send_all_proxy_req(Proxy, #riak_vnode_req_v1{index = Index, request = Message, sender = Sender})
             end),
  {noreply, State}.

handle_info(_Info, State) -> {noreply, State}.

%% @private
terminate(_Reason, _State) -> ok.

%% @private
code_change(_OldVsn, State, _Extra) -> {ok, State}.
