require 'spec_helper'

describe 'roles::authelia' do
  let(:hiera_config) { File.expand_path('../fixtures/authelia_hiera.yaml', __dir__) }

  def rendered_file(path)
    catalogue.resource('file', path)[:content]
  end

  it { is_expected.to compile.with_all_deps }

  it 'protects secret-bearing configuration and limits the listener to localhost' do
    manifest = File.read(File.expand_path('../../modules/roles/manifests/authelia.pp', __dir__))

    is_expected.to contain_file('/opt/authelia/configuration.yml').with(
      ensure: 'file',
      mode: '0600',
      notify: 'Exec[authelia-restart]',
    )
    expect(manifest).to match(/content\s*=>\s*Sensitive\(\$config_content\)/)
    expect(rendered_file('/opt/authelia/docker-compose.yml')).to include(
      '127.0.0.1:9091:9091',
    )
  end

  it 'keeps deny-by-default access control and only bypasses the login portal' do
    config = rendered_file('/opt/authelia/configuration.yml')

    expect(config).to include(
      'default_policy: deny',
      '- domain: "auth.mljr.eu"',
      'policy: bypass',
      '- domain: "*.mljr.eu"',
      'policy: one_factor',
    )
  end

  it 'does not regenerate users or restart Authelia on every apply' do
    is_expected.to contain_exec('authelia-users-database').with(
      creates: '/opt/authelia/users_database.yml',
      notify: 'Exec[authelia-restart]',
      require: 'File[/opt/authelia]',
    )
    is_expected.to contain_exec('authelia-restart').with(
      refreshonly: true,
      require: 'File[/opt/authelia/docker-compose.yml]',
    )
  end
end
