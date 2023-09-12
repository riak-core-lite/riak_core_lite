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
%% @doc Periodically check that we're registered with the EPMD and take
%% appropriate action if we're not.
%%
%% This handles the case where the EPMD (Erlang Port Mapper Daemon) service
%% has been killed or restarted, which can happen occasionally due to:
%% <ul><li>
%%  OS service managers that don't recognize suitable process ownership for
%%  the EPMD process.
%% </li><li>
%%  Riak or other Erlang package installations/updates that choose to replace
%%  a running EPMD.
%% </li><li>
%%  Other overly-aggressive external operations, including operator error.
%% </li></ul>
%%
%% == Behavior ==
%%
%% The service has four effective modes of operation:
%%
%% <dl><dt>
%%  Registration Monitor (REG)
%%  </dt><dd>
%%      Periodically checks that the running Erlang node is properly
%%      registered with the EPMD, and re-registers it if it is not.
%%      <br/>
%%      This mode is configured automatically, with an available override
%%      supporting non-standard environments.
%% </dd><dt>
%%  Service Monitor (SVC)
%%  </dt><dd>
%%      Periodically checks that the EPMD process is running and available,
%%      restarting it if it is not.
%%      <br/>
%%      This mode defaults to <em>enabled</em>, with an available
%%      override supporting OS-level service managers.
%% </dd><dt>
%%  Both of the Above
%%  </dt><dd>
%%      Both monitors active with a shared check interval.
%% </dd><dt>
%%  None of the Above
%%  </dt><dd>
%%      Neither monitor is active, though the service can be <i>awakened</i>
%%      through configuration changes followed by a call to {@link status()}.
%% </dd></dl>
%%
%% == Configuration ==
%%
%%  A number of characteristics within the running system dictate whether
%%  and how EPMD status is evaluated and what actions this service takes in
%%  response to monitored status changes.
%%
%%  In all cases the service re-evaluates its configuration and may alter its
%%  behavior as a result when {@link status()} is called.
%%
%% The following keys within the `riak_core' application environment are
%% recognized:
%% <dl><dt>
%%  `epmd_registration_check :: boolean()'
%%  </dt><dd>
%%      Specifies whether the service is to enable REG monitoring.<br/>
%%      Generally the default calculated value should be used, but it can be
%%      explicitly overridden by setting this key.<br/>
%%      The only envisioned use case for doing so is to disable REG monitoring
%%      when a non-default EPMD module is specified to `erlexec' that performs
%%      the monitoring itself.
%%      As such, the value cannot be overridden to `true' when the default EPMD
%%      module implements auto-reregistration - a warning is logged if you try.
%%      <br/>
%%      Defaults to a calculated value based on the execution environment.<br/>
%%      See {@section Automatic Reregistration}
%% </dd><dt>
%%  `epmd_service_check :: boolean()'
%%  </dt><dd>
%%      Specifies whether the service is to enable SVC monitoring.<br/>
%%      If `true' and the service is found not to be running, [re]starts the
%%      configured or default EPMD.<br/>
%%      If EPMD is configured as an OS service this key should be configured
%%      with the value `false'.
%%      <br/>
%%      Defaults to `true'.
%% </dd><dt>
%%  `epmd_check_interval :: pos_integer()'
%%  </dt><dd>
%%      Specifies the interval, in seconds, between checks (that is, the
%%      interval after a check completes before the next check is started).
%%      <br/>
%%      If neither REG nor SVC monitoring is active, this setting is ignored.
%%      <br/>
%%      Range is 1..86400 seconds.
%%      <br/>
%%      Defaults to 11.
%% </dd><dt>
%%  `epmd_service_command :: nonempty_list(nonempty_string())'
%%  </dt><dd>
%%      Specifies a non-default command to run to start the EPMD.<br/>
%%      The first element of the list is the absolute path of an existing
%%      executable file that the effective Riak user has access to.
%%      Subsequent elements are command-line parameters, as strings.<br/>
%%      The command as a whole <i>MUST</i> be idempotent and must execute
%%      successfully (return code == 0) within a reasonable time - assume
%%      around 15 seconds - though the acceptable startup time <i>can</i> be
%%      overridden with the `epmd_service_start_timeout' setting.
%%      <br/>
%%      If SVC monitoring is not active, this setting has no effect.
%%      <br/>
%%      Defaults to `["code:root_dir()/erts-<version>/bin/epmd", "-daemon"]'.
%% </dd><dt>
%%  `epmd_service_start_timeout :: pos_integer()'
%%  </dt><dd>
%%      Specifies the maximum time to wait, in seconds, for a user-specified
%%      start command to complete (the default is always used for the default
%%      ERTS EPMD).
%%      <br/>
%%      If SVC monitoring is not active, this setting has no effect.
%%      <br/>
%%      Range is 5..300 seconds.
%%      <br/>
%%      Defaults to 20.
%% </dd></dl>
%%
%% If any configuration key is set to an invalid value an error is logged and
%% the default is used.
%%
%% == Implementation Notes ==
%%
%% ==== Failure Severity ====
%%
%% The service counts consecutive failures and increases the severity of its
%% logged messages as they increase.
%% The severity ramp-up algorithm is entirely contained within the
%% `failure_severity/1' function, and should only be adjusted there.
%% At present the algorithm <i>IS NOT</i> configurable.
%%
%% There's a trade-off in how severity escalation is handled - on one hand,
%% Riak is a clustered database, and the loss of one node should not have a
%% material impact on availability. Conversely, continuing failures indicate
%% that something is very wrong - either this service is misconfigured, or the
%% OTP installation itself is incomplete or corrupted, calling into question
%% the reliability of the Riak node.
%%
%% Note that the node may still be participating in cluster operations even
%% when not properly registered with the EPMD, as existing disterl connections
%% don't rely on EPMD lookup, so in the case of OTP corruption an unhealthy
%% node could potentially be passing along incorrect data to other nodes.
%% This scenario is why we escalate severity, in hopes that some higher
%% severity will trigger an alert that gets through to someone.
%%
%% ==== EPMD Command ====
%%
%% By default, the Erlang boot script causes ERTS EPMD to be started in
%% ```
%%  otp/etc/common/erlexec.c:start_epmd(...)
%% '''
%% with the command line
%% ```
%%  code:root_dir()/erts-<version>/bin/epmd -daemon
%% '''
%% We refer to this as the "default" EPMD. An alternative executable
%% <em>can</em> be specified on the `erlexec' command line, but it doesn't get
%% passed through to the VM so there's no way for us to find out what it was.
%%
%% We do allow an ERTS startup command to be specified in the application
%% environment, though, so if a non-default EPMD is specified to `erlexec' it
%% can also be configured for this service's use with
%% ```
%%  {riak_core, [
%%      {epmd_service_command, ["/some/other/epmd", "-switches" ...]}
%% '''
%% If an alternative command is specified but it doesn't <em>look</em> valid
%% we log an error and default to using the one in ERTS if we need to restart
%% the EPMD.<br/>
%% If an alternative command passes static validation (it's an executable
%% regular file) but subsequently fails to start or service requests we fall
%% back to using the default ERTS EPMD.
%%
%% ==== Automatic Reregistration ====
%%
%% Automatic reregistration with the EPMD was added to the default `erl_epmd'
%% kernel module in OTP 23.3 (kernel-7.3, erts-11.2). We set the `epmd_rereg'
%% state element indicating whether this functionality is present and active.
%% ```
%%  net_kernel:epmd_module() =:= erl_epmd andalso <kernel-version> >= 7.3
%% '''
%% This value, along with the `epmd_registration_check' configuration key,
%% determines whether REG checking is active.
%%
%% ==== ERTS EPMD API ====
%%
%% While the `net_kernel:epmd_module/0' function has been present with its
%% current behavior since at least R13, it is <em>NOT</em> part of the
%% "official" documented API.
%%
%% Similarly, the implemented behavior of the `erl_epmd' module does not
%% conform to its documentation (or even function specs) in all cases.
%%
%% For efficiency, we cache the result of `net_kernel:epmd_module/0' and use
%% the module it returns to look up and register names through what is believed
%% to be a small and stable subset of the API whose behavior has been confirmed
%% through OTP 26.
%%
%% For all of the above reasons, the first place to look if unexpected behavior
%% is observed using an OTP release later than 26 is the kernel source.
%%
%% The `EpmdMod:names/1' function is used throughout to both check that the
%% EPMD is running and that we're registered with it. While potentially more
%% efficient, `EpmdMod:port_please/2' is not used because it doesn't tell us
%% whether the EPMD is running, only whether we're registered, requiring a
%% subsequent call to `EpmdMod:names/1' to resolve ambiguity. We assume that
%% the list of registered nodes on a Riak server will generally be small, so
%% the protocol efficiency shouldn't be an issue.
%%
%% @end
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

