require 'spec_helper'

describe 'roles::backup' do
  let(:params) do
    {
      services: ['forgejo', 'umami'],
      hostname: 'spec-host',
    }
  end

  it { is_expected.to compile.with_all_deps }

  it do
    is_expected.to contain_file('/opt/backups/scripts/backup.sh').with(
      ensure: 'file',
      mode: '0700',
      require: 'File[/opt/backups/scripts]',
    )
  end

  it do
    is_expected.to contain_file('/etc/systemd/system/homelab-backup.timer').with(
      ensure: 'file',
      mode: '0644',
      content: %r{OnCalendar=\*-\*-\* 03:00:00},
      notify: 'Exec[backup-systemd-reload]',
    )
  end

  it do
    is_expected.to contain_service('homelab-backup.timer').with(
      ensure: 'running',
      enable: true,
      require: [
        'File[/etc/systemd/system/homelab-backup.timer]',
        'Exec[backup-systemd-reload]',
      ],
    )
  end

  context 'when fresh-host recovery selects a dump-backed service' do
    let(:facts) { { openvox_recovery_services: 'forgejo' } }

    it do
      is_expected.to contain_exec('backup-recovery-forgejo').with(
        command: %r{/opt/backups/scripts/restore\.sh --force --skip-volumes forgejo-db-data --service forgejo},
        require: 'Exec[backup-recovery-fresh-host-guard]',
      )
    end
  end

  context 'when recovery selects a service not backed up by this host' do
    let(:facts) { { openvox_recovery_services: 'not-local' } }

    it { is_expected.to compile.and_raise_error(%r{Unknown or non-local-backup recovery selection}) }
  end
end
