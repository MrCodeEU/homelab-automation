# Port of ansible/roles/grafana-alloy (cross-checked against its
# already-verified migration/spot port, commit f564e59). rocky (mljr,
# nuc) + ugreen - nas/wd-mycloud stay on services/nas-alloy and
# roles/wd-mycloud-node-exporter respectively, untouched by this role.
#
# config.alloy.epp is a direct EPP port of config.alloy.j2 (5 host-
# conditional blocks: mljr-only crowdsec scrape, ugreen+nuc smartctl
# scrape, nuc-only homeassistant scrape gated on a token being set,
# nuc-only wd_mycloud remote scrape, mljr-only caddy log path).
# Rendered output verified byte-exact against all 3 real production
# config.alloy files before writing this class.
#
# Real idempotent container management, not roles::glance's
# always-recreate shortcut: recreates only when the config content
# changed (tracked via a stored hash marker) or the pulled image
# digest differs from what's running - same logic already proven live
# by the spot port. NOTE: since the stored hash marker is new
# bookkeeping this port introduces, the very first real apply always
# recreates the container once even though production's existing
# config already matches byte-exact - expected, one-time, low-risk for
# a monitoring agent (brief metrics/log gap, no user-facing service).
class roles::grafana_alloy (
  String $hostname,
  String $docker_root         = '/var/lib/docker',
  # Rocky hosts get python3-docker from roles::base's own
  # base-python3-docker exec (already included ahead of this class on
  # both mljr/nuc in site.pp) - only ugreen (no roles::base) needs its
  # own install here. Community.docker's actual Ansible task installs
  # this everywhere for self-containment, but declaring the same
  # dependency twice in one Puppet catalog would be redundant, not
  # self-contained.
  Boolean $manage_docker_sdk  = false,
  # Both hardcode nuc's own Tailscale IP - same "the fixed target host
  # is stable, no need to look it up generically" call already made by
  # roles::host_facts_endpoint's $client_tailscale_ip default.
  String $prometheus_remote_write_url = 'http://100.100.10.1:19090/api/v1/write',
  String $loki_push_url               = 'http://100.100.10.1:3100/loki/api/v1/push',
) {
  if $manage_docker_sdk {
    package { 'python3-docker':
      ensure => installed,
    }
  }

  # The EPP template's own $hostname == 'nuc' gate means this is a
  # harmless no-op lookup on mljr/ugreen - simpler to always resolve it
  # here (same self-lookup convention as
  # roles::hetrixtools_agent/roles::crowdsec_firewall_bouncer) than to
  # thread a per-host override through site.pp. Empty string (the
  # secret not being set) becomes undef, not Sensitive(''), matching
  # the Ansible template's own truthy check
  # (`secrets.homeassistant.token is defined and secrets.homeassistant.token`) -
  # an empty Sensitive value would still satisfy the EPP's NotUndef
  # gate and wrongly emit the homeassistant scrape block with a blank
  # bearer_token.
  $homeassistant_token_raw = lookup('vault_homeassistant_token', { 'default_value' => '' })
  $homeassistant_token = $homeassistant_token_raw ? {
    ''      => undef,
    default => Sensitive($homeassistant_token_raw),
  }

  $work_dir = '/usr/local/libexec/openvox-grafana-alloy'

  file { $work_dir:
    ensure  => directory,
    mode    => '0755',
    recurse => true,
    purge   => true,
    source  => 'puppet:///modules/roles/grafana_alloy',
  }

  file { ['/opt/grafana-alloy', '/opt/grafana-alloy/data']:
    ensure => directory,
    mode   => '0755',
  }

  # Sensitive-wrapped so the homeassistant bearer token never leaks
  # into noop/--show_diff output or logs - same precedent as
  # roles::authelia/roles::crowdsec_firewall_bouncer's own config files.
  file { '/opt/grafana-alloy/config.alloy':
    ensure  => file,
    mode    => '0644',
    content => Sensitive(epp('roles/grafana_alloy/config.alloy.epp', {
      'hostname'                    => $hostname,
      'prometheus_remote_write_url' => $prometheus_remote_write_url,
      'loki_push_url'               => $loki_push_url,
      'homeassistant_token'         => $homeassistant_token,
    })),
    require => File['/opt/grafana-alloy'],
  }

  exec { 'grafana-alloy-run':
    command     => "${work_dir}/run-apply.sh",
    unless      => "${work_dir}/run-check.sh",
    path        => ['/usr/bin', '/bin'],
    environment => ["ALLOY_DOCKER_ROOT=${docker_root}"],
    require     => [File['/opt/grafana-alloy/config.alloy'], File['/opt/grafana-alloy/data'], File[$work_dir]],
  }
}
