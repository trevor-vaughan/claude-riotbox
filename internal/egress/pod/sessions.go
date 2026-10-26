package pod

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/trevor-vaughan/claude-riotbox/internal/display"
	"github.com/trevor-vaughan/claude-riotbox/internal/egress/state"
)

// RunningSession is a session whose proxy container runs, as the engine
// reports it.
type RunningSession struct {
	Name     string
	Started  time.Time // when its proxy started; zero when not reported
	OwnerPID int       // its launch.sh; 0 when the label is missing or not in 1..MaxInt32
}

// RunningSessions returns the sessions whose proxy container runs, sorted
// by name and each once. A container whose label is not a valid session
// name, or whose own name is not that session's proxy name, is reported
// and left out: nothing may act on a name that could escape the state
// root, or on a container that merely claims a session.
func (m Manager) RunningSessions() ([]RunningSession, error) {
	out, err := m.Engine.Output("ps", "--filter", "label="+LabelRole+"="+roleGateway, "--format", "json")
	if err != nil {
		return nil, err
	}
	var containers []struct {
		Names     []string
		Labels    map[string]string
		StartedAt int64 // Unix seconds
	}
	if err := decodeList(out, &containers); err != nil {
		return nil, fmt.Errorf("reading the engine's container list: %w", err)
	}
	var running []RunningSession
	for _, c := range containers {
		name, ok := m.sessionName(c.Labels, c.Names, "-egress")
		if !ok {
			continue
		}
		s := RunningSession{Name: name, OwnerPID: ownerPID(c.Labels)}
		if c.StartedAt > 0 {
			s.Started = time.Unix(c.StartedAt, 0)
		}
		running = append(running, s)
	}
	slices.SortStableFunc(running, func(a, b RunningSession) int { return strings.Compare(a.Name, b.Name) })
	return slices.CompactFunc(running, func(a, b RunningSession) bool { return a.Name == b.Name }), nil
}

// Running returns the names of the sessions RunningSessions reports.
func (m Manager) Running() ([]string, error) {
	sessions, err := m.RunningSessions()
	if err != nil {
		return nil, err
	}
	names := make([]string, 0, len(sessions))
	for _, s := range sessions {
		names = append(names, s.Name)
	}
	return names, nil
}

// Target picks the session an allow, deny or reload acts on: the named one,
// which must be running, or with no name the only running one.
func (m Manager) Target(root, name string) (state.Dir, error) {
	running, err := m.Running()
	if err != nil {
		return state.Dir{}, err
	}
	switch {
	case name != "":
		if !slices.Contains(running, name) {
			return state.Dir{}, fmt.Errorf("no egress session named %s is running", display.Quote(name))
		}
	case len(running) == 0:
		return state.Dir{}, errors.New("no egress session is running")
	case len(running) > 1:
		return state.Dir{}, fmt.Errorf("%d egress sessions are running; pick one with --session: %s", len(running), strings.Join(running, " "))
	default:
		name = running[0]
	}
	return state.Open(root, name)
}

// session is one egress pod or network the engine knows of.
type session struct {
	name       string
	ownerPID   int // 0 when the label is missing or not in 1..MaxInt32
	ownerPIDNS string
}

// sessions lists every egress pod and network that is named as its
// session's object. podman prints pods with capitalised JSON keys and
// networks with lowercase ones; encoding/json matches either.
func (m Manager) sessions() ([]session, error) {
	var found []session
	for _, kind := range []struct {
		noun     string
		args     []string
		suffixes []string
	}{
		{"pods", []string{"pod", "ps"}, []string{"-pod"}},
		{"networks", []string{"network", "ls"}, []string{"-int", "-ext"}},
	} {
		out, err := m.Engine.Output(append(kind.args, "--filter", "label="+LabelEgress, "--format", "json")...)
		if err != nil {
			return nil, fmt.Errorf("listing egress %s: %w", kind.noun, err)
		}
		var objects []struct {
			Name   string
			Labels map[string]string
		}
		if err := decodeList(out, &objects); err != nil {
			return nil, fmt.Errorf("reading the engine's %s list: %w", kind.noun, err)
		}
		for _, o := range objects {
			name, ok := m.sessionName(o.Labels, []string{o.Name}, kind.suffixes...)
			if !ok {
				continue
			}
			found = append(found, session{name: name, ownerPID: ownerPID(o.Labels), ownerPIDNS: o.Labels[LabelOwnerPIDNS]})
		}
	}
	return found, nil
}

