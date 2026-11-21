require 'spec_helper'

describe 'roles::ziti_renew' do
  let(:node) { 'nuc.int.mljr.eu' }
  let(:params) do
    {
      identities: [
        { 'file' => '/opt/kuma/ziti/kuma-nuc.json', 'restart' => 'docker restart kuma-ziti-proxy' },
        { 'file' => '/opt/ziti-router-nuc/data/nuc.cert' },
      ],
    }
  end

  it { is_expected.to compile.with_all_deps }

  it 'lists each identity with its restart command, and watch-only paths alone' do
    is_expected.to contain_file('/etc/ziti-renew/identities.conf').with_content(
      %r{^/opt/kuma/ziti/kuma-nuc\.json docker restart kuma-ziti-proxy\n/opt/ziti-router-nuc/data/nuc\.cert\n\z},
    )
  end

  it 'runs daily with the renewal threshold, without UGOS GODEBUG' do
    is_expected.to contain_file('/etc/systemd/system/ziti-renew.service')
      .with_content(%r{^ExecStart=/usr/local/bin/ziti-renew -days 60$})
      .with_content(%r{^Environment=GODEBUG=$})
    is_expected.to contain_file('/etc/systemd/system/ziti-renew.timer').with_content(%r{^OnCalendar=\*-\*-\* 10:40$})
    is_expected.to contain_service('ziti-renew.timer').with(ensure: 'running', enable: true)
    is_expected.to contain_exec('ziti-renew-first-run')
  end

  context 'with a relative path' do
    let(:params) { { identities: [{ 'file' => 'kuma-nuc.json' }] } }

    it { is_expected.to compile.and_raise_error(%r{identities}) }
  end
end
