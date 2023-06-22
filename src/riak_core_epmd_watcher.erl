%% -------------------------------------------------------------------
%%
%% Copyright (c) 2023 Workday, Inc.
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
%%
%% Periodically check that we're registered with EPMD and re-register if
%% we're not.
%%
%% This handles the case where the EPMD executable has been killed or
%% restarted, which appears to happen occasionally under OS service managers
%% that can't see suitable process ownership for the EPMD and/or due to
%% over-aggressive external operations.
%%
%% Configuration:
%%
%% The following keys within the `riak_core' application environment are
%% recognized:
%%
%%  ?CHECK_ENABLED_KEY (epmd_check_enabled) :: boolean()
%%      Specifies whether the service is to perform periodic checks. What
%%      those checks do *may* be dictated, in part, by the OTP version.
%%      Defaults to `true'.
%%
%%  ?CHECK_INTERVAL_KEY (epmd_check_interval) :: pos_integer()
%%      Specifies the interval, in seconds, between checks (that is, the
%%      interval after a check completes before the next check is started).
%%      Range is ?MIN_CHECK_INTERVAL..?MAX_CHECK_INTERVAL seconds.
%%      Defaults to ?DEFAULT_CHECK_INTERVAL.
%%
%%  ?EPMD_COMMAND_KEY (epmd_start_command) :: nonempty_list(nonempty_string())
%%      Specifies a non-default command to run to start the EPMD.
%%      The first element of the list is the absolute path of an existing
%%      executable file that the effective Riak user has access to.
%%      Subsequent elements are command-line parameters, as strings.
%%      The command as a whole MUST be idempotent and must execute successfully
%%      (return code == 0) within a reasonable time - assume around 15 seconds.
%%      Defaults to ["<erlang-path>/erts-<version>/bin/epmd", "-daemon"].
%%
%%  ?START_TIMEOUT_KEY (epmd_start_timeout) :: pos_integer()
%%      Specifies the maximum time to wait, in seconds, for a user-specified
%%      start command to complete (the default is always used for the default
%%      ERTS EPMD).
%%      Range is ?MIN_START_TIMEOUT..?MAX_START_TIMEOUT seconds.
%%      Defaults to ?DEFAULT_START_TIMEOUT.
%%
%% If any configuration key is set to an invalid value an error is logged and
%% the default is used.
%%
%% Implementation notes:
%%
%% **
%% By default, the Erlang boot script causes ERTS EPMD to be started in
%%      otp/etc/common/erlexec.c:start_epmd(_)
%% with the command line
%%      code:root_dir()/erts-<version>/bin/epmd -daemon
%%
%% We refer to this as the "default" EPMD. An alternative executable *can* be
%% specified on the `erlexec' command line, but it doesn't get passed through
%% to the VM so there's no way for us to find out what it was *
%%
%% ToDo: * this assumption needs further research, but not today.
%%
%% We do allow an ERTS startup command to be specified in the application
%% environment, though, so if a non-default EPMD is specified to `erlexec' it
%% can also be configured for `riak_core'.
%%
%% If an alternative command is specified but it doesn't *look* valid we log
%% an error and default to using the one in ERTS if we need to restart EPMD.
%% If an alternative command passes static validation (it's an executable
%% regular file) but subsequently fails to start or service requests we fall
%% back using the default ERTS EPMD.
%%
%% **
%% Automatic reregistration with the EPMD was added after OTP 23's initial
%% release. We set the `epmd_rereg' state element indicating whether this
%% functionality is present, and report it in the `status/0` result, but don't
%% currently alter behavior based on it.
%%
%% ToDo: Use the `epmd_rereg' flag to skip some checks once we're on OTP 24+.
%%
%% **
%% The above automatic reregistration functionality is triggered by keeping a
%% socket open to the EPMD and reacting to an asynchronous message indicating
%% the socket has died.
%%
%% ToDo: Consider using the same approach to be signaled when the EPMD dies.
%%
%% **
%% The documentation (and spec) of the success result of the
%%      erl_epmd:port_please/2
%% function was wrong prior to OTP-24.
%% The pattern used here is correct from at least R16 forward.
%%
-module(riak_core_epmd_watcher).
-behaviour(gen_server).
-compile([
    inline,
    inline_list_funcs,
    warn_export_vars
]).

%% Public API
-export([status/0]).

%% Private supervisor API
-export([start_link/0]).

%% gen_server callbacks
-export([handle_call/3, handle_cast/2, handle_info/2, init/1]).

-ifndef(OTP_RELEASE).
%% gen_server callbacks required prior to Riak3+
-export([code_change/3, terminate/2]).
-endif.

%% Dialyzer correctly warns that the
%%      check_epmd/1
%%      ensure_epmd/1
%%      update_state/1
%% functions never return the {error, _} terms declared in their specs.
%% This is by design, as the present strategy is for this service to run
%% continually. The patterns are kept, however, so that a random future
%% implementation change doesn't percolate up into a bad_match or case_clause
%% exception.
-dialyzer({no_match, [
    check_epmd/1,   %% ensure_epmd/1 -> Error
    handle_call/3,  %% update_state/1 -> Error
    handle_info/2   %% check_epmd/1 -> Error
]}).

%% For #file_info{} record.
-include_lib("kernel/include/file.hrl").
%% For #hostent{} record.
-include_lib("kernel/include/inet.hrl").

-define(SERVICE,    ?MODULE).                       %% Registered service.
-define(STATE,      riak_core_epmd_watcher_state).  %% State record name.

%% Key to set whether the service is enabled in the riak_core application.
-define(CHECK_ENABLED_KEY,      epmd_check_enabled).
%% Key to set check interval seconds in the riak_core application.
-define(CHECK_INTERVAL_KEY,     epmd_check_interval).
%% Key to set EPMD start command in the riak_core application.
-define(EPMD_COMMAND_KEY,       epmd_start_command).
%% Key to set the maximum EPMD command start timeout.
-define(START_TIMEOUT_KEY,      epmd_start_timeout).

%% Check interval in seconds.
-define(MIN_CHECK_INTERVAL,     1).
-define(MAX_CHECK_INTERVAL,     (24 * 60 * 60)).    %% Max one day
-define(DEFAULT_CHECK_INTERVAL, 17).

%% Start timeout in seconds
-define(MIN_START_TIMEOUT,      5).     %% Overly aggressive, but allowed.
-define(MAX_START_TIMEOUT,      300).   %% Five minutes, because really?
-define(DEFAULT_START_TIMEOUT,  20).    %% Should be fine for most anything.

-type command()     :: nonempty_list(nonempty_string()).
-type error()       :: {error, term()}.
-type ck_interval() :: ?MIN_CHECK_INTERVAL..?MAX_CHECK_INTERVAL.
-type st_timeout()  :: ?MIN_START_TIMEOUT..?MAX_START_TIMEOUT.
-type timer_inf()   :: {reference(), reference()} | undefined.

%% Status is reported as a map or proplist, depending on platform.
-ifdef(OTP_RELEASE).
-type status()  :: #{
    enabled :=  boolean(),
    interval := ck_interval(),
    command :=  command(),
    timeout :=  st_timeout(),
    sysrereg := boolean(),
    service :=  ?SERVICE
}.
-define(STATUS_REPORT(Enabled, Interval, Command, Timeout, ErtsReReg), #{
    enabled =>  Enabled,
    interval => Interval,
    command =>  Command,
    timeout =>  Timeout,
    sysrereg => ErtsReReg,
    service =>  ?SERVICE
}).
-else.  % Old OTP => Riak2
-type status()  :: [
    {enabled,   boolean()} |
    {interval,  ck_interval()} |
    {command,   command()} |
    {timeout,   st_timeout()} |
    {sysrereg,  boolean()} |
    {service,   ?SERVICE}
].
-define(STATUS_REPORT(Enabled, Interval, Command, Timeout, ErtsReReg), [
    {enabled,   Enabled},
    {interval,  Interval},
    {command,   Command},
    {timeout,   Timeout},
    {sysrereg,  ErtsReReg},
    {service,   ?SERVICE}
]).
-endif. % OTP_RELEASE

%% Use a record instead of map for drop-in compatibility with Riak 2.x
-record(?STATE, {
    %% Whether the service is currently performing periodic checks.
    enabled     :: boolean(),

    %% What, if any, check is scheduled, and how often.
    timer       :: timer_inf(),
    interval    :: ck_interval(),

    %% The EPMD interface module to use, and whether it implements
    %% auto-reregistration (added to the default module in OTP-23).
    epmd_mod    :: module(),
    auto_rereg  :: boolean(),

    %% The active, possibly user-specified EPMD start command, and the
    %% default ERTS EPMD command. If `active_cmd` fails AND it differs from
    %% `default_cmd', falls back to `default_cmd'.
    %% If `default_cmd' fails, things are very much not as they should be.
    %% Still, we don't want to crash out and potentially take Riak down, so we
    %% count failures and use that to extend the check interval until we
    %% (hopefully) get to another success.
    active_cmd  :: command(),
    default_cmd :: command(),
    cmd_timeout :: st_timeout(),
    failures    :: non_neg_integer(),

    %% What's registered with the EPMD.
    dist_port   :: inet:port_number(),
    node_addr   :: inet:ip_address(),
    node_name   :: atom()
}).
-type state() :: #?STATE{}.

%% Cancel timers asynchronously and quietly if we can.
-ifdef(OTP_RELEASE).
-define(CANCEL_TIMER(TimerRef),
    erlang:cancel_timer(TimerRef, [{async, true}, {info, false}])).
-else.
-define(CANCEL_TIMER(TimerRef), erlang:cancel_timer(TimerRef)).
-endif.

%% ERTS EPMD starts up almost instantly, but we don't know what layers of
%% system management may surround it, nor do we know how or an alternative
%% EPMD may be implemented, so give it time to start up.

%% How much total time, in seconds,  we want to wait before giving up on a
%% newly-started EPMD.
-define(EPMD_START_CHECK_DURATION,  15).
%% Milliseconds between attempts to contact a newly-started EPMD.
-define(EPMD_START_CHECK_INTERVAL,  333).

%% ===================================================================
%% Public API
%% ===================================================================

-spec start_link() -> {ok, pid()} | error().
%% Invoked by `riak_core_sup' to start and own the service.
start_link() ->
    case init_state() of
        {ok, State} ->
            gen_server:start_link({local, ?SERVICE}, ?MODULE, State, []);
        Error ->
            Error
    end.

