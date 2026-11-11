package deployagent

import (
	"context"
	"crypto/tls"
	"fmt"
	"net"
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
	if r.Mode == "noop" {
		title = fmt.Sprintf("Deploy noop %s on %s: %s", short, r.Host, r.Outcome)
	}
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

// Mail sends through one SMTP submission relay, STARTTLS required, as
// healthreport does (mail.mljr.eu first, an independent relay second:
// one Mail notifier per relay, in that order).
type Mail struct {
	Host     string
	Port     int
	User     string
	Password string
	From, To string
}

func (m Mail) Name() string { return "mail " + m.Host }

func (m Mail) Notify(ctx context.Context, r Result) error {
	title, body := summary(r)
	d := net.Dialer{Timeout: 30 * time.Second}
	conn, err := d.DialContext(ctx, "tcp", net.JoinHostPort(m.Host, fmt.Sprint(m.Port)))
	if err != nil {
		return err
	}
	conn.SetDeadline(time.Now().Add(2 * time.Minute))
	c, err := smtp.NewClient(conn, m.Host)
	if err != nil {
		conn.Close()
		return err
	}
	defer c.Close()
	if err := c.StartTLS(&tls.Config{ServerName: m.Host}); err != nil {
		return err
	}
	if m.User != "" {
		if err := c.Auth(smtp.PlainAuth("", m.User, m.Password, m.Host)); err != nil {
			return err
		}
	}
	if err := c.Mail(m.From); err != nil {
		return err
	}
	if err := c.Rcpt(m.To); err != nil {
		return err
	}
	w, err := c.Data()
	if err != nil {
		return err
	}
	fmt.Fprintf(w, "From: %s\r\nTo: %s\r\nSubject: %s\r\nDate: %s\r\n\r\n%s\r\n",
		m.From, m.To, title, time.Now().Format(time.RFC1123Z), strings.ReplaceAll(body, "\n", "\r\n"))
	if err := w.Close(); err != nil {
		return err
	}
	return c.Quit()
}
