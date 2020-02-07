%% -------------------------------------------------------------------
%%
%% stats: Statistics Suite for Erlang
%%
%% Copyright (c) 2009 Dave Smith (dizzyd@dizzyd.com)
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
-module(basho_stats_utils).

-include("stats.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-compile(export_all).
-endif.

%% ===================================================================
%% Unit Test Helpers
%% ===================================================================

-ifdef(EUNIT).

r_run(Input, Command) ->
    case r_port() of
        {ok, Port} ->
            InputStr = [integer_to_list(I) || I <- Input],
            port_command(Port, ?FMT("x <- c(~s)\n", [string:join(InputStr, ",")])),
            port_command(Port, ?FMT("write(~s, ncolumns=1, file=stdout())\n", [Command])),
            port_command(Port, "write('', file=stdout())\n"),
            r_simple_read_loop(Port, []);
        {error, Reason} ->
            {error, Reason}
    end.

r_port() ->
    Port = case erlang:get(r_port) of
        undefined ->
            IPort = open_port({spawn, "R --vanilla --slave"},
                             [use_stdio, exit_status, {line, 16384},
                              stderr_to_stdout]),
            erlang:put(r_port, IPort),
            IPort;
        IPort -> IPort
    end,

    %% Check the status of the port
    try port_command(Port, "write('', file=stdout())\n") of
        _ ->
            receive
                {Port, {data, {eol, []}}} ->
                    {ok, Port};
                {Port, {data, {eol, Other}}} ->
                    erlang:erase(r_port),
                    {error, Other}
            end
    catch
        error:badarg ->
            erlang:erase(r_port),
            {error, port_closed}
    end.

r_simple_read_loop(Port, Acc) ->
    receive
        {Port, {data, {eol, []}}} ->
            lists:reverse(Acc);
        {Port, {data, {eol, Line}}} ->
            case Line of
                "Error"++_ ->
                    Error = get_error(Port, [Line]),
                    exit({error, Error});
                _ ->
                    r_simple_read_loop(Port, [to_number(Line) | Acc])
            end;
        {Port, {exit_status, _}} ->
            lists:reverse(Acc)
    end.

get_error(Port, Acc) ->
    receive
        {Port, {data, {eol, []}}} ->
            lists:reverse(Acc);
        {Port, {data, {eol, Line}}} ->
            get_error(Port, [Line | Acc]);
        {Port, {exit_status, _}} ->
            lists:reverse(Acc)
    end.

to_number(Str) ->
    case catch(list_to_integer(Str)) of
        {'EXIT', _} ->
            list_to_float(Str);
        Value ->
            Value
    end.

-endif.

