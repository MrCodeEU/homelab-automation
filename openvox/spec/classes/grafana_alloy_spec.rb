require 'spec_helper'

describe 'roles::grafana_alloy' do
  let(:hiera_config) { File.expand_path('../fixtures/grafana_alloy_hiera.yaml', __dir__) }
  let(:params) { { hostname: 'nuc' } }

  def rendered_file(path)
    catalogue.resource('file', path)[:content]
  end

  it { is_expected.to compile.with_all_deps }

  it 'protects rendered credentials and uses the intended remote-write endpoints' do
    manifest = File.read(File.expand_path('../../modules/roles/manifests/grafana_alloy.pp', __dir__))
    config = rendered_file('/opt/grafana-alloy/config.alloy')

    is_expected.to contain_file('/opt/grafana-alloy/config.alloy').with(
      ensure: 'file',
      mode: '0644',
      require: 'File[/opt/grafana-alloy]',
    )
    expect(manifest).to match(/content\s*=>\s*Sensitive\(epp\(/)
    expect(config).to include(
      'url = "http://100.100.10.1:19090/api/v1/write"',
      'url = "http://100.100.10.1:3100/loki/api/v1/push"',
      'bearer_token    = "test-homeassistant-token"',
    )
  end

  it 'renders NUC-only remote monitoring without relabelling its remote sources' do
    config = rendered_file('/opt/grafana-alloy/config.alloy')

    expect(config).to include(
      'prometheus.scrape "homeassistant"',
      '"__address__" = "100.100.10.200:8123"',
      'prometheus.scrape "wd_mycloud"',
      '"__address__" = "100.100.10.5:9100"',
      'forward_to      = [prometheus.remote_write.homelab.receiver]',
    )
  end

  it 'self-heals the containerd socket remount without running on ordinary applies' do
    is_expected.to contain_file('/etc/systemd/system/grafana-alloy-containerd-remount.path').with(
      content: %r{PathChanged=/run/containerd/containerd\.sock},
      notify: 'Exec[grafana-alloy-systemd-reload]',
    )
    is_expected.to contain_service('grafana-alloy-containerd-remount.path').with(
      ensure: 'running',
      enable: true,
    )
    is_expected.to contain_exec('grafana-alloy-remount-current-containerd-socket').with(
      refreshonly: true,
      require: 'Exec[grafana-alloy-run]',
    )
  end

  context 'on Mljr without a Home Assistant token' do
    let(:hiera_config) { '/dev/null' }
    let(:params) { { hostname: 'mljr' } }

    it 'keeps the Caddy scrape but omits the bearer-token scrape' do
      config = rendered_file('/opt/grafana-alloy/config.alloy')

      expect(config).to include('prometheus.scrape "security"', '/var/log/caddy/*.log')
      expect(config).not_to include('prometheus.scrape "homeassistant"', 'bearer_token')
    end
  end

  context 'on Ugreen' do
    let(:hiera_config) { '/dev/null' }
    let(:params) { { hostname: 'ugreen', manage_docker_sdk: true } }

    it 'installs the Docker SDK locally and collects SMART metrics' do
      is_expected.to contain_package('python3-docker').with(ensure: 'installed')
      expect(rendered_file('/opt/grafana-alloy/config.alloy')).to include(
        'prometheus.scrape "smart"',
        '"instance"    = "ugreen"',
      )
    end
  end
end
