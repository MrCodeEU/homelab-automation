require 'spec_helper'

describe 'roles::backup_remote_target' do
  let(:params) do
    {
      pubkey: 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey backup-source',
    }
  end

  it { is_expected.to compile.with_all_deps }

  it 'creates a locked, shell-less SFTP-only backup account' do
    is_expected.to contain_user('rclone-backup').with(
      ensure: 'present',
      system: true,
      shell: '/usr/sbin/nologin',
      home: '/volume1/homelab-backups/data',
      password: '!',
    )
  end

  it 'keeps the chroot root immutable to the backup user' do
    is_expected.to contain_file('/volume1/homelab-backups').with(
      ensure: 'directory',
      owner: 'root',
      group: 'root',
      mode: '0755',
    )
    is_expected.to contain_file('/volume1/homelab-backups/data').with(
      ensure: 'directory',
      owner: 'rclone-backup',
      group: 'rclone-backup',
      mode: '0750',
    )
    is_expected.to contain_file('/volume1/homelab-backups/snapshots').with(
      owner: 'root',
      group: 'root',
      mode: '0700',
    )
  end

  it 'authorizes only the public key and protects the key file' do
    is_expected.to contain_file('/volume1/homelab-backups/data/.ssh/authorized_keys').with(
      owner: 'rclone-backup',
      group: 'rclone-backup',
      mode: '0600',
      content: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey \n",
    )
  end

  it 'schedules root-only Btrfs history creation' do
    is_expected.to contain_file('/usr/local/libexec/openvox-backup-history/snapshot.sh').with(
      owner: 'root',
      group: 'root',
      mode: '0700',
    )
    is_expected.to contain_file('/etc/systemd/system/homelab-backup-snapshot.timer').with(
      content: %r{OnCalendar=\*-\*-\* 05:30:00},
      notify: 'Exec[backup-snapshot-systemd-reload]',
    )
    is_expected.to contain_service('homelab-backup-snapshot.timer').with(
      ensure: 'running',
      enable: true,
    )
  end

  it 'installs the idempotent sshd containment reconciler' do
    is_expected.to contain_exec('backup-remote-target-sshd-match-block').with(
      command: %r{sshd-match-block-apply\.sh},
      unless: %r{sshd-match-block-check\.sh},
      require: 'File[/usr/local/libexec/openvox-backup-remote-target]',
    )
  end

  it 'uses a forced, non-forwarding internal-sftp fallback configuration' do
    script = File.read(File.expand_path('../../modules/roles/files/backup_remote_target/sshd-match-block-check.sh', __dir__))

    expect(script).to include(
      'Match User rclone-backup',
      'ChrootDirectory /volume1/homelab-backups',
      'ForceCommand internal-sftp',
      'AllowTcpForwarding no',
      'AllowAgentForwarding no',
      'X11Forwarding no',
      'PermitTTY no',
      'PasswordAuthentication no',
    )
  end
end
