# Dockhand's remote environments (Dockhand runs on nas, Unraid template):
# host, port and Hawser token of each, so they need no manual setup in the UI
# after a token rotation or an address change. Runs on nuc and drives nas
# over `ssh nas-mgmt` (roles::nas_mgmt_key), like the other nas classes.
#
# $environments: Dockhand environment name => host, port and the eyaml key
# of that Hawser's token (vault_hawser_token_<host>, same value as in that
# host's own eyaml for roles::hawser_agent). The rows must exist (created
# once in the UI); this only sets them. Host and port are ziti-proxy-nas's
# listeners on docker0 (services/ziti-proxy-nas, ziti/tofu/hawser.tf).
#
# $oidc_secret_key: eyaml key of the client secret of the Authelia OIDC
# client "dockhand" (authelia_oidc_clients, common.yaml). When set, the
# login provider "Authelia" is created or updated in Dockhand (oidc.tsv):
# Authelia group admins become Dockhand admins. Dockhand encrypts the
# secret at its next start, like the Hawser tokens.
class roles::dockhand_environments (
  Hash[String[1], Struct[{
    host      => Stdlib::Host,
    port      => Stdlib::Port,
    token_key => Pattern[/\Avault_[a-z0-9_]+\z/],
  }]] $environments = {},
  Optional[Pattern[/\Avault_[a-z0-9_]+\z/]] $oidc_secret_key = undef,
  String $domain = 'mljr.eu',
  String $work_dir = '/usr/local/libexec/openvox-dockhand-environments',
  String $data_dir = '/var/lib/openvox-dockhand-environments',
) {
  # One line per environment: name, host, port, token (tab-separated).
  $lines = $environments.keys.sort.map |$name| {
    $e = $environments[$name]
    "${name}\t${e['host']}\t${e['port']}\t${Sensitive(lookup($e['token_key'])).unwrap}\n"
  }

  file { $data_dir:
    ensure => directory,
    owner  => 'root',
    group  => 'root',
    mode   => '0700',
  }

  file { "${data_dir}/environments.tsv":
    ensure    => file,
    owner     => 'root',
    group     => 'root',
    mode      => '0600',
    content   => Sensitive($lines.join),
    show_diff => false,
  }

  # Issuer, client id, redirect URI and secret (tab-separated); empty when
  # $oidc_secret_key is unset, which leaves Dockhand's OIDC settings alone.
  $oidc_line = $oidc_secret_key ? {
    undef   => '',
    default => "https://auth.${domain}\tdockhand\thttps://dockhand.${domain}/api/auth/oidc/callback\t${Sensitive(lookup($oidc_secret_key)).unwrap}\n",
  }

  file { "${data_dir}/oidc.tsv":
    ensure    => file,
    owner     => 'root',
    group     => 'root',
    mode      => '0600',
    content   => Sensitive($oidc_line),
    show_diff => false,
  }

  file { $work_dir:
    ensure  => directory,
    mode    => '0755',
    recurse => true,
    purge   => true,
    source  => 'puppet:///modules/roles/dockhand_environments',
  }

  # Guarded like roles::nas_mgmt_key: a --noop before the first real apply
  # reports "would run" instead of a missing-command error.
  exec { 'dockhand-environments':
    command  => "/bin/bash ${work_dir}/apply.sh",
    unless   => "test -f ${work_dir}/check.sh && /bin/bash ${work_dir}/check.sh",
    provider => shell,
    path     => ['/usr/bin', '/bin'],
    require  => [File[$work_dir, "${data_dir}/environments.tsv", "${data_dir}/oidc.tsv"], Class['roles::nas_mgmt_key']],
  }
}
