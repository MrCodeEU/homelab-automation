# frozen_string_literal: true

require 'spec_helper'

describe 'roles::opkssh' do
  let(:facts) { { os: { family: 'RedHat', selinux: { enabled: true } } } }
  let(:params) do
    { auth_ids: [{ 'user' => 'root', 'identity' => 'spec-sub', 'issuer' => 'https://auth.mljr.eu' }] }
  end

  it { is_expected.to compile.with_all_deps }

  it 'only trusts Authelia with the opkssh client' do
    is_expected.to contain_file('/etc/opk/providers')
      .with(owner: 'root', group: 'opksshuser', mode: '0640')
      .with_content(%r{^https://auth\.mljr\.eu opkssh 24h$})
  end

  it { is_expected.to contain_file('/etc/opk/auth_id').with_content(%r{^root spec-sub https://auth\.mljr\.eu$}) }

  it 'pins the binary by digest' do
    is_expected.to contain_exec('opkssh-binary')
      .with_command(%r{sha256sum -c})
      .with_unless(%r{e799b780d5477e8d986a2e6784773ebb2451d860dd842d23e271baf88aee2da3})
  end

  it 'enables the command only after everything it needs is in place' do
    is_expected.to contain_file('/etc/ssh/sshd_config.d/10-openvox-opkssh.conf')
      .with_content(%r{^AuthorizedKeysCommand /usr/local/bin/opkssh verify %u %k %t$})
      .with_content(%r{^AuthorizedKeysCommandUser opksshuser$})
      .that_requires(['Exec[opkssh-binary]', 'Exec[opkssh-selinux]', 'File[/etc/opk/auth_id]'])
      .that_notifies('Exec[opkssh-sshd-reload]')
  end

  context 'without SELinux, with GODEBUG cleared (ugreen, UGOS)' do
    let(:facts) { { os: { family: 'Debian', selinux: { enabled: false } } } }
    let(:params) do
      { auth_ids: [{ 'user' => 'mrcode', 'identity' => 'spec-sub', 'issuer' => 'https://auth.mljr.eu' }], clear_godebug: true }
    end

    it { is_expected.to compile.with_all_deps }
    it { is_expected.not_to contain_exec('opkssh-selinux') }
    it { is_expected.not_to contain_exec('opkssh-cache-label') }
    it do
      is_expected.to contain_file('/etc/ssh/sshd_config.d/10-openvox-opkssh.conf')
        .with_content(%r{^AuthorizedKeysCommand /usr/bin/env -u GODEBUG /usr/local/bin/opkssh verify %u %k %t$})
        .that_requires('Exec[opkssh-binary]')
    end
    it { is_expected.to contain_file('/etc/ssh/sshd_config.d/11-openvox-opkssh-root.conf').with_ensure('absent') }

    context 'with root from one loopback address' do
      let(:params) { super().merge(root_match_address: '127.0.0.2') }

      it do
        is_expected.to contain_file('/etc/ssh/sshd_config.d/11-openvox-opkssh-root.conf')
          .with(ensure: 'file', mode: '0600')
          .with_content(%r{^Match User root Address 127\.0\.0\.2\n  PermitRootLogin prohibit-password\n  AuthenticationMethods publickey\nMatch all\n\z})
          .that_notifies('Exec[opkssh-sshd-reload]')
      end
    end
  end

  context 'without auth_ids' do
    let(:params) { {} }

    it { is_expected.to contain_file('/etc/opk/auth_id').without_content(%r{^root }) }
  end
end
