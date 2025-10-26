#!/bin/bash
set -eo pipefail -o nounset

# In conjunction with set -o nounset, the lines below will throw an exception if the
# variables aren't set in the calling environment prior to the script running
: ${CI_BUILD_NUMBER}      # sourced from "${bamboo.buildNumber}"
: ${CI_BRANCH_NAME}       # sourced from "${bamboo.planRepository.branchName}"
: ${ARTIFACTORY_USERNAME} # sourced from "${bamboo.artifactory.user}"
: ${ARTIFACTORY_PASSWORD} # sourced from "${bamboo.artifactory.password}"

ruby_version="$(cut -f2 -d'-' .ruby-version)"

# run the ci build/tests
docker run -i --rm -v $(pwd):/opt/opschain -w /opt/opschain -e BUNDLE_PATH=.bundle/path -e BUNDLE_JOBS=20 -e BUNDLE_ARTIFACTORY__LIMEPOINT__ENGINEERING="${ARTIFACTORY_USERNAME}:${ARTIFACTORY_PASSWORD}" ruby:${ruby_version} sh -c 'bundle install && bundle exec rspec'

# update gem version
git reset --hard # to keep gem-release happy - there are some diff-index issues in the shebang script

run_docker="docker run -i --rm -v $(pwd):/opt/opschain -w /opt/opschain -e BUNDLE_PATH=.bundle/path -e BUNDLE_JOBS=20 ruby:${ruby_version}"

# Generate version in format: major_version.yymmdd.hhMMss
# Example: 400.251024.102030 for October 24, 2025 at 10:20:30
version_file_path="lib/pond"
major_version="$(${run_docker} ruby -I ${version_file_path} -r version -e 'puts Pond::VERSION')"
new_version="${major_version}.$(date +%y%m%d.%H%M%S)"

if [ "${CI_BRANCH_NAME}" != "OpsChain_Rel_4.0.0" ]; then
  branch_name="${CI_BRANCH_NAME}"
  # For non-release branches, append branch name as prerelease identifier
  # Example: 400.251024.102030-feature
  new_version="${new_version}-${branch_name//[^a-zA-Z0-9]/}"
fi

${run_docker} sh -ec "git config --global --add safe.directory /opt/opschain && gem install gem-release && gem bump --file ${version_file_path}/version.rb -v ${new_version} --no-commit && bundle exec rake build"
