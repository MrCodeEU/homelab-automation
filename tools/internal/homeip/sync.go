package homeip

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Allowlist is what Sync needs from CrowdSec.
type Allowlist interface {
	// Values returns the entries; ok false when the allowlist does not exist.
	Values(ctx context.Context) (values []string, ok bool, err error)
	Create(ctx context.Context) error
	Add(ctx context.Context, values []string, comment string) error
	Remove(ctx context.Context, values []string) error
}

// Change is what one sync did to the allowlist.
type Change struct {
	Added, Removed []string
}

func (c Change) Empty() bool { return len(c.Added) == 0 && len(c.Removed) == 0 }

func (c Change) String() string {
	var parts []string
	for _, v := range c.Added {
		parts = append(parts, "+ "+v)
	}
	for _, v := range c.Removed {
		parts = append(parts, "- "+v)
	}
	return strings.Join(parts, "\n")
}

// Sync makes the allowlist contain exactly h's values. New values are added
// before old ones are removed, so the owner is never unlisted in between.
func Sync(ctx context.Context, al Allowlist, h Home, now time.Time) (Change, error) {
	if err := h.Validate(); err != nil {
		return Change{}, err
	}
	have, ok, err := al.Values(ctx)
	if err != nil {
		return Change{}, err
	}
	if !ok {
		if err := al.Create(ctx); err != nil {
			return Change{}, err
		}
	}
	want := h.Values()
	var ch Change
	for _, v := range want {
		if !contains(have, v) {
			ch.Added = append(ch.Added, v)
		}
	}
	for _, v := range have {
		if !contains(want, v) {
			ch.Removed = append(ch.Removed, v)
		}
	}
	sort.Strings(ch.Removed)
	if len(ch.Added) > 0 {
		if err := al.Add(ctx, ch.Added, "home-ip sync "+now.UTC().Format(time.RFC3339)); err != nil {
			return Change{}, err
		}
	}
	if len(ch.Removed) > 0 {
		if err := al.Remove(ctx, ch.Removed); err != nil {
			return ch, err
		}
	}
	return ch, nil
}

func contains(list []string, v string) bool {
	for _, x := range list {
		if x == v {
			return true
		}
	}
	return false
}

// Fetch reads a Home from url (Serve's answer).
func Fetch(ctx context.Context, c *http.Client, url string) (Home, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return Home{}, err
	}
	resp, err := c.Do(req)
	if err != nil {
		return Home{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return Home{}, fmt.Errorf("%s: HTTP %d: %s", url, resp.StatusCode, strings.TrimSpace(string(msg)))
	}
	var h Home
	if err := json.NewDecoder(io.LimitReader(resp.Body, 4096)).Decode(&h); err != nil {
		return Home{}, fmt.Errorf("%s: %w", url, err)
	}
	return h, nil
}

// Cscli is an Allowlist through cscli, e.g. Command
// ["docker", "exec", "crowdsec", "cscli"].
type Cscli struct {
	Command []string
	Name    string
}

func (c Cscli) run(ctx context.Context, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, c.Command[0], append(append([]string{}, c.Command[1:]...), args...)...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return out, fmt.Errorf("cscli %s: %w: %s", strings.Join(args[:min(len(args), 3)], " "), err, strings.TrimSpace(string(out)))
	}
	return out, nil
}

func (c Cscli) Values(ctx context.Context) ([]string, bool, error) {
	out, err := c.run(ctx, "allowlists", "inspect", c.Name, "-o", "json")
	if err != nil {
		if strings.Contains(string(out), "not found") {
			return nil, false, nil
		}
		return nil, false, err
	}
	var al struct {
		Items []struct {
			Value string `json:"value"`
		} `json:"items"`
	}
	if err := json.Unmarshal(out, &al); err != nil {
		return nil, false, fmt.Errorf("cscli allowlists inspect: %w", err)
	}
	var vs []string
	for _, it := range al.Items {
		vs = append(vs, it.Value)
	}
	return vs, true, nil
}

func (c Cscli) Create(ctx context.Context) error {
	_, err := c.run(ctx, "allowlists", "create", c.Name, "-d", "Home connection, kept current by home-ip sync (roles::home_ip)")
	return err
}

func (c Cscli) Add(ctx context.Context, values []string, comment string) error {
	_, err := c.run(ctx, append(append([]string{"allowlists", "add", c.Name}, values...), "-d", comment)...)
	return err
}

func (c Cscli) Remove(ctx context.Context, values []string) error {
	_, err := c.run(ctx, append([]string{"allowlists", "remove", c.Name}, values...)...)
	return err
}

// WriteMetrics writes the textfile for Alloy: whether the last sync worked,
// when one last did, and what the allowlist holds after it.
func WriteMetrics(path string, ok bool, lastSuccess time.Time, h Home) error {
	var b strings.Builder
	success := 0
	if ok {
		success = 1
	}
	fmt.Fprintf(&b, "homelab_home_ip_sync_success %d\n", success)
	if !lastSuccess.IsZero() {
		fmt.Fprintf(&b, "homelab_home_ip_last_sync_timestamp_seconds %d\n", lastSuccess.Unix())
	}
	if h.IPv4 != "" {
		fmt.Fprintf(&b, "homelab_home_ip_allowlisted_info{family=\"ipv4\",value=%q} 1\n", h.IPv4)
	}
	if h.IPv6Prefix != "" {
		fmt.Fprintf(&b, "homelab_home_ip_allowlisted_info{family=\"ipv6\",value=%q} 1\n", h.IPv6Prefix)
	}
	tmp := filepath.Join(filepath.Dir(path), "."+filepath.Base(path)+".tmp")
	if err := os.WriteFile(tmp, []byte(b.String()), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
