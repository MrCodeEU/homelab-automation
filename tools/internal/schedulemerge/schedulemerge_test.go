package schedulemerge

import "testing"

func TestScheduleID(t *testing.T) {
	cases := map[string]string{
		"homelab-compose-up":   "schedulehomelabcomposeup",
		"aoostar-display-stop": "scheduleaoostardisplaystop",
		"nas-backup":           "schedulenasbackup",
	}
	for name, want := range cases {
		if got := scheduleID(name); got != want {
			t.Errorf("scheduleID(%q) = %q, want %q", name, got, want)
		}
	}
}

func TestMarshalSortedIsStable(t *testing.T) {
	m := map[string]any{"b": map[string]any{"x": 1}, "a": map[string]any{"y": "z"}}
	first, err := marshalSorted(m)
	if err != nil {
		t.Fatal(err)
	}
	second, err := marshalSorted(m)
	if err != nil {
		t.Fatal(err)
	}
	if first != second {
		t.Fatalf("marshalSorted not deterministic:\n%s\n%s", first, second)
	}
	if first[:6] != "{\n    " {
		t.Fatalf("unexpected indent: %q", first[:10])
	}
}
