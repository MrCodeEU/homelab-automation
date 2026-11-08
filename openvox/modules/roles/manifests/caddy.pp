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
#
# $appsec_enabled (needs $custom_build): adds the global `crowdsec { ... }`
# block to the Caddyfile (LAPI + AppSec on the loopback ports the crowdsec
# container publishes), a root:caddy 0640 /etc/caddy/crowdsec.env with the
# bouncer key (systemd EnvironmentFile, so the key never lands in the
# world-readable Caddyfile), and lets catalog entries opt in with
# `appsec: log|block` (+ `appsec_exclude_paths`). Mode is chosen per vhost:
# Caddy sets X-Appsec-Mode: block for `block`, strips it for `log`; the
# homelab/poc AppSec config only enforces when the header is `block`.
#
# $log_rotate_* : logrotate, not Caddy, rotates /var/log/caddy (see the
# caddy-logrotate block): size, rotated copies kept, their maximum age in
# days, and gzip. Uncompressed by default, as Caddy's roll_uncompressed was.
#
# $ziti_transport (needs $custom_build): catalog entries with
# `ziti_via_caddy: true` are proxied over OpenZiti instead of Tailscale,
# with the ziti reverse_proxy transport built into the custom Caddy
# (services/caddy-poc/ziti-caddy), dialing <name>.<host>.int.mljr.eu:<port>
# as identity caddy-mljr ($ziti_identity, enrolled by
# scripts/ziti-enroll-caddy.sh; services and policy in ziti/tofu/). Off
# switch for all of them at once: false, and those entries go back to
# Tailscale on the next apply. Per entry: drop the catalog flag.
class roles::caddy (
  String $work_dir               = '/usr/local/libexec/openvox-caddy',
  String $email                  = 'admin@mljr.eu',
  String $log_path                = '/var/log',
  String $base_path              = '/opt',
  String $domain                 = 'mljr.eu',
  String $log_rotate_size        = '100M',
  Integer $log_rotate_keep       = 3,
  Integer $log_rotate_max_days   = 7,
  Boolean $log_rotate_compress   = false,
  Boolean $is_staging_deployment = true,
  String $staging_domain_prefix  = 'dev',
  String $staging_host           = 'nuc',
  Optional[Struct[{
    tag    => String[1],
    sha256 => Pattern[/\A[0-9a-f]{64}\z/],
  }]] $custom_build              = undef,
  Boolean $appsec_enabled        = false,
  Boolean $ziti_transport        = false,
  String[1] $ziti_identity          = '/etc/caddy/ziti/caddy-mljr.json',
) {
  if $appsec_enabled and !$custom_build {
    fail('roles::caddy::appsec_enabled needs roles::caddy::custom_build (the packaged Caddy has no AppSec module)')
  }
  if $ziti_transport and !$custom_build {
    fail('roles::caddy::ziti_transport needs roles::caddy::custom_build (the packaged Caddy has no ziti transport)')
  }
  $appsec_key = Sensitive(lookup('vault_crowdsec_caddy_bouncer_key', { 'default_value' => '' }))
  $custom_bin = '/usr/local/bin/caddy-crowdsec'
  $caddy_bin = $custom_build ? {
    undef   => '/usr/bin/caddy',
    default => $custom_bin,
  }
  $services_catalog = lookup('services_catalog')
  # caddy_vhost: false = the domain is listed (dashboards, scans) but DNS points
  # elsewhere, so mljr must not serve it or try to get a certificate for it.
  $caddy_services = $services_catalog.filter |$svc| {
    pick($svc['enabled'], true) and 'domain' in $svc and pick($svc['caddy_vhost'], true)
  }
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
        "CADDY_CUSTOM_ZITI=${ziti_transport}",
      ],
      require     => [File[$work_dir], Exec['caddy-package'], Exec['caddy-selinux']],
      before      => File['/etc/systemd/system/caddy.service.d/override.conf'],
      notify      => Exec['caddy-restart-on-override'],
      # curl retries for up to 120 s, plus one attempt of up to 300 s.
      timeout     => 600,
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

  # The identity file itself is written by scripts/ziti-enroll-caddy.sh, not
  # managed here. If it is missing, validate.sh refuses the staged config
  # (the transport checks the file while provisioning), so the running
  # config stays.
  if $ziti_transport {
    file { dirname($ziti_identity):
      ensure => directory,
      owner  => 'root',
      group  => 'caddy',
      mode   => '0750',
    }
  }

  if $appsec_enabled {
    file { '/etc/caddy/crowdsec.env':
      ensure    => file,
      owner     => 'root',
      group     => 'caddy',
      mode      => '0640',
      content   => Sensitive("CROWDSEC_BOUNCER_KEY=${appsec_key.unwrap}\n"),
      show_diff => false,
      require   => Exec['caddy-dirs'],
      before    => File['/etc/systemd/system/caddy.service.d/override.conf'],
      notify    => Exec['caddy-restart-on-override'],
    }
    $env_override = "EnvironmentFile=/etc/caddy/crowdsec.env\n"
  } else {
    $env_override = ''
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
      ${env_override}${exec_override}
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
    $svc_ziti_identity = ($ziti_transport and pick($svc['ziti_via_caddy'], false)) ? {
      true    => $ziti_identity,
      default => '',
    }
    file { "/etc/caddy/conf.d.openvox-staging/${svc['name']}.caddy":
      ensure  => file,
      mode    => '0644',
      content => epp('roles/caddy/service_snippet.caddy.epp', {
        'service'               => $svc,
        'target_host'           => $svc_target_host,
        'log_path'              => $log_path,
        'is_staging_deployment' => $is_staging_deployment,
        'staging_domain_prefix' => $staging_domain_prefix,
        'staging_target'        => $staging_target,
        'appsec_enabled'        => $appsec_enabled,
        'ziti_identity'         => $svc_ziti_identity,
      }),
      require => File['/etc/caddy/conf.d.openvox-staging'],
    }
  }

  # Caddy's own roll_size rotation renames the log, and SELinux lets httpd_t
  # only create and append in httpd_log_t (no remove_name): every roll failed
  # with "permission denied" and the logs stopped growing at 100 MB, so
  # CrowdSec and Loki saw nothing new for those sites (found 2026-11-08,
  # some stuck since 2026-10-27). logrotate runs as logrotate_t, which may
  # manage these logs, with copytruncate: Caddy keeps its open file and the
  # tailers (CrowdSec, Alloy, GoAccess's caddylog) keep the inode. Rotated
  # copies are <name>.log-<date>, outside the *.log globs the tailers read.
  # The list is explicit so the access-*-size.log files Caddy rotated before
  # this are left to age out.
  $staging_log_names = $is_staging_deployment ? {
    true    => $caddy_services.filter |$svc| { pick($svc['staging'], false) }.map |$svc| { "${svc['name']}-staging" },
    default => [],
  }
  $log_names = ['access', 'deploy'] + $caddy_services.map |$svc| { $svc['name'] } + $staging_log_names
  $log_compress = $log_rotate_compress ? { true => 'compress', default => 'nocompress' }
  $logrotate_paths = $log_names.unique.sort.map |$n| { "${log_path}/caddy/${n}.log" }.join("\n")

  # Not in /etc/caddy: that is httpd_config_t, and logrotate_t may read but
  # not map it ("Error mapping config file", first run 2026-11-08).
  file { '/etc/caddy/logrotate.conf':
    ensure => absent,
  }

  file { '/etc/logrotate-caddy.conf':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => @("LOGROTATE"),
      # Managed by OpenVox (roles::caddy). Run hourly by caddy-logrotate.timer.
      ${logrotate_paths} {
          su caddy caddy
          size ${log_rotate_size}
          rotate ${log_rotate_keep}
          maxage ${log_rotate_max_days}
          copytruncate
          missingok
          notifempty
          dateext
          dateformat -%Y%m%d-%s
          ${log_compress}
      }
      | LOGROTATE
    require => Exec['caddy-dirs'],
  }

  file { '/etc/systemd/system/caddy-logrotate.service':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => "[Unit]\nDescription=Rotate Caddy logs (roles::caddy)\n\n[Service]\nType=oneshot\nExecStart=/usr/sbin/logrotate -s /var/lib/logrotate/caddy.status /etc/logrotate-caddy.conf\n",
    notify  => Exec['caddy-logrotate-systemd-reload'],
  }

  file { '/etc/systemd/system/caddy-logrotate.timer':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => "[Unit]\nDescription=Hourly Caddy log rotation\n\n[Timer]\nOnCalendar=hourly\nPersistent=true\nUnit=caddy-logrotate.service\n\n[Install]\nWantedBy=timers.target\n",
    notify  => Exec['caddy-logrotate-systemd-reload'],
  }

  exec { 'caddy-logrotate-systemd-reload':
    command     => '/usr/bin/systemctl daemon-reload',
    refreshonly => true,
  }

  service { 'caddy-logrotate.timer':
    ensure  => running,
    enable  => true,
    require => [
      File['/etc/logrotate-caddy.conf'],
      File['/etc/systemd/system/caddy-logrotate.service'],
      File['/etc/systemd/system/caddy-logrotate.timer'],
      Exec['caddy-logrotate-systemd-reload'],
    ],
  }

  file { '/etc/caddy/Caddyfile.openvox-staging':
    ensure  => file,
    mode    => '0644',
    content => epp('roles/caddy/Caddyfile.epp', {
      'email'          => $email,
      'log_path'       => $log_path,
      'base_path'      => $base_path,
      'domain'         => $domain,
      'appsec_enabled' => $appsec_enabled,
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
