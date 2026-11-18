package zitinotify

import (
	"context"
	"fmt"
	"mime"
	"net/http"
	"strings"
	"time"
)

// Ntfy posts messages to one topic URL.
type Ntfy struct {
	URL    string
	Client *http.Client
}

func (n Ntfy) Send(ctx context.Context, m Message) error {
	c := n.Client
	if c == nil {
		c = &http.Client{Timeout: 20 * time.Second}
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, n.URL, strings.NewReader(m.Body))
	if err != nil {
		return err
	}
	// ntfy decodes RFC 2047 headers; ASCII titles pass unchanged.
	req.Header.Set("Title", mime.BEncoding.Encode("UTF-8", m.Title))
	if m.Priority > 0 {
		req.Header.Set("Priority", fmt.Sprint(m.Priority))
	}
	if len(m.Tags) > 0 {
		req.Header.Set("Tags", strings.Join(m.Tags, ","))
	}
	resp, err := c.Do(req)
	if err != nil {
		return fmt.Errorf("ntfy: %w", err)
	}
	resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("ntfy: HTTP %d", resp.StatusCode)
	}
	return nil
}