-include_lib("kernel/include/logger.hrl").
%% The LOCATION macro is undocumented, issue a warning if it goes away and
%% we have to define it ourselves.
-ifndef(LOCATION).
-warning("Logger macro LOCATION not defined, using possibly outdated version.").
-define(LOCATION, #{
    mfa => {?MODULE, ?FUNCTION_NAME, ?FUNCTION_ARITY},
    line => ?LINE,
    file => ?FILE
}).
-endif. % LOCATION

%% For #file_info{} record.
-include_lib("kernel/include/file.hrl").
%% For #hostent{} record.
-include_lib("kernel/include/inet.hrl").

%% Registered service.
-define(SERVICE,    ?MODULE).

%% The default net_kernel EPMD module, and when auto-reregistration
%% was added to it.
-define(KERNEL_EPMD_MOD,    erl_epmd).
-define(KERNEL_REREG_VSN,   [7, 3]).

%% Check interval in seconds.
%% Note that these values are hard-coded in the module documentation,
%% so update it if you change them.
-define(MIN_CHECK_INTERVAL,     1).
-define(MAX_CHECK_INTERVAL,     (24 * 60 * 60)).    %% Max one day
-define(DEFAULT_CHECK_INTERVAL, 11).

%% Start timeout in seconds
%% Note that these values are hard-coded in the module documentation,
%% so update it if you change them.
-define(MIN_START_TIMEOUT,      5).     %% Overly aggressive, but allowed.
-define(MAX_START_TIMEOUT,      300).   %% Five minutes, because really?
-define(DEFAULT_START_TIMEOUT,  20).    %% Should be fine for most anything.

