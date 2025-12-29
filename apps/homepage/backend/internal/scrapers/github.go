package scrapers

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/mrcodeeu/homepage/internal/storage"
)

const (
	githubAPIBase   = "https://api.github.com"
	portfolioFile   = ".portfolio"
	cacheKeyGitHub  = "github_projects"
	defaultCacheTTL = 1 * time.Hour
)

// GitHubScraper implements the Scraper interface for GitHub repositories
type GitHubScraper struct {
	username string
	token    string
	cache    storage.Cache
	cacheTTL time.Duration
	client   *http.Client
}

// NewGitHubScraper creates a new GitHub scraper
func NewGitHubScraper(username, token string, cache storage.Cache) *GitHubScraper {
	// Validate username format (GitHub usernames are alphanumeric + hyphens)
	if err := validateUsername(username); err != nil {
		log.Printf("Warning: Invalid GitHub username format: %v", err)
	}

	return &GitHubScraper{
		username: username,
		token:    token,
		cache:    cache,
		cacheTTL: defaultCacheTTL,
		client: &http.Client{
			Timeout: 30 * time.Second,
		},
	}
}

// validateUsername validates GitHub username format
func validateUsername(username string) error {
	if username == "" {
		return fmt.Errorf("username cannot be empty")
	}
	matched, _ := regexp.MatchString(`^[a-zA-Z0-9-]+$`, username)
	if !matched {
		return fmt.Errorf("invalid GitHub username (must be alphanumeric with hyphens)")
	}
	return nil
}

// Name returns the scraper name
func (g *GitHubScraper) Name() string {
	return "github"
}

// Project represents a GitHub project
type Project struct {
	Name        string   `json:"name"`
	Description string   `json:"description"`
	URL         string   `json:"url"`
	Stars       int      `json:"stars"`
	Language    string   `json:"language"`
	Topics      []string `json:"topics"`
	Images      []string `json:"images"`
	Featured    bool     `json:"featured"`
}

// PortfolioMetadata represents .portfolio file content
type PortfolioMetadata struct {
	Description string   `json:"description,omitempty"`
	Images      []string `json:"images,omitempty"`
	Featured    bool     `json:"featured,omitempty"`
	Tags        []string `json:"tags,omitempty"`
}

// GitHubRepo represents a GitHub repository from the API
type GitHubRepo struct {
	Name        string   `json:"name"`
	Description string   `json:"description"`
	HTMLURL     string   `json:"html_url"`
	Language    string   `json:"language"`
	StarCount   int      `json:"stargazers_count"`
	Topics      []string `json:"topics"`
	Private     bool     `json:"private"`
}

// GetCached returns cached projects or scrapes if needed
func (g *GitHubScraper) GetCached() (any, error) {
	// Try to get from cache
	cached, err := g.cache.Get(cacheKeyGitHub)
	if err != nil {
		return nil, fmt.Errorf("cache error: %w", err)
	}

	if cached != nil {
		var projects []Project
		if err := json.Unmarshal(cached, &projects); err != nil {
			// Invalid cache, scrape fresh data
			return g.Refresh()
		}
		return projects, nil
	}

	// Cache miss, scrape fresh data
	return g.Refresh()
}

// Scrape fetches fresh data from GitHub
func (g *GitHubScraper) Scrape() (any, error) {
	// Get all repositories
	repos, err := g.fetchRepositories()
	if err != nil {
		return nil, fmt.Errorf("failed to fetch repositories: %w", err)
	}

	// Filter and enrich portfolio projects
	projects := make([]Project, 0)
	for _, repo := range repos {
		// Skip private repos
		if repo.Private {
			continue
		}

		// Check for portfolio marker
		hasMarker, metadata, err := g.checkPortfolioMarker(repo.Name)
		if err != nil {
			// Log error but continue
			continue
		}

		if !hasMarker {
			continue
		}

		// Build project
		project := Project{
			Name:        repo.Name,
			Description: repo.Description,
			URL:         repo.HTMLURL,
			Stars:       repo.StarCount,
			Language:    repo.Language,
			Topics:      repo.Topics,
			Featured:    metadata.Featured,
		}

		// Override description if provided in metadata
		if metadata.Description != "" {
			project.Description = metadata.Description
		}

		// Merge images from metadata and README
		images := make([]string, 0)

		// Convert metadata images (from .portfolio) to absolute URLs if needed
		for _, img := range metadata.Images {
			images = append(images, g.normalizeImageURL(img, repo.Name))
		}

		// Try to extract images from README
		readmeImages, err := g.extractImagesFromREADME(repo.Name)
		if err == nil {
			images = append(images, readmeImages...)
		}

		project.Images = deduplicateStrings(images)

		projects = append(projects, project)
	}

	return projects, nil
}

// Refresh forces a fresh scrape and updates cache
func (g *GitHubScraper) Refresh() (any, error) {
	projects, err := g.Scrape()
	if err != nil {
		return nil, err
	}

	// Update cache
	data, err := json.Marshal(projects)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal projects: %w", err)
	}

	if err := g.cache.Set(cacheKeyGitHub, data, g.cacheTTL); err != nil {
		// Log error but don't fail - we still have the data
		log.Printf("Warning: failed to update cache: %v", err)
	}

	return projects, nil
}

