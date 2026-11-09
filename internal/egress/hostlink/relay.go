package hostlink

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/trevor-vaughan/claude-riotbox/internal/egress/policy"
)

// Relay answers the CONNECTs Envoy passes on, unterminated, for
// policy.HostLink: it tunnels one to Target on its port when the ports
// file lists the port, and refuses it otherwise. Envoy has already checked
// the port against the same allowlist; this is a second check.
//
// An established tunnel has no idle bound of its own: Envoy's
// stream_idle_timeout (3600s on the listener) closes an idle one, which
// ends both directions here.
type Relay struct {
	PortsFile string      // read again for each connection
	Target    string      // the address that reaches the host's loopback
	Log       *log.Logger // one line per connection; must be set
}

var (
	connectLine = regexp.MustCompile(`^CONNECT ([!-~]+) HTTP/1\.1$`)
	portText    = regexp.MustCompile(`^[1-9][0-9]{0,4}$`)
)

// maxDrain is the most a refusal reads of what the client sent after the
// head, so that closing does not reset the connection and drop the reply.
const maxDrain = 64 << 10

// Serve answers each connection ln accepts until ln is closed, then
// returns nil.
func (r Relay) Serve(ln net.Listener) error {
	for {
		c, err := ln.Accept()
		if errors.Is(err, net.ErrClosed) {
			return nil
		}
		if err != nil {
			r.Log.Printf("accept: %v", err)
			time.Sleep(acceptBackoff)
			continue
		}
		go r.handle(c)
	}
}

func (r Relay) handle(c net.Conn) {
	defer func() { _ = c.Close() }() // pipe may have closed it already
	if err := c.SetReadDeadline(time.Now().Add(headTimeout)); err != nil {
		r.Log.Printf("%v", err)
		return
	}
	br := bufio.NewReaderSize(c, maxHead)
	port, status := r.check(br)
	if status != http.StatusOK {
		r.refuse(c, br, port, status)
		return
	}
	up, err := net.DialTimeout("tcp", net.JoinHostPort(r.Target, strconv.Itoa(port)), dialTimeout)
	if err != nil {
		r.Log.Printf("port %d: %v", port, err)
		r.refuse(c, br, port, http.StatusBadGateway)
		return
	}
	if err := c.SetReadDeadline(time.Time{}); err != nil {
		r.Log.Printf("port %d: %v", port, err)
		_ = up.Close()
		return
	}
	if _, err := io.WriteString(c, "HTTP/1.1 200 Connection established\r\n\r\n"); err != nil {
		r.Log.Printf("port %d: %v", port, err)
		_ = up.Close()
		return
	}
	sent, received := pipe(c, br, up, up)
	r.Log.Printf("port %d: 200, %d bytes sent, %d received", port, sent, received)
}

// check reads the request head and returns the port it asks for (0 when
// it names none) and the status to answer: 200 to tunnel, 400 for anything
// but a CONNECT to policy.HostLink on a port 1-65535 without leading
// zeros, 403 for a port the ports file does not list.
func (r Relay) check(br *bufio.Reader) (port, status int) {
	head, err := readHead(br)
	if err != nil || len(head) == 0 {
		return 0, http.StatusBadRequest
	}
	m := connectLine.FindStringSubmatch(head[0])
	if m == nil {
		return 0, http.StatusBadRequest
	}
	host, digits, err := net.SplitHostPort(m[1])
	if err != nil || !strings.EqualFold(host, policy.HostLink) || !portText.MatchString(digits) || m[1] != host+":"+digits {
		return 0, http.StatusBadRequest
	}
	if port, err = strconv.Atoi(digits); err != nil || port > 65535 {
		return 0, http.StatusBadRequest
	}
	allowed, err := LoadPorts(r.PortsFile)
	if err != nil {
		r.Log.Printf("%s: %v; refusing every port", r.PortsFile, err)
		return port, http.StatusForbidden
	}
	if !allowed.Has(port) {
		return port, http.StatusForbidden
	}
	return port, http.StatusOK
}

// refuse answers status, half-closes and reads what the client still
// sends (up to maxDrain, within the head deadline), so the reply is not
// lost to a reset when the connection closes.
func (r Relay) refuse(c net.Conn, br *bufio.Reader, port, status int) {
	r.Log.Printf("port %d: %d", port, status)
	if _, err := fmt.Fprintf(c, "HTTP/1.1 %d %s\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", status, http.StatusText(status)); err != nil {
		r.Log.Printf("port %d: answering %d: %v", port, status, err)
		return
	}
	closeWrite(c)
	_, _ = io.Copy(io.Discard, io.LimitReader(br, maxDrain)) // draining only; its end is the close
}
