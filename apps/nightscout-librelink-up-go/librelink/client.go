package librelink

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

const (
	appVersion  = "4.17.0"
	appProduct  = "llu.android"
	contentType = "application/json"
)

// Regional API endpoints for LibreLink Up
var endpoints = map[string]string{
	"AE":  "https://api-ae.libreview.io",
	"AP":  "https://api-ap.libreview.io",
	"AU":  "https://api-au.libreview.io",
	"CA":  "https://api-ca.libreview.io",
	"DE":  "https://api-de.libreview.io",
	"EU":  "https://api-eu.libreview.io",
	"EU2": "https://api-eu2.libreview.io",
	"FR":  "https://api-fr.libreview.io",
	"JP":  "https://api-jp.libreview.io",
	"US":  "https://api-us.libreview.io",
	"LA":  "https://api-la.libreview.io",
	"RU":  "https://api-ru.libreview.io",
	"CN":  "https://api-cn.libreview.io",
}

// Client represents a LibreLink Up API client
type Client struct {
	baseURL    string
	username   string
	password   string
	authToken  string
	httpClient *http.Client
}

// Connection represents a LibreLink sensor connection
type Connection struct {
	PatientID   string `json:"patientId"`
	FirstName   string `json:"firstName"`
	LastName    string `json:"lastName"`
	SensorState int    `json:"sensor"`
}

// GlucoseReading represents a blood glucose measurement
type GlucoseReading struct {
	Value       float64
	Unit        string
	Timestamp   time.Time
	TrendArrow  string
}

// API request/response structures
type loginRequest struct {
	Email    string `json:"email"`
	Password string `json:"password"`
}

type loginResponse struct {
	Status int `json:"status"`
	Data   struct {
		User struct {
			ID    string `json:"id"`
			Email string `json:"email"`
		} `json:"user"`
		AuthTicket struct {
			Token     string    `json:"token"`
			ExpiresAt time.Time `json:"expires"`
		} `json:"authTicket"`
	} `json:"data"`
}

type connectionsResponse struct {
	Status int `json:"status"`
	Data   []struct {
		PatientID string `json:"patientId"`
		FirstName string `json:"firstName"`
		LastName  string `json:"lastName"`
		Sensor    struct {
			DeviceID string `json:"deviceId"`
			Serial   string `json:"sn"`
		} `json:"sensor"`
	} `json:"data"`
}

type glucoseResponse struct {
	Status int `json:"status"`
	Data   struct {
		Connection struct {
			GlucoseMeasurement struct {
				Value         float64 `json:"Value"`
				ValueInMgPerDl float64 `json:"ValueInMgPerDl"`
				TrendArrow    int     `json:"TrendArrow"`
				Timestamp     string  `json:"Timestamp"`
			} `json:"glucoseMeasurement"`
		} `json:"connection"`
	} `json:"data"`
}

// NewClient creates a new LibreLink Up client
func NewClient(region, username, password string) (*Client, error) {
	baseURL, ok := endpoints[region]
	if !ok {
		return nil, fmt.Errorf("unsupported region: %s", region)
	}

	return &Client{
		baseURL:  baseURL,
		username: username,
		password: password,
		httpClient: &http.Client{
			Timeout: 30 * time.Second,
		},
	}, nil
}

// Login authenticates with LibreLink Up and retrieves auth token
func (c *Client) Login() error {
	loginReq := loginRequest{
		Email:    c.username,
		Password: c.password,
	}

	reqBody, err := json.Marshal(loginReq)
	if err != nil {
		return fmt.Errorf("failed to marshal login request: %w", err)
	}

	req, err := http.NewRequest("POST", c.baseURL+"/llu/auth/login", bytes.NewBuffer(reqBody))
	if err != nil {
		return fmt.Errorf("failed to create login request: %w", err)
	}

	c.setHeaders(req)

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("login request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("login failed with status %d: %s", resp.StatusCode, string(body))
	}

	var loginResp loginResponse
	if err := json.NewDecoder(resp.Body).Decode(&loginResp); err != nil {
		return fmt.Errorf("failed to decode login response: %w", err)
	}

	if loginResp.Status != 0 {
		return fmt.Errorf("login failed with API status: %d", loginResp.Status)
	}

	c.authToken = loginResp.Data.AuthTicket.Token
	return nil
}

