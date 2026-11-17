require 'spec_helper'

describe 'roles::ziti_notify' do
  let(:node) { 'mljr.int.mljr.eu' }

  it { is_expected.to compile.with_all_deps }
  it do
    is_expected.to contain_file('/usr/local/bin/ziti-notify').with(source: 'puppet:///modules/roles/ziti_notify/ziti-notify')
    is_expected.to contain_file('/etc/systemd/system/ziti-notify.service')
      .with_content(%r{^ExecStart=/usr/local/bin/ziti-notify$})
      .with_content(%r{^Environment=ZITI_NOTIFY_NTFY_URL=https://ntfy\.mljr\.eu/homelab-security$})
      .with_content(%r{^ProtectSystem=strict$})
    is_expected.to contain_service('ziti-notify').with(ensure: 'running', enable: true)
  end
end
