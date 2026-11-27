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
      expect(v4).to include('-A HOMELAB-INPUT -i tailscale+ -j RETURN')
      expect(v4).to include('--log-prefix "homelab-in: "')
      expect(v4).not_to match(%r{-j (ACCEPT|DROP)})
    end

    it 'uses ICMPv6 and DHCPv6 for IPv6' do
      expect(v6).to include('-A HOMELAB-INPUT -p ipv6-icmp -j RETURN')
      expect(v6).to include('--sport 547 --dport 546')
    end
  end

  context 'containers to the host' do
    it 'logs and returns by default, after the exceptions' do
      expect(v4).to include('-A HOMELAB-INPUT -i br-+ -p tcp -m tcp --dport 8442 -j RETURN')
      expect(v4).to include('-A HOMELAB-INPUT -i br-+ -m conntrack --ctstate NEW -m limit --limit 30/min --limit-burst 60 -j LOG --log-prefix "homelab-ctr: "')
      expect(v4).to include('-A HOMELAB-INPUT -i docker0 -j RETURN')
      expect(v4).not_to include('REJECT')
      expect(v4.index('--dport 8442 -j RETURN')).to be < v4.index('-j LOG --log-prefix "homelab-ctr: "')
    end

    context 'in enforce mode' do
      let(:params) { { mode: 'enforce' } }

      it 'accepts the exceptions and rejects the rest of the container traffic' do
        expect(v4).to include('-A HOMELAB-INPUT -i br-+ -p tcp -m tcp --dport 8442 -j ACCEPT')
        expect(v4).to include('-A HOMELAB-INPUT -i br-+ -j REJECT')
        expect(v4.index('-i br-+ -j REJECT')).to be < v4.index('multiport')
      end
    end
  end

  context 'container chain' do
    let(:fwd) { catalogue.resource('File', "#{dir}/rules.fwd.v4")[:content] }

    it 'logs new container connections to the LAN and blocks nothing by default' do
      expect(fwd).to include(':HOMELAB-FORWARD - [0:0]')
      expect(fwd).to include('-A HOMELAB-FORWARD -d 192.168.50.0/24 -p tcp -m tcp --dport 8442 -j RETURN')
      expect(fwd).to include('-A HOMELAB-FORWARD -i docker0 -d 192.168.50.0/24 -m conntrack --ctstate NEW')
      expect(fwd).to include('-A HOMELAB-FORWARD -i br-+ -d 192.168.50.0/24 -m conntrack --ctstate NEW')
      expect(fwd).to include('--log-prefix "homelab-fwd: "')
      expect(fwd).not_to match(%r{-j (REJECT|DROP|ACCEPT)})
    end

    context 'in enforce mode' do
      let(:params) { { egress_mode: 'enforce', egress_exceptions: ['tcp:8442', 'udp:22000'] } }

      it 'rejects after the exceptions' do
        expect(fwd).to include('-A HOMELAB-FORWARD -d 192.168.50.0/24 -p udp -m udp --dport 22000 -j RETURN')
        expect(fwd).to include('-A HOMELAB-FORWARD -i br-+ -d 192.168.50.0/24 -j REJECT')
        expect(fwd.index('--dport 22000 -j RETURN')).to be < fwd.index('-j REJECT')
      end
    end
  end

  context 'with input_scope containers (nuc, firewalld owns the host side)' do
    let(:params) { { input_scope: 'containers' } }

    it 'holds only the container section and leaves the rest to firewalld' do
      expect(v4).to include('--log-prefix "homelab-ctr: "')
      expect(v4).not_to include('multiport')
      expect(v4).not_to include('homelab-in: ')
      expect(v4).not_to match(%r{-j (ACCEPT|DROP)})
      is_expected.to contain_file("#{dir}/rules.fwd.v4").with_ensure('file')
    end

    context 'in enforce mode' do
      let(:params) { { input_scope: 'containers', mode: 'enforce' } }

      it 'returns the exceptions to firewalld and rejects the rest' do
        expect(v4).to include('-A HOMELAB-INPUT -i br-+ -p tcp -m tcp --dport 8442 -j RETURN')
        expect(v4).to include('-A HOMELAB-INPUT -i br-+ -j REJECT')
        expect(v4).not_to match(%r{-j (ACCEPT|DROP)})
      end
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

  it 'stages the container chain with the Syncthing exception' do
    is_expected.to contain_file("#{stage}/rules.fwd.v4").with_content(
      %r{-d 192\.168\.50\.0/24 -p tcp -m tcp --dport 22000 -j RETURN},
    )
  end

  it 'drives nas over nas-mgmt, guarded for noop' do
    is_expected.to contain_exec('nas-lan-firewall').with(
      unless: 'test -f /usr/local/libexec/openvox-nas-lan-firewall/check.sh && /bin/bash /usr/local/libexec/openvox-nas-lan-firewall/check.sh',
    )
  end
end
