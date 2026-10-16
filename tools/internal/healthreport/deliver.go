// Delivery: ntfy headline plus the full report by email. Both are
// best-effort and independent: a broken SMTP config must not suppress the
// push notification, and vice versa. Failures are returned, not raised, so
// the caller can report what actually went out.
package healthreport

import (
	"bytes"
	"compress/gzip"
	"crypto/tls"
	"encoding/base64"
	"fmt"
	"mime"
	"mime/multipart"
	"mime/quotedprintable"
	"net"
	"net/http"
	"net/smtp"
	"net/textproto"
	"strings"
	"time"
)

// ntfy priorities: 5 urgent, 4 high, 3 default.
var ntfyPriority = map[string]string{"crit": "5", "warn": "4", "info": "3"}
var ntfyTags = map[string]string{"crit": "rotating_light", "warn": "warning", "info": "white_check_mark"}

func WorstSeverity(facts *Facts) string {
	if facts.Summary.Crit > 0 {
		return "crit"
	}
	if facts.Summary.Warn > 0 {
		return "warn"
	}
	return "info"
}

func SendNtfy(cfg Config, facts *Facts, title, body string) string {
	if cfg.NtfyURL == "" || cfg.NtfyTopic == "" {
		return "skipped: no ntfy configuration"
	}

	level := WorstSeverity(facts)
	marker := ""
	if facts.LLMStatus != "ok" && facts.LLMStatus != "disabled" {
		marker = " [no-LLM]"
	}
	titleHeader := title + marker
	if len(titleHeader) > 200 {
		titleHeader = titleHeader[:200]
	}

	req, err := http.NewRequest(http.MethodPost, strings.TrimRight(cfg.NtfyURL, "/")+"/"+cfg.NtfyTopic, bytes.NewReader([]byte(body)))
	if err != nil {
		return "ntfy: " + err.Error()
	}
	req.Header.Set("Title", titleHeader)
	req.Header.Set("Priority", ntfyPriority[level])
	req.Header.Set("Tags", ntfyTags[level]+",homelab")
	req.Header.Set("Click", cfg.GrafanaURL)
	if cfg.NtfyToken != "" {
		req.Header.Set("Authorization", "Bearer "+cfg.NtfyToken)
	}

	client := &http.Client{Timeout: 20 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return "ntfy: " + err.Error()
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Sprintf("ntfy: HTTP %d", resp.StatusCode)
	}
	return ""
}

func SendEmail(cfg Config, facts *Facts, subject, bodyMarkdown, bodyHTML string) string {
	if cfg.EmailTo == "" || (cfg.SMTPHost == "" && cfg.SMTP2Host == "") {
		return "skipped: no SMTP configuration"
	}

	subjectTrim := subject
	if len(subjectTrim) > 250 {
		subjectTrim = subjectTrim[:250]
	}

	var buf bytes.Buffer
	writer := multipart.NewWriter(&buf)

	// From is set per relay (see sendVia), so the message is built without
	// it and the header is prepended once the relay is known.
	buf.WriteString("Subject: " + mime.QEncoding.Encode("utf-8", subjectTrim) + "\r\n")
	buf.WriteString("To: " + cfg.EmailTo + "\r\n")
	buf.WriteString("MIME-Version: 1.0\r\n")
	buf.WriteString("Content-Type: multipart/mixed; boundary=" + writer.Boundary() + "\r\n\r\n")

	// multipart/alternative: the Markdown stays as the text/plain part so
	// the report is still readable in a plain-text client, or if the HTML
	// fails to render. The HTML part is additive, never the only copy.
	altBuf := &bytes.Buffer{}
	altWriter := multipart.NewWriter(altBuf)
	writePart(altWriter, map[string]string{"Content-Type": "text/plain; charset=utf-8"}, []byte(bodyMarkdown))
	if bodyHTML != "" {
		writePart(altWriter, map[string]string{"Content-Type": "text/html; charset=utf-8"}, []byte(bodyHTML))
	}
	altWriter.Close()

	altPart, _ := writer.CreatePart(textproto.MIMEHeader{
		"Content-Type": {"multipart/alternative; boundary=" + altWriter.Boundary()},
	})
	altPart.Write(altBuf.Bytes())

	// Attach the raw facts so the full data is retained even after the
	// state directory rotates.
	payload, err := sortedJSON(facts)
	if err != nil {
		return "email: " + err.Error()
	}
	stamp := facts.Run.ID
	if len(stamp) > 10 {
		stamp = stamp[:10]
	}
	if len(payload) > 200*1024 {
		var gz bytes.Buffer
		gw := gzip.NewWriter(&gz)
		gw.Write(payload)
		gw.Close()
		writePart(writer, map[string]string{
			"Content-Type":              "application/gzip",
			"Content-Disposition":       fmt.Sprintf(`attachment; filename="facts-%s.json.gz"`, stamp),
			"Content-Transfer-Encoding": "base64",
		}, gz.Bytes())
	} else {
		writePart(writer, map[string]string{
			"Content-Type":              "application/json",
			"Content-Disposition":       fmt.Sprintf(`attachment; filename="facts-%s.json"`, stamp),
			"Content-Transfer-Encoding": "base64",
		}, payload)
	}
	writer.Close()

	// The primary relay is mail.mljr.eu, which runs on the same fleet this
	// report describes - when it is down the report must still arrive via
	// an independent relay.
	relays := []smtpRelay{
		{cfg.SMTPHost, cfg.SMTPPort, cfg.SMTPUser, cfg.SMTPPassword, cfg.SMTPFrom},
		{cfg.SMTP2Host, cfg.SMTP2Port, cfg.SMTP2User, cfg.SMTP2Password, cfg.SMTP2From},
	}
	var errs []string
	for i, r := range relays {
		if r.host == "" {
			continue
		}
		if err := r.send(cfg.EmailTo, buf.Bytes()); err != nil {
			errs = append(errs, fmt.Sprintf("relay %d (%s): %v", i+1, r.host, err))
			continue
		}
		if len(errs) > 0 {
			// Delivered, but only via the backup: still worth surfacing.
			return "email: delivered via backup relay after: " + strings.Join(errs, "; ")
		}
		return ""
	}
	return "email: " + strings.Join(errs, "; ")
}

