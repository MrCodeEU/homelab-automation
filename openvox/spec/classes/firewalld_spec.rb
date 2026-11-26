require 'spec_helper'

describe 'roles::firewalld' do
  it { is_expected.to compile.with_all_deps }

  it do
    is_expected.to contain_file('/usr/local/libexec/openvox-firewalld').with(
      ensure: 'directory',
      mode: '0755',
    )
  end

  [
    'zone-sources-check.sh',
    'zone-sources-apply.sh',
  ].each do |script|
    it do
      is_expected.to contain_file("/usr/local/libexec/openvox-firewalld/#{script}").with(
        ensure: 'file',
        mode: '0755',
        require: 'File[/usr/local/libexec/openvox-firewalld]',
      )
    end
  end

  it do
    is_expected.to contain_service('firewalld').with(
      ensure: 'running',
      enable: true,
    )
  end

  it 'leaves StrictForwardPorts off by default' do
    is_expected.to contain_exec('firewalld-strict-forward-ports').with(
      unless: "grep -qx 'StrictForwardPorts=no' /etc/firewalld/firewalld.conf",
    )
  end

  context 'with strict forward ports' do
    let(:params) { { strict_forward_ports: true } }

    it 'sets StrictForwardPorts=yes and reloads firewalld' do
      is_expected.to contain_exec('firewalld-strict-forward-ports').with(
        command: %r{StrictForwardPorts=yes/' /etc/firewalld/firewalld.conf && firewall-cmd --reload},
        unless: "grep -qx 'StrictForwardPorts=yes' /etc/firewalld/firewalld.conf",
      )
    end
  end
end
