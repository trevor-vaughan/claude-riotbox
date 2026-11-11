// Package hub is `riotbox hub`: one page on one LAN port that lists the
// running `riotbox anywhere` sessions and links to each one's Yep Anywhere.
//
// It holds no session state of its own. The list comes from the engine:
// libexec/anywhere-lib.sh labels every `riotbox anywhere` container with
// LabelURL, and launch.sh labels every container with LabelSession, whose
// state dir records the session's projects. Each session keeps its own
// container, password and certificate; the hub only links to them.
package hub

import (
	"encoding/json"
	"fmt"
	"net/url"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/trevor-vaughan/claude-riotbox/internal/records"
)

// The labels a `riotbox anywhere` container carries.
const (
	LabelURL     = "riotbox.anywhere.url"
	LabelSession = "riotbox.session"
)

// Session is one running `riotbox anywhere` container.
type Session struct {
	Container string    // the container's name
	Key       string    // its riotbox.session label
	URL       string    // where its Yep Anywhere is published
	Projects  []string  // the project dirs its state dir records; nil when unreadable
	Started   time.Time // zero when the engine did not report it
	LocalOnly bool      // published on loopback: unreachable from a phone
}

// Lister lists sessions. Engine is the container engine command (podman or
// docker); StateRoot is RIOTBOX_STATE_ROOT. Output runs the engine and
// returns its stdout; nil means exec.Command.
type Lister struct {
	Engine    string
	StateRoot string
	Output    func(name string, args ...string) ([]byte, error)
}

func (l Lister) output(args ...string) ([]byte, error) {
	if l.Output != nil {
		return l.Output(l.Engine, args...)
	}
	out, err := exec.Command(l.Engine, args...).Output()
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok && len(ee.Stderr) > 0 {
			return nil, fmt.Errorf("%s %s: %w: %s", l.Engine, args[0], err, strings.TrimSpace(string(ee.Stderr)))
		}
		return nil, fmt.Errorf("%s %s: %w", l.Engine, args[0], err)
	}
	return out, nil
}

// inspected is the part of `container inspect` both podman and docker print
// the same way.
type inspected struct {
	Name   string
	Config struct {
		Labels map[string]string
	}
	State struct {
		Running   bool
		StartedAt string
	}
}

// List returns the running sessions, oldest first. A container whose URL
// label is not an https URL is left out: the page must link only to what
// RiotBox itself published.
func (l Lister) List() ([]Session, error) {
	ids, err := l.output("ps", "--filter", "label="+LabelURL, "--format", "{{.ID}}")
	if err != nil {
		return nil, err
	}
	fields := strings.Fields(string(ids))
	if len(fields) == 0 {
		return nil, nil
	}
	out, err := l.output(append([]string{"container", "inspect"}, fields...)...)
	if err != nil {
		// A container that exited between ps and inspect fails the whole
		// inspect; the next refresh will not see it.
		return nil, err
	}
	var containers []inspected
	if err := json.Unmarshal(out, &containers); err != nil {
		return nil, fmt.Errorf("reading %s container inspect: %w", l.Engine, err)
	}
	var sessions []Session
	for _, c := range containers {
		if !c.State.Running {
			continue
		}
		s, ok := l.session(c)
		if ok {
			sessions = append(sessions, s)
		}
	}
	slices.SortStableFunc(sessions, func(a, b Session) int {
		if c := a.Started.Compare(b.Started); c != 0 {
			return c
		}
		return strings.Compare(a.Container, b.Container)
	})
	return sessions, nil
}

func (l Lister) session(c inspected) (Session, bool) {
	raw := c.Config.Labels[LabelURL]
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || (u.Path != "" && u.Path != "/") || u.RawQuery != "" || u.Fragment != "" {
		return Session{}, false
	}
	s := Session{
		Container: strings.TrimPrefix(c.Name, "/"),
		Key:       c.Config.Labels[LabelSession],
		URL:       u.Scheme + "://" + u.Host,
	}
	if t, err := time.Parse(time.RFC3339Nano, c.State.StartedAt); err == nil {
		s.Started = t
	}
	host := u.Hostname()
	s.LocalOnly = host == "localhost" || strings.HasPrefix(host, "127.") || host == "::1"
	// The key names a directory under the state root, so it must be one
	// path element: a label is whatever the container was given.
	if s.Key != "" && s.Key == filepath.Base(s.Key) && s.Key != "." && s.Key != ".." && l.StateRoot != "" {
		if projects, err := records.Recorded(filepath.Join(l.StateRoot, s.Key)); err == nil {
			s.Projects = projects
		}
	}
	return s, true
}
