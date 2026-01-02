require "logger"

RSpec.describe Sidekiq::Mem::Warden do
  it "has a version number" do
    expect(Sidekiq::Mem::Warden::VERSION).not_to be nil
  end

  it "exposes configurable defaults" do
    config = described_class.config
    expect(config.memory_limit_mb).to be > 0
    expect(config.check_interval).to be > 0
    expect(config.quiet_timeout).to be >= 0
    expect(config.shutdown_timeout).to be > 0
  end

  it "allows configuration overrides" do
    described_class.configure do |c|
      c.memory_limit_mb = 2048
      c.check_interval = 10
    end

    config = described_class.config
    expect(config.memory_limit_mb).to eq(2048)
    expect(config.check_interval).to eq(10)
  end

  it "installs on sidekiq startup" do
    monitor = instance_double(Sidekiq::Mem::Warden::Monitor, start: true)
    allow(described_class::Monitor).to receive(:new).and_return(monitor)
    allow(described_class).to receive(:start_monitor)

    startup_block = nil
    sidekiq_config = double("SidekiqConfig")
    allow(sidekiq_config).to receive(:on) do |event, &block|
      expect(event).to eq(:startup)
      startup_block = block
    end

    described_class.install!(sidekiq_config)
    expect(startup_block).not_to be_nil
    startup_block.call

    expect(described_class).to have_received(:start_monitor).with(monitor)
  end

  it "prevents multiple monitor starts at the class level" do
    described_class.instance_variable_set(:@started, false)
    described_class.instance_variable_set(:@start_mutex, Mutex.new)

    monitor = instance_double(Sidekiq::Mem::Warden::Monitor, start: true)
    described_class.start_monitor(monitor)
    described_class.start_monitor(monitor)

    expect(monitor).to have_received(:start).once
  end

  describe Sidekiq::Mem::Warden::Monitor do
    let(:config) do
      c = Sidekiq::Mem::Warden::Config.new
      c.memory_limit_mb = 100
      c.check_interval = 1
      c.quiet_timeout = 0
      c.shutdown_timeout = 2
      c.logger = logger
      c
    end
    let(:logger) { instance_double(Logger, warn: nil) }

    before do
      allow(Sidekiq).to receive(:logger).and_return(logger)
      stub_const("Sidekiq::Workers", Class.new)
    end

    it "starts only once per monitor instance" do
      monitor = described_class.new(config)
      allow(Thread).to receive(:new).and_return(double("thread"))

      monitor.start
      monitor.start

      expect(Thread).to have_received(:new).once
    end

    it "triggers quiet and shutdown when over the limit" do
      monitor = described_class.new(config)
      allow(monitor).to receive(:rss_mb).and_return(150)
      allow(Sidekiq::Workers).to receive(:new).and_return(double(size: 0))
      allow(monitor).to receive(:sleep)
      allow(Process).to receive(:kill)

      monitor.send(:trigger!)

      expect(Process).to have_received(:kill).with("TSTP", Process.pid)
      expect(Process).to have_received(:kill).with("TERM", Process.pid)
    end

    it "sleeps for quiet_timeout before draining" do
      config.quiet_timeout = 5
      monitor = described_class.new(config)
      allow(Sidekiq::Workers).to receive(:new).and_return(double(size: 0))
      allow(monitor).to receive(:sleep)
      allow(monitor).to receive(:wait_for_idle)
      allow(Process).to receive(:kill)

      monitor.send(:trigger!)

      expect(monitor).to have_received(:sleep).with(5)
      expect(monitor).to have_received(:wait_for_idle).with(2)
    end

    it "only triggers once per monitor instance" do
      monitor = described_class.new(config)
      allow(Sidekiq::Workers).to receive(:new).and_return(double(size: 0))
      allow(monitor).to receive(:sleep)
      allow(Process).to receive(:kill)

      monitor.send(:trigger!)
      monitor.send(:trigger!)

      expect(Process).to have_received(:kill).with("TSTP", Process.pid).once
      expect(Process).to have_received(:kill).with("TERM", Process.pid).once
    end

    it "logs when quiet signal fails" do
      monitor = described_class.new(config)
      allow(Sidekiq::Workers).to receive(:new).and_return(double(size: 0))
      allow(monitor).to receive(:sleep)
      allow(Process).to receive(:kill).and_raise(StandardError.new("boom"))

      monitor.send(:trigger!)

      expect(logger).to have_received(:warn).with(/failed to send TSTP/)
      expect(logger).to have_received(:warn).with(/failed to send TERM/)
    end

    it "waits for workers to drain" do
      monitor = described_class.new(config)
      workers = double
      allow(workers).to receive(:size).and_return(2, 1, 0)
      allow(Sidekiq::Workers).to receive(:new).and_return(workers)
      allow(monitor).to receive(:sleep)

      monitor.send(:wait_for_idle, 5)

      expect(logger).not_to have_received(:warn)
    end

    it "warns on drain timeout" do
      monitor = described_class.new(config)
      allow(Sidekiq::Workers).to receive(:new).and_return(double(size: 1))
      allow(monitor).to receive(:sleep)

      monitor.send(:wait_for_idle, 0)

      expect(logger).to have_received(:warn).with(/timeout waiting for busy to drain/)
    end

    it "detects over_limit? based on rss_mb" do
      monitor = described_class.new(config)
      allow(monitor).to receive(:rss_mb).and_return(101)

      expect(monitor.send(:over_limit?)).to eq(true)
    end

    it "reads rss from /proc when available" do
      monitor = described_class.new(config)
      allow(File).to receive(:exist?).and_return(true)
      allow(File).to receive(:read).and_return("VmRSS:\t12345 kB\n")

      expect(monitor.send(:rss_kb)).to eq(12345)
    end

    it "falls back to ps when /proc is unavailable" do
      monitor = described_class.new(config)
      allow(File).to receive(:exist?).and_return(false)
      allow(monitor).to receive(:`).and_return("4321\n")

      expect(monitor.send(:rss_kb)).to eq(4321)
    end

    it "returns zero on rss read failure" do
      monitor = described_class.new(config)
      allow(File).to receive(:exist?).and_return(false)
      allow(monitor).to receive(:`).and_raise(StandardError)

      expect(monitor.send(:rss_kb)).to eq(0)
    end

    it "converts rss to megabytes" do
      monitor = described_class.new(config)
      allow(monitor).to receive(:rss_kb).and_return(2048)

      expect(monitor.send(:rss_mb)).to eq(2.0)
    end
  end
end
