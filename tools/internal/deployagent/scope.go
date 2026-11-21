package deployagent

import (
	"sort"
	"strings"

	"github.com/go-git/go-git/v5/plumbing/object"
)

// maxFold bounds the walk back from the head request. More requests than
// this between two applies is no longer a burst of builds: pull everything.
const maxFold = 100

// PullScope returns the services whose images an apply of head pulls,
// comma-separated and sorted, or "" for all of them.
//
// Requests that arrive while an apply runs fold into the next one: the
// agent applies only the head of deploy/<host> (twelve dispatches made
// three applies, 2026-11-21). A repository_dispatch request names one
// service, so the head alone would drop the services of the requests it
// replaced. PullScope walks from head back to prev, the request handled
// last, and unions their services. It returns "" (all services) as soon
// as a request on the way names none (any other trigger), is not a
// signed, valid request, or the walk does not reach prev.
func PullScope(head *object.Commit, prev, keyring string) string {
	if prev == "" {
		return ""
	}
	seen := map[string]bool{}
	c := head
	for range maxFold {
		if c.Hash.String() == prev {
			names := make([]string, 0, len(seen))
			for s := range seen {
				names = append(names, s)
			}
			sort.Strings(names)
			return strings.Join(names, ",")
		}
		if _, err := Verify(c, keyring); err != nil {
			return ""
		}
		data, err := ReadFile(c, RequestPath)
		if err != nil {
			return ""
		}
		req, err := ParseRequest(data)
		if err != nil || req.Service == "" {
			return ""
		}
		seen[req.Service] = true
		if c.NumParents() != 1 {
			return ""
		}
		if c, err = c.Parent(0); err != nil {
			return ""
		}
	}
	return ""
}
