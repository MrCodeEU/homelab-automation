// Package catalogdiff compares two compiled Puppet catalogs of one host
// (scripts/catalog-compile.sh) and renders the difference as Markdown for
// the PR check's job summary.
//
// A catalog holds a file resource's `source` only as a URL, so a change to a
// script or binary under modules/<m>/files would be invisible. Each
// puppet:///modules/<m>/<path> source is resolved in its own tree and
// compared by content, file by file for recursive directory sources.
package catalogdiff

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
)

// Resource is one catalog resource, as `puppet catalog compile` renders it.
type Resource struct {
	Type       string         `json:"type"`
	Title      any            `json:"title"`
	Parameters map[string]any `json:"parameters"`
	Sensitive  []string       `json:"sensitive_parameters"`
}

func (r Resource) Key() string { return fmt.Sprintf("%s[%v]", r.Type, r.Title) }

// Catalog is the part of a compiled catalog the diff uses.
type Catalog struct {
	Name      string     `json:"name"`
	Resources []Resource `json:"resources"`
}

// Load reads a compiled catalog.
func Load(path string) (*Catalog, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var c Catalog
	if err := json.Unmarshal(data, &c); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return &c, nil
}

// Change is one resource that differs.
type Change struct {
	Key    string
	Kind   string // added, removed, changed
	Params []ParamChange
}

// ParamChange is one differing parameter of a changed resource.
type ParamChange struct {
	Name      string
	Old, New  any
	Sensitive bool
	// Files lists, for a source parameter, the files whose content differs
	// ("~ path", "+ path", "- path"); empty when only the URL changed.
	Files []string
}

// Diff compares base and head. baseTree and headTree are the openvox/
// directories the catalogs were compiled from, for source contents.
func Diff(base, head *Catalog, baseTree, headTree string) []Change {
	b, h := index(base), index(head)
	var out []Change
	for k, hr := range h {
		br, ok := b[k]
		if !ok {
			out = append(out, Change{Key: k, Kind: "added"})
			continue
		}
		if ps := diffParams(br, hr, baseTree, headTree); len(ps) > 0 {
			out = append(out, Change{Key: k, Kind: "changed", Params: ps})
		}
	}
	for k := range b {
		if _, ok := h[k]; !ok {
			out = append(out, Change{Key: k, Kind: "removed"})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Key < out[j].Key })
	return out
}

func index(c *Catalog) map[string]Resource {
	m := map[string]Resource{}
	if c == nil {
		return m
	}
	for _, r := range c.Resources {
		m[r.Key()] = r
	}
	return m
}

func diffParams(b, h Resource, baseTree, headTree string) []ParamChange {
	names := map[string]bool{}
	for n := range b.Parameters {
		names[n] = true
	}
	for n := range h.Parameters {
		names[n] = true
	}
	sensitive := map[string]bool{}
	for _, n := range append(append([]string{}, b.Sensitive...), h.Sensitive...) {
		sensitive[n] = true
	}
	var out []ParamChange
	for n := range names {
		ov, nv := b.Parameters[n], h.Parameters[n]
		pc := ParamChange{Name: n, Old: ov, New: nv, Sensitive: sensitive[n]}
		if n == "source" {
			pc.Files = sourceDiff(ov, nv, baseTree, headTree)
			if len(pc.Files) > 0 || !reflect.DeepEqual(ov, nv) {
				out = append(out, pc)
			}
			continue
		}
		if !reflect.DeepEqual(ov, nv) {
			out = append(out, pc)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

// sourceDiff compares the content behind two source values. Only single
// puppet:///modules/ URLs are resolved; anything else compares as a value.
func sourceDiff(ov, nv any, baseTree, headTree string) []string {
	bs, ok1 := ov.(string)
	hs, ok2 := nv.(string)
	if !ok1 || !ok2 {
		return nil
	}
	bf, bok := sourceFiles(baseTree, bs)
	hf, hok := sourceFiles(headTree, hs)
	if !bok || !hok {
		return nil
	}
	var out []string
	for p, sum := range hf {
		if old, ok := bf[p]; !ok {
			out = append(out, "+ "+p)
		} else if old != sum {
			out = append(out, "~ "+p)
		}
	}
	for p := range bf {
		if _, ok := hf[p]; !ok {
			out = append(out, "- "+p)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i][2:] < out[j][2:] })
	return out
}

// sourceFiles maps the files behind a puppet:///modules/<m>/<path> URL in
// tree to their SHA-256: one entry ("") for a file, one per file for a
// directory. false when the URL is not resolvable there (e.g. a Forge
// module, which the tree does not contain).
func sourceFiles(tree, src string) (map[string]string, bool) {
	rest, ok := strings.CutPrefix(src, "puppet:///modules/")
	if !ok {
		return nil, false
	}
	mod, path, ok := strings.Cut(rest, "/")
	if !ok || !filepath.IsLocal(path) || !filepath.IsLocal(mod) {
		return nil, false
	}
	root := filepath.Join(tree, "modules", mod, "files", path)
	info, err := os.Stat(root)
	if err != nil {
		return nil, false
	}
	out := map[string]string{}
	if !info.IsDir() {
		sum, err := fileSum(root)
		if err != nil {
			return nil, false
		}
		out[filepath.Base(path)] = sum
		return out, true
	}
	err = filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		sum, err := fileSum(p)
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, p)
		out[rel] = sum
		return nil
	})
	return out, err == nil
}

func fileSum(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	s := sha256.Sum256(data)
	return hex.EncodeToString(s[:]), nil
}