type smtpRelay struct {
	host     string
	port     int
	user     string
	password string
	from     string
}

func (r smtpRelay) send(to string, msg []byte) error {
	addr := net.JoinHostPort(r.host, fmt.Sprint(r.port))
	conn, err := net.DialTimeout("tcp", addr, 30*time.Second)
	if err != nil {
		return err
	}
	conn.SetDeadline(time.Now().Add(2 * time.Minute))
	client, err := smtp.NewClient(conn, r.host)
	if err != nil {
		conn.Close()
		return err
	}
	defer client.Close()

	if err := client.StartTLS(&tls.Config{ServerName: r.host}); err != nil {
		return err
	}
	if r.user != "" {
		if err := client.Auth(smtp.PlainAuth("", r.user, r.password, r.host)); err != nil {
			return err
		}
	}
	if err := client.Mail(r.from); err != nil {
		return err
	}
	for _, rcpt := range strings.Split(to, ",") {
		rcpt = strings.TrimSpace(rcpt)
		if rcpt == "" {
			continue
		}
		if err := client.Rcpt(rcpt); err != nil {
			return err
		}
	}
	wc, err := client.Data()
	if err != nil {
		return err
	}
	if _, err := wc.Write([]byte("From: " + r.from + "\r\n")); err != nil {
		return err
	}
	if _, err := wc.Write(msg); err != nil {
		return err
	}
	if err := wc.Close(); err != nil {
		return err
	}
	return client.Quit()
}

// SendNtfyEmailFailure is the fallback for a failed email: a high-priority
// push carrying the failure reason and as much of the report as ntfy takes,
// so a dead mail path never means a silent day.
func SendNtfyEmailFailure(cfg Config, facts *Facts, emailErr, body string) string {
	if cfg.NtfyURL == "" || cfg.NtfyTopic == "" {
		return "skipped: no ntfy configuration"
	}
	msg := "Email delivery failed: " + emailErr + "\n\n" + body
	if len(msg) > 3800 {
		msg = msg[:3800]
	}
	req, err := http.NewRequest(http.MethodPost, strings.TrimRight(cfg.NtfyURL, "/")+"/"+cfg.NtfyTopic, strings.NewReader(msg))
	if err != nil {
		return "ntfy fallback: " + err.Error()
	}
	req.Header.Set("Title", "[homelab] health report email FAILED")
	req.Header.Set("Priority", "4")
	req.Header.Set("Tags", "warning,e-mail,homelab")
	req.Header.Set("Click", cfg.GrafanaURL)
	if cfg.NtfyToken != "" {
		req.Header.Set("Authorization", "Bearer "+cfg.NtfyToken)
	}
	resp, err := (&http.Client{Timeout: 20 * time.Second}).Do(req)
	if err != nil {
		return "ntfy fallback: " + err.Error()
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Sprintf("ntfy fallback: HTTP %d", resp.StatusCode)
	}
	return ""
}

func writePart(writer *multipart.Writer, headers map[string]string, body []byte) {
	header := textproto.MIMEHeader{}
	for k, v := range headers {
		header.Set(k, v)
	}
	if _, ok := header["Content-Transfer-Encoding"]; !ok {
		header.Set("Content-Transfer-Encoding", "quoted-printable")
	}
	part, _ := writer.CreatePart(header)
	if header.Get("Content-Transfer-Encoding") == "base64" {
		encoded := base64.StdEncoding.EncodeToString(body)
		for i := 0; i < len(encoded); i += 76 {
			end := i + 76
			if end > len(encoded) {
				end = len(encoded)
			}
			part.Write([]byte(encoded[i:end]))
			part.Write([]byte("\r\n"))
		}
		return
	}
	qp := quotedprintable.NewWriter(part)
	qp.Write(body)
	qp.Close()
}

func SubjectLine(facts *Facts) string {
	var state string
	if facts.Summary.Crit > 0 || facts.Summary.Warn > 0 {
		var parts []string
		if facts.Summary.Crit > 0 {
			parts = append(parts, fmt.Sprintf("%d crit", facts.Summary.Crit))
		}
		if facts.Summary.Warn > 0 {
			parts = append(parts, fmt.Sprintf("%d warn", facts.Summary.Warn))
		}
		state = strings.Join(parts, ", ")
	} else {
		state = "all clear"
	}
	stamp := facts.Run.ID
	if len(stamp) > 10 {
		stamp = stamp[:10]
	}
	return fmt.Sprintf("[homelab] daily health — %s — %s", state, stamp)
}
