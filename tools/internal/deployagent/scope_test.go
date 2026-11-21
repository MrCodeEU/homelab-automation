package deployagent

import (
	"strings"
	"testing"

	"github.com/go-git/go-git/v5/plumbing"
	"github.com/go-git/go-git/v5/plumbing/object"
)

func TestPullScope(t *testing.T) {
	o := newOrigin(t)
	script := "#!/bin/bash\necho \"pull=$OPENVOX_PULL_SERVICES\" >> \"$APPLY_LOG\"\n"
	m1 := o.commit("main", plumbing.ZeroHash, map[string]string{"scripts/apply.sh": script}, false)
	a, applyLog := newAgent(t, o, &recorder{})
	dispatch := func(svc string, unsigned bool) {
		o.request(m1, func(r *Request) { r.Trigger, r.Service = "repository_dispatch", svc }, unsigned)
	}
	last := func() string {
		t.Helper()
		lines := strings.Split(strings.TrimSpace(mustRead(t, applyLog)), "\n")
		return lines[len(lines)-1]
	}

	for _, step := range []struct {
		name    string
		queue   func()
		want    string
		outcome string
	}{
		// Nothing handled yet: no chain to walk.
		{"first request", func() { dispatch("homepage", false) }, "pull=", "success"},
		{"one dispatch", func() { dispatch("homepage", false) }, "pull=homepage", "success"},
		{"folded dispatches", func() {
			dispatch("ui-showcase", false)
			dispatch("codec", false)
			dispatch("ui-showcase", false)
		}, "pull=codec,ui-showcase", "success"},
		{"full request in the fold", func() {
			dispatch("codec", false)
			o.request(m1, nil, false)
			dispatch("homepage", false)
		}, "pull=", "success"},
		{"unsigned request in the fold", func() {
			dispatch("codec", true)
			dispatch("homepage", false)
		}, "pull=", "success"},
		{"full request alone", func() { o.request(m1, nil, false) }, "pull=", "success"},
	} {
		step.queue()
		if r := a.mustPoll(t); r.Outcome != step.outcome {
			t.Fatalf("%s: outcome %s (%s)", step.name, r.Outcome, r.Detail)
		}
		if got := last(); got != step.want {
			t.Errorf("%s: %q, want %q", step.name, got, step.want)
		}
	}

	// A deploy branch rewritten under the agent (prev no longer an
	// ancestor) pulls everything.
	if got := PullScope(mustHead(t, a), "0000000000000000000000000000000000000000", o.keyring); got != "" {
		t.Errorf("unreachable prev: %q, want all", got)
	}
}

func mustHead(t *testing.T, a *Agent) *object.Commit {
	t.Helper()
	c, err := a.repo.Head(DeployBranch(a.cfg.Host))
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func TestImageTags(t *testing.T) {
	o := newOrigin(t)
	script := "#!/bin/bash\necho \"tags=$OPENVOX_IMAGE_TAGS\" >> \"$APPLY_LOG\"\n"
	m1 := o.commit("main", plumbing.ZeroHash, map[string]string{"scripts/apply.sh": script}, false)
	a, applyLog := newAgent(t, o, &recorder{})
	dispatch := func(svc, tag string) {
		o.request(m1, func(r *Request) { r.Trigger, r.Service, r.ImageTag = "repository_dispatch", svc, tag }, false)
	}
	last := func() string {
		t.Helper()
		lines := strings.Split(strings.TrimSpace(mustRead(t, applyLog)), "\n")
		return lines[len(lines)-1]
	}

	for _, step := range []struct {
		name  string
		queue func()
		want  string
	}{
		{"untagged dispatch", func() { dispatch("homepage", "") }, "tags="},
		{"tagged dispatch", func() { dispatch("homepage", "sha-1a2b3c4") }, "tags=homepage=sha-1a2b3c4"},
		// The pin outlives requests that do not name a tag for it.
		{"full request keeps the pin", func() { o.request(m1, nil, false) }, "tags=homepage=sha-1a2b3c4"},
		{"other service", func() { dispatch("codec", "v1.2.0") }, "tags=codec=v1.2.0,homepage=sha-1a2b3c4"},
		// Folded: the newest request per service wins.
		{"folded retag", func() {
			dispatch("homepage", "sha-2")
			dispatch("homepage", "sha-3")
		}, "tags=codec=v1.2.0,homepage=sha-3"},
		{"latest clears", func() { dispatch("homepage", "latest") }, "tags=codec=v1.2.0"},
		{"no tag clears", func() { dispatch("codec", "") }, "tags="},
	} {
		step.queue()
		if r := a.mustPoll(t); r.Outcome != "success" {
			t.Fatalf("%s: outcome %s (%s)", step.name, r.Outcome, r.Detail)
		}
		if got := last(); got != step.want {
			t.Errorf("%s: %q, want %q", step.name, got, step.want)
		}
	}
}

func TestImageTagValidation(t *testing.T) {
	base := Request{ID: "20261121T200000Z", Host: "h", Commit: strings.Repeat("a", 40), Trigger: "repository_dispatch", Service: "homepage"}
	for tag, ok := range map[string]bool{
		"sha-1a2b3c4": true, "v1.2.3": true, "latest": true, "1.0_rc1": true,
		".hidden": false, "a b": false, "x\nIMAGE_TAG=evil": false, strings.Repeat("a", 129): false,
	} {
		r := base
		r.ImageTag = tag
		if err := r.Validate(); (err == nil) != ok {
			t.Errorf("tag %q: err %v, want ok=%v", tag, err, ok)
		}
	}
	r := base
	r.Service, r.ImageTag = "", "v1"
	if r.Validate() == nil {
		t.Error("image_tag without service accepted")
	}
	// Old requests (no image_tag key) still parse.
	if _, err := ParseRequest([]byte(`{"id":"20261121T200000Z","host":"h","commit":"` + strings.Repeat("a", 40) + `","trigger":"manual","service":"","staging_services":"","docker_prune":false,"reboot_if_needed":false}`)); err != nil {
		t.Errorf("request without image_tag: %v", err)
	}
}