%% Don't re-schedule an existing scheduled check if the re-scheduled check
%% time would be within ?CHECK_FUZZ_MS milliseconds of the originally
%% scheduled check.
-define(CHECK_FUZZ_MS,          100).

-type check_time()  :: integer().
-type ck_interval() :: ?MIN_CHECK_INTERVAL..?MAX_CHECK_INTERVAL.
-type epmd_cmd()    :: nonempty_list(nonempty_string()).
-type st_timeout()  :: ?MIN_START_TIMEOUT..?MAX_START_TIMEOUT.
-type timer_inf()   :: {timer_ref(), check_time()}.
-type timer_ref()   :: reference().

-type status()  :: #{
    chk_interval:= ck_interval(),
    reg_monitor := boolean(),
    svc_monitor := boolean(),
    epmd_cmd    := epmd_cmd(),
    cmd_timeout := st_timeout(),
    sysrereg    := boolean(),
    service     := ?SERVICE
}.

-type state() :: #{
    %% Whether REG monitoring is enabled.
    mon_reg     := boolean(),

    %% Whether SVC monitoring is enabled.
    mon_svc     := boolean(),

    %% Whether monitoring is currently active.
    %% Logically `(mon_reg orelse mon_svc)`
    active      := boolean(),

    %% What, if any, check is scheduled, and how often.
    timer       := timer_inf() | undefined,
    interval    := ck_interval(),

    %% The EPMD interface module to use
    epmd_mod    := module(),

    %% Whether the (default) ?KERNEL_EPMD_MOD module implements auto-reregistration.
    auto_rereg  := boolean(),

    %% The active, possibly user-specified EPMD start command, and the
    %% default ERTS EPMD command. If `active_cmd` fails AND it differs from
    %% `default_cmd', falls back to `default_cmd'.
    %% If `default_cmd' fails, things are very much not as they should be.
    %% Still, we don't want to crash out and potentially take Riak down, so we
    %% count failures and use that to extend the check interval until we
    %% (hopefully) get to another success.
    active_cmd  := epmd_cmd() | default,
    default_cmd := epmd_cmd() | default,
    cmd_timeout := st_timeout(),
    failures    := non_neg_integer(),

    %% Where we talk to the EPMD and what we register with it.
    epmd_addr   := inet:ip_address(),
    node_name   := nonempty_string(),
    dist_port   := inet:port_number(),

    %% Name of this service, for viewing the state externally
    service     := ?SERVICE
}.

%% ERTS EPMD starts up almost instantly, but we don't know what layers of
%% system management may surround it, nor do we know how or an alternative
%% EPMD may be implemented, so give it time to start up.

%% How much total time, in seconds,  we want to wait before giving up on a
%% newly-started EPMD.
-define(EPMD_START_CHECK_DURATION,  15).
%% Milliseconds between attempts to contact a newly-started EPMD.
-define(EPMD_START_CHECK_INTERVAL,  333).

%% Cleaner than macros.
-compile({inline, [
    cancel_scheduled/1,
    schedule_time/0
]}).

-spec cancel_scheduled(TimerRef :: timer_ref()) -> ok.
%% Cancel timers asynchronously and quietly, to be be inlined away.
cancel_scheduled(TimerRef) ->
    erlang:cancel_timer(TimerRef, [{async, true}, {info, false}]).

-spec schedule_time() -> check_time().
%% @hidden Current time in milliseconds, to be be inlined away.
schedule_time() ->
    erlang:monotonic_time(millisecond).

%% ===================================================================
%% Public API
%% ===================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
%% @private Invoked by `riak_core_sup' to start and own the service.
start_link() ->
    case init_state() of
        {ok, State} ->
            gen_server:start_link({local, ?SERVICE}, ?MODULE, State, []);
        Error ->
            Error
    end.

