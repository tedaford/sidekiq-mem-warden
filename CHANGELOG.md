# Changelog

## 0.1.7
- Added `Sidekiq::Mem::Warden.install!` and `options_from_env` to provide one canonical middleware install path.
- Default memory limit increased to 8 GB (`8192 MB`).
- Hardened shutdown locking so sequential shutdown requests continue to work.

## 0.1.0
- Initial release with RSS-based watchdog, quiet, drain, and restart behavior.

## 0.1.1
- Default memory limit set to 4.5 GB (4608 MB).

## 0.1.2
- Default memory limit set to 1 GB (1024 MB).
- Default grace time set to 5 minutes (300 seconds).

## 0.1.3
- Replaced the internal watchdog with Sidekiq server middleware based on sidekiq-worker-killer.

## 0.1.4
- Fix lockfile

## 0.1.5
- Increase default timeout to 2500 seconds

## 0.1.6
- Increase default memory limit to 2 GB
