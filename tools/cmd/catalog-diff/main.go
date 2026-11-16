// Command catalog-diff compares the catalogs scripts/catalog-compile.sh
// wrote for a base and a head tree and prints a Markdown report:
//
//	catalog-diff [-title TEXT] <base-catalogs> <head-catalogs> <base-openvox> <head-openvox>
//
// One report row per <certname>.json in the head directory. A host whose head
// catalog is missing is an error (exit 1); a missing base catalog (the base
// did not compile) is reported, with everything counted as added.
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/MrCodeEU/homelab-automation/tools/internal/catalogdiff"
)

func main() {
	title := flag.String("title", "Catalog diff", "report heading")
	flag.Parse()
	if flag.NArg() != 4 {
		fmt.Fprintln(os.Stderr, "usage: catalog-diff [-title TEXT] <base-catalogs> <head-catalogs> <base-openvox> <head-openvox>")
		os.Exit(2)
	}
	baseDir, headDir, baseTree, headTree := flag.Arg(0), flag.Arg(1), flag.Arg(2), flag.Arg(3)
	heads, err := filepath.Glob(filepath.Join(headDir, "*.json"))
	if err != nil || len(heads) == 0 {
		fmt.Fprintf(os.Stderr, "no catalogs in %s\n", headDir)
		os.Exit(1)
	}
	sort.Strings(heads)
	var results []catalogdiff.HostResult
	for _, hp := range heads {
		name := strings.TrimSuffix(filepath.Base(hp), ".json")
		head, err := catalogdiff.Load(hp)
		if err != nil {
			fmt.Fprintf(os.Stderr, "head catalog %s: %v\n", name, err)
			os.Exit(1)
		}
		r := catalogdiff.HostResult{Host: strings.SplitN(name, ".", 2)[0]}
		base, err := catalogdiff.Load(filepath.Join(baseDir, name+".json"))
		if err != nil {
			r.BaseErr = err.Error()
			if msg, rerr := os.ReadFile(filepath.Join(baseDir, name+".err")); rerr == nil && len(msg) > 0 {
				r.BaseErr = string(msg)
			}
			base = nil
		}
		r.Changes = catalogdiff.Diff(base, head, baseTree, headTree)
		results = append(results, r)
	}
	fmt.Print(catalogdiff.Markdown(*title, results))
}