-spec status() -> ok | error().
%% Reloads configuration from riak_core application state (NOT from config
%% file), restarts the service according to the new state, and returns the
%% status report.
status() ->
    gen_server:call(?SERVICE, status, 30000).

%% ===================================================================
%% gen_server
%% ===================================================================

init(#?STATE{} = State) ->
    %% If we try to start EPMD and it fails, we want to report it.
    erlang:process_flag(trap_exit, true),
    lager:info("~s started with configuration ~p",
        [?MODULE, status_report(State)]),
    {ok, schedule_check(State)}.

handle_call(status, _From, State) ->
    case update_state(State) of
        {ok, StateOut} ->
            {reply, status_report(StateOut), StateOut};
        Error ->
            {stop, Error, Error, State}
    end;
handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

%% Scheduled check message.
handle_info({check_epmd, ChkRef}, #?STATE{timer = {_, ChkRef}} = State) ->
    handle_info(check_epmd, State#?STATE{timer = undefined});
%% Unscheduled check message, clear the pending scheduled message.
handle_info(check_epmd, #?STATE{timer = {Timer, _}} = State) ->
    _ = ?CANCEL_TIMER(Timer),
    handle_info(check_epmd, State#?STATE{timer = undefined});
%% Perform the check if enabled.
handle_info(check_epmd, #?STATE{enabled = true} = State) ->
    case check_epmd(State) of
        {ok, StateOut} ->
            {noreply, schedule_check(StateOut)};
        Error ->
            {stop, Error, State}
    end;
%% Drop everything else, which includes leftover messages from the port we
%% use when restarting EPMD.
handle_info(_Info, State) ->
    {noreply, State}.

-ifndef(OTP_RELEASE).
%% gen_server callbacks required prior to Riak3+
terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.
-endif. % OTP_RELEASE

%% ===================================================================
%% Internal
%% ===================================================================

-spec config(Key :: atom()) -> term().
config(?CHECK_ENABLED_KEY = Key) ->
    config_bool(Key, true);
config(?CHECK_INTERVAL_KEY = Key) ->
    config_int(Key,
        ?MIN_CHECK_INTERVAL, ?MAX_CHECK_INTERVAL, ?DEFAULT_CHECK_INTERVAL);
config(?START_TIMEOUT_KEY = Key) ->
    config_int(Key,
        ?MIN_START_TIMEOUT, ?MAX_START_TIMEOUT, ?DEFAULT_START_TIMEOUT);
config(?EPMD_COMMAND_KEY = Key) ->
    case application:get_env(riak_core, Key) of
        {ok, Command} ->
            case verify_command(Command) of
                ok ->
                    Command;
                Error ->
                    lager:error(
                        "invalid ~p value, verification failed with ~p,"
                        " using default ERTS EPMD", [Key, Error])
            end;
        Undefined ->
            Undefined
    end.

-spec config_bool(Key :: atom(), Default :: boolean()) -> boolean().
%% Helper for config/1
config_bool(Key, Default) ->
    case application:get_env(riak_core, Key) of
        {ok, Bool} when erlang:is_boolean(Bool) ->
            Bool;
        {ok, BadVal} ->
            logger:error("invalid ~s value: ~p,"
                " must be boolean 'true' or 'false'"
                " using default ~s", [Key, BadVal, Default]),
            Default;
        _NotSet ->
            Default
    end.

-spec config_int(
    Key :: atom(), Min :: integer(), Max :: integer(), Default :: integer())
        -> integer().
%% Helper for config/1
config_int(Key, Min, Max, Default) ->
    case application:get_env(riak_core, Key) of
        {ok, Int} when erlang:is_integer(Int)
                andalso Int >= Min andalso Int =< Max ->
            Int;
        {ok, BadVal} ->
            lager:error("invalid ~p value: ~p,"
                " must be an integer in the range ~b through ~b,"
                " using default ~b", [Key, BadVal, Min, Max, Default]),
            Default;
        _NotSet ->
            Default
    end.

-spec check_epmd(State :: state()) -> {ok, state()} | error().
check_epmd(
    #?STATE{
        dist_port = Port,
        epmd_mod  = EpmdMod,
        node_addr = Addr,
        node_name = Name} = State) ->
    case EpmdMod:port_please(Name, Addr) of
        {port, Port, _Version} ->
            {ok, State#?STATE{failures = 0}};
        {ok, NewPort, _Version} ->
            {ok, State#?STATE{dist_port = NewPort, failures = 0}};
        _ ->
            case ensure_epmd(State) of
                {ok, _StateOut} = Result ->
                    case EpmdMod:register_node(Name, Port) of
                        {ok, Creation} when erlang:is_integer(Creation) ->
                            Result;
                        {error, already_registered = Info} ->
                            lager:debug("~p:register_node(~p, ~p) returned ~p",
                                [EpmdMod, Name, Port, Info]),
                            Result;
                        Error ->
                            lager:error("~p:register_node(~p, ~p) returned ~p",
                                [EpmdMod, Name, Port, Error]),
                            Result
                    end;
                Error ->
                    Error
            end
    end.

-spec ensure_epmd(State :: state()) -> {ok, state()} | error().
%% Ensure the EPMD is running.
ensure_epmd(#?STATE{epmd_mod = EpmdMod, active_cmd = Command} = State) ->
    case EpmdMod:names() of
        {ok, _} ->
            {ok, State#?STATE{failures = 0}};
        _ ->
            lager:warning(
                "EPMD not running, restarting it with ~p", [Command]),
            ensure_epmd_running(State)
    end.

-spec ensure_epmd_failover(State :: state()) -> {ok, state()} | error().
%% Switch to ERTS EPMD after configured EPMD failure.
ensure_epmd_failover(#?STATE{default_cmd = ErtsEpmd} = OldState) ->
    NewState = update_timer(
        OldState#?STATE{active_cmd = ErtsEpmd, failures = 0}),
    lager:info("configuration changed from ~p to ~p",
        [status_report(OldState), status_report(NewState)]),
    ensure_epmd(NewState).

-spec ensure_epmd_running(State :: state()) -> {ok, state()} | error().
%% Restart and ensure the EPMD service is running.
ensure_epmd_running(
    #?STATE{
        active_cmd = Command,
        default_cmd = Command,
        failures = Failures} = State) ->
    %%
    %% Using ERTS EPMD - if this doesn't work, we'll reduce the retry
    %% frequency until it does.
    %%
    case run_command(Command, ?DEFAULT_START_TIMEOUT) of
        {ok, Output} ->
            case ensure_epmd_started(State) of
                true ->
                    {ok, State#?STATE{failures = 0}};
                _ ->
                    %% So it started, but it's not responding ...
                    %% We'll back off the check interval
                    lager:warning("ERTS EPMD not servicing requests after"
                        " restart, timed out", [Command]),
                    lager:info("ERTS EPMD start output: ~p", [Output]),
                    {ok, State#?STATE{failures = (Failures + 1)}}
            end;
        Error ->
            lager:error("start ERTS EPMD failed with ~p", [Error]),
            {ok, State#?STATE{failures = (Failures + 1)}}
    end;
ensure_epmd_running(
    #?STATE{active_cmd = Command, cmd_timeout = TimeoutSecs} = State) ->
    %%
    %% Using configured EPMD - if this doesn't work, fall back to ERTS.
    %% All outcomes reset `failures' to zero, as we either succeed or change
    %% to a different EPMD start command.
    %%
    case run_command(Command, TimeoutSecs) of
        {ok, Output} ->
            case ensure_epmd_started(State) of
                true ->
                    {ok, State#?STATE{failures = 0}};
                _ ->
                    lager:warning("configured EPMD not servicing requests"
                        " after restart, reverting to ERTS EPMD."
                        " ~p timed out.", [Command]),
                    lager:info("configured EPMD start output: ~p", [Output]),
                    ensure_epmd_failover(State)
            end;
        Error ->
            lager:error("configured EPMD didn't start, reverting to ERTS EPMD."
                " ~p failed with ~p.", [Command, Error]),
            ensure_epmd_failover(State)
    end.

-spec ensure_epmd_started(State :: state()) -> boolean().
ensure_epmd_started(State) ->
    %% How many times we'll try to contact an EPMD before calling it dead.
    MaxTries =
        ((?EPMD_START_CHECK_DURATION * 1000) div ?EPMD_START_CHECK_INTERVAL),
    ensure_epmd_started(MaxTries, State, orddict:new()).

-spec ensure_epmd_started(
    Retries :: non_neg_integer(),
    State :: state(),
    Errors :: list({term(), pos_integer()}) )   %% R16+ compatible orddict spec
        -> boolean().
ensure_epmd_started(Retries, #?STATE{epmd_mod = EpmdMod} = State, Errors)
        when Retries > 0 ->
    timer:sleep(?EPMD_START_CHECK_INTERVAL),
    case EpmdMod:names() of
        {ok, _} ->
            true;
        {error, Reason} ->
            ensure_epmd_started((Retries - 1), State,
                orddict:update_counter(Reason, 1, Errors));
        Unexpected ->
            lager:warning("~p:names() returned ~p", [EpmdMod, Unexpected]),
            ensure_epmd_started((Retries - 1), State, Errors)
    end;
ensure_epmd_started(_Retries, _State, []) ->
    false;
ensure_epmd_started(_Retries, #?STATE{epmd_mod = EpmdMod}, Errors) ->
    lager:info("~p:names() error counts: ~p", [EpmdMod, Errors]),
    false.

-spec init_state() -> {ok, state()} | error().
%% Build the state in the starting process before the gen_server is spawned.
init_state() ->
    case validated_default_epmd() of
        {ok, ErtsEpmdCmd} ->
            init_state(ErtsEpmdCmd);
        ErtsEpmdError ->
            %% This is VERY bad - fortunately it should never happen.
            lager:alert(
                "invalid ERTS EPMD, verification failed with ~p",
                [ErtsEpmdError]),
            {error, ErtsEpmdError}
    end.

-spec init_state(ErtsEpmdCmd :: command()) -> {ok, state()} | error().
init_state(ErtsEpmdCmd) ->
    [NameStr, HostStr] =
        string:tokens(erlang:atom_to_list(erlang:node()), "@"),
    Name = erlang:list_to_atom(NameStr),
    EpmdMod = net_kernel:epmd_module(),
    EpmdAutoRereg = case EpmdMod of
        erl_epmd ->
            %% The behavior we care about was added midway through OTP 23.
            %% AFAIK, nobody's seriously using OTP 23, so just check for >23
            %% rather than parsing the kernel version.
            {IntOrErr, _} = string:to_integer(erlang:system_info(otp_release)),
            erlang:is_integer(IntOrErr) andalso IntOrErr > 23;
        _ ->
            false
    end,
    case inet:gethostbyname(HostStr) of
        {ok, #hostent{h_addr_list = [Addr |_]}} ->
            case EpmdMod:port_please(Name, Addr) of
                {port, Port, _Version} ->
                    InitEpmdCmd = case config(?EPMD_COMMAND_KEY) of
                        [[_|_]|_] = ConfEpmdCmd ->
                            ConfEpmdCmd;
                        _ ->
                            ErtsEpmdCmd
                    end,
                    {ok, #?STATE{
                        enabled     = config(?CHECK_ENABLED_KEY),
                        timer       = undefined,
                        interval    = config(?CHECK_INTERVAL_KEY),
                        epmd_mod    = EpmdMod,
                        auto_rereg  = EpmdAutoRereg,
                        active_cmd  = InitEpmdCmd,
                        default_cmd = ErtsEpmdCmd,
                        cmd_timeout = config(?START_TIMEOUT_KEY),
                        failures    = 0,
                        dist_port   = Port,
                        node_addr   = Addr,
                        node_name   = Name
                    }};
                Bad ->
                    lager:error(
                        "~p:port_please(~p, ~p) returned ~p",
                        [EpmdMod, Name, Addr, Bad]),
                    {error, unknown_disterl_port}
            end;
        Error ->
            Error
    end.

-spec schedule_check(State :: state()) -> state().
schedule_check(
    #?STATE{
        enabled = true,
        timer = undefined,
        interval = Interval,
        failures = Failures} = State) ->
    Delay = (erlang:min(
        (Interval * erlang:max(1, Failures)), ?MAX_CHECK_INTERVAL) * 1000),
    ChkRef = erlang:make_ref(),
    Timer = erlang:send_after(Delay, erlang:self(), {check_epmd, ChkRef}),
    State#?STATE{timer = {Timer, ChkRef}};
schedule_check(State) ->
    State.

-spec status_report(State :: state()) -> status().
status_report(
    #?STATE{
        enabled = Enabled,
        interval = Interval,
        active_cmd = Command,
        default_cmd = Command,
        auto_rereg = AutoRereg}) ->
    ?STATUS_REPORT(
        Enabled, Interval, Command, ?DEFAULT_START_TIMEOUT, AutoRereg);
status_report(
    #?STATE{
        enabled = Enabled,
        interval = Interval,
        active_cmd = Command,
        cmd_timeout = Timeout,
        auto_rereg = AutoRereg}) ->
    ?STATUS_REPORT(Enabled, Interval, Command, Timeout, AutoRereg).

-spec update_state(State :: state()) -> {ok, state()} | error().
%% Reloads configuration and updates state similar to restarting the service.
%% There are a number of state changes that precipitate additional changes.
%% `failures` is always reset so that this operation can be used to "poke" the
%% service even when no other state changes are applied.
%% The `timer' state is validated and/or updated accordingly.
update_state(OldState) ->
    %% Capture the reportable elements before and after.
    OldStatus = status_report(OldState),

    NewCmd = case config(?EPMD_COMMAND_KEY) of
        [[_|_]|_] = ConfEpmdCmd ->
            ConfEpmdCmd;
        _ ->
            OldState#?STATE.default_cmd
    end,
    NewEnabled = config(?CHECK_ENABLED_KEY),
    NewInterval = config(?CHECK_INTERVAL_KEY),
    NewState = update_timer(
        OldState#?STATE{
        enabled     = NewEnabled,
        interval    = NewInterval,
        active_cmd  = NewCmd,
        cmd_timeout = config(?START_TIMEOUT_KEY),
        failures    = 0 }),

    NewStatus = status_report(NewState),
    NewStatus =:= OldStatus orelse
        lager:info("updated state to ~p", [NewStatus]),
    {ok, schedule_check(NewState)}.

-spec update_timer(State :: state()) -> state().
%% Maybe cancel an existing timer after a state update.
%% It's the caller's responsibility to ensure that schedule_check/1 is invoked
%% on the new state after this operation.
update_timer(#?STATE{enabled = false, timer = {TimerRef, _}} = State) ->
    _ = ?CANCEL_TIMER(TimerRef),
    State#?STATE{timer = undefined};
update_timer(#?STATE{timer = {TimerRef, _}, interval = Interval} = State) ->
    case erlang:read_timer(TimerRef) of
        Remain when erlang:is_integer(Remain)
                andalso Remain =< (Interval * 1000) ->
            %% Existing timer is within interval.
            State;
        false ->
            %% Most likely the timer fired since we started handling whatever
            %% message got us here.
            State#?STATE{timer = undefined};
        _ ->
            %% The remaining time is greater than the interval.
            _ = ?CANCEL_TIMER(TimerRef),
            State#?STATE{timer = undefined}
    end;
update_timer(State) ->
    State.

-spec validated_default_epmd() -> {ok, command()} | error().
validated_default_epmd() ->
    EpmdExe = filename:join([code:root_dir(),
        ["erts-", erlang:system_info(version)], "bin", "epmd"]),
    EpmdCmd = [EpmdExe, "-daemon"],
    case verify_command(EpmdCmd) of
        ok ->
            {ok, EpmdCmd};
        PosixError ->
            %% This is VERY bad - fortunately it should never happen.
            lager:alert(
                "invalid ERTS EPMD, verification failed with ~p",
                [PosixError]),
            {error, PosixError}
    end.

-spec verify_command(Command :: term())
        -> ok | {file:posix(), nonempty_list()}.
%% Verifies that:
%%  - Command is a list of unicode strings.
%%  - Exe is an absolute path.
%%  - Exe is a regular file.
%%  - Exe's Mode *looks* executable *
%%
%% * The Mode check is flawed, as it's only testing whether ANY execute bit
%% is set, which may not be applicable to the effective user, but we're not
%% going to resolve all that here.
%% A command that passes validation here will still be checked by the system
%% when it's executed, and we'll trap and act upon that error if it occurs.
verify_command([[_|_] = Exe | _Args] = Command) ->
    case lists:all(fun io_lib:char_list/1, Command)
            andalso filename:pathtype(Exe) of
        absolute ->
            case file:read_file_info(Exe, [{time, posix}, raw]) of
                {ok, #file_info{type = Type, mode = Mode}} ->
                    case Type of
                        regular ->
                            case (Mode band 8#111) of
                                0 ->
                                    {eacces, [Exe]};
                                _ ->
                                    ok
                            end;
                        directory ->
                            {eisdir, [Exe]};
                        _ ->
                            {eftype, [Exe]}
                    end;
                {error, Posix} ->
                    {Posix, [Exe]}
            end;
        false ->
            {einval, [not_char_data | Command]};
        Relative ->
            {einval, [Relative, Exe]}
    end;
verify_command(Invalid) ->
    {einval, [badarg, Invalid]}.

-spec run_command(Command :: command(), TimeoutSecs :: pos_integer())
        -> {ok, list()} | error().
run_command([Exe | Args], TimeoutSecs) ->
    PortOpts = [binary, exit_status, in, stderr_to_stdout],
    Opts = case Args of
        [] ->
            PortOpts;
        _ ->
            [{args, Args} | PortOpts]
    end,
    try
        Port = erlang:open_port({spawn_executable, Exe}, Opts),
        run_command_result(Port, (TimeoutSecs * 1000), [])
    catch
        error:eacces ->
            {error, {eacces, [Exe]}}
    end.

-spec run_command_result(
    Port :: port(), TimeoutMS :: pos_integer(), Output :: list())
        -> {ok, list()} | error().
%% Collect output until we get a message indicating completion. We don't need
%% to flush subsequent messages from this port, as handle_info/2 will drop
%% stragglers for us.
run_command_result(Port, TimeoutMS, Output) ->
    receive
        {Port, {data, Out}} ->
            run_command_result(Port, TimeoutMS, Output ++ [Out]);
        {Port, {exit_status, 0}} ->
            Port ! {erlang:self(), close},
            {ok, Output};
        {Port, {exit_status, RC}} ->
            Port ! {erlang:self(), close},
            {error, {RC, Output}};
        {Port, closed} ->
            {error, {-1, Output}};
        {'EXIT', Port, Reason} ->
            {error, {Reason, Output}}
    after
        TimeoutMS ->
            Port ! {erlang:self(), close},
            {error, {timeout, Output}}
    end.
