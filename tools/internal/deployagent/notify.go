package deployagent

import (
	"context"
	"fmt"
	"net/http"
	"net/smtp"
	"strings"
	"time"
)

// Notifier delivers one result. The outbox tries notifiers in order and
// keeps the result until one returns nil.
type Notifier interface {
	Name() string
	Notify(ctx context.Context, r Result) error
}

func summary(r Result) (title, body string) {
	short := r.Commit
	if len(short) > 9 {
		short = short[:9]
	}
	title = fmt.Sprintf("Deploy %s on %s: %s", short, r.Host, r.Outcome)
	body = fmt.Sprintf("request %s\n%s", r.RequestID, tail(r.Detail, 15))
	return title, body
}

// Ntfy posts to an ntfy topic URL (https://ntfy.mljr.eu/deployment).
type Ntfy struct {
	URL    string
	Client *http.Client
}

func (n Ntfy) Name() string { return "ntfy" }

func (n Ntfy) Notify(ctx context.Context, r Result) error {
	title, body := summary(r)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, n.URL, strings.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Title", title)
	req.Header.Set("Tags", "openvox,homelab")
	if r.Outcome != "success" {
		req.Header.Set("Priority", "high")
	}
	c := n.Client
	if c == nil {
		c = &http.Client{Timeout: 10 * time.Second}
	}
	resp, err := c.Do(req)
	if err != nil {
		return err
	}
	resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("ntfy: %s", resp.Status)
	}
	return nil
}

// Mail sends through an SMTP submission server (mailcow) with STARTTLS
// and PLAIN auth. Used when ntfy fails, so results only go here then.
type Mail struct {
	Addr     string // host:587
	User     string
	Password string
	From, To string
}

func (m Mail) Name() string { return "mail" }

func (m Mail) Notify(_ context.Context, r Result) error {
	title, body := summary(r)
	host, _, _ := strings.Cut(m.Addr, ":")
	msg := fmt.Sprintf("From: %s\r\nTo: %s\r\nSubject: %s\r\nDate: %s\r\n\r\n%s\r\n",
		m.From, m.To, title, time.Now().Format(time.RFC1123Z), strings.ReplaceAll(body, "\n", "\r\n"))
	return smtp.SendMail(m.Addr, smtp.PlainAuth("", m.User, m.Password, host), m.From, []string{m.To}, []byte(msg))
}
