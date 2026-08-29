package collectors

import (
	"testing"
	"time"
)

func TestVerificationStale(t *testing.T) {
	now := time.Now()
	fresh, _ := verificationStale(now.Add(-7*24*time.Hour).Format(time.RFC3339), backupIntegrityMaxAge)
	if fresh {
		t.Fatal("seven-day integrity result was marked stale")
	}
	stale, _ := verificationStale(now.Add(-9*24*time.Hour).Format(time.RFC3339), backupIntegrityMaxAge)
	if !stale {
		t.Fatal("nine-day integrity result was not marked stale")
	}
	invalid, _ := verificationStale("not-a-timestamp", backupIntegrityMaxAge)
	if !invalid {
		t.Fatal("invalid verification timestamp was not marked stale")
	}
}
