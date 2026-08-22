# Reverse proxy fronting real live traffic for every service in this
# repo - Rocky Linux (mljr) only. Logic-ported directly from the
# already-validated, already-live migration/spot port
# (spot/playbooks/caddy.yml, commit b845bdf) rather than re-deriving
# from ansible/roles/caddy's ~565-line tasks/main.yml, same "prefer
# spot's already-applied logic" precedent as roles::mailcow.
#
# The actual per-service Caddyfile/conf.d generation (the Jinja-template
# equivalent covering ~40 services) is NOT reimplemented in Puppet DSL -
# spot's own port already delegates that to a pure-Go renderer
# (spot/tools/render-caddy, validated byte-exact against live output).
# Reusing that renderer's OUTPUT as static content
# (files/caddy_rendered/) is the same "trust an already-validated
# external artifact rather than re-derive it" call this migration made
# for roles::glance's Jinja output. Re-run `bin/render-caddy` and copy
# its output into files/caddy_rendered/ whenever the services catalog
# changes - this role does not regenerate it itself.
#
# Config is staged then validated then promoted (mirrors spot's own
# stage/validate/promote three-step, not Puppet's native file-resource
# diffing alone) specifically so a bad future re-render is caught by
# `caddy validate` before ever touching the live paths that the running
# process would pick up on reload.
class roles::caddy (
  String $work_dir = '/usr/local/libexec/openvox-caddy',
) {
  file { $work_dir:
    ensure  => directory,
    mode    => '0755',
    recurse => true,
    purge   => true,
    source  => 'puppet:///modules/roles/caddy',
  }

  exec { 'caddy-package':
    command => "${work_dir}/package-apply.sh",
    unless  => "${work_dir}/package-check.sh",
    path    => ['/usr/bin', '/bin'],
    require => File[$work_dir],
    timeout => 300,
  }

  exec { 'caddy-stop-conflicting-webservers':
    command => "${work_dir}/stopwebservers-apply.sh",
    unless  => "${work_dir}/stopwebservers-check.sh",
    path    => ['/usr/bin', '/bin'],
    require => File[$work_dir],
  }

  exec { 'caddy-legacy-container':
    command => "${work_dir}/legacy-container-apply.sh",
    unless  => "${work_dir}/legacy-container-check.sh",
    path    => ['/usr/bin', '/bin'],
    require => File[$work_dir],
  }

  exec { 'caddy-firewall':
    command => "${work_dir}/firewall-apply.sh",
    unless  => "${work_dir}/firewall-check.sh",
    path    => ['/usr/bin', '/bin'],
    require => File[$work_dir],
  }

  exec { 'caddy-dirs':
    command => "${work_dir}/dirs-apply.sh",
    unless  => "${work_dir}/dirs-check.sh",
    path    => ['/usr/bin', '/bin'],
    require => [File[$work_dir], Exec['caddy-package']],
  }

  exec { 'caddy-selinux':
    command => "${work_dir}/selinux-apply.sh",
    unless  => "${work_dir}/selinux-check.sh",
    path    => ['/usr/bin', '/bin'],
    require => Exec['caddy-dirs'],
    timeout => 180,
  }

  file { '/etc/systemd/system/caddy.service.d':
    ensure  => directory,
    mode    => '0755',
    require => Exec['caddy-package'],
  }

  file { '/etc/systemd/system/caddy.service.d/override.conf':
    ensure  => file,
    mode    => '0644',
    content => @(OVERRIDE),
      # Systemd override for Caddy
      # Ensures proper network setup and DNS resolution for Tailscale

      [Unit]
      # Wait for network to be fully online (including Tailscale)
      After=network-online.target tailscaled.service
      Wants=network-online.target

      [Service]
      # Restart on failure
      Restart=on-failure
      RestartSec=5s

      # Ensure DNS resolution works properly
      # This allows Caddy to resolve Tailscale hostnames
      Environment="GODEBUG=netdns=go"

      # The upstream unit enables ProtectSystem=full. Keep Caddy's log directory
      # explicitly writable so timberjack can rename files during log rotation.
      ReadWritePaths=/var/log/caddy
      | OVERRIDE
    require => File['/etc/systemd/system/caddy.service.d'],
    notify  => Exec['caddy-restart-on-override'],
  }

  exec { 'caddy-restart-on-override':
    command     => '/usr/bin/systemctl daemon-reload && /usr/bin/systemctl restart caddy',
    refreshonly => true,
    require     => Exec['caddy-dirs'],
  }

  file { '/etc/caddy/conf.d.openvox-staging':
    ensure  => directory,
    mode    => '0755',
    recurse => true,
    purge   => true,
    source  => 'puppet:///modules/roles/caddy_rendered/conf.d',
    require => Exec['caddy-dirs'],
  }

  file { '/etc/caddy/Caddyfile.openvox-staging':
    ensure  => file,
    mode    => '0644',
    source  => 'puppet:///modules/roles/caddy_rendered/Caddyfile',
    require => Exec['caddy-dirs'],
  }

  exec { 'caddy-validate':
    command => "${work_dir}/validate.sh",
    path    => ['/usr/bin', '/bin'],
    require => [
      File['/etc/caddy/conf.d.openvox-staging'],
      File['/etc/caddy/Caddyfile.openvox-staging'],
      Exec['caddy-restart-on-override'],
    ],
  }

  exec { 'caddy-promote':
    command => "${work_dir}/promote-apply.sh",
    unless  => "${work_dir}/promote-check.sh",
    path    => ['/usr/bin', '/bin'],
    require => Exec['caddy-validate'],
  }

  exec { 'caddy-service':
    command => "${work_dir}/service-apply.sh",
    unless  => "${work_dir}/service-check.sh",
    path    => ['/usr/bin', '/bin'],
    require => Exec['caddy-promote'],
  }

  exec { 'caddy-healthcheck':
    command => "${work_dir}/healthcheck.sh",
    path    => ['/usr/bin', '/bin'],
    require => Exec['caddy-service'],
  }
}
