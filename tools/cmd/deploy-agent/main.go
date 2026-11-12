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
//	DEPLOY_MODE          apply (default) or noop
//	DEPLOY_APPLY_TIMEOUT default 30m
//	DEPLOY_INTERVAL      poll interval (default 60s)
//	DEPLOY_SUSPEND_FILE  default /etc/homelab-deploy/suspend
//	DEPLOY_NTFY_URL      default https://ntfy.mljr.eu/deployment; empty: none
//	DEPLOY_MAIL_TO       mail recipient; empty: no mail fallback
//	DEPLOY_SMTP_HOST, _PORT (587), _USER, _PASSWORD, _FROM (default user)
//	DEPLOY_SMTP2_*       second, independent relay (as healthreport's)
//
//	DEPLOY_ENV_FILE      watched for changes (default /etc/homelab-deploy/agent.env)
//
// The agent exits after a poll once its own binary or DEPLOY_ENV_FILE
// changed, and systemd (Restart=always) starts the new one. Puppet does
// not restart the unit: an apply run by the agent that updates the agent
// would kill its own puppet apply.
//
// --once polls once and exits. --test-notify sends a test result through
// each notifier on its own and reports which ones work.
package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"strconv"
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
	if len(os.Args) > 1 && os.Args[1] == "--test-notify" {
		testNotify(host, notifiers)
		return
	}

	agent, err := deployagent.New(deployagent.Config{
		Host:         host,
		RepoURL:      envOr("DEPLOY_REPO_URL", "https://github.com/MrCodeEU/homelab-automation.git"),
		MainBranch:   envOr("DEPLOY_MAIN_BRANCH", "main"),
		StateDir:     envOr("DEPLOY_STATE_DIR", "/var/lib/homelab-deploy"),
		Keyring:      string(keyring),
		Apply:        envOr("DEPLOY_APPLY", "scripts/openvox-apply.sh"),
		ApplyTimeout: timeout,
		Mode:         envOr("DEPLOY_MODE", "apply"),
		SuspendFile:  envOr("DEPLOY_SUSPEND_FILE", "/etc/homelab-deploy/suspend"),
		Notifiers:    notifiers,
		Log:          log,
	})
	if err != nil {
		fatal(err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	self, _ := os.Executable()
	watched := []string{self, envOr("DEPLOY_ENV_FILE", "/etc/homelab-deploy/agent.env")}
	started := fingerprints(watched)
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
		if now := fingerprints(watched); now != started {
			log.Info("binary or env file changed, exiting for systemd to restart", "files", watched)
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
	to := os.Getenv("DEPLOY_MAIL_TO")
	for _, p := range []string{"DEPLOY_SMTP_", "DEPLOY_SMTP2_"} {
		host := os.Getenv(p + "HOST")
		if to == "" || host == "" {
			continue
		}
		port, err := strconv.Atoi(envOr(p+"PORT", "587"))
		if err != nil {
			return nil, fmt.Errorf("%sPORT: %w", p, err)
		}
		user := os.Getenv(p + "USER")
		ns = append(ns, deployagent.Mail{
			Host: host, Port: port, User: user, Password: os.Getenv(p + "PASSWORD"),
			From: envOr(p+"FROM", user), To: to,
		})
	}
	return ns, nil
}

// testNotify sends one made-up failure through every notifier.
func testNotify(host string, ns []deployagent.Notifier) {
	r := deployagent.Result{
		RequestID: time.Now().UTC().Format("20060102T150405Z") + "-test", Host: host,
		Commit: strings.Repeat("0", 40), Outcome: "failure",
		Detail: "test notification from deploy-agent --test-notify, nothing was deployed", Time: time.Now(),
	}
	failed := false
	for _, n := range ns {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
		err := n.Notify(ctx, r)
		cancel()
		if err != nil {
			failed = true
		}
		fmt.Printf("%-28s %v\n", n.Name(), errOK(err))
	}
	if failed || len(ns) == 0 {
		os.Exit(1)
	}
}

func errOK(err error) any {
	if err == nil {
		return "ok"
	}
	return err
}

// fingerprints identifies the files' current versions (inode, size,
// mtime); a missing file counts as a version too.
func fingerprints(paths []string) string {
	var b strings.Builder
	for _, p := range paths {
		fi, err := os.Stat(p)
		if err != nil {
			fmt.Fprintf(&b, "%s:missing;", p)
			continue
		}
		var ino uint64
		if st, ok := fi.Sys().(*syscall.Stat_t); ok {
			ino = st.Ino
		}
		fmt.Fprintf(&b, "%s:%d:%d:%d;", p, ino, fi.Size(), fi.ModTime().UnixNano())
	}
	return b.String()
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
