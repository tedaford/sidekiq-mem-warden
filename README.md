# Sidekiq::Mem::Warden

Sidekiq::Mem::Warden is a tiny, in-process watchdog that quiets a Sidekiq process when RSS exceeds a limit, waits for busy jobs to drain, then exits so your process manager can restart it.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'sidekiq-mem-warden'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install sidekiq-mem-warden

## Usage

Configure it in your Sidekiq server process:

```ruby
require "sidekiq/mem/warden"

Sidekiq.configure_server do |config|
  Sidekiq::Mem::Warden.configure do |c|
    c.memory_limit_mb = 1024
    c.check_interval = 15
    c.quiet_timeout = 30
    c.shutdown_timeout = 300
  end

  Sidekiq::Mem::Warden.install!(config)
end
```

Operational notes:

- The warden runs inside each Sidekiq process.
- When memory exceeds the limit, it sends `TSTP` to quiet the process, sleeps for `quiet_timeout`, waits for `Sidekiq::Workers` to drain, then sends `TERM` to exit.
- Ensure your supervisor (systemd, Kubernetes, etc.) is set to restart the process.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/tedaford/sidekiq-mem-warden.

## License

The gem is available as open source under the terms of the GNU General Public License v2.0.
