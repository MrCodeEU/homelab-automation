package config

import (
	"os"
	"testing"
)

func TestLoad(t *testing.T) {
	// Set test environment variables
	if err := os.Setenv("PORT", "9999"); err != nil {
		t.Fatalf("Failed to set PORT env var: %v", err)
	}
	if err := os.Setenv("GITHUB_USERNAME", "testuser"); err != nil {
		t.Fatalf("Failed to set GITHUB_USERNAME env var: %v", err)
	}
	defer func() {
		if err := os.Unsetenv("PORT"); err != nil {
			t.Logf("Failed to unset PORT: %v", err)
		}
		if err := os.Unsetenv("GITHUB_USERNAME"); err != nil {
			t.Logf("Failed to unset GITHUB_USERNAME: %v", err)
		}
	}()

	cfg := Load()

	if cfg.Port != "9999" {
		t.Errorf("Expected port 9999, got %s", cfg.Port)
	}

	if cfg.GitHubUsername != "testuser" {
		t.Errorf("Expected GitHub username 'testuser', got %s", cfg.GitHubUsername)
	}
}

func TestLoadDefaults(t *testing.T) {
	// Ensure env vars are not set
	if err := os.Unsetenv("PORT"); err != nil {
		t.Logf("Failed to unset PORT: %v", err)
	}
	if err := os.Unsetenv("GITHUB_USERNAME"); err != nil {
		t.Logf("Failed to unset GITHUB_USERNAME: %v", err)
	}

	cfg := Load()

	if cfg.Port != "8080" {
		t.Errorf("Expected default port 8080, got %s", cfg.Port)
	}

	if cfg.GitHubUsername != "mrcodeeu" {
		t.Errorf("Expected default GitHub username 'mrcodeeu', got %s", cfg.GitHubUsername)
	}

	if cfg.CacheTTLHours != 24 {
		t.Errorf("Expected cache TTL 24 hours, got %d", cfg.CacheTTLHours)
	}
}
