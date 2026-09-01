require 'spec_helper'

describe 'roles::tutabridge_cli' do
  let(:hiera_config) { File.expand_path('../fixtures/tutabridge_hiera.yaml', __dir__) }

  it { is_expected.to compile.with_all_deps }

  it 'keeps credentials private and gates destructive recovery behind checks' do
    is_expected.to contain_file('/opt/tutabridge/keyring-pass').with(mode: '0600')
    is_expected.to contain_exec('tutabridge-keyring-selfheal').with(
      command: %r{keyring-lock-apply\.sh},
      unless: %r{keyring-lock-check\.sh},
      require: 'Service[gnome-keyring-daemon]',
    )
    is_expected.to contain_exec('tutabridge-first-login').with(
      unless: '/usr/bin/test -f /opt/tutabridge/.first-login-done',
      timeout: 3600,
      logoutput: 'on_failure',
    )
  end

  it 'orders unit reconciliation before enabling scheduled export' do
    is_expected.to contain_exec('tutabridge-daemon-reload').with(refreshonly: true)
    is_expected.to contain_exec('tutabridge-backup-timer').with(
      require: 'Exec[tutabridge-daemon-reload]',
    )
  end
end
