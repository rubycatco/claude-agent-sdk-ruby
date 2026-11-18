# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'claude_agent_sdk/testing/cassette'

# Records through the real SubprocessCLITransport against FakeClaude (a child
# process speaking the CLI's protocol), then replays with the executable
# deleted, so a replay that tried to reach a CLI would fail.
# The CLI side of a transport, in process: answers each control request
# (in the shape +reply+ builds) and each prompt with a result. +fail_on+
# :write raises on the prompt, :exit ends the output with a ProcessError at
# end_input, :block holds the prompt's write until +release+ is popped
# (pushing to +entered+ first), :eof ends the output right after the result,
# :close holds every close the same way. +closes+ counts the closes.
class CassetteStubCLI < ClaudeAgentSDK::Transport
  def initialize(_options, reply: :nested, fail_on: nil, entered: nil, release: nil)
    super()
    @queue = Thread::Queue.new
    @reply = reply
    @fail_on = fail_on
    @entered = entered
    @release = release
    @closes = 0
  end

  attr_reader :closes

  def connect; end

  def write(data)
    frame = JSON.parse(data, symbolize_names: true)
    return prompt if frame[:type] == 'user'

    id = frame[:request_id]
    @queue << if @reply == :top_level
                { type: 'control_response', request_id: id, response: { subtype: 'success', response: {} } }
              else
                { type: 'control_response', response: { subtype: 'success', request_id: id, response: {} } }
              end
  end

  def prompt
    raise ClaudeAgentSDK::CLIConnectionError, 'send failed' if @fail_on == :write

    if @fail_on == :block
      @entered << true
      @release.pop
    end
    return if @queue.closed?

    @queue << { type: 'system', subtype: 'session_state_changed', state: 'running', sdk_host_only: true } if @fail_on == :eof
    @queue << { type: 'result', subtype: 'success', is_error: false, session_id: 's', result: 'OK' }
    @queue << :eof if @fail_on == :eof
  end

  def read_messages
    while (message = @queue.pop)
      break if message == :eof
      raise ClaudeAgentSDK::ProcessError.new('cannot reap', stderr: 'gone') if message == :fail

      yield message
    end
  end

  def end_input
    @queue << :fail if @fail_on == :exit
  end

  def close
    @closes += 1
    if @fail_on == :close
      @entered << true
      @release.pop
    end
    @queue.close
  end
end

