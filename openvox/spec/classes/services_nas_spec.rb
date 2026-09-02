require 'spec_helper'

describe 'roles::services_nas' do
  let(:hiera_config) { File.expand_path('../fixtures/services_nas_hiera.yaml', __dir__) }

  it { is_expected.to compile.with_all_deps }

  it 'deploys only enabled, managed, non-bespoke NAS services' do
    is_expected.to contain_roles__services_nas__service('ollama')
    is_expected.not_to contain_roles__services_nas__service('manual-nas-service')
    is_expected.not_to contain_roles__services_nas__service('skipped-nas-service')
    is_expected.not_to contain_roles__services_nas__service('disabled-nas-service')
  end

  it 'keeps proxy credentials quiet and orders staging, sync, deploy, and health checks' do
    is_expected.to contain_exec('services-nas-ghcr-login').with(logoutput: false)
    is_expected.to contain_file('/var/lib/openvox-services-nas-staging/ollama/.env').with(mode: '0600')
    is_expected.to contain_exec('services-nas-ollama-sync').with(
      require: [
        'File[/var/lib/openvox-services-nas-staging/ollama]',
        'File[/var/lib/openvox-services-nas-staging/ollama/.env]',
      ],
    )
    is_expected.to contain_exec('services-nas-ollama-deploy').with(
      require: 'Exec[services-nas-ollama-sync]',
    )
    is_expected.to contain_exec('services-nas-ollama-healthcheck').with(
      require: 'Exec[services-nas-ollama-deploy]',
    )
  end

  it 'runs the declared post-deploy hook only after remote deployment' do
    is_expected.to contain_exec('services-nas-ollama-post-deploy-hook').with(
      timeout: 600,
      require: 'Exec[services-nas-ollama-deploy]',
    )
  end
end
