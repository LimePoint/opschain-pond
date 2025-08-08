# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'pond/version'

Gem::Specification.new do |spec|
  spec.name          = 'opschain-pond'
  spec.version       = Pond::VERSION
  spec.authors       = ['LimePoint Pty Ltd']
  spec.email         = ['support@limepoint.com']

  spec.description   = %q{Based on Chris Hanks (https://github.com/chanks/pond) connection pool Gem, with the inclusion of an idle timeout feature.}
  spec.summary       = %q{A simple, generic, thread-safe pool with idle timeout.}
  spec.homepage      = 'https://github.com/limepoint/opschain-pond'
  spec.license       = 'LimePoint End User Licence Agreement (EULA). Proprietary.'

  spec.files         = `git ls-files`.split($/)
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ['lib']

  spec.add_development_dependency 'bundler', '>= 1.3'
  spec.add_development_dependency 'rspec',   '>= 2.14'
  spec.add_development_dependency 'rake'
end
