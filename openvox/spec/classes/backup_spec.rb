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

  it 'renders only this host\'s selected service backup contract' do
    is_expected.to contain_file('/opt/backups/scripts/backup.sh').with(
      content: %r{Processing service: forgejo},
    )
    is_expected.to contain_file('/opt/backups/scripts/backup.sh').with(
      content: %r{backup_volume "forgejo-db-data"},
    )
    is_expected.to contain_file('/opt/backups/scripts/backup.sh').with(
      content: %r{Processing service: umami},
    )
    is_expected.to contain_file('/opt/backups/scripts/backup.sh').with(
      content: %r{backup_volume "umami_umami-db-data-v18"},
    )
  end

  it do
    is_expected.to contain_file('/opt/backups/scripts/restore.sh').with(
      ensure: 'file',
      mode: '0700',
      content: %r{forgejo\)},
    )
  end

  it 'keeps the rclone configuration owner-only and out of reports' do
    is_expected.to contain_file('/root/.config/rclone/rclone.conf').with(
      ensure: 'file',
      mode: '0600',
      show_diff: false,
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

  {
    'homelab-backup-verify-integrity.timer' => 'Sun *-*-* 04:30:00',
    'homelab-backup-verify-restore.timer' => 'Sun *-*-01..07 08:30:00',
  }.each do |timer, schedule|
    it do
      is_expected.to contain_file("/etc/systemd/system/#{timer}").with(
        ensure: 'file',
        mode: '0644',
        content: %r{OnCalendar=#{Regexp.escape(schedule)}},
        notify: 'Exec[backup-systemd-reload]',
      )
      is_expected.to contain_service(timer).with(
        ensure: 'running',
        enable: true,
      )
    end
  end

  context 'restore verification' do
    let(:verify) { catalogue.resource('file', '/opt/backups/scripts/verify.sh')[:content] }

    it 'restores dumps only for services in this host\'s contract' do
      expect(verify).to match(%r{^  restore_postgres 'forgejo' 'forgejo-dumps/forgejo\.sql' 'postgres:18\.6-alpine'$})
      expect(verify).to match(%r{^  restore_postgres 'umami' 'umami-dumps/umami\.sql'})
      expect(verify).not_to match(%r{restore_postgres 'sure'})
      expect(verify).not_to match(%r{restore_postgres 'defectdojo'})
    end

    it 'checks only SQLite volumes that are in the contract' do
      # neither kuma, actual-budget nor glucava is selected here
      expect(verify).not_to match(%r{^  restore_sqlite })
    end

    it 'runs the throwaway restore without network and cleans up' do
      expect(verify).to match(%r{--network none})
      expect(verify).to match(%r{docker volume rm -f "\$PG_VOLUME"})
      expect(verify).to match(%r{DUMP_MAX_AGE_S=\$\(\( 72 \* 3600 \)\)})
    end

    context 'with mailcow selected' do
      let(:params) { super().merge(services: ['mailcow']) }

      it do
        expect(verify).to match(%r{^  restore_mariadb 'mailcow' 'mailcow-dumps/mailcow\.sql' 'mariadb:10\.11' 'mailcow' 'mailcow-dumps/mailcow\.conf mailcow-dumps/redis-dump\.rdb'$})
      end
    end

    it 'does not restore mariadb for hosts without mailcow' do
      expect(verify).not_to match(%r{^  restore_mariadb })
    end

    context 'with kuma and glucava selected' do
      let(:params) { super().merge(services: ['kuma', 'glucava']) }

      it do
        expect(verify).to match(%r{^  restore_sqlite 'kuma_uptime-kuma-sqlite'$})
        expect(verify).to match(%r{^  restore_sqlite 'glucava-data'$})
        expect(verify).not_to match(%r{restore_sqlite 'actual-budget-data'})
      end
    end
  end

  context 'when backup CPU quota is configured' do
    let(:params) do
      super().merge(cpu_quota: '35%')
    end

    it do
      is_expected.to contain_file('/etc/systemd/system/homelab-backup.service').with(
        content: %r{CPUQuota=35%},
      )
    end
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

  context 'when fresh-host recovery selects Umami' do
    let(:facts) { { openvox_recovery_services: 'umami' } }

    it do
      is_expected.to contain_exec('backup-recovery-umami').with(
        command: %r{/opt/backups/scripts/restore\.sh --force --skip-volumes umami_umami-db-data-v18 --service umami},
        require: 'Exec[backup-recovery-fresh-host-guard]',
      )
    end
  end

  context 'when recovery selects a service not backed up by this host' do
    let(:facts) { { openvox_recovery_services: 'not-local' } }

    it { is_expected.to compile.and_raise_error(%r{Unknown or non-local-backup recovery selection}) }
  end
end
