// deploy-agent applies deploy requests from the branch deploy/<host>
// (docs/DEPLOY_AGENT.md): it polls the branch, checks the request and
// its target commit, runs the host-side apply script from that commit's
// tree and reports the result through an outbox (ntfy, mail as fallback)
// and a metrics textfile.
//
// Environment:
//
//	DEPLOY_HOST          this host's name (required)
//	DEPLOY_REPO_URL      default https://github.com/MrCodeEU/homelab-automation.git
//	DEPLOY_MAIN_BRANCH   protected branch target commits must be on (default main)
//	DEPLOY_STATE_DIR     default /var/lib/homelab-deploy
//	DEPLOY_KEYRING       armored public keys trusted to sign (default /etc/homelab-deploy/keyring.asc)
//	DEPLOY_APPLY         apply script inside the tree (default scripts/openvox-apply.sh)
//	DEPLOY_APPLY_TIMEOUT default 30m
//	DEPLOY_INTERVAL      poll interval (default 60s)
//	DEPLOY_SUSPEND_FILE  default /etc/homelab-deploy/suspend
//	DEPLOY_LOCK_FILE     default /run/homelab-deploy.lock
//	DEPLOY_NTFY_URL      default https://ntfy.mljr.eu/deployment; empty: none
//	DEPLOY_SMTP_ADDR, DEPLOY_SMTP_USER, DEPLOY_SMTP_PASSWORD_FILE,
//	DEPLOY_MAIL_FROM, DEPLOY_MAIL_TO   mail fallback; empty addr: none
//
// --once polls once and exits.
package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/MrCodeEU/homelab-automation/tools/internal/deployagent"
)

func main() {
	once := len(os.Args) > 1 && os.Args[1] == "--once"
	log := slog.New(slog.NewTextHandler(os.Stderr, nil))

	host := os.Getenv("DEPLOY_HOST")
	if host == "" {
		fatal(fmt.Errorf("DEPLOY_HOST is required"))
	}
	interval, err := time.ParseDuration(envOr("DEPLOY_INTERVAL", "60s"))
	if err != nil || interval < 10*time.Second {
		fatal(fmt.Errorf("DEPLOY_INTERVAL must be a duration of at least 10s: %q", os.Getenv("DEPLOY_INTERVAL")))
	}
	timeout, err := time.ParseDuration(envOr("DEPLOY_APPLY_TIMEOUT", "30m"))
	if err != nil {
		fatal(fmt.Errorf("DEPLOY_APPLY_TIMEOUT: %w", err))
	}
	keyring, err := os.ReadFile(envOr("DEPLOY_KEYRING", "/etc/homelab-deploy/keyring.asc"))
	if err != nil {
		fatal(err)
	}
	notifiers, err := notifiersFromEnv()
	if err != nil {
		fatal(err)
	}

	agent, err := deployagent.New(deployagent.Config{
		Host:         host,
		RepoURL:      envOr("DEPLOY_REPO_URL", "https://github.com/MrCodeEU/homelab-automation.git"),
		MainBranch:   envOr("DEPLOY_MAIN_BRANCH", "main"),
		StateDir:     envOr("DEPLOY_STATE_DIR", "/var/lib/homelab-deploy"),
		Keyring:      string(keyring),
		Apply:        envOr("DEPLOY_APPLY", "scripts/openvox-apply.sh"),
		ApplyTimeout: timeout,
		SuspendFile:  envOr("DEPLOY_SUSPEND_FILE", "/etc/homelab-deploy/suspend"),
		LockFile:     envOr("DEPLOY_LOCK_FILE", "/run/homelab-deploy.lock"),
		Notifiers:    notifiers,
		Log:          log,
	})
	if err != nil {
		fatal(err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	for {
		pollCtx, cancel := context.WithTimeout(ctx, timeout+5*time.Minute)
		if err := agent.Poll(pollCtx); err != nil {
			log.Error("poll", "err", err)
			if once {
				cancel()
				os.Exit(1)
			}
		}
		cancel()
		if once {
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(interval):
		}
	}
}

func notifiersFromEnv() ([]deployagent.Notifier, error) {
	var ns []deployagent.Notifier
	if u := envOr("DEPLOY_NTFY_URL", "https://ntfy.mljr.eu/deployment"); u != "" {
		ns = append(ns, deployagent.Ntfy{URL: u})
	}
	if addr := os.Getenv("DEPLOY_SMTP_ADDR"); addr != "" {
		pw, err := os.ReadFile(os.Getenv("DEPLOY_SMTP_PASSWORD_FILE"))
		if err != nil {
			return nil, fmt.Errorf("DEPLOY_SMTP_PASSWORD_FILE: %w", err)
		}
		ns = append(ns, deployagent.Mail{
			Addr: addr, User: os.Getenv("DEPLOY_SMTP_USER"), Password: strings.TrimSpace(string(pw)),
			From: os.Getenv("DEPLOY_MAIL_FROM"), To: os.Getenv("DEPLOY_MAIL_TO"),
		})
	}
	return ns, nil
}

// envOr returns the variable, or def when it is unset. Set but empty
// stays empty (DEPLOY_NTFY_URL= turns ntfy off).
func envOr(k, def string) string {
	if v, ok := os.LookupEnv(k); ok {
		return v
	}
	return def
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "deploy-agent:", err)
	os.Exit(1)
}
