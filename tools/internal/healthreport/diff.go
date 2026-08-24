package healthreport

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
)

const (
	StateFileLatest   = "facts-latest.json"
	StateFilePrevious = "facts-previous.json"
	SeenFile          = "seen/observations.json"
)

// SeenRecord is the long-lived per-identity state that survives across runs.
type SeenRecord struct {
	FirstSeen         string `json:"first_seen"`
	LastSeen          string `json:"last_seen"`
	Count             int    `json:"count"`
	LastActionableRun *string `json:"last_actionable_run"`
	Severity          string `json:"severity"`
	Kind              string `json:"kind"`
	Subject           string `json:"subject"`
	LastValue         any    `json:"last_value,omitempty"`
	ResolvedAt        string `json:"resolved_at,omitempty"`
}

type PrevObservation struct {
	ID       string `json:"id"`
	Severity string `json:"severity"`
}

type PreviousFacts struct {
	Observations []PrevObservation `json:"observations"`
}

func readJSON[T any](path string) T {
	var out T
	raw, err := os.ReadFile(path)
	if err != nil {
		return out
	}
	_ = json.Unmarshal(raw, &out)
	return out
}

func LoadPrevious(stateDir string) PreviousFacts {
	return readJSON[PreviousFacts](filepath.Join(stateDir, StateFileLatest))
}

func LoadSeen(stateDir string) map[string]*SeenRecord {
	seen := readJSON[map[string]*SeenRecord](filepath.Join(stateDir, SeenFile))
	if seen == nil {
		seen = map[string]*SeenRecord{}
	}
	return seen
}

// PreviousIDs returns ids that were actionable last run. Only warn/crit
// count. An observation that merely existed at info level was not a
// problem, so its reappearance at warn level is genuinely new.
func PreviousIDs(previous PreviousFacts) map[string]bool {
	out := map[string]bool{}
	for _, entry := range previous.Observations {
		if entry.Severity == "warn" || entry.Severity == "crit" {
			out[entry.ID] = true
		}
	}
	return out
}

// AttachPreviousValues gives each observation its value and first-seen date
// from the last run. Must run before severity classification.
func AttachPreviousValues(observations []*Observation, seen map[string]*SeenRecord) {
	for _, obs := range observations {
		if record, ok := seen[obs.ID]; ok {
			obs.PreviousValue = record.LastValue
			if record.FirstSeen != "" {
				obs.FirstSeen = record.FirstSeen
			}
		}
	}
}

// rememberValue stores the current value for the next run's spike
// comparison. Only numeric values are useful here, and bools are excluded:
// True would otherwise compare as 1 and read as a rate.
func rememberValue(record *SeenRecord, obs *Observation) {
	switch obs.Value.(type) {
	case bool:
		return
	case float64, float32, int, int64:
		record.LastValue = obs.Value
	}
}

type SeverityTransition struct {
	ID   string `json:"id"`
	From string `json:"from"`
	To   string `json:"to"`
}

type DiffResult struct {
	New        []string              `json:"new"`
	Reopened   []string              `json:"reopened"`
	Worsened   []SeverityTransition  `json:"worsened"`
	Improved   []SeverityTransition  `json:"improved"`
	Resolved   []string              `json:"resolved"`
	Persisting []string              `json:"persisting"`
}

// Compute compares this run against the last and updates the seen-state in
// place.
func Compute(observations []*Observation, previous PreviousFacts, seen map[string]*SeenRecord, nowISO string) DiffResult {
	previousByID := map[string]PrevObservation{}
	for _, entry := range previous.Observations {
		previousByID[entry.ID] = entry
	}

	currentActionable := map[string]*Observation{}
	for _, obs := range observations {
		if obs.Severity == "warn" || obs.Severity == "crit" {
			currentActionable[obs.ID] = obs
		}
	}
	previousActionable := PreviousIDs(previous)

	result := DiffResult{
		New: []string{}, Reopened: []string{}, Worsened: []SeverityTransition{},
		Improved: []SeverityTransition{}, Resolved: []string{}, Persisting: []string{},
	}

	// Deterministic iteration order for stable output.
	ids := make([]string, 0, len(currentActionable))
	for id := range currentActionable {
		ids = append(ids, id)
	}
	sort.Strings(ids)

	for _, obsID := range ids {
		obs := currentActionable[obsID]
		record, hasRecord := seen[obsID]
		previousEntry, hasPrevious := previousByID[obsID]
		wasActionable := previousActionable[obsID]

		if wasActionable {
			result.Persisting = append(result.Persisting, obsID)
			before := "info"
			if hasPrevious && previousEntry.Severity != "" {
				before = previousEntry.Severity
			}
			if SeverityRank(obs.Severity) > SeverityRank(before) {
				result.Worsened = append(result.Worsened, SeverityTransition{ID: obsID, From: before, To: obs.Severity})
			} else if SeverityRank(obs.Severity) < SeverityRank(before) {
				result.Improved = append(result.Improved, SeverityTransition{ID: obsID, From: before, To: obs.Severity})
			}
		} else if hasRecord && record.LastActionableRun != nil {
			// Known before, cleared, and back again. Distinct from brand
			// new: a flapping problem needs different attention than a
			// fresh one.
			result.Reopened = append(result.Reopened, obsID)
		} else {
			result.New = append(result.New, obsID)
		}

		if hasRecord {
			if record.FirstSeen != "" {
				obs.FirstSeen = record.FirstSeen
			} else {
				obs.FirstSeen = nowISO
			}
			record.LastSeen = nowISO
			record.Count++
			run := nowISO
			record.LastActionableRun = &run
			record.Severity = obs.Severity
			rememberValue(record, obs)
		} else {
			obs.FirstSeen = nowISO
			run := nowISO
			newRecord := &SeenRecord{
				FirstSeen: nowISO, LastSeen: nowISO, Count: 1,
				LastActionableRun: &run, Severity: obs.Severity,
				Kind: obs.Kind, Subject: obs.Subject,
			}
			rememberValue(newRecord, obs)
			seen[obsID] = newRecord
		}
	}

	resolved := []string{}
	for id := range previousActionable {
		if _, stillActionable := currentActionable[id]; !stillActionable {
			resolved = append(resolved, id)
		}
	}
	sort.Strings(resolved)
	result.Resolved = resolved
	for _, obsID := range resolved {
		if record, ok := seen[obsID]; ok {
			record.ResolvedAt = nowISO
		}
	}

	// Non-actionable observations still need first_seen carried, and their
	// identity recorded, so new_only rules (log signatures) work at all.
	for _, obs := range observations {
		if _, actionable := currentActionable[obs.ID]; actionable {
			continue
		}
		if record, ok := seen[obs.ID]; ok {
			if record.FirstSeen != "" {
				obs.FirstSeen = record.FirstSeen
			} else {
				obs.FirstSeen = nowISO
			}
			record.LastSeen = nowISO
			record.Count++
			// Recorded for info-level observations too: a rate only
			// becomes a spike by being compared against the quiet days
			// that preceded it.
			rememberValue(record, obs)
		} else {
			obs.FirstSeen = nowISO
			newRecord := &SeenRecord{
				FirstSeen: nowISO, LastSeen: nowISO, Count: 1,
				LastActionableRun: nil, Severity: obs.Severity,
				Kind: obs.Kind, Subject: obs.Subject,
			}
			rememberValue(newRecord, obs)
			seen[obs.ID] = newRecord
		}
	}

	return result
}

