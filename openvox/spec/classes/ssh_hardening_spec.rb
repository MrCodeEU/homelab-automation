require 'spec_helper'

describe 'roles::ssh_hardening' do
  let(:hiera_config) { File.expand_path('../fixtures/ssh_hardening_hiera.yaml', __dir__) }

  context 'phase 1 (default): key installed, passwords untouched' do
    it { is_expected.to compile.with_all_deps }

    it 'installs the recovery key where sshd looks for it' do
      is_expected.to contain_file('/etc/ssh/authorized_keys.d/root')
        .with(owner: 'root', mode: '0644')
        .with_content(%r{\Assh-ed25519 \S+ homelab-recovery\n\z})
    end

    it 'adds the key path but does not disable passwords' do
      is_expected.to contain_file('/etc/ssh/sshd_config.d/00-openvox-hardening.conf')
        .with_content(%r{^AuthorizedKeysFile \.ssh/authorized_keys /etc/ssh/authorized_keys\.d/%u$})
        .without_content(%r{PasswordAuthentication})
        .that_requires('File[/etc/ssh/authorized_keys.d/root]')
        .that_notifies('Exec[ssh-hardening-reload]')
    end
  end

  context 'phase 2: passwords disabled' do
    let(:params) { { disable_passwords: true, recovery_user: 'mrcode' } }

    it 'turns password and keyboard-interactive login off' do
      is_expected.to contain_file('/etc/ssh/authorized_keys.d/mrcode')
      is_expected.to contain_file('/etc/ssh/sshd_config.d/00-openvox-hardening.conf')
        .with_content(%r{^PasswordAuthentication no$})
        .with_content(%r{^KbdInteractiveAuthentication no$})
    end
  end
end
