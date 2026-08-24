// Log-derived facts from Loki. The valuable signal is not the error rate -
// that is noisy and mostly constant. It is the appearance of an error
// signature that has never been seen before. Signatures are normalized
// (numbers, hashes, IPs, UUIDs masked) so that a thousand variations of the
// same message collapse into one identity.
package collectors

import (
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	hr "github.com/MrCodeEU/homelab-automation/tools/internal/healthreport"
)

const errorPattern = `(?i)(error|fatal|panic|traceback|exception)`

// Structured logs carry an error field on success too: Caddy access logs
// all contain `error=<nil>`, which made every served request look like an
// error and inflated the daily count into the tens of thousands. Drop the
// "no error" idioms before counting.
const notErrorPattern = `(?i)(error=<nil>|error=null|"error":null|"error":""|err=<nil>|error=\s*$|error:\s*none\b)`

// Loki's querier echoes the query text into its own logs, a feedback loop
// that grows without bound. Exclude the query engine's own chatter.
const selfLogPattern = `(component=querier|component=ingester|caller=(metrics|engine)\.go)`

// A signature must recur this often within the sample before it becomes an
// observation, and only this many are reported per run.
const minSignatureCount = 10
const maxSignatures = 15

var dockerErrors = fmt.Sprintf(`{job="docker"} |~ `+"`%s`"+` !~ `+"`%s`"+` !~ `+"`%s`", errorPattern, notErrorPattern, selfLogPattern)

// Order matters: mask the most specific shapes first.
var normalizers = []struct {
	pattern     *regexp.Regexp
	replacement string
}{
	// ANSI colour codes must go first, and not only because they are ugly
	// in a notification. A sequence like \x1b[2m ends in a word
	// character, so a timestamp glued straight to it has no word boundary
	// in front of the digits and the <ts> rule below silently fails to
	// match.
	{regexp.MustCompile("\x1b\\[[0-9;]*[A-Za-z]"), ""},
	{regexp.MustCompile(`(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b`), "<uuid>"},
	{regexp.MustCompile(`\b(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?\b`), "<ip>"},
	{regexp.MustCompile(`(?i)\b[0-9a-f]{16,}\b`), "<hash>"},
	{regexp.MustCompile(`\b\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}\S*`), "<ts>"},
	// Any slash-bearing token is a path, digits or not.
	{regexp.MustCompile(`[\w.\-]*/[\w./\-]+`), "<path>"},
	{regexp.MustCompile(`\b\d+\b`), "<n>"},
	{regexp.MustCompile(`\s+`), " "},
}

func normalize(line string) string {
	text := strings.TrimSpace(line)
	for _, n := range normalizers {
		text = n.pattern.ReplaceAllString(text, n.replacement)
	}
	if len(text) > 200 {
		text = text[:200]
	}
	return text
}

var weekdays = []string{"mon", "tue", "wed", "thu", "fri", "sat", "sun"}
var windowRe = regexp.MustCompile(`(?i)^\s*(daily|mon|tue|wed|thu|fri|sat|sun)\s+(\d{1,2}):(\d{2})\s*-\s*(\d{1,2}):(\d{2})\s*$`)

type maintenanceWindow struct {
	day        int // -1 for daily
	start, end int
}

// parseWindows parses "sun 05:00-08:00" strings into (day, startMin,
// endMin) triples. day is -1 for `daily`. Unparseable entries are dropped
// rather than raising: a typo in one window must not take the whole report
// down.
func parseMaintenanceWindows(specs []string) []maintenanceWindow {
	var out []maintenanceWindow
	for _, spec := range specs {
		match := windowRe.FindStringSubmatch(spec)
		if match == nil {
			continue
		}
		day := strings.ToLower(match[1])
		fromH, _ := strconv.Atoi(match[2])
		fromM, _ := strconv.Atoi(match[3])
		toH, _ := strconv.Atoi(match[4])
		toM, _ := strconv.Atoi(match[5])
		start := fromH*60 + fromM
		end := toH*60 + toM
		dayIdx := -1
		if day != "daily" {
			for i, w := range weekdays {
				if w == day {
					dayIdx = i
					break
				}
			}
		}
		out = append(out, maintenanceWindow{day: dayIdx, start: start, end: end})
	}
	return out
}

