package healthreport

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"sort"
)

var historyFilename = regexp.MustCompile(`^facts-(\d{4})(\d{2})(\d{2})\.json$`)

type TrendPoint struct {
	Date string `json:"date"`
	Crit int    `json:"crit"`
	Warn int    `json:"warn"`
}

// Trend returns [{date, crit, warn}] oldest-first for the last `days` files.
func Trend(stateDir string, days int) []TrendPoint {
	historyDir := filepath.Join(stateDir, "history")
	entries, err := os.ReadDir(historyDir)
	if err != nil {
		return nil
	}
	var names []string
	for _, e := range entries {
		if historyFilename.MatchString(e.Name()) {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	if len(names) > days {
		names = names[len(names)-days:]
	}

	var out []TrendPoint
	for _, name := range names {
		match := historyFilename.FindStringSubmatch(name)
		raw, err := os.ReadFile(filepath.Join(historyDir, name))
		if err != nil {
			continue
		}
		var facts struct {
			Summary struct {
				Crit int `json:"crit"`
				Warn int `json:"warn"`
			} `json:"summary"`
		}
		if err := json.Unmarshal(raw, &facts); err != nil {
			continue
		}
		out = append(out, TrendPoint{
			Date: match[2] + "-" + match[3],
			Crit: facts.Summary.Crit,
			Warn: facts.Summary.Warn,
		})
	}
	return out
}

type HostFindingCount struct {
	Subject string `json:"subject"`
	Crit    int    `json:"crit"`
	Warn    int    `json:"warn"`
	Total   int    `json:"total"`
}

// ByHost returns actionable findings per subject, worst first. Subjects are
// hosts for most collectors but also repos and monitor names; that is the
// useful grouping - it answers "where is the trouble".
func ByHost(facts *Facts) []HostFindingCount {
	type counts struct{ crit, warn int }
	byOrder := []string{}
	byCounts := map[string]*counts{}
	for _, obs := range facts.Observations {
		if obs.Severity != "crit" && obs.Severity != "warn" {
			continue
		}
		subject := obs.Subject
		if subject == "" {
			subject = "unknown"
		}
		c, ok := byCounts[subject]
		if !ok {
			c = &counts{}
			byCounts[subject] = c
			byOrder = append(byOrder, subject)
		}
		if obs.Severity == "crit" {
			c.crit++
		} else {
			c.warn++
		}
	}

	rows := make([]HostFindingCount, 0, len(byOrder))
	for _, subject := range byOrder {
		c := byCounts[subject]
		rows = append(rows, HostFindingCount{Subject: subject, Crit: c.crit, Warn: c.warn, Total: c.crit + c.warn})
	}
	// Critical count dominates the ordering: three warnings are not worse
	// than one outage.
	sort.SliceStable(rows, func(i, j int) bool {
		if rows[i].Crit != rows[j].Crit {
			return rows[i].Crit > rows[j].Crit
		}
		if rows[i].Total != rows[j].Total {
			return rows[i].Total > rows[j].Total
		}
		return rows[i].Subject < rows[j].Subject
	})
	return rows
}
