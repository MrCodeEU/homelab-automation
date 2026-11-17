package zitinotify

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"net/url"
	"sync"
	"time"
)

// Directory resolves ids through the controller's management API, as the
// default admin. It refreshes every RefreshEvery and, at most once a
// minute, when an id is unknown (a service or identity created since).
// Unknown ids stay ids: a message with an id beats no message.
type Directory struct {
	BaseURL      string // https://127.0.0.1:8440/edge/management/v1
	Username     string
	Password     string
	Client       *http.Client
	RefreshEvery time.Duration

	mu        sync.Mutex
	names     map[string]map[string]string // kind -> id -> name
	loaded    time.Time
	triedMiss time.Time
}

// NewDirectory trusts only the controller's own root CA.
func NewDirectory(baseURL, user, password string, rootPEM []byte) (*Directory, error) {
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(rootPEM) {
		return nil, fmt.Errorf("no certificate in the controller root CA file")
	}
	return &Directory{
		BaseURL: baseURL, Username: user, Password: password,
		Client: &http.Client{
			Timeout:   20 * time.Second,
			Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}},
		},
		RefreshEvery: 10 * time.Minute,
		names:        map[string]map[string]string{},
	}, nil
}

var listPaths = map[string]string{
	"identity": "/identities",
	"service":  "/services",
	"router":   "/edge-routers",
}

// Refresh reloads every name.
func (d *Directory) Refresh(ctx context.Context) error {
	token, err := d.login(ctx)
	if err != nil {
		return err
	}
	fresh := map[string]map[string]string{}
	for kind, path := range listPaths {
		m, err := d.list(ctx, token, path)
		if err != nil {
			return fmt.Errorf("%s: %w", path, err)
		}
		fresh[kind] = m
	}
	d.mu.Lock()
	d.names, d.loaded = fresh, time.Now()
	d.mu.Unlock()
	return nil
}

func (d *Directory) login(ctx context.Context) (string, error) {
	body, _ := json.Marshal(map[string]string{"username": d.Username, "password": d.Password})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, d.BaseURL+"/authenticate?method=password", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := d.Client.Do(req)
	if err != nil {
		return "", fmt.Errorf("login: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("login: HTTP %d", resp.StatusCode)
	}
	var out struct {
		Data struct {
			Token string `json:"token"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil || out.Data.Token == "" {
		return "", fmt.Errorf("login: no session token")
	}
	return out.Data.Token, nil
}

func (d *Directory) list(ctx context.Context, token, path string) (map[string]string, error) {
	m := map[string]string{}
	for offset := 0; ; {
		q := url.Values{"limit": {"500"}, "offset": {fmt.Sprint(offset)}}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, d.BaseURL+path+"?"+q.Encode(), nil)
		if err != nil {
			return nil, err
		}
		req.Header.Set("zt-session", token)
		resp, err := d.Client.Do(req)
		if err != nil {
			return nil, err
		}
		var out struct {
			Data []struct {
				ID   string `json:"id"`
				Name string `json:"name"`
			} `json:"data"`
			Meta struct {
				Pagination struct {
					TotalCount int `json:"totalCount"`
				} `json:"pagination"`
			} `json:"meta"`
		}
		err = json.NewDecoder(resp.Body).Decode(&out)
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
		}
		if err != nil {
			return nil, err
		}
		for _, e := range out.Data {
			m[e.ID] = e.Name
		}
		offset += len(out.Data)
		if len(out.Data) == 0 || offset >= out.Meta.Pagination.TotalCount {
			return m, nil
		}
	}
}

func (d *Directory) lookup(kind, id string) string {
	if id == "" {
		return ""
	}
	d.mu.Lock()
	name, ok := d.names[kind][id]
	stale := time.Since(d.loaded) > d.RefreshEvery
	retry := !ok && time.Since(d.triedMiss) > time.Minute
	if retry {
		d.triedMiss = time.Now()
	}
	d.mu.Unlock()
	if ok && !stale {
		return name
	}
	if stale || retry {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		if err := d.Refresh(ctx); err != nil {
			slog.Warn("refresh names", "err", err)
		}
		d.mu.Lock()
		name, ok = d.names[kind][id]
		d.mu.Unlock()
	}
	if ok {
		return name
	}
	return id
}

func (d *Directory) Identity(id string) string { return d.lookup("identity", id) }
func (d *Directory) Service(id string) string  { return d.lookup("service", id) }
func (d *Directory) Router(id string) string   { return d.lookup("router", id) }

func (d *Directory) Learn(kind, id, name string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.names[kind] == nil {
		d.names[kind] = map[string]string{}
	}
	d.names[kind][id] = name
}
