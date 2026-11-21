package tcpproxy

import (
	"bufio"
	"context"
	"io"
	"log/slog"
	"net"
	"strings"
	"testing"
	"time"
)

func listen(t *testing.T) net.Listener {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = ln.Close() })
	return ln
}

// proxy serves a relay to upstream and returns its address.
func proxy(t *testing.T, upstream string, idle time.Duration) string {
	t.Helper()
	ln := listen(t)
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	dial := func(ctx context.Context) (net.Conn, error) {
		var d net.Dialer
		return d.DialContext(ctx, "tcp", upstream)
	}
	go func() {
		_ = Serve(ctx, ln, "test", dial, time.Second, idle, slog.New(slog.NewTextHandler(io.Discard, nil)))
	}()
	return ln.Addr().String()
}

func TestRelayRequestResponse(t *testing.T) {
	up := listen(t)
	go func() {
		c, err := up.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		line, _ := bufio.NewReader(c).ReadString('\n')
		_, _ = io.WriteString(c, "echo "+line)
	}()

	c, err := net.Dial("tcp", proxy(t, up.Addr().String(), time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	_, _ = io.WriteString(c, "ping\n")
	got, err := io.ReadAll(c)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "echo ping\n" {
		t.Fatalf("got %q", got)
	}
}

// A client that half-closes after its request still gets the response.
func TestRelayHalfClose(t *testing.T) {
	up := listen(t)
	go func() {
		c, err := up.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		body, _ := io.ReadAll(c) // returns at the client's FIN
		_, _ = io.WriteString(c, strings.ToUpper(string(body)))
	}()

	c, err := net.Dial("tcp", proxy(t, up.Addr().String(), time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	_, _ = io.WriteString(c, "request")
	_ = c.(*net.TCPConn).CloseWrite()
	got, _ := io.ReadAll(c)
	if string(got) != "REQUEST" {
		t.Fatalf("got %q", got)
	}
}

// The upstream accepts and then never answers or closes: the zombie
// circuit. The client must see EOF after the idle timeout, not hang.
func TestRelayIdleTimeoutClosesSilentUpstream(t *testing.T) {
	up := listen(t)
	held := make(chan net.Conn, 1)
	go func() {
		c, err := up.Accept()
		if err == nil {
			held <- c
		}
	}()
	t.Cleanup(func() {
		select {
		case c := <-held:
			_ = c.Close()
		default:
		}
	})

	c, err := net.Dial("tcp", proxy(t, up.Addr().String(), 200*time.Millisecond))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	_, _ = io.WriteString(c, "GET /v1/heartbeat\n")
	_ = c.SetReadDeadline(time.Now().Add(5 * time.Second))
	start := time.Now()
	n, err := c.Read(make([]byte, 16))
	if n != 0 || err != io.EOF {
		t.Fatalf("read = %d, %v; want 0, EOF", n, err)
	}
	if d := time.Since(start); d > 2*time.Second {
		t.Fatalf("closed after %s", d)
	}
}

// Traffic keeps resetting the idle timer: a slow but live stream survives.
func TestRelayActivityResetsIdle(t *testing.T) {
	up := listen(t)
	go func() {
		c, err := up.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		for i := 0; i < 6; i++ {
			time.Sleep(100 * time.Millisecond)
			if _, err := io.WriteString(c, "x"); err != nil {
				return
			}
		}
	}()

	c, err := net.Dial("tcp", proxy(t, up.Addr().String(), 250*time.Millisecond))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	got, _ := io.ReadAll(c)
	if string(got) != "xxxxxx" {
		t.Fatalf("got %q; stream cut by the idle timeout", got)
	}
}

func TestServeDialFailureClosesClient(t *testing.T) {
	ln := listen(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	dial := func(context.Context) (net.Conn, error) { return nil, io.ErrUnexpectedEOF }
	go func() {
		_ = Serve(ctx, ln, "test", dial, time.Second, time.Minute, slog.New(slog.NewTextHandler(io.Discard, nil)))
	}()
	c, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	_ = c.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := c.Read(make([]byte, 1)); err != io.EOF {
		t.Fatalf("read err = %v; want EOF", err)
	}
}
