package catalogdiff

import (
	"encoding/json"
	"fmt"
	"strings"
)

// HostResult is one host's comparison for the report. BaseErr set: the base
// catalog did not compile (every head resource then counts as added).
type HostResult struct {
	Host    string
	Changes []Change
	BaseErr string
}

// maxLines caps each side of a shown text change.
const maxLines = 40

// Markdown renders the report: a table of counts, then per host the
// resources with their changed parameters, collapsed.
func Markdown(title string, results []HostResult) string {
	var b strings.Builder
	fmt.Fprintf(&b, "## %s\n\n", title)
	b.WriteString("Compiled without hosts: facts from `openvox/ci/facts`, secrets as placeholders (`scripts/catalog-compile.sh`).\n\n")
	b.WriteString("| Host | Added | Removed | Changed |\n|---|---|---|---|\n")
	for _, r := range results {
		a, d, c := counts(r.Changes)
		fmt.Fprintf(&b, "| %s | %d | %d | %d |\n", r.Host, a, d, c)
	}
	for _, r := range results {
		b.WriteString("\n")
		if r.BaseErr != "" {
			fmt.Fprintf(&b, "**%s:** the base catalog did not compile, so everything counts as added:\n```\n%s\n```\n", r.Host, tail(r.BaseErr, 10))
		}
		if len(r.Changes) == 0 {
			fmt.Fprintf(&b, "**%s:** no changes.\n", r.Host)
			continue
		}
		fmt.Fprintf(&b, "<details><summary><b>%s</b>: %d resource(s)</summary>\n\n", r.Host, len(r.Changes))
		for _, c := range r.Changes {
			switch c.Kind {
			case "added":
				fmt.Fprintf(&b, "- **added** `%s`\n", c.Key)
			case "removed":
				fmt.Fprintf(&b, "- **removed** `%s`\n", c.Key)
			default:
				fmt.Fprintf(&b, "- **changed** `%s`\n", c.Key)
				for _, p := range c.Params {
					writeParam(&b, p)
				}
			}
		}
		b.WriteString("\n</details>\n")
	}
	return b.String()
}

func counts(cs []Change) (added, removed, changed int) {
	for _, c := range cs {
		switch c.Kind {
		case "added":
			added++
		case "removed":
			removed++
		default:
			changed++
		}
	}
	return
}

func writeParam(b *strings.Builder, p ParamChange) {
	switch {
	case p.Sensitive:
		fmt.Fprintf(b, "  - `%s`: changed (sensitive, not shown)\n", p.Name)
	case len(p.Files) > 0:
		fmt.Fprintf(b, "  - `%s` content:", p.Name)
		for _, f := range p.Files {
			fmt.Fprintf(b, " `%s`", f)
		}
		b.WriteString("\n")
	default:
		os, oml := render(p.Old)
		ns, nml := render(p.New)
		if !oml && !nml {
			fmt.Fprintf(b, "  - `%s`: `%s` → `%s`\n", p.Name, os, ns)
			return
		}
		fmt.Fprintf(b, "  - `%s`:\n\n```diff\n%s```\n\n", p.Name, textDiff(os, ns))
	}
}

// render returns a value as text, and whether it spans lines.
func render(v any) (string, bool) {
	switch t := v.(type) {
	case nil:
		return "(unset)", false
	case string:
		return t, strings.Contains(t, "\n")
	default:
		data, _ := json.Marshal(t)
		return string(data), false
	}
}

// textDiff shows the changed middle of two texts: common leading and
// trailing lines are cut, each side is capped at maxLines.
func textDiff(a, b string) string {
	al, bl := strings.Split(a, "\n"), strings.Split(b, "\n")
	pre := 0
	for pre < len(al) && pre < len(bl) && al[pre] == bl[pre] {
		pre++
	}
	suf := 0
	for suf < len(al)-pre && suf < len(bl)-pre && al[len(al)-1-suf] == bl[len(bl)-1-suf] {
		suf++
	}
	var out strings.Builder
	if pre > 0 {
		fmt.Fprintf(&out, "@@ %d unchanged line(s) @@\n", pre)
	}
	side := func(lines []string, sign string) {
		for i, l := range lines {
			if i == maxLines {
				fmt.Fprintf(&out, "%s ... %d more line(s)\n", sign, len(lines)-maxLines)
				return
			}
			out.WriteString(sign + l + "\n")
		}
	}
	side(al[pre:len(al)-suf], "-")
	side(bl[pre:len(bl)-suf], "+")
	if suf > 0 {
		fmt.Fprintf(&out, "@@ %d unchanged line(s) @@\n", suf)
	}
	return out.String()
}

func tail(s string, n int) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}
