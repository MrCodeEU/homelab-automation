require 'spec_helper'

describe 'roles::services' do
  let(:hiera_config) { File.expand_path('../fixtures/services_hiera.yaml', __dir__) }

  let(:params) do
    {
      hostname: 'mljr',
    }
  end

  it { is_expected.to compile.with_all_deps }

  it 'deploys only enabled, managed, non-dedicated services for the host' do
    is_expected.to contain_file('/opt/forgejo/.env').with(
      ensure: 'file',
      mode: '0600',
      show_diff: false,
      content: %r{BIND_ADDR=127\.0\.0\.1},
    )
    is_expected.to contain_file('/opt/homepage/.env')
    is_expected.not_to contain_file('/opt/authelia/.env')
    is_expected.not_to contain_file('/opt/manual-service/.env')
    is_expected.not_to contain_file('/opt/disabled-service/.env')
  end

  it 'runs the configured critical production hook after deploy' do
    is_expected.to contain_exec('services-forgejo-post-deploy-hook').with(
      command: %r{post-deploy-hook\.sh forgejo /opt/forgejo true},
      require: 'Exec[services-forgejo-deploy]',
    )
  end

  it 'cleans only entries no longer active on this host' do
    is_expected.to contain_exec('services-cleanup-orphaned').with(
      command: %r{cleanup-apply\.sh /opt forgejo,authelia,manual-service,disabled-service,homepage,speedtest forgejo,authelia,manual-service,homepage},
      unless: %r{cleanup-check\.sh /opt forgejo,authelia,manual-service,disabled-service,homepage,speedtest forgejo,authelia,manual-service,homepage},
    )
  end

  context 'when cleanup is disabled for an appliance host' do
    let(:params) { super().merge(cleanup_enabled: false) }

    it { is_expected.not_to contain_exec('services-cleanup-orphaned') }
  end

  it 'pulls every service when no pull scope is set' do
    is_expected.to contain_exec('services-forgejo-deploy').with(environment: [])
    is_expected.to contain_exec('services-homepage-deploy').with(environment: [])
  end

  context 'with a repository_dispatch pull scope' do
    let(:facts) { { openvox_pull_services: 'homepage,codec' } }

    it 'pulls only the named services and still deploys the others' do
      is_expected.to contain_exec('services-homepage-deploy').with(environment: [])
      is_expected.to contain_exec('services-forgejo-deploy').with(
        command: %r{compose-deploy\.sh /opt/forgejo false},
        environment: ['OPENVOX_SKIP_PULL=true'],
      )
    end
  end

  context 'on nuc with a selected staging service' do
    let(:params) do
      super().merge(hostname: 'nuc')
    end

    let(:facts) { { openvox_staging_services: 'homepage' } }

    it 'creates only the selected isolated staging deployment' do
      is_expected.to contain_file('/opt/staging/homepage/.env').with(
        content: %r{BIND_ADDR=127\.0\.0\.1},
      )
      is_expected.to contain_exec('services-homepage-staging-deploy').with(
        command: %r{compose-deploy\.sh /opt/staging/homepage false homepage-staging},
      )
      is_expected.not_to contain_exec('services-homepage-staging-post-deploy-hook')
    end
  end

  context 'on nuc with an invalid staging selection' do
    let(:params) do
      super().merge(hostname: 'nuc')
    end

    let(:facts) { { openvox_staging_services: 'forgejo' } }

    it { is_expected.to compile.and_raise_error(%r{Unknown or non-staging service selection}) }
  end
end
