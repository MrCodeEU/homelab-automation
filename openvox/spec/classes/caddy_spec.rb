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

  context 'without a custom build (the default)' do
    it 'runs the packaged binary and removes any leftover custom one' do
      is_expected.not_to contain_exec('caddy-custom-binary')
      is_expected.to contain_file('/usr/local/bin/caddy-crowdsec').with(
        ensure: 'absent',
        notify: 'Exec[caddy-restart-on-override]',
      )
      is_expected.to contain_file('/etc/systemd/system/caddy.service.d/override.conf')
        .without_content(%r{ExecStart=})
      is_expected.to contain_exec('caddy-validate').with(
        environment: ['CADDY_BIN=/usr/bin/caddy'],
      )
    end
  end

  context 'with a custom build pinned in hiera' do
    let(:sha) { 'ebd5a88596a13c4aa6148e679fa08e1814789131e0349a53631219884b0431c9' }
    let(:params) { { custom_build: { 'tag' => 'caddy-v2.11.7-crowdsec-v0.14.1-b38ae651', 'sha256' => sha } } }

    it { is_expected.to compile.with_all_deps }

    it 'installs the pinned release before the unit override and restarts Caddy' do
      is_expected.to contain_exec('caddy-custom-binary').with(
        command: '/usr/local/libexec/openvox-caddy/custom-binary-apply.sh',
        unless: '/usr/local/libexec/openvox-caddy/custom-binary-check.sh',
        before: 'File[/etc/systemd/system/caddy.service.d/override.conf]',
        notify: 'Exec[caddy-restart-on-override]',
        environment: [
          'CADDY_CUSTOM_BIN=/usr/local/bin/caddy-crowdsec',
          'CADDY_CUSTOM_TAG=caddy-v2.11.7-crowdsec-v0.14.1-b38ae651',
          "CADDY_CUSTOM_SHA256=#{sha}",
        ],
      )
      is_expected.not_to contain_file('/usr/local/bin/caddy-crowdsec')
    end

    it 'points ExecStart and ExecReload at the custom binary and validates with it' do
      is_expected.to contain_file('/etc/systemd/system/caddy.service.d/override.conf')
        .with_content(%r{^ExecStart=$})
        .with_content(%r{^ExecStart=/usr/local/bin/caddy-crowdsec run --environ --config /etc/caddy/Caddyfile$})
        .with_content(%r{^ExecReload=/usr/local/bin/caddy-crowdsec reload --config /etc/caddy/Caddyfile --force$})
      is_expected.to contain_exec('caddy-validate').with(
        environment: ['CADDY_BIN=/usr/local/bin/caddy-crowdsec'],
      )
    end

    context 'with a malformed checksum' do
      let(:params) { { custom_build: { 'tag' => 'x', 'sha256' => 'abc' } } }

      it { is_expected.to compile.and_raise_error(%r{custom_build}) }
    end
  end
end
