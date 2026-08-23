// caddylog converts Caddy JSON access logs into the flat, space-separated
// format goaccess expects (see services/goaccess/README.md), either
// processing a file once (-t 0) or tailing it (-t <seconds>).
//
// Usage: caddylog -i <input.log> -t <interval> -g <output.log>
//
// Port of services/goaccess/caddyLog.py - argv parsing, log-rotation
// detection, and the readline()-at-EOF tailing behavior are kept 1:1.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"
	"time"
)

type caddyRequest struct {
	Host       string              `json:"host"`
	RemoteIP   string              `json:"remote_ip"`
	RemoteAddr string              `json:"remote_addr"`
	Method     string              `json:"method"`
	URI        string              `json:"uri"`
	Proto      string              `json:"proto"`
	Headers    map[string][]string `json:"headers"`
}

type caddyLogEntry struct {
	TS       float64      `json:"ts"`
	Logger   string       `json:"logger"`
	Request  caddyRequest `json:"request"`
	Status   int          `json:"status"`
	Size     *int64       `json:"size"`
	Duration float64      `json:"duration"`
}

func stamp() string {
	return time.Now().Format("2006-01-02 15:04:05.000000")
}

func convertToGoAccess(e caddyLogEntry) string {
	sec := int64(e.TS)
	nsec := int64((e.TS - float64(sec)) * 1e9)
	t := time.Unix(sec, nsec)

	host := e.Request.RemoteIP
	if host == "" {
		host = e.Request.RemoteAddr
		if idx := lastIndexByte(host, ':'); idx >= 0 {
			host = host[:idx]
		}
		if len(host) > 0 && host[0] == '[' {
			if end := lastIndexByte(host, ']'); end >= 0 {
				host = host[1:end]
			}
		}
	}

	size := int64(0)
	if e.Size != nil {
		size = *e.Size
	}

	referer := "unknown"
	if v, ok := e.Request.Headers["Referer"]; ok && len(v) > 0 {
		referer = v[0]
	}

	userAgent := `""`
	if v, ok := e.Request.Headers["User-Agent"]; ok && len(v) > 0 {
		userAgent = `"` + v[0] + `"`
	}

	return fmt.Sprintf("%s %s %s %s %s %s %s %d %d %v %s %s",
		t.Format("2006-01-02"), t.Format("15:04:05"),
		e.Request.Host, host, e.Request.Method, e.Request.URI, e.Request.Proto,
		e.Status, size, e.Duration, referer, userAgent,
	)
}

func lastIndexByte(s string, b byte) int {
	for i := len(s) - 1; i >= 0; i-- {
		if s[i] == b {
			return i
		}
	}
	return -1
}

func inode(f *os.File) uint64 {
	fi, err := f.Stat()
	if err != nil {
		return 0
	}
	if st, ok := fi.Sys().(*syscall.Stat_t); ok {
		return st.Ino
	}
	return 0
}

func statInode(path string) (uint64, error) {
	fi, err := os.Stat(path)
	if err != nil {
		return 0, err
	}
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, fmt.Errorf("no stat_t")
	}
	return st.Ino, nil
}

func run(inputPath string, timeInterval int, outputPath string) error {
	g, err := os.Create(outputPath)
	if err != nil {
		fmt.Printf("\n%s - ERROR: Output file %q error\n", stamp(), outputPath)
		os.Exit(2)
	}
	defer g.Close()

	j, err := os.Open(inputPath)
	if err != nil {
		fmt.Printf("\n%s - ERROR: Input file %q not found\n", stamp(), inputPath)
		os.Exit(2)
	}
	defer j.Close()

	fmt.Printf("%s - processing JSON input file: %s\n", stamp(), inputPath)

	totalLogCount := 0
	batchLogCount := 0
	currentInode := inode(j)
	reader := bufio.NewReader(j)

	for {
		line, rerr := reader.ReadString('\n')
		if line != "" {
			var entry caddyLogEntry
			if err := json.Unmarshal([]byte(line), &entry); err != nil {
				continue
			}
			if !hasPrefix(entry.Logger, "http.log.access") {
				continue
			}
			fmt.Fprintln(g, convertToGoAccess(entry))
			totalLogCount++
			batchLogCount++
			continue
		}

		if rerr != nil && rerr != io.EOF {
			return rerr
		}

		if timeInterval > 0 {
			g.Sync()
			if batchLogCount > 0 {
				fmt.Printf("%s - %d log entries written to %s\n", stamp(), batchLogCount, outputPath)
				batchLogCount = 0
			}
			if newInode, statErr := statInode(inputPath); statErr == nil && newInode != currentInode {
				fmt.Printf("%s - log rotation detected, reopening %s\n", stamp(), inputPath)
				j.Close()
				newJ, openErr := os.Open(inputPath)
				if openErr != nil {
					return openErr
				}
				j = newJ
				currentInode = inode(j)
				reader = bufio.NewReader(j)
				continue
			}
			fmt.Printf("%s - sleeping for %d seconds before checking for additional log entries\n", stamp(), timeInterval)
			time.Sleep(time.Duration(timeInterval) * time.Second)
		} else {
			fmt.Printf("%s - TOTAL: %d log entries written to %s\n\n", stamp(), totalLogCount, outputPath)
			g.Sync()
			return nil
		}
	}
}

func hasPrefix(s, prefix string) bool {
	return len(s) >= len(prefix) && s[:len(prefix)] == prefix
}

func main() {
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT)
	go func() {
		<-sigCh
		fmt.Printf("\n%s - Terminating . . . \n", stamp())
		os.Exit(0)
	}()

	args := os.Args
	inputPath := ""
	if len(args) > 2 && args[1] == "-i" {
		inputPath = args[2]
	}
	timeInterval := 0
	if len(args) > 4 && args[3] == "-t" {
		fmt.Sscanf(args[4], "%d", &timeInterval)
	}
	outputPath := ""
	if len(args) > 6 && args[5] == "-g" {
		outputPath = args[6]
	}

	fmt.Println()
	fmt.Printf("%s - INITIALISING: caddylog (Caddy/GoAccess data logger & converter)\n", stamp())

	if inputPath == "" {
		return
	}
	if err := run(inputPath, timeInterval, outputPath); err != nil {
		fmt.Printf("%s - ERROR: %v\n", stamp(), err)
		os.Exit(1)
	}
}
