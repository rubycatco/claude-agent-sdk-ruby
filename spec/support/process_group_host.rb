# frozen_string_literal: true

require 'json'

# The host side of the Ctrl-C example in
# spec/unit/subprocess_cli_transport_fake_cli_spec.rb (issue #175), run in a
# CHILD process that the spec starts as the leader of a process group of its
# own, the way a shell starts a foreground job. It traps INT the way a
# terminal app that handles Ctrl-C itself would (the trap only records the
# signal), connects a real SubprocessCLITransport to FakeClaude, and answers
# the spec's commands, one JSON line each:
#
#   (at start)  spawned: the CLI's pid, as soon as the CLI is started
#               ready: pids and process groups of the host and the CLI
#   int?        whether the host's INT trap ran (waits for it, bounded)
#   ping        a fresh control request to the CLI, and its response
#   waiter      how the CLI process ended, from its Open3 waiter
#
# Plain Ruby with no RSpec dependency; spec_helper loads it too, which only
# defines the module.
module ProcessGroupHost
  INITIALIZE_ID = 'req_1_0a1b2c3d'
  PING_ID = 'req_2_0a1b2c3d'
  # Generous: nothing healthy comes near it, and the spec bounds its own wait.
  WAIT_SECONDS = 15

  module_function

  # Child-process entry point:
  # `ruby -e 'ProcessGroupHost.main(ARGV)' CONFIG_JSON`, where CONFIG_JSON
  # holds `options`, the ClaudeAgentOptions attributes for the transport,
  # and `stall_before_ready`, which makes the host hang for good after the
  # initialize exchange, never reading its stdin again: what the spec's
  # cleanup must survive when readiness fails.
  def main(argv)
    $stdout.sync = true
    config = JSON.parse(argv.fetch(0))
    interrupts = Thread::Queue.new
    trap('INT') { interrupts << :int } # no SDK call in here: Ruby forbids it in a trap
    transport = ClaudeAgentSDK::SubprocessCLITransport.new(ClaudeAgentSDK::ClaudeAgentOptions.new(config['options']))
    transport.connect
    # Before anything that could hang, so the spec can always clean the CLI up.
    reply(event: 'spawned', child_pid: transport.instance_variable_get(:@process).pid)
    child_pid = request(transport, INITIALIZE_ID, subtype: 'initialize', hooks: nil, agents: nil)
                .dig(:response, :response, :pid)
    sleep if config['stall_before_ready']
    reply(event: 'ready', trap: true, host_pid: Process.pid, host_pgid: Process.getpgrp,
          child_pid: child_pid, child_pgid: Process.getpgid(child_pid))
    serve(transport, interrupts)
  ensure
    transport&.close
  end

  def serve(transport, interrupts)
    while (command = $stdin.gets&.chomp)
      case command
      when 'int?' then reply(event: 'int', received: !interrupts.pop(timeout: WAIT_SECONDS).nil?)
      when 'ping' then reply(event: 'ping', response: bounded { request(transport, PING_ID, subtype: 'mcp_status') })
      when 'waiter'
        status = transport.instance_variable_get(:@process).join(WAIT_SECONDS)&.value
        reply(event: 'waiter', exited: !status.nil?, termsig: status&.termsig, exitstatus: status&.exitstatus)
      end
    end
  end

  # Writes a control request and returns the first frame the CLI sends
  # back: FakeClaude answers a control request before anything else.
  def request(transport, id, request)
    transport.write("#{JSON.generate(type: 'control_request', request_id: id, request: request)}\n")
    transport.read_messages { |frame| break frame }
  end

  def bounded(&)
    worker = Thread.new(&)
    worker.report_on_exception = false # reported in the reply, by #value
    worker.join(WAIT_SECONDS) ? worker.value : { error: "no answer within #{WAIT_SECONDS}s" }
  rescue StandardError => e
    { error: "#{e.class}: #{e.message}" }
  end

  def reply(payload)
    $stdout.puts(JSON.generate(payload))
  end
end
