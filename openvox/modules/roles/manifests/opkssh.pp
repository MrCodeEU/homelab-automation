# SSH login through the IdP with opkssh (OpenPubkey SSH), Phase 3 C14
# (docs/ZERO_TRUST_PLAN.md, "SSH auth"). `opkssh login` on a client signs
# in at Authelia and creates a short-lived SSH key bound to the ID token;
# sshd hands every offered key to `opkssh verify` (AuthorizedKeysCommand),
# which checks the token against the issuer's public keys and $auth_ids.
# The usual authorized_keys files (break-glass keys) keep working: sshd
# tries them first, and a failing command only denies that one key.
#
# Does what opkssh's install-linux.sh does, so OpenVox owns it: the
# opksshuser system account, the pinned binary, the SELinux module, the
# /etc/opk files with the owners and modes opkssh insists on, the JWKS
# cache (logins keep working for $cache_fallback while the issuer is
# unreachable) and the sshd drop-in. No home-directory policies: the sudo
# rule they need is left out, only /etc/opk/auth_id counts.
#
# The verifier reaches the issuer (auth.mljr.eu on mljr) over the public
# internet, so nothing here depends on Tailscale.
class roles::opkssh (
  String $version = 'v0.19.2',
  # sha256 of opkssh-linux-amd64 from the GitHub release (asset digest).
  Pattern[/\A[0-9a-f]{64}\z/] $sha256 = 'e799b780d5477e8d986a2e6784773ebb2451d860dd842d23e271baf88aee2da3',
  # "<issuer> <client id> <expiration policy>" lines for /etc/opk/providers.
  Array[String[1]] $providers = ['https://auth.mljr.eu opkssh 24h'],
  # Who may log in as whom. Match on the OIDC sub, not the email: two
  # Authelia users share admin@mljr.eu.
  Array[Struct[{ user => String[1], identity => String[1], issuer => String[1] }]] $auth_ids = [],
  String $cache_max_age = '1h',
  String $cache_fallback = '24h',
) {
  $bin       = '/usr/local/bin/opkssh'
  $libexec   = '/usr/local/libexec/opkssh'
  $cache_dir = '/var/cache/opkssh'

  group { 'opksshuser':
    ensure => present,
    system => true,
  }

  user { 'opksshuser':
    ensure     => present,
    system     => true,
    gid        => 'opksshuser',
    shell      => '/sbin/nologin',
    home       => '/nonexistent',
    managehome => false,
    require    => Group['opksshuser'],
  }

  file { $libexec:
    ensure => directory,
    owner  => 'root',
    group  => 'root',
    mode   => '0755',
  }

  file { "${libexec}/opkssh.te":
    ensure => file,
    mode   => '0644',
    source => 'puppet:///modules/roles/opkssh/opkssh.te',
  }

  file { "${libexec}/selinux-install.sh":
    ensure => file,
    mode   => '0755',
    source => 'puppet:///modules/roles/opkssh/selinux-install.sh',
  }

  exec { 'opkssh-selinux':
    command   => "${libexec}/selinux-install.sh",
    unless    => '/usr/sbin/semodule -l | /usr/bin/grep -qx opkssh',
    path      => ['/usr/sbin', '/usr/bin', '/sbin', '/bin'],
    subscribe => File["${libexec}/opkssh.te"],
    require   => File["${libexec}/selinux-install.sh"],
    timeout   => 300,
  }

  # Download, check against the pinned digest, then install. Guard inline
  # (noop-safe): installed means the pinned checksum.
  exec { 'opkssh-binary':
    command  => "set -e; t=\$(mktemp); trap 'rm -f \$t' EXIT
      curl -fsSL -o \$t https://github.com/openpubkey/opkssh/releases/download/${version}/opkssh-linux-amd64
      echo '${sha256}  '\$t | sha256sum -c --quiet
      install -m 0755 -o root -g opksshuser \$t ${bin}
      restorecon ${bin} 2>/dev/null || true",
    unless   => "test \"$(sha256sum ${bin} 2>/dev/null | cut -d' ' -f1)\" = ${sha256}",
    provider => shell,
    path     => ['/usr/sbin', '/usr/bin', '/sbin', '/bin'],
    require  => Group['opksshuser'],
    timeout  => 300,
  }

  file { ['/etc/opk', '/etc/opk/policy.d']:
    ensure  => directory,
    owner   => 'root',
    group   => 'opksshuser',
    mode    => '0750',
    require => Group['opksshuser'],
  }

  file { '/etc/opk/providers':
    ensure  => file,
    owner   => 'root',
    group   => 'opksshuser',
    mode    => '0640',
    content => "# Managed by OpenVox (roles::opkssh)\n# issuer client-id expiration-policy\n${providers.join("\n")}\n",
  }

  $auth_id_lines = $auth_ids.map |$a| { "${a['user']} ${a['identity']} ${a['issuer']}" }
  file { '/etc/opk/auth_id':
    ensure  => file,
    owner   => 'root',
    group   => 'opksshuser',
    mode    => '0640',
    content => "# Managed by OpenVox (roles::opkssh)\n# principal identity(sub) issuer\n${auth_id_lines.map |$l| { "${l}\n" }.join}",
  }

  file { '/etc/opk/config.yml':
    ensure  => file,
    owner   => 'root',
    group   => 'opksshuser',
    mode    => '0640',
    content => @("CFG"),
      # Managed by OpenVox (roles::opkssh)
      ---
      cache:
        base_dir: ${cache_dir}
        max_age: ${cache_max_age}
        fallback_max_age: ${cache_fallback}
      | CFG
  }

  file { $cache_dir:
    ensure  => directory,
    owner   => 'opksshuser',
    group   => 'opksshuser',
    mode    => '0700',
    require => User['opksshuser'],
  }

  exec { 'opkssh-cache-label':
    command  => "semanage fcontext -a -t opkssh_cache_t '${cache_dir}(/.*)?' 2>/dev/null || semanage fcontext -m -t opkssh_cache_t '${cache_dir}(/.*)?'; restorecon -R ${cache_dir}",
    unless   => "stat -c %C ${cache_dir} | grep -q opkssh_cache_t",
    provider => shell,
    path     => ['/usr/sbin', '/usr/bin', '/sbin', '/bin'],
    require  => [File[$cache_dir], Exec['opkssh-selinux']],
  }

  # Last: sshd only calls opkssh once everything above is in place.
  file { '/etc/ssh/sshd_config.d/10-openvox-opkssh.conf':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0600',
    content => "# Managed by OpenVox (roles::opkssh)\nAuthorizedKeysCommand ${bin} verify %u %k %t\nAuthorizedKeysCommandUser opksshuser\n",
    require => [
      Exec['opkssh-binary', 'opkssh-selinux', 'opkssh-cache-label'],
      File['/etc/opk/providers', '/etc/opk/auth_id', '/etc/opk/config.yml'],
      User['opksshuser'],
    ],
    notify  => Exec['opkssh-sshd-reload'],
  }

  exec { 'opkssh-sshd-reload':
    command     => '/bin/sh -c "/usr/sbin/sshd -t && (systemctl reload sshd 2>/dev/null || systemctl reload ssh)"',
    path        => ['/usr/sbin', '/usr/bin', '/bin'],
    refreshonly => true,
  }
}