// inWindow reports whether this local time falls inside any window.
// Windows that wrap past midnight are handled by treating the range as
// two: the day it starts on and the small hours of the next one.
func inWindow(t time.Time, windows []maintenanceWindow) bool {
	minute := t.Hour()*60 + t.Minute()
	// time.Weekday: Sunday=0..Saturday=6; our weekday index: mon=0..sun=6.
	weekday := (int(t.Weekday()) + 6) % 7
	for _, w := range windows {
		if w.start <= w.end {
			if (w.day == -1 || w.day == weekday) && w.start <= minute && minute < w.end {
				return true
			}
			continue
		}
		// Wraps midnight: before the end means it belongs to the previous day.
		if (w.day == -1 || w.day == weekday) && minute >= w.start {
			return true
		}
		previousDay := (weekday - 1 + 7) % 7
		if (w.day == -1 || w.day == previousDay) && minute < w.end {
			return true
		}
	}
	return false
}

type sample struct {
	ts    int64
	value float64
}

// splitMaintenance splits a [(unixTs, value)] series into (kept,
// suppressed) by maintenance window. A bucket produced by
// count_over_time([1h]) at timestamp T covers the hour ending at T, so it
// is judged by the hour it starts: a window at 05:00-08:00 should swallow
// the bucket stamped 06:00.
func splitMaintenance(series []sample, windows []maintenanceWindow) (kept, suppressed []sample) {
	if len(windows) == 0 {
		return series, nil
	}
	for _, s := range series {
		started := time.Unix(s.ts-3600, 0)
		if inWindow(started, windows) {
			suppressed = append(suppressed, s)
		} else {
			kept = append(kept, s)
		}
	}
	return kept, suppressed
}

func hourLabel(ts int64) string {
	if ts == 0 {
		return "n/a"
	}
	return time.Unix(ts, 0).Format("Mon 15:04")
}

