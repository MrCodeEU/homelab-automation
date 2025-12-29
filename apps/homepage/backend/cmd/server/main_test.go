package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/mrcodeeu/homepage/internal/scrapers"
)

// mockCache for testing
type mockCache struct {
	data map[string][]byte
}

func newMockCache() *mockCache {
	return &mockCache{
		data: make(map[string][]byte),
	}
}

func (m *mockCache) Get(key string) ([]byte, error) {
	data, ok := m.data[key]
	if !ok {
		return nil, nil
	}
	return data, nil
}

func (m *mockCache) Set(key string, data []byte, ttl time.Duration) error {
	m.data[key] = data
	return nil
}

func (m *mockCache) Delete(key string) error {
	delete(m.data, key)
	return nil
}

func (m *mockCache) Clear() error {
	m.data = make(map[string][]byte)
	return nil
}

// setupTestScraper initializes the global githubScraper for testing
func setupTestScraper() {
	cache := newMockCache()
	githubScraper = scrapers.NewGitHubScraper("testuser", "", cache)

	// Pre-populate cache with test data
	testProjects := []scrapers.Project{
		{
			Name:        "test-project",
			Description: "A test project",
			URL:         "https://github.com/testuser/test-project",
			Stars:       10,
			Language:    "Go",
			Topics:      []string{"test"},
			Images:      []string{},
			Featured:    false,
		},
	}

	data, err := json.Marshal(testProjects)
	if err != nil {
		panic(fmt.Sprintf("Failed to marshal test data: %v", err))
	}
	if err := cache.Set("github_projects", data, 1*time.Hour); err != nil {
		panic(fmt.Sprintf("Failed to set cache: %v", err))
	}
}

func TestHandleHealth(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/api/health", nil)
	w := httptest.NewRecorder()

	handleHealth(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("Expected status 200, got %d", w.Code)
	}

	var response map[string]interface{}
	if err := json.NewDecoder(w.Body).Decode(&response); err != nil {
		t.Fatalf("Failed to decode response: %v", err)
	}

	if response["status"] != "healthy" {
		t.Errorf("Expected status 'healthy', got %v", response["status"])
	}

	if _, ok := response["time"]; !ok {
		t.Error("Expected 'time' field in response")
	}
}

func TestHandleCV(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/api/cv", nil)
	w := httptest.NewRecorder()

	handleCV(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("Expected status 200, got %d", w.Code)
	}

	var response map[string]interface{}
	if err := json.NewDecoder(w.Body).Decode(&response); err != nil {
		t.Fatalf("Failed to decode response: %v", err)
	}

	// Check required fields
	requiredFields := []string{"name", "title", "summary", "experience", "education", "skills"}
	for _, field := range requiredFields {
		if _, ok := response[field]; !ok {
			t.Errorf("Expected field '%s' in CV response", field)
		}
	}
}

func TestHandleProjects(t *testing.T) {
	// Setup test scraper with mock data
	setupTestScraper()

	req := httptest.NewRequest(http.MethodGet, "/api/projects", nil)
	w := httptest.NewRecorder()

	handleProjects(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("Expected status 200, got %d", w.Code)
	}

	var response []map[string]interface{}
	if err := json.NewDecoder(w.Body).Decode(&response); err != nil {
		t.Fatalf("Failed to decode response: %v", err)
	}

	if len(response) == 0 {
		t.Error("Expected at least one project in response")
	}

	// Check first project has required fields
	if len(response) > 0 {
		project := response[0]
		requiredFields := []string{"name", "description", "url", "stars", "language"}
		for _, field := range requiredFields {
			if _, ok := project[field]; !ok {
				t.Errorf("Expected field '%s' in project", field)
			}
		}
	}
}

func TestHandleStrava(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/api/strava", nil)
	w := httptest.NewRecorder()

	handleStrava(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("Expected status 200, got %d", w.Code)
	}

	var response map[string]interface{}
	if err := json.NewDecoder(w.Body).Decode(&response); err != nil {
		t.Fatalf("Failed to decode response: %v", err)
	}

	// Check required fields
	requiredFields := []string{"total_activities", "total_distance", "total_time", "recent_runs"}
	for _, field := range requiredFields {
		if _, ok := response[field]; !ok {
			t.Errorf("Expected field '%s' in Strava response", field)
		}
	}
}

func TestCORSMiddleware(t *testing.T) {
	handler := corsMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))

	// Test with localhost origin (should be allowed)
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set("Origin", "http://localhost:5173")
	w := httptest.NewRecorder()

	handler.ServeHTTP(w, req)

	if w.Header().Get("Access-Control-Allow-Origin") != "http://localhost:5173" {
		t.Errorf("Expected CORS header to be 'http://localhost:5173', got '%s'", w.Header().Get("Access-Control-Allow-Origin"))
	}

	// Test without origin (should not set CORS header)
	req2 := httptest.NewRequest(http.MethodGet, "/", nil)
	w2 := httptest.NewRecorder()

	handler.ServeHTTP(w2, req2)

	if w2.Header().Get("Access-Control-Allow-Origin") != "" {
		t.Errorf("Expected no CORS header for same-origin request, got '%s'", w2.Header().Get("Access-Control-Allow-Origin"))
	}
}

func TestCORSPreflight(t *testing.T) {
	handler := corsMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))

	req := httptest.NewRequest(http.MethodOptions, "/", nil)
	w := httptest.NewRecorder()

	handler.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("Expected status 200 for OPTIONS request, got %d", w.Code)
	}
}
