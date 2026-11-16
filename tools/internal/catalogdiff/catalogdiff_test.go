package catalogdiff

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func tree(t *testing.T, files map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	for p, c := range files {
		full := filepath.Join(dir, "modules", "roles", "files", p)
		os.MkdirAll(filepath.Dir(full), 0o755)
		if err := os.WriteFile(full, []byte(c), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func res(typ, title string, params map[string]any, sensitive ...string) Resource {
	return Resource{Type: typ, Title: title, Parameters: params, Sensitive: sensitive}
}

func TestDiff(t *testing.T) {
	baseTree := tree(t, map[string]string{"base/a.sh": "one", "base/b.sh": "two", "single.sh": "x", "dir/same": "s"})
	headTree := tree(t, map[string]string{"base/a.sh": "ONE", "base/c.sh": "new", "single.sh": "y", "dir/same": "s"})
	src := func(p string) map[string]any { return map[string]any{"source": "puppet:///modules/roles/" + p} }
	base := &Catalog{Resources: []Resource{
		res("File", "/etc/base", src("base")),
		res("File", "/usr/bin/single", src("single.sh")),
		res("File", "/etc/same", src("dir")),
		res("File", "/etc/forge", map[string]any{"source": "puppet:///modules/docker/x"}),
		res("File", "/etc/env", map[string]any{"content": "A=1\n"}, "content"),
		res("File", "/etc/conf", map[string]any{"content": "a\nb\nc\n", "mode": "0644"}),
		res("Package", "old", nil),
	}}
	head := &Catalog{Resources: []Resource{
		res("File", "/etc/base", src("base")),
		res("File", "/usr/bin/single", src("single.sh")),
		res("File", "/etc/same", src("dir")),
		res("File", "/etc/forge", map[string]any{"source": "puppet:///modules/docker/x"}),
		res("File", "/etc/env", map[string]any{"content": "A=2\n"}, "content"),
		res("File", "/etc/conf", map[string]any{"content": "a\nB\nc\n", "mode": "0600"}),
		res("Package", "new", nil),
	}}

	got := map[string]Change{}
	for _, c := range Diff(base, head, baseTree, headTree) {
		got[c.Key] = c
	}
	want := map[string]string{
		"File[/etc/base]": "changed", "File[/usr/bin/single]": "changed",
		"File[/etc/env]": "changed", "File[/etc/conf]": "changed",
		"Package[old]": "removed", "Package[new]": "added",
	}
	if len(got) != len(want) {
		t.Errorf("got %d changes, want %d: %v", len(got), len(want), got)
	}
	for k, kind := range want {
		if got[k].Kind != kind {
			t.Errorf("%s: got %q, want %q", k, got[k].Kind, kind)
		}
	}
	if f := got["File[/etc/base]"].Params[0].Files; strings.Join(f, ",") != "~ a.sh,- b.sh,+ c.sh" {
		t.Errorf("directory source files: %v", f)
	}
	if f := got["File[/usr/bin/single]"].Params[0].Files; strings.Join(f, ",") != "~ single.sh" {
		t.Errorf("file source: %v", f)
	}

	md := Markdown("Catalog diff", []HostResult{{Host: "nuc", Changes: Diff(base, head, baseTree, headTree)}})
	for _, s := range []string{
		"| nuc | 1 | 1 | 4 |",
		"`content`: changed (sensitive, not shown)",
		"`mode`: `0644` → `0600`",
		"-b\n+B\n",
		"`source` content: `~ a.sh` `- b.sh` `+ c.sh`",
	} {
		if !strings.Contains(md, s) {
			t.Errorf("markdown lacks %q:\n%s", s, md)
		}
	}
	if strings.Contains(md, "A=2") {
		t.Errorf("sensitive value rendered:\n%s", md)
	}
}

func TestTextDiffCaps(t *testing.T) {
	var a, b []string
	for i := 0; i < 100; i++ {
		a = append(a, "old")
		b = append(b, "new")
	}
	d := textDiff(strings.Join(a, "\n"), strings.Join(b, "\n"))
	if !strings.Contains(d, "- ... 60 more line(s)") || strings.Count(d, "\n") > 2*maxLines+4 {
		t.Errorf("not capped:\n%s", d)
	}
}
