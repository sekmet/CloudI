%-*-Mode:erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et nomod:
%%%
%%%------------------------------------------------------------------------
%%% @doc
%%% ==OS Process Spawn==
%%% Used interaction with the cloudi_os_spawn process.
%%% @end
%%%
%%% MIT License
%%%
%%% Copyright (c) 2011-2019 Michael Truog <mjtruog at protonmail dot com>
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a
%%% copy of this software and associated documentation files (the "Software"),
%%% to deal in the Software without restriction, including without limitation
%%% the rights to use, copy, modify, merge, publish, distribute, sublicense,
%%% and/or sell copies of the Software, and to permit persons to whom the
%%% Software is furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in
%%% all copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
%%% FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
%%% DEALINGS IN THE SOFTWARE.
%%%
%%% @author Michael Truog <mjtruog at protonmail dot com>
%%% @copyright 2011-2019 Michael Truog
%%% @version 1.8.0 {@date} {@time}
%%%------------------------------------------------------------------------

-module(cloudi_core_i_os_spawn).
-author('mjtruog at protonmail dot com').

-behavior(gen_server).

%% gen_server interface
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, 
         handle_call/3, handle_cast/2, handle_info/2, 
         terminate/2, code_change/3]).

-include("cloudi_logger.hrl").
-include("cloudi_core_i_constants.hrl").
-ifdef(CLOUDI_CORE_STANDALONE).
-export([spawn/15]).
-define(ERL_PORT_NAME, "/dev/null").
-compile({nowarn_unused_function, [{call_port_sync, 3}]}).
spawn(_SpawnProcess, _SpawnProtocol, _SpawnSocketPath, _Ports, _SpawnRlimits,
      _SpawnUserI, _SpawnUserStr, _SpawnGroupI, _SpawnGroupStr,
      _SpawnNice, _SpawnChroot, _SpawnDirectory,
      _SpawnFilename, _SpawnArguments, _SpawnEnvironment) ->
    {error, badarg}.
-else.
-include("cloudi_core_i_os_spawn.hrl").
-endif.

-record(state, {last_port_name,
                replies = [],
                port = undefined}).

%%%------------------------------------------------------------------------
%%% Interface functions from gen_server
%%%------------------------------------------------------------------------

start_link() ->
    gen_server:start_link(?MODULE, [], []).

%%%------------------------------------------------------------------------
%%% Callback functions from gen_server
%%%------------------------------------------------------------------------

init([]) ->
    % port/port_driver find/load/open
    erlang:process_flag(trap_exit, true),
    Name = local_port_name(),
    Port = load_local_port(Name),
    true = is_port(Port),
    {ok, #state{last_port_name = Name,
                port = Port}}.

