package main

import (
	"context"
	"embed"
	"encoding/json"
	"fmt"
	"io/fs"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/mrcodeeu/homepage/internal/config"
	"github.com/mrcodeeu/homepage/internal/scrapers"
	"github.com/mrcodeeu/homepage/internal/storage"
)

//go:embed all:static
var staticFiles embed.FS

// Global scrapers (initialized in main)
var (
	githubScraper *scrapers.GitHubScraper
)

func main() {
	// Load configuration
	cfg := config.Load()

	// Initialize cache
	cache, err := storage.NewFileCache(cfg.CacheDir)
	if err != nil {
		log.Fatalf("Failed to create cache: %v", err)
	}
	log.Printf("Cache initialized at %s", cfg.CacheDir)

	// Initialize GitHub scraper
	githubScraper = scrapers.NewGitHubScraper(cfg.GitHubUsername, cfg.GitHubToken, cache)
	log.Printf("GitHub scraper initialized for user: %s", cfg.GitHubUsername)

	// Create HTTP server
	mux := http.NewServeMux()

	// Serve embedded static files
	staticFS, err := fs.Sub(staticFiles, "static")
	if err != nil {
		log.Fatal("Failed to load static files:", err)
	}

	// Debug: List embedded files
	log.Println("Embedded static files:")
	if err := fs.WalkDir(staticFS, ".", func(path string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			log.Printf("  - %s", path)
		}
		return nil
	}); err != nil {
		log.Printf("Warning: Failed to list static files: %v", err)
	}

	// Serve static files directly
	mux.Handle("/", http.FileServer(http.FS(staticFS)))

	// API endpoints
	mux.HandleFunc("/api/health", handleHealth)
	mux.HandleFunc("/api/cv", handleCV)
	mux.HandleFunc("/api/projects", handleProjects)
	mux.HandleFunc("/api/strava", handleStrava)

	// Create server
	srv := &http.Server{
		Addr:         fmt.Sprintf(":%s", cfg.Port),
		Handler:      corsMiddleware(loggingMiddleware(mux)),
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 15 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	// Start server in goroutine
	go func() {
		log.Printf("Server starting on port %s", cfg.Port)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("Server failed to start: %v", err)
		}
	}()

	// Graceful shutdown
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	log.Println("Server shutting down...")
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if err := srv.Shutdown(ctx); err != nil {
		log.Fatalf("Server forced to shutdown: %v", err)
	}

	log.Println("Server stopped")
}

// Middleware for CORS
func corsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		// Allow localhost for development and same-origin for production
		if origin == "http://localhost:5173" || origin == "" {
			if origin != "" {
				w.Header().Set("Access-Control-Allow-Origin", origin)
			}
		}
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type")

		if r.Method == "OPTIONS" {
			w.WriteHeader(http.StatusOK)
			return
		}

		next.ServeHTTP(w, r)
	})
}

// Middleware for logging
func loggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		log.Printf("%s %s %v", r.Method, r.URL.Path, time.Since(start))
	})
}

// Health check endpoint
func handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(map[string]interface{}{
		"status": "healthy",
		"time":   time.Now().Format(time.RFC3339),
	}); err != nil {
		log.Printf("Error encoding health response: %v", err)
	}
}

// CV endpoint (mock data for MVP)
func handleCV(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	cv := map[string]interface{}{
		"name":    "Your Name",
		"title":   "Software Engineer",
		"summary": "Building awesome things with Go and Svelte",
		"experience": []map[string]interface{}{
			{
				"title":       "Senior Developer",
				"company":     "Tech Corp",
				"location":    "Remote",
				"start_date":  "2020-01",
				"end_date":    "Present",
				"description": "Leading development of cloud infrastructure",
			},
			{
				"title":       "Developer",
				"company":     "Startup Inc",
				"location":    "Vienna, Austria",
				"start_date":  "2018-01",
				"end_date":    "2020-01",
				"description": "Full-stack development with modern technologies",
			},
		},
		"education": []map[string]interface{}{
			{
				"school":     "University Name",
				"degree":     "Bachelor of Science",
				"field":      "Computer Science",
				"start_date": "2014",
				"end_date":   "2018",
			},
		},
		"skills": []string{"Go", "Svelte", "Kubernetes", "Docker", "Ansible"},
	}
	if err := json.NewEncoder(w).Encode(cv); err != nil {
		http.Error(w, "Failed to encode CV data", http.StatusInternalServerError)
		log.Printf("Error encoding CV response: %v", err)
	}
}

// Projects endpoint - uses GitHub scraper
func handleProjects(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	// Get projects from GitHub scraper (uses cache if available)
	projects, err := githubScraper.GetCached()
	if err != nil {
		log.Printf("Error fetching projects: %v", err)
		http.Error(w, "Failed to fetch projects", http.StatusInternalServerError)
		return
	}

	if err := json.NewEncoder(w).Encode(projects); err != nil {
		http.Error(w, "Failed to encode projects data", http.StatusInternalServerError)
		log.Printf("Error encoding projects response: %v", err)
	}
}

// Strava endpoint (mock data for MVP)
func handleStrava(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	stats := map[string]interface{}{
		"total_activities": 42,
		"total_distance":   245.5,
		"total_time":       36000,
		"recent_runs": []map[string]interface{}{
			{
				"name":        "Morning Run",
				"distance":    5.2,
				"moving_time": 1800,
				"date":        "2025-01-15",
			},
			{
				"name":        "Evening Run",
				"distance":    8.5,
				"moving_time": 3000,
				"date":        "2025-01-12",
			},
		},
	}
	if err := json.NewEncoder(w).Encode(stats); err != nil {
		http.Error(w, "Failed to encode Strava data", http.StatusInternalServerError)
		log.Printf("Error encoding Strava response: %v", err)
	}
}
