package storage

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestNewFileCache(t *testing.T) {
	tmpDir := t.TempDir()
	cacheDir := filepath.Join(tmpDir, "cache")

	cache, err := NewFileCache(cacheDir)
	if err != nil {
		t.Fatalf("Failed to create cache: %v", err)
	}

	if cache == nil {
		t.Fatal("Cache is nil")
	}

	// Verify directory was created
	if _, err := os.Stat(cacheDir); os.IsNotExist(err) {
		t.Error("Cache directory was not created")
	}
}

func TestFileCache_SetAndGet(t *testing.T) {
	tmpDir := t.TempDir()
	cache, err := NewFileCache(tmpDir)
	if err != nil {
		t.Fatalf("Failed to create cache: %v", err)
	}

	// Test data
	key := "test-key"
	data := []byte("test data")
	ttl := 1 * time.Hour

	// Set data
	if setErr := cache.Set(key, data, ttl); setErr != nil {
		t.Fatalf("Failed to set cache: %v", setErr)
	}

	// Get data
	retrieved, err := cache.Get(key)
	if err != nil {
		t.Fatalf("Failed to get cache: %v", err)
	}

	if string(retrieved) != string(data) {
		t.Errorf("Retrieved data mismatch. Expected %s, got %s", data, retrieved)
	}
}

func TestFileCache_GetNonExistent(t *testing.T) {
	tmpDir := t.TempDir()
	cache, err := NewFileCache(tmpDir)
	if err != nil {
		t.Fatalf("Failed to create cache: %v", err)
	}

	// Get non-existent key
	data, err := cache.Get("non-existent")
	if err != nil {
		t.Fatalf("Get returned error for non-existent key: %v", err)
	}

	if data != nil {
		t.Error("Expected nil for non-existent key")
	}
}

func TestFileCache_Expiration(t *testing.T) {
	tmpDir := t.TempDir()
	cache, err := NewFileCache(tmpDir)
	if err != nil {
		t.Fatalf("Failed to create cache: %v", err)
	}

	key := "expire-test"
	data := []byte("will expire")

	// Set with very short TTL
	if setErr := cache.Set(key, data, 100*time.Millisecond); setErr != nil {
		t.Fatalf("Failed to set cache: %v", setErr)
	}

	// Should be available immediately
	retrieved, err := cache.Get(key)
	if err != nil {
		t.Fatalf("Failed to get cache: %v", err)
	}
	if retrieved == nil {
		t.Error("Data should be available before expiration")
	}

	// Wait for expiration
	time.Sleep(200 * time.Millisecond)

	// Should be nil after expiration
	retrieved, err = cache.Get(key)
	if err != nil {
		t.Fatalf("Failed to get cache after expiration: %v", err)
	}
	if retrieved != nil {
		t.Error("Data should be nil after expiration")
	}
}

func TestFileCache_Delete(t *testing.T) {
	tmpDir := t.TempDir()
	cache, err := NewFileCache(tmpDir)
	if err != nil {
		t.Fatalf("Failed to create cache: %v", err)
	}

	key := "delete-test"
	data := []byte("to be deleted")

	// Set data
	if setErr := cache.Set(key, data, 1*time.Hour); setErr != nil {
		t.Fatalf("Failed to set cache: %v", setErr)
	}

	// Verify it exists
	retrieved, getErr := cache.Get(key)
	if getErr != nil {
		t.Fatalf("Failed to get cache: %v", getErr)
	}
	if retrieved == nil {
		t.Fatal("Data should exist before deletion")
	}

	// Delete
	if delErr := cache.Delete(key); delErr != nil {
		t.Fatalf("Failed to delete cache: %v", delErr)
	}

	// Verify it's gone
	retrieved, err = cache.Get(key)
	if err != nil {
		t.Fatalf("Failed to get cache after deletion: %v", err)
	}
	if retrieved != nil {
		t.Error("Data should be nil after deletion")
	}
}

func TestFileCache_Clear(t *testing.T) {
	tmpDir := t.TempDir()
	cache, err := NewFileCache(tmpDir)
	if err != nil {
		t.Fatalf("Failed to create cache: %v", err)
	}

	// Set multiple keys
	keys := []string{"key1", "key2", "key3"}
	for _, key := range keys {
		if err := cache.Set(key, []byte("data"), 1*time.Hour); err != nil {
			t.Fatalf("Failed to set cache for %s: %v", key, err)
		}
	}

	// Clear all
	if err := cache.Clear(); err != nil {
		t.Fatalf("Failed to clear cache: %v", err)
	}

	// Verify all keys are gone
	for _, key := range keys {
		data, err := cache.Get(key)
		if err != nil {
			t.Fatalf("Failed to get cache for %s: %v", key, err)
		}
		if data != nil {
			t.Errorf("Key %s should be cleared", key)
		}
	}
}

func TestSanitizeKey(t *testing.T) {
	tests := []struct {
		input    string
		expected string
	}{
		{"simple", "simple"},
		{"with-dash", "with-dash"},
		{"with_underscore", "with_underscore"},
		{"with spaces", "with_spaces"},
		{"with/slash", "with_slash"},
		{"with@special!chars", "with_special_chars"},
		{"123numbers", "123numbers"},
	}

	for _, tt := range tests {
		result := sanitizeKey(tt.input)
		if result != tt.expected {
			t.Errorf("sanitizeKey(%q) = %q, expected %q", tt.input, result, tt.expected)
		}
	}
}