func lokiQueryMatrix(cfg hr.Config, logql string, hours int, step int) ([]struct {
	metric map[string]string
	series []sample
}, error) {
	end := time.Now()
	start := end.Add(-time.Duration(hours) * time.Hour)
	target := fmt.Sprintf("%s/loki/api/v1/query_range?%s", strings.TrimRight(cfg.LokiURL, "/"), url.Values{
		"query": {logql},
		"start": {fmt.Sprintf("%d", start.UnixNano())},
		"end":   {fmt.Sprintf("%d", end.UnixNano())},
		"step":  {fmt.Sprintf("%d", step)},
	}.Encode())
	resp, err := httpGet(target, 60*time.Second, nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var payload struct {
		Status string `json:"status"`
		Data   struct {
			Result []struct {
				Metric map[string]string `json:"metric"`
				Values [][2]json.RawMessage `json:"values"`
			} `json:"result"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return nil, err
	}
	if payload.Status != "success" {
		return nil, fmt.Errorf("loki query failed: %v", payload)
	}
	var out []struct {
		metric map[string]string
		series []sample
	}
	for _, series := range payload.Data.Result {
		var points []sample
		for _, pair := range series.Values {
			var tsRaw, valRaw string
			if err := json.Unmarshal(pair[0], &tsRaw); err != nil {
				continue
			}
			if err := json.Unmarshal(pair[1], &valRaw); err != nil {
				continue
			}
			tsF, err1 := strconv.ParseFloat(tsRaw, 64)
			val, err2 := strconv.ParseFloat(valRaw, 64)
			if err1 != nil || err2 != nil {
				continue
			}
			points = append(points, sample{ts: int64(tsF), value: val})
		}
		out = append(out, struct {
			metric map[string]string
			series []sample
		}{series.Metric, points})
	}
	return out, nil
}

// lokiQueryInstant runs an aggregation query. Counting the entries
// returned by a range query is wrong: the result is silently truncated at
// `limit`, so count_over_time is evaluated server-side over the whole
// window instead.
func lokiQueryInstant(cfg hr.Config, logql string) ([]struct {
	metric map[string]string
	value  float64
}, error) {
	target := fmt.Sprintf("%s/loki/api/v1/query?%s", strings.TrimRight(cfg.LokiURL, "/"), url.Values{"query": {logql}}.Encode())
	resp, err := httpGet(target, 60*time.Second, nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var payload struct {
		Status string `json:"status"`
		Data   struct {
			Result []struct {
				Metric map[string]string `json:"metric"`
				Value  [2]json.RawMessage `json:"value"`
			} `json:"result"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return nil, err
	}
	if payload.Status != "success" {
		return nil, fmt.Errorf("loki query failed: %v", payload)
	}
	var out []struct {
		metric map[string]string
		value  float64
	}
	for _, series := range payload.Data.Result {
		var valRaw string
		if err := json.Unmarshal(series.Value[1], &valRaw); err != nil {
			continue
		}
		v, err := strconv.ParseFloat(valRaw, 64)
		if err != nil {
			continue
		}
		out = append(out, struct {
			metric map[string]string
			value  float64
		}{series.Metric, v})
	}
	return out, nil
}

type lokiStream struct {
	Stream map[string]string  `json:"stream"`
	Values [][2]string        `json:"values"`
}

func lokiQueryRange(cfg hr.Config, logql string, hours int, limit int) ([]lokiStream, error) {
	end := time.Now()
	start := end.Add(-time.Duration(hours) * time.Hour)
	target := fmt.Sprintf("%s/loki/api/v1/query_range?%s", strings.TrimRight(cfg.LokiURL, "/"), url.Values{
		"query":     {logql},
		"start":     {fmt.Sprintf("%d", start.UnixNano())},
		"end":       {fmt.Sprintf("%d", end.UnixNano())},
		"limit":     {fmt.Sprint(limit)},
		"direction": {"backward"},
	}.Encode())
	resp, err := httpGet(target, 60*time.Second, nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var payload struct {
		Status string `json:"status"`
		Data   struct {
			Result []lokiStream `json:"result"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return nil, err
	}
	if payload.Status != "success" {
		return nil, fmt.Errorf("loki query failed: %v", payload)
	}
	return payload.Data.Result, nil
}

type logSignature struct {
	container string
	host      string
	signature string
	count     int
	example   string
}

func init() {
	hr.RegisterCollector("logs", collectLogs)
}

func collectLogs(cfg hr.Config, rules hr.RulesFile) *hr.CollectorResult {
	result := hr.NewCollectorResult("logs")
	hours := cfg.LookbackHours
	logql := dockerErrors

	// Accurate totals, evaluated server-side over the whole window.
	type containerKey struct{ host, container string }
	perContainer := map[containerKey]int{}
	var perContainerOrder []containerKey
	countQ := fmt.Sprintf(`sum by (host, container) (count_over_time(%s [%dh]))`, dockerErrors, hours)
	countRows, err := lokiQueryInstant(cfg, countQ)
	if err != nil {
		panic(err)
	}
	for _, row := range countRows {
		host := row.metric["host"]
		if host == "" {
			host = row.metric["instance"]
		}
		if host == "" {
			host = "unknown"
		}
		container := row.metric["container"]
		if container == "" {
			container = "unknown"
		}
		if hr.IsEphemeral(container) {
			continue
		}
		key := containerKey{host, container}
		if _, ok := perContainer[key]; !ok {
			perContainerOrder = append(perContainerOrder, key)
		}
		perContainer[key] = int(row.value)
	}

	// Signatures need the actual lines, so this one stays a range query.
	streams, err := lokiQueryRange(cfg, logql, hours, 5000)
	if err != nil {
		panic(err)
	}
	signatures := map[string]*logSignature{}
	var sigOrder []string
	for _, stream := range streams {
		container := stream.Stream["container"]
		if container == "" {
			container = "unknown"
		}
		host := stream.Stream["host"]
		if host == "" {
			host = stream.Stream["instance"]
		}
		if host == "" {
			host = "unknown"
		}
		if hr.IsEphemeral(container) {
			continue
		}
		for _, pair := range stream.Values {
			line := pair[1]
			sig := normalize(line)
			if sig == "" {
				continue
			}
			key := container + "|" + sig
			entry, ok := signatures[key]
			if !ok {
				example := strings.TrimSpace(line)
				if len(example) > 400 {
					example = example[:400]
				}
				entry = &logSignature{container: container, host: host, signature: sig, example: example}
				signatures[key] = entry
				sigOrder = append(sigOrder, key)
			}
			entry.count++
		}
	}

	// Distinct error signatures appear constantly in a busy homelab. Only
	// signatures that recur meaningfully are worth waking up for; the
	// rest stay in `data` for forensics without becoming observations.
	ranked := make([]*logSignature, 0, len(sigOrder))
	for _, key := range sigOrder {
		ranked = append(ranked, signatures[key])
	}
	sort.SliceStable(ranked, func(i, j int) bool { return ranked[i].count > ranked[j].count })

	var notable []*logSignature
	for _, e := range ranked {
		if e.count >= minSignatureCount {
			notable = append(notable, e)
		}
	}
	if len(notable) > maxSignatures {
		notable = notable[:maxSignatures]
	}

	rankedForData := ranked
	if len(rankedForData) > 100 {
		rankedForData = rankedForData[:100]
	}
	signatureRows := make([]map[string]any, 0, len(rankedForData))
	for _, e := range rankedForData {
		signatureRows = append(signatureRows, map[string]any{
			"container": e.container, "host": e.host, "signature": e.signature,
			"count": e.count, "example": e.example,
		})
	}

	// most_common(50): sort by count desc, stable on insertion order.
	perContainerSorted := append([]containerKey{}, perContainerOrder...)
	sort.SliceStable(perContainerSorted, func(i, j int) bool {
		return perContainer[perContainerSorted[i]] > perContainer[perContainerSorted[j]]
	})
	if len(perContainerSorted) > 50 {
		perContainerSorted = perContainerSorted[:50]
	}
	perContainerRows := make([]map[string]any, 0, len(perContainerSorted))
	for _, k := range perContainerSorted {
		perContainerRows = append(perContainerRows, map[string]any{
			"host": k.host, "container": k.container, "errors": perContainer[k],
		})
	}

	data := map[string]any{
		"signature_count": len(signatures),
		"notable_count":   len(notable),
		"signatures":      signatureRows,
		"per_container":   perContainerRows,
	}

	// Emitted for every signature; the diff decides which are actually
	// new, and the severity rules only escalate the new ones.
	for _, e := range notable {
		msg := e.signature
		if len(msg) > 140 {
			msg = msg[:140]
		}
		result.Observations = append(result.Observations, &hr.Observation{
			ID: fmt.Sprintf("log_signature.%s.%s", e.container, sigKey(e.signature)), Collector: "logs",
			Subject: e.host, Kind: "log_signature", Value: e.count, Unit: "occurrences_in_sample",
			Message:  fmt.Sprintf("%s: %s (x%d in sample)", e.container, msg, e.count),
			Evidence: map[string]any{"example": e.example, "logql": logql}, Severity: "info",
		})
	}

	for _, k := range perContainerSorted {
		count := perContainer[k]
		result.Observations = append(result.Observations, &hr.Observation{
			ID: fmt.Sprintf("log_error_rate.%s.%s", k.host, k.container), Collector: "logs",
			Subject: k.host, Kind: "log_error_rate", Value: count, Unit: "lines",
			Message:  fmt.Sprintf("%s/%s logged %s error lines in %dh", k.host, k.container, formatThousands(float64(count)), hours),
			Evidence: map[string]any{"logql": logql}, Severity: "info",
		})
	}

	// Authentication failures. Alloy ships /var/log/secure as job="auth".
	authLogql := fmt.Sprintf(`sum by (host) (count_over_time({job="auth"} |= "Failed password" [%dh]))`, hours)
	authRows, err := lokiQueryInstant(cfg, authLogql)
	if err != nil {
		panic(err)
	}
	authCounts := map[string]int{}
	var authOrder []string
	for _, row := range authRows {
		host := row.metric["host"]
		if host == "" {
			host = "unknown"
		}
		if _, ok := authCounts[host]; !ok {
			authOrder = append(authOrder, host)
		}
		authCounts[host] = int(row.value)
	}
	authData := map[string]int{}
	for h, c := range authCounts {
		authData[h] = c
	}
	data["auth_failures"] = authData
	for _, host := range authOrder {
		count := authCounts[host]
		result.Observations = append(result.Observations, &hr.Observation{
			ID: "auth_failures." + host + ".", Collector: "logs", Subject: host, Kind: "auth_failures",
			Value: count, Unit: "attempts",
			Message:  fmt.Sprintf("%s saw %d failed SSH password attempts in %dh", host, count, hours),
			Evidence: map[string]any{"logql": authLogql}, Severity: "info",
		})
	}

	// Caddy 5xx: the user-visible failure mode for every proxied service.
	// Bucketed hourly rather than summed over the window, because a
	// single 24h total cannot tell a planned maintenance window from an
	// outage.
	caddyLogql := `sum by (host) (count_over_time({job="caddy"} | json | status >= 500 [1h]))`
	windows := parseMaintenanceWindows(cfg.MaintenanceWindows)
	hourThreshold := cfg.Caddy5xxHourThreshold
	perHostBuckets := map[string][]sample{}
	var hostOrder []string
	matrixRows, err := lokiQueryMatrix(cfg, caddyLogql, hours, 3600)
	if err != nil {
		panic(err)
	}
	for _, row := range matrixRows {
		host := row.metric["host"]
		if host == "" {
			host = "mljr"
		}
		if _, ok := perHostBuckets[host]; !ok {
			hostOrder = append(hostOrder, host)
		}
		perHostBuckets[host] = append(perHostBuckets[host], row.series...)
	}

	caddyData := map[string]any{}
	for _, host := range hostOrder {
		series := perHostBuckets[host]
		kept, suppressed := splitMaintenance(series, windows)
		total := 0.0
		for _, s := range kept {
			total += s.value
		}
		suppressedTotal := 0.0
		for _, s := range suppressed {
			suppressedTotal += s.value
		}
		var badHours int
		var peak float64
		var peakTS int64
		for _, s := range kept {
			if s.value >= float64(hourThreshold) {
				badHours++
			}
			if s.value > peak {
				peak = s.value
				peakTS = s.ts
			}
		}

		caddyData[host] = map[string]any{
			"total": int64(total), "suppressed": int64(suppressedTotal),
			"suppressed_hours": len(suppressed), "bad_hours": badHours, "peak": int64(peak),
		}
		evidence := map[string]any{
			"logql": caddyLogql, "hour_threshold": hourThreshold, "peak_hour": hourLabel(peakTS),
			"peak": int64(peak), "maintenance_windows": cfg.MaintenanceWindows,
			"suppressed_responses": int64(suppressedTotal), "suppressed_hours": len(suppressed),
		}

		result.Observations = append(result.Observations, &hr.Observation{
			ID: "caddy_5xx." + host + ".", Collector: "logs", Subject: host, Kind: "caddy_5xx",
			Value: int64(total), Unit: "responses",
			Message: fmt.Sprintf("%s served %s 5xx responses in %dh (excluding %d maintenance hour(s))",
				host, formatThousands(total), hours, len(suppressed)),
			Evidence: evidence, Severity: "info",
		})

		// The shape signal. One restart burst is one bad hour; a service
		// that is actually broken stays bad for many.
		result.Observations = append(result.Observations, &hr.Observation{
			ID: "caddy_5xx_hours." + host + ".", Collector: "logs", Subject: host, Kind: "caddy_5xx_hours",
			Value: badHours, Unit: "hours", Threshold: hourThreshold,
			Message: fmt.Sprintf("%s had %d hour(s) above %d 5xx in %dh (peak %s at %s)",
				host, badHours, hourThreshold, hours, formatThousands(peak), hourLabel(peakTS)),
			Evidence: evidence, Severity: "info",
		})
	}
	data["caddy_5xx"] = caddyData

	result.Data = data
	return result
}

func sigKey(signature string) string {
	sum := sha1.Sum([]byte(signature))
	return hex.EncodeToString(sum[:])[:12]
}

func formatThousands(v float64) string {
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
