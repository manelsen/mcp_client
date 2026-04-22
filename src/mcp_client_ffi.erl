%% gleam_mcp_ffi — Erlang FFI for MCP STDIO transport.
%%
%% Opens OS processes via Erlang ports and communicates via
%% newline-delimited JSON-RPC 2.0 over STDIO.
-module(mcp_client_ffi).
-export([open_port/3, send_and_receive/3, send_data/2, close_port/1, dynamic_to_json/1, delete_file_if_exists/1]).

%% Open an OS process and return {ok, Port} or {error, Reason}.
%% Uses Erlang port with {line, 1048576} for line-buffered STDIO communication (1 MB buffer).
open_port(Command, Args, Env) ->
  try
    CommandStr = binary_to_list(Command),
    ArgsStrs = [binary_to_list(A) || A <- Args],
    EnvStrs = [{binary_to_list(K), binary_to_list(V)} || {K, V} <- Env],
    case resolve_command(CommandStr) of
      {ok, Executable} ->
        Port = erlang:open_port(
          {spawn_executable, Executable},
          [
            binary,
            {args, ArgsStrs},
            {env, EnvStrs},
            {line, 1048576},
            exit_status
          ]
        ),
        {ok, Port};
      {error, Reason} ->
        {error, list_to_binary(Reason)}
    end
  catch
    _:CatchReason ->
      {error, list_to_binary(io_lib:format("Failed to open port: ~p", [CatchReason]))}
  end.

%% Resolve command names from PATH when a bare executable name is provided.
resolve_command(CommandStr) ->
  case {filename:pathtype(CommandStr), lists:member($/, CommandStr)} of
    {absolute, _} ->
      {ok, CommandStr};
    {_, true} ->
      %% Relative paths with "/" are resolved from current working directory.
      {ok, filename:absname(CommandStr)};
    {_, false} ->
      case os:find_executable(CommandStr) of
        false ->
          {error, io_lib:format("Failed to open port: command not found (~s)", [CommandStr])};
        Executable ->
          {ok, Executable}
      end
  end.

%% Send data to port and wait for a complete line response.
%% Returns {ok, Line} | {error, Reason}.
%% NOTE: This must be called from the process that opened the port,
%% or the port's controlling process must be changed first.
send_and_receive(Port, Data, TimeoutMs) ->
  try
    %% Ensure this process is the port's controlling process
    erlang:port_connect(Port, self()),
    Port ! {self(), {command, <<Data/binary, "\n">>}},
    wait_for_line(Port, TimeoutMs)
  catch
    _:Reason ->
      {error, list_to_binary(io_lib:format("Send/receive failed: ~p", [Reason]))}
  end.

%% Send data to port without waiting for response (fire-and-forget).
%% Returns {ok, nil} | {error, Reason}.
send_data(Port, Data) ->
  try
    erlang:port_connect(Port, self()),
    Port ! {self(), {command, <<Data/binary, "\n">>}},
    {ok, nil}
  catch
    _:Reason ->
      {error, list_to_binary(io_lib:format("Send failed: ~p", [Reason]))}
  end.

%% Close the port and clean up.
%% Returns nil.
close_port(Port) ->
  try
    catch port_close(Port)
  catch
    _:_ -> nil
  end,
  nil.

%% Internal: wait for a complete line from the port.
wait_for_line(Port, TimeoutMs) ->
  receive
    {Port, {data, {eol, Line}}} ->
      {ok, Line};
    {Port, {data, {noeol, Partial}}} ->
      %% Incomplete line, wait for the rest
      collect_rest(Port, Partial, TimeoutMs);
    {Port, {exit_status, Status}} ->
      {error, list_to_binary(io_lib:format("Process exited with status ~p", [Status]))}
  after TimeoutMs ->
    {error, <<"timeout">>}
  end.

%% Internal: collect remaining data until we get eol or timeout.
collect_rest(Port, Acc, TimeoutMs) ->
  receive
    {Port, {data, {eol, Rest}}} ->
      {ok, <<Acc/binary, Rest/binary>>};
    {Port, {data, {noeol, Partial}}} ->
      collect_rest(Port, <<Acc/binary, Partial/binary>>, TimeoutMs);
    {Port, {exit_status, Status}} ->
      {error, list_to_binary(io_lib:format("Process exited with status ~p", [Status]))}
  after TimeoutMs ->
    {error, <<"timeout">>}
  end.

%% Delete a file if it exists; always returns nil.
delete_file_if_exists(Path) ->
  catch file:delete(binary_to_list(Path)),
  nil.

%% Convert a dynamic (arbitrary Erlang term) to JSON string.
dynamic_to_json(Term) ->
  try
    JsonStr = format_as_json(Term),
    {ok, list_to_binary(JsonStr)}
  catch
    _:Reason ->
      {error, list_to_binary(io_lib:format("Failed to encode JSON: ~p", [Reason]))}
  end.

%% Escape a string for safe JSON embedding.
escape_json_string([]) -> [];
escape_json_string([$" | Rest])  -> [$\\, $"  | escape_json_string(Rest)];
escape_json_string([$\\ | Rest]) -> [$\\, $\\ | escape_json_string(Rest)];
escape_json_string([$\n | Rest]) -> [$\\, $n  | escape_json_string(Rest)];
escape_json_string([$\r | Rest]) -> [$\\, $r  | escape_json_string(Rest)];
escape_json_string([$\t | Rest]) -> [$\\, $t  | escape_json_string(Rest)];
escape_json_string([C | Rest])   -> [C        | escape_json_string(Rest)].

%% Simple JSON formatter for common Erlang terms.
format_as_json(Term) when is_binary(Term) ->
  "\"" ++ escape_json_string(binary_to_list(Term)) ++ "\"";
format_as_json(Term) when is_list(Term) ->
  case io_lib:printable_list(Term) of
    true ->
      "\"" ++ escape_json_string(Term) ++ "\"";
    false ->
      %% It's a list/array
      "[" ++ string:join([format_as_json(E) || E <- Term], ",") ++ "]"
  end;
format_as_json(Term) when is_map(Term) ->
  Pairs = maps:to_list(Term),
  FormattedPairs = [format_key_value(K, V) || {K, V} <- Pairs],
  "{" ++ string:join(FormattedPairs, ",") ++ "}";
format_as_json(Term) when is_integer(Term) ->
  integer_to_list(Term);
format_as_json(Term) when is_float(Term) ->
  float_to_list(Term);
format_as_json(true) ->
  "true";
format_as_json(false) ->
  "false";
format_as_json(nil) ->
  "null";
format_as_json(null) ->
  "null";
format_as_json(_) ->
  "null".

format_key_value(Key, Value) when is_binary(Key) ->
  "\"" ++ binary_to_list(Key) ++ "\":" ++ format_as_json(Value);
format_key_value(Key, Value) when is_atom(Key) ->
  "\"" ++ atom_to_list(Key) ++ "\":" ++ format_as_json(Value);
format_key_value(Key, Value) ->
  "\"" ++ lists:flatten(io_lib:format("~p", [Key])) ++ "\":" ++ format_as_json(Value).
