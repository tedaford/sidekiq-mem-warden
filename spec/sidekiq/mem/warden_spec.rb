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
end
