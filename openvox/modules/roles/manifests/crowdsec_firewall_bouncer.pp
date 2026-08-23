# Port of ansible/roles/crowdsec-firewall-bouncer (cross-checked against
# its already-verified migration/spot port, commit ad5e19d). mljr only -
# host-level nftables remediation agent reading decisions from the
# Dockerized CrowdSec LAPI (roles::services' own "crowdsec" catalog
# entry) over 127.0.0.1:8088 and blocking/unblocking IPs at the OS
# firewall layer.
#
# Config file holds the bouncer's API key in plaintext (0600, same as
# the Ansible role) - vault_crowdsec_firewall_bouncer_key already exists
# in openvox/data/common.eyaml (roles::services' own crowdsec catalog
# entry already reads it for the LAPI side of this same handshake).
class roles::crowdsec_firewall_bouncer (
  Sensitive[String] $api_key = Sensitive(lookup('vault_crowdsec_firewall_bouncer_key', { 'default_value' => '' })),
) {
  $work_dir = '/usr/local/libexec/openvox-crowdsec-firewall-bouncer'

  file { $work_dir:
    ensure  => directory,
    mode    => '0755',
    recurse => true,
    purge   => true,
    source  => 'puppet:///modules/roles/crowdsec_firewall_bouncer',
  }

  Exec {
    path => ['/usr/bin', '/bin'],
  }

  # Same reasoning as the Ansible role's own `when: not ansible_check_mode`
  # wait_for() - give the Dockerized LAPI time to come up before the
  # bouncer package tries to reach it. Read-only, no state to converge,
  # so it always runs (no unless) same as roles::mailcow's own
  # unconditional health-check exec.
  exec { 'crowdsec-firewall-bouncer-wait-lapi':
    command => "${work_dir}/wait-lapi.sh",
    require => File[$work_dir],
  }

  yumrepo { 'crowdsec_crowdsec':
    descr           => 'crowdsec_crowdsec',
    baseurl         => 'https://packagecloud.io/crowdsec/crowdsec/rpm_any/rpm_any/$basearch',
    repo_gpgcheck   => 1,
    gpgcheck        => 1,
    enabled         => 1,
    # A Puppet Array here only keeps the first element once yumrepo
    # writes the .repo file (confirmed live) - the multi-value INI
    # continuation syntax needs one real string with embedded
    # newline+indent, matching the file already live in production
    # byte-for-byte (7-space indent under "gpgkey=").
    gpgkey          => "https://packagecloud.io/crowdsec/crowdsec/gpgkey\n       https://packagecloud.io/crowdsec/crowdsec/gpgkey/crowdsec-crowdsec-EDE2C695EC9A5A5C.pub.gpg\n       https://packagecloud.io/crowdsec/crowdsec/gpgkey/crowdsec-crowdsec-C822EDD6B39954A1.pub.gpg\n       https://packagecloud.io/crowdsec/crowdsec/gpgkey/crowdsec-crowdsec-FED78314A2468CCF.pub.gpg",
    sslverify       => 1,
    sslcacert       => '/etc/pki/tls/certs/ca-bundle.crt',
    metadata_expire => '3600',
  }

  package { 'crowdsec-firewall-bouncer-nftables':
    ensure  => installed,
    require => Yumrepo['crowdsec_crowdsec'],
  }

  file { '/etc/crowdsec/bouncers':
    ensure  => directory,
    mode    => '0750',
    require => Package['crowdsec-firewall-bouncer-nftables'],
  }

  # Content wrapped in Sensitive() so the API key never appears in
  # noop/--show_diff output or logs - same precedent as
  # roles::authelia's own config_content, since a plain interpolated
  # String here (even built from a Sensitive[String] param) is not
  # itself redacted unless re-wrapped for the file resource.
  file { '/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml':
    ensure  => file,
    mode    => '0600',
    content => Sensitive("api_url: http://127.0.0.1:8088/\napi_key: ${api_key.unwrap}\nmode: nftables\nupdate_frequency: 10s\nlog_mode: file\nlog_dir: /var/log\nlog_level: info\ndeny_action: DROP\ndeny_log: false\nnftables:\n  ipv4:\n    enabled: true\n    set-only: false\n    table: crowdsec\n    chain: crowdsec-chain\n  ipv6:\n    enabled: true\n    set-only: false\n    table: crowdsec6\n    chain: crowdsec6-chain\n"),
    require => File['/etc/crowdsec/bouncers'],
  }

  service { 'crowdsec-firewall-bouncer':
    ensure    => running,
    enable    => true,
    subscribe => File['/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml'],
    require   => [
      Exec['crowdsec-firewall-bouncer-wait-lapi'],
      Package['crowdsec-firewall-bouncer-nftables'],
    ],
  }

  exec { 'crowdsec-firewall-bouncer-verify-active':
    command => "${work_dir}/verify-active.sh",
    require => Service['crowdsec-firewall-bouncer'],
  }
}