// Sweep tears down the egress pods and networks whose launch is gone (its
// owner PID no longer exists in this PID namespace) and whose agent no
// longer runs, then deletes the state dirs under root that no session uses
// and that saw no use for maxAge. Nothing is touched when the engine
// cannot list them. A session is judged over all its entries: if any has
// an owner that is in another PID namespace, has a missing or malformed
// owner label, or is alive, the session is left alone, because a
// concurrent session must never be torn down. So is a session whose agent
// container still runs in its pod, or whose pod's containers cannot be
// listed: a launch killed with SIGKILL leaves its agent running.
//
// A session name reused by a new launch (names end in 32 random bits)
// whose old state dir is older than maxAge could be removed between
// Create and Up's log reset. That is accepted: names collide with
// negligible probability.
func (m Manager) Sweep(root string, maxAge time.Duration, now time.Time) error {
	found, err := m.sessions()
	if err != nil {
		return err
	}
	own := pidNamespace()
	live := map[string]bool{}
	for _, s := range found {
		if own == "" || s.ownerPIDNS != own || s.ownerPID == 0 || alive(s.ownerPID) {
			live[s.name] = true
		}
	}
	var errs []error
	checked := map[string]bool{}
	for _, s := range found {
		if live[s.name] || checked[s.name] {
			continue
		}
		checked[s.name] = true
		running, err := m.agentRunning(s.name)
		if err != nil {
			errs = append(errs, fmt.Errorf("keeping the egress session %s: cannot tell whether its agent runs: %w", s.name, err))
		}
		if running || err != nil {
			live[s.name] = true
		}
	}
	for _, s := range found {
		if live[s.name] {
			continue
		}
		dir, err := state.Open(root, s.name)
		if err == nil {
			err = m.Down(dir, false)
		}
		if err != nil {
			errs = append(errs, fmt.Errorf("tearing down the orphaned egress session %s: %w", s.name, err))
		}
		// Down removes the session's every object; a repeat for its other
		// entries, or a state dir kept after a failure, must not follow.
		live[s.name] = true
	}
	// Stale reports the names it could judge even when some entry could
	// not be examined; act on those and report the rest.
	stale, err := state.Stale(root, live, maxAge, now)
	if err != nil {
		errs = append(errs, err)
	}
	for _, name := range stale {
		dir, err := state.Open(root, name)
		if err == nil {
			err = dir.Remove()
		}
		if err != nil {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}

// agentRunning reports whether the session's agent container, which
// launch.sh names after the session, runs in the session's pod.
func (m Manager) agentRunning(session string) (bool, error) {
	out, err := m.Engine.Output("ps", "--filter", "pod="+namesFor(session).pod, "--format", "json")
	if err != nil {
		return false, err
	}
	var containers []struct{ Names []string }
	if err := decodeList(out, &containers); err != nil {
		return false, fmt.Errorf("reading the engine's container list: %w", err)
	}
	for _, c := range containers {
		if slices.Contains(c.Names, session) {
			return true, nil
		}
	}
	return false, nil
}

// sessionName returns the riotbox.egress label when it is a valid session
// name and one of objectNames is the name+suffix of that session; it warns
// on Stderr otherwise. The object-name check stops an object that merely
// carries the label from steering teardown at another session.
func (m Manager) sessionName(labels map[string]string, objectNames []string, suffixes ...string) (string, bool) {
	name := labels[LabelEgress]
	if err := state.ValidName(name); err != nil {
		_, _ = fmt.Fprintf(m.Stderr, "egress: ignoring an engine object labelled %s=%s: %v\n", LabelEgress, display.Quote(name), err)
		return "", false
	}
	for _, have := range objectNames {
		for _, suffix := range suffixes {
			if have == name+suffix {
				return name, true
			}
		}
	}
	_, _ = fmt.Fprintf(m.Stderr, "egress: ignoring %s: it is labelled %s=%s but is not named like that session's object\n", display.Quote(strings.Join(objectNames, ",")), LabelEgress, name)
	return "", false
}

// ownerPID is the owner PID label, or 0 when it is missing or not in
// 1..MaxInt32.
func ownerPID(labels map[string]string) int {
	pid, err := strconv.Atoi(labels[LabelOwnerPID])
	if err != nil || pid < 1 || pid > math.MaxInt32 {
		return 0
	}
	return pid
}

// decodeList decodes the engine's JSON list output; empty output is none.
func decodeList(out []byte, v any) error {
	if len(bytes.TrimSpace(out)) == 0 {
		return nil
	}
	return json.Unmarshal(out, v)
}

// alive reports whether a process with this PID exists. EPERM means it
// does, owned by someone else.
func alive(pid int) bool {
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}
