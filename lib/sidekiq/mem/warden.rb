require "sidekiq"
require "sidekiq/mem/warden/version"

module Sidekiq
  module Mem
    module Warden
      class Error < StandardError; end

      class Config
        attr_accessor :memory_limit_mb, :check_interval, :quiet_timeout, :shutdown_timeout, :logger

        def initialize
          @memory_limit_mb = 4608
          @check_interval = 15
          @quiet_timeout = 30
          @shutdown_timeout = 300
          @logger = nil
        end
      end

      def self.configure
        yield(config)
      end

      def self.install!(sidekiq_config = nil)
        sidekiq_config ||= Sidekiq
        sidekiq_config.on(:startup) do
          start_monitor(Warden::Monitor.new(config))
        end
      end

      def self.config
        @config ||= Config.new
      end

      def self.start_monitor(monitor)
        @start_mutex ||= Mutex.new
        @start_mutex.synchronize do
          return if @started
          @started = true
        end
        monitor.start
      end

      class Monitor
        def initialize(config)
          @config = config
          @logger = config.logger || Sidekiq.logger
          @triggered = false
          @lock = Mutex.new
          @start_lock = Mutex.new
          @started = false
        end

        def start
          @start_lock.synchronize do
            return if @started
            @started = true
          end

          @thread = Thread.new do
            Thread.current.name = "sidekiq-mem-warden" if Thread.current.respond_to?(:name=)
            loop do
              sleep @config.check_interval
              next unless over_limit?
              trigger!
              break
            end
          end
        end

        private

        def trigger!
          @lock.synchronize do
            return if @triggered
            @triggered = true
          end

          @logger.warn("[sidekiq-mem-warden] RSS over limit (#{rss_mb}MB >= #{@config.memory_limit_mb}MB), quieting")
          begin
            Process.kill("TSTP", Process.pid)
          rescue StandardError => e
            @logger.warn("[sidekiq-mem-warden] failed to send TSTP: #{e.class}: #{e.message}")
          end

          sleep @config.quiet_timeout
          wait_for_idle(@config.shutdown_timeout)

          @logger.warn("[sidekiq-mem-warden] shutting down for restart")
          begin
            Process.kill("TERM", Process.pid)
          rescue StandardError => e
            @logger.warn("[sidekiq-mem-warden] failed to send TERM: #{e.class}: #{e.message}")
          end
        end

        def wait_for_idle(timeout_seconds)
          deadline = Time.now + timeout_seconds
          while Time.now < deadline
            busy = Sidekiq::Workers.new.size
            return if busy == 0
            sleep 1
          end
          @logger.warn("[sidekiq-mem-warden] timeout waiting for busy to drain; proceeding")
        end

        def over_limit?
          rss_mb >= @config.memory_limit_mb
        end

        def rss_mb
          (rss_kb.to_f / 1024).round(2)
        end

        def rss_kb
          status_path = "/proc/#{Process.pid}/status"
          if File.exist?(status_path)
            status = File.read(status_path)
            match = status.match(/^VmRSS:\s+(\d+)\s+kB$/)
            return match[1].to_i if match
          end

          output = `ps -o rss= -p #{Process.pid}`.to_s.strip
          output.to_i
        rescue StandardError
          0
        end
      end
    end
  end
end
