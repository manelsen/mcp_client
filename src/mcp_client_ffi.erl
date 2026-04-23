%% mcp_client_ffi — Erlang FFI for MCP STDIO transport.
%%
%% Opens OS processes via Erlang ports and communicates via
%% newline-delimited JSON-RPC 2.0 over STDIO.
-module(mcp_client_ffi).
-export([open_port/3, send_and_receive/3, send_data/2, close_port/1, dynamic_to_json/1, delete_file_if_exists/1, drain_notifications/1]).

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

%% Send data to port and wait for a JSON-RPC response.
%% Intercepts server-sent notifications (lines without "id") during the wait,
%% collecting them and returning alongside the response.
%% Returns {ok, {ResponseLine, Notifications}} | {error, Reason},
%% where Notifications is a list of notification binary strings.
send_and_receive(Port, Data, TimeoutMs) ->
  try
    erlang:port_connect(Port, self()),
    Port ! {self(), {command, <<Data/binary, "\n">>}},
    wait_for_line(Port, TimeoutMs, os:timestamp())
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

%% Drain any buffered notification messages from the port.
%% Uses zero timeout — only picks up what's already in the mailbox.
%% Returns a list of notification binary strings.
drain_notifications(Port) ->
  drain_notifications(Port, []).

drain_notifications(Port, Acc) ->
  receive
    {Port, {data, {eol, Line}}} ->
      case is_notification(Line) of
        true ->
          drain_notifications(Port, [Line | Acc]);
        false ->
          %% Not a notification — put it back in the mailbox and stop draining.
          %% Erlang doesn't have "unreceive", so we re-send to self.
          self() ! {Port, {data, {eol, Line}}},
          lists:reverse(Acc)
      end;
    {Port, {data, {noeol, Partial}}} ->
      %% Incomplete line — re-queue and stop. Can't meaningfully handle
      %% partial lines during drain.
      self() ! {Port, {data, {noeol, Partial}}},
      lists:reverse(Acc)
  after 0 ->
    lists:reverse(Acc)
  end.

%% Internal: wait for a complete JSON-RPC response line from the port.
%% Notifications (lines without "id") are collected and skipped.
%% Returns {ok, {ResponseLine, Notifications}} | {error, Reason}.
wait_for_line(Port, TimeoutMs, StartTime) ->
  Elapsed = timer:now_diff(os:timestamp(), StartTime) div 1000,
  Remaining = TimeoutMs - Elapsed,
  case Remaining =< 0 of
    true ->
      {error, <<"timeout">>};
    false ->
      receive
        {Port, {data, {eol, Line}}} ->
          case is_notification(Line) of
            true ->
              %% Notification — collect it and keep waiting for the response.
              case wait_for_line(Port, TimeoutMs, StartTime) of
                {ok, {Resp, Notes}} ->
                  {ok, {Resp, [Line | Notes]}};
                Error ->
                  Error
              end;
            false ->
              {ok, {Line, []}}
          end;
        {Port, {data, {noeol, Partial}}} ->
          collect_rest(Port, Partial, TimeoutMs, StartTime, []);
        {Port, {exit_status, Status}} ->
          {error, list_to_binary(io_lib:format("Process exited with status ~p", [Status]))}
      after Remaining ->
        {error, <<"timeout">>}
      end
  end.

%% Internal: collect remaining data until we get eol or timeout.
%% Notifications intercepted during multi-line assembly are collected.
collect_rest(Port, Acc, TimeoutMs, StartTime, Notes) ->
  Elapsed = timer:now_diff(os:timestamp(), StartTime) div 1000,
  Remaining = TimeoutMs - Elapsed,
  case Remaining =< 0 of
    true ->
      {error, <<"timeout">>};
    false ->
      receive
        {Port, {data, {eol, Rest}}} ->
          FullLine = <<Acc/binary, Rest/binary>>,
          case is_notification(FullLine) of
            true ->
              %% Notification collected during multi-line read — keep waiting.
              wait_for_line(Port, TimeoutMs, StartTime);
            false ->
              case Notes of
                [] -> {ok, {FullLine, []}};
                _ -> {ok, {FullLine, lists:reverse(Notes)}}
              end
          end;
        {Port, {data, {noeol, Partial}}} ->
          collect_rest(Port, <<Acc/binary, Partial/binary>>, TimeoutMs, StartTime, Notes);
        {Port, {exit_status, Status}} ->
          {error, list_to_binary(io_lib:format("Process exited with status ~p", [Status]))}
      after Remaining ->
        {error, <<"timeout">>}
      end
  end.

%% Check if a JSON-RPC message is a notification (no "id" field).
%% Uses a simple binary search for the "id" key rather than full JSON parsing.
%% A JSON-RPC response always has "id". A notification never does.
is_notification(Line) ->
  case binary:match(Line, <<"\"id\"">>) of
    nomatch -> true;
    _ -> false
  end.

%% Delete a file if it exists; always returns nil.
delete_file_if_exists(Path) ->
  catch file:delete(binary_to_list(Path)),
  nil.

%% Convert an Erlang term (from gleam/dynamic) to a JSON binary string.
%% Uses the OTP 27 json module — the same encoder that gleam_json v3 uses.
dynamic_to_json(Term) ->
  try
    {ok, iolist_to_binary(json:encode(Term))}
  catch
    _:Reason ->
      {error, list_to_binary(io_lib:format("Failed to encode JSON: ~p", [Reason]))}
  end.
