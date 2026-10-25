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
#     filesystem to glob against, so it's now a `staging: true` flag
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
#
# $custom_build (hiera, optional): { tag, sha256 } of a release built by
# .github/workflows/caddy-build.yml (Caddy + CrowdSec bouncer + AppSec). When
# set, that binary is installed to /usr/local/bin/caddy-crowdsec and the
# systemd unit runs it instead of the COPR package's /usr/bin/caddy, which
# stays installed. Unsetting it is the rollback: the next apply drops the
# ExecStart override, removes the binary and restarts Caddy on the rpm.
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
  Optional[Struct[{
    tag    => String[1],
    sha256 => Pattern[/\A[0-9a-f]{64}\z/],
  }]] $custom_build              = undef,
) {
  $custom_bin = '/usr/local/bin/caddy-crowdsec'
  $caddy_bin = $custom_build ? {
    undef   => '/usr/bin/caddy',
    default => $custom_bin,
  }
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
  roles::firewalld::service { 'caddy-http':
    ensure  => present,
    zone    => 'public',
    service => 'http',
  }

  roles::firewalld::service { 'caddy-https':
    ensure  => present,
    zone    => 'public',
    service => 'https',
  }

  roles::firewalld::port { 'caddy-http3':
    ensure   => present,
    zone     => 'public',
    port     => 443,
    protocol => 'udp',
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

  if $custom_build {
    exec { 'caddy-custom-binary':
      command     => "${work_dir}/custom-binary-apply.sh",
      # Read-only guard, inline on purpose: under --noop the scripts in
      # ${work_dir} are not written yet on the run that introduces them, and a
      # guard that points at a missing file fails the whole noop. Installed
      # means: the pinned checksum and the packaged binary's SELinux type.
      unless      => "test \"$(sha256sum ${custom_bin} | cut -d' ' -f1)\" = ${custom_build['sha256']} && stat -c %C ${custom_bin} | grep -q httpd_exec_t",
      provider    => shell,
      path        => ['/usr/sbin', '/usr/bin', '/sbin', '/bin'],
      environment => [
        "CADDY_CUSTOM_BIN=${custom_bin}",
        "CADDY_CUSTOM_TAG=${custom_build['tag']}",
        "CADDY_CUSTOM_SHA256=${custom_build['sha256']}",
      ],
      require     => [File[$work_dir], Exec['caddy-package'], Exec['caddy-selinux']],
      before      => File['/etc/systemd/system/caddy.service.d/override.conf'],
      notify      => Exec['caddy-restart-on-override'],
      timeout     => 400,
    }
    $exec_override = @("EXEC")
      # Custom build with the CrowdSec bouncer and AppSec (roles::caddy::custom_build).
      # The first, empty assignment clears the ExecStart/ExecReload of the packaged unit.
      ExecStart=
      ExecStart=${custom_bin} run --environ --config /etc/caddy/Caddyfile
      ExecReload=
      ExecReload=${custom_bin} reload --config /etc/caddy/Caddyfile --force
      |- EXEC
  } else {
    $exec_override = ''
    file { $custom_bin:
      ensure => absent,
      notify => Exec['caddy-restart-on-override'],
    }
  }

  file { '/etc/systemd/system/caddy.service.d':
    ensure  => directory,
    mode    => '0755',
    require => Exec['caddy-package'],
  }

  file { '/etc/systemd/system/caddy.service.d/override.conf':
    ensure  => file,
    mode    => '0644',
    content => @("OVERRIDE"),
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
      ${exec_override}
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
    command     => "${work_dir}/validate.sh",
    path        => ['/usr/bin', '/bin'],
    environment => ["CADDY_BIN=${caddy_bin}"],
    require     => [
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
