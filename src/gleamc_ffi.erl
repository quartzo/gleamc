%% Minimal Erlang shim for the gleamc compiler.
%%
%% The compiler runs on the BEAM: the remaining OS contact (processes,
%% environment, arguments) goes through here. File I/O uses `simplifile`.
%% These functions are called from Gleam via
%% `@external(erlang, "gleamc_ffi", "...")` (see src/gleamc/ffi.gleam).
-module(gleamc_ffi).

-export([run/1, which/1, get_env/1, argv/0]).

%% Runs a command through the shell and returns {ExitStatus, Output}.
%% (a Unix shell gives redirection/pipes for free)
-spec run(binary()) -> {integer(), binary()}.
run(Command) ->
    Port = open_port(
        {spawn, binary_to_list(Command)},
        [binary, exit_status, use_stdio, stderr_to_stdout, hide]
    ),
    collect(Port, []).

collect(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect(Port, [Acc, Data]);
        {Port, {exit_status, Status}} ->
            {Status, iolist_to_binary(Acc)}
    end.

-spec which(binary()) -> {ok, binary()} | {error, nil}.
which(Name) ->
    case os:find_executable(binary_to_list(Name)) of
        false -> {error, nil};
        Path -> {ok, list_to_binary(Path)}
    end.

-spec get_env(binary()) -> {ok, binary()} | {error, nil}.
get_env(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, list_to_binary(Value)}
    end.

-spec argv() -> [binary()].
argv() ->
    case init:get_plain_arguments() of
        [] ->
            %% `gleam run` with no `--`: use what the runner forwarded.
            case os:getenv("GLEAMC_ARGV") of
                false -> [];
                Value -> string:split(Value, " ", all)
            end;
        Args ->
            [list_to_binary(A) || A <- Args]
    end.