-spec status() -> {ok, status()} | {error, term()}.
%% @doc Reloads configuration from the `riak_core' application environment,
%% restarts the service according to the new configuration, and returns the
%% status report.
status() ->
    gen_server:call(?SERVICE, status, 30000).

%% ===================================================================
%% gen_server
%% ===================================================================

-spec init(State :: state()) -> {ok, state()}.
%% @private
init(State) ->
    %% If we try to start EPMD and it fails, we want to report it.
    erlang:process_flag(trap_exit, true),
    ?LOG_INFO("~s started with configuration ~0p",
        [?MODULE, status_report(State)]),
    {ok, schedule_check(State)}.

-spec handle_call(Request :: term(), From :: term(), State :: state() )
        -> {reply, {ok, status()} | ignored, state()} .
%% @private
handle_call(status, _From, StateIn) ->
    StateOut = update_state(StateIn),
    {reply, {ok, status_report(StateOut)}, StateOut};
handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

-spec handle_cast(Request :: term(), State :: state())
        -> {noreply, state()}.
%% @private
handle_cast(_Request, State) ->
    {noreply, State}.

-spec handle_info(Msg :: term(), State :: state() ) -> {noreply, state()}.
%% @private Scheduled check message.
%% First, clean up the timer.
%% This is how a properly scheduled message should look.
handle_info({check_epmd, When}, #{timer := {_, When}} = State) ->
    handle_info(check_epmd, State#{timer := undefined});
%% Out-of-order check message, clear the pending scheduled message.
handle_info({check_epmd, _}, #{timer := {Timer, _}} = State) ->
    cancel_scheduled(Timer),
    handle_info(check_epmd, State#{timer := undefined});
%% Perform the check if enabled.
handle_info(check_epmd, #{active := true} = State) ->
    {noreply, check_epmd(State)};
%% Drop everything else, which includes leftover messages from the port we
%% use when restarting EPMD.
handle_info(_Info, State) ->
    {noreply, State}.

%% ===================================================================
%% Internal
%% ===================================================================

-spec app_version(AppName :: atom()) -> nonempty_list(non_neg_integer()).
%% @hidden Return AppName's version as a list of integers.
app_version(AppName) ->
    case lists:keyfind(AppName, 1, application:loaded_applications()) of
        {_AppName, _Deps, VsnStr} ->
            app_version_ints(string:lexemes(VsnStr, "."));
        _ ->
            [0]
    end.

-spec app_version_ints(Segs :: list(unicode:chardata()) )
        -> list(non_neg_integer()).
%% @hidden app_version/1 helper.
app_version_ints([Seg | Segs]) ->
    case string:to_integer(Seg) of
        {Int, _} when erlang:is_integer(Int) ->
            [Int | app_version_ints(Segs)];
        _ ->
            app_version_ints(Segs)
    end;
app_version_ints([] = R) ->
    R.

-spec check_epmd(State :: state()) -> state().
%% @hidden Perform a periodic check, whatever that means.
%% Called by handle_info/2 when at least one check is active.
check_epmd(#{epmd_mod := EpmdMod,
        node_name := Name, epmd_addr := Addr, dist_port := Port} = State) ->
    %% In the normal case, the node should already be registered.
    ResultState = case EpmdMod:names(Addr) of
        {ok, Names} ->
            case lists:keyfind(Name, 1, Names) of
                {Name, Port} ->
                    State#{failures := 0};
                {Name, NewPort} ->
                    State#{dist_port := NewPort, failures := 0};
                _ ->
                    check_epmd_rereg(State)
            end;
        _ ->
            check_epmd_restart(State)
    end,
    schedule_check(ResultState).

-spec check_epmd_rereg(State :: state()) -> state().
%% @hidden check_epmd/1 helper.
%% Called when we're not registered with a running EPMD.
check_epmd_rereg(#{mon_reg := true,
        epmd_mod := EpmdMod, node_name := Name, dist_port := Port} = State) ->
    %%
    %% We're automatically or explicitly configured to reregister the node.
    %%
    case EpmdMod:register_node(Name, Port) of
        {ok, Creation} when erlang:is_integer(Creation) ->
            ?LOG_INFO("Reregistered with EPMD"),
            State#{failures := 0};
        {error, already_registered = Info} ->
            %% Hmmm, something else reregistered us.
            %% Most likely auto reregistration just occurred through:
            %% - a non-standard EpmdMod
            %% - some other external actor
            %% This almost certainly means that `mon_reg' is `true' when it
            %% shouldn't be - either by default or through being explicitly
            %% set - but it's possible that the config is deliberate because
            %% whatever reregistered isn't reliable.
            ?LOG_NOTICE("External EPMD reregistration appears active: "
                "~0p:register_node(~0p, ~0p) returned ~0p",
                [EpmdMod, Name, Port, Info]),
            State#{failures := 0};
        Error ->
            %% This is not good - the service is/was running, but isn't
            %% accepting our registration.
            %% Increment the failure count and try again later.
            #{failures := PrevFailures} = State,
            Failures = (PrevFailures + 1),
            logger:log(failure_severity(Failures),
                "~0p:register_node(~0p, ~0p) returned ~0p",
                [EpmdMod, Name, Port, Error], ?LOCATION),
            State#{failures := Failures}
    end;
