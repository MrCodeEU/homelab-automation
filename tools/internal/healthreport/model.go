// Package healthreport collects, classifies and reports on the health of the
// whole homelab estate.
//
// Port of services/healthreport/app/*.py.
package healthreport

import (
	"encoding/json"
	"math"
	"regexp"
)

var severities = []string{"info", "warn", "crit"}

// EphemeralContainer matches containers that are supposed to appear and
// disappear, and must never become findings: `docker compose run` mints
// <project>-run-<hash> for every invocation, so this report would otherwise
// create a permanent new observation id every time it runs and keep it in
// the seen-state forever.
var EphemeralContainer = regexp.MustCompile(`(-run-[0-9a-f]+$|^healthreport$|_run_[0-9]+$)`)

func IsEphemeral(name string) bool {
	return name != "" && EphemeralContainer.MatchString(name)
}

func SeverityRank(severity string) int {
	for i, s := range severities {
		if s == severity {
			return i
		}
	}
	return 0
}

func Worst(values []string) string {
	best := -1
	worst := "info"
	for _, s := range values {
		rank := -1
		for i, sev := range severities {
			if sev == s {
				rank = i
				break
			}
		}
		if rank < 0 {
			continue
		}
		if rank > best {
			best = rank
			worst = s
		}
	}
	return worst
}

// Observation is the atomic unit of the report. Its Id is deliberately
// value-free (<kind>.<subject>.<resource>) so that the same underlying
// problem maps to the same id on every run - that is what makes "new since
// yesterday" and "broken for six days" derivable instead of guessed.
type Observation struct {
	ID        string         `json:"id"`
	Collector string         `json:"collector"`
	Subject   string         `json:"subject"`
	Kind      string         `json:"kind"`
	Message   string         `json:"message"`
	Severity  string         `json:"severity"`
	Value     any            `json:"value"`
	Unit      any            `json:"unit"`
	Threshold any            `json:"threshold"`
	Evidence  map[string]any `json:"evidence"`
	// PreviousValue is this observation's value on the previous run, filled
	// in by diff.AttachPreviousValues. Lets a rule escalate on a jump rather
	// than only on an absolute level.
	PreviousValue any `json:"previous_value"`
	// FirstSeen is filled in by the diff stage from the previous run's state.
	FirstSeen any `json:"first_seen"`
}

func NewObservation(id, collector, subject, kind, message string) *Observation {
	return &Observation{
		ID: id, Collector: collector, Subject: subject, Kind: kind, Message: message,
		Severity: "info", Evidence: map[string]any{},
	}
}

// CollectorResult is what one collector returns: ok, error or unavailable,
// plus whatever observations and raw data it produced. A collector that
// raises is recorded as an error rather than killing the run - a broken
// collector is itself something the report must say out loud.
type CollectorResult struct {
	Name         string
	Status       string // ok | error | unavailable
	Error        string
	DurationS    float64
	Data         any
	Observations []*Observation
}

func NewCollectorResult(name string) *CollectorResult {
	return &CollectorResult{Name: name, Status: "ok"}
}

func (r *CollectorResult) ToDict() map[string]any {
	var errVal any
	if r.Error != "" {
		errVal = r.Error
	}
	return map[string]any{
		"status":     r.Status,
		"error":      errVal,
		"duration_s": round(r.DurationS, 3),
		"data":       r.Data,
	}
}

// MarshalJSON matches Python's CollectorResult.to_dict(): only status,
// error, duration_s and data are persisted in facts.json. Observations live
// at the top level of Facts instead.
func (r *CollectorResult) MarshalJSON() ([]byte, error) {
	return json.Marshal(r.ToDict())
}

func round(v float64, places int) float64 {
	mult := math.Pow(10, float64(places))
	return math.Round(v*mult) / mult
}
