// Ollama triage narrative. The model groups, ranks and explains. It never
// decides severity - that is already fixed by rules.yml before this module
// is called, and any severity-like key in the response is stripped.
//
// Contract: load -> generate -> unload, so a crash cannot leave the model
// resident in NAS RAM.
package healthreport

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"
)

// Floor for loading the model into RAM, independent of the generation
// budget. An 8B model read cold off the NAS array takes minutes; warm it is
// ~24s.
const llmLoadTimeoutS = 600

const llmSystemPrompt = `You are the triage step of an automated homelab health report.

The observations you receive have ALREADY been classified by deterministic
rules. You must not re-judge them:
- Never state or imply a different severity than the one given.
- Never invent hosts, services, metrics or numbers that are not in the input.
- Only reference observations by an observation_id that appears in the input.

Your job is to group related findings, pick the three that most deserve
attention, explain briefly why they matter, and suggest concrete next steps.

Each finding is an object with an "observation_id" field. When you reference a
finding, copy that field's value exactly and nothing else - no severity, no
message text appended.
Be terse and factual. No pleasantries, no filler, no speculation about causes
you cannot support from the data.

The headline is the push-notification title and must name the single most
important concrete thing, e.g. "nas cache filling, 2 monitors down". Never a
generic label like "Top 3 Critical Findings" or "System Health Summary". The
assessment must say what changed and what it means - not restate that the
findings deserve attention.

Reply with JSON conforming to the given schema and nothing else.`

// Keys that would let the model smuggle a severity judgement back in.
var llmForbiddenKeys = map[string]bool{
	"severity": true, "level": true, "priority": true, "crit": true, "warn": true, "status": true, "verdict": true,
}

var llmResponseSchema = map[string]any{
	"type":     "object",
	"required": []string{"headline", "assessment", "top_issues", "suggested_actions"},
	"properties": map[string]any{
		"headline":   map[string]any{"type": "string", "maxLength": 120},
		"assessment": map[string]any{"type": "string", "maxLength": 1200},
		"top_issues": map[string]any{
			"type": "array", "maxItems": 3,
			"items": map[string]any{
				"type": "object", "required": []string{"observation_id", "why_it_matters"},
				"properties": map[string]any{
					"observation_id": map[string]any{"type": "string"},
					"why_it_matters": map[string]any{"type": "string", "maxLength": 300},
				},
			},
		},
		"suggested_actions": map[string]any{
			"type": "array", "maxItems": 5,
			"items": map[string]any{"type": "string", "maxLength": 200},
		},
		"correlations": map[string]any{
			"type": "array", "maxItems": 3,
			"items": map[string]any{"type": "string", "maxLength": 200},
		},
	},
}

type Narrative struct {
	Headline          string        `json:"headline"`
	Assessment        string        `json:"assessment"`
	TopIssues         []TopIssue    `json:"top_issues"`
	SuggestedActions  []string      `json:"suggested_actions"`
	Correlations      []string      `json:"correlations"`
}

type TopIssue struct {
	ObservationID string `json:"observation_id"`
	WhyItMatters  string `json:"why_it_matters"`
}

func llmPost(cfg Config, path string, payload map[string]any, timeout time.Duration) (map[string]any, error) {
	body, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequest(http.MethodPost, strings.TrimRight(cfg.OllamaURL, "/")+path, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: timeout}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, &llmHTTPError{status: resp.StatusCode}
	}
	var out map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	return out, nil
}

type llmHTTPError struct{ status int }

func (e *llmHTTPError) Error() string { return fmt.Sprintf("HTTP %d", e.status) }

// llmLoad: an empty prompt loads the model into memory without generating.
// Given its own, larger budget than a generation. Reading 5GB of weights
// off disk into RAM is one-off and slow, and is not the thing the
// generation timeout is protecting against.
func llmLoad(cfg Config) error {
	timeout := cfg.LLMTimeoutS
	if timeout < llmLoadTimeoutS {
		timeout = llmLoadTimeoutS
	}
	_, err := llmPost(cfg, "/api/generate", map[string]any{
		"model": cfg.OllamaModel, "prompt": "", "keep_alive": "10m",
	}, time.Duration(timeout)*time.Second)
	return err
}

// llmUnload: keep_alive 0 evicts immediately - equivalent to `ollama stop`.
func llmUnload(cfg Config) {
	_, _ = llmPost(cfg, "/api/generate", map[string]any{
		"model": cfg.OllamaModel, "prompt": "", "keep_alive": 0,
	}, 60*time.Second)
}

// buildLLMInput compacts the facts into ~2k tokens: identity plus message,
// no payloads.
func buildLLMInput(facts *Facts) map[string]any {
	byID := map[string]*Observation{}
	for _, obs := range facts.Observations {
		byID[obs.ID] = obs
	}

	render := func(ids []string) []map[string]any {
		out := []map[string]any{}
		for _, id := range ids {
			if obs, ok := byID[id]; ok {
				out = append(out, map[string]any{
					"observation_id": id, "severity": obs.Severity, "message": obs.Message,
				})
			}
		}
		return out
	}

	diff := facts.Diff
	worsened := []map[string]any{}
	for _, w := range diff.Worsened {
		msg := ""
		if obs, ok := byID[w.ID]; ok {
			msg = obs.Message
		}
		worsened = append(worsened, map[string]any{
			"observation_id": w.ID, "from": w.From, "to": w.To, "message": msg,
		})
	}

	persistingSample := diff.Persisting
	if len(persistingSample) > 10 {
		persistingSample = persistingSample[:10]
	}

	return map[string]any{
		"date":              facts.Run.ID,
		"counts":            facts.Summary,
		"new":               render(diff.New),
		"reopened":          render(diff.Reopened),
		"worsened":          worsened,
		"persisting_count":  len(diff.Persisting),
		"persisting_sample": render(persistingSample),
		"resolved":          render(diff.Resolved),
		"failed_collectors": facts.Summary.CollectorsFailed,
	}
}

