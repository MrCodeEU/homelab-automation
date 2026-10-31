package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"golang.org/x/text/unicode/norm"
)

func TestClassifyAndDest(t *testing.T) {
	cases := []struct {
		rel  string
		cls  class
		dest string
	}{
		{"Sync/Persönliches/Wichtige Dokumente/Zeugnise/a.pdf", persoenlich, "Persönlich/Inbox/Wichtige Dokumente/Zeugnise/a.pdf"},
		{"Sync/Persönliches/Bewerben/2024/Ventopay/x/y/a.pdf", persoenlich, "Persönlich/Inbox/Bewerben/2024/a.pdf"},
		{"Fotos/Wichtiges Scans Adressen/Scans Wichtig/s.pdf", persoenlich, "Persönlich/Inbox/Scans Wichtig/s.pdf"},
		{"Sync/JKU Semester 7/Micro Controller/deep/er/f.pptx", wissen, "Wissen/JKU Semester 7/Micro Controller/f.pptx"},
		{"Sync/HTL/f.pdf", wissen, "Wissen/HTL/f.pdf"},
		{"Fotos/Fotos/2020/Trip/t.pdf", unsortiert, "Unsortiert/Inbox/Fotos/2020/t.pdf"},
		{"Sync/MrCode USB Stick/x.pdf", unsortiert, "Unsortiert/Inbox/MrCode USB Stick/x.pdf"},
		{"Sync/Games/manual.pdf", skip, ""},
		{"Fotos/Passwords-Backup.docx", skip, ""},
	}
	for _, c := range cases {
		cls, root := classify(c.rel)
		if cls != c.cls {
			t.Errorf("%s: class %s, want %s", c.rel, cls, c.cls)
			continue
		}
		if cls == skip {
			continue
		}
		if got := destFor(c.rel, cls, root); got != c.dest {
			t.Errorf("%s: dest %q, want %q", c.rel, got, c.dest)
		}
	}
}

func TestClassifyNFD(t *testing.T) {
	rel := norm.NFD.String("Sync/Persönliches/a.pdf")
	if cls, _ := classify(rel); cls != persoenlich {
		t.Fatalf("NFD path classified as %s", cls)
	}
}

func TestPlanDedupePrefersHigherPriority(t *testing.T) {
	root := t.TempDir()
	write := func(rel, content string) {
		p := filepath.Join(root, rel)
		os.MkdirAll(filepath.Dir(p), 0o755)
		os.WriteFile(p, []byte(content), 0o644)
	}
	write("Sync/HTL/copy.pdf", "same-content")
	write("Sync/Persönliches/Dokumente/orig.pdf", "same-content")
	write("Sync/HTL/other.pdf", "other-content!")
	write("Sync/Persönliches/.stversions/old.pdf", "ignored")
	write("Sync/Games/m.pdf", "game")
	write("Sync/HTL/~$tmp.docx", "lock")
	files, err := walk(root, true)
	if err != nil {
		t.Fatal(err)
	}
	res := buildPlan(root, files)
	if res.dupes != 1 {
		t.Fatalf("dupes = %d, want 1", res.dupes)
	}
	var kept []string
	for _, r := range res.rows {
		kept = append(kept, r.rel)
	}
	want := map[string]bool{"Sync/Persönliches/Dokumente/orig.pdf": true, "Sync/HTL/other.pdf": true}
	if len(kept) != 2 || !want[kept[0]] || !want[kept[1]] {
		t.Fatalf("kept %v", kept)
	}
	if res.stats[skip][0] != 1 {
		t.Fatalf("skip count %d, want 1", res.stats[skip][0])
	}
}

func TestCopyFileCreatesOwnedDirsAndKeepsMtime(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "src.pdf")
	os.WriteFile(src, []byte("data"), 0o644)
	old := time.Date(2019, 3, 4, 5, 6, 7, 0, time.UTC)
	os.Chtimes(src, old, old)
	consume := filepath.Join(dir, "consume")
	os.Mkdir(consume, 0o755)
	dst := filepath.Join(consume, "Wissen", "HTL", "src.pdf")
	if err := copyFile(src, dst, consume, os.Getuid(), os.Getgid()); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(dst)
	if err != nil || !info.ModTime().Equal(old) {
		t.Fatalf("copy missing or mtime lost: %v %v", err, info)
	}
	if err := copyFile(src, dst, consume, os.Getuid(), os.Getgid()); err == nil {
		t.Fatal("copy over an existing file must fail (O_EXCL)")
	}
}
