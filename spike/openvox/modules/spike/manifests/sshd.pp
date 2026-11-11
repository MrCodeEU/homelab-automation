# Part 3: an sshd drop-in, validated with sshd -t before it goes live,
# a guard script created in the same run, and a reload only on change.
# The guard is written the naive way on purpose: on a fresh host the
# script does not exist yet during --noop, which is the failure this
# spike measures (the exit-127 noop failure on ugreen, 2026-11-10).
class spike::sshd {
  user { 'spikefacts':
    ensure     => present,
    managehome => true,
    shell      => '/bin/bash',
  }

  file { '/usr/local/sbin/spike-facts':
    ensure  => file,
    mode    => '0755',
    content => "#!/bin/sh\necho \"facts from \$(hostname -s)\"\n",
  }

  file { '/etc/ssh/sshd_config.d/50-spike.conf':
    ensure       => file,
    mode         => '0600',
    content      => @(END),
      Match User spikefacts Address 127.0.0.1
          ForceCommand /usr/local/sbin/spike-facts
          AllowTcpForwarding no
      | END
    validate_cmd => '/usr/sbin/sshd -t -f %',
    require      => [User['spikefacts'], File['/usr/local/sbin/spike-facts']],
  }

  file { '/usr/local/sbin/spike-sshd-check.sh':
    ensure  => file,
    mode    => '0755',
    content => @(END),
      #!/bin/bash
      # Exit 0 when the running sshd already applies the Match block.
      /usr/sbin/sshd -T -C user=spikefacts,host=localhost,addr=127.0.0.1 \
        | grep -qx 'forcecommand /usr/local/sbin/spike-facts'
      | END
  }

  exec { 'sshd-reload':
    command => '/usr/bin/systemctl reload sshd',
    unless  => '/usr/local/sbin/spike-sshd-check.sh',
    require => [File['/etc/ssh/sshd_config.d/50-spike.conf'], File['/usr/local/sbin/spike-sshd-check.sh']],
  }
}