RSpec.describe ClaudeAgentSDK::Testing::Cassette do
  around do |example|
    Dir.mktmpdir('cassette') do |dir|
      @dir = File.realpath(dir)
      @cli = FakeClaude.install(@dir)
      @path = File.join(@dir, 'cassettes', 'session.jsonl')
      Timeout.timeout(30) { example.run }
    end
  end

  let(:hook_inputs) { [] }
  let(:tool_calls) { [] }

  def options(**overrides)
    hook = lambda do |input, _tool_use_id, _context|
      hook_inputs << input.tool_name
      {}
    end
    add = ClaudeAgentSDK.create_tool('add', 'Add two numbers', { a: :number, b: :number }) do |args|
      tool_calls << args
      @tool_result ? @tool_result.call(args) : (args[:a] + args[:b]).to_s
    end
    ClaudeAgentSDK::ClaudeAgentOptions.new(
      cli_path: @cli, cwd: @dir,
      env: FakeClaude.env(tool_call: JSON.generate(server: 'calc', name: 'add', arguments: { a: 2, b: 3 }),
                          reply: 'The sum is 5'),
      hooks: { 'PreToolUse' => [ClaudeAgentSDK::HookMatcher.new(matcher: 'Bash', hooks: [hook])] },
      mcp_servers: { 'calc' => ClaudeAgentSDK.create_sdk_mcp_server(name: 'calc', tools: [add]) },
      **overrides
    )
  end

  def run_query(cassette, prompt = 'add 2 and 3', opts = options)
    messages = []
    ClaudeAgentSDK.query(prompt: prompt, options: opts, transport: cassette.transport(opts)) { |m| messages << m }
    messages
  end

  def run_client(cassette, prompts)
    ClaudeAgentSDK::Client.open(options: options, **cassette.client_args) do |client|
      prompts.map do |prompt|
        client.query(prompt)
        last = nil
        client.receive_response { |message| last = message }
        last.result
      end
    end
  end

  def record_query
    cassette = described_class.new(@path)
    expect(cassette).to be_recording
    run_query(cassette)
    hook_inputs.clear
    tool_calls.clear
    File.delete(@cli)
  end

  it 'replays a recorded query() with hooks and an SDK MCP tool, without a CLI' do
    recorded = run_query(described_class.new(@path))
    hook_inputs.clear
    tool_calls.clear
    File.delete(@cli)

    cassette = described_class.new(@path)
    expect(cassette).to be_replaying
    replayed = run_query(cassette)

    expect(replayed.map(&:class)).to eq(recorded.map(&:class))
    expect(replayed.last.result).to eq('The sum is 5')
    # The callbacks ran again during the replay, with the recorded inputs.
    expect(hook_inputs).to eq(['Bash'])
    expect(tool_calls).to eq([{ a: 2, b: 3 }])
    expect(cassette.verify!).to be_nil

    header = JSON.parse(File.readlines(@path).first)
    expect(header).to include('cassette' => 1, 'cli_version' => FakeClaude::CLI_VERSION,
                              'pinned_cli_version' => ClaudeAgentSDK::CLIInstaller::PINNED_CLI_VERSION)
  end

  it 'replays a multi-turn Client session, remapping the request ids the SDK generates' do
    expect(run_client(described_class.new(@path), %w[one two])).to eq(['The sum is 5'] * 2)
    File.delete(@cli)
    sdk_requests = File.readlines(@path).map { |line| JSON.parse(line) }.select do |event|
      event['dir'] == 'out' && event.dig('frame', 'type') == 'control_request'
    end
    # initialize, whose response must reach its waiter under a new id.
    expect(sdk_requests.map { |event| event.dig('frame', 'request', 'subtype') }).to eq(['initialize'])

    cassette = described_class.new(@path)
    expect(run_client(cassette, %w[one two])).to eq(['The sum is 5'] * 2)
    expect(cassette.verify!).to be_nil
  end

  it 'raises MismatchError naming the difference when a tool now returns something else' do
    record_query
    @tool_result = ->(_args) { 'six' }

    cassette = described_class.new(@path)
    expect { run_query(cassette) }.to raise_error(described_class::MismatchError, /recorded "5", written "six"/)
    expect { cassette.verify! }.to raise_error(described_class::MismatchError, /written "six"/)
  end

  it 'accepts the changed tool output under match: :type' do
    record_query
    @tool_result = ->(_args) { 'six' }

    cassette = described_class.new(@path, match: :type)
    expect(run_query(cassette).last.result).to eq('The sum is 5')
    expect(cassette.verify!).to be_nil
  end

  it 'raises MismatchError from ask when the prompt differs' do
    record_query

    cassette = described_class.new(@path)
    expect { ClaudeAgentSDK.ask('subtract', options: options, transport: cassette.transport(options)) }
      .to raise_error(described_class::MismatchError, /\$\.message\.content: recorded "add 2 and 3", written "subtract"/)
  end

  it 'replays a failed CLI as the same ProcessError' do
    opts = ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: @cli, cwd: @dir,
                                                  env: FakeClaude.env(scenario: 'stderr_then_fail', stderr_lines: 2))
    recorded = begin
      run_query(described_class.new(@path), 'hi', opts)
    rescue ClaudeAgentSDK::ProcessError => e
      e
    end
    expect(recorded).to be_a(ClaudeAgentSDK::ProcessError)
    File.delete(@cli)

    expect { run_query(described_class.new(@path), 'hi', opts) }.to raise_error(ClaudeAgentSDK::ProcessError) do |error|
      expect([error.class, error.message, error.exit_code, error.stderr])
        .to eq([recorded.class, recorded.message, recorded.exit_code, recorded.stderr])
    end
  end

  it 'reports the turns a replay never reached' do
    run_client(described_class.new(@path), %w[one two])
    File.delete(@cli)

    cassette = described_class.new(@path)
    expect(run_client(cassette, %w[one])).to eq(['The sum is 5'])
    expect { cassette.verify! }.to raise_error(described_class::MismatchError, /\A[^\n]+\n- connection 0: never reached user\n/)
  end

  it 'warns once when the options or the pinned CLI changed since recording, and replays anyway' do
    record_query
    expect { run_query(described_class.new(@path)) }.not_to output.to_stderr

    changed = options(model: 'claude-sonnet-5-5')
    expect { run_query(described_class.new(@path), 'add 2 and 3', changed) }
      .to output(/different CLI arguments than when it was recorded/).to_stderr

    lines = File.readlines(@path)
    lines[0] = "#{JSON.generate(JSON.parse(lines[0]).merge('pinned_cli_version' => '2.0.0'))}\n"
    File.write(@path, lines.join)
    expect { run_query(described_class.new(@path)) }
      .to output(/recorded with CLI #{Regexp.escape(FakeClaude::CLI_VERSION)} when the pinned CLI was 2\.0\.0/)
      .to_stderr
  end

  # A cassette written by hand, for cases a FakeClaude session cannot produce.
  def write_cassette(events)
    FileUtils.mkdir_p(File.dirname(@path))
    File.write(@path, [{ cassette: 1 }, *events.map { |event| { conn: 0, **event } }]
      .map { |line| "#{JSON.generate(line)}\n" }.join)
  end

  def replay_transport(**cassette_options)
    cassette = described_class.new(@path, **cassette_options)
    transport = cassette.transport
    transport.connect
    [cassette, transport]
  end

  def write_frame(transport, frame)
    transport.write("#{JSON.generate(frame)}\n")
  end

  it 'does not save a recording when a transport call failed, and verify! says why' do
    cassette = described_class.new(@path, transport_class: CassetteStubCLI, transport_args: { fail_on: :write })
    expect { ClaudeAgentSDK.ask('hi', transport: cassette.transport) }
      .to raise_error(ClaudeAgentSDK::CLIConnectionError, 'send failed')
      .and output(/not saved: connection 0: write raised/).to_stderr

    expect(File).not_to exist(@path)
    expect { cassette.verify! }.to raise_error(described_class::Error, /write raised .*send failed/)
  end

  it 'starts a recorded CLI with the permission prompt tool when can_use_tool is set' do
    log = File.join(@dir, 'cli.log')
    allow_all = ->(*) { ClaudeAgentSDK::PermissionResultAllow.new }
    opts = ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: @cli, cwd: @dir, env: FakeClaude.env(log: log),
                                                  can_use_tool: allow_all)
    ClaudeAgentSDK.ask('hi', options: opts, transport: described_class.new(@path).transport(opts))

    argv = FakeClaude.events(log).find { |event| event['event'] == 'start' }.fetch('argv')
    expect(argv.each_cons(2)).to include(['--permission-prompt-tool', 'stdio'])
  end

  it 'replays a ProcessError without an exit code as a ProcessError' do
    cassette = described_class.new(@path, transport_class: CassetteStubCLI, transport_args: { fail_on: :exit })
    expect { ClaudeAgentSDK.ask('hi', transport: cassette.transport) }.to raise_error(ClaudeAgentSDK::ProcessError)

    expect { ClaudeAgentSDK.ask('hi', transport: described_class.new(@path).transport) }
      .to raise_error(ClaudeAgentSDK::ProcessError) { |error| expect([error.exit_code, error.stderr]).to eq([nil, 'gone']) }
  end

  it 'remaps request ids in control responses that carry them at the top level' do
    cassette = described_class.new(@path, transport_class: CassetteStubCLI, transport_args: { reply: :top_level })
    ClaudeAgentSDK::Client.open(**cassette.client_args) { nil }

    cassette = described_class.new(@path, wait: 1)
    expect(ClaudeAgentSDK::Client.open(**cassette.client_args) { :connected }).to eq(:connected)
    expect(cassette.verify!).to be_nil
  end

  it 'pairs concurrent writes of the same kind by content, in either order' do
    a = { type: 'control_request', request_id: 'rec_a', request: { subtype: 'set_model', model: 'A' } }
    b = { type: 'control_request', request_id: 'rec_b', request: { subtype: 'set_model', model: 'B' } }
    reply = ->(id) { { type: 'control_response', response: { subtype: 'success', request_id: id, response: {} } } }
    write_cassette([{ dir: 'out', frame: a }, { dir: 'out', frame: b }, { dir: 'in', frame: reply.call('rec_b') },
                    { dir: 'in', frame: reply.call('rec_a') }, { dir: 'exit', status: 0 }])
    cassette, transport = replay_transport
    write_frame(transport, b.merge(request_id: 'new_b'))
    write_frame(transport, a.merge(request_id: 'new_a'))

    replies = []
    transport.read_messages { |frame| replies << frame.dig(:response, :request_id) }
    expect(replies).to eq(%w[new_b new_a])
    expect(cassette.verify!).to be_nil
  end

  it 'keeps reporting a write or end_input the cassette does not have' do
    write_cassette([{ dir: 'exit', status: 0 }, { dir: 'close' }])
    cassette, transport = replay_transport
    transport.read_messages { nil }
    transport.close
    transport.end_input
    write_frame(transport, type: 'user', message: { content: 'late' })
    transport.close

    2.times do
      expect { cassette.verify! }.to raise_error(described_class::MismatchError) { |error|
        expect(error.message.lines.drop(1).map(&:strip)).to eq(
          ['- connection 0: the SDK called end_input after the cassette ended',
           '- connection 0: the SDK wrote {"type":"user","message":{"content":"late"}} after the cassette ended']
        )
      }
    end
  end

  it 'does not save a recording whose write was cancelled' do
    entered = Thread::Queue.new
    cassette = described_class.new(@path, transport_class: CassetteStubCLI,
                                          transport_args: { fail_on: :block, entered: entered,
                                                            release: Thread::Queue.new })
    expect do
      Sync do |task|
        query = task.async { ClaudeAgentSDK.query(prompt: 'hi', transport: cassette.transport) { nil } }
        entered.pop
        query.stop
      end
    end.to output(/not saved: connection 0: write raised/).to_stderr

    expect(File).not_to exist(@path)
    expect { cassette.verify! }.to raise_error(described_class::Error, /write raised/)
  end

  it 'keeps the existing file when the transport is closed while a write is in flight' do
    write_cassette([{ dir: 'connect' }, { dir: 'close' }])
    original = File.read(@path)
    entered = Thread::Queue.new
    release = Thread::Queue.new
    cassette = described_class.new(@path, mode: :record, transport_class: CassetteStubCLI,
                                          transport_args: { fail_on: :block, entered: entered, release: release })
    transport = cassette.transport
    transport.connect
    writer = Thread.new { write_frame(transport, type: 'user', message: { content: 'hi' }) }
    entered.pop
    expect { transport.close }.to output(/not saved: connection 0 was closed while 1 call/).to_stderr
    release << true
    writer.join

    expect(File.read(@path)).to eq(original)
    expect { cassette.verify! }.to raise_error(described_class::Error, /connection 0 was closed while 1 call/)
  end

  it 'publishes once every connection is closed, not when another one closes mid-write' do
    entered = Thread::Queue.new
    release = Thread::Queue.new
    cassette = described_class.new(@path, transport_class: CassetteStubCLI,
                                          transport_args: { fail_on: :block, entered: entered, release: release })
    idle, busy = Array.new(2) { cassette.transport.tap(&:connect) }
    writer = Thread.new { write_frame(busy, type: 'user', message: { content: 'hi' }) }
    entered.pop
    idle.close
    expect(File).not_to exist(@path)
    release << true
    writer.join
    busy.close

    events = File.readlines(@path).drop(1).map { |line| JSON.parse(line).values_at('conn', 'dir') }
    expect(events).to eq([[0, 'connect'], [1, 'connect'], [1, 'out'], [0, 'close'], [1, 'close']])
    expect(cassette.verify!).to be_nil
  end

  it 'reports a wrong frame the SDK wrote after it stopped reading, the same way every time' do
    write_cassette([{ dir: 'in', frame: { type: 'system', subtype: 'a' } },
                    { dir: 'out', frame: { type: 'user', n: 1 } }, { dir: 'in', frame: { type: 'system', subtype: 'b' } },
                    { dir: 'out', frame: { type: 'user', n: 2 } }, { dir: 'close' }])
    cassette, transport = replay_transport
    transport.read_messages { break }
    write_frame(transport, type: 'user', n: 2)
    write_frame(transport, type: 'user', n: 1)
    transport.close

    messages = Array.new(2) do
      cassette.verify!
    rescue described_class::MismatchError => e
      e.message
    end
    expect(messages.first).to include('user differs: $.n: recorded 1, written 2')
    expect(messages.uniq.size).to eq(1)
  end

  it 'refuses a second read loop and keeps the first one running' do
    write_cassette([{ dir: 'in', frame: { type: 'system', subtype: 'a' } },
                    { dir: 'in', frame: { type: 'system', subtype: 'b' } }, { dir: 'exit', status: 0 }])
    _cassette, transport = replay_transport
    read = []
    transport.read_messages do |frame|
      transport.read_messages # an Enumerator; must not release the running loop
      expect { transport.read_messages { nil } }.to raise_error(described_class::Error, /already being read/)
      read << frame[:subtype]
    end
    expect(read).to eq(%w[a b])
  end

  it 'does not save a recording whose close was cancelled, and lets the SDK close again' do
    write_cassette([{ dir: 'connect' }, { dir: 'close' }])
    original = File.read(@path)
    entered = Thread::Queue.new
    release = Thread::Queue.new
    cassette = described_class.new(@path, mode: :record, transport_class: CassetteStubCLI,
                                          transport_args: { fail_on: :close, entered: entered, release: release })
    transport = cassette.transport
    transport.connect
    expect do
      Sync do |task|
        closer = task.async { transport.close }
        entered.pop
        closer.stop
      end
    end.to output(/not saved: connection 0: close raised/).to_stderr

    expect(File.read(@path)).to eq(original)
    expect { cassette.verify! }.to raise_error(described_class::Error, /close raised/)
    release << true
    transport.close
    expect(entered.size).to eq(1) # the retry reached the inner transport
  end

  it 'records one close when a second close comes while the first is in progress' do
    entered = Thread::Queue.new
    release = Thread::Queue.new
    cassette = described_class.new(@path, transport_class: CassetteStubCLI,
                                          transport_args: { fail_on: :close, entered: entered, release: release })
    transport = cassette.transport
    transport.connect
    closer = Thread.new { transport.close }
    entered.pop
    transport.close # returns at once: the first close owns it
    release << true
    closer.join

    expect(File.readlines(@path).drop(1).map { |line| JSON.parse(line)['dir'] }).to eq(%w[connect close])
    expect(cassette.verify!).to be_nil
  end

  it 'reports a cassette file it could not write' do
    File.write(File.join(@dir, 'cassettes'), 'a file where the directory should be')
    cassette = described_class.new(@path, transport_class: CassetteStubCLI)
    transport = cassette.transport
    transport.connect
    expect { transport.close }.to raise_error(SystemCallError)

    2.times { expect { cassette.verify! }.to raise_error(described_class::Error, /writing .* raised Errno::/) }
  end

  it 'counts a write as in flight from before its frame is recorded' do
    write_cassette([{ dir: 'connect' }, { dir: 'close' }])
    original = File.read(@path)
    cassette = described_class.new(@path, mode: :record, transport_class: CassetteStubCLI)
    transport = cassette.transport
    transport.connect
    entered = Thread::Queue.new
    release = Thread::Queue.new
    writer = Thread.new do
      trace = TracePoint.new(:call) do |point|
        next unless point.method_id == :record && point.self.equal?(cassette)

        trace.disable
        entered << true
        release.pop
      end
      trace.enable(target_thread: Thread.current) { write_frame(transport, type: 'user', message: { content: 'hi' }) }
    end
    entered.pop
    expect { transport.close }.to output(/not saved: connection 0 was closed while 1 call/).to_stderr
    release << true
    writer.join

    expect(File.read(@path)).to eq(original)
  end

  it 'never lets an older publication replace a newer one' do
    cassette = described_class.new(@path, transport_class: CassetteStubCLI)
    first = cassette.transport.tap(&:connect)
    entered = Thread::Queue.new
    release = Thread::Queue.new
    closer = Thread.new do
      trace = TracePoint.new(:c_call) do |point|
        next unless point.method_id == :rename && point.self == File

        trace.disable
        entered << true
        release.pop
      end
      trace.enable(target_thread: Thread.current) { first.close }
    end
    entered.pop
    second = cassette.transport.tap(&:connect)
    second_closer = Thread.new { second.close }
    sleep 0.1
    release << true
    [closer, second_closer].each(&:join)

    expect(File.readlines(@path).drop(1).map { |line| JSON.parse(line).values_at('conn', 'dir') })
      .to eq([[0, 'connect'], [0, 'close'], [1, 'connect'], [1, 'close']])
  end

  it 'does not take a close for the end_input the cassette expects' do
    write_cassette([{ dir: 'end_input' }, { dir: 'close' }])
    cassette, transport = replay_transport
    Sync do |task|
      reader = task.async { transport.read_messages { nil } }
      transport.close
      reader.wait
    end

    expect { cassette.verify! }.to raise_error(described_class::MismatchError, /never reached end_input/)
  end

  it 'pairs a close the SDK makes while the read loop is still running' do
    write_cassette([{ dir: 'in', frame: { type: 'system', subtype: 'x' } }, { dir: 'exit', status: 0 },
                    { dir: 'close' }])
    cassette, transport = replay_transport
    transport.read_messages { transport.close }

    expect(cassette.verify!).to be_nil
  end

  it 'does not require the SDK to read the CLI output to its end' do
    write_cassette([{ dir: 'in', frame: { type: 'system', subtype: 'a' } },
                    { dir: 'in', frame: { type: 'system', subtype: 'b' } }, { dir: 'close' }])
    cassette, transport = replay_transport
    read = []
    transport.read_messages do |frame|
      read << frame[:subtype]
      break
    end
    transport.close

    expect(read).to eq(['a'])
    expect(cassette.verify!).to be_nil
  end

  it 'replays a CLI whose output ends before the SDK closes stdin' do
    # can_use_tool keeps the control channel needed, so stdin stays open
    # until the SDK sees the output end.
    opts = ClaudeAgentSDK::ClaudeAgentOptions.new(can_use_tool: ->(*) { ClaudeAgentSDK::PermissionResultAllow.new })
    cassette = described_class.new(@path, transport_class: CassetteStubCLI, transport_args: { fail_on: :eof })
    expect(ClaudeAgentSDK.ask('hi', options: opts, transport: cassette.transport(opts)).result).to eq('OK')
    directions = File.readlines(@path).drop(1).map { |line| JSON.parse(line)['dir'] }
    expect(directions.last(3)).to eq(%w[exit end_input close])

    cassette = described_class.new(@path)
    expect(ClaudeAgentSDK.ask('hi', options: opts, transport: cassette.transport(opts)).result).to eq('OK')
    expect(cassette.verify!).to be_nil
  end

  it 'pairs what the SDK wrote before it disconnected and stopped reading' do
    send_only = ->(cassette) { ClaudeAgentSDK::Client.open(options: options, **cassette.client_args) { |c| c.query('hi') } }
    send_only.call(described_class.new(@path))
    File.delete(@cli)

    cassette = described_class.new(@path)
    send_only.call(cassette)
    expect(cassette.verify!).to be_nil
  end

  it 'rejects an event it does not know when loading' do
    write_cassette([{ dir: 'inn', frame: { type: 'user' } }])
    expect { described_class.new(@path) }.to raise_error(described_class::Error, /session\.jsonl:2 is not a cassette event/)
  end

  it 'accepts any object with #call as the matcher' do
    write_cassette([{ dir: 'out', frame: { type: 'user', n: 1 } }, { dir: 'exit', status: 0 }])
    cassette, transport = replay_transport(match: ->(recorded, written) { written[:n] == recorded[:n] + 1 }.method(:call))
    write_frame(transport, type: 'user', n: 2)
    transport.read_messages { nil }
    transport.close
    expect(cassette.verify!).to be_nil
  end

  it 'times out instead of hanging when the SDK never writes the recorded frame' do
    write_cassette([{ dir: 'out', frame: { type: 'user' } }])
    _cassette, transport = replay_transport(wait: 0.2)

    expect { transport.read_messages { nil } }
      .to raise_error(described_class::MismatchError, /timed out after 0.2s waiting for the SDK to write user/)
  end
end
