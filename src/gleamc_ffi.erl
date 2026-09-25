%% Minimal Erlang shim for the gleamc compiler (bootstrap host only).
%%
%% The compiler runs on the BEAM while it is bootstrapped by the official
%% toolchain; these functions provide its host process/environment access,
%% mirroring the C runtime's `Gleamc_host_*` builtins used when gleamc
%% compiles itself. File I/O uses `simplifile`.
-module(gleamc_ffi).

-export([
    run_blob/1,
    argv_blob/0,
    get_env_bin/1,
    which_bin/1,
    blob_slice/2,
    int64_at/2,
    char_code_at/2,
    char_byte_len/2,
    byte_slice/3,
    now_ms/0
]).

-spec now_ms() -> integer().
now_ms() ->
    erlang:monotonic_time(millisecond).

%% Runs a command through the shell and returns a blob: 8-byte little-endian
%% exit status followed by the combined stdout/stderr.
-spec run_blob(binary()) -> binary().
run_blob(Command) ->
    Port = open_port(
        {spawn, binary_to_list(Command) ++ " 2>&1"},
        [binary, exit_status, use_stdio, stderr_to_stdout, hide]
    ),
    {Status, Output} = collect(Port, []),
    <<Status:64/little, Output/binary>>.

collect(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect(Port, [Acc, Data]);
        {Port, {exit_status, Status}} ->
            {Status, iolist_to_binary(Acc)}
    end.

%% Command-line arguments joined by the unit separator (0x1f).
-spec argv_blob() -> binary().
argv_blob() ->
    Args = case init:get_plain_arguments() of
        [] ->
            case os:getenv("GLEAMC_ARGV") of
                false -> [];
                Value -> string:split(Value, " ", all)
            end;
        Found ->
            Found
    end,
    iolist_to_binary(lists:join(<<31>>, [list_to_binary(A) || A <- Args])).

-spec get_env_bin(binary()) -> binary().
get_env_bin(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> <<>>;
        Value -> list_to_binary(Value)
    end.

-spec which_bin(binary()) -> binary().
which_bin(Name) ->
    case os:find_executable(binary_to_list(Name)) of
        false -> <<>>;
        Path -> list_to_binary(Path)
    end.

-spec blob_slice(binary(), integer()) -> binary().
blob_slice(Blob, Offset) ->
    try binary:part(Blob, Offset, byte_size(Blob) - Offset)
    catch
        _:_ -> <<>>
    end.

-spec int64_at(binary(), integer()) -> integer().
int64_at(Blob, Index) ->
    Offset = Index * 8,
    try
        <<_:Offset/binary, Value:64/little-signed, _/binary>> = Blob,
        Value
    catch
        _:_ -> 0
    end.

%% Byte-indexed string access for the tokenizer.
char_code_at(String, Off) ->
    Bin = iolist_to_binary(String),
    case Off >= 0 andalso Off < byte_size(Bin) of
        false -> -1;
        true ->
            <<_:Off/binary, Rest/binary>> = Bin,
            {Code, _} = next_cp(Rest),
            Code
    end.

char_byte_len(String, Off) ->
    Bin = iolist_to_binary(String),
    case Off >= 0 andalso Off < byte_size(Bin) of
        false -> 0;
        true ->
            <<_:Off/binary, Rest/binary>> = Bin,
            {_, Len} = next_cp(Rest),
            Len
    end.

byte_slice(String, Start, Len) ->
    Bin = iolist_to_binary(String),
    Size = byte_size(Bin),
    S = max(0, min(Start, Size)),
    E = max(S, min(S + Len, Size)),
    binary:part(Bin, S, E - S).

next_cp(<<C/utf8, _/binary>>) ->
    {C, byte_size(<<C/utf8>>)};
next_cp(<<B, _/binary>>) ->
    {B, 1}.
