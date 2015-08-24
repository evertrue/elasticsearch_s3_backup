$LOAD_PATH.unshift File.expand_path('../../lib', __FILE__)
require 'elasticsearch_s3_backup'

RSpec.configure do |config|
  config.formatter = :documentation
  config.color = true
end
