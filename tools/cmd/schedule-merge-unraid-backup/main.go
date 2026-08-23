// schedule-merge-unraid-backup merges the nas-backup entry into Unraid's
// User Scripts schedule.json and removes the retired manual "rclone
// backup" script.
//
// Port of openvox/modules/roles/files/unraid_backup/schedule-merge.py.
// Same shape as schedule-merge-unraid - kept as a separate binary rather
// than a shared/parameterized one since the two roles' Ansible/spot
// ancestors were also always two separate scripts, not one shared with
// flags. Runs directly on nas via scp+ssh from
// roles::unraid_backup_proxy's proxy-exec scripts. --check exits 1 if
// anything would change, 0 if already clean.
package main

import (
	"fmt"
	"os"

	"github.com/MrCodeEU/homelab-automation/tools/internal/schedulemerge"
)

func main() {
	checkOnly := false
	for _, a := range os.Args[1:] {
		if a == "--check" {
			checkOnly = true
		}
	}

	cfg := schedulemerge.Config{
		ScriptName: "nas-backup",
		Frequency:  "daily",
		// The manual "rclone backup" User Script this role replaces.
		Retired:     []string{"rclone backup"},
		DoneMessage: "backup schedule merge complete",
	}

	if err := schedulemerge.Run(cfg, checkOnly); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
