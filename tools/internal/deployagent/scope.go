package deployagent

import (
	"sort"
	"strings"

	"github.com/go-git/go-git/v5/plumbing/object"
)

// maxFold bounds the walk back from the head request. More requests than
// this between two applies is no longer a burst of builds: pull everything.
const maxFold = 100

// fold returns the requests from head back to prev (the request handled
// last, exclusive), newest first. Requests that arrive while an apply runs
// fold into the next one: the agent applies only the head of deploy/<host>
// (twelve dispatches made three applies, 2026-11-21). complete is false
// when a commit on the way is not a signed, valid request or the walk does
// not reach prev; reqs then holds the requests before that point.
func fold(head *object.Commit, prev, keyring string) (reqs []Request, complete bool) {
	if prev == "" {
		return nil, false
	}
	c := head
	for range maxFold {
		if c.Hash.String() == prev {
			return reqs, true
		}
		if _, err := Verify(c, keyring); err != nil {
			return reqs, false
		}
		data, err := ReadFile(c, RequestPath)
		if err != nil {
			return reqs, false
		}
		req, err := ParseRequest(data)
		if err != nil {
			return reqs, false
		}
		reqs = append(reqs, req)
		if c.NumParents() != 1 {
			return reqs, false
		}
		if c, err = c.Parent(0); err != nil {
			return reqs, false
		}
	}
	return reqs, false
}

// PullScope returns the services whose images an apply of head pulls,
// comma-separated and sorted, or "" for all of them. A repository_dispatch
// request names one service, so the head alone would drop the services of
// the requests it replaced: PullScope unions the services of every request
// fold returns. It returns "" (all services) as soon as a request names
// none (any other trigger) or the fold is not complete.
func PullScope(head *object.Commit, prev, keyring string) string {
	reqs, complete := fold(head, prev, keyring)
	if !complete {
		return ""
	}
	seen := map[string]bool{}
	for _, r := range reqs {
		if r.Service == "" {
			return ""
		}
		seen[r.Service] = true
	}
	names := make([]string, 0, len(seen))
	for s := range seen {
		names = append(names, s)
	}
	sort.Strings(names)
	return strings.Join(names, ",")
}

// UpdateImageTags applies the image tags of the dispatches in reqs (newest
// first, as fold returns them) to tags, oldest first so the newest wins.
// A dispatch with a tag pins its service to it; one without (or with
// "latest") clears the pin, so the service runs `latest` again. The pins
// live in the agent's state, not in git: every apply passes them on
// (ImageTagsEnv), so a later apply without a tag does not bring the
// service back up on an older local `latest`.
func UpdateImageTags(tags map[string]string, reqs []Request) {
	for i := len(reqs) - 1; i >= 0; i-- {
		r := reqs[i]
		if r.Trigger != "repository_dispatch" || r.Service == "" {
			continue
		}
		if r.ImageTag == "" || r.ImageTag == "latest" {
			delete(tags, r.Service)
		} else {
			tags[r.Service] = r.ImageTag
		}
	}
}

// ImageTagsEnv is tags as OPENVOX_IMAGE_TAGS: service=tag pairs,
// comma-separated and sorted.
func ImageTagsEnv(tags map[string]string) string {
	pairs := make([]string, 0, len(tags))
	for s, t := range tags {
		pairs = append(pairs, s+"="+t)
	}
	sort.Strings(pairs)
	return strings.Join(pairs, ",")
}