// FirstRunIDs returns ids already known, used to decide new_only
// severities. On the very first run nothing is known, so every signature
// would look new and the report would be pure noise.
func FirstRunIDs(stateDir string) map[string]bool {
	out := map[string]bool{}
	for id := range LoadSeen(stateDir) {
		out[id] = true
	}
	return out
}

// PruneSeen drops identities not seen for a long time. Returns the number
// removed. An entry that is currently actionable is never pruned, whatever
// its age.
func PruneSeen(seen map[string]*SeenRecord, nowISO string, retentionDays int) int {
	now, err := parseISOTime(nowISO)
	if err != nil {
		return 0
	}
	cutoff := now.AddDate(0, 0, -retentionDays)

	var stale []string
	for id, record := range seen {
		if record.LastActionableRun != nil && *record.LastActionableRun == nowISO {
			continue
		}
		if record.LastSeen == "" {
			continue
		}
		lastSeen, err := parseISOTime(record.LastSeen)
		if err != nil {
			continue
		}
		if lastSeen.Before(cutoff) {
			stale = append(stale, id)
		}
	}
	for _, id := range stale {
		delete(seen, id)
	}
	return len(stale)
}

// Save writes facts and seen-state to disk, rotating latest->previous and
// retaining a dated history copy.
func Save(stateDir string, facts *Facts, seen map[string]*SeenRecord, historyDays int) error {
	if err := os.MkdirAll(filepath.Join(stateDir, "history"), 0o755); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Join(stateDir, "seen"), 0o755); err != nil {
		return err
	}

	pruned := PruneSeen(seen, facts.Run.StartedAt, 60)
	if pruned > 0 {
		facts.Summary.SeenPruned = pruned
	}

	latest := filepath.Join(stateDir, StateFileLatest)
	previous := filepath.Join(stateDir, StateFilePrevious)
	if _, err := os.Stat(latest); err == nil {
		if err := os.Rename(latest, previous); err != nil {
			return err
		}
	}

	if err := writeJSONAtomic(latest, facts); err != nil {
		return err
	}
	if err := writeJSONAtomic(filepath.Join(stateDir, SeenFile), seen); err != nil {
		return err
	}

	stamp := facts.Run.ID
	if len(stamp) > 10 {
		stamp = stamp[:10]
	}
	stamp = replaceAll(stamp, "-", "")
	if stamp != "" {
		if err := writeJSONAtomic(filepath.Join(stateDir, "history", "facts-"+stamp+".json"), facts); err != nil {
			return err
		}
	}
	pruneHistory(filepath.Join(stateDir, "history"), historyDays)
	return nil
}

func replaceAll(s, old, new string) string {
	out := ""
	for i := 0; i < len(s); i++ {
		if string(s[i]) == old {
			out += new
		} else {
			out += string(s[i])
		}
	}
	return out
}

func writeJSONAtomic(path string, payload any) error {
	sorted, err := sortedJSON(payload)
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, sorted, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// sortedJSON marshals payload with alphabetically sorted object keys,
// matching Python's json.dump(..., sort_keys=True). encoding/json already
// sorts map[string]any keys, so round-tripping through a generic value
// achieves the same effect for structs.
func sortedJSON(payload any) ([]byte, error) {
	raw, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	var generic any
	if err := json.Unmarshal(raw, &generic); err != nil {
		return nil, err
	}
	return json.MarshalIndent(generic, "", "  ")
}

func pruneHistory(directory string, keep int) {
	entries, err := os.ReadDir(directory)
	if err != nil {
		return
	}
	var names []string
	for _, e := range entries {
		if !e.IsDir() && len(e.Name()) > 6 && e.Name()[:6] == "facts-" {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	if len(names) <= keep {
		return
	}
	for _, name := range names[:len(names)-keep] {
		_ = os.Remove(filepath.Join(directory, name))
	}
}
