// schedule-merge-unraid-aoostar merges the AOOSTAR display start and stop
// entries into Unraid's User Scripts schedule.json and removes the two
// hand-made scripts they replace. Runs directly on nas via scp+ssh from
// roles::unraid_aoostar_proxy's proxy-exec scripts. --check exits 1 if
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
		ScriptName: "aoostar-display",
		Frequency:  "start",
		Extra: []schedulemerge.Entry{
			// "At Stopping of Array": kills the display driver, which Unraid
			// does not do on its own.
			{ScriptName: "aoostar-display-stop", Frequency: "stop"},
		},
		// The hand-made scripts this role replaces (a long-running launcher
		// and a 1100-line controller with credentials embedded).
		Retired:     []string{"aoostar_display", "aoostar_display_controller"},
		DoneMessage: "aoostar display schedule merge complete",
	}

	if err := schedulemerge.Run(cfg, checkOnly); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
