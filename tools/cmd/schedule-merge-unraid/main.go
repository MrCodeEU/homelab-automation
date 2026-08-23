// schedule-merge-unraid merges the homelab-compose-up bootstrap entry into
// Unraid's User Scripts schedule.json and removes retired entries.
//
// Port of openvox/modules/roles/files/unraid/schedule-merge.py. Runs
// directly on nas via scp+ssh from roles::unraid_proxy's proxy-exec
// scripts (see schedule-apply.sh/schedule-check.sh). --check exits 1 if
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
		ScriptName: "homelab-compose-up",
		Frequency:  "start",
		// Legacy User Scripts entry superseded by Ansible/spot/OpenVox -
		// "GHCR Auth" held a plaintext GitHub PAT on the boot flash; GHCR
		// login now happens from the eyaml-held token instead.
		Retired:     []string{"GHCR Auth"},
		DoneMessage: "bootstrap schedule merge complete",
	}

	if err := schedulemerge.Run(cfg, checkOnly); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