check_epmd_rereg(#{failures := 0} = State) ->
    %% Some external service is responsible for reregistration, assume the
    %% first miss is due to timing.
    State#{failures := 1};
check_epmd_rereg(#{failures := Failures} = State) ->
    %% Some external service is responsible for reregistration, and hasn't
    %% done it.
    logger:log(failure_severity(Failures),
        "external EPMD reregistration failures: ~b", [Failures], ?LOCATION),
    State#{failures := (Failures + 1)}.

-spec check_epmd_restart(State :: state()) -> state().
%% @hidden check_epmd/1 helper.
%% Called when the EPMD isn't running.
check_epmd_restart(#{mon_svc := true, active_cmd := default,
        default_cmd := Command, cmd_timeout := TimeoutSecs,
        failures := PrevFailures} = State) ->
    %%
    %% Using ERTS EPMD. This *should* never fail, but if it does we'll keep
    %% retrying at progressively-longer intervals and higher log severities
    %% until somebody notices and does something about it.
    %%
    logger:log(failure_severity(PrevFailures),
        "EPMD not running, restarting ...", ?LOCATION),
    case run_command(Command, TimeoutSecs) of
        {ok, Output} ->
            case ensure_epmd_started(State) of
                true ->
                    check_epmd_rereg(State#{failures := 0});
                _ ->
                    %% So it started, but it's not responding ...
                    %% We'll back off the check interval
                    logger:log(failure_severity(PrevFailures),
                        "ERTS EPMD not servicing requests after"
                        " restart, timed out", [Command], ?LOCATION),
                    ?LOG_INFO("ERTS EPMD start output: ~0p", [Output]),
                    State#{failures := (PrevFailures + 1)}
            end;
        Error ->
            Failures = (PrevFailures + 1),
            logger:log(failure_severity(Failures),
                "start ERTS EPMD failed with ~0p", [Error], ?LOCATION),
            State#{failures := Failures}
    end;
check_epmd_restart(#{mon_svc := true,
        active_cmd := Command, cmd_timeout := TimeoutSecs} = State) ->
    %%
    %% Using configured EPMD - if this doesn't work, fall back to ERTS.
    %% All outcomes reset `failures' to zero, as we either succeed or change
    %% to a different EPMD start command.
    %%
    ?LOG_WARNING("EPMD not running, restarting ..."),
    case run_command(Command, TimeoutSecs) of
        {ok, Output} ->
            case ensure_epmd_started(State) of
                true ->
                    State#{failures := 0};
                _ ->
                    ?LOG_ERROR("configured EPMD not servicing requests"
                        " after restart, reverting to ERTS EPMD."
                        " ~0p timed out.", [Command]),
                    ?LOG_INFO("configured EPMD start output: ~0p", [Output]),
                    check_epmd_restart_failover(State)
            end;
        Error ->
            ?LOG_ERROR("configured EPMD didn't start, reverting to ERTS EPMD."
                " ~0p failed with ~0p.", [Command, Error]),
            check_epmd_restart_failover(State)
    end;
check_epmd_restart(#{failures := 0} = State) ->
    %% Some external service is responsible for restarting the EPMD, assume
    %% the first miss is due to timing.
    State#{failures := 1};
check_epmd_restart(#{failures := Failures} = State) ->
    %% Some external service is responsible for restarting the EPMD, and
    %% hasn't done it.
    logger:log(failure_severity(Failures),
        "external EPMD restart failures: ~b", [Failures], ?LOCATION),
    State#{failures := (Failures + 1)}.

-spec check_epmd_restart_failover(State :: state()) -> state().
%% @hidden Switch to ERTS EPMD after configured EPMD failure.
check_epmd_restart_failover(State) ->
    NewState = update_timer(State#{active_cmd := default,
        cmd_timeout := ?DEFAULT_START_TIMEOUT, failures := 0}),
    ?LOG_INFO("configuration changed to ~0p", [status_report(NewState)]),
    check_epmd_restart(NewState).

-spec config
    (Key :: epmd_registration_check) -> boolean() | default ;
    (Key :: epmd_service_check) -> boolean() ;
    (Key :: epmd_check_interval) -> pos_integer() ;
    (Key :: epmd_service_start_timeout) -> pos_integer() ;
    (Key :: epmd_service_command) -> epmd_cmd() | default .
%% @hidden Gets a config key's value from the application environment.
%%
%% Some keys return `default' if not configured, allowing for decisions
%% based on presence as well as value.

config(epmd_registration_check = Key) ->
    config_bool(Key, default);
config(epmd_service_check = Key) ->
    config_bool(Key, true);
config(epmd_check_interval = Key) ->
    config_int(Key,
        ?MIN_CHECK_INTERVAL, ?MAX_CHECK_INTERVAL, ?DEFAULT_CHECK_INTERVAL);
config(epmd_service_start_timeout = Key) ->
    config_int(Key,
        ?MIN_START_TIMEOUT, ?MAX_START_TIMEOUT, ?DEFAULT_START_TIMEOUT);
config(epmd_service_command = Key) ->
    case application:get_env(riak_core, Key) of
        {ok, Command} ->
            case verify_command(Command) of
                ok ->
                    Command;
                Error ->
                    ?LOG_ERROR(
                        "invalid ~0p value, verification failed with ~0p,"
                        " using default ERTS EPMD", [Key, Error]),
                    default
            end;
        _Undefined ->
            default
    end.

-spec config_bool(Key :: atom(), Default :: boolean() | default)
        -> boolean() | default.
%% @hidden Helper for config/1
config_bool(Key, Default) ->
    case application:get_env(riak_core, Key) of
        {ok, Bool} when erlang:is_boolean(Bool) ->
            Bool;
        {ok, BadVal} ->
            Dflt = case Default of
                Bool when erlang:is_boolean(Default) ->
                    [$', erlang:atom_to_list(Bool), $'];
                _ ->
                    "calculated behavior"
            end,
            ?LOG_ERROR("invalid ~s value: ~0p, must be boolean 'true' or"
                " 'false', using default ~s", [Key, BadVal, Dflt]),
            Default;
        _NotSet ->
            Default
    end.

-spec config_int(
    Key :: atom(), Min :: integer(), Max :: integer(), Default :: integer())
        -> integer().
%% @hidden Helper for config/1
config_int(Key, Min, Max, Default) ->
    case application:get_env(riak_core, Key) of
        {ok, Int} when erlang:is_integer(Int)
                andalso Int >= Min andalso Int =< Max ->
            Int;
        {ok, BadVal} ->
            ?LOG_ERROR("invalid ~0p value: ~0p,"
                " must be an integer in the range ~b through ~b,"
                " using default ~b", [Key, BadVal, Min, Max, Default]),
            Default;
        _NotSet ->
            Default
    end.

-spec config_state(State :: state()) -> state().
%% @hidden Apply current application configuration to the state.
%%
%% This overwrites configured fields indiscriminately - take before and after
%% snapshots to determine whether the state has changed.
config_state(#{epmd_mod := EpmdMod, auto_rereg := AutoRereg} = State) ->

    ReregActive = AutoRereg andalso EpmdMod =:= ?KERNEL_EPMD_MOD,
    RegChk = case config(epmd_registration_check) of
        default ->
            not ReregActive;
        true when ReregActive ->
            ?LOG_WARNING(
                "registration check cannot be enabled through ~s when kernel"
                " reregistration is active, defaulting to disabled",
                [epmd_registration_check]),
            false;
        ConfRereg ->
            ConfRereg
    end,

    SvcChk = config(epmd_service_check),
    {SvcCmd, Timeout} = case config(epmd_service_command) of
        default ->
            {default, ?DEFAULT_START_TIMEOUT};
        CfgCmd ->
            case State of
                #{default_cmd := CfgCmd} ->
                    {default, ?DEFAULT_START_TIMEOUT};
                _ ->
                    {CfgCmd, config(epmd_service_start_timeout)}
            end
    end,

    ChkInt  = config(epmd_check_interval),
    Active  = (RegChk orelse SvcChk),

    State#{
        mon_reg     := RegChk,
        mon_svc     := SvcChk,
        active      := Active,
        interval    := ChkInt,
        active_cmd  := SvcCmd,
        cmd_timeout := Timeout
    }.

-spec default_state() -> state().
%% @hidden Return a legal, stable state() to modify with subsequent settings.
%%
%% A little less efficient, but easier than doing it all in init_state/1,
%% which then just merges in a couple of runtime-calculated fields, as
%% config_state/1 will be invoked on the result either way.
default_state() ->
    %% We don't care about the hostname part of the node name, we'll only be
    %% talking to the local EPMD. `characters_to_list/1` isn't really needed,
    %% as it'll already be a flat list, it's just to keep dialyzer happy.
    Name = unicode:characters_to_list(erlang:hd(
        string:split(erlang:atom_to_list(erlang:node()), "@")  )),
    %% Through at least OTP 26 the EPMD is assumed to always listen on the
    %% IPv4 loopback address.
    Addr = {127, 0, 0, 1},
    % Addr = case inet_db:res_option(inet6) of
    %     true ->
    %         {0, 0, 0, 0, 0, 0, 0, 1};
    %     _ ->
    %         {127, 0, 0, 1}
    % end,
    EpmdMod = net_kernel:epmd_module(),
    AutoRereg = (app_version(kernel) >= ?KERNEL_REREG_VSN),
    #{
        mon_reg     => true,
        mon_svc     => true,
        active      => true,
        timer       => undefined,
        interval    => ?DEFAULT_CHECK_INTERVAL,
        epmd_mod    => EpmdMod,
        auto_rereg  => AutoRereg,
        active_cmd  => default,
        default_cmd => default,
        cmd_timeout => ?DEFAULT_START_TIMEOUT,
        failures    => 0,
        epmd_addr   => Addr,
        node_name   => Name,
        dist_port   => 0,
        service     => ?SERVICE
    }.

