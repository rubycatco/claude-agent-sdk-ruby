# Testing with Cassettes

`ClaudeAgentSDK::Testing::Cassette` records the stream-JSON frames of a real session to a JSONL file, then replays them in later test runs without the CLI: no subprocess, no API call, and the same frames every time. It is not loaded by `require 'claude_agent_sdk'`; require it in your test helper:

```ruby
require 'claude_agent_sdk/testing/cassette'
```

## Recording and Replaying

```ruby
cassette = ClaudeAgentSDK::Testing::Cassette.new('spec/cassettes/weather.jsonl')

# query() and ask take a transport instance
result = ClaudeAgentSDK.ask('Weather in Beijing?', options: options, transport: cassette.transport(options))

# Client takes a transport class and its arguments; each connect plays the next recorded connection
ClaudeAgentSDK::Client.open(options: options, **cassette.client_args) do |client|
  client.query('Weather in Beijing?')
  client.receive_response { |message| ... }
end

cassette.verify!
```

The default mode, `:once`, records when the file does not exist and replays it when it does. `mode: :record` and `mode: :replay` force one or the other, and `CLAUDE_CASSETTE_RECORD=1` in the environment forces recording. A recording wraps `SubprocessCLITransport` by default, so it needs a CLI and credentials; pass `transport_class:` and `transport_args:` to record through another transport.

Pass the same `options` to the query as to `cassette.transport(options)`. When they set `can_use_tool`, the transport starts the CLI with `--permission-prompt-tool stdio`, which `query` cannot add to a transport it did not build ([docs/client.md](client.md#one-shot-queries-over-a-custom-transport)).

If `connect`, `write`, `end_input` or `close` of the recorded transport does not complete (it raises, or its task is cancelled), or the transport is closed while one of them is still running, the recording is not saved (an existing file is left as it was), a warning says why, and `verify!` raises `Cassette::Error`. With several connections on one cassette (a `Client` that reconnects, or concurrent transports), the file is written each time the last open connection closes.

A replay plays the CLI's side of the conversation. Your hooks, `can_use_tool` callback and SDK MCP tools run during a replay exactly as they did while recording, and what they send back is compared with what was recorded.

## What a Replay Checks

Every frame the SDK writes (the `initialize` request, each prompt, each reply to a hook, permission or tool request) must match the recorded one. With `match: :strict`, the default, frames must be equal apart from `request_id`, `requestId` and `uuid` at the top level and any keys you list in `ignore:` (dropped at any depth). With `match: :type`, only the kind of frame is compared. Any object with `#call(recorded, written)`, such as a Proc or a Method, decides for itself. Frames the SDK writes back to back (replies to concurrent control requests) may arrive in any order; each is paired with the first recorded frame of the same kind that matches it.

The SDK's own control requests get a new id every run; the replay maps the recorded ids to the new ones, so responses reach the right waiter.

A mismatch raises `Cassette::MismatchError` from `query`, `ask`, `Client#connect` or `Client#receive_response`, naming the first difference:

```text
connection 0: control_response 00000000-...-16 differs: $.response.response.mcp_response.result.content[0].text: recorded "5", written "six"
```

If the SDK does not write a frame the cassette expects within `wait:` seconds (default 5), the replay raises `MismatchError` instead of hanging. A recorded CLI failure replays as the same `ProcessError`, with its exit code (nil included) and stderr.

The SDK does not have to read the CLI's output to its end: when it stops reading (a `break`, a disconnect) or the output ends before the SDK closes stdin, what it still writes, ends or closes is paired with the rest of the cassette when you call `verify!`, and CLI frames it never read are not reported. That includes a recorded result or CLI failure your test never read: a replay cannot tell whether your code used what the SDK delivered, so assert on the result in the test itself.

Call `verify!` once the session has ended. It raises `MismatchError` listing every mismatch, every recorded event the SDK did not answer (a frame it should have written, or a turn your test no longer sends), every frame or `end_input` the SDK wrote that the cassette does not have, and every connection that was never opened. Calling it again reports the same. A cassette file with an event the format does not define raises `Cassette::Error` when it is loaded, naming the line.

Read messages with a block (`query(...) { |message| ... }`, `receive_response { |message| ... }`) rather than iterating an Enumerator twice: a replay plays each recorded connection once.

## Warnings

A replay warns once, on stderr, and replays anyway, when:

- the options produce different CLI arguments than when the cassette was recorded (the cassette stores a digest of them). Settings that reach the CLI over stdin, such as hooks, agents and the prompt, are checked frame by frame instead.
- `CLIInstaller::PINNED_CLI_VERSION` has changed since the cassette was recorded.

Re-record with `CLAUDE_CASSETTE_RECORD=1` to clear either.

## The File

One JSON object per line: a header (`cassette`, `sdk_version`, `cli_version`, `pinned_cli_version`, `recorded_at`), then one event per line, each with the connection it belongs to (`conn`) and its direction (`dir`): `in` for a frame the CLI sent, `out` for a frame the SDK wrote, `connect`, `end_input` and `close` for the SDK's calls on the transport, and `exit` for the end of the CLI's output.

A cassette holds everything that crossed the wire: prompts, tool inputs and outputs, file contents the model read, and paths of the machine it was recorded on. Review it like any other fixture before you commit it.
