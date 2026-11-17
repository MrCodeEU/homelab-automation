require 'spec_helper'

describe 'roles::home_ip' do
  let(:node) { 'nuc.int.mljr.eu' }

  context 'serve (nuc)' do
    let(:params) { { mode: 'serve' } }

    it { is_expected.to compile.with_all_deps }
    it do
      is_expected.to contain_file('/usr/local/bin/home-ip').with(source: 'puppet:///modules/roles/home_ip/home-ip')
      is_expected.to contain_file('/etc/systemd/system/home-ip.service')
        .with_content(%r{^ExecStart=/usr/local/bin/home-ip serve$})
        .with_content(%r{^Environment=HOME_IP_LISTEN=127\.0\.0\.1:19480$})
        .with_content(%r{^DynamicUser=yes$})
      is_expected.to contain_service('home-ip').with(ensure: 'running', enable: true)
      is_expected.not_to contain_file('/etc/systemd/system/home-ip-sync.timer')
    end
  end

  context 'sync (mljr)' do
    let(:node) { 'mljr.int.mljr.eu' }
    let(:params) { { mode: 'sync' } }

    it { is_expected.to compile.with_all_deps }
    it do
      is_expected.to contain_file('/etc/systemd/system/home-ip-sync.service')
        .with_content(%r{^ExecStart=/usr/local/bin/home-ip sync$})
        .with_content(%r{^Environment=HOME_IP_SOURCE=http://127\.0\.0\.1:19480/v1/home-ip$})
      is_expected.to contain_file('/etc/systemd/system/home-ip-sync.timer').with_content(%r{^OnUnitActiveSec=5min$})
      is_expected.to contain_service('home-ip-sync.timer').with(ensure: 'running', enable: true)
      is_expected.not_to contain_service('home-ip')
    end
  end
end
