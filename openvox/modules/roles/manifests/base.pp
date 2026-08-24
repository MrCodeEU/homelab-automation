# System packages, Docker, and host hardening for the rocky hosts (mljr,
# nuc). Port of ansible/roles/base. Complex/stateful logic (dnf.conf
# edits, fail2ban removal, swap, ssh breakglass block, journald flush) is
# real script files under files/base/ rather than Puppet heredocs -
# roles::authelia's port found real, silent Puppet-heredoc-interpolation
# bugs ($1/$2-style bash variables colliding with Puppet's own regex
# match variables), so anything with bash positional/awk-style $N stays
# out of heredocs entirely here. Per-host values are passed to script
# files via `environment`, never embedded as text - avoids that whole bug
# class outright, not just the one instance already hit.
#
# swap/cockpit/ssh-breakglass are real per-host opt-in features
# (mljr only, matches ansible/inventory/hosts.yml's host_vars) - off by
# default here too. docker_prune and the gated reboot are similarly
# off by default, matching the Ansible role's own defaults; the reboot
# script is ported faithfully but deliberately never exercised live by
# this migration (it reboots the host it runs on).
class roles::base (
  String  $timezone              = 'Europe/Vienna',
  Boolean $swap_enabled           = false,
  String  $swap_file_path         = '/swapfile',
  Integer $swap_size_mb           = 2048,
  Optional[String] $public_ip     = undef,
  Optional[Integer] $ssh_breakglass_port = undef,
  String  $tailscale_ip           = '',
  Boolean $cockpit_console_enabled = false,
  String  $domain                 = 'mljr.eu',
  Boolean $docker_prune_enabled   = false,
  Boolean $reboot_if_needed       = false,
  Boolean $reboot_enabled         = true,
) {
  $work_dir = '/usr/local/libexec/openvox-base'

  file { $work_dir:
    ensure  => directory,
    mode    => '0755',
    recurse => true,
    purge   => true,
    source  => 'puppet:///modules/roles/base',
  }

  Exec {
    path    => ['/usr/bin', '/bin', '/usr/sbin', '/sbin'],
    require => File[$work_dir],
  }

  # ==========================================================================
  # System packages
  # ==========================================================================

  exec { 'base-timezone':
    command     => "${work_dir}/timezone-apply.sh",
    unless      => "${work_dir}/timezone-check.sh",
    environment => ["TZ_VALUE=${timezone}"],
  }

  exec { 'base-dnf-conf':
    command => "${work_dir}/dnf-conf-apply.sh",
    unless  => "${work_dir}/dnf-conf-check.sh",
  }

  exec { 'base-dnf-upgrade':
    command => "${work_dir}/dnf-upgrade-apply.sh",
    timeout => 1800,
    require => [File[$work_dir], Exec['base-dnf-conf']],
  }

  package { [
    'acl', 'git', 'curl', 'wget', 'vim', 'htop', 'net-tools',
    'ca-certificates', 'unzip', 'jq', 'tar', 'lsof', 'python3',
    'python3-pip', 'yum-utils',
  ]:
    ensure  => installed,
    require => Exec['base-dnf-upgrade'],
  }

  # ==========================================================================
  # Retired: fail2ban (superseded by CrowdSec)
  # ==========================================================================

  exec { 'base-fail2ban-remove':
    command => "${work_dir}/fail2ban-remove-apply.sh",
    unless  => "${work_dir}/fail2ban-remove-check.sh",
  }

  # ==========================================================================
  # Swapfile (optional per host)
  # ==========================================================================

  if $swap_enabled {
    exec { 'base-swap':
      command     => "${work_dir}/swap-apply.sh",
      unless      => "${work_dir}/swap-check.sh",
      environment => ["SWAP_PATH=${swap_file_path}", "SWAP_SIZE_MB=${swap_size_mb}"],
    }
  }

  # ==========================================================================
  # Docker installation
  #
  # Repo, package, and service are all owned by puppetlabs-docker (already
  # `puppet module install`-ed by scripts/install-openvox.sh, just never
  # wired in until now) - its RedHat defaults already point at
  # download.docker.com/linux/rhel, same repo the old hand-rolled
  # yum-config-manager exec targeted. buildx/compose-plugin aren't part of
  # the module's own dependent_packages list, so they stay a plain
  # package{} requiring Class['docker'].
  #
  # python3-docker (previously installed here) is gone: it existed only so
  # Ansible's community.docker modules had a Python client to shell out to.
  # Ansible is retired, nothing in this repo imports it anymore.
  # ==========================================================================

  include docker

  package { ['docker-buildx-plugin', 'docker-compose-plugin']:
    ensure  => installed,
    require => Class['docker'],
  }

  # ==========================================================================
  # Docker Hub login (prevents 401s / anonymous rate limits)
  # ==========================================================================

  $dockerhub_user = lookup('vault_dockerhub_username', { 'default_value' => '' })
  $dockerhub_pass = Sensitive(lookup('vault_dockerhub_token', { 'default_value' => '' }))

  if $dockerhub_user != '' and $dockerhub_pass.unwrap != '' {
    docker::registry { 'https://index.docker.io/v1/':
      username => $dockerhub_user,
      password => $dockerhub_pass.unwrap,
      require  => Service['docker'],
    }
  }

  # ==========================================================================
  # Firewall (Tailscale internal network)
  # ==========================================================================

  service { 'firewalld':
    ensure => running,
    enable => true,
  }

  exec { 'base-firewalld-tailscale':
    command => "${work_dir}/firewalld-tailscale-apply.sh",
    unless  => "${work_dir}/firewalld-tailscale-check.sh",
    require => Service['firewalld'],
  }

  # ==========================================================================
  # SSH deception cutover (opt-in, mljr only)
  # ==========================================================================

  if $public_ip and $ssh_breakglass_port {
    firewalld_port { 'ssh-breakglass':
      ensure   => present,
      zone     => 'public',
      port     => $ssh_breakglass_port,
      protocol => 'tcp',
      require  => Service['firewalld'],
    }

    exec { 'base-selinux-breakglass-port':
      command     => "${work_dir}/selinux-breakglass-port-apply.sh",
      unless      => "${work_dir}/selinux-breakglass-port-check.sh",
      environment => ["BREAKGLASS_PORT=${ssh_breakglass_port}"],
    }

    exec { 'base-ssh-breakglass':
      command     => "${work_dir}/ssh-breakglass-apply.sh",
      unless      => "${work_dir}/ssh-breakglass-check.sh",
      environment => [
        "TAILSCALE_IP=${tailscale_ip}",
        "PUBLIC_IP=${public_ip}",
        "BREAKGLASS_PORT=${ssh_breakglass_port}",
      ],
      require     => Exec['base-selinux-breakglass-port'],
    }
  }

  # ==========================================================================
  # Cockpit break-glass console (opt-in, mljr only) - loopback-only,
  # fronted by Caddy's cockpit.<domain> vhost (Authelia-gated).
  # ==========================================================================

  if $cockpit_console_enabled {
    file { '/etc/systemd/system/cockpit.socket.d':
      ensure => directory,
      mode   => '0755',
    }

    file { '/etc/systemd/system/cockpit.socket.d/override.conf':
      ensure  => file,
      mode    => '0644',
      content => "[Socket]\nListenStream=\nListenStream=127.0.0.1:9090\n",
      require => File['/etc/systemd/system/cockpit.socket.d'],
      notify  => Exec['base-cockpit-reload'],
    }

    file { '/etc/cockpit/cockpit.conf':
      ensure  => file,
      mode    => '0644',
      content => "[WebService]\nOrigins = https://cockpit.${domain} wss://cockpit.${domain}\nProtocolHeader = X-Forwarded-Proto\n",
      notify  => Exec['base-cockpit-reload'],
    }

    exec { 'base-cockpit-reload':
      command     => 'systemctl daemon-reload && systemctl restart cockpit.socket',
      provider    => shell,
      refreshonly => true,
    }

    service { 'cockpit.socket':
      ensure  => running,
      enable  => true,
      require => File['/etc/systemd/system/cockpit.socket.d/override.conf'],
    }

    firewalld_service { 'cockpit-public':
      ensure  => absent,
      zone    => 'public',
      service => 'cockpit',
      require => Service['firewalld'],
    }
  }

  # ==========================================================================
  # Docker prune (opt-in maintenance)
  # ==========================================================================

  if $docker_prune_enabled {
    exec { 'base-docker-prune':
      command => "${work_dir}/docker-prune-apply.sh",
      timeout => 600,
      require => Service['docker'],
    }
  }

  # ==========================================================================
  # Persistent journald
  # ==========================================================================

  file { '/var/log/journal':
    ensure => directory,
    owner  => 'root',
    group  => 'systemd-journal',
    mode   => '2755',
  }

  file { '/etc/systemd/journald.conf.d':
    ensure => directory,
    owner  => 'root',
    group  => 'root',
    mode   => '0755',
  }

  file { '/etc/systemd/journald.conf.d/99-persistent.conf':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => "# Managed by OpenVox (roles::base).\n# Without this, Storage=auto keeps logs in /run and a reboot erases them.\n[Journal]\nStorage=persistent\n",
    require => File['/etc/systemd/journald.conf.d'],
    notify  => Exec['base-journald-restart'],
  }

  exec { 'base-journald-restart':
    command     => "${work_dir}/journald-restart-apply.sh",
    refreshonly => true,
    require     => File['/var/log/journal'],
  }

  # ==========================================================================
  # Gated reboot (opt-in, off by default - never triggered by this
  # migration's own verification runs)
  # ==========================================================================

  if $reboot_if_needed and $reboot_enabled {
    exec { 'base-reboot-if-needed':
      command => "${work_dir}/reboot-if-needed-apply.sh",
    }
  }
}
