require 'spec_helper'

describe 'roles::lan_firewall' do
  let(:dir) { '/usr/local/libexec/openvox-lan-firewall' }
  let(:v4) { catalogue.resource('File', "#{dir}/rules.v4")[:content] }
  let(:v6) { catalogue.resource('File', "#{dir}/rules.v6")[:content] }

  it { is_expected.to compile.with_all_deps }

  it 'loads the chain only when setup.sh --check says so' do
    is_expected.to contain_exec('lan-firewall').with(
      command: "#{dir}/setup.sh",
      unless: "#{dir}/setup.sh --check",
    )
  end

  it 're-checks from a timer (UGOS rebuilds INPUT)' do
    is_expected.to contain_service('homelab-lan-firewall.timer').with(ensure: 'running', enable: true)
  end

  context 'in log mode (default)' do
    it 'blocks nothing: allowed traffic and logged traffic both return' do
      expect(v4).to include(':HOMELAB-INPUT - [0:0]')
      expect(v4).to include('-A HOMELAB-INPUT -p tcp -m multiport --dports 22,8442,22000 -j RETURN')
      expect(v4).to include('-A HOMELAB-INPUT -p udp -m multiport --dports 21027,22000 -j RETURN')
      expect(v4).to include('-A HOMELAB-INPUT -i br-+ -j RETURN')
      expect(v4).to include('--log-prefix "homelab-in: "')
      expect(v4).not_to match(%r{-j (ACCEPT|DROP)})
    end

    it 'uses ICMPv6 and DHCPv6 for IPv6' do
      expect(v6).to include('-A HOMELAB-INPUT -p ipv6-icmp -j RETURN')
      expect(v6).to include('--sport 547 --dport 546')
    end
  end

  context 'in enforce mode' do
    let(:params) { { mode: 'enforce' } }

    it 'accepts the lists and drops the rest' do
      expect(v4).to include('-A HOMELAB-INPUT -p tcp -m multiport --dports 22,8442,22000 -j ACCEPT')
      expect(v4).to match(%r{-j DROP\nCOMMIT\n\z})
      expect(v4).not_to include('-j RETURN')
    end
  end
end

describe 'roles::nas_lan_firewall' do
  let(:stage) { '/var/lib/openvox-nas-lan-firewall' }

  it { is_expected.to compile.with_all_deps }

  it 'stages the same setup.sh and rules for nas' do
    is_expected.to contain_file("#{stage}/setup.sh").with_source('puppet:///modules/roles/lan_firewall/setup.sh')
    is_expected.to contain_file("#{stage}/rules.v4").with_content(%r{Managed by OpenVox \(roles::nas_lan_firewall\)})
  end

  it 'drives nas over nas-mgmt, guarded for noop' do
    is_expected.to contain_exec('nas-lan-firewall').with(
      unless: 'test -f /usr/local/libexec/openvox-nas-lan-firewall/check.sh && /bin/bash /usr/local/libexec/openvox-nas-lan-firewall/check.sh',
    )
  end
end
