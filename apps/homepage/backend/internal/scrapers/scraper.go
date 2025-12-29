package scrapers

import "time"

// Scraper defines the interface for data scrapers
type Scraper interface {
	// Name returns the scraper's name
	Name() string

	// Scrape fetches fresh data
	Scrape() (any, error)

	// GetCached returns cached data or scrapes if cache is empty/expired
	GetCached() (any, error)

	// Refresh forces a fresh scrape and updates cache
	Refresh() (any, error)
}

// Config holds scraper configuration
type Config struct {
	// GitHub configuration
	GitHubToken    string
	GitHubUsername string

	// Strava configuration
	StravaClientID     string
	StravaClientSecret string
	StravaRefreshToken string

	// LinkedIn configuration (future use)
	LinkedInAPIKey    string
	LinkedInAPISecret string

	// Cache settings
	CacheTTL time.Duration
}
