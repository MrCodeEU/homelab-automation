package collectors

import "testing"

func TestDowntimeMinutes(t *testing.T) {
	cases := []struct {
		pct, window, want float64
	}{
		{100, 1440, 0},
		{99, 1440, 14},
		{50, 1440, 720},
		{0, 60, 60},
	}
	for _, c := range cases {
		if got := downtimeMinutes(c.pct, c.window); got != c.want {
			t.Errorf("downtimeMinutes(%v,%v)=%v want %v", c.pct, c.window, got, c.want)
		}
	}
}

func TestAvailabilityMessage(t *testing.T) {
	got := availabilityMessage("glucava", 99, 99.9, true)
	want := "glucava was 99.00% available over 24h (~14 min down), 99.90% over 7d (~10 min down)"
	if got != want {
		t.Errorf("got %q want %q", got, want)
	}
	if got := availabilityMessage("x", 100, 0, false); got != "x was 100.00% available over 24h (~0 min down)" {
		t.Errorf("no-7d message wrong: %q", got)
	}
}
