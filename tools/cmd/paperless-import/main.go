// paperless-import is a one-shot backfill of existing NAS documents into
// paperless-ngx. It runs on nas (static linux/amd64 binary) and never
// modifies a source file: it only reads them and copies into paperless'
// consume dir.
//
//	paperless-import plan                 # walk, dedupe, write manifest + report
//	paperless-import apply [--batch N]    # copy next batches, wait for ingest
//
// Folder names under consume/ become tags (PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS),
// so the destination path is the tagging scheme:
//
//	persoenlich -> Persönlich/Inbox/<sub1>/<sub2>/file   (reviewed by hand)
//	wissen      -> Wissen/<sub1>/<sub2>/file             (reference material)
//	unsortiert  -> Unsortiert/Inbox/<top>/<sub1>/file    (decide later)
//
// At most two sub-folder levels below the rule root become tags; deeper
// files are flattened into their level-2 folder so the tag count stays sane.
//
// Identical content (sha256) is imported once and the highest-priority class
// wins (persoenlich > wissen > unsortiert). State lives in --state, so apply
// can be interrupted and re-run.
package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"golang.org/x/text/unicode/norm"
)

const maxTagDepth = 2

type class string

const (
	persoenlich class = "persoenlich"
	wissen      class = "wissen"
	unsortiert  class = "unsortiert"
	skip        class = "skip"
)

var priority = map[class]int{persoenlich: 0, wissen: 1, unsortiert: 2}

var topName = map[class]string{
	persoenlich: "Persönlich/Inbox",
	wissen:      "Wissen",
	unsortiert:  "Unsortiert/Inbox",
}

type rule struct {
	prefix string // relative to the source root, NFC
	cls    class
	root   string // path whose sub-folders become tags
}

var scanRoots = []string{"Fotos", "Sync", "cloud", "opencloud"}

// First matching prefix wins. Anything under a scanned root that matches no
// rule becomes unsortiert.
var rules = []rule{
	{"Fotos/Wichtiges Scans Adressen", persoenlich, "Fotos/Wichtiges Scans Adressen"},
	{"Sync/Persönliches", persoenlich, "Sync/Persönliches"},
	{"Sync/1_2021WS", wissen, "Sync"},
	{"Sync/2_2022SS", wissen, "Sync"},
	{"Sync/3_2022WS", wissen, "Sync"},
	{"Sync/4_2023SS", wissen, "Sync"},
	{"Sync/5_2023WS", wissen, "Sync"},
	{"Sync/6_2024SS", wissen, "Sync"},
	{"Sync/JKU Semester 7", wissen, "Sync"},
	{"Sync/JKU Semester 8", wissen, "Sync"},
	{"Sync/JKU Semester 9", wissen, "Sync"},
	{"Sync/HTL", wissen, "Sync"},
	{"Sync/HackTheBox", wissen, "Sync"},
	// Not documents worth indexing (game manuals, old device dumps, web
	// projects, media) or too sensitive for a bulk copy.
	{"Fotos/Passwords-Backup.docx", skip, ""},
	{"Fotos/Musik", skip, ""},
	{"Fotos/Videos", skip, ""},
	{"Sync/Games", skip, ""},
	{"Sync/Nintendo 2DS Backup", skip, ""},
	{"Sync/NUC_Old", skip, ""},
	{"Sync/Pi4Old", skip, ""},
	{"Sync/WebDev", skip, ""},
}

var skipDirs = map[string]bool{
	".stversions": true, ".stfolder": true, ".Recycle.Bin": true,
	".git": true, "node_modules": true, "__pycache__": true,
}

var officeExts = map[string]bool{
	".doc": true, ".docx": true, ".odt": true, ".ppt": true, ".pptx": true, ".xls": true, ".xlsx": true,
}

func allowedExt(ext string, office bool) bool {
	switch ext {
	case ".pdf", ".tif", ".tiff":
		return true
	}
	return office && officeExts[ext]
}

// classify returns the class and tag root for a path relative to the source
// root. Syncthing/macOS may store names decomposed (NFD); rules are NFC.
func classify(rel string) (class, string) {
	rel = norm.NFC.String(rel)
	for _, r := range rules {
		if rel == r.prefix || strings.HasPrefix(rel, r.prefix+"/") {
			return r.cls, r.root
		}
	}
	parts := strings.Split(rel, "/")
	if len(parts) > 2 {
		parts = parts[:2]
	}
	return unsortiert, strings.Join(parts, "/")
}

