package storage

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"time"
)

// Cache defines the interface for caching data
type Cache interface {
	// Get retrieves data from cache. Returns nil if not found or expired.
	Get(key string) ([]byte, error)

	// Set stores data in cache with TTL
	Set(key string, data []byte, ttl time.Duration) error

	// Delete removes data from cache
	Delete(key string) error

	// Clear removes all cached data
	Clear() error
}

// CacheEntry represents a cached item with metadata
type CacheEntry struct {
	Data      []byte    `json:"data"`
	ExpiresAt time.Time `json:"expires_at"`
}

// FileCache implements Cache interface using file system
type FileCache struct {
	baseDir string
}

// NewFileCache creates a new file-based cache
func NewFileCache(baseDir string) (*FileCache, error) {
	// Create cache directory if it doesn't exist
	if err := os.MkdirAll(baseDir, 0755); err != nil {
		return nil, fmt.Errorf("failed to create cache directory: %w", err)
	}

	return &FileCache{
		baseDir: baseDir,
	}, nil
}

// Get retrieves data from cache
func (c *FileCache) Get(key string) ([]byte, error) {
	filePath := c.getFilePath(key)

	// Read cache file
	data, err := os.ReadFile(filePath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil // Cache miss
		}
		return nil, fmt.Errorf("failed to read cache file: %w", err)
	}

	// Parse cache entry
	var entry CacheEntry
	if err := json.Unmarshal(data, &entry); err != nil {
		// Invalid cache file, delete it
		if removeErr := os.Remove(filePath); removeErr != nil && !os.IsNotExist(removeErr) {
			log.Printf("Warning: failed to remove invalid cache file: %v", removeErr)
		}
		return nil, nil
	}

	// Check if expired
	if time.Now().After(entry.ExpiresAt) {
		// Expired, delete it
		if removeErr := os.Remove(filePath); removeErr != nil && !os.IsNotExist(removeErr) {
			// Log but don't fail on cleanup error
			log.Printf("Warning: failed to remove expired cache file: %v", removeErr)
		}
		return nil, nil
	}

	return entry.Data, nil
}

// Set stores data in cache
func (c *FileCache) Set(key string, data []byte, ttl time.Duration) error {
	entry := CacheEntry{
		Data:      data,
		ExpiresAt: time.Now().Add(ttl),
	}

	// Marshal entry
	entryData, err := json.Marshal(entry)
	if err != nil {
		return fmt.Errorf("failed to marshal cache entry: %w", err)
	}

	// Write to file
	filePath := c.getFilePath(key)
	if err := os.WriteFile(filePath, entryData, 0644); err != nil {
		return fmt.Errorf("failed to write cache file: %w", err)
	}

	return nil
}

// Delete removes data from cache
func (c *FileCache) Delete(key string) error {
	filePath := c.getFilePath(key)
	if err := os.Remove(filePath); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("failed to delete cache file: %w", err)
	}
	return nil
}

// Clear removes all cached data
func (c *FileCache) Clear() error {
	// Remove all files in cache directory
	entries, err := os.ReadDir(c.baseDir)
	if err != nil {
		return fmt.Errorf("failed to read cache directory: %w", err)
	}

	for _, entry := range entries {
		if !entry.IsDir() {
			filePath := filepath.Join(c.baseDir, entry.Name())
			if err := os.Remove(filePath); err != nil {
				return fmt.Errorf("failed to remove cache file %s: %w", entry.Name(), err)
			}
		}
	}

	return nil
}

// getFilePath returns the file path for a cache key
func (c *FileCache) getFilePath(key string) string {
	// Sanitize key to make it a valid filename
	safeKey := sanitizeKey(key)
	return filepath.Join(c.baseDir, fmt.Sprintf("%s.json", safeKey))
}

// sanitizeKey makes a cache key safe for use as a filename
func sanitizeKey(key string) string {
	// Replace problematic characters
	safe := ""
	for _, r := range key {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '-' || r == '_' {
			safe += string(r)
		} else {
			safe += "_"
		}
	}
	return safe
}