// GetConnections retrieves all LibreLink connections (sensors)
func (c *Client) GetConnections() ([]Connection, error) {
	if c.authToken == "" {
		return nil, fmt.Errorf("not authenticated, call Login() first")
	}

	req, err := http.NewRequest("GET", c.baseURL+"/llu/connections", nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create connections request: %w", err)
	}

	c.setHeaders(req)
	req.Header.Set("Authorization", "Bearer "+c.authToken)

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("connections request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("connections request failed with status %d: %s", resp.StatusCode, string(body))
	}

	var connResp connectionsResponse
	if err := json.NewDecoder(resp.Body).Decode(&connResp); err != nil {
		return nil, fmt.Errorf("failed to decode connections response: %w", err)
	}

	connections := make([]Connection, len(connResp.Data))
	for i, conn := range connResp.Data {
		connections[i] = Connection{
			PatientID: conn.PatientID,
			FirstName: conn.FirstName,
			LastName:  conn.LastName,
		}
	}

	return connections, nil
}

// GetLatestReading retrieves the latest glucose reading for a patient
func (c *Client) GetLatestReading(patientID string) (*GlucoseReading, error) {
	if c.authToken == "" {
		return nil, fmt.Errorf("not authenticated, call Login() first")
	}

	url := fmt.Sprintf("%s/llu/connections/%s/graph", c.baseURL, patientID)
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create glucose request: %w", err)
	}

	c.setHeaders(req)
	req.Header.Set("Authorization", "Bearer "+c.authToken)

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("glucose request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("glucose request failed with status %d: %s", resp.StatusCode, string(body))
	}

	var glucoseResp glucoseResponse
	if err := json.NewDecoder(resp.Body).Decode(&glucoseResp); err != nil {
		return nil, fmt.Errorf("failed to decode glucose response: %w", err)
	}

	measurement := glucoseResp.Data.Connection.GlucoseMeasurement

	// Parse timestamp (format: "11/19/2024 3:14:29 PM")
	timestamp, err := parseLibreLinkTimestamp(measurement.Timestamp)
	if err != nil {
		return nil, fmt.Errorf("failed to parse timestamp: %w", err)
	}

	return &GlucoseReading{
		Value:      measurement.ValueInMgPerDl,
		Unit:       "mg/dL",
		Timestamp:  timestamp,
		TrendArrow: trendArrowToString(measurement.TrendArrow),
	}, nil
}

func (c *Client) setHeaders(req *http.Request) {
	req.Header.Set("Content-Type", contentType)
	req.Header.Set("Accept", contentType)
	req.Header.Set("Product", appProduct)
	req.Header.Set("Version", appVersion)
	req.Header.Set("User-Agent", "FreeStyle LibreLink Up/"+appVersion)
}

func parseLibreLinkTimestamp(timestamp string) (time.Time, error) {
	// Try parsing with common formats
	formats := []string{
		"1/2/2006 3:04:05 PM",
		"01/02/2006 15:04:05",
		time.RFC3339,
	}

	for _, format := range formats {
		if t, err := time.Parse(format, timestamp); err == nil {
			return t, nil
		}
	}

	return time.Time{}, fmt.Errorf("unable to parse timestamp: %s", timestamp)
}

func trendArrowToString(arrow int) string {
	switch arrow {
	case 1:
		return "DoubleUp"
	case 2:
		return "SingleUp"
	case 3:
		return "FortyFiveUp"
	case 4:
		return "Flat"
	case 5:
		return "FortyFiveDown"
	case 6:
		return "SingleDown"
	case 7:
		return "DoubleDown"
	default:
		return "Unknown"
	}
}
