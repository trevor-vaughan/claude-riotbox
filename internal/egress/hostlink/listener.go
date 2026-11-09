package hostlink

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"maps"
	"net"
	"os"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/trevor-vaughan/claude-riotbox/internal/egress/policy"
)

// Listener gives the agent a 127.0.0.1 listener for each port its ports
// file lists, so a tool can use localhost:PORT, and tunnels each accepted
// connection through the egress proxy as a CONNECT to policy.HostLink on
// that port. NO_PROXY keeps those tools' localhost connections direct.
type Listener struct {
	PortsFile string        // polled every Poll
	Proxy     string        // the proxy's host:port
	Poll      time.Duration // how often the ports file is read
	Log       *log.Logger
}

// Run keeps the listeners in step with the ports file until ctx ends. It
// applies the file each time its content changes: it opens a listener for
// each new port, closes the listener of each removed one (connections
// already open stay open, as with a live deny) and, on a port another
// process already holds, warns and tries it again at the next change. A
// file it cannot read or parse keeps the current listeners.
func (l Listener) Run(ctx context.Context) {
	open := map[int]net.Listener{}
	defer func() {
		for _, ln := range open {
			_ = ln.Close() // shutting down; nothing to do about a failed close
		}
	}()
	tick := time.NewTicker(l.Poll)
	defer tick.Stop()
	var last []byte
	lastErr, first := "", true
	for {
		data, err := os.ReadFile(l.PortsFile)
		if errors.Is(err, fs.ErrNotExist) {
			data, err = nil, nil
		}
		switch {
		case err != nil:
			if err.Error() != lastErr {
				l.Log.Printf("reading %s: %v; keeping the current listeners", l.PortsFile, err)
				lastErr = err.Error()
			}
		case first || !bytes.Equal(data, last):
			first, last, lastErr = false, data, ""
			if ports, perr := ParsePorts(data); perr != nil {
				l.Log.Printf("%s: %v; keeping the current listeners", l.PortsFile, perr)
			} else {
				l.apply(open, ports)
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
	}
}

// apply makes open hold a listener for each port of ports. A range wider
// than policy.MaxPortRange (every port, from host.containers.internal:*)
// gets none: one listener per port would take the whole port space.
func (l Listener) apply(open map[int]net.Listener, ports Ports) {
	want := map[int]bool{}
	for _, r := range ports {
		if r.Hi-r.Lo+1 > policy.MaxPortRange {
			l.Log.Printf("ports %d-%d: no 127.0.0.1 listeners for a range wider than %d ports; use %s:PORT through the proxy", r.Lo, r.Hi, policy.MaxPortRange, policy.HostLink)
			continue
		}
		for p := r.Lo; p <= r.Hi; p++ {
			want[p] = true
		}
	}
	for p, ln := range open {
		if !want[p] {
			_ = ln.Close() // a close error leaves nothing to undo
			delete(open, p)
			l.Log.Printf("port %d: closed", p)
		}
	}
	for _, p := range slices.Sorted(maps.Keys(want)) {
		if open[p] != nil {
			continue
		}
		ln, err := net.Listen("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(p)))
		if err != nil {
			l.Log.Printf("WARNING: port %d: %v; retrying when the allowlist changes", p, err)
			continue
		}
		open[p] = ln
		l.Log.Printf("port %d: listening on %s", p, ln.Addr())
		go l.serve(ln, p)
	}
}

// serve tunnels each connection ln accepts until ln is closed.
func (l Listener) serve(ln net.Listener, port int) {
	for {
		c, err := ln.Accept()
		if errors.Is(err, net.ErrClosed) {
			return
		}
		if err != nil {
			l.Log.Printf("port %d: accept: %v", port, err)
			time.Sleep(acceptBackoff)
			continue
		}
		go l.tunnel(c, port)
	}
}

// tunnel opens a CONNECT to policy.HostLink on port through the proxy and
// pipes c through it; any answer but 200 closes c.
func (l Listener) tunnel(c net.Conn, port int) {
	up, err := net.DialTimeout("tcp", l.Proxy, dialTimeout)
	if err != nil {
		l.Log.Printf("port %d: reaching the proxy: %v", port, err)
		_ = c.Close()
		return
	}
	fail := func(format string, args ...any) {
		l.Log.Printf("port %d: "+format, append([]any{port}, args...)...)
		_ = c.Close()
		_ = up.Close()
	}
	authority := net.JoinHostPort(policy.HostLink, strconv.Itoa(port))
	if err := up.SetDeadline(time.Now().Add(headTimeout)); err != nil {
		fail("%v", err)
		return
	}
	if _, err := fmt.Fprintf(up, "CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n", authority, authority); err != nil {
		fail("%v", err)
		return
	}
	br := bufio.NewReaderSize(up, maxHead)
	head, err := readHead(br)
	if err != nil {
		fail("reading the proxy's answer: %v", err)
		return
	}
	if len(head) == 0 {
		fail("the proxy sent an empty answer")
		return
	}
	if f := strings.Fields(head[0]); len(f) < 2 || f[1] != "200" {
		fail("the proxy refused: %q", head[0])
		return
	}
	if err := up.SetDeadline(time.Time{}); err != nil {
		fail("%v", err)
		return
	}
	sent, received := pipe(c, c, up, br)
	l.Log.Printf("port %d: done, %d bytes sent, %d received", port, sent, received)
}
