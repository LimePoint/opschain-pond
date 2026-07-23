# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

`opschain-pond` is LimePoint's fork of Chris Hanks' [pond](https://github.com/chanks/pond)
gem: a thread-safe, generic object pool (usually wrapping connections). The gem name is
`opschain-pond` but the Ruby class is still `Pond`. The fork's defining addition over
upstream is idle-timeout eviction (a background thread that closes idle pooled objects) plus
a `healthy_if` check performed before an object is handed to a caller.

The entire implementation lives in a single file: `lib/pond.rb`.

## Commands

```bash
bundle install
bundle exec rspec                       # run all specs
bundle exec rspec spec/checkout_spec.rb # run one spec file
bundle exec rspec spec/checkout_spec.rb:42   # run the example at a line
bundle exec rake                        # default task == full rspec suite
bundle exec rake build                  # build the gem into pkg/
bundle exec rake stress                 # concurrency stress test (see tasks/stress.rake)
```

Ruby version is pinned in `.ruby-version` (currently 3.4.6). Specs run in random order
(`.rspec`) and use both `expect` and legacy `should` syntax (`spec/spec_helper.rb`).

## Architecture

`Pond` is built around a `Monitor` + `ConditionVariable`. Two data structures hold the pool:

- `@available` — an array of instantiated-but-idle objects.
- `@allocated` — a nested hash `{ scope => { Thread => object } }` tracking objects currently
  checked out. The outer key is the **scope** (default `nil`), which lets the same thread
  hold independent checkouts under different frozen scope keys (`checkout(scope: ...)`).

Key design invariants to preserve when editing:

- **Lazy instantiation happens outside the monitor.** The user's instantiation `@block` is
  potentially slow, so `lock_object` never calls it while holding the lock. Instead, when a
  new object is needed it sets the checked-out slot to `@block` itself as a sentinel, releases
  the lock, then calls `@block.call`. Any change touching checkout must keep the block call
  off the critical section. `size` counts `@block` sentinels as real objects so the pool never
  over-allocates.
- **`size` must always be accurate.** All mutations of `@available`/`@allocated` are wrapped in
  `sync {}` precisely so `size` (used to enforce `maximum_size`) stays correct under concurrency.
- **`healthy_if` and `detach_if` callables run outside the monitor.** Both are user-supplied and
  may be slow or call `#finish`; running them under the lock would block other threads. An
  unhealthy object is dropped (and `#finish`ed) in `discard_current_object_unless_healthy`, and
  the `lock_object` loop obtains/instantiates another.
- **Idle eviction.** `monitor_connections` runs in a dedicated background thread started in
  `initialize`, waking every second to evict objects idle longer than `idle_timeout` (default
  120s) and calling `#finish` on them. `@last_used` records return timestamps. Note the historical
  bug (see CHANGELOG): eviction must key off `idle_timeout`, not `timeout` (the checkout-wait).

`Pond.wrap` returns a `Wrapper < BasicObject` that forwards every method through
`checkout`, so callers can use the pooled object transparently.

## CI

CI is Bamboo-driven via the `ci/` scripts, which run inside a `ruby:<version>` Docker container:

- `ci/run_ci_tests.sh` — entry point; runs rspec then build/release in containers. Requires env
  vars `CI_BUILD_NUMBER`, `CI_BRANCH_NAME`, `ARTIFACTORY_USERNAME`, `ARTIFACTORY_PASSWORD`.
- `ci/run_rspec.sh` — `bundle install && bundle exec rspec`.
- `ci/run_build_and_release.sh` — bumps the version (appending a prerelease suffix derived from
  the build number / branch name for non-`master` branches) via `gem-release`, then `rake build`.

Version lives in `lib/pond/version.rb`.
