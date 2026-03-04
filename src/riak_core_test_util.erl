%% -*- mode: erlang; erlang-indent-level: 4; indent-tabs-mode: nil -*-
%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007-2014 Basho Technologies, Inc.
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
%%
%% @doc Utilities for test scripts.
%%
-module(riak_core_test_util).

%% Public API for use from other apps
-export([
    ensure_no_file/1,
    get_test_dir/1, get_test_dir/2,
    logger_filesync/0,
    logger_redirect/1, logger_redirect/2,
    logger_restore/0,
    logger_silence/0
]).

%% Private API for use only from riak_core
-ifdef(TEST).
-export([
    fake_ring/2,
    setup_mockring1/0,
    stop_pid/1,
    wait_for_pid/1
]).
-endif. % TEST

-include_lib("stdlib/include/assert.hrl").

-type abs_path()    :: nonempty_string().
-type fs_path()     :: abs_path() | rel_path().
-type rel_path()    :: file:name().
-type test_name()   :: atom() | nonempty_string().

%% Test data root when not running under Rebar3.
-define(TEST_DATA_ROOT, "/tmp").
-define(TEST_DATA_DIR,  "testdata").

%% Persistent term keys
-define(LOGSTATE_PKEY,      {?MODULE, logger_state}).
-define(TESTROOT_PKEY,      {?MODULE, testdata_root}).
-define(TESTDATA_PKEY(T),   {?MODULE, testdata_dir, T}).

-define(LOG_FILE(FilePath), #{
    type => file,
    file => FilePath,
    file_check => 50,
    filesync_repeat_interval => 100
}).
-define(LOG_FMT, {logger_formatter, #{
    legacy_header => false,
    single_line => false,
    time_designator => $\s,
    template => [
        time, " [", level, "] ", {pid, [pid, "@"], []},
        {mfa, [mfa, ":"], []}, {line, [line, ":"], []},
        " ", msg, "\n"
    ]}
}).
-define(LOG_CFG(FilePath), #{
    config => ?LOG_FILE(FilePath),
    formatter => ?LOG_FMT
}).
-define(LOG_CFG(FilePath, Level), #{
    config => ?LOG_FILE(FilePath),
    formatter => ?LOG_FMT,
    level => Level
}).

-spec ensure_no_file(Path :: fs_path()) -> ok.
%% @doc Ensures that the specified file/directory does not exist,
%% deleting it unconditionally if it does.
%% Note that this function should only be used on paths within transient
%% test data, as it does not report permission errors.
ensure_no_file(Path) ->
    _ = filelib:is_file(Path) =:= false orelse
        os:cmd(io_lib:format("/bin/rm -rf '~ts'", [Path])),
    ok.

-spec get_test_dir(TestName :: test_name()) -> abs_path().
%% @doc Ensures the test directory for TestName exists.
%% @returns The Absolute path of the directory to use for the specified TestName.
%% @equiv get_test_dir(TestName, false)
get_test_dir(TestName) ->
    get_test_dir(TestName, false).

-spec get_test_dir(
    TestName :: test_name(), EnsureEmpty :: boolean())
        -> abs_path().
%% @doc Ensures the test directory for TestName exists and, if EnsureEmpty
%% is true, that it is empty.
%% @returns The Absolute path of the directory to use for the specified TestName.
get_test_dir(TestName, EnsureEmpty) ->
    PKey = ?TESTDATA_PKEY(TestName),
    TestDir = case persistent_term:get(PKey, undefined) of
        undefined ->
            Path = filename:join(get_testdata_path(), TestName),
            persistent_term:put(PKey, Path),
            Path;
        Val ->
            Val
    end,
    EnsureEmpty =/= true orelse ensure_no_file(TestDir),
    ?assertMatch(ok, filelib:ensure_dir(filename:join(TestDir, "x"))),
    TestDir.

-spec get_testdata_path() -> abs_path().
%% @hidden Gets the root under which all test-specific data directories live.
%% When running under Rebar3, the path is under the '_build' directory.
get_testdata_path() ->
    PKey = ?TESTROOT_PKEY,
    case persistent_term:get(PKey, undefined) of
        undefined ->
            {ok, CWD} = file:get_cwd(),
            Build = filename:join(CWD, "_build"),
            DataDir = case filelib:is_dir(Build) of
                true ->
                    filename:join([Build, "test", ?TEST_DATA_DIR]);
                _ ->
                    Default = filename:join(?TEST_DATA_ROOT, ?TEST_DATA_DIR),
                    io:format(user,
                        "~n*** ~ts not present~n*** Using ~ts~n",
                        [Build, Default]),
                    Default
            end,
            persistent_term:put(PKey, DataDir),
            DataDir;
        TDVal ->
            TDVal
    end.