// destFor builds the consume-relative destination path for a source file.
func destFor(rel string, cls class, root string) string {
	rel = norm.NFC.String(rel)
	var parts []string
	if root != "" {
		sub := strings.TrimPrefix(strings.TrimPrefix(rel, root), "/")
		for _, p := range strings.Split(filepath.Dir(sub), "/") {
			if p != "" && p != "." {
				parts = append(parts, p)
			}
		}
	}
	if len(parts) > maxTagDepth {
		parts = parts[:maxTagDepth]
	}
	if cls == unsortiert {
		base := filepath.Base(root)
		if base == "." || base == "/" || base == "" {
			base = "Sonstige"
		}
		keep := parts
		if len(keep) > 1 {
			keep = keep[:1]
		}
		parts = append([]string{base}, keep...)
	}
	return filepath.Join(append([]string{topName[cls]}, append(parts, filepath.Base(rel))...)...)
}

type file struct {
	rel  string
	size int64
}

func walk(srcRoot string, office bool) ([]file, error) {
	var out []file
	for _, top := range scanRoots {
		base := filepath.Join(srcRoot, top)
		if _, err := os.Stat(base); err != nil {
			continue
		}
		err := filepath.WalkDir(base, func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return nil // unreadable entry: skip, never abort the walk
			}
			if d.IsDir() {
				if skipDirs[d.Name()] {
					return filepath.SkipDir
				}
				return nil
			}
			low := strings.ToLower(d.Name())
			if strings.HasPrefix(low, "~$") || strings.HasPrefix(low, ".~lock") || strings.HasPrefix(low, "._") {
				return nil
			}
			if !allowedExt(filepath.Ext(low), office) {
				return nil
			}
			info, err := d.Info()
			if err != nil || !info.Mode().IsRegular() || info.Size() == 0 {
				return nil
			}
			rel, _ := filepath.Rel(srcRoot, path)
			out = append(out, file{rel: filepath.ToSlash(rel), size: info.Size()})
			return nil
		})
		if err != nil {
			return nil, err
		}
	}
	return out, nil
}

func sha256File(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

type row struct {
	cls  class
	rel  string
	dest string
	size int64
	sha  string
}

type planResult struct {
	rows    []row
	dupes   int
	scanned int
	stats   map[class][2]int64 // files, bytes
}

// buildPlan classifies, hashes size-colliding files only (unique sizes
// cannot be duplicates) and drops exact duplicates, keeping the
// highest-priority copy.
func buildPlan(srcRoot string, files []file) planResult {
	bySize := map[int64][]string{}
	for _, f := range files {
		bySize[f.size] = append(bySize[f.size], f.rel)
	}
	hashes := map[string]string{}
	for _, rels := range bySize {
		if len(rels) < 2 {
			continue
		}
		for _, rel := range rels {
			if h, err := sha256File(filepath.Join(srcRoot, rel)); err == nil {
				hashes[rel] = h
			}
		}
	}
	type keyed struct {
		f   file
		cls class
		rt  string
	}
	ks := make([]keyed, 0, len(files))
	for _, f := range files {
		c, rt := classify(f.rel)
		ks = append(ks, keyed{f, c, rt})
	}
	sort.Slice(ks, func(i, j int) bool {
		pi, oki := priority[ks[i].cls]
		pj, okj := priority[ks[j].cls]
		if !oki {
			pi = 9
		}
		if !okj {
			pj = 9
		}
		if pi != pj {
			return pi < pj
		}
		return ks[i].f.rel < ks[j].f.rel
	})
	res := planResult{scanned: len(files), stats: map[class][2]int64{}}
	seen := map[string]bool{}
	for _, k := range ks {
		st := res.stats[k.cls]
		if k.cls == skip {
			st[0]++
			st[1] += k.f.size
			res.stats[k.cls] = st
			continue
		}
		if h := hashes[k.f.rel]; h != "" {
			if seen[h] {
				res.dupes++
				continue
			}
			seen[h] = true
		}
		res.rows = append(res.rows, row{k.cls, k.f.rel, destFor(k.f.rel, k.cls, k.rt), k.f.size, hashes[k.f.rel]})
		st[0]++
		st[1] += k.f.size
		res.stats[k.cls] = st
	}
	return res
}

func writeManifest(path string, rows []row) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	w := bufio.NewWriter(f)
	for _, r := range rows {
		fmt.Fprintf(w, "%s\t%s\t%s\t%d\t%s\n", r.cls, r.rel, r.dest, r.size, r.sha)
	}
	return w.Flush()
}

