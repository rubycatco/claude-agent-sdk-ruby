# frozen_string_literal: true

require 'English'
require 'digest'
require 'fileutils'
require 'json'
require 'securerandom'
require 'time'
require_relative '../../claude_agent_sdk'

module ClaudeAgentSDK
  module Testing
    # Records the stream-JSON frames of real sessions to a JSONL file and
    # replays them later without the CLI: no subprocess, no API call, the
    # same frames every time. Hooks, can_use_tool, SDK MCP tools and
    # SessionStore mirroring run for real during a replay, because the
    # replay plays the CLI's side of the conversation and checks what the
    # SDK writes back.
    #
    #   require 'claude_agent_sdk/testing/cassette'
    #
    #   cassette = ClaudeAgentSDK::Testing::Cassette.new('spec/cassettes/weather.jsonl')
    #   result = ClaudeAgentSDK.ask('Weather in Beijing?', options: options, transport: cassette.transport(options))
    #   ClaudeAgentSDK::Client.open(options: options, **cassette.client_args) { |client| ... }
    #   cassette.verify!
    #
    # Mode :once (the default) records when the file does not exist and
    # replays it when it does; :record and :replay force one or the other,
    # and CLAUDE_CASSETTE_RECORD=1 in the environment forces recording.
    #
    # A cassette is a header line followed by one event per line, each
    # tagged with the connection (+conn+) it belongs to. +dir+ is the
    # direction: +in+ a frame the CLI sent, +out+ a frame the SDK wrote,
    # +connect+, +end_input+ and +close+ the SDK's calls on the transport,
    # +exit+ the end of the CLI's output. A replay walks the events of a
    # connection in order: it yields each +in+ frame, waits for the SDK to
    # write each +out+ frame and compares it, and waits for +end_input+ and
    # +close+. Consecutive +out+ events are matched in any order, since
    # replies to concurrent control requests can be written in either.
    #
    # A mismatch raises MismatchError from the transport's read loop, so it
    # reaches the caller of query / ask / Client like a CLI failure would.
    # (Raising it from #write would not: the SDK answers a failed write of a
    # control response as a callback failure.) #verify! reports mismatches
    # again, and events the replay never reached.
    class Cassette
      class Error < ClaudeSDKError; end

      # The SDK did something the cassette did not record.
      class MismatchError < Error; end

      FORMAT_VERSION = 1
      MODES = %i[once record replay].freeze
      MATCH_MODES = %i[strict type].freeze

      # Top-level keys that differ on every run: the ids the SDK gives its
      # own control requests (remapped instead) and message uuids.
      VOLATILE_KEYS = %i[request_id requestId uuid].freeze

      attr_reader :path, :mode, :match, :ignore, :wait

      # @param path [String, Pathname] the JSONL file
      # @param mode [Symbol] :once, :record or :replay
      # @param match [Symbol, Proc] how an SDK frame is compared with the
      #   recorded one: :strict (equal apart from VOLATILE_KEYS and +ignore+),
      #   :type (same type, subtype and control request id), or a Proc
      #   called with (recorded, written) that returns truthy on a match
      # @param ignore [Array<String, Symbol>] keys :strict drops at any depth
      # @param wait [Numeric] seconds a replay waits for each SDK write
      # @param transport_class the transport a recording wraps
      # @param transport_args [Hash] keyword arguments for transport_class.new
      def initialize(path, mode: :once, match: :strict, ignore: [], wait: 5,
                     transport_class: SubprocessCLITransport, transport_args: {})
        raise ArgumentError, "mode must be one of #{MODES.inspect} (got #{mode.inspect})" unless MODES.include?(mode)
        unless MATCH_MODES.include?(match) || match.respond_to?(:call)
          raise ArgumentError, "match must be one of #{MATCH_MODES.inspect} or a Proc (got #{match.inspect})"
        end

        @path = path.to_s
        @mode = resolve_mode(mode)
        @match = match
        @ignore = ignore.map(&:to_sym)
        @wait = wait
        @transport_class = transport_class
        @transport_args = transport_args
        @mutex = Mutex.new
        @connections = 0
        @inflight = Hash.new(0)
        @open = []
        @saved = false
        @publish = Mutex.new
        @transports = []
        @problems = []
        @warned = {}
        @events = []
        if recording?
          @header = {}
        else
          load!
        end
      end

      def recording?
        @mode == :record
      end

      def replaying?
        @mode == :replay
      end

      # A transport for one connection, for query(transport:) / ask(transport:).
      # Pass the same options to the query. With can_use_tool set, the
      # transport gets them with permission_prompt_tool_name: 'stdio', which
      # query cannot add to a transport it did not build (docs/client.md).
      # @param options [ClaudeAgentOptions] the options of the call, used to
      #   spawn the CLI when recording and for the fingerprint check
      def transport(options = nil)
        options ||= ClaudeAgentOptions.new
        if options.can_use_tool && !options.permission_prompt_tool_name
          options = options.dup_with(permission_prompt_tool_name: 'stdio')
        end
        transport_class.new(options, cassette: self)
      end

      # Keyword arguments for Client.new / Client.open. Each connect takes
      # the next connection of the cassette.
      def client_args
        { transport_class: transport_class, transport_args: { cassette: self } }
      end

      # Raises MismatchError listing every mismatch and every event a replay
      # did not reach, or, for a recording, Error saying why it was not saved. Call it
      # after the session has ended. Calling it again reports the same.
      # @return [nil]
      def verify!
        transports = @mutex.synchronize { @transports.dup }
        # Settled before the problems are read: settling reports mismatches.
        leftovers = replaying? ? transports.flat_map(&:leftovers) : []
        problems = @mutex.synchronize do
          @problems + @open.map { |conn| "connection #{conn} was never closed; the cassette was not saved" }
        end
        problems += leftovers
        (transports.size...connection_count).each do |conn|
          problems << "connection #{conn} was recorded but never opened" if replaying?
        end
        return nil if problems.empty?

        raise Error, "cassette #{@path} was not recorded cleanly:\n- #{problems.uniq.join("\n- ")}" if recording?

        raise MismatchError, "cassette #{@path} did not replay cleanly:\n- #{problems.uniq.join("\n- ")}"
      end

      # A short digest of the CLI arguments +options+ produce (everything
      # but the executable path), or nil when they cannot be built. Settings
      # that reach the CLI through stdin instead (hooks, agents, the prompt)
      # are checked frame by frame.
      def self.fingerprint(options)
        argv = CommandBuilder.new('claude', options).build.drop(1)
        "sha256:#{Digest::SHA256.hexdigest(JSON.generate(argv))[0, 16]}"
      rescue StandardError
        nil
      end

      # The rest is for the two transports.

      # @api private
      attr_reader :transport_args

      # @api private
      def recording_transport_class
        @transport_class
      end

      # @api private
      def open_connection(transport)
        @mutex.synchronize do
          @transports << transport
          @connections += 1
          @open << (@connections - 1) if recording?
          @connections - 1
        end
      end

      # @api private
      def record(conn, dir, **fields)
        frame = fields[:frame]
        @mutex.synchronize do
          if dir == 'in' && frame[:type] == 'system' && frame[:subtype] == 'init' && !@header[:cli_version]
            @header[:cli_version] = frame[:claude_code_version]
          end
          @events << { conn: conn, dir: dir, **fields }
        end
      end

      # @api private
      def events_for(conn)
        @events.select { |event| event[:conn] == conn }
      end

      # @api private
      def report(problem)
        @mutex.synchronize { @problems << problem }
      end

      # Brackets a transport call while recording: save does not publish
      # while a call on the connection it closes is in flight, its outcome
      # not known yet. A call that did not return (it raised, or was
      # cancelled) invalidates the recording in the same step as it ends, so
      # a save never sees it finished but not yet failed.
      # @api private
      def call_started(conn)
        @mutex.synchronize { @inflight[conn] += 1 }
      end

      # @api private
      def call_finished(conn, call, failed, error)
        @mutex.synchronize do
          @inflight[conn] -= 1
          invalidate_unlocked(conn, call, error) if failed
        end
      end

      # A transport call the format cannot replay did not complete: the
      # cassette is not saved, so a bad recording never replaces a file. When
      # it was saved already, verify! says it must be re-recorded.
      # @api private
      def invalidate(conn, call, error)
        @mutex.synchronize { invalidate_unlocked(conn, call, error) }
      end

      # @api private
      def warn_once(message)
        first = @mutex.synchronize { @warned[message] ? false : (@warned[message] = true) }
        warn "Claude SDK: cassette #{@path}: #{message}" if first
      end

      # Called when connection +conn+ closes. Publishes once every
      # connection opened so far is closed: to a sibling temp file first,
      # renamed into place, so a failure never leaves half a cassette.
      # Publications are serialized from the snapshot to the rename, so an
      # older snapshot never replaces a newer one.
      # @api private
      def save(conn)
        @publish.synchronize do
          lines, invalid = snapshot(conn)
          return warn_once("not saved: #{invalid}") if invalid
          return unless lines

          publish(lines)
        end
      end

      # Whether +written+ matches the +recorded+ frame (both already of the
      # same kind), or a description of the first difference.
      # @api private
      def compare(recorded, written)
        case @match
        when :type then nil
        when :strict
          Cassette.difference(normalize(recorded), normalize(written))
        else
          @match.call(recorded, written) ? nil : 'the match Proc returned false'
        end
      end

      # The first place +expected+ and +actual+ differ, as text, or nil.
      # @api private
      def self.difference(expected, actual, path = '$') # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- one recursive walk over Hash, Array and leaf
        return nil if expected == actual

        if expected.is_a?(Hash) && actual.is_a?(Hash)
          (expected.keys | actual.keys).each do |key|
            at = "#{path}.#{key}"
            return "#{at}: missing (recorded #{brief(expected[key])})" unless actual.key?(key)
            return "#{at}: not recorded (written #{brief(actual[key])})" unless expected.key?(key)

            found = difference(expected[key], actual[key], at)
            return found if found
          end
        elsif expected.is_a?(Array) && actual.is_a?(Array) && expected.size == actual.size
          expected.each_index do |i|
            found = difference(expected[i], actual[i], "#{path}[#{i}]")
            return found if found
          end
        end
        "#{path}: recorded #{brief(expected)}, written #{brief(actual)}"
      end

      # @api private
      def self.brief(value)
        text = JSON.generate(value)
        text.size > 120 ? "#{text[0, 117]}..." : text
      end

      private

      def invalidate_unlocked(conn, call, error)
        outcome = error ? "raised #{error.class}: #{error.message}" : 'did not complete'
        problem = "connection #{conn}: #{call} #{outcome}"
        @invalid ||= problem
        @problems << (@saved ? "#{problem} after the cassette was saved; re-record it" : "#{problem}; not saved")
      end

      # The lines to publish, nil while another connection is open, or the
      # reason the recording is invalid.
      # Only a completed rename counts as saved. A failure (or cancellation)
      # invalidates the recording, so verify! reports it, and goes on.
      def publish(lines)
        done = false
        temp = "#{@path}.#{Process.pid}.#{SecureRandom.hex(4)}.tmp"
        FileUtils.mkdir_p(File.dirname(@path))
        File.write(temp, lines.join("\n") << "\n")
        File.rename(temp, @path)
        done = true
      ensure
        FileUtils.rm_f(temp) unless done
        @mutex.synchronize do
          if done
            @saved = true
          else
            error = $ERROR_INFO
            @invalid ||= "writing #{@path} #{error ? "raised #{error.class}: #{error.message}" : 'did not complete'}"
            @problems << "#{@invalid}; not saved"
          end
        end
      end

      def snapshot(conn)
        @mutex.synchronize do
          @open.delete(conn)
          if @inflight[conn].positive?
            @invalid ||= "connection #{conn} was closed while #{@inflight[conn]} call(s) on it were in flight"
            @problems << "#{@invalid}; not saved"
          end
          next [nil, @invalid] if @invalid
          next [nil, nil] unless @open.empty?

          header = { cassette: FORMAT_VERSION, sdk_version: VERSION, cli_version: @header[:cli_version],
                     pinned_cli_version: CLIInstaller::PINNED_CLI_VERSION, recorded_at: Time.now.utc.iso8601 }
          [[header, *@events].map { |line| JSON.generate(line) }, nil]
        end
      end

      def transport_class
        recording? ? RecordingTransport : ReplayTransport
      end

      def connection_count
        @events.map { |event| event[:conn] }.uniq.size
      end

      def resolve_mode(mode)
        return :record if ENV['CLAUDE_CASSETTE_RECORD'] == '1'
        return mode unless mode == :once

        File.exist?(@path) ? :replay : :record
      end

      def load!
        raise Error, "cassette #{@path} does not exist (record it with mode: :record)" unless File.exist?(@path)

        header, *events = File.readlines(@path, chomp: true).reject(&:empty?)
                              .map { |line| JSON.parse(line, symbolize_names: true) }
        unless header.is_a?(Hash) && header[:cassette] == FORMAT_VERSION
          raise Error, "#{@path} is not a version #{FORMAT_VERSION} cassette"
        end

        events.each_with_index { |event, index| validate_event(event, index + 2) }
        @header = header
        @events = events
        pinned = header[:pinned_cli_version]
        return if pinned.nil? || pinned == CLIInstaller::PINNED_CLI_VERSION

        warn_once("recorded with CLI #{header[:cli_version] || 'unknown'} when the pinned CLI was #{pinned}; " \
                  "the pin is now #{CLIInstaller::PINNED_CLI_VERSION}. Re-record it with CLAUDE_CASSETTE_RECORD=1.")
      rescue JSON::ParserError => e
        raise Error, "#{@path} is not a valid cassette: #{e.message}"
      end

      DIRECTIONS = %w[connect in out end_input close exit].freeze
      private_constant :DIRECTIONS

      def validate_event(event, line)
        valid = event.is_a?(Hash) && event[:conn].is_a?(Integer) && DIRECTIONS.include?(event[:dir]) &&
                (!%w[in out].include?(event[:dir]) || event[:frame].is_a?(Hash))
        raise Error, "#{@path}:#{line} is not a cassette event: #{Cassette.brief(event)}" unless valid
      end

      def normalize(frame)
        strip_keys(frame.except(*VOLATILE_KEYS))
      end

      def strip_keys(value)
        case value
        when Hash then value.except(*@ignore).transform_values { |item| strip_keys(item) }
        when Array then value.map { |item| strip_keys(item) }
        else value
        end
      end

      # Wraps a real transport (cassette transport_class, by default
      # SubprocessCLITransport) and records every call and frame.
      class RecordingTransport < Transport
        def initialize(options, cassette:)
          super()
          @cassette = cassette
          @options = options
          @inner = cassette.recording_transport_class.new(options, **cassette.transport_args)
          @conn = cassette.open_connection(self)
          @close_state = nil
          @close_lock = Mutex.new
        end

        def connect
          guard('connect') do
            @inner.connect
            @cassette.record(@conn, 'connect', fingerprint: Cassette.fingerprint(@options))
          end
        end

        def ready?
          @inner.ready?
        end

        # Recorded before the write: the CLI's reply can be read before the
        # write returns, and the replay must see the write first.
        def write(data)
          guard('write') do
            data.each_line do |line|
              next if line.strip.empty?

              @cassette.record(@conn, 'out', frame: JSON.parse(line, symbolize_names: true))
            end
            @inner.write(data)
          end
        end

        def end_input
          guard('end_input') do
            @cassette.record(@conn, 'end_input')
            @inner.end_input
          end
        end

        def read_messages
          return enum_for(:read_messages) unless block_given?

          from_sdk = nil
          @inner.read_messages do |message|
            @cassette.record(@conn, 'in', frame: JSON.parse(JSON.generate(message), symbolize_names: true))
            begin
              yield message
            rescue StandardError => e
              from_sdk = e
              raise
            end
          end
          @cassette.record(@conn, 'exit', status: 0)
        rescue StandardError => e
          record_failure(e) unless e.equal?(from_sdk)
          raise
        end

        # Idempotent; one caller at a time owns the close. Only a close
        # that returns completes it: one that raised or was cancelled
        # invalidates the recording and can be retried, to release what the
        # inner transport holds. The close event is recorded once.
        def close
          first = @close_lock.synchronize do
            next nil if %i[closing closed].include?(@close_state)

            first_attempt = @close_state.nil?
            @close_state = :closing
            first_attempt
          end
          return if first.nil?

          @cassette.record(@conn, 'close') if first
          done = false
          begin
            @inner.close
            done = true
          ensure
            @close_state = done ? :closed : :failed
            @cassette.invalidate(@conn, 'close', $ERROR_INFO) unless done
            @cassette.save(@conn)
          end
        end

        private

        # A call counts as done only when it returns: an exception or a
        # cancellation (Async::Stop) invalidates the recording, then goes on.
        def guard(call)
          @cassette.call_started(@conn)
          done = false
          result = yield
          done = true
          result
        ensure
          @cassette.call_finished(@conn, call, !done, $ERROR_INFO)
        end

        # The end of the CLI's output as an error: a ProcessError replays as
        # one (exit_code nil included), anything else as CLIConnectionError.
        # ProcessError decorates its message with the exit code and stderr;
        # the base message is recorded so a replay raises the same text.
        def record_failure(error)
          message = error.message
          unless error.is_a?(ProcessError)
            return @cassette.record(@conn, 'exit', error: error.class.name, message: message)
          end

          message = message.split("\nError output: ").first if error.stderr
          message = message.delete_suffix(" (exit code: #{error.exit_code})") if error.exit_code
          @cassette.record(@conn, 'exit', error: 'ProcessError', status: error.exit_code, stderr: error.stderr,
                                          message: message)
        end
      end

      # Plays the CLI's side of one recorded connection.
      class ReplayTransport < Transport
        def initialize(options, cassette:)
          super()
          @cassette = cassette
          @options = options
          @conn = cassette.open_connection(self)
          @events = cassette.events_for(@conn)
          @position = 0
          @unmatched = []
          @written = Thread::Queue.new
          @ids = {}
          @state = Mutex.new
          @reading = false
          @backlog = []
          @settle_failed = false
          @connected = false
        end

        def connect
          if @events.empty?
            raise Error, "cassette #{@cassette.path} has no connection #{@conn} (it was recorded with fewer connects)"
          end

          @connected = true
          event = current
          return unless event&.dig(:dir) == 'connect'

          advance
          fingerprint = Cassette.fingerprint(@options)
          return if event[:fingerprint].nil? || fingerprint.nil? || event[:fingerprint] == fingerprint

          @cassette.warn_once("connection #{@conn}: the options produce different CLI arguments than when it was " \
                              'recorded. Re-record it with CLAUDE_CASSETTE_RECORD=1.')
        end

        def ready?
          @connected
        end

        # Only queues: a mismatch is raised from #read_messages (see Cassette).
        def write(data)
          data.each_line do |line|
            next if line.strip.empty?

            frame = begin
              JSON.parse(line, symbolize_names: true)
            rescue JSON::ParserError
              { unparsable: line.chomp }
            end
            @written << [:frame, frame]
          end
        end

        def end_input
          @written << [:end_input]
        end

        # Idempotent: only the first close pairs with the recorded one.
        def close
          @written << [:close]
          @connected = false
        end

        def read_messages(&block)
          return enum_for(:read_messages) unless block

          read(&block)
        end

        # What #verify! reports for this connection.
        # @api private
        def leftovers
          @state.synchronize do
            settle_unlocked unless @reading
            remaining = @unmatched + @events.drop(@position)
            where = remaining.empty? ? 'after the cassette ended' : 'where the cassette does not have it'
            remaining.map { |event| "connection #{@conn}: never reached #{describe(event)}" } +
              @backlog.filter_map do |(what, frame)|
                case what
                when :frame then "connection #{@conn}: the SDK wrote #{Cassette.brief(frame)} #{where}"
                when :end_input then "connection #{@conn}: the SDK called end_input #{where}"
                end
              end
          end
        end

        private

        # Only the call that took the read loop releases it.
        def read(&)
          @state.synchronize do
            raise Error, "connection #{@conn} is already being read" if @reading

            @reading = true
          end
          begin
            play(&)
          rescue MismatchError => e
            @cassette.report(e.message)
            raise
          ensure
            @state.synchronize { @reading = false }
          end
        end

        # Once the read loop is over (the CLI's output ended, or the SDK
        # stopped reading), what the SDK wrote, ended or closed that the loop
        # never took is paired with the events left, in order, without
        # waiting. CLI frames left are skipped: the SDK need not read the
        # CLI's output to its end. Stops at the first event without its
        # call, and for good at the first mismatch, so repeated calls report
        # the same; #leftovers reports the rest.
        def settle_unlocked
          @backlog << @written.pop(timeout: 0) until @written.empty?
          @backlog.compact!
          return if @settle_failed

          loop do
            pending = @unmatched
            @unmatched = []
            pending << advance_unlocked while current&.dig(:dir) == 'out'
            unless pending.empty?
              settled = settle_writes(pending)
              @unmatched = pending
              return unless settled

              next
            end
            return unless (event = current) && settled?(event)
          end
        end

        def settle_writes(pending)
          until pending.empty?
            return false unless @backlog.first&.first == :frame

            check_write(pending, @backlog.shift[1])
          end
          true
        rescue MismatchError => e
          @cassette.report(e.message)
          @settle_failed = true
          false
        end

        # CLI events are skipped; an SDK call is taken from the backlog.
        def settled?(event)
          unless %w[in exit connect].include?(event[:dir])
            return false unless @backlog.first&.first == event[:dir].to_sym

            @backlog.shift
          end
          advance_unlocked
          true
        end

        def play
          while (event = current)
            case event[:dir]
            when 'connect' then advance
            when 'in'
              advance
              yield rewrite(event[:frame])
            when 'out' then return unless expect_writes
            when 'end_input' then return unless called?(:end_input)
            when 'close' then return unless called?(:close)
            when 'exit'
              advance
              finish(event)
              return
            else raise Error, "connection #{@conn}: unknown cassette event #{Cassette.brief(event)}"
            end
          end
        end

        # Takes the run of consecutive +out+ events at the current position
        # and waits until the SDK has written a matching frame for each, in
        # any order. False when the SDK closed the transport instead. What
        # is still pending when this ends early (close, a mismatch, or the
        # SDK stopping the read task) is kept for #leftovers.
        def expect_writes
          pending = []
          pending << advance while current&.dig(:dir) == 'out'
          until pending.empty?
            item = next_written("the SDK to write #{describe(pending.first)}")
            case item[0]
            when :close then return false
            when :end_input
              raise MismatchError, "connection #{@conn}: the SDK closed stdin before writing #{describe(pending.first)}"
            end
            check_write(pending, item[1])
          end
          true
        ensure
          @state.synchronize { @unmatched.concat(pending) }
        end

        # Of the pending frames of the same kind, the first that matches is
        # the one written; with none, the first is reported as differing.
        def check_write(pending, frame)
          candidates = pending.select { |event| kind(event[:frame]) == kind(frame) }
          if candidates.empty?
            raise MismatchError, "connection #{@conn}: the SDK wrote #{Cassette.brief(frame)}; " \
                                 "the cassette expects #{pending.map { |event| describe(event) }.join(' or ')}"
          end

          matched = matching(candidates, frame)
          recorded = pending.delete_at(pending.index { |event| event.equal?(matched) })[:frame]
          @ids[recorded[:request_id]] = frame[:request_id] if frame[:type] == 'control_request'
        end

        def matching(candidates, frame)
          differences = candidates.map { |event| @cassette.compare(event[:frame], frame) }
          index = differences.index(nil)
          return candidates[index] if index

          raise MismatchError, "connection #{@conn}: #{describe_frame(candidates.first[:frame])} differs: " \
                               "#{differences.first}"
        end

        # Waits for the SDK to call end_input / close. A write, or an
        # end_input where close is expected, is something the cassette does
        # not have. False when the SDK closed where end_input was expected.
        def called?(marker)
          what, frame = marker == :close ? @written.pop : next_written("the SDK to call #{marker}")
          if what == :frame
            raise MismatchError, "connection #{@conn}: the SDK wrote #{Cassette.brief(frame)}; " \
                                 "the cassette expects #{marker}"
          end
          if what == :end_input && marker == :close
            raise MismatchError, "connection #{@conn}: the SDK called end_input; the cassette expects close"
          end

          unless what == marker
            put_back([what])
            return false
          end

          advance
          true
        end

        # A call the read loop took but does not answer stays for #leftovers.
        def put_back(item)
          @state.synchronize { @backlog << item }
        end

        def next_written(what)
          item = @written.pop(timeout: @cassette.wait)
          raise MismatchError, "connection #{@conn}: timed out after #{@cassette.wait}s waiting for #{what}" unless item

          item
        end

        def finish(event)
          case event[:error]
          when nil then nil
          when 'ProcessError'
            raise ProcessError.new(event[:message] || 'Command failed', exit_code: event[:status],
                                                                        stderr: event[:stderr])
          else
            raise CLIConnectionError, "#{event[:message]} (recorded #{event[:error]})"
          end
        end

        # A fresh copy, as the subprocess transport parses each line anew,
        # with the SDK's own request ids put back into responses to them.
        def rewrite(frame)
          frame = JSON.parse(JSON.generate(frame), symbolize_names: true)
          return frame unless frame[:type] == 'control_response'

          # Both places Query reads a response's id from.
          [frame, frame[:response]].each do |holder|
            next unless holder.is_a?(Hash)

            %i[request_id requestId].each do |key|
              holder[key] = @ids[holder[key]] if holder.key?(key) && @ids.key?(holder[key])
            end
          end
          frame
        end

        # What identifies a written frame among concurrent ones.
        def kind(frame)
          case frame[:type]
          when 'control_request' then ['control_request', frame.dig(:request, :subtype)]
          when 'control_response' then ['control_response', frame.dig(:response, :request_id)]
          else [frame[:type]]
          end
        end

        def describe(event)
          case event[:dir]
          when 'out' then describe_frame(event[:frame])
          when 'in' then "CLI frame #{describe_frame(event[:frame])}"
          else event[:dir]
          end
        end

        def describe_frame(frame)
          kind(frame).compact.join(' ')
        end

        def current
          @events[@position]
        end

        def advance
          @state.synchronize { advance_unlocked }
        end

        def advance_unlocked
          event = @events[@position]
          @position += 1
          event
        end
      end
    end
  end
end
