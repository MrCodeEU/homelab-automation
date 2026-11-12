require 'spec_helper'

describe 'roles::deploy_agent' do
  let(:node) { 'nuc.int.mljr.eu' }

  it { is_expected.to compile.with_all_deps }

  # agent.env is Sensitive; with_content cannot match through that.
  def agent_env
    content = catalogue.resource('File', '/etc/homelab-deploy/agent.env')[:content]
    content.respond_to?(:unwrap) ? content.unwrap : content
  end

  it 'installs the agent, keyring and a secret env file for this host' do
    is_expected.to contain_file('/usr/local/bin/deploy-agent').with(
      mode: '0755',
      source: 'puppet:///modules/roles/deploy_agent/deploy-agent',
    )
    is_expected.to contain_file('/etc/homelab-deploy/keyring.asc').with(
      source: 'puppet:///modules/roles/deploy_agent/github-web-flow.asc',
    )
    is_expected.to contain_file('/etc/homelab-deploy/agent.env').with(mode: '0600', show_diff: false)
    expect(agent_env).to match(%r{^DEPLOY_HOST=nuc$})
    expect(agent_env).to match(%r{^DEPLOY_MODE=noop$})
    expect(agent_env).to match(%r{^OPENVOX_CERTNAME=nuc\.int\.mljr\.eu$})
    expect(agent_env).to match(%r{^DEPLOY_APPLY=scripts/openvox-apply\.sh$})
  end

  it 'never restarts the unit from Puppet (an agent-run apply would kill itself)' do
    is_expected.to contain_service('deploy-agent').with(ensure: 'running', enable: true)
    is_expected.to contain_service('deploy-agent').without_subscribe
    is_expected.to contain_file('/etc/systemd/system/deploy-agent.service')
      .with_content(%r{^Restart=always$})
      .with_content(%r{^EnvironmentFile=/etc/homelab-deploy/agent\.env$})
  end

  context 'in apply mode' do
    let(:params) { { mode: 'apply' } }

    it { expect(agent_env).to match(%r{^DEPLOY_MODE=apply$}) }
  end
end
