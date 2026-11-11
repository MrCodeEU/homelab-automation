# Part 1: package, a systemd unit with a templated ExecStart, enabled and
# running, restarted only when the unit changes.
class spike::iperf3 (
  Integer $port,
  String  $bind = '127.0.0.1',
) {
  package { 'iperf3':
    ensure => installed,
  }

  file { '/etc/systemd/system/spike-iperf3.service':
    ensure  => file,
    mode    => '0644',
    content => @("END"),
      [Unit]
      Description=iperf3 server (spike)
      After=network-online.target

      [Service]
      ExecStart=/usr/bin/iperf3 -s -B ${bind} -p ${port}
      Restart=on-failure

      [Install]
      WantedBy=multi-user.target
      | END
  }

  # The systemd provider runs daemon-reload itself when the unit changed.
  service { 'spike-iperf3':
    ensure    => running,
    enable    => true,
    subscribe => [Package['iperf3'], File['/etc/systemd/system/spike-iperf3.service']],
  }
}
