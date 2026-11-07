# frozen_string_literal: true

require 'spec_helper'

describe 'roles::opkssh' do
  let(:facts) { { os: { family: 'RedHat' } } }
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

  context 'without auth_ids' do
    let(:params) { {} }

    it { is_expected.to contain_file('/etc/opk/auth_id').without_content(%r{^root }) }
  end
end
