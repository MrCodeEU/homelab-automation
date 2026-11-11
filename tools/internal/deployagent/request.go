// Package deployagent is the pull side of deploys (docs/DEPLOY_AGENT.md):
// a request on the branch deploy/<host> names a main commit, the agent on
// the host checks the request and applies that commit.
package deployagent

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
)

// RequestPath is the one file on a deploy/<host> branch.
const RequestPath = ".deploy/request.json"

// Request is the content of RequestPath.
type Request struct {
	// ID orders requests: a UTC timestamp, optionally followed by a dash
	// and a run id (20261111T181502Z-42). Only a request whose ID sorts
	// after the last one handled is applied.
	ID      string `json:"id"`
	Host    string `json:"host"`
	Commit  string `json:"commit"`
	Trigger string `json:"trigger"`

	// The deploy.yml inputs, passed to the apply command unchanged.
	Service         string `json:"service"`
	StagingServices string `json:"staging_services"`
	DockerPrune     bool   `json:"docker_prune"`
	RebootIfNeeded  bool   `json:"reboot_if_needed"`
}

var (
	idRE      = regexp.MustCompile(`^[0-9]{8}T[0-9]{6}Z(-[0-9A-Za-z]{1,40})?$`)
	hostRE    = regexp.MustCompile(`^[a-z0-9-]{1,63}$`)
	commitRE  = regexp.MustCompile(`^[0-9a-f]{40}$`)
	serviceRE = regexp.MustCompile(`^[A-Za-z0-9._-]{1,64}$`)
)

// The triggers deploy.yml and the laptop create requests for.
var triggers = map[string]bool{
	"workflow_dispatch":   true,
	"schedule":            true,
	"repository_dispatch": true,
	"manual":              true,
}

// ParseRequest decodes and validates a request. Unknown fields are an
// error: a request the agent does not fully understand is not applied.
func ParseRequest(data []byte) (Request, error) {
	var r Request
	dec := json.NewDecoder(strings.NewReader(string(data)))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&r); err != nil {
		return Request{}, fmt.Errorf("parse %s: %w", RequestPath, err)
	}
	return r, r.Validate()
}

// Validate applies the same allowlist as deploy.yml's input checks.
func (r Request) Validate() error {
	switch {
	case !idRE.MatchString(r.ID):
		return fmt.Errorf("request id %q: want YYYYMMDDTHHMMSSZ[-run]", r.ID)
	case !hostRE.MatchString(r.Host):
		return fmt.Errorf("request host %q is not a host name", r.Host)
	case !commitRE.MatchString(r.Commit):
		return fmt.Errorf("request commit %q is not a full sha", r.Commit)
	case !triggers[r.Trigger]:
		return fmt.Errorf("request trigger %q is not one of workflow_dispatch, schedule, repository_dispatch, manual", r.Trigger)
	case r.Service != "" && !serviceRE.MatchString(r.Service):
		return fmt.Errorf("request service %q: want 1-64 of [A-Za-z0-9._-]", r.Service)
	case len(r.StagingServices) > 256:
		return fmt.Errorf("request staging_services is longer than 256")
	}
	if r.StagingServices != "" {
		for _, s := range strings.Split(r.StagingServices, ",") {
			if !serviceRE.MatchString(s) {
				return fmt.Errorf("request staging service %q: want 1-64 of [A-Za-z0-9._-]", s)
			}
		}
	}
	return nil
}

// After reports whether r is newer than the request with id last. The id
// format sorts as text; an empty last means no request was handled yet.
func (r Request) After(last string) bool {
	return last == "" || r.ID > last
}

// Env is the request as environment variables for the apply command,
// named like deploy.yml's (OPENVOX_STAGING_SERVICES).
func (r Request) Env() []string {
	return []string{
		"DEPLOY_REQUEST_ID=" + r.ID,
		"DEPLOY_COMMIT=" + r.Commit,
		"DEPLOY_TRIGGER=" + r.Trigger,
		"DEPLOY_SERVICE=" + r.Service,
		"OPENVOX_STAGING_SERVICES=" + r.StagingServices,
		fmt.Sprintf("DEPLOY_DOCKER_PRUNE=%t", r.DockerPrune),
		fmt.Sprintf("DEPLOY_REBOOT_IF_NEEDED=%t", r.RebootIfNeeded),
	}
}
