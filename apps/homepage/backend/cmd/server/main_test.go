package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

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

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	w := httptest.NewRecorder()

	handler.ServeHTTP(w, req)

	if w.Header().Get("Access-Control-Allow-Origin") != "*" {
		t.Error("Expected CORS header to be set")
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
