# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'elasticsearch_s3_backup/version'

Gem::Specification.new do |spec|
  spec.name          = 'elasticsearch_s3_backup'
  spec.version       = EverTools::ElasticsearchS3Backup::VERSION
  spec.authors       = ['Eric Herot']
  spec.email         = ['eric.github@herot.com']

  spec.summary       = 'Backs up ElasticSearch to S3'
  spec.description   = spec.description
  spec.homepage      = 'https://nerds.evertrue.com'
  spec.license       = 'MIT'

  # Prevent pushing this gem to RubyGems.org by setting 'allowed_push_host', or
  # delete this section to allow pushing this gem to any host.
  if spec.respond_to?(:metadata)
    spec.metadata['allowed_push_host'] = 'https://rubygems.org'
  else
    fail 'RubyGems 2.0 or newer is required to protect against public gem ' \
         'pushes.'
  end

  spec.files = `git ls-files -z`.split("\x0").reject do |f|
    f.match(%r{^(test|spec|features)/})
  end

  spec.bindir        = 'exe'
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  spec.add_development_dependency 'bundler', '~> 1.10'
  spec.add_development_dependency 'rake', '~> 10.0'
  spec.add_development_dependency 'rspec'

  spec.add_dependency 'activesupport'
  spec.add_dependency 'unirest'
  spec.add_dependency 'faker'
  spec.add_dependency 'pagerduty'
  spec.add_dependency 'sentry-raven'
  spec.add_dependency 'elasticsearch'
  spec.add_dependency 'hashie'
end