-spec ensure_epmd_started(State :: state()) -> boolean().
%% @hidden
ensure_epmd_started(State) ->
    %% How many times we'll try to contact an EPMD before calling it dead.
    MaxTries =
        ((?EPMD_START_CHECK_DURATION * 1000) div ?EPMD_START_CHECK_INTERVAL),
    ensure_epmd_started(MaxTries, State, #{}).

-spec ensure_epmd_started(
    Retries :: non_neg_integer(),
    State :: state(),
    Errors :: #{term() => pos_integer()} )
        -> boolean().
%% @hidden
ensure_epmd_started(Retries, #{epmd_mod := EpmdMod} = State, Errors)
        when Retries > 0 ->
    timer:sleep(?EPMD_START_CHECK_INTERVAL),
    case EpmdMod:names() of
        {ok, _} ->
            true;
        {error, Reason} ->
            ensure_epmd_started(
                (Retries - 1), State, inc_counter(Reason, Errors));
        Unexpected ->
            ?LOG_WARNING("~0p:names() returned ~0p", [EpmdMod, Unexpected]),
            ensure_epmd_started(
                (Retries - 1), State, inc_counter(Unexpected, Errors))
    end;
ensure_epmd_started(_Retries, _State, Errors)
        when erlang:map_size(Errors) == 0 ->
    false;
ensure_epmd_started(_Retries, #{epmd_mod := EpmdMod}, Errors) ->
    ?LOG_ERROR("~0p:names() error counts: ~0p", [EpmdMod, Errors]),
    false.

-spec failure_severity(Failures :: non_neg_integer()) -> logger:level().
%% @hidden How loud do we yell?
%% Keep raising the severity until somebody notices and does something about
%% it. It's questionable whether this truly ever becomes an "emergency", but
%% someone should be paying attention.
%% Failures shouldn't ever be negative, but cover all cases.
failure_severity(Failures) when Failures < 1 ->
    warning;
failure_severity(Failures) when Failures < 3 ->
    error;
failure_severity(Failures) when Failures < 5 ->
    critical;
failure_severity(Failures) when Failures < 9 ->
    alert;
failure_severity(_) ->
    emergency.

-spec inc_counter(Key :: term(), Map :: map()) -> map().
%% @hidden
inc_counter(Key, Map) ->
    maps:update_with(Key, fun(V) -> (V + 1) end, 1, Map).

-spec init_state() -> {ok, state()} | {error, term()}.
%% @hidden Build the state in the starting process prior to gen_server spawn.
init_state() ->
    case validated_default_epmd() of
        {ok, ErtsEpmd} ->
            init_state(ErtsEpmd);
        Error ->
            %% This is VERY bad - fortunately it should never happen.
            ?LOG_ALERT(
                "invalid ERTS EPMD, verification failed with ~0p", [Error]),
            Error
    end.

-spec init_state(ErtsEpmdCmd :: epmd_cmd()) -> {ok, state()} | {error, term()}.
%% @hidden Build the state in the starting process prior to gen_server spawn.
init_state(ErtsEpmd) ->
    State = default_state(),
    #{epmd_mod := EpmdMod, epmd_addr := Addr, node_name := Name} = State,
    case EpmdMod:names(Addr) of
        {ok, Names} ->
            case lists:keyfind(Name, 1, Names) of
                {Name, Port} ->
                    {ok, config_state(
                        State#{default_cmd := ErtsEpmd, dist_port := Port})};
                _ ->
                    ?LOG_ERROR("Current node '~s' is not registered with"
                        " EPMD '~s' at ~0p", [Name, EpmdMod, Addr]),
                    {error, unknown_disterl_port}
            end;
        Error ->
            ?LOG_ERROR("~0p:names(~0p) returned ~0p", [EpmdMod, Addr, Error]),
            {error, no_local_epmd}
    end.

-spec schedule_check(State :: state()) -> state().
%% @hidden If no check is scheduled, schedules one after the appropriate
%% interval.
%% Failures == 0 is the normal case, so it skips the interval calculation.
schedule_check(#{active := true, timer := undefined,
        failures := 0, interval := Interval} = State) ->
    State#{timer := schedule_check_msg(Interval)};
schedule_check(#{active := true, timer := undefined,
        failures := Failures, interval := Interval} = State) ->
    IntSecs = erlang:min((Interval * Failures), ?MAX_CHECK_INTERVAL),
    State#{timer := schedule_check_msg(IntSecs)};
schedule_check(State) ->
    State.

-spec schedule_check_msg(IntervalSecs :: pos_integer()) -> timer_inf().
%% @hidden Schedule a check after IntervalSecs seconds.
schedule_check_msg(IntervalSecs) ->
    When = (schedule_time() + (IntervalSecs * 1000)),
    {erlang:send_after(When, erlang:self(),
        {check_epmd, When}, [{abs, true}]), When}.

-spec status_report(State :: state()) -> status().
%% @hidden Generates the status map.
status_report(
    #{
        active_cmd  := ACommand,
        auto_rereg  := AutoRereg,
        cmd_timeout := CmdTimeout,
        default_cmd := DCommand,
        interval    := ChkInt,
        mon_reg     := RegChk,
        mon_svc     := SvcChk,
        service     := Service } ) ->

    {Command, Timeout} = case ACommand of
        default ->
            {DCommand, ?DEFAULT_START_TIMEOUT};
        _ ->
            {ACommand, CmdTimeout}
    end,
    #{
        chk_interval=> ChkInt,
        reg_monitor => RegChk,
        svc_monitor => SvcChk,
        epmd_cmd    => Command,
        cmd_timeout => Timeout,
        sysrereg    => AutoRereg,
        service     => Service
    }.

-spec update_state(State :: state()) -> state().
%% @hidden Reloads configuration and updates state similar to restarting
%% the service.
%% There are a number of state changes that precipitate additional changes.
%% `failures` is always reset so that this operation can be used to "poke" the
%% service even when no other state changes are applied.
%% The `timer' state is validated and/or updated accordingly.
update_state(OldState) ->
    case config_state(OldState) of
        OldState ->
            OldState;
        NewState ->
            State = update_timer(NewState#{failures := 0}),
            ?LOG_INFO("updated state to ~0p", [status_report(State)]),
            schedule_check(State)
    end.

-spec update_timer(State :: state()) -> state().
%% @hidden Maybe cancel an existing timer after a state update.
%%
%% It's the caller's responsibility to ensure that schedule_check/1 is invoked
%% on the new state after this operation.
update_timer(#{active := false, timer := {TRef, _}} = State) ->
    cancel_scheduled(TRef),
    State#{timer := undefined};
update_timer(#{timer := {TRef, TWhen}, interval := IntSecs} = State) ->
    Interval = (IntSecs * 1000),
    case (TWhen - schedule_time()) of
        %% < 0: the timer has fired, handle_info will get it.
        %% =< Tnterval+Fuzz: close enough, carry on.
        %% > Tnterval+Fuzz: cancel timer, let schedule_check set a new one.
        Remain when Remain =< (Interval + ?CHECK_FUZZ_MS) ->
            State;
        _ ->
            cancel_scheduled(TRef),
            State#{timer := undefined}
    end;
update_timer(State) ->
    State.

-spec validated_default_epmd() -> {ok, epmd_cmd()} | {error, term()}.
%% @hidden
validated_default_epmd() ->
    EpmdExe = filename:join([code:root_dir(),
        ["erts-", erlang:system_info(version)], "bin", "epmd"]),
    EpmdCmd = [EpmdExe, "-daemon"],
    case verify_command(EpmdCmd) of
        ok ->
            {ok, EpmdCmd};
        PosixError ->
            %% This is VERY bad - fortunately it should never happen.
            ?LOG_ALERT(
                "invalid ERTS EPMD, verification failed with ~0p",
                [PosixError]),
            {error, PosixError}
    end.

-spec verify_command(Command :: term())
        -> ok | {file:posix(), nonempty_list()}.
%% @hidden Verifies that:
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

-spec run_command(Command :: epmd_cmd(), TimeoutSecs :: pos_integer())
        -> {ok, list()} | {error, term()}.
%% @hidden
run_command([Exe | Args] = Cmd, TimeoutSecs) ->
    ?LOG_INFO("Starting EPMD with: ~s", [[$', lists:join("' '", Cmd), $']]),
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
        -> {ok, list()} | {error, term()}.
%% @hidden Collect output until we get a message indicating completion.
%%
%% We don't need to flush subsequent messages from this port, as handle_info/2
%% will drop stragglers for us.
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
