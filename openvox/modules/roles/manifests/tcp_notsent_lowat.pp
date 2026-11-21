# Caps the unsent data the kernel queues per TCP socket at 128 KiB
# (default: unlimited). The Ziti routers' links carry heartbeats in the
# same socket as bulk data (backups, Trivy imports): with an unlimited
# queue a heartbeat waited behind seconds of data, the far router saw no
# answer within its timeout and closed the link, dropping every circuit
# (about 15 times a day in 2026-11, the 502 bursts). The same setting
# fixed xgress on nas (roles::unraid_proxy, docs/ZERO_TRUST_PLAN.md C6:
# 64 % -> 97-99 %). Host-wide, so it applies to every TCP sender here.
class roles::tcp_notsent_lowat (
  Integer[16384] $bytes = 131072,
) {
  $conf = '/etc/sysctl.d/60-homelab-tcp-notsent-lowat.conf'

  file { $conf:
    ensure  => file,
    mode    => '0644',
    content => "# Managed by OpenVox (roles::tcp_notsent_lowat)\nnet.ipv4.tcp_notsent_lowat = ${bytes}\n",
  }

  exec { 'tcp-notsent-lowat':
    command => "sysctl -q -w net.ipv4.tcp_notsent_lowat=${bytes}",
    unless  => "test \"$(sysctl -n net.ipv4.tcp_notsent_lowat)\" = ${bytes}",
    path    => ['/usr/sbin', '/sbin', '/usr/bin', '/bin'],
    require => File[$conf],
  }
}
