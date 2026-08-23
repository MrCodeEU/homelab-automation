// Package schedulemerge merges one User Scripts entry into Unraid's
// schedule.json (shared with UI-created entries, so it must be merged,
// not overwritten) and removes retired entries.
//
// Shared logic behind the two schedule-merge binaries
// (cmd/schedule-merge-unraid, cmd/schedule-merge-unraid-backup) - kept as
// two separate binaries rather than one flag-driven one, matching the
// same design decision the two Python scripts this ports already made
// (see their own header comments): their Ansible/spot ancestors were
// always two separate scripts too, not one shared with flags.
package schedulemerge

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
)

const (
	usPath      = "/boot/config/plugins/user.scripts"
	runtimePath = "/tmp/user.scripts"
	backupPath  = usPath + "/schedule.json.openvox-bak"
)

type Config struct {
	// ScriptName is both the User Scripts directory name and, with
	// non-alphanumerics stripped, the suffix of the generated schedule id
	// ("schedule" + alnum(ScriptName)).
	ScriptName string
	Frequency  string
	// Retired User Scripts entries (by directory name) to drop from
	// schedule.json and delete from disk.
	Retired []string
	// DoneMessage is printed as the final success line, matching each
	// Python script's own distinct closing message.
	DoneMessage string
}

func schedulePath() string { return usPath + "/schedule.json" }
func scriptPath(name string) string {
	return filepath.Join(usPath, "scripts", name, "script")
}
func runtimeFile() string { return runtimePath + "/schedule.json" }

func scheduleID(scriptName string) string {
	id := "schedule"
	for _, r := range scriptName {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') {
			id += string(r)
		}
	}
	return id
}

// marshalSorted matches Python's json.dumps(indent=4, sort_keys=True) -
// re-serializing unchanged content must be byte-identical, or every run
// shows spurious drift from key reordering alone.
func marshalSorted(m map[string]any) (string, error) {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	var buf bytes.Buffer
	buf.WriteString("{")
	for i, k := range keys {
		if i > 0 {
			buf.WriteString(",")
		}
		buf.WriteString("\n    ")
		kb, err := json.Marshal(k)
		if err != nil {
			return "", err
		}
		buf.Write(kb)
		buf.WriteString(": ")
		entry, err := json.Marshal(m[k])
		if err != nil {
			return "", err
		}
		// Re-indent the entry's own 2-space-equivalent nesting to match
		// json.dumps(indent=4)'s 8-space nested-object indent.
		var entryBuf bytes.Buffer
		if err := json.Indent(&entryBuf, entry, "    ", "    "); err != nil {
			return "", err
		}
		buf.Write(entryBuf.Bytes())
	}
	if len(keys) > 0 {
		buf.WriteString("\n")
	}
	buf.WriteString("}")
	return buf.String() + "\n", nil
}

func Run(cfg Config, checkOnly bool) error {
	schedPath := schedulePath()
	thisScriptPath := scriptPath(cfg.ScriptName)
	retiredPaths := make(map[string]bool, len(cfg.Retired))
	for _, n := range cfg.Retired {
		retiredPaths[scriptPath(n)] = true
	}

	existedBefore := false
	existingRaw := ""
	existing := map[string]any{}
	if raw, err := os.ReadFile(schedPath); err == nil {
		existedBefore = true
		existingRaw = string(raw)
		if trimmedNonEmpty(existingRaw) {
			if err := json.Unmarshal(raw, &existing); err != nil {
				return fmt.Errorf("parsing %s: %w", schedPath, err)
			}
		}
	} else if !os.IsNotExist(err) {
		return err
	}

	merged := map[string]any{}
	for k, v := range existing {
		if !retiredPaths[k] {
			merged[k] = v
		}
	}
	merged[thisScriptPath] = map[string]any{
		"script":    thisScriptPath,
		"frequency": cfg.Frequency,
		"id":        scheduleID(cfg.ScriptName),
		"custom":    "",
	}
	mergedJSON, err := marshalSorted(merged)
	if err != nil {
		return err
	}

	scheduleChanged := mergedJSON != existingRaw

	var retiredDirsPresent []string
	for _, n := range cfg.Retired {
		if isDir(filepath.Join(usPath, "scripts", n)) {
			retiredDirsPresent = append(retiredDirsPresent, n)
		}
	}

	runtimeStale := true
	if raw, err := os.ReadFile(runtimeFile()); err == nil {
		runtimeStale = string(raw) != mergedJSON
	} else if !os.IsNotExist(err) {
		return err
	}

	if checkOnly {
		if scheduleChanged || len(retiredDirsPresent) > 0 || runtimeStale {
			os.Exit(1)
		}
		os.Exit(0)
	}

	if scheduleChanged {
		if existedBefore {
			// backup: true can't be used here - the boot flash is vfat, and
			// timestamp-embedded backup filenames contain colons, which vfat
			// rejects with EINVAL. Keep a single fixed-name copy instead.
			if err := copyFile(schedPath, backupPath, 0o644); err != nil {
				return err
			}
		}
		if err := os.MkdirAll(usPath, 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(schedPath, []byte(mergedJSON), 0o644); err != nil {
			return err
		}
		if err := os.Chmod(schedPath, 0o644); err != nil {
			return err
		}
		fmt.Printf("merged %s\n", schedPath)
	}

	// The scheduler does not read the flash copy - cron.daily/hourly/weekly
	// run startSchedule.php, which loads this runtime copy, refreshed by
	// the plugin only at boot or when its settings page is saved. Always
	// re-mirror (cheap, keeps it correct even if only the runtime copy
	// went stale).
	if err := os.MkdirAll(runtimePath, 0o755); err != nil {
		return err
	}
	if err := copyFile(schedPath, runtimeFile(), 0o600); err != nil {
		return err
	}

	for _, n := range cfg.Retired {
		d := filepath.Join(usPath, "scripts", n)
		if isDir(d) {
			if err := os.RemoveAll(d); err != nil {
				return err
			}
			fmt.Printf("removed retired user script '%s'\n", n)
		}
	}

	fmt.Println(cfg.DoneMessage)
	return nil
}

func trimmedNonEmpty(s string) bool {
	for _, r := range s {
		if r != ' ' && r != '\t' && r != '\n' && r != '\r' {
			return true
		}
	}
	return false
}

func isDir(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && fi.IsDir()
}

func copyFile(src, dst string, mode os.FileMode) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	if err := os.WriteFile(dst, data, mode); err != nil {
		return err
	}
	return os.Chmod(dst, mode)
}
