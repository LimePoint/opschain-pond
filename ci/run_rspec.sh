#!/bin/bash
set -eo pipefail

git config --global --add safe.directory /opt/opschain

bundle install
bundle exec rspec
