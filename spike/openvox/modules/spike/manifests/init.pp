# The config-management spike slice (docs/SPIKE_CONFIG_MGMT.md), the same
# four parts in every tool.
class spike {
  contain spike::iperf3
  contain spike::stack
  contain spike::sshd
  contain spike::hostfile
}
