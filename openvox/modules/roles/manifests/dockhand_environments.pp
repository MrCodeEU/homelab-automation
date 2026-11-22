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
class roles::dockhand_environments (
  Hash[String[1], Struct[{
    host      => Stdlib::Host,
    port      => Stdlib::Port,
    token_key => Pattern[/\Avault_[a-z0-9_]+\z/],
  }]] $environments = {},
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
    require  => [File[$work_dir, "${data_dir}/environments.tsv"], Class['roles::nas_mgmt_key']],
  }
}
