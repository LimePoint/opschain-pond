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
version_file_path="lib/pond"
current_version="$(${run_docker} ruby -I ${version_file_path} -r version -e 'puts Pond::VERSION')"
prerelease_version=".${CI_BUILD_NUMBER}"

if [ "${CI_BRANCH_NAME}" != master ]; then
  branch="${CI_BRANCH_NAME}"
  prerelease_version="-${branch//[^a-zA-Z0-9]/}${prerelease_version}" # replace the branch to match https://github.com/rubygems/rubygems/blob/a9b3694abd272ecba32e0d9698496b7e7ea834c4/lib/rubygems/version.rb#L157 (the prerelease bit) - we could allow `-` if we wanted but it splits the prerelease bit with dots then
fi

${run_docker} sh -ec "git config --global --add safe.directory /opt/opschain && gem install gem-release && gem bump --file ${version_file_path}/version.rb -v ${current_version}${prerelease_version} --no-commit && bundle exec rake build"
