require 'spec_helper'

describe 'roles::container_reconcile' do
  context 'with the current expected standalone container' do
    it { is_expected.to compile.with_all_deps }
    it { is_expected.not_to contain_exec('container-reconcile-rm-grafana-alloy') }
  end

  context 'when Grafana Alloy is no longer expected' do
    let(:params) { { expected: [] } }

    it 'only removes its known container after a read-only existence check' do
      is_expected.to contain_exec('container-reconcile-rm-grafana-alloy').with(
        command: '/usr/bin/docker rm -f grafana-alloy',
        onlyif: '/usr/bin/docker inspect grafana-alloy',
      )
      is_expected.to contain_file('/opt/grafana-alloy').with(
        ensure: 'absent', force: true,
        require: 'Exec[container-reconcile-rm-grafana-alloy]',
      )
    end
  end
end

describe 'roles::hawser_agent' do
  let(:params) { { tailscale_ip: '100.64.0.10' } }
  let(:pre_condition) { 'service { "firewalld": ensure => running }' }

  it { is_expected.to compile.with_all_deps }

  it 'binds the management agent only to Tailscale and the trusted zone' do
    is_expected.to contain_file('/etc/systemd/system/hawser.service.d/override.conf').with(
      content: %r{HAWSER_BIND_ADDRESS=100\.64\.0\.10},
    )
    is_expected.to contain_roles__firewalld__port('hawser-agent-tcp').with(
      zone: 'trusted', port: 2376, protocol: 'tcp',
    )
    is_expected.to contain_exec('hawser-agent-daemon-reload').with(refreshonly: true)
  end
end

describe 'roles::hetrixtools_agent' do
  it { is_expected.to compile.with_all_deps }

  it 'does not expose the installer command in successful apply logs' do
    is_expected.to contain_exec('hetrixtools-agent-install').with(
      creates: '/etc/hetrixtools/hetrixtools_agent.sh',
      logoutput: 'on_failure',
    )
    is_expected.to contain_exec('hetrixtools-agent-verify-cron').with(
      require: 'Exec[hetrixtools-agent-install]',
    )
  end
end

describe 'roles::homepage_data_sync' do
  it { is_expected.to compile.with_all_deps }

  it 'runs an initial data sync only after its timer is reconciled' do
    is_expected.to contain_exec('homepage-data-sync-daemon-reload').with(refreshonly: true)
    is_expected.to contain_service('homepage-data-sync.timer').with(
      ensure: 'running', enable: true,
      require: 'Exec[homepage-data-sync-daemon-reload]',
    )
    is_expected.to contain_exec('homepage-data-sync-initial-run').with(
      refreshonly: true,
      require: 'Service[homepage-data-sync.timer]',
    )
  end
end

describe 'roles::iperf3' do
  let(:pre_condition) { 'service { "firewalld": ensure => running }' }

  it { is_expected.to compile.with_all_deps }

  it 'uses host networking but restricts both benchmark protocols to trusted' do
    is_expected.to contain_file('/opt/iperf3/docker-compose.yml').with(content: %r{network_mode: host})
    %w[tcp udp].each do |protocol|
      is_expected.to contain_roles__firewalld__port("iperf3-#{protocol}").with(
        zone: 'trusted', port: 5201, protocol: protocol,
      )
    end
    is_expected.to contain_docker_compose('iperf3').with(
      subscribe: 'File[/opt/iperf3/docker-compose.yml]',
    )
  end

  context 'on Ugreen' do
    let(:params) { { manage_firewall: false } }

    it 'does not attempt to manage Rocky-specific firewalld resources' do
      is_expected.not_to contain_roles__firewalld__port('iperf3-tcp')
      is_expected.not_to contain_roles__firewalld__port('iperf3-udp')
    end
  end
end

describe 'roles::netronome_agent' do
  let(:params) { { interface: 'eth0' } }
  let(:pre_condition) { 'service { "firewalld": ensure => running }' }

  it { is_expected.to compile.with_all_deps }

  it 'shares Tailscale read-only and persists vnStat state separately' do
    compose = catalogue.resource('file', '/opt/netronome-agent/docker-compose.yml')[:content]
    expect(compose).to include(
      '/var/run/tailscale:/var/run/tailscale:ro',
      '/opt/netronome-agent/vnstat-db:/var/lib/vnstat:ro',
      'NETRONOME__AGENT_INTERFACE: eth0',
    )
    is_expected.to contain_roles__firewalld__port('netronome-agent-tcp').with(
      zone: 'trusted', port: 8200, protocol: 'tcp',
    )
    is_expected.to contain_docker_compose('netronome-agent').with(
      subscribe: 'File[/opt/netronome-agent/docker-compose.yml]',
    )
  end
end

describe 'roles::ugreen_tailscale' do
  it { is_expected.to compile.with_all_deps }

  it 'updates only Tailscale and reports its version after the package' do
    is_expected.to contain_package('tailscale').with(
      ensure: 'latest', require: 'Class[Apt::Update]',
    )
    is_expected.to contain_exec('ugreen-tailscale-version').with(
      command: '/usr/bin/tailscale version',
      require: 'Package[tailscale]',
    )
  end
end
