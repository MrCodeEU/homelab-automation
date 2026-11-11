# Part 4: a file that differs per host, and a secret only this host can
# decrypt (its own eyaml file and key).
class spike::hostfile (
  String        $colour,
  Array[String] $peers,
) {
  $host_secret = lookup('spike::hostfile::secret')

  file { '/etc/spike':
    ensure => directory,
    mode   => '0755',
  }

  file { '/etc/spike/host-info.txt':
    ensure  => file,
    mode    => '0644',
    content => epp('spike/host-info.txt.epp', {
      'colour' => $colour,
      'peers'  => $peers,
    }),
  }

  file { '/etc/spike/host-secret':
    ensure    => file,
    mode      => '0600',
    content   => Sensitive("${host_secret}\n"),
    show_diff => false,
  }
}
