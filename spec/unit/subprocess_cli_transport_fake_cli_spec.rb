# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# SubprocessCLITransport against a real child process (FakeClaude,
# spec/support/fake_claude.rb): what #connect hands the child, what it raises
# when the spawn fails, and how #close and the read loop treat a child that
# finishes, lingers or fails. The other transport specs enter #connect with
# Open3.popen3 stubbed, or plant a process in @process; here nothing is
# stubbed, and what the child saw is read from the child's own log.
RSpec.describe ClaudeAgentSDK::SubprocessCLITransport do
  around do |example|
    Dir.mktmpdir('fake-claude') do |dir|
      @dir = File.realpath(dir)
      @cli = FakeClaude.install(@dir)
      @log = File.join(@dir, 'fake-claude.jsonl')
      example.run
    end
  end

  def transport_for(scenario: 'conversation', cli_path: @cli, cwd: @dir, env: {}, **options)
    described_class.new(
      ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: cli_path, cwd: cwd, env: FakeClaude.env(scenario: scenario, log: @log).merge(env), **options
      )
    )
  end

  # Runs the block on a thread of its own and fails the example if it is
  # still running after +seconds+. The regressions these examples guard
  # against leave the SDK waiting for a child forever, and that has to be a
  # failure here, not a suite that never ends. Generous on purpose: nothing
  # healthy comes near it.
  def bounded(seconds = 60)
    worker = Thread.new do
      Thread.current.report_on_exception = false # the error is re-raised below, by #value
      yield
    end
    return worker.value if worker.join(seconds)

    # The child is what the SDK is stuck on: take it away, then report.
    FakeClaude.pids(@log).each { |pid| kill_fake_claude(pid) }
    worker.kill unless worker.join(10)
    raise "still running after #{seconds}s (the fake CLI was killed to end the example)"
  end

  # KILLs +pid+ only while it still is the fake CLI: a pid outlives its
  # process as a number that the system hands out again.
  def kill_fake_claude(pid)
    command, = Open3.capture2('ps', '-o', 'command=', '-p', pid.to_s)
    Process.kill('KILL', pid) if command.include?('fake_claude.rb')
  rescue Errno::ESRCH
    nil
  end

  # The first exchange of every session, and proof that the child is up and
  # reading: the `initialize` request the SDK sends, and the child's answer,
  # which is returned.
  def handshake(transport)
    request = { type: 'control_request', request_id: 'req_1_0a1b2c3d',
                request: { subtype: 'initialize', hooks: nil, agents: nil } }
    transport.write("#{JSON.generate(request)}\n")
    answer = transport.read_messages { |frame| break frame }
    expect(answer).to include(type: 'control_response')
    expect(answer.dig(:response, :request_id)).to eq('req_1_0a1b2c3d')
    answer
  end

  def events
    FakeClaude.events(@log)
  end

  describe '#connect' do
    it 'starts the child in cwd with the inherited environment, except CLAUDECODE' do
      previous = %w[CLAUDECODE FAKE_CLAUDE_INHERITED].to_h { |name| [name, ENV.fetch(name, nil)] }
      ENV['CLAUDECODE'] = '1' # what a shell inside Claude Code has; the CLI refuses to nest under it
      ENV['FAKE_CLAUDE_INHERITED'] = 'yes'
      transport = transport_for(env: { 'FAKE_CLAUDE_FROM_OPTIONS' => 'yes' })

      bounded do
        transport.connect
        handshake(transport)
        transport.close
      end

      start = events.first
      expect(start).to include('event' => 'start', 'cwd' => @dir)
      # Inherited and option-supplied variables both arrive, so the missing
      # one below was removed, not lost with everything else.
      expect(start.fetch('env_names')).to include('FAKE_CLAUDE_INHERITED', 'FAKE_CLAUDE_FROM_OPTIONS')
      expect(start.fetch('env_names')).not_to include('CLAUDECODE')
      expect(start.dig('env', 'CLAUDE_AGENT_SDK_VERSION')).to eq(ClaudeAgentSDK::VERSION)
      expect(start.dig('env', 'PWD')).to eq(@dir)
    ensure
      transport&.close
      previous&.each { |name, value| value ? ENV[name] = value : ENV.delete(name) }
    end

    it 'raises CLINotFoundError when the executable does not exist' do
      missing = File.join(@dir, 'no-such-claude')
      transport = transport_for(cli_path: missing)

      expect { bounded { transport.connect } }
        .to raise_error(ClaudeAgentSDK::CLINotFoundError, /#{Regexp.escape(missing)}/)
      expect(transport).not_to be_ready
    ensure
      transport&.close
    end

    it 'raises a CLIConnectionError naming the directory when cwd does not exist' do
      gone = File.join(@dir, 'gone')
      transport = transport_for(cwd: gone)

      expect { bounded { transport.connect } }.to raise_error(ClaudeAgentSDK::CLIConnectionError) do |error|
        # The executable is there: this must not be reported as a missing CLI.
        expect(error).not_to be_a(ClaudeAgentSDK::CLINotFoundError)
        expect(error.message).to include(gone)
      end
      expect(events).to be_empty # the child was never started
    ensure
      transport&.close
    end
  end

  # Issue #175. A terminal's Ctrl-C signals the whole foreground process
  # group; with process_group the CLI is out of it.
  describe 'process_group' do
    before { skip 'process groups are exercised on Unix only' if Gem.win_platform? }

    def child_pgid(process_group:)
      transport = transport_for(process_group: process_group)
      bounded do
        transport.connect
        pid = handshake(transport).dig(:response, :response, :pid)
        [pid, Process.getpgid(pid)] # while the child is alive
      end
    ensure
      transport&.close
    end

    it 'starts the CLI as the leader of a process group of its own, and in ours without it' do
      pid, pgid = child_pgid(process_group: true)
      expect(pgid).to eq(pid)
      expect(pgid).not_to eq(Process.getpgrp)

      _, pgid = child_pgid(process_group: false)
      expect(pgid).to eq(Process.getpgrp)
    end

    # The keypress itself, played for real: a host process that leads a group
    # of its own, as a shell's foreground job does, traps INT and runs the
    # transport against the fake CLI (spec/support/process_group_host.rb).
    # The example signals the host's whole group, as the terminal does.
    describe 'a Ctrl-C to the host process group' do
      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # Starts the host and reads its first reply, the CLI's pid: recorded
      # before anything that can hang, so the CLI is always cleaned up.
      def start_host(process_group:, scenario: 'conversation', stall_before_ready: false)
        config = { options: { cli_path: @cli, cwd: @dir, env: FakeClaude.env(scenario: scenario, log: @log),
                              process_group: process_group },
                   stall_before_ready: stall_before_ready }
        @host_err = File.join(@dir, 'host.err')
        @host_in, @host_out, @host = Open3.popen2(
          RbConfig.ruby, '-I', File.expand_path('../../lib', __dir__), '-r', 'claude_agent_sdk',
          '-r', File.expand_path('../support/process_group_host.rb', __dir__),
          '-e', 'ProcessGroupHost.main(ARGV)', JSON.generate(config), pgroup: true, err: @host_err
        )
        spawned = host_says
        expect(spawned).to include('event' => 'spawned')
        @child_pid = spawned.fetch('child_pid')
      end

      # The host's next reply. The whole line is read against one deadline:
      # a host that stalls after part of a line fails here as surely as one
      # that says nothing.
      def host_says(command = nil, seconds: 30)
        @host_in.puts(command) if command
        deadline = now + seconds
        @host_buffer ||= +''
        until (newline = @host_buffer.index("\n"))
          remaining = deadline - now
          raise "no reply from the host within #{seconds}s; its stderr: #{host_stderr}" unless remaining.positive?
          next unless @host_out.wait_readable(remaining)

          chunk = @host_out.read_nonblock(4096, exception: false)
          raise "the host closed its stdout mid-reply (#{@host_buffer.inspect}); its stderr: #{host_stderr}" unless chunk

          @host_buffer << chunk unless chunk == :wait_readable
        end
        JSON.parse(@host_buffer.slice!(0..newline))
      end

      def host_stderr
        @host_err && File.exist?(@host_err) ? File.read(@host_err) : ''
      end

      # Ready, and the groups are what the example is about: the host leads
      # one that is not ours (so the signal below cannot reach rspec), and
      # the CLI is in the expected one.
      def ready_host(process_group:)
        start_host(process_group: process_group)
        ready = host_says
        expect(ready).to include('event' => 'ready', 'trap' => true, 'host_pid' => @host.pid,
                                 'child_pid' => @child_pid)
        expect(ready.fetch('host_pgid')).to eq(@host.pid)
        expect(ready.fetch('host_pgid')).not_to eq(Process.getpgrp)
        expect(ready.fetch('child_pgid')).to eq(process_group ? @child_pid : @host.pid)
        ready.fetch('host_pgid')
      end

      def alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH, Errno::EPERM
        false
      end

      def kill(signal, pid)
        Process.kill(signal, pid)
      rescue Errno::ESRCH
        nil
      end

      # Stops what start_host started, and fails unless both processes are
      # gone. The host first gets a bounded chance to close its transport and
      # exit on stdin EOF, which reaps the CLI; then its group is KILLed, and
      # so is every CLI pid on record (the one the host reported, and those
      # the fake logged), since an isolated CLI is out of the host's group.
      # These are processes this example started moments ago, so a pid is
      # only KILLed while it still leads its own group or is in the host's.
      def stop_host(grace: 10)
        host = @host or return
        @host = nil
        @host_in.close
        unless host.join(grace)
          kill('KILL', -host.pid)
          raise 'the host is still running after SIGKILL' unless host.join(10)
        end
        @host_out.close
        cli = [@child_pid, *FakeClaude.pids(@log)].compact.uniq
        cli.each do |pid|
          kill('KILL', pid) if [pid, host.pid].include?(Process.getpgid(pid))
        rescue Errno::ESRCH
          nil
        end
        deadline = now + 10
        until (cli = cli.select { |pid| alive?(pid) }).empty?
          raise "the CLI is still running after SIGKILL: #{cli.inspect}" if now > deadline

          sleep 0.01 # polling for the reaper outside this process, against the deadline
        end
      end

      after { stop_host }

      it 'leaves the CLI alive and answering, and the host with the signal' do
        host_pgid = ready_host(process_group: true)

        Process.kill('INT', -host_pgid)

        expect(host_says('int?')).to include('received' => true)
        expect(host_says('ping').fetch('response')).to include(
          'type' => 'control_response', 'response' => include('request_id' => ProcessGroupHost::PING_ID)
        )
      end

      it 'kills the CLI with SIGINT along with the host without the option' do
        host_pgid = ready_host(process_group: false)

        Process.kill('INT', -host_pgid)

        expect(host_says('int?')).to include('received' => true)
        expect(host_says('waiter')).to include('exited' => true, 'termsig' => Signal.list.fetch('INT'))
      end

      # The cleanup above, when readiness never comes: a host that hangs
      # without reading stdin, and an isolated CLI that ignores stdin EOF
      # and SIGTERM. Neither may outlive the example.
      it 'leaves no process behind when the host never gets ready' do
        start_host(process_group: true, scenario: 'wedged', stall_before_ready: true)
        host = @host
        cli = @child_pid

        expect { host_says(seconds: 1) }.to raise_error(/no reply from the host within 1s/)
        stop_host(grace: 1)

        expect(host.join(0)).to be(host)
        expect(alive?(cli)).to be(false)
      end

      it 'bounds a reply that never comes, comes in part, or is cut off' do
        [['', true], ['{"event":"ready"', true], ['{"event":"ready"', false]].each do |partial, keep_open|
          @host_out, writer = IO.pipe
          @host_buffer = nil
          writer.write(partial)
          writer.close unless keep_open

          expect { bounded(5) { host_says(seconds: 0.2) } }
            .to raise_error(keep_open ? /no reply from the host within 0.2s/ : /closed its stdout mid-reply/)
        ensure
          @host_out&.close
          writer&.close
        end
      end
    end

    # Every SIGKILL the SDK sends a CLI started with process_group goes to
    # its process group first; SIGTERM stays on the pid. The processes put
    # in the CLI's group here are the example's own (spawned into it by
    # pid), and their waiters reap them, so how each one ended is read from
    # its own wait status, never from a signal 0 to a pid someone else
    # reaps.
    describe 'SIGKILL to the CLI process group' do
      before do
        @owned = []
        @sent = []
      end

      # Every process the example started: KILLed by pid while its waiter
      # still holds it, then reaped, bounded.
      after do
        @owned.each { |waiter| kill_by_waiter(waiter) }
        expect(@owned.reject { |waiter| waiter.join(10) }).to be_empty
      end

      # KILLs +waiter+'s process by pid while the waiter still holds it
      # (until it has reaped the process, the pid is that process's).
      def kill_by_waiter(waiter)
        Process.kill('KILL', waiter.pid) if waiter.alive?
      rescue Errno::ESRCH
        nil
      end

      # #bounded for these examples, without a process-table lookup: every
      # process they start is known by its waiter (the CLI's in @cli_waiter,
      # the rest in @owned), so when the bound expires those are KILLed by
      # pid, and the worker is joined, or killed, in an ensure that a
      # failing signal cannot skip. (@cli is the fake's path, set by the
      # file's around hook.)
      def bounded_by_waiters(seconds = 60)
        worker = Thread.new do
          Thread.current.report_on_exception = false # the error is re-raised below, by #value
          yield
        end
        return worker.value if worker.join(seconds)

        raise "still running after #{seconds}s (the example's processes were killed to end it)"
      ensure
        if worker&.alive?
          begin
            [@cli_waiter, *@owned].compact.each { |waiter| kill_by_waiter(waiter) }
          ensure
            worker.kill unless worker.join(10)
            worker.join(10)
          end
        end
      end

      def sigkill
        Signal.list.fetch('KILL')
      end

      # A process the example owns, in process group +pgroup+ (true: one of
      # its own; nil: ours), that ignores SIGTERM and never reads its stdin:
      # only SIGKILL ends it. Recorded before anything can fail; returned
      # (its waiter) once its trap is in place.
      def spawn_owned(pgroup)
        reader, writer = IO.pipe
        pid = Process.spawn({ 'RUBYOPT' => nil, 'RUBYLIB' => nil }, RbConfig.ruby, '--disable-gems', '-e',
                            "trap('TERM', 'IGNORE'); STDOUT.sync = true; puts 'ready'; sleep",
                            in: File::NULL, out: writer, pgroup: pgroup)
        @owned << (waiter = Process.detach(pid))
        writer.close
        expect(reader.wait_readable(30) && reader.gets).to eq("ready\n")
        waiter
      ensure
        [reader, writer].each { |io| io&.close unless io&.closed? }
      end

      # How +waiter+'s process ended: the signal that killed it, if any.
      def termsig(waiter)
        waiter.join(30)&.value&.termsig
      end

      # The graces that have to lapse (the CLI ignores stdin EOF and SIGTERM)
      # shrink to a fraction of a second; the polling is the real one. A KILL
      # of the CLI's pid returns once the CLI is reaped, so the bounded wait
      # after it cannot lapse on a slow machine. Every signal is recorded.
      def short_graces(transport)
        allow(transport).to receive(:wait_process_with_timeout).and_wrap_original do |original, seconds, *rest|
          original.call([seconds, 0.3].min, *rest)
        end
        allow(Process).to receive(:kill).and_wrap_original do |original, signal, target|
          @sent << [signal, target]
          result = original.call(signal, target)
          @cli_waiter.join(30) if signal == 'KILL' && @cli_waiter && target == @cli_waiter.pid
          result
        end
      end

      # A fake_* control request (spec/support/fake_claude.rb); its answer.
      def fake_request(transport, subtype, **fields)
        id = "req_#{subtype}"
        transport.write("#{JSON.generate(type: 'control_request', request_id: id,
                                         request: { subtype: subtype, **fields })}\n")
        answer = transport.read_messages { |frame| break frame }
        expect(answer.dig(:response, :request_id)).to eq(id)
        answer.dig(:response, :response)
      end

      # Connects to a wedged fake (it ignores stdin EOF and SIGTERM) and
      # returns its pid, with the CLI's waiter kept for the cleanup. The
      # signals recorded so far are dropped: #connect's `-v` probe gets a
      # TERM when its waiter has not reaped it yet, which is not teardown.
      def connect_wedged(transport)
        transport.connect
        @sent.clear
        @cli_waiter = transport.instance_variable_get(:@process)
        expect(handshake(transport).dig(:response, :response, :pid)).to eq(@cli_waiter.pid)
        @cli_waiter.pid
      end

      # The cleanup of an example that failed before the SDK killed the CLI,
      # or with an SDK that never does: the wedged CLI ignores everything
      # else, so it is KILLed by pid while its waiter still holds it, and
      # the #close that follows has nothing left to wait for. Bounded.
      def stop_cli(transport)
        Process.kill('KILL', @cli_waiter.pid) if @cli_waiter&.alive?
      rescue Errno::ESRCH
        nil
      ensure
        @cli_waiter&.join(10)
        transport&.close
      end

      # Takes the transport to a SIGKILL of the CLI on +path+: #close's
      # escalation, the read loop's wait after the CLI let go of stdout, or
      # the fallback of a #close cancelled before its escalation.
      def kill_through(path, transport)
        case path
        when :close then transport.close
        when :stdout_eof
          fake_request(transport, 'fake_close_stdout')
          expect { transport.read_messages { |_frame| nil } }
            .to raise_error(ClaudeAgentSDK::ProcessError, /terminated by the SDK with signal #{sigkill}/)
        when :cancelled_close
          allow(transport).to receive(:teardown_process).and_raise(Async::Stop)
          worker = nil
          allow(transport).to receive(:force_terminate_in_background).and_wrap_original do |original, process|
            worker = original.call(process, grace_seconds: 0.3)
          end
          expect { transport.close }.to raise_error(Async::Stop)
          expect(worker.join(30)).not_to be_nil
        end
      end

      %i[close stdout_eof cancelled_close].each do |path|
        it "reaches a process in the CLI's group that ignores SIGTERM (#{path})" do
          transport = transport_for(scenario: 'wedged', process_group: true)
          short_graces(transport)

          bounded_by_waiters do
            cli = connect_wedged(transport)
            member = spawn_owned(cli)
            kill_through(path, transport)

            expect(termsig(@cli_waiter)).to eq(sigkill)
            expect(termsig(member)).to eq(sigkill)
            expect(@sent.first(3)).to eq([['TERM', cli], ['KILL', -cli], ['KILL', cli]])
            expect(described_class.active_processes).not_to include(@cli_waiter)
          end
        ensure
          stop_cli(transport)
        end
      end

      it 'leaves a process in the CLI group running without the option' do
        transport = transport_for(scenario: 'wedged')
        short_graces(transport)

        bounded_by_waiters do
          cli = connect_wedged(transport)
          member = spawn_owned(nil) # the CLI's group is ours
          expect(Process.getpgid(member.pid)).to eq(Process.getpgid(cli))
          transport.close

          expect(termsig(@cli_waiter)).to eq(sigkill)
          expect(member.join(0.5)).to be_nil # still running; the after hook ends it
          expect(@sent).to eq([['TERM', cli], ['KILL', cli]])
        end
      ensure
        stop_cli(transport)
      end

      # A CLI may leave the group it was started in. The group KILL then
      # finds that group empty (ESRCH), or kills only what is left in it, and
      # the CLI itself is still KILLed by pid and waited for. It moves into a
      # group the example owns, never into ours.
      %i[close stdout_eof cancelled_close].each do |path|
        [false, true].each do |member_stays|
          left = member_stays ? 'still holds a process' : 'is empty'
          it "KILLs and reaps a CLI that left its group, when that group #{left} (#{path})" do
            elsewhere = spawn_owned(true)
            transport = transport_for(scenario: 'wedged', process_group: true)
            short_graces(transport)

            bounded_by_waiters do
              cli = connect_wedged(transport)
              member = spawn_owned(cli) if member_stays
              expect(fake_request(transport, 'fake_setpgid', pgid: elsewhere.pid)).to eq(pgid: elsewhere.pid)
              kill_through(path, transport)

              expect(termsig(@cli_waiter)).to eq(sigkill)
              expect(termsig(member)).to eq(sigkill) if member_stays
              expect(@sent.first(3)).to eq([['TERM', cli], ['KILL', -cli], ['KILL', cli]])
              expect(described_class.active_processes).not_to include(@cli_waiter)
            end
            expect(elsewhere).to be_alive # the group the CLI moved to was never signalled
          ensure
            stop_cli(transport)
          end
        end
      end

      # What the group KILL is for: the CLI's own children start in its
      # group. The fake reaps its child itself, at stdin EOF.
      it "starts the CLI's children in the CLI's group, and in ours without the option" do
        [true, false].each do |process_group|
          transport = transport_for(process_group: process_group)

          bounded_by_waiters do
            transport.connect
            @cli_waiter = transport.instance_variable_get(:@process)
            cli = handshake(transport).dig(:response, :response, :pid)
            child = fake_request(transport, 'fake_spawn_child')
            expect(child.fetch(:pgid)).to eq(process_group ? cli : Process.getpgrp)
            transport.close
          end

          expect(events.last(2)).to match([include('event' => 'eof'), include('event' => 'exit', 'status' => 0)])
        ensure
          transport&.close
        end
      end
    end
  end

  describe '#close' do
    # The grace period after stdin EOF exists for this child: the CLI flushes
    # its session file before it exits, and a SIGTERM in that window loses
    # the last message. A child that ignores TERM cannot tell a grace period
    # from none; one that needs a moment can.
    it 'lets a child that needs a moment after stdin EOF finish on its own, unsignalled' do
      transport = transport_for(scenario: 'slow_exit')

      bounded do
        transport.connect
        handshake(transport)
        transport.close
      end

      expect(events.map { |event| event['event'] }).to eq(%w[start stdin eof flushed exit])
      expect(events.last).to include('status' => 0)
    ensure
      transport&.close
    end

    it 'kills a child that ignores stdin EOF and SIGTERM' do
      transport = transport_for(scenario: 'wedged')

      # Real time: the ladder waits 5s for the exit and 2s after TERM before
      # KILL. If the escalation regresses, #close waits for a child that
      # never dies and the bound ends the example.
      bounded do
        transport.connect
        handshake(transport)
        transport.close
      end

      # It saw EOF, was asked with TERM, and never logged an exit of its own...
      expect(events.map { |event| event['event'] }).to eq(%w[start stdin eof signal])
      expect(events.last).to include('name' => 'TERM')
      # ...and it is gone, reaped, all the same.
      expect { Process.kill(0, events.first.fetch('pid')) }.to raise_error(Errno::ESRCH)
    ensure
      transport&.close
    end
  end

  describe '#read_messages and #write around a child that has exited' do
    it 'keeps the last 20 stderr lines and puts the last 10 in the ProcessError of a failed child' do
      lines = Thread::Queue.new
      transport = transport_for(scenario: 'stderr_then_fail', env: { 'FAKE_CLAUDE_STDERR_LINES' => '25' },
                                stderr: ->(line) { lines << line })
      written = Array.new(25) { |i| "fake claude: stderr line #{i + 1}" }

      error = bounded do
        transport.connect
        # All 25 have gone through the stderr thread before the child is
        # allowed to exit, so what the error carries below is not a race
        # with that thread.
        expect(Array.new(25) { lines.pop(timeout: 30) }).to eq(written)
        transport.end_input
        begin
          transport.read_messages { |_frame| nil }
          nil
        rescue ClaudeAgentSDK::ProcessError => e
          e
        end
      end

      expect(error).to be_a(ClaudeAgentSDK::ProcessError)
      expect(error.exit_code).to eq(1)
      expect(error.stderr).to eq(written.last(10).join("\n"))
      expect(transport.instance_variable_get(:@recent_stderr)).to eq(written.last(20))
    ensure
      transport&.close
    end

    it 'refuses to write to a child that has exited' do
      transport = transport_for(scenario: 'exit_at_once')

      bounded do
        transport.connect
        transport.read_messages { |_frame| nil } # returns at stdout EOF, once the child is reaped
        expect { transport.write("{}\n") }
          .to raise_error(ClaudeAgentSDK::CLIConnectionError, 'Cannot write to terminated process')
      end
    ensure
      transport&.close
    end
  end

  # The whole stack on the fake: ClaudeAgentSDK.query spawns it, probes its
  # version, initializes, serves the SDK MCP handshake, a hook and a tool
  # call, and closes stdin once the child reports idle.
  describe 'a query() run end to end' do
    it 'serves hooks and an SDK MCP server over the control channel, then lets the child exit on its own' do
      hook_inputs = []
      hook = lambda do |input, _tool_use_id, _context|
        hook_inputs << input
        {}
      end
      tool_calls = []
      add = ClaudeAgentSDK.create_tool('add', 'Add two numbers', { a: :number, b: :number }) do |args|
        tool_calls << args
        (args[:a] + args[:b]).to_s
      end
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: @cli, cwd: @dir,
        env: FakeClaude.env(log: @log, tool_call: JSON.generate(server: 'calc', name: 'add', arguments: { a: 2, b: 3 })),
        hooks: { 'PreToolUse' => [ClaudeAgentSDK::HookMatcher.new(matcher: 'Bash', hooks: [hook])] },
        mcp_servers: { 'calc' => ClaudeAgentSDK.create_sdk_mcp_server(name: 'calc', tools: [add]) }
      )

      messages = []
      bounded { ClaudeAgentSDK.query(prompt: 'hi', options: options) { |message| messages << message } }

      # What the caller sees.
      expect(messages.map(&:class)).to eq([ClaudeAgentSDK::InitMessage, ClaudeAgentSDK::AssistantMessage,
                                           ClaudeAgentSDK::ResultMessage])
      expect(messages.last.result).to eq('OK')
      expect(hook_inputs.map(&:class)).to eq([ClaudeAgentSDK::PreToolUseHookInput])
      expect(hook_inputs.first.tool_input).to eq(command: 'ls', description: 'List files')
      expect(tool_calls).to eq([{ a: 2, b: 3 }])

      # What the child received on its stdin.
      received = events.select { |event| event['event'] == 'stdin' }.map { |event| event.fetch('frame') }
      expect(received.first.dig('request', 'subtype')).to eq('initialize')
      expect(received.first.dig('request', 'hooks', 'PreToolUse')).to eq(
        [{ 'matcher' => 'Bash', 'hookCallbackIds' => ['hook_0'] }]
      )
      expect(received.find { |frame| frame['type'] == 'user' }.dig('message', 'content')).to eq('hi')
      mcp_results = received.filter_map { |frame| frame.dig('response', 'response', 'mcp_response', 'result') }
      expect(mcp_results[0]).to include('protocolVersion' => '2024-11-05', 'capabilities' => { 'tools' => {} })
      expect(mcp_results[2].fetch('tools').map { |tool| tool['name'] }).to eq(['add'])
      expect(mcp_results[3].fetch('content')).to eq([{ 'type' => 'text', 'text' => '5' }])

      # stdin was closed once the child reported idle, and it exited by
      # itself: an EOF, then a clean exit, no signal.
      expect(events.last(2).map { |event| event['event'] }).to eq(%w[eof exit])
      expect(events.last).to include('status' => 0)
    end
  end
end
