// Package zitimesh reads the state of the Ziti overlay from the controller's
// management and fabric APIs (routers, links, identities, terminators,
// circuits) and renders it as Prometheus metrics: plain gauges for alerts
// and tables, plus ziti_mesh_node / ziti_mesh_edge series shaped for
// Grafana's Node Graph panel (one series per node or edge, the labels are
// the panel's fields).
//
// It only reads. The identity it logs in with has the admin_readonly
// permission (ziti/tofu/mesh-exporter.tf).
package zitimesh

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
)

// pageSize is the controller's maximum page size.
const pageSize = 500

// Client talks to the controller's admin listener (edge management and
// fabric APIs) with a certificate login.
type Client struct {
	HTTP *http.Client
	// Base is the listener's base URL, e.g. https://127.0.0.1:8440.
	Base string

	mu    sync.Mutex
	token string
}

func (c *Client) login(ctx context.Context) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		c.Base+"/edge/management/v1/authenticate?method=cert", strings.NewReader("{}"))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode/100 != 2 {
		return "", fmt.Errorf("authenticate: %s: %s", resp.Status, strings.TrimSpace(string(data)))
	}
	var r struct {
		Data struct {
			Token string `json:"token"`
		} `json:"data"`
	}
	if err := json.Unmarshal(data, &r); err != nil || r.Data.Token == "" {
		return "", errors.New("authenticate: no token")
	}
	return r.Data.Token, nil
}

// errUnauthorized marks a 401: the session expired, log in again.
var errUnauthorized = errors.New("unauthorized")

func (c *Client) get(ctx context.Context, token, path string, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.Base+path, nil)
	if err != nil {
		return err
	}
	req.Header.Set("zt-session", token)
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 32<<20))
	if resp.StatusCode == http.StatusUnauthorized {
		return errUnauthorized
	}
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("GET %s: %s: %s", path, resp.Status, strings.TrimSpace(string(data)))
	}
	return json.Unmarshal(data, out)
}

// list reads every page of a list endpoint (e.g. "/edge/management/v1/identities").
func list[T any](ctx context.Context, c *Client, path string) ([]T, error) {
	var all []T
	for offset := 0; ; {
		var page struct {
			Data []T `json:"data"`
			Meta struct {
				Pagination struct {
					TotalCount int `json:"totalCount"`
				} `json:"pagination"`
			} `json:"meta"`
		}
		q := url.Values{"limit": {fmt.Sprint(pageSize)}, "offset": {fmt.Sprint(offset)}}
		if err := c.do(ctx, path+"?"+q.Encode(), &page); err != nil {
			return nil, err
		}
		all = append(all, page.Data...)
		offset += len(page.Data)
		if len(page.Data) == 0 || offset >= page.Meta.Pagination.TotalCount {
			return all, nil
		}
	}
}

// do is get with the cached session, logging in first or again after a 401.
func (c *Client) do(ctx context.Context, path string, out any) error {
	c.mu.Lock()
	token := c.token
	c.mu.Unlock()
	for attempt := 0; attempt < 2; attempt++ {
		if token == "" {
			t, err := c.login(ctx)
			if err != nil {
				return err
			}
			token = t
			c.mu.Lock()
			c.token = t
			c.mu.Unlock()
		}
		err := c.get(ctx, token, path, out)
		if !errors.Is(err, errUnauthorized) {
			return err
		}
		token = ""
	}
	return fmt.Errorf("GET %s: still unauthorized after a new login", path)
}

type ref struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

type router struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	IsOnline bool   `json:"isOnline"`
}

type link struct {
	ID            string `json:"id"`
	SourceRouter  ref    `json:"sourceRouter"`
	DestRouter    ref    `json:"destRouter"`
	State         string `json:"state"`
	Down          bool   `json:"down"`
	Cost          int64  `json:"cost"`
	SourceLatency int64  `json:"sourceLatency"` // ns
	DestLatency   int64  `json:"destLatency"`   // ns
}

type identity struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Type     ref    `json:"type"`
	Online   bool   `json:"hasEdgeRouterConnection"`
	Disabled bool   `json:"disabled"`
}

type terminator struct {
	ID       string `json:"id"`
	Service  ref    `json:"service"`
	Router   ref    `json:"router"`
	Binding  string `json:"binding"`
	Identity string `json:"identity"`
}

type circuit struct {
	ID      string            `json:"id"`
	Service ref               `json:"service"`
	Tags    map[string]string `json:"tags"`
	Path    struct {
		Nodes []ref `json:"nodes"`
	} `json:"path"`
}

// State is one read of the overlay.
type State struct {
	Routers     []router
	Links       []link
	Identities  []identity
	Terminators []terminator
	Circuits    []circuit
}

// Read fetches the whole state. Any failed call fails the read: a partial
// map would show missing routers or services as gone.
func (c *Client) Read(ctx context.Context) (*State, error) {
	s := &State{}
	var err error
	if s.Routers, err = list[router](ctx, c, "/edge/management/v1/edge-routers"); err != nil {
		return nil, err
	}
	if s.Links, err = list[link](ctx, c, "/fabric/v1/links"); err != nil {
		return nil, err
	}
	if s.Identities, err = list[identity](ctx, c, "/edge/management/v1/identities"); err != nil {
		return nil, err
	}
	if s.Terminators, err = list[terminator](ctx, c, "/edge/management/v1/terminators"); err != nil {
		return nil, err
	}
	if s.Circuits, err = list[circuit](ctx, c, "/fabric/v1/circuits"); err != nil {
		return nil, err
	}
	return s, nil
}
