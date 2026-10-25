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

  it 'renders no vhost for catalog entries whose DNS points elsewhere (caddy_vhost: false)' do
    is_expected.not_to contain_file('/etc/caddy/conf.d.openvox-staging/dns-elsewhere.caddy')
    is_expected.to contain_file('/etc/caddy/conf.d.openvox-staging/remote-https.caddy')
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
        provider: 'shell',
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

    it 'skips the install only when the pinned checksum and SELinux type already match' do
      guard = catalogue.resource('exec', 'caddy-custom-binary')[:unless]
      expect(guard).to include(sha)
      expect(guard).to include('httpd_exec_t')
      expect(guard).not_to include('custom-binary-check.sh')
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

  context 'AppSec' do
    let(:sha) { 'ebd5a88596a13c4aa6148e679fa08e1814789131e0349a53631219884b0431c9' }
    let(:custom) { { 'tag' => 'caddy-v2.11.7-crowdsec-v0.14.1-b38ae651', 'sha256' => sha } }

    context 'disabled (the default)' do
      it 'renders no AppSec config even for catalog entries that opt in' do
        expect(catalogue.resource('file', '/etc/caddy/Caddyfile.openvox-staging')[:content]).not_to include('crowdsec')
        snippet = catalogue.resource('file', '/etc/caddy/conf.d.openvox-staging/appsec-log.caddy')[:content]
        expect(snippet).not_to include('route {')
        expect(snippet).not_to include('X-Appsec-Mode')
        is_expected.not_to contain_file('/etc/caddy/crowdsec.env')
      end
    end

    context 'enabled without a custom build' do
      let(:params) { { appsec_enabled: true } }

      it { is_expected.to compile.and_raise_error(%r{needs roles::caddy::custom_build}) }
    end

    context 'enabled with a custom build' do
      let(:params) { { custom_build: custom, appsec_enabled: true } }

      it { is_expected.to compile.with_all_deps }

      it 'keeps the bouncer key out of the Caddyfile and in a root:caddy 0640 env file' do
        is_expected.to contain_file('/etc/caddy/crowdsec.env').with(
          owner: 'root',
          group: 'caddy',
          mode: '0640',
          show_diff: false,
          notify: 'Exec[caddy-restart-on-override]',
        )
        is_expected.to contain_file('/etc/systemd/system/caddy.service.d/override.conf')
          .with_content(%r{^EnvironmentFile=/etc/caddy/crowdsec\.env$})
        caddyfile = catalogue.resource('file', '/etc/caddy/Caddyfile.openvox-staging')[:content]
        expect(caddyfile).to include('api_key {env.CROWDSEC_BOUNCER_KEY}')
        expect(caddyfile).to include('appsec_url http://127.0.0.1:7422', 'appsec_fail_open', 'appsec_timeout 2s')
      end

      it 'opts vhosts in per catalog entry and fixes the mode server-side' do
        log = catalogue.resource('file', '/etc/caddy/conf.d.openvox-staging/appsec-log.caddy')[:content]
        expect(log).to include("    request_header -X-Appsec-Mode\n    route {\n        appsec\n    }")
        expect(log).not_to include('X-Appsec-Mode block')

        blk = catalogue.resource('file', '/etc/caddy/conf.d.openvox-staging/appsec-block.caddy')[:content]
        expect(blk).to include('request_header X-Appsec-Mode block')
        expect(blk).to include('@appsec_inspect not path /upload/* /dav/*', 'route @appsec_inspect {')

        other = catalogue.resource('file', '/etc/caddy/conf.d.openvox-staging/remote-https.caddy')[:content]
        expect(other).not_to include('route {')
      end
    end
  end
end
