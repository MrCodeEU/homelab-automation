require 'rspec-puppet'

RSpec.configure do |config|
  config.module_path = [
    File.expand_path('../modules', __dir__),
    File.expand_path('fixtures/modules', __dir__),
  ].reject(&:empty?).join(File::PATH_SEPARATOR)
  # Unit tests provide their own facts and intentionally never decrypt or
  # consume the production eyaml hierarchy.
  config.hiera_config = '/dev/null'
  config.default_facts = {
    networking: { hostname: 'spec-host', ip: '127.0.0.1' },
    openvox_recovery_services: '',
  }
end
