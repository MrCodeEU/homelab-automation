package healthreport

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

var falseStrings = map[string]bool{"false": true, "0": true, "no": true, "none": true, "null": true, "": true}

// Rule is one entry from rules.yml. Severity is decided here, deterministically,
// before the LLM is ever called - see llm.go.
type Rule struct {
	Type        string   `yaml:"type"`
	Direction   string   `yaml:"direction"`
	Warn        *float64 `yaml:"warn"`
	Crit        *float64 `yaml:"crit"`
	MinAgeDays  *float64 `yaml:"min_age_days"`
	SpikeFactor *float64 `yaml:"spike_factor"`
	SpikeFloor  *float64 `yaml:"spike_floor"`
	SpikeLevel  string   `yaml:"spike_level"`
	CritValues  []any    `yaml:"crit_values"`
	WarnValues  []any    `yaml:"warn_values"`
	OkValues    []any    `yaml:"ok_values"`
	Level       string   `yaml:"level"`
	Subjects    []string `yaml:"subjects"`
}

type RulesFile struct {
	Rules map[string]Rule `yaml:"rules"`
}

func LoadRules(path string) (RulesFile, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return RulesFile{}, err
	}
	var rf RulesFile
	if err := yaml.Unmarshal(raw, &rf); err != nil {
		return RulesFile{}, err
	}
	return rf, nil
}

func numeric(value any) (float64, bool) {
	switch v := value.(type) {
	case bool:
		return 0, false
	case float64:
		return v, true
	case float32:
		return float64(v), true
	case int:
		return float64(v), true
	case int64:
		return float64(v), true
	case string:
		f, err := strconv.ParseFloat(v, 64)
		if err != nil {
			return 0, false
		}
		return f, true
	default:
		return 0, false
	}
}

func truthy(value any) bool {
	switch v := value.(type) {
	case bool:
		return v
	case nil:
		return false
	case float64:
		return v != 0
	case float32:
		return v != 0
	case int:
		return v != 0
	case int64:
		return v != 0
	default:
		return !falseStrings[strings.ToLower(strings.TrimSpace(fmt.Sprint(v)))]
	}
}

func ageDays(firstSeen any, now *time.Time) (float64, bool) {
	s, ok := firstSeen.(string)
	if !ok || s == "" || now == nil {
		return 0, false
	}
	seenAt, err := parseISOTime(s)
	if err != nil {
		return 0, false
	}
	return now.Sub(seenAt).Hours() / 24.0, true
}

func parseISOTime(s string) (time.Time, error) {
	for _, layout := range []string{time.RFC3339Nano, time.RFC3339, "2006-01-02T15:04:05.999999"} {
		if t, err := time.Parse(layout, s); err == nil {
			return t, nil
		}
	}
	return time.Time{}, fmt.Errorf("unparseable time: %s", s)
}

func valuesContain(values []any, want string) bool {
	for _, v := range values {
		if fmt.Sprint(v) == want {
			return true
		}
	}
	return false
}

