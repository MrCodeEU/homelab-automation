# Reverse proxy fronting real live traffic for every service in this
# repo - Rocky Linux (mljr) only. Host-state management (package,
# firewall, dirs, SELinux, systemd override, service, healthcheck) is
# ported directly from the already-validated, already-live
# migration/spot port (spot/playbooks/caddy.yml), same "prefer spot's
# already-applied logic" precedent as roles::mailcow.
#
# The per-service Caddyfile/conf.d generation IS reimplemented here as
# real EPP templates (templates/caddy/{Caddyfile,snippets.caddy,
# service_snippet.caddy}.epp), ported directly from
# ansible/roles/caddy/templates/*.j2 - not spot's pre-built Go renderer
# (bin/render-caddy) copied in as static content, which is what this
# role did before. Per-service data comes from lookup('services_catalog')
# (data/common.yaml), the same catalog roles::glance's EPP template
# reads, so the catalog only needs updating in one place. Two Jinja
# constructs needed real design decisions to port, not a 1:1 syntax
# swap:
#   - hostvars[service.host]['ansible_host'] (Ansible's cross-host
#     inventory lookup) becomes "${service.host}.tail33930.ts.net" -
#     every host in ansible/inventory/hosts.yml follows that exact
#     ansible_host naming convention, so no per-service host_ip catalog
#     data was needed.
#   - the has_dev_folder Jinja check does a live fileglob against
#     services/<name>/dev/docker-compose.yml on the Ansible controller
#     at render time; Puppet's compiler has no controller-side
#     filesystem to glob against, so it's now a `dev_deploy: true` flag
#     on the 4 catalog entries that actually have a dev/ folder
#     (homepage, service-template, speedtest, ui-showcase) - confirmed
#     against the real filesystem when this was ported. Production is
#     already running with is_staging_deployment effectively true (live
#     dev.*.mljr.eu vhosts exist), so that's this role's default too.
#
# Config is staged then validated then promoted (mirrors spot's own
# stage/validate/promote three-step, not Puppet's native file-resource
# diffing alone) specifically so a bad future re-render is caught by
# `caddy validate` before ever touching the live paths that the running
# process would pick up on reload. Kept unchanged by the EPP rework -
# it's orthogonal to where the content comes from.
class roles::caddy (
  String $work_dir               = '/usr/local/libexec/openvox-caddy',
  String $email                  = 'admin@mljr.eu',
  String $log_path                = '/var/log',
  String $base_path              = '/opt',
  String $domain                 = 'mljr.eu',
  String $roll_size              = '100mb',
  Integer $roll_keep             = 3,
  String $roll_keep_for          = '168h',
  Boolean $roll_uncompressed     = true,
  Boolean $is_staging_deployment = true,
  String $staging_domain_prefix  = 'dev',
  String $staging_host           = 'nuc',
) {
  $services_catalog = lookup('services_catalog')
  $caddy_services = $services_catalog.filter |$svc| { pick($svc['enabled'], true) and 'domain' in $svc }
  $staging_target = "${staging_host}.tail33930.ts.net"

  $auth_user = Sensitive(lookup('vault_caddy_auth_user', { 'default_value' => 'admin' }))
  $auth_hash = Sensitive(lookup('vault_caddy_auth_hash', { 'default_value' => '' }))

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

  # firewalld itself is already ensure=>running/enable=>true in
  # roles::base, which every host running roles::caddy also includes -
  # no need to redeclare the service resource here, just require it.
  firewalld_service { 'caddy-http':
    ensure  => present,
    zone    => 'public',
    service => 'http',
    require => Service['firewalld'],
  }

  firewalld_service { 'caddy-https':
    ensure  => present,
    zone    => 'public',
    service => 'https',
    require => Service['firewalld'],
  }

  firewalld_port { 'caddy-http3':
    ensure   => present,
    zone     => 'public',
    port     => 443,
    protocol => 'udp',
    require  => Service['firewalld'],
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
    require => Exec['caddy-dirs'],
  }

  file { '/etc/caddy/conf.d.openvox-staging/000-snippets.caddy':
    ensure  => file,
    mode    => '0644',
    content => epp('roles/caddy/snippets.caddy.epp', {
      'auth_user' => $auth_user,
      'auth_hash' => $auth_hash,
    }),
    require => File['/etc/caddy/conf.d.openvox-staging'],
  }

  $service_files = $caddy_services.map |$svc| {
    $svc_is_local = $svc['host'] == 'mljr'
    $svc_target_host = $svc_is_local ? { true => 'localhost', default => "${svc['host']}.tail33930.ts.net" }
    file { "/etc/caddy/conf.d.openvox-staging/${svc['name']}.caddy":
      ensure  => file,
      mode    => '0644',
      content => epp('roles/caddy/service_snippet.caddy.epp', {
        'service'               => $svc,
        'target_host'           => $svc_target_host,
        'log_path'              => $log_path,
        'roll_size'             => $roll_size,
        'roll_keep'             => $roll_keep,
        'roll_keep_for'         => $roll_keep_for,
        'roll_uncompressed'     => $roll_uncompressed,
        'is_staging_deployment' => $is_staging_deployment,
        'staging_domain_prefix' => $staging_domain_prefix,
        'staging_target'        => $staging_target,
      }),
      require => File['/etc/caddy/conf.d.openvox-staging'],
    }
  }

  file { '/etc/caddy/Caddyfile.openvox-staging':
    ensure  => file,
    mode    => '0644',
    content => epp('roles/caddy/Caddyfile.epp', {
      'email'             => $email,
      'log_path'          => $log_path,
      'base_path'         => $base_path,
      'domain'            => $domain,
      'roll_size'         => $roll_size,
      'roll_keep'         => $roll_keep,
      'roll_keep_for'     => $roll_keep_for,
      'roll_uncompressed' => $roll_uncompressed,
    }),
    require => Exec['caddy-dirs'],
  }

  exec { 'caddy-validate':
    command => "${work_dir}/validate.sh",
    path    => ['/usr/bin', '/bin'],
    require => [
      File['/etc/caddy/conf.d.openvox-staging'],
      File['/etc/caddy/conf.d.openvox-staging/000-snippets.caddy'],
      File['/etc/caddy/Caddyfile.openvox-staging'],
      Exec['caddy-restart-on-override'],
    ] + $service_files,
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
