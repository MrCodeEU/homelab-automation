# Part 2: a compose stack whose .env holds a secret from eyaml, a
# post-deploy hook, and a redeploy only when a file changed.
class spike::stack (
  String $image,
  String $dir = '/opt/whoami',
) {
  $secret = lookup('spike::stack::secret')

  file { $dir:
    ensure => directory,
    mode   => '0755',
  }

  file { "${dir}/docker-compose.yml":
    ensure  => file,
    mode    => '0644',
    content => @("END"/$),
      services:
        whoami:
          image: ${image}
          container_name: whoami
          restart: unless-stopped
          ports: ["127.0.0.1:8080:80"]
          environment:
            WHOAMI_NAME: \${WHOAMI_NAME}
      | END
  }

  file { "${dir}/.env":
    ensure    => file,
    mode      => '0600',
    content   => Sensitive("WHOAMI_NAME=${secret}\n"),
    show_diff => false,
  }

  file { "${dir}/post-deploy.sh":
    ensure  => file,
    mode    => '0755',
    content => @("END"/$),
      #!/bin/bash
      # Waits for the new container, then records the deploy.
      set -euo pipefail
      for _ in \$(seq 30); do
        if curl -fsS http://127.0.0.1:8080/ | grep -q '^Name: '; then
          date -u +%FT%TZ > ${dir}/last-deploy
          exit 0
        fi
        sleep 1
      done
      echo 'whoami did not answer' >&2
      exit 1
      | END
  }

  exec { 'whoami-up':
    command     => "/usr/bin/docker compose -f ${dir}/docker-compose.yml up -d --remove-orphans",
    cwd         => $dir,
    refreshonly => true,
    subscribe   => [File["${dir}/docker-compose.yml"], File["${dir}/.env"]],
  }

  exec { 'whoami-post-deploy':
    command     => "${dir}/post-deploy.sh",
    refreshonly => true,
    subscribe   => Exec['whoami-up'],
    require     => File["${dir}/post-deploy.sh"],
  }
}
