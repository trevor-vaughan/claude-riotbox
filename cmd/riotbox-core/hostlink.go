package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log"
	"net"
	"net/url"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/trevor-vaughan/claude-riotbox/internal/display"
	"github.com/trevor-vaughan/claude-riotbox/internal/egress/hostlink"
)

// hostlinkRelay runs the hostlink sidecar's relay (hostlink.Relay) on a
// Unix socket at --socket, mode 0600, replacing a stale one, until killed.
// It logs to stderr, which the sidecar discards (--log-driver=none).
func hostlinkRelay(a parsedArgs, _, stderr io.Writer) int {
	target := a.opts["--target"]
	if net.ParseIP(target) == nil {
		_, _ = fmt.Fprintf(stderr, "riotbox-core: hostlink-relay: --target %s is not an IP address\n", display.Quote(target))
		return badUsage(stderr)
	}
	socket := a.opts["--socket"]
	if err := os.Remove(socket); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return egressFailed(stderr, err)
	}
	ln, err := net.Listen("unix", socket)
	if err != nil {
		return egressFailed(stderr, err)
	}
	if err := os.Chmod(socket, 0o600); err != nil {
		return egressFailed(stderr, errors.Join(err, ln.Close()))
	}
	r := hostlink.Relay{
		PortsFile: a.opts["--ports"],
		Target:    target,
		Log:       log.New(stderr, "hostlink-relay: ", log.LstdFlags),
	}
	if err := r.Serve(ln); err != nil {
		return egressFailed(stderr, err)
	}
	return 0
}

// hostlinkListen runs the agent's host-loopback listeners
// (hostlink.Listener) until SIGTERM or SIGINT.
func hostlinkListen(a parsedArgs, _, stderr io.Writer) int {
	u, err := url.Parse(a.opts["--proxy"])
	if err != nil || u.Scheme != "http" || u.Hostname() == "" || u.Port() == "" {
		_, _ = fmt.Fprintf(stderr, "riotbox-core: hostlink-listen: --proxy %s is not http://host:port\n", display.Quote(a.opts["--proxy"]))
		return badUsage(stderr)
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()
	hostlink.Listener{
		PortsFile: a.opts["--ports"],
		Proxy:     u.Host,
		Poll:      2 * time.Second,
		Log:       log.New(stderr, "hostlink-listen: ", log.LstdFlags),
	}.Run(ctx)
	return 0
}
