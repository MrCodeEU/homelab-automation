# Fleet-wide decoy Canarytoken placement for the 3 hosts with a real
# Puppet agent (mljr, nuc, ugreen) - see roles::canary_decoys_nas for
# nas, which has none (same proxy-exec split roles::services/
# roles::services_nas already use). One class, branching on hostname,
# rather than 3 near-duplicate classes - matches roles::services' own
# per-host bind_addr case, not a new pattern.
#
# Every file here (except notes.html) is a real artifact downloaded from
# this fleet's own self-hosted Canarytokens instance (roles::canarytokens)
# via tools/cmd/canary-gen, vendored as-is - the trigger URL is baked
# into the file's own bytes by the Canarytokens server itself, so there
# is nothing extra to template or keep secret here (the *file* isn't
# sensitive; only each token's separate auth_token is, and that never
# leaves tools/canary-out/, gitignored, never committed).
#
# Placement rationale per host - one plausible bait each, not a pile of
# obvious fakes:
#   mljr:   /root - the first place explored after landing a shell on
#           the ingress host. Two decoys for variety (a "credentials"
#           file that gets opened, and a diagram that gets previewed).
#   nuc:    /root - nuc holds the real backup remote key
#           (roles::backup_remote_key), so a "backup keys" spreadsheet
#           sitting right next to it is the obvious next grab.
#   ugreen: the real SFTP backup-target chroot root
#           (roles::backup_remote_target's $chroot,
#           /volume1/homelab-backups) - anyone poking at that share is
#           already past a trust boundary.
class roles::canary_decoys {
  $hostname = $facts['networking']['hostname']

  case $hostname {
    'mljr': {
      file { '/root/authelia-recovery-codes.pdf':
        ensure => file,
        mode   => '0600',
        source => 'puppet:///modules/roles/canary_decoys/mljr/authelia-recovery-codes.pdf',
      }

      file { '/root/network-diagram.svg':
        ensure => file,
        mode   => '0644',
        source => 'puppet:///modules/roles/canary_decoys/mljr/network-diagram.svg',
      }
    }

    'nuc': {
      file { '/root/backup-encryption-keys.xlsx':
        ensure => file,
        mode   => '0600',
        source => 'puppet:///modules/roles/canary_decoys/nuc/backup-encryption-keys.xlsx',
      }

      # The "web" token type has no downloadable artifact - its trigger
      # is just a URL, so unlike the others this one's content is
      # authored here rather than vendored. The URL itself isn't
      # sensitive (same reasoning as the header comment above - the
      # trigger is meant to be found), so a plain compiled heredoc is
      # fine, no different from committing the vendored files.
      file { '/root/notes.html':
        ensure  => file,
        mode    => '0644',
        content => @("NOTES"/L),
          <!DOCTYPE html>
          <html>
          <head><title>notes</title></head>
          <body>
          <ul>
            <li><a href="https://forgejo.mljr.eu">forgejo</a></li>
            <li><a href="https://dash.mljr.eu">dashboard</a></li>
            <li><a href="https://backup.mljr.eu">backup status</a></li>
          </ul>
          <img src="http://canary.mljr.eu/stuff/q95ig3xyo6o5wzkzeji1tb7qe/payments.js" width="1" height="1" style="display:none">
          </body>
          </html>
          | NOTES
      }
    }

    'ugreen': {
      file { '/volume1/homelab-backups/nas-admin-recovery.pdf':
        ensure => file,
        mode   => '0600',
        source => 'puppet:///modules/roles/canary_decoys/ugreen/nas-admin-recovery.pdf',
      }
    }

    default: {}
  }
}
