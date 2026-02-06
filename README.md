# Sidekiq::Mem::Warden

Sidekiq::Mem::Warden is a tiny Sidekiq server middleware that watches RSS and shuts down bloated processes after a grace period, allowing your process manager to restart them.

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
  Sidekiq::Mem::Warden.install!(config)
end
```

By default this uses:

- `max_rss`: `8192` MB (8 GB)
- `grace_time`: `300` seconds
- `shutdown_wait`: `30` seconds
- `kill_signal`: `SIGKILL`
- `gc`: `true`

You can override these defaults with environment variables:

- `SIDEKIQ_MEM_WARDEN_LIMIT_MB`
- `SIDEKIQ_MEM_WARDEN_GRACE_TIME`
- `SIDEKIQ_MEM_WARDEN_SHUTDOWN_WAIT`
- `SIDEKIQ_MEM_WARDEN_KILL_SIGNAL`
- `SIDEKIQ_MEM_WARDEN_GC`

Or pass explicit overrides:

```ruby
Sidekiq.configure_server do |config|
  Sidekiq::Mem::Warden.install!(config, max_rss: 12_288, grace_time: 900)
end
```

Operational notes:

- The warden runs inside each Sidekiq process.
- When RSS exceeds `max_rss`, it quiets the process, waits for jobs to finish up to `grace_time`, then stops and sends `kill_signal`.
- Ensure your supervisor (systemd, Kubernetes, etc.) is set to restart the process.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/tedaford/sidekiq-mem-warden.

## Credits

This gem is heavily based on the archived MIT-licensed `sidekiq-worker-killer` project.

## License

The gem is available as open source under the terms of the GNU General Public License v2.0.
