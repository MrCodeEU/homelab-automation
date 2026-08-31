require 'spec_helper'

describe 'roles::caddy' do
  let(:hiera_config) { File.expand_path('../fixtures/hiera.yaml', __dir__) }

  # The profile includes roles::base, which owns this prerequisite in
  # production. Keep this unit spec focused on the Caddy role's catalog.
  let(:pre_condition) { 'service { "firewalld": ensure => running }' }

  it { is_expected.to compile.with_all_deps }

  it 'opens the complete public HTTP/HTTPS/HTTP3 firewall surface' do
    is_expected.to contain_roles__firewalld__service('caddy-http').with(
      ensure: 'present',
      zone: 'public',
      service: 'http',
    )
    is_expected.to contain_roles__firewalld__service('caddy-https').with(
      ensure: 'present',
      zone: 'public',
      service: 'https',
    )
    is_expected.to contain_roles__firewalld__port('caddy-http3').with(
      ensure: 'present',
      zone: 'public',
      port: 443,
      protocol: 'udp',
    )
  end

  it 'keeps generated snippets in an isolated, reconciled directory' do
    is_expected.to contain_file('/etc/caddy/conf.d.openvox-staging').with(
      ensure: 'directory',
      mode: '0755',
      recurse: true,
      purge: true,
      require: 'Exec[caddy-dirs]',
    )
  end

  it 'reloads systemd only after a service override changes' do
    is_expected.to contain_file('/etc/systemd/system/caddy.service.d/override.conf').with(
      notify: 'Exec[caddy-restart-on-override]',
    )
    is_expected.to contain_exec('caddy-restart-on-override').with(
      refreshonly: true,
      require: 'Exec[caddy-dirs]',
    )
  end

  it 'validates staged configuration before promotion and service reconciliation' do
    validation_requirements = catalogue.resource('exec', 'caddy-validate')[:require].map(&:ref)
    expect(validation_requirements).to include(
      'File[/etc/caddy/conf.d.openvox-staging]',
      'File[/etc/caddy/conf.d.openvox-staging/000-snippets.caddy]',
      'File[/etc/caddy/Caddyfile.openvox-staging]',
      'Exec[caddy-restart-on-override]',
    )
    is_expected.to contain_exec('caddy-promote').with(
      require: 'Exec[caddy-validate]',
    )
    is_expected.to contain_exec('caddy-service').with(
      require: 'Exec[caddy-promote]',
    )
    is_expected.to contain_exec('caddy-healthcheck').with(
      require: 'Exec[caddy-service]',
    )
  end
end
