require "get_process_mem"
require "sidekiq"
require "sidekiq/api"
begin
  require "sidekiq/middleware/modules"
rescue LoadError
end
require "sidekiq/mem/warden/version"

module Sidekiq
  module Mem
    class Warden
      include Sidekiq::ServerMiddleware if defined?(Sidekiq::ServerMiddleware)

      MUTEX = Mutex.new
      DEFAULT_MAX_RSS_MB = 8192
      DEFAULT_GRACE_TIME_SECONDS = 300
      DEFAULT_SHUTDOWN_WAIT_SECONDS = 30
      DEFAULT_KILL_SIGNAL = "SIGKILL"
      DEFAULT_GC = true

      def initialize(options = {})
        @max_rss = options.fetch(:max_rss, DEFAULT_MAX_RSS_MB)
        @grace_time = options.fetch(:grace_time, DEFAULT_GRACE_TIME_SECONDS)
        @shutdown_wait = options.fetch(:shutdown_wait, DEFAULT_SHUTDOWN_WAIT_SECONDS)
        @kill_signal = options.fetch(:kill_signal, DEFAULT_KILL_SIGNAL)
        @gc = options.fetch(:gc, DEFAULT_GC)
        @skip_shutdown = options.fetch(:skip_shutdown_if, proc { false })
        @on_shutdown = options.fetch(:on_shutdown, nil)
      end

      def self.options_from_env(env = ENV)
        {
          max_rss: env.fetch("SIDEKIQ_MEM_WARDEN_LIMIT_MB", DEFAULT_MAX_RSS_MB).to_i,
          grace_time: env.fetch("SIDEKIQ_MEM_WARDEN_GRACE_TIME", DEFAULT_GRACE_TIME_SECONDS).to_i,
          shutdown_wait: env.fetch("SIDEKIQ_MEM_WARDEN_SHUTDOWN_WAIT", DEFAULT_SHUTDOWN_WAIT_SECONDS).to_i,
          kill_signal: env.fetch("SIDEKIQ_MEM_WARDEN_KILL_SIGNAL", DEFAULT_KILL_SIGNAL),
          gc: truthy?(env.fetch("SIDEKIQ_MEM_WARDEN_GC", DEFAULT_GC.to_s))
        }
      end

      def self.install!(config, env: ENV, logger: Sidekiq.logger, **overrides)
        options = options_from_env(env).merge(overrides)
        config.server_middleware do |chain|
          chain.add(self, **options)
        end

        logger&.warn(install_log(options))
        options
      end

      def call(worker, job, queue)
        yield

        return unless @max_rss.to_i > 0
        return unless current_rss > @max_rss

        GC.start(full_mark: true, immediate_sweep: true) if @gc
        return unless current_rss > @max_rss

        if skip_shutdown?(worker, job, queue)
          warn "current RSS #{current_rss} exceeds maximum RSS #{@max_rss}, " \
               "however shutdown will be ignored"
          return
        end

        warn "current RSS #{current_rss} of #{identity} exceeds maximum RSS #{@max_rss}"
        run_shutdown_hook(worker, job, queue)
        request_shutdown
      end

      private

      def run_shutdown_hook(worker, job, queue)
        @on_shutdown.respond_to?(:call) && @on_shutdown.call(worker, job, queue)
      end

      def skip_shutdown?(worker, job, queue)
        @skip_shutdown.respond_to?(:call) && @skip_shutdown.call(worker, job, queue)
      end

      def request_shutdown
        Thread.new do
          next unless MUTEX.try_lock

          begin
            shutdown
          ensure
            MUTEX.unlock if MUTEX.locked?
          end
        end
      end

      def shutdown
        warn "sending quiet to #{identity}"
        sidekiq_process.quiet!

        sleep(5)

        warn "shutting down #{identity} in #{@grace_time} seconds"
        wait_job_finish_in_grace_time

        warn "stopping #{identity}"
        sidekiq_process.stop!

        warn "waiting #{@shutdown_wait} seconds before sending #{@kill_signal} to #{identity}"
        sleep(@shutdown_wait)

        warn "sending #{@kill_signal} to #{identity}"
        ::Process.kill(@kill_signal, ::Process.pid)
      end

      def wait_job_finish_in_grace_time
        start = Time.now
        sleep(1) until grace_time_exceeded?(start) || jobs_finished?
      end

      def grace_time_exceeded?(start)
        return false if @grace_time == Float::INFINITY

        start + @grace_time < Time.now
      end

      def jobs_finished?
        sidekiq_process.stopping? && sidekiq_process["busy"] == 0
      end

      def current_rss
        ::GetProcessMem.new.mb
      end

      def sidekiq_process
        Sidekiq::ProcessSet.new.find do |process|
          process["identity"] == identity
        end || Sidekiq::ProcessSet.new.find do |process|
          process["pid"].to_i == ::Process.pid
        end || raise("No sidekiq worker with identity #{identity} found")
      end

      def identity
        if respond_to?(:config) && config
          config[:identity] || config["identity"]
        else
          Sidekiq.default_configuration[:identity] || Sidekiq.default_configuration["identity"]
        end
      end

      def warn(msg)
        Sidekiq.logger.warn(msg)
      end

      def self.truthy?(value)
        return value if value == true || value == false

        !%w[0 false no off].include?(value.to_s.strip.downcase)
      end

      def self.install_log(options)
        "[sidekiq-mem-warden] installed limit=#{options[:max_rss]}MB " \
          "grace=#{options[:grace_time]}s " \
          "shutdown_wait=#{options[:shutdown_wait]}s " \
          "kill_signal=#{options[:kill_signal]} " \
          "gc=#{options[:gc]}"
      end
    end
  end
end
