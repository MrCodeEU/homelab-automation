# ugreen only. UGOS's "SSH from local networks only" setting
# (iptables chain UG_SSH_INPUT) accepts 10/8, 172.16/12 and 192.168/16 and
# drops every other source on port 22 - loopback included. The Ziti router
# on ugreen hosts the ssh service by dialing 127.0.0.1:22 (host-mode
# tunnel, docs/ZITI_ENROLL.md), so without a loopback accept SSH over Ziti
# times out ("dial tcp 127.0.0.1:22: i/o timeout", C1 on 2026-11-07).
#
# The rule opens nothing from outside: only processes on ugreen itself can
# use 127.0.0.0/8. UGOS rebuilds its chains at boot and on firewall changes
# in its UI, so a timer re-checks it (1 min after boot, then every 5 min),
# and every agent run checks it too.
class roles::ugreen_ssh_loopback {
  $script = '/usr/local/sbin/ugreen-ssh-loopback.sh'

  file { $script:
    ensure  => file,
    mode    => '0755',
    content => @(SCRIPT),
      #!/bin/sh
      # Managed by OpenVox (roles::ugreen_ssh_loopback).
      set -eu
      if ! /usr/sbin/iptables -S UG_SSH_INPUT >/dev/null 2>&1; then
        echo "UG_SSH_INPUT not there yet, next timer run retries"
        exit 0
      fi
      /usr/sbin/iptables -C UG_SSH_INPUT -s 127.0.0.0/8 -p tcp --dport 22 -j ACCEPT 2>/dev/null \
        || /usr/sbin/iptables -I UG_SSH_INPUT 1 -s 127.0.0.0/8 -p tcp --dport 22 -j ACCEPT
      | SCRIPT
  }

  file { '/etc/systemd/system/ugreen-ssh-loopback.service':
    ensure  => file,
    mode    => '0644',
    content => @("UNIT"),
      [Unit]
      Description=Accept SSH from loopback in UGOS's UG_SSH_INPUT (Ziti ssh service)

      [Service]
      Type=oneshot
      ExecStart=${script}
      | UNIT
  }

  file { '/etc/systemd/system/ugreen-ssh-loopback.timer':
    ensure  => file,
    mode    => '0644',
    content => @(UNIT),
      [Unit]
      Description=Re-check the SSH loopback accept after boot and UGOS firewall rebuilds

      [Timer]
      OnBootSec=1min
      OnUnitActiveSec=5min

      [Install]
      WantedBy=timers.target
      | UNIT
  }

  exec { 'ugreen-ssh-loopback-daemon-reload':
    command     => '/usr/bin/systemctl daemon-reload',
    refreshonly => true,
    subscribe   => File['/etc/systemd/system/ugreen-ssh-loopback.service', '/etc/systemd/system/ugreen-ssh-loopback.timer'],
  }

  service { 'ugreen-ssh-loopback.timer':
    ensure  => running,
    enable  => true,
    require => Exec['ugreen-ssh-loopback-daemon-reload'],
  }

  exec { 'ugreen-ssh-loopback':
    command => $script,
    unless  => '/usr/sbin/iptables -C UG_SSH_INPUT -s 127.0.0.0/8 -p tcp --dport 22 -j ACCEPT',
    require => File[$script],
  }
}
