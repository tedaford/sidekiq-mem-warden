# Changelog

## 0.1.0
- Initial release with RSS-based watchdog, quiet, drain, and restart behavior.

## 0.1.1
- Default memory limit set to 4.5 GB (4608 MB).

## 0.1.2
- Default memory limit set to 1 GB (1024 MB).
- Default grace time set to 5 minutes (300 seconds).

## 0.1.3
- Replaced the internal watchdog with Sidekiq server middleware based on sidekiq-worker-killer.
