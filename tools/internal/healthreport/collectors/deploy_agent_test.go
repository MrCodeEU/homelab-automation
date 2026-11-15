package collectors

import (
	"testing"
	"time"
)

func TestEvaluateDeploy(t *testing.T) {
	now := time.Date(2026, 11, 12, 12, 0, 0, 0, time.UTC)
	fresh := now.Add(-time.Minute)
	old := &deployRequest{ID: "20261112T113000Z-7", Commit: "abc"}
	recent := &deployRequest{ID: "20261112T115500Z"}

	cases := []struct {
		name string
		req  *deployRequest
		view *deployAgentView
		want []string
	}{
		{"no metric at all", old, nil, []string{"deploy_agent_missing"}},
		{"no branch yet, polling", nil, &deployAgentView{lastPoll: fresh}, nil},
		{"stale polls", nil, &deployAgentView{lastPoll: now.Add(-time.Hour)}, []string{"deploy_agent_stale"}},
		{"handled ok", old, &deployAgentView{lastPoll: fresh, requestID: old.ID, outcome: "success"}, nil},
		{"handled, failed", old, &deployAgentView{lastPoll: fresh, requestID: old.ID, outcome: "failure"}, []string{"deploy_request_failed"}},
		{"handled, rejected", old, &deployAgentView{lastPoll: fresh, requestID: old.ID, outcome: "rejected"}, []string{"deploy_request_failed"}},
		{"suspended", old, &deployAgentView{lastPoll: fresh, requestID: old.ID, outcome: "suspended"}, []string{"deploy_request_suspended"}},
		{"old request not seen", old, &deployAgentView{lastPoll: fresh, requestID: "20261111T000000Z", outcome: "success"}, []string{"deploy_request_unhandled"}},
		{"new request, still in grace", recent, &deployAgentView{lastPoll: fresh}, nil},
		{"apply agent, no drift check yet", old, &deployAgentView{lastPoll: fresh, requestID: old.ID, outcome: "success", mode: "apply"}, []string{"deploy_drift_stale"}},
		{"noop agent, no drift check", old, &deployAgentView{lastPoll: fresh, requestID: old.ID, outcome: "success", mode: "noop"}, nil},
		{"drift clean", nil, &deployAgentView{lastPoll: fresh, driftRun: now.Add(-time.Hour), driftOK: true}, nil},
		{"drift", nil, &deployAgentView{lastPoll: fresh, driftRun: now.Add(-time.Hour), driftOK: true, driftChanges: 2}, []string{"deploy_drift"}},
		{"drift noop failed", nil, &deployAgentView{lastPoll: fresh, driftRun: now.Add(-time.Hour)}, []string{"deploy_drift_failed"}},
		{"drift check stale", nil, &deployAgentView{lastPoll: fresh, driftRun: now.Add(-60 * time.Hour), driftOK: true}, []string{"deploy_drift_stale"}},
	}
	for _, c := range cases {
		got := evaluateDeploy("nuc", now, c.req, c.view)
		var kinds []string
		for _, o := range got {
			kinds = append(kinds, o.Kind)
		}
		if len(kinds) != len(c.want) {
			t.Errorf("%s: got %v, want %v", c.name, kinds, c.want)
			continue
		}
		for i := range kinds {
			if kinds[i] != c.want[i] {
				t.Errorf("%s: got %v, want %v", c.name, kinds, c.want)
			}
		}
	}
}