-spec logger_filesync() -> ok | {error, term()}.
%% @doc If the `default' log handler is directed to a file, invokes the
%% handler module's `filesync/1' function.
logger_filesync() ->
    Handler = default,
    case logger:get_handler_config(Handler) of
        {ok, #{config := #{file := _}, module := Mod}} ->
            ?assertMatch(ok, Mod:filesync(Handler));
        _ ->
            ok
    end.

-spec logger_redirect(TestName :: test_name()) -> abs_path().
%% @doc Redirects the `default' log handler to a file.
%% The file is named `TestName.log' in the directory returned by
%% {@link get_test_dir/1. get_test_dir(TestName)}.
logger_redirect(TestName) ->
    logger_redirect(TestName, [TestName, ".log"]).

-spec logger_redirect(TestName :: test_name(), LogFile :: rel_path())
        -> abs_path().
%% @doc Redirects the `default' log handler to a file.
%% The file is named `LogFile' in the directory returned by
%% {@link get_test_dir/1. get_test_dir(TestName)}.
logger_redirect(TestName, LogFile) ->
    TestDir = get_test_dir(TestName),
    LogPath = filename:join(TestDir, LogFile),
    Handler = default,
    case logger:get_handler_config(Handler) of
        {ok, #{config := #{file := LogPath}}} ->
            %% already redirected to the target file
            ok;
        {ok, #{level := Level} = OldConf} ->
            logger_replace(Handler, ?LOG_CFG(LogPath, Level), OldConf);
        {error, {not_found, _Handler} = NFRec} ->
            logger_replace(Handler, ?LOG_CFG(LogPath), NFRec)
    end,
    LogPath.

-spec logger_restore() -> ok.
%% @doc Restores the `default' log handler that was replaced by
%% {@link logger_redirect/2}.
logger_restore() ->
    case persistent_term:get(?LOGSTATE_PKEY, undefined) of
        undefined ->
            ok;
        #{config := #{file := _}, id := ID, module := Mod} = OldConf ->
            ?assertMatch(ok, Mod:filesync(ID)),
            persistent_term:erase(?LOGSTATE_PKEY),
            logger_replace(ID, OldConf, false);
        #{id := ID} = OldConf ->
            persistent_term:erase(?LOGSTATE_PKEY),
            logger_replace(ID, OldConf, false);
        {not_found, ID} ->
            persistent_term:erase(?LOGSTATE_PKEY),
            ?assertMatch(ok, logger:remove_handler(ID))
    end.

-spec logger_silence() -> logger:level() | all | none.
%% @doc Silences the `default' log handler.
%% The handler's log level can be restored by invoking
%% ```
%%  logger:set_handler_config(default, level, Level)
%% '''
%% where `Level' is the value returned from this function.
%% @returns The previous level, or `none' if no `default' handler is present.
logger_silence() ->
    Handler = default,
    case logger:get_handler_config(Handler) of
        {ok, #{level := none = None}} ->
            None;
        {ok, #{level := Level}} ->
            ?assertMatch(ok, logger:set_handler_config(Handler, level, none)),
            Level;
        _ ->
            none
    end.

-spec logger_replace(
    HandlerID :: logger:handler_id(),
    HConfig :: logger:handler_config(),
    StoreRec :: false | logger:handler_config() | tuple())
        -> ok.
%% @hidden The handler always needs to be replaced when changing
%% the output path.
%% If StoreRec is not `false' AND no prior state is stored, StoreRec
%% becomes the restorable state.
logger_replace(ID, HConfig, false) ->
    ?assertMatch(ok, logger:remove_handler(ID)),
    ?assertMatch(ok, logger:add_handler(ID, logger_std_h, HConfig));
logger_replace(ID, HConfig, StoreRec) ->
    persistent_term:get(?LOGSTATE_PKEY, undefined) =/= undefined
        orelse persistent_term:put(?LOGSTATE_PKEY, StoreRec),
    logger_replace(ID, HConfig, false).

-ifdef(TEST).

stop_pid(Other) when not is_pid(Other) ->
    ok;
stop_pid(Pid) ->
    unlink(Pid),
    exit(Pid, shutdown),
    ok = wait_for_pid(Pid).

wait_for_pid(Pid) ->
    Mref = erlang:monitor(process, Pid),
    receive
        {'DOWN', Mref, process, _, _} ->
            ok
    after
        5000 ->
            {error, didnotexit}
    end.

setup_mockring1() ->
    % requires a running riak_core_ring_manager, in test-mode is ok
    Ring0 = riak_core_ring:fresh(16,node()),
    Ring1 = riak_core_ring:add_member(node(), Ring0, 'othernode@otherhost'),
    Ring2 = riak_core_ring:add_member(node(), Ring1, 'othernode2@otherhost2'),

    Ring3 = lists:foldl(fun(_,R) ->
                               riak_core_ring:transfer_node(
                                 hd(riak_core_ring:my_indices(R)),
                                 'othernode@otherhost', R) end,
                        Ring2,[1,2,3,4,5,6]),
    Ring = lists:foldl(fun(_,R) ->
                               riak_core_ring:transfer_node(
                                 hd(riak_core_ring:my_indices(R)),
                                 'othernode2@otherhost2', R) end,
                       Ring3,[1,2,3,4,5,6]),
    riak_core_ring_manager:set_ring_global(Ring).

fake_ring(Size, NumNodes) ->
    ManyNodes = [list_to_atom("dev" ++ integer_to_list(X) ++ "@127.0.0.1")
                 || _ <- lists:seq(0, Size div NumNodes),
                    X <- lists:seq(1, NumNodes)],
    Nodes = lists:sublist(ManyNodes, Size),
    Inc = chash:ring_increment(Size),
    Indices = lists:seq(0, (Size-1)*Inc, Inc),
    Owners = lists:zip(Indices, Nodes),
    [Node|OtherNodes] = Nodes,
    Ring = riak_core_ring:fresh(Size, Node),
    Ring2 = lists:foldl(fun(OtherNode, RingAcc) ->
                                RingAcc2 = riak_core_ring:add_member(Node, RingAcc, OtherNode),
                                riak_core_ring:set_member(Node, RingAcc2, OtherNode,
                                                          valid, same_vclock)
                        end, Ring, OtherNodes),
    Ring3 = lists:foldl(fun({Idx, Owner}, RingAcc) ->
                                riak_core_ring:transfer_node(Idx, Owner, RingAcc)
                        end, Ring2, Owners),
    Ring3.

-endif. %TEST.
