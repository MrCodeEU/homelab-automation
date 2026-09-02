require 'spec_helper'

describe 'roles::canarytokens' do
  let(:params) { { wg_key_seed: 'test-only-canary-seed' } }

  it { is_expected.to compile.with_all_deps }

  it 'keeps both environment files owner-only and redacted' do
    ['/opt/canarytokens/frontend.env', '/opt/canarytokens/switchboard.env'].each do |path|
      is_expected.to contain_file(path).with(mode: '0600', show_diff: false)
    end
  end

  it 'publishes only loopback listeners and recreates containers on a refresh' do
    is_expected.to contain_file('/opt/canarytokens/docker-compose.yml').with(
      content: %r{127\.0\.0\.1:8100:8083},
      notify: 'Exec[canarytokens-restart]',
    )
    is_expected.to contain_exec('canarytokens-restart').with(
      refreshonly: true,
      require: 'File[/opt/canarytokens/docker-compose.yml]',
    )
  end
end