// fetchRepositories gets all repositories for the user
func (g *GitHubScraper) fetchRepositories() ([]GitHubRepo, error) {
	url := fmt.Sprintf("%s/users/%s/repos?per_page=100", githubAPIBase, g.username)

	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}

	// Add authentication if token is provided
	if g.token != "" {
		req.Header.Set("Authorization", fmt.Sprintf("Bearer %s", g.token))
	}
	req.Header.Set("Accept", "application/vnd.github.v3+json")

	resp, err := g.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to fetch repositories: %w", err)
	}
	defer func() {
		if closeErr := resp.Body.Close(); closeErr != nil {
			log.Printf("Warning: failed to close response body: %v", closeErr)
		}
	}()

	if resp.StatusCode != http.StatusOK {
		body, readErr := io.ReadAll(resp.Body)
		if readErr != nil {
			return nil, fmt.Errorf("GitHub API returned status %d (failed to read body)", resp.StatusCode)
		}
		return nil, fmt.Errorf("GitHub API returned status %d: %s", resp.StatusCode, string(body))
	}

	var repos []GitHubRepo
	if err := json.NewDecoder(resp.Body).Decode(&repos); err != nil {
		return nil, fmt.Errorf("failed to decode response: %w", err)
	}

	return repos, nil
}

// checkPortfolioMarker checks if a repository has a portfolio marker
func (g *GitHubScraper) checkPortfolioMarker(repoName string) (bool, PortfolioMetadata, error) {
	// Try to fetch .portfolio file
	content, err := g.fetchFileContent(repoName, portfolioFile)
	if err == nil {
		// Parse .portfolio JSON
		var metadata PortfolioMetadata
		if unmarshalErr := json.Unmarshal([]byte(content), &metadata); unmarshalErr != nil {
			return false, PortfolioMetadata{}, fmt.Errorf("invalid .portfolio file: %w", unmarshalErr)
		}
		return true, metadata, nil
	}

	// If .portfolio doesn't exist, check README for marker
	readme, err := g.fetchREADME(repoName)
	if err != nil {
		return false, PortfolioMetadata{}, err
	}

	// Check for <!-- PORTFOLIO --> comment or 🎨 emoji
	if strings.Contains(readme, "<!-- PORTFOLIO -->") || strings.Contains(readme, "🎨") {
		return true, PortfolioMetadata{}, nil
	}

	return false, PortfolioMetadata{}, nil
}

// fetchFileContent fetches a file from a repository
func (g *GitHubScraper) fetchFileContent(repoName, filePath string) (string, error) {
	url := fmt.Sprintf("%s/repos/%s/%s/contents/%s", githubAPIBase, g.username, repoName, filePath)

	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return "", fmt.Errorf("failed to create request: %w", err)
	}

	if g.token != "" {
		req.Header.Set("Authorization", fmt.Sprintf("Bearer %s", g.token))
	}
	req.Header.Set("Accept", "application/vnd.github.v3.raw")

	resp, err := g.client.Do(req)
	if err != nil {
		return "", fmt.Errorf("failed to fetch file: %w", err)
	}
	defer func() {
		if closeErr := resp.Body.Close(); closeErr != nil {
			log.Printf("Warning: failed to close response body: %v", closeErr)
		}
	}()

	if resp.StatusCode == http.StatusNotFound {
		return "", fmt.Errorf("file not found")
	}

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("unexpected status code: %d", resp.StatusCode)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("failed to read response: %w", err)
	}

	return string(body), nil
}

// fetchREADME fetches the README file from a repository
func (g *GitHubScraper) fetchREADME(repoName string) (string, error) {
	// Try different README filename variations
	variations := []string{"README.md", "README.MD", "readme.md", "Readme.md", "README"}

	for _, filename := range variations {
		content, err := g.fetchFileContent(repoName, filename)
		if err == nil {
			return content, nil
		}
	}

	return "", fmt.Errorf("README not found")
}

// extractImagesFromREADME extracts image URLs from README markdown
func (g *GitHubScraper) extractImagesFromREADME(repoName string) ([]string, error) {
	readme, err := g.fetchREADME(repoName)
	if err != nil {
		return nil, err
	}

	// Regex to match markdown images: ![alt](url)
	imgRegex := regexp.MustCompile(`!\[.*?\]\((.*?)\)`)
	matches := imgRegex.FindAllStringSubmatch(readme, -1)

	images := make([]string, 0)
	for _, match := range matches {
		if len(match) > 1 {
			imageURL := g.normalizeImageURL(match[1], repoName)
			images = append(images, imageURL)
		}
	}

	return images, nil
}

// normalizeImageURL converts relative image paths to absolute GitHub URLs
func (g *GitHubScraper) normalizeImageURL(imageURL, repoName string) string {
	// If already an absolute URL (http/https), return as-is
	if strings.HasPrefix(imageURL, "http://") || strings.HasPrefix(imageURL, "https://") {
		return imageURL
	}

	// Remove leading ./ if present
	cleanPath := strings.TrimPrefix(imageURL, "./")

	// Remove leading / if present (for absolute paths within repo)
	cleanPath = strings.TrimPrefix(cleanPath, "/")

	// Convert to raw GitHub URL
	return fmt.Sprintf("https://raw.githubusercontent.com/%s/%s/main/%s",
		g.username, repoName, cleanPath)
}

// deduplicateStrings removes duplicate strings from a slice
func deduplicateStrings(slice []string) []string {
	seen := make(map[string]bool)
	result := make([]string, 0)

	for _, item := range slice {
		if !seen[item] {
			seen[item] = true
			result = append(result, item)
		}
	}

	return result
}