func readManifest(path string) ([]row, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var rows []row
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	for sc.Scan() {
		p := strings.Split(sc.Text(), "\t")
		if len(p) != 5 {
			continue
		}
		var size int64
		fmt.Sscan(p[3], &size)
		rows = append(rows, row{class(p[0]), p[1], p[2], size, p[4]})
	}
	return rows, sc.Err()
}

func cmdPlan(args []string) error {
	fs := flag.NewFlagSet("plan", flag.ExitOnError)
	src := fs.String("src", "/mnt/user", "source root")
	state := fs.String("state", "/mnt/user/appdata/paperless/import-state", "state dir")
	noOffice := fs.Bool("no-office", false, "PDF/TIFF only")
	fs.Parse(args)

	files, err := walk(*src, !*noOffice)
	if err != nil {
		return err
	}
	res := buildPlan(*src, files)
	if err := os.MkdirAll(*state, 0o755); err != nil {
		return err
	}
	manifest := filepath.Join(*state, "manifest.tsv")
	if err := writeManifest(manifest, res.rows); err != nil {
		return err
	}
	fmt.Printf("scanned %d files, %d exact duplicates dropped\n", res.scanned, res.dupes)
	for _, c := range []class{persoenlich, wissen, unsortiert, skip} {
		st := res.stats[c]
		fmt.Printf("  %-12s %6d files %9.1f MB\n", c, st[0], float64(st[1])/1e6)
	}
	fmt.Printf("manifest: %s (%d rows)\n", manifest, len(res.rows))
	tops := map[string]int{}
	for _, r := range res.rows {
		if r.cls == unsortiert {
			p := strings.Split(r.rel, "/")
			if len(p) > 2 {
				p = p[:2]
			}
			tops[strings.Join(p, "/")]++
		}
	}
	if len(tops) > 0 {
		keys := make([]string, 0, len(tops))
		for k := range tops {
			keys = append(keys, k)
		}
		sort.Slice(keys, func(i, j int) bool { return tops[keys[i]] > tops[keys[j]] })
		fmt.Println("unsortiert by folder (add a rule to move/skip):")
		for _, k := range keys {
			fmt.Printf("  %5d  %s\n", tops[k], k)
		}
	}
	return nil
}

func countFiles(dir string) int {
	n := 0
	filepath.WalkDir(dir, func(_ string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			n++
		}
		return nil
	})
	return n
}

// waitDrained blocks until paperless has consumed (and removed) every file,
// or until the count has not changed for stall.
func waitDrained(consume string, stall, poll time.Duration) bool {
	last, lastChange := countFiles(consume), time.Now()
	for last > 0 {
		time.Sleep(poll)
		cur := countFiles(consume)
		if cur != last {
			last, lastChange = cur, time.Now()
		} else if time.Since(lastChange) > stall {
			return false
		}
	}
	return true
}

// quarantine moves files paperless could not ingest out of consume so they
// stop blocking the next batch.
func quarantine(consume, failed string) int {
	n := 0
	filepath.WalkDir(consume, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		rel, _ := filepath.Rel(consume, path)
		dst := filepath.Join(failed, rel)
		if os.MkdirAll(filepath.Dir(dst), 0o755) == nil && os.Rename(path, dst) == nil {
			n++
		}
		return nil
	})
	return n
}

