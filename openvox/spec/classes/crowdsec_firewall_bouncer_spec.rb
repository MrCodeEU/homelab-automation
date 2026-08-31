require 'spec_helper'

describe 'roles::crowdsec_firewall_bouncer' do
  it { is_expected.to compile.with_all_deps }

  it 'uses the signed CrowdSec repository and installs the nftables bouncer' do
    is_expected.to contain_yumrepo('crowdsec_crowdsec').with(
      baseurl: 'https://packagecloud.io/crowdsec/crowdsec/rpm_any/rpm_any/$basearch',
      repo_gpgcheck: 1,
      gpgcheck: 1,
      sslverify: 1,
    )
    is_expected.to contain_package('crowdsec-firewall-bouncer-nftables').with(
      ensure: 'installed',
      require: 'Yumrepo[crowdsec_crowdsec]',
    )
  end

  it 'protects the local LAPI credential and configures nftables enforcement' do
    config = catalogue.resource('file', '/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml')
    manifest = File.read(File.expand_path('../../modules/roles/manifests/crowdsec_firewall_bouncer.pp', __dir__))

    expect(config[:mode]).to eq('0600')
    expect(manifest).to match(/content\s*=>\s*Sensitive\(/)
    expect(config[:content]).to include(
      'api_url: http://127.0.0.1:8088/',
      'api_key: ',
      'mode: nftables',
      'deny_action: DROP',
      "ipv4:\n    enabled: true",
      "ipv6:\n    enabled: true",
    )
  end

  it 'waits for the local LAPI before starting and verifies active enforcement' do
    is_expected.to contain_exec('crowdsec-firewall-bouncer-wait-lapi').with(
      command: %r{wait-lapi\.sh},
      require: 'File[/usr/local/libexec/openvox-crowdsec-firewall-bouncer]',
    )
    service_requirements = catalogue.resource('service', 'crowdsec-firewall-bouncer')[:require].map(&:ref)
    expect(service_requirements).to include(
      'Exec[crowdsec-firewall-bouncer-wait-lapi]',
      'Package[crowdsec-firewall-bouncer-nftables]',
    )
    is_expected.to contain_service('crowdsec-firewall-bouncer').with(
      ensure: 'running',
      enable: true,
      subscribe: 'File[/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml]',
    )
    is_expected.to contain_exec('crowdsec-firewall-bouncer-verify-active').with(
      command: %r{verify-active\.sh},
      require: 'Service[crowdsec-firewall-bouncer]',
    )
  end
end
