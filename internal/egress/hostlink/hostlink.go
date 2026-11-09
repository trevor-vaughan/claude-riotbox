// Package hostlink carries an egress session's CONNECTs to
// policy.HostLink to the host's loopback, where ssh -L forwards bind.
// Relay runs in the session's hostlink sidecar, whose only network is
// pasta with --map-host-loopback; Envoy passes it each allowed CONNECT
// unterminated over a Unix socket, and it checks the port again before
// dialling. Listener runs in the agent and gives each allowed port a
// 127.0.0.1 listener that tunnels through the proxy. Both read the allowed
// ports from the session's ports file (RenderPorts). See docs/dev/egress.md
// "Host loopback".
package hostlink

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/trevor-vaughan/claude-riotbox/internal/egress/policy"
)

// PortsFile names the allowed-ports file in the session's share dir.
const PortsFile = "hostlink.ports"

// maxHead is the most bytes of a request or response head either side
// reads before the blank line.
const maxHead = 8 << 10

// dialTimeout bounds each TCP dial; headTimeout bounds reading a head.
const (
	dialTimeout = 10 * time.Second
	headTimeout = 30 * time.Second
)

// acceptBackoff is how long an accept loop waits after an error other than
// a closed listener (such as running out of file descriptors).
const acceptBackoff = 100 * time.Millisecond

// Range is the ports Lo to Hi, inclusive.
type Range struct{ Lo, Hi int }

// Ports is a parsed ports file.
type Ports []Range

// Has reports whether any range of p holds port.
func (p Ports) Has(port int) bool {
	for _, r := range p {
		if r.Lo <= port && port <= r.Hi {
			return true
		}
	}
	return false
}

// RenderPorts returns the ports file of entries: one line per tunnel entry
// for policy.HostLink, "port" or "low-high", every port being "1-65535".
// Plain entries for that host are skipped: the relay carries tunnels only.
func RenderPorts(entries []policy.Entry) []byte {
	var b strings.Builder
	for _, e := range entries {
		if e.Host != policy.HostLink || e.Plain {
			continue
		}
		if e.Last() == e.Port {
			fmt.Fprintf(&b, "%d\n", e.Port)
		} else {
			fmt.Fprintf(&b, "%d-%d\n", e.Port, e.Last())
		}
	}
	return []byte(b.String())
}

var portsLine = regexp.MustCompile(`^([1-9][0-9]{0,4})(?:-([1-9][0-9]{0,4}))?$`)

// ParsePorts reads a ports file as RenderPorts writes it. It fails the
// whole file, so a damaged file allows nothing, on any line that is not a
// port or a low-high range of ports 1 to 65535, and on non-empty data that
// does not end in a newline (a partly read file must not allow a fragment
// such as 181 of 18100). It accepts a range of one port, duplicates and
// overlaps.
func ParsePorts(data []byte) (Ports, error) {
	if len(data) == 0 {
		return nil, nil
	}
	if data[len(data)-1] != '\n' {
		return nil, errors.New("the file does not end in a newline")
	}
	var p Ports
	for i, line := range strings.Split(strings.TrimSuffix(string(data), "\n"), "\n") {
		m := portsLine.FindStringSubmatch(line)
		if m == nil {
			return nil, fmt.Errorf("line %d: %q is not a port or a low-high range", i+1, line)
		}
		lo, err := strconv.Atoi(m[1])
		if err != nil {
			return nil, fmt.Errorf("line %d: %w", i+1, err)
		}
		hi := lo
		if m[2] != "" {
			if hi, err = strconv.Atoi(m[2]); err != nil {
				return nil, fmt.Errorf("line %d: %w", i+1, err)
			}
		}
		if lo > hi || hi > 65535 {
			return nil, fmt.Errorf("line %d: %q is not a range of ports 1 to 65535", i+1, line)
		}
		p = append(p, Range{Lo: lo, Hi: hi})
	}
	return p, nil
}

// LoadPorts reads and parses the ports file at path; a missing file is no
// ports.
func LoadPorts(path string) (Ports, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return ParsePorts(data)
}
