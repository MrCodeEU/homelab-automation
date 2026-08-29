require 'spec_helper'

describe 'roles::caddy', type: :class do
  let(:hiera_config) { File.expand_path('../fixtures/hiera.yaml', __dir__) }
  # The production role is included after roles::base, which owns this
  # prerequisite. Keep the integration fixture focused on Caddy rendering.
  let(:pre_condition) { 'service { "firewalld": ensure => running }' }

  def rendered_file(path)
    catalogue.resource('file', path)[:content]
  end

  it { is_expected.to compile.with_all_deps }

  it 'renders every enabled service and excludes disabled services' do
    is_expected.to contain_file('/etc/caddy/conf.d.openvox-staging/local-authelia.caddy')
    is_expected.to contain_file('/etc/caddy/conf.d.openvox-staging/remote-https.caddy')
    is_expected.to contain_file('/etc/caddy/conf.d.openvox-staging/custom-upstream.caddy')
    is_expected.not_to contain_file('/etc/caddy/conf.d.openvox-staging/disabled.caddy')
  end

  it 'renders the intended local, remote, staging, HTTPS, and custom routes' do
    expect(rendered_file('/etc/caddy/conf.d.openvox-staging/local-authelia.caddy')).to include(
      'reverse_proxy localhost:8080',
      'import authelia_auth',
      'local.dev.example.test',
    )
    expect(rendered_file('/etc/caddy/conf.d.openvox-staging/000-snippets.caddy')).to include(
      'forward_auth http://localhost:9091',
    )
    expect(rendered_file('/etc/caddy/conf.d.openvox-staging/remote-https.caddy')).to include(
      'app.example.test, alt.example.test',
      'reverse_proxy https://nuc.tail33930.ts.net:8443',
      'tls_insecure_skip_verify',
    )
    expect(rendered_file('/etc/caddy/conf.d.openvox-staging/custom-upstream.caddy')).to include(
      'reverse_proxy nuc.tail33930.ts.net:9000',
      'reverse_proxy http://custom-backend:9000',
    )
  end

  it 'writes a complete, isolated Caddy configuration when requested' do
    render_dir = ENV.fetch('OPENVOX_CADDY_RENDER_DIR', '')
    skip 'OPENVOX_CADDY_RENDER_DIR not set' if render_dir.empty?

    conf_dir = File.join(render_dir, 'conf.d')
    Dir.mkdir(render_dir) unless Dir.exist?(render_dir)
    Dir.mkdir(conf_dir) unless Dir.exist?(conf_dir)

    File.write(File.join(render_dir, 'Caddyfile'), rendered_file('/etc/caddy/Caddyfile.openvox-staging'))
    File.write(File.join(conf_dir, '000-snippets.caddy'), rendered_file('/etc/caddy/conf.d.openvox-staging/000-snippets.caddy'))
    %w[local-authelia remote-https custom-upstream].each do |service|
      File.write(File.join(conf_dir, "#{service}.caddy"), rendered_file("/etc/caddy/conf.d.openvox-staging/#{service}.caddy"))
    end
  end
end
