require 'spec_helper'

describe 'roles::base' do
  it { is_expected.to compile.with_all_deps }

  it 'keeps optional host changes disabled by default' do
    is_expected.not_to contain_exec('base-swap')
    is_expected.not_to contain_roles__firewalld__port('ssh-breakglass')
    is_expected.not_to contain_file('/etc/systemd/system/cockpit.socket.d/override.conf')
    is_expected.not_to contain_exec('base-docker-prune')
    is_expected.not_to contain_exec('base-reboot-if-needed')
  end

  it 'uses read-only guards for stateful base scripts' do
    {
      'base-timezone' => 'timezone-check.sh',
      'base-dnf-conf' => 'dnf-conf-check.sh',
      'base-fail2ban-remove' => 'fail2ban-remove-check.sh',
    }.each do |title, check_script|
      is_expected.to contain_exec(title).with(
        unless: %r{#{Regexp.escape(check_script)}},
      )
    end
  end

  it 'persists journald data and restarts only after its configuration changes' do
    is_expected.to contain_file('/var/log/journal').with(
      ensure: 'directory',
      owner: 'root',
      group: 'systemd-journal',
      mode: '2755',
    )
    is_expected.to contain_file('/etc/systemd/journald.conf.d/99-persistent.conf').with(
      notify: 'Exec[base-journald-restart]',
      content: %r{Storage=persistent},
    )
    is_expected.to contain_exec('base-journald-restart').with(
      refreshonly: true,
      require: 'File[/var/log/journal]',
    )
  end

  it 'limits the trusted firewall zone to the declared sources' do
    is_expected.to contain_roles__firewalld__zone_sources('trusted').with(
      zone: 'trusted',
      sources: ['100.64.0.0/10'],
    )
  end

  context 'during weekly maintenance' do
    let(:facts) { { openvox_weekly_maintenance: 'true' } }

    it 'enables only the explicitly scheduled prune and reboot actions' do
      is_expected.to contain_exec('base-docker-prune').with(
        timeout: 600,
        require: 'Service[docker]',
      )
      is_expected.to contain_exec('base-reboot-if-needed').with(
        command: %r{reboot-if-needed-apply\.sh},
      )
    end
  end

  context 'with the opt-in SSH break-glass path' do
    let(:params) do
      {
        public_ip: '203.0.113.10',
        tailscale_ip: '100.64.0.10',
        ssh_breakglass_port: 2222,
      }
    end

    it 'opens only the configured TCP port and orders SSH after SELinux' do
      is_expected.to contain_roles__firewalld__port('ssh-breakglass').with(
        ensure: 'present',
        zone: 'public',
        port: 2222,
        protocol: 'tcp',
      )
      is_expected.to contain_exec('base-selinux-breakglass-port').with(
        unless: %r{selinux-breakglass-port-check\.sh},
      )
      is_expected.to contain_exec('base-ssh-breakglass').with(
        unless: %r{ssh-breakglass-check\.sh},
        require: 'Exec[base-selinux-breakglass-port]',
      )
    end
  end

  context 'with the opt-in Cockpit console' do
    let(:params) { { cockpit_console_enabled: true } }

    it 'binds Cockpit to loopback and removes its public firewall service' do
      is_expected.to contain_file('/etc/systemd/system/cockpit.socket.d/override.conf').with(
        content: "[Socket]\nListenStream=\nListenStream=127.0.0.1:9090\n",
        notify: 'Exec[base-cockpit-reload]',
      )
      is_expected.to contain_roles__firewalld__service('cockpit-public').with(
        ensure: 'absent',
        zone: 'public',
        service: 'cockpit',
      )
      is_expected.to contain_exec('base-cockpit-reload').with(
        refreshonly: true,
      )
    end
  end
end
