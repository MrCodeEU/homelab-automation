require 'spec_helper'

describe 'roles::unraid_proxy' do
  it { is_expected.to compile.with_all_deps }

  it 'requires a started array before changing persistent NAS state' do
    is_expected.to contain_file('/usr/local/libexec/openvox-unraid').with(
      ensure: 'directory',
      recurse: true,
      purge: true,
    )
    is_expected.to contain_exec('unraid-array-started').with(
      command: %r{array-check\.sh},
      unless: '/usr/bin/false',
      require: 'File[/usr/local/libexec/openvox-unraid]',
    )
  end

  it 'uses read-only guards and preserves bootstrap ordering' do
    is_expected.to contain_exec('unraid-array-dirs').with(
      command: %r{dirs-apply\.sh},
      unless: %r{dirs-check\.sh},
      require: 'Exec[unraid-array-started]',
    )
    is_expected.to contain_exec('unraid-bootstrap-script').with(
      command: %r{bootstrap-script-apply\.sh},
      unless: %r{bootstrap-script-check\.sh},
      require: 'Exec[unraid-array-started]',
    )
    is_expected.to contain_exec('unraid-schedule-merge').with(
      command: %r{schedule-apply\.sh},
      unless: %r{schedule-check\.sh},
      require: 'Exec[unraid-bootstrap-script]',
    )
  end
end

describe 'roles::unraid_backup_proxy' do
  it { is_expected.to compile.with_all_deps }

  it 'keeps backup provisioning guarded and schedules only after its script exists' do
    %w[unraid-backup-key unraid-backup-logdir unraid-backup-script].each do |resource|
      apply = resource.sub('unraid-backup-', '')
      is_expected.to contain_exec(resource).with(
        command: %r{#{apply}-apply\.sh},
        unless: %r{#{apply}-check\.sh},
        require: 'File[/usr/local/libexec/openvox-unraid-backup]',
      )
    end
    is_expected.to contain_exec('unraid-backup-schedule').with(
      command: %r{schedule-apply\.sh},
      unless: %r{schedule-check\.sh},
      require: 'Exec[unraid-backup-script]',
    )
  end
end

describe 'roles::wd_mycloud_proxy' do
  it { is_expected.to compile.with_all_deps }

  it 'keeps recovery actions guarded and bounds the remote update operation' do
    is_expected.to contain_exec('wd-mycloud-tailscale-update').with(
      command: %r{tailscale-update-apply\.sh},
      unless: %r{tailscale-update-check\.sh},
      timeout: 120,
      require: 'File[/usr/local/libexec/openvox-wd-mycloud]',
    )
    {
      'watchdog-script' => 'watchdog',
      'watchdog-cron' => 'cron',
      'clamav-hook' => 'clamav',
    }.each do |action, script|
      is_expected.to contain_exec("wd-mycloud-#{action}").with(
        command: %r{#{script}-apply\.sh},
        unless: %r{#{script}-check\.sh},
        require: 'File[/usr/local/libexec/openvox-wd-mycloud]',
      )
    end
  end
end