// Classify returns the severity for one observation. Unknown kinds stay info.
func Classify(obs *Observation, rule Rule, isNew bool, now *time.Time) string {
	if rule.Type == "" {
		return "info"
	}

	if len(rule.Subjects) > 0 {
		found := false
		for _, s := range rule.Subjects {
			if s == obs.Subject {
				found = true
				break
			}
		}
		if !found {
			return "info"
		}
	}

	switch rule.Type {
	case "threshold":
		value, ok := numeric(obs.Value)
		if !ok {
			return "info"
		}
		direction := rule.Direction
		if direction == "" {
			direction = "above"
		}
		for _, level := range []string{"crit", "warn"} {
			limit := rule.Crit
			if level == "warn" {
				limit = rule.Warn
			}
			if limit == nil {
				continue
			}
			breached := (direction == "above" && value > *limit) || (direction == "below" && value < *limit)
			if !breached {
				continue
			}
			if rule.MinAgeDays != nil {
				// A day-one advisory list is normal; only escalate once it
				// has genuinely sat unresolved. A brand new observation
				// with no recorded first_seen yet reads as age 0, so it
				// stays info on its first sighting too.
				age, ok := ageDays(obs.FirstSeen, now)
				if !ok || age < *rule.MinAgeDays {
					return "info"
				}
			}
			obs.Threshold = *limit
			return level
		}
		return "info"

	case "threshold_or_spike":
		// Two independent ways to escalate, whichever fires first. The
		// absolute threshold is deliberately NOT raised to compensate for
		// the spike rule: this widens coverage rather than trading one
		// signal for another.
		value, ok := numeric(obs.Value)
		if !ok {
			return "info"
		}
		direction := rule.Direction
		if direction == "" {
			direction = "above"
		}
		for _, level := range []string{"crit", "warn"} {
			limit := rule.Crit
			if level == "warn" {
				limit = rule.Warn
			}
			if limit == nil {
				continue
			}
			if (direction == "above" && value > *limit) || (direction == "below" && value < *limit) {
				obs.Threshold = *limit
				return level
			}
		}

		previous, hasPrevious := numeric(obs.PreviousValue)
		factor := 3.0
		if rule.SpikeFactor != nil {
			factor = *rule.SpikeFactor
		}
		floor := 0.0
		if rule.SpikeFloor != nil {
			floor = *rule.SpikeFloor
		}
		// A first sighting has no baseline and must not read as a spike,
		// and a previous value of zero would make any growth infinite.
		if hasPrevious && previous > 0 && value >= floor && value >= previous*factor {
			obs.Message = fmt.Sprintf("%s — up %.1fx from %s", obs.Message, value/previous, formatThousands(previous))
			level := rule.SpikeLevel
			if level == "" {
				level = "warn"
			}
			return level
		}
		return "info"

	case "equals":
		value := fmt.Sprint(obs.Value)
		if valuesContain(rule.CritValues, value) {
			return "crit"
		}
		if valuesContain(rule.WarnValues, value) {
			return "warn"
		}
		return "info"

	case "not_equals":
		value := fmt.Sprint(obs.Value)
		if !valuesContain(rule.OkValues, value) {
			level := rule.Level
			if level == "" {
				level = "warn"
			}
			return level
		}
		return "info"

	case "truthy":
		level := rule.Level
		if level == "" {
			level = "warn"
		}
		if truthy(obs.Value) {
			return level
		}
		return "info"

	case "falsy":
		level := rule.Level
		if level == "" {
			level = "warn"
		}
		if !truthy(obs.Value) {
			return level
		}
		return "info"

	case "present":
		level := rule.Level
		if level == "" {
			level = "warn"
		}
		return level

	case "new_only":
		// Only interesting the first time it is seen. Steady-state noise
		// stays info so it never reaches the report body.
		if isNew {
			level := rule.Level
			if level == "" {
				level = "warn"
			}
			return level
		}
		return "info"
	}

	return "info"
}

func formatThousands(v float64) string {
	// Matches Python's f"{v:,.0f}".
	s := strconv.FormatFloat(v, 'f', 0, 64)
	neg := strings.HasPrefix(s, "-")
	if neg {
		s = s[1:]
	}
	var out []byte
	for i, c := range []byte(s) {
		if i > 0 && (len(s)-i)%3 == 0 {
			out = append(out, ',')
		}
		out = append(out, c)
	}
	if neg {
		return "-" + string(out)
	}
	return string(out)
}

// Apply classifies every observation in place.
func Apply(observations []*Observation, rules RulesFile, newIDs map[string]bool, now *time.Time) {
	for _, obs := range observations {
		rule := rules.Rules[obs.Kind]
		obs.Severity = Classify(obs, rule, newIDs[obs.ID], now)
	}
}