%% handle synchronous function calls on the port/port_driver
handle_call({call, Command, Msg}, Client,
            #state{port = Port,
                   replies = Replies} = State)
    when is_port(Port), is_list(Msg) ->
    case call_port(Port, Msg) of
        ok ->
            {noreply, State#state{replies = Replies ++ [{Command, Client}]}};
        {error, _} = Error ->
            {reply, Error, State}
    end;

handle_call(Request, _, State) ->
    {stop, cloudi_string:format("Unknown call \"~w\"", [Request]),
     error, State}.

%% handle asynchronous function calls on the port driver
handle_cast({call, _, Msg},
            #state{port = Port} = State)
    when is_port(Port) ->
    case call_port(Port, Msg) of
        ok ->
            ok;
        {error, Reason} ->
            ?LOG_ERROR("port_command error ~p~n", [Reason]),
            ok
    end,
    {noreply, State};

handle_cast(Request, State) ->
    {stop, cloudi_string:format("Unknown cast \"~w\"", [Request]), State}.

%% port exited with a fatal error/signal
handle_info({Port, {exit_status, Status}},
            #state{port = Port} = State)
    when is_port(Port), is_integer(Status) ->
    catch erlang:port_close(Port),
    Reason = "port exited with " ++ exit_status_to_list(Status),
    {stop, Reason, State#state{port = undefined}};

%% port/port_driver sync response
handle_info({Port, {data, Data}},
            #state{port = Port,
                   replies = Replies} = State)
    when is_port(Port) ->
    case transform_data(Data) of
        {error, 0, Reason} ->
            catch erlang:port_close(Port),
            {stop, Reason, State#state{port = undefined}};
        {error, Command, Reason} ->
            case lists:keytake(Command, 1, Replies) of
                false ->
                    catch erlang:port_close(Port),
                    {stop, "invalid reply", State#state{port = undefined}};
                {value, {Command, Client}, NewReplies} ->
                    gen_server:reply(Client, {error, Reason}),
                    {noreply, State#state{replies = NewReplies}}
            end;
        {stdout, OsPid, Output} ->
            cloudi_core_i_services_external:stdout(OsPid, Output),
            {noreply, State};
        {stderr, OsPid, Output} ->
            cloudi_core_i_services_external:stderr(OsPid, Output),
            {noreply, State};
        {Command, Success} ->
            case lists:keytake(Command, 1, Replies) of
                false ->
                    catch erlang:port_close(Port),
                    {stop, "invalid reply", State#state{port = undefined}};
                {value, {Command, Client}, NewReplies} ->
                    gen_server:reply(Client, {ok, Success}),
                    {noreply, State#state{replies = NewReplies}}
            end
    end;

%% port_driver async response
handle_info({Port, {async, RawData}},
            #state{port = Port} = State)
    when is_port(Port) ->
    Data = case transform_data(RawData) of
        {error, _, Reason} ->
            {error, Reason};
        {_, Success} ->
            {ok, Success}
    end,
    io:format("async function call returned: ~p~n", [Data]),
    {noreply, State};

%% something unexpected happened when sending to the port
handle_info({'EXIT', Port, PosixCode},
            #state{port = Port} = State)
    when is_port(Port) ->
    catch erlang:port_close(Port),
    Reason = case PosixCode of
        eacces ->
            "permission denied";
        eagain ->
            "resource temporarily unavailable";
        ebadf ->
            "bad file number";
        ebusy ->
            "file busy";
        edquot ->
            "disk quota exceeded";
        eexist ->
            "file already exists";
        efault ->
            "bad address in system call argument";
        efbig ->
            "file too large";
        eintr ->
            "interrupted system call";
        einval ->
            "invalid argument";
        eio ->
            "IO error";
        eisdir ->
            "illegal operation on a directory";
        eloop ->
            "too many levels of symbolic links";
        emfile ->
            "too many open files";
        emlink ->
            "too many links";
        enametoolong ->
            "file name too long";
        enfile ->
            "file table overflow";
        enodev ->
            "no such device";
        enoent ->
            "no such file or directory";
        enomem ->
            "not enough memory";
        enospc ->
            "no space left on device";
        enotblk ->
            "block device required";
        enotdir ->
            "not a directory";
        enotsup ->
            "operation not supported";
        enxio ->
            "no such device or address";
        eperm ->
            "not owner";
        epipe ->
            "broken pipe";
        erofs ->
            "read-only file system";
        espipe ->
            "invalid seek";
        esrch ->
            "no such process";
        estale ->
            "stale remote file handle";
        exdev ->
            "cross-domain link";
        Other when is_atom(Other) ->
            atom_to_list(Other)
    end,
    {stop, Reason, State#state{port = undefined}};

handle_info({ReplyRef, _}, State) when is_reference(ReplyRef) ->
    % gen_server:call/3 had a timeout exception that was caught but the
    % reply arrived later and must be discarded
    {noreply, State};

handle_info(Request, State) ->
    {stop, cloudi_string:format("Unknown info \"~w\"", [Request]), State}.

terminate(_, #state{port = Port}) when is_port(Port) ->
    catch erlang:port_close(Port),
    ok;

terminate(_, _) ->
    ok.

code_change(_, State, _) ->
    {ok, State}.

%%%------------------------------------------------------------------------
%%% Private functions
%%%------------------------------------------------------------------------

-ifdef(ERL_PORT_DRIVER_NAME).
local_port_name() ->
    ?ERL_PORT_DRIVER_NAME.
load_local_port(Name) when is_list(Name) ->
    {ok, Path} = load_path(Name ++ ".so"),
    Result = case erl_ddll:load_driver(Path, Name) of
        ok ->
            ok;
        {error, already_loaded} ->
            ok;
        % {open_error, -10}, otherwise known as "Unknown dlload error",
        % could mean any of the following:
        % - driver does not exist in the path specified
        % - driver can not be read
        % - driver does not have all the required symbols
        % etc.
        {error, ErrorDesc} ->
            {error, erl_ddll:format_error(ErrorDesc)}
    end,
    case Result of
        ok ->
            case erlang:open_port({spawn, Name}, []) of
                P when is_port(P) ->
                    {ok, P};
                Error ->
                    {error, Error}
            end;
        {error, Reason} ->
            {error, Reason}
    end.
transform_data(D) ->
    D.
% only a port driver can perform asynchronous function calls
call_port_async(Process, Command, Msg)
    when is_integer(Command), is_list(Msg) ->
    gen_server:cast(Process, {call, Command, Msg}).
-else.
-ifdef(ERL_PORT_NAME).
local_port_name() ->
    ?ERL_PORT_NAME.
load_local_port(Name) when is_list(Name) ->
    {ok, Path} = load_path(Name),
    erlang:open_port({spawn, Path ++ "/" ++ Name},
                     [{packet, 4}, binary, exit_status, nouse_stdio]).
transform_data(D) ->
    erlang:binary_to_term(D, [safe]).
%call_port_async(Process, Command, Msg) ->
%    call_port_sync(Process, Command, Msg).
-endif.
-endif.

call_port_sync(Process, Command, Msg)
    when is_integer(Command), is_list(Msg) ->
    try gen_server:call(Process, {call, Command, Msg})
    catch
        _:Reason ->
            {error, Reason}
    end.

call_port(Port, Msg) when is_port(Port), is_list(Msg) ->
    try erlang:port_command(Port, Msg) of
        true ->
            ok
    catch
        error:badarg ->
            try erlang:iolist_size(Msg) of
                _ ->
                    {error, einval}
            catch
                error:_ ->
                    {error, badarg}
            end;
        error:Reason ->
            {error, Reason}
    end.

load_path(File) when is_list(File) ->
    case cloudi_core_i_app:test() of
        true ->
            Path = [_ | _] = code:lib_dir(cloudi_core),
            {ok, filename:join(Path, "cxx_src")};
        false ->
            case code:priv_dir(cloudi_core) of
                {error, _} ->
                    {error, enotdir};
                Path ->
                    case file:read_file_info(filename:join([Path, File]),
                                             [raw]) of
                        {ok, _} ->
                            {ok, Path};
                        _ ->
                            {error, enoent}
                    end
            end
    end.

%% exit status messages

exit_status_to_list(  0) -> "no error occurred";
%% GEPD exit status values (from InternalExitStatus in port.cpp)
%% exit_status >= GEPD::ExitStatus::errors_min (from port.hpp)
%% (GEPD::ExitStatus::errors_min == 80)
exit_status_to_list( 80) -> "erlang exited";
exit_status_to_list( 81) -> "erlang port read EAGAIN";
exit_status_to_list( 82) -> "erlang port read EBADF";
exit_status_to_list( 83) -> "erlang port read EFAULT";
exit_status_to_list( 84) -> "erlang port read EINTR";
exit_status_to_list( 85) -> "erlang port read EINVAL";
exit_status_to_list( 86) -> "erlang port read EIO";
exit_status_to_list( 87) -> "erlang port read EISDIR";
exit_status_to_list( 88) -> "erlang port read null";
exit_status_to_list( 89) -> "erlang port read overflow";
exit_status_to_list( 90) -> "erlang port read unknown";
exit_status_to_list( 91) -> "erlang port write EAGAIN";
exit_status_to_list( 92) -> "erlang port write EBADF";
exit_status_to_list( 93) -> "erlang port write EFAULT";
exit_status_to_list( 94) -> "erlang port write EFBIG";
exit_status_to_list( 95) -> "erlang port write EINTR";
exit_status_to_list( 96) -> "erlang port write EINVAL";
exit_status_to_list( 97) -> "erlang port write EIO";
exit_status_to_list( 98) -> "erlang port write ENOSPC";
exit_status_to_list( 99) -> "erlang port write EPIPE";
exit_status_to_list(100) -> "erlang port write null";
exit_status_to_list(101) -> "erlang port write overflow";
exit_status_to_list(102) -> "erlang port write unknown";
exit_status_to_list(103) -> "erlang port ei_encode_error";
exit_status_to_list(104) -> "erlang port poll EBADF";
exit_status_to_list(105) -> "erlang port poll EFAULT";
exit_status_to_list(106) -> "erlang port poll EINTR";
exit_status_to_list(107) -> "erlang port poll EINVAL";
exit_status_to_list(108) -> "erlang port poll ENOMEM";
exit_status_to_list(109) -> "erlang port poll ERR";
exit_status_to_list(110) -> "erlang port poll HUP";
exit_status_to_list(111) -> "erlang port poll NVAL";
exit_status_to_list(112) -> "erlang port poll unknown";
exit_status_to_list(113) -> "erlang port pipe EFAULT";
exit_status_to_list(114) -> "erlang port pipe EINVAL";
exit_status_to_list(115) -> "erlang port pipe EMFILE";
exit_status_to_list(116) -> "erlang port pipe ENFILE";
exit_status_to_list(117) -> "erlang port pipe unknown";
exit_status_to_list(118) -> "erlang port dup EBADF";
exit_status_to_list(119) -> "erlang port dup EBUSY";
exit_status_to_list(120) -> "erlang port dup EINTR";
exit_status_to_list(121) -> "erlang port dup EINVAL";
exit_status_to_list(122) -> "erlang port dup EMFILE";
exit_status_to_list(123) -> "erlang port dup unknown";
exit_status_to_list(124) -> "erlang port close EBADF";
exit_status_to_list(125) -> "erlang port close EINTR";
exit_status_to_list(126) -> "erlang port close EIO";
exit_status_to_list(127) -> "erlang port close unknown";
%% exit status values due to signals
exit_status_to_list(129) -> "SIGHUP";
exit_status_to_list(130) -> "SIGINT";
exit_status_to_list(131) -> "SIGQUIT";
exit_status_to_list(132) -> "SIGILL";
exit_status_to_list(133) -> "SIGTRAP";
exit_status_to_list(134) -> "SIGABRT";
exit_status_to_list(135) -> "SIGBUS/SIGEMT";
exit_status_to_list(136) -> "SIGFPE";
exit_status_to_list(137) -> "SIGKILL";
exit_status_to_list(138) -> "SIGUSR1/SIGBUS";
exit_status_to_list(139) -> "SIGSEGV";
exit_status_to_list(140) -> "SIGUSR2/SIGSYS";
exit_status_to_list(141) -> "SIGPIPE";
exit_status_to_list(142) -> "SIGALRM";
exit_status_to_list(143) -> "SIGTERM";
exit_status_to_list(144) -> "SIGUSR1/SIGURG";
exit_status_to_list(145) -> "SIGUSR2/SIGCHLD/SIGSTOP";
exit_status_to_list(146) -> "SIGCHLD/SIGCONT/SIGTSTP";
exit_status_to_list(147) -> "SIGCONT/SIGSTOP/SIGPWR";
exit_status_to_list(148) -> "SIGCHLD/SIGTSTP/SIGWINCH";
exit_status_to_list(149) -> "SIGTTIN/SIGURG";
exit_status_to_list(150) -> "SIGTTOU/SIGIO";
exit_status_to_list(151) -> "SIGSTOP/SIGURG/SIGIO";
exit_status_to_list(152) -> "SIGTSTP/SIGXCPU";
exit_status_to_list(153) -> "SIGCONT/SIGXFSZ";
exit_status_to_list(154) -> "SIGTTIN/SIGVTALRM";
exit_status_to_list(155) -> "SIGTTOU/SIGPROF";
exit_status_to_list(156) -> "SIGVTALRM/SIGWINCH";
exit_status_to_list(157) -> "SIGPROF/SIGIO/SIGPWR";
exit_status_to_list(158) -> "SIGUSR1/SIGXCPU/SIGPWR";
exit_status_to_list(159) -> "SIGUSR2/SIGXFSZ/SIGSYS";
exit_status_to_list(Status) when is_integer(Status), Status > 128 ->
    "SIG#" ++ integer_to_list(Status - 128);
exit_status_to_list(Status) when is_integer(Status) ->
    integer_to_list(Status).

