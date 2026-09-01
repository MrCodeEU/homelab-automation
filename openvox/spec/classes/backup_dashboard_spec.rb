require 'json'
require 'spec_helper'

describe 'roles::backup_dashboard' do
  let(:hiera_config) { File.expand_path('../fixtures/backup_dashboard_hiera.yaml', __dir__) }
  let(:params) { { generated_at: '2026-09-01T12:00:00Z' } }

  def backup_catalog
    JSON.parse(catalogue.resource('file', '/var/lib/backup-dashboard/backup_catalog.json')[:content])
  end

  it { is_expected.to compile.with_all_deps }

  it 'keeps collector state separate from deployment files and writable only by its runtime UID' do
    is_expected.to contain_file('/var/lib/backup-dashboard').with(
      ensure: 'directory',
      owner: 'root',
      group: 'root',
      mode: '0755',
    )
    is_expected.to contain_file('/var/lib/backup-dashboard/state').with(
      owner: 10001,
      group: 10001,
      mode: '0755',
      require: 'File[/var/lib/backup-dashboard]',
    )
  end

  it 'writes a root-owned JSON catalog for NAS and critical service backups' do
    is_expected.to contain_file('/var/lib/backup-dashboard/backup_catalog.json').with(
      ensure: 'file',
      owner: 'root',
      group: 'root',
      mode: '0644',
      require: 'File[/var/lib/backup-dashboard]',
    )

    catalog = backup_catalog
    expect(catalog).to include('generated_at', 'entries')
    expect(catalog['generated_at']).to eq('2026-09-01T12:00:00Z')
    expect(catalog['entries']).to all(include('name', 'host', 'source', 'destinations', 'schedule'))
  end

  it 'preserves offsite destinations and schedules for NAS and service backups' do
    entries = backup_catalog['entries']
    appdata = entries.find { |entry| entry['name'] == 'appdata' }
    forgejo = entries.find { |entry| entry['name'] == 'forgejo' }
    mailcow = entries.find { |entry| entry['name'] == 'mailcow' }

    expect(appdata).to include(
      'host' => 'nas',
      'source' => '/mnt/user/appdata',
      'dest' => 'nas/appdata',
      'destinations' => %w[pcloud ugreen],
      'schedule' => '04:40:00',
    )
    expect(forgejo).to include(
      'host' => 'nuc',
      'destinations' => %w[pcloud ugreen],
      'schedule' => '03:00:00',
    )
    expect(mailcow).to include(
      'host' => 'mljr',
      'destinations' => %w[pcloud ugreen],
      'schedule' => '03:00:00',
    )
  end
end
