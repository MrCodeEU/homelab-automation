# Minimal test double for puppetlabs-docker. roles::base owns the ordering
# around its dependency; the Forge module itself is tested by its upstream
# project and is installed from the pinned Puppetfile on managed hosts.
class docker {
  service { 'docker':
    ensure => running,
  }
}