// stripForbidden recursively drops severity-like keys from the model's response.
func stripForbidden(payload any) any {
	switch v := payload.(type) {
	case map[string]any:
		out := map[string]any{}
		for k, val := range v {
			if !llmForbiddenKeys[strings.ToLower(k)] {
				out[k] = stripForbidden(val)
			}
		}
		return out
	case []any:
		out := make([]any, len(v))
		for i, item := range v {
			out[i] = stripForbidden(item)
		}
		return out
	default:
		return payload
	}
}

// ValidateNarrative enforces the contract. Returns an error if the response
// is unusable.
func ValidateNarrative(raw any, validIDs map[string]bool) (*Narrative, error) {
	payloadAny, ok := raw.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("response is not an object")
	}
	stripped, _ := stripForbidden(payloadAny).(map[string]any)

	headline, _ := stripped["headline"].(string)
	assessment, _ := stripped["assessment"].(string)
	if strings.TrimSpace(headline) == "" {
		return nil, fmt.Errorf("missing headline")
	}
	if strings.TrimSpace(assessment) == "" {
		return nil, fmt.Errorf("missing assessment")
	}

	var issues []TopIssue
	if rawIssues, ok := stripped["top_issues"].([]any); ok {
		for _, ri := range rawIssues {
			issue, ok := ri.(map[string]any)
			if !ok {
				continue
			}
			obsID, _ := issue["observation_id"].(string)
			// Anti-hallucination: an id the run never produced is dropped outright.
			if !validIDs[obsID] {
				continue
			}
			why := fmt.Sprint(issue["why_it_matters"])
			if len(why) > 300 {
				why = why[:300]
			}
			issues = append(issues, TopIssue{ObservationID: obsID, WhyItMatters: why})
			if len(issues) == 3 {
				break
			}
		}
	}

	var actions []string
	if rawActions, ok := stripped["suggested_actions"].([]any); ok {
		for _, a := range rawActions {
			s := fmt.Sprint(a)
			if len(s) > 200 {
				s = s[:200]
			}
			actions = append(actions, s)
			if len(actions) == 5 {
				break
			}
		}
	}

	var correlations []string
	if rawCorr, ok := stripped["correlations"].([]any); ok {
		for _, c := range rawCorr {
			s := fmt.Sprint(c)
			if len(s) > 200 {
				s = s[:200]
			}
			correlations = append(correlations, s)
			if len(correlations) == 3 {
				break
			}
		}
	}

	headlineTrim := strings.TrimSpace(headline)
	if len(headlineTrim) > 120 {
		headlineTrim = headlineTrim[:120]
	}
	assessmentTrim := strings.TrimSpace(assessment)
	if len(assessmentTrim) > 1200 {
		assessmentTrim = assessmentTrim[:1200]
	}

	return &Narrative{
		Headline: headlineTrim, Assessment: assessmentTrim, TopIssues: issues,
		SuggestedActions: actions, Correlations: correlations,
	}, nil
}

// Summarize returns (narrative, status). Never returns an error to the
// caller - unreachable/invalid LLM output degrades the status instead.
func Summarize(cfg Config, facts *Facts) (*Narrative, string) {
	if !cfg.LLMEnabled {
		return nil, "disabled"
	}

	validIDs := map[string]bool{}
	for _, obs := range facts.Observations {
		validIDs[obs.ID] = true
	}
	payloadIn := buildLLMInput(facts)

	if err := llmLoad(cfg); err != nil {
		return nil, "unavailable"
	}
	defer llmUnload(cfg)

	inputJSON, _ := json.MarshalIndent(payloadIn, "", " ")

	for attempt, temperature := range []float64{0.2, 0.0} {
		messages := []map[string]any{
			{"role": "system", "content": llmSystemPrompt},
			{"role": "user", "content": string(inputJSON)},
		}
		if attempt > 0 {
			messages = append(messages, map[string]any{
				"role": "user", "content": "Your last reply was not valid JSON for the schema. " +
					"Reply with schema-conforming JSON only.",
			})
		}
		payload := map[string]any{
			"model": cfg.OllamaModel, "stream": false, "format": llmResponseSchema,
			"keep_alive": "10m", "options": map[string]any{"temperature": temperature, "num_ctx": 8192},
			// qwen3 is a reasoning model and emits a long <think> block by
			// default. On NAS CPU that alone blew past the budget and
			// every run degraded to "unavailable". The report needs a
			// summary, not visible deliberation.
			"think":    false,
			"messages": messages,
		}

		response, err := llmPost(cfg, "/api/chat", payload, time.Duration(cfg.LLMTimeoutS)*time.Second)
		if err != nil {
			if httpErr, ok := err.(*llmHTTPError); ok && httpErr.status == 400 {
				// Models that do not support thinking reject the field outright.
				delete(payload, "think")
				response, err = llmPost(cfg, "/api/chat", payload, time.Duration(cfg.LLMTimeoutS)*time.Second)
				if err != nil {
					return nil, "unavailable"
				}
			} else {
				return nil, "unavailable"
			}
		}

		message, _ := response["message"].(map[string]any)
		content, _ := message["content"].(string)
		var parsed any
		if err := json.Unmarshal([]byte(content), &parsed); err == nil {
			if narrative, err := ValidateNarrative(parsed, validIDs); err == nil {
				return narrative, "ok"
			}
		}
	}

	return nil, "degraded_invalid"
}