// mkdirAllOwned creates dir (and missing parents below stop) owned by
// uid:gid, so the unprivileged paperless user can consume and delete files.
func mkdirAllOwned(dir, stop string, uid, gid int) error {
	var missing []string
	for d := dir; d != stop && d != "/" && d != "."; d = filepath.Dir(d) {
		if _, err := os.Stat(d); err == nil {
			break
		}
		missing = append(missing, d)
	}
	for i := len(missing) - 1; i >= 0; i-- {
		if err := os.Mkdir(missing[i], 0o755); err != nil && !os.IsExist(err) {
			return err
		}
		if err := os.Lchown(missing[i], uid, gid); err != nil {
			return err
		}
	}
	return nil
}

func copyFile(src, dst, consume string, uid, gid int) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	info, err := in.Stat()
	if err != nil {
		return err
	}
	if err := mkdirAllOwned(filepath.Dir(dst), consume, uid, gid); err != nil {
		return err
	}
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		os.Remove(dst)
		return err
	}
	if err := out.Close(); err != nil {
		return err
	}
	if err := os.Lchown(dst, uid, gid); err != nil {
		return err
	}
	// Keep the source mtime: paperless falls back to it as the created date.
	return os.Chtimes(dst, info.ModTime(), info.ModTime())
}

func cmdApply(args []string) error {
	fs := flag.NewFlagSet("apply", flag.ExitOnError)
	src := fs.String("src", "/mnt/user", "source root")
	consume := fs.String("consume", "/mnt/user/appdata/paperless/consume", "paperless consume dir")
	state := fs.String("state", "/mnt/user/appdata/paperless/import-state", "state dir")
	batch := fs.Int("batch", 100, "files per batch")
	maxBatches := fs.Int("max-batches", 0, "stop after N batches (0 = all)")
	only := fs.String("only", "", "only this class (persoenlich|wissen|unsortiert)")
	uid := fs.Int("uid", 1000, "owner uid of created files (paperless container user)")
	gid := fs.Int("gid", 1000, "owner gid of created files")
	stall := fs.Duration("stall", 15*time.Minute, "no progress before leftovers are quarantined")
	fs.Parse(args)

	rows, err := readManifest(filepath.Join(*state, "manifest.tsv"))
	if err != nil {
		return fmt.Errorf("no manifest - run plan first: %w", err)
	}
	donePath := filepath.Join(*state, "done.tsv")
	done := map[string]bool{}
	if f, err := os.Open(donePath); err == nil {
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 1<<20), 1<<20)
		for sc.Scan() {
			done[strings.SplitN(sc.Text(), "\t", 2)[0]] = true
		}
		f.Close()
	}
	var todo []row
	for _, r := range rows {
		if !done[r.rel] && (*only == "" || string(r.cls) == *only) {
			todo = append(todo, r)
		}
	}
	fmt.Printf("%d files to import, batch size %d\n", len(todo), *batch)
	log, err := os.OpenFile(donePath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer log.Close()
	for b, i := 1, 0; i < len(todo); b, i = b+1, i+*batch {
		end := min(i+*batch, len(todo))
		copied := 0
		for _, r := range todo[i:end] {
			target := filepath.Join(*consume, r.dest)
			if _, err := os.Stat(target); err == nil {
				ext := filepath.Ext(target)
				sum := r.sha
				if sum == "" {
					h := sha256.Sum256([]byte(r.rel))
					sum = hex.EncodeToString(h[:])
				}
				target = strings.TrimSuffix(target, ext) + "-" + sum[:8] + ext
			}
			if err := copyFile(filepath.Join(*src, r.rel), target, *consume, *uid, *gid); err != nil {
				fmt.Fprintf(os.Stderr, "copy %s: %v\n", r.rel, err)
				continue
			}
			fmt.Fprintf(log, "%s\t%s\n", r.rel, target)
			copied++
		}
		ok := waitDrained(*consume, *stall, 15*time.Second)
		q := 0
		if !ok {
			q = quarantine(*consume, filepath.Join(*state, "failed"))
		}
		fmt.Printf("batch %d: %d copied, drained=%v, quarantined=%d\n", b, copied, ok, q)
		if *maxBatches > 0 && b >= *maxBatches {
			break
		}
	}
	return nil
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: paperless-import plan|apply [flags]")
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "plan":
		err = cmdPlan(os.Args[2:])
	case "apply":
		err = cmdApply(os.Args[2:])
	default:
		err = fmt.Errorf("unknown command %q", os.Args[1])
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}
