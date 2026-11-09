// Package policy parses and merges the allowlist a RIOTBOX_EGRESS=1
// session's Envoy proxy enforces: the host:port pairs the agent may open a
// CONNECT tunnel to. See docs/dev/egress.md.
//
// Every entry is validated here, before any value reaches Envoy's
// configuration, so a conf file cannot inject configuration.
package policy

import (
	"errors"
	"fmt"
	"regexp"
	"slices"
	"strconv"
	"strings"
)

// DefaultPort is the port of an entry that names none; PlainPort is the
// port of a plain-HTTP entry that names none.
const (
	DefaultPort = 443
	PlainPort   = 80
)

// MaxPortRange is the most ports one host:low-high entry may cover;
// host:* is how an entry allows every port.
const MaxPortRange = 1024

// plainScheme is the prefix of a plain-HTTP entry.
const plainScheme = "http://"

var (
	dnsLabel = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`)
	// numericLabel is a label inet_aton and the WHATWG URL parser read as a
	// number (decimal or 0x hex); a name ending in one is an IPv4 literal.
	// The input is already lowercase.
	numericLabel = regexp.MustCompile(`^([0-9]+|0x[0-9a-f]*)$`)
	portDigits   = regexp.MustCompile(`^[0-9]{1,5}$`)
)

var errIPLiteral = errors.New("host looks like an IP address; only names are allowed")

// Entry is one allowed destination.
type Entry struct {
	// Host is a lowercase DNS name, or "*." and one: a wildcard matching
	// any name that ends in "." and the rest, at any depth, but not the
	// rest itself.
	Host string
	Port int
	// PortEnd is the last port of a range host:Port-PortEnd, or 0 for the
	// single port Port. Every port is Port 1, PortEnd 65535: host:*.
	PortEnd int
	// Plain is true for plain (non-CONNECT) HTTP to Host:Port, which a
	// conf file spells http://host[:port]; false for a CONNECT tunnel.
	Plain bool
}

// AllPorts reports whether e allows every port (host:*).
func (e Entry) AllPorts() bool { return e.Port == 1 && e.PortEnd == 65535 }

// Last is e's last port: PortEnd for a range, else Port.
func (e Entry) Last() int {
	if e.PortEnd == 0 {
		return e.Port
	}
	return e.PortEnd
}

// String is the entry as a conf file spells it: http:// for a plain
// entry, and the port only when it is not that kind's default; host:* for
// every port, host:low-high for a range.
func (e Entry) String() string {
	scheme, port := "", DefaultPort
	if e.Plain {
		scheme, port = plainScheme, PlainPort
	}
	switch {
	case e.AllPorts():
		return scheme + e.Host + ":*"
	case e.PortEnd != 0:
		return scheme + e.Host + ":" + strconv.Itoa(e.Port) + "-" + strconv.Itoa(e.PortEnd)
	case e.Port == port:
		return scheme + e.Host
	default:
		return scheme + e.Host + ":" + strconv.Itoa(e.Port)
	}
}

// Authority is a single-port entry as Envoy matches a request's authority:
// always host:port.
func (e Entry) Authority() string {
	return e.Host + ":" + strconv.Itoa(e.Port)
}

// Parse reads one entry: ["-"] ["http://"] host [":" (port | low "-" high | "*")], where host is
// a DNS name of at least two labels or "*." and one. "http://" makes it a
// plain-HTTP entry, port 80 unless one is given; without it the entry is
// a CONNECT tunnel, port 443 unless one is given. A range covers at most
// MaxPortRange ports and low-low is the single port low; "*" is every
// port. remove reports the leading "-". Only printable ASCII is accepted, and it is checked before
// lowercasing: Unicode case folding maps some non-ASCII letters (U+212A
// KELVIN SIGN) to ASCII ones, which would let a look-alike pass
// validation.
func Parse(raw string) (e Entry, remove bool, err error) {
	for i := 0; i < len(raw); i++ {
		if raw[i] < 0x21 || raw[i] > 0x7e {
			return Entry{}, false, errors.New("only printable ASCII without spaces is allowed")
		}
	}
	s := strings.ToLower(raw)
	s, remove = strings.CutPrefix(s, "-")
	s, plain := strings.CutPrefix(s, plainScheme)
	if plain && strings.ContainsAny(s, "/?@") {
		if strings.Contains(s, "://") {
			return Entry{}, false, errors.New("a URL is not an entry; give host or host:port")
		}
		return Entry{}, false, errors.New("give http://host or http://host:port, without a path, query or user")
	}
	host, port := s, DefaultPort
	if plain {
		port = PlainPort
	}
	end := 0
	if i := strings.LastIndexByte(s, ':'); i >= 0 {
		host = s[:i]
		spec := s[i+1:]
		if strings.HasPrefix(spec, "//") {
			return Entry{}, false, errors.New("a URL is not an entry; give host or host:port")
		}
		if spec == "*" {
			port, end = 1, 65535
		} else {
			lo, hi, isRange := strings.Cut(spec, "-")
			var perr error
			if port, perr = parsePort(lo); perr != nil {
				return Entry{}, false, perr
			}
			if isRange {
				last, herr := parsePort(hi)
				if herr != nil {
					return Entry{}, false, herr
				}
				if last < port {
					return Entry{}, false, errors.New("a port range runs low-high")
				}
				if last-port+1 > MaxPortRange {
					return Entry{}, false, fmt.Errorf("a port range covers at most %d ports; use host:* for every port", MaxPortRange)
				}
				if last > port {
					end = last
				}
			}
		}
	}
	if strings.ContainsAny(host, ":[]") {
		return Entry{}, false, errIPLiteral
	}
	if cerr := checkHost(strings.TrimPrefix(host, "*.")); cerr != nil {
		return Entry{}, false, cerr
	}
	return Entry{Host: host, Port: port, PortEnd: end, Plain: plain}, remove, nil
}

// parsePort reads one port number, 1 to 65535.
func parsePort(digits string) (int, error) {
	n, err := strconv.Atoi(digits)
	if !portDigits.MatchString(digits) || err != nil || n < 1 || n > 65535 {
		return 0, errors.New("port must be a number from 1 to 65535")
	}
	return n, nil
}

// checkHost validates a DNS name (a wildcard's part after "*.").
func checkHost(name string) error {
	if name == "" {
		return errors.New("host is empty")
	}
	if len(name) > 253 {
		return errors.New("host is longer than 253 characters")
	}
	labels := strings.Split(name, ".")
	if len(labels) < 2 {
		return errors.New("host must have at least two labels (a bare name, * or *.tld is not allowed)")
	}
	for _, l := range labels {
		if !dnsLabel.MatchString(l) {
			return fmt.Errorf("label %q is not a valid DNS label", l)
		}
	}
	if numericLabel.MatchString(labels[len(labels)-1]) {
		return errIPLiteral
	}
	return nil
}

// HostCovers reports whether pattern matches host: the same name, or a
// wildcard "*.s" and a host (a name, or a narrower wildcard) ending in
// ".s".
func HostCovers(pattern, host string) bool {
	if pattern == host {
		return true
	}
	suffix, wild := strings.CutPrefix(pattern, "*")
	return wild && strings.HasSuffix(host, suffix)
}

// Covers reports whether w allows every host and port e names, whatever
// either one's kind.
func Covers(w, e Entry) bool {
	return HostCovers(w.Host, e.Host) && w.Port <= e.Port && e.Last() <= w.Last()
}

// Covering returns the other entries of e's kind that cover e (a wildcard
// matching its host, a range or every port holding its ports), so a deny
// can say why a host stays allowed.
func Covering(entries []Entry, e Entry) []Entry {
	var out []Entry
	for _, w := range entries {
		if w != e && w.Plain == e.Plain && Covers(w, e) {
			out = append(out, w)
		}
	}
	return out
}

// Overlapping returns the other entries of e's kind that allow some of e's
// hosts and ports but do not cover e: a narrower or partly overlapping
// range, or a name under a wildcard, so a deny can say what stays allowed.
func Overlapping(entries []Entry, e Entry) []Entry {
	var out []Entry
	for _, w := range entries {
		if w != e && w.Plain == e.Plain && !Covers(w, e) &&
			(HostCovers(w.Host, e.Host) || HostCovers(e.Host, w.Host)) &&
			w.Port <= e.Last() && e.Port <= w.Last() {
			out = append(out, w)
		}
	}
	return out
}

// merge returns add minus remove, each entry once, sorted by host, port, port end, then
// tunnel before plain.
func merge(add, remove []Entry) []Entry {
	removed := map[Entry]bool{}
	for _, e := range remove {
		removed[e] = true
	}
	seen := map[Entry]bool{}
	var out []Entry
	for _, e := range add {
		if removed[e] || seen[e] {
			continue
		}
		seen[e] = true
		out = append(out, e)
	}
	slices.SortFunc(out, func(a, b Entry) int {
		if c := strings.Compare(a.Host, b.Host); c != 0 {
			return c
		}
		if a.Port != b.Port {
			return a.Port - b.Port
		}
		if a.PortEnd != b.PortEnd {
			return a.PortEnd - b.PortEnd
		}
		switch {
		case a.Plain == b.Plain:
			return 0
		case a.Plain:
			return 1
		default:
			return -1
		}
	})
	return out
}
