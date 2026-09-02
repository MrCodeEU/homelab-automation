# Minimal test double for the puppetlabs-docker docker_compose defined type.
define docker_compose (
  Array[String] $compose_files,
  String $ensure = 'present',
) {}
