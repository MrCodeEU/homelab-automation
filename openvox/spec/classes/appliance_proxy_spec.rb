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
    is_expected.to contain_exec('unraid-tcp-sysctl').with(
      command: %r{sysctl-apply\.sh},
      unless: %r{sysctl-check\.sh},
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
  # Provides breakglass_pubkeys, which the class looks up.
  let(:hiera_config) { File.expand_path('../fixtures/ssh_hardening_hiera.yaml', __dir__) }

  it { is_expected.to compile.with_all_deps }

  it 'installs the break-glass keys behind a read-only guard' do
    is_expected.to contain_file('/usr/local/libexec/openvox-wd-mycloud/breakglass-authorized_keys')
      .with_content(%r{homelab-recovery\n.*homelab-breakglass-yk1\nfrom="127\.0\.0\.1",no-agent-forwarding,no-port-forwarding,no-X11-forwarding ssh-ed25519 \S+ homelab-wd-mycloud-mgmt\n\z}m)
    is_expected.to contain_exec('wd-mycloud-breakglass').with(
      command: %r{breakglass-apply\.sh},
      unless: %r{breakglass-check\.sh},
      require: ['File[/usr/local/libexec/openvox-wd-mycloud/breakglass-authorized_keys]', 'Exec[wd-mycloud-clamav-hook]'],
    )
  end

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

describe 'roles::wd_mycloud_node_exporter_proxy' do
  it { is_expected.to compile.with_all_deps }

  it 'keeps every remote mutation behind a read-only check' do
    {
      'update' => ['update', 300],
      'watchdog-script' => ['watchdog', nil],
      'watchdog-cron' => ['cron', nil],
      'clamav-hook' => ['clamav', nil],
    }.each do |action, (script, timeout)|
      resource = "wd-mycloud-node-exporter-#{action}"
      is_expected.to contain_exec(resource).with(
        command: %r{#{script}-apply\.sh},
        unless: %r{#{script}-check\.sh},
        require: 'File[/usr/local/libexec/openvox-wd-mycloud-node-exporter]',
      )
      is_expected.to contain_exec(resource).with(timeout: timeout) if timeout
    end
  end
end

describe 'roles::wd_mycloud_mgmt_key' do
  let(:hiera_config) { File.expand_path('../fixtures/ssh_hardening_hiera.yaml', __dir__) }
  let(:conf) { '/etc/ssh/ssh_config.d/40-wd-mycloud-mgmt.conf' }

  it { is_expected.to compile.with_all_deps }

  it 'writes the key from eyaml without showing it in diffs' do
    is_expected.to contain_file('/opt/wd-mycloud-mgmt/ssh/id_ed25519').with(mode: '0600', show_diff: false)
  end

  it 'pins the device host key and dials it through the m2m proxy' do
    is_expected.to contain_file('/opt/wd-mycloud-mgmt/ssh/known_hosts')
      .with_content("wd-mycloud ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQFixtureHostKey\n")
    is_expected.to contain_file(conf).with_content(%r{^Host wd-mycloud-mgmt\n    HostName 127\.0\.0\.1\n    Port 2425\n})
    is_expected.to contain_file(conf).with_content(%r{^    StrictHostKeyChecking yes$})
  end
end

describe 'roles::nas_mgmt_key' do
  let(:hiera_config) { File.expand_path('../fixtures/ssh_hardening_hiera.yaml', __dir__) }
  let(:conf) { '/etc/ssh/ssh_config.d/40-nas-mgmt.conf' }

  it { is_expected.to compile.with_all_deps }

  it 'writes the key from eyaml without showing it in diffs' do
    is_expected.to contain_file('/opt/nas-mgmt/ssh/id_ed25519').with(mode: '0600', show_diff: false)
  end

  it 'pins the nas host key and dials it through the m2m proxy' do
    is_expected.to contain_file('/opt/nas-mgmt/ssh/known_hosts')
      .with_content("nas ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureNasHostKey\n")
    is_expected.to contain_file(conf).with_content(%r{^Host nas-mgmt\n    HostName 127\.0\.0\.1\n    Port 2427\n})
    is_expected.to contain_file(conf).with_content(%r{^    StrictHostKeyChecking yes$})
  end

  it 'authorizes the key on nas for connections from nas itself only' do
    is_expected.to contain_exec('nas-mgmt-key').with(
      unless: %r{\Atest -f \S+/key-check\.sh && },
      environment: [%r{\AOPENVOX_NAS_MGMT_ENTRY=from="192\.168\.50\.80",no-agent-forwarding,no-port-forwarding,no-X11-forwarding ssh-ed25519 \S+ homelab-nas-mgmt\z}],
    )
  end
end

describe 'roles::nas_ziti_tcp_proxy' do
  let(:hiera_config) { File.expand_path('../fixtures/ssh_hardening_hiera.yaml', __dir__) }
  let(:pre_condition) { 'include roles::ziti_tcp_proxy include roles::nas_mgmt_key' }

  it { is_expected.to compile.with_all_deps }

  it 'copies the binary only when nas has a different one' do
    is_expected.to contain_exec('nas-ziti-tcp-proxy-binary').with(
      unless: %r{\Atest -f \S+/binary-check\.sh && },
      require: ['File[/usr/local/libexec/openvox-nas-ziti-tcp-proxy]', 'Class[Roles::Ziti_tcp_proxy]', 'Class[Roles::Nas_mgmt_key]'],
    )
  end
end

describe 'roles::nas_opkssh' do
  let(:hiera_config) { File.expand_path('../fixtures/ssh_hardening_hiera.yaml', __dir__) }
  let(:facts) { { os: { family: 'RedHat', selinux: { enabled: false } } } }
  let(:pre_condition) do
    <<~PP
      class { 'roles::opkssh':
        auth_ids => [{ 'user' => 'root', 'identity' => 'spec-sub', 'issuer' => 'https://auth.mljr.eu' }],
      }
      include roles::nas_mgmt_key
    PP
  end

  it { is_expected.to compile.with_all_deps }

  it 'stages nuc\'s pinned binary and the same /etc/opk content as nuc' do
    is_expected.to contain_file('/var/lib/openvox-nas-opkssh/opkssh')
      .with(source: '/usr/local/bin/opkssh', require: 'Exec[opkssh-binary]')
    is_expected.to contain_file('/var/lib/openvox-nas-opkssh/etc/providers')
      .with_content(%r{^https://auth\.mljr\.eu opkssh 24h$})
    is_expected.to contain_file('/var/lib/openvox-nas-opkssh/etc/auth_id')
      .with_content(%r{^root spec-sub https://auth\.mljr\.eu$})
  end

  it 'applies on nas only when the check fails' do
    is_expected.to contain_exec('nas-opkssh').with(unless: %r{\Atest -f \S+/check\.sh && })
  end
end

describe 'roles::dockhand_environments' do
  let(:hiera_config) { File.expand_path('../fixtures/ssh_hardening_hiera.yaml', __dir__) }
  let(:pre_condition) { 'include roles::nas_mgmt_key' }
  let(:params) do
    {
      environments: {
        'NUC' => { 'host' => '172.17.0.1', 'port' => 2376, 'token_key' => 'vault_hawser_token_nuc' },
        'MLJR - VPS' => { 'host' => '172.17.0.1', 'port' => 2377, 'token_key' => 'vault_hawser_token_mljr' },
      },
    }
  end

  it { is_expected.to compile.with_all_deps }

  it 'writes the wanted rows, tokens included, to a 0600 file without diffs' do
    is_expected.to contain_file('/var/lib/openvox-dockhand-environments/environments.tsv')
      .with(mode: '0600', show_diff: false)
      .with_content(sensitive("MLJR - VPS\t172.17.0.1\t2377\ttest-token-mljr\nNUC\t172.17.0.1\t2376\ttest-token-nuc\n"))
  end

  it 'applies on nas only when the check fails' do
    is_expected.to contain_exec('dockhand-environments').with(unless: %r{\Atest -f \S+/check\.sh && })
  end
end

describe 'roles::wd_mycloud_ziti_proxy' do
  it { is_expected.to compile.with_all_deps }

  it 'installs the pinned tunneler release behind a read-only check' do
    is_expected.to contain_exec('wd-mycloud-ziti-install').with(
      command: %r{install-apply\.sh v\d+\.\d+\.\d+ \h{64}\z},
      unless: %r{\Atest -f \S+/install-check\.sh && /bin/bash \S+/install-check\.sh v\d+\.\d+\.\d+\z},
      timeout: 300,
    )
  end

  it 'starts it from cron and the clamAV boot hook, after the install' do
    {
      'watchdog-script' => 'watchdog',
      'watchdog-cron' => 'cron',
      'clamav-hook' => 'clamav',
    }.each do |action, script|
      is_expected.to contain_exec("wd-mycloud-ziti-#{action}").with(
        command: %r{#{script}-apply\.sh},
        unless: %r{\Atest -f \S+/#{script}-check\.sh && },
        require: 'Exec[wd-mycloud-ziti-install]',
      )
    end
  end

  context 'with a malformed checksum' do
    let(:params) { { sha256: 'abc' } }

    it { is_expected.to compile.and_raise_error(%r{sha256}) }
  end
end

describe 'roles::unraid_host_facts_proxy' do
  let(:hiera_config) { File.expand_path('../fixtures/healthreport_hiera.yaml', __dir__) }

  it { is_expected.to compile.with_all_deps }

  it 'stages facts separately and restricts the forced-command key path' do
    is_expected.to contain_file('/usr/local/libexec/openvox-unraid-host-facts-staging/homelab-facts.py').with(
      mode: '0644',
    )
    is_expected.to contain_exec('unraid-host-facts-script').with(
      command: %r{script-apply\.sh},
      unless: %r{script-check\.sh},
    )
    is_expected.to contain_exec('unraid-host-facts-key').with(
      command: %r{key-apply\.sh},
      unless: %r{key-check\.sh},
    )
    is_expected.to contain_exec('unraid-host-facts-persist').with(
      require: 'Exec[unraid-host-facts-key]',
    )
  end
end

describe 'roles::unraid_aoostar_proxy' do
  # The scripts write to the array, so the class borrows roles::unraid_proxy's
  # array-started precondition.
  let(:pre_condition) { 'include roles::unraid_proxy' }

  it { is_expected.to compile.with_all_deps }

  it 'installs the scripts only after the array is confirmed started' do
    is_expected.to contain_exec('unraid-aoostar-scripts').with(
      command: %r{scripts-apply\.sh},
      unless: %r{scripts-check\.sh},
      require: ['File[/usr/local/libexec/openvox-unraid-aoostar]', 'Exec[unraid-array-started]'],
    )
  end

  it 'merges the start and stop schedule entries after the scripts exist' do
    is_expected.to contain_exec('unraid-aoostar-schedule').with(
      command: %r{schedule-apply\.sh},
      unless: %r{schedule-check\.sh},
      require: 'Exec[unraid-aoostar-scripts]',
    )
  end

  it 'writes controller.env after the scripts, guarded and with secrets in the exec environment' do
    is_expected.to contain_exec('unraid-aoostar-env').with(
      command: %r{env-apply\.sh},
      unless: %r{env-check\.sh},
      logoutput: false,
    )
    is_expected.to contain_exec('unraid-aoostar-env').that_requires('Exec[unraid-aoostar-scripts]')
  end

  it 'ships the controller without embedded credentials' do
    controller = File.read(File.expand_path('../../modules/roles/files/unraid_aoostar/aoostar-controller.sh', __dir__))
    expect(controller).to include('PASSWORD="${PASSWORD:?')
    expect(controller).to include('IMMICH_API_KEY="${IMMICH_API_KEY:?')
    expect(controller).not_to match(/IMMICH_API_KEY="[A-Za-z0-9_-]{20,}"/)
    expect(controller).not_to match(/PASSWORD="[^$"]+"/)
  end
end
