package main

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/trevor-vaughan/claude-riotbox/internal/display"
	"github.com/trevor-vaughan/claude-riotbox/internal/egress/inject"
	"github.com/trevor-vaughan/claude-riotbox/internal/egress/pod"
	"github.com/trevor-vaughan/claude-riotbox/internal/egress/policy"
	"github.com/trevor-vaughan/claude-riotbox/internal/egress/state"
)

// egressConfOptions are the options of the verbs that compute a session's
// allowlist from the conf files.
var egressConfOptions = []string{"--engine", "--state-root", "--system-conf", "--user-conf"}

// sweepMaxAge is how long an unused egress state dir is kept, so its logs
// can be read after the session ends.
const sweepMaxAge = 7 * 24 * time.Hour

// maxUpInput caps what egress-up reads on stdin: the agent's hosts and
// variables are a few KiB, and the whole input is held in memory.
const maxUpInput = 1 << 20

// egressFailed reports a failure that ends an egress verb.
func egressFailed(stderr io.Writer, err error) int {
	_, _ = fmt.Fprintf(stderr, "riotbox-core: egress: %v\n", err)
	return 1
}

// egressUp starts a session's proxy and prints the agent's engine flags,
// one per line. Stdin holds the agent's hosts and, after a NUL, the
// variables the agent would get from the host (inject.ParseInput); the
// provider keys among them the proxy injects (inject.Decide), and the
// keys that still enter the container are named on stderr.
func egressUp(a parsedArgs, stdout, stderr io.Writer) int {
	pid, err := strconv.Atoi(a.opts["--owner-pid"])
	if err != nil || pid <= 0 {
		_, _ = fmt.Fprintf(stderr, "riotbox-core: egress-up: --owner-pid %s is not a process ID\n", display.Quote(a.opts["--owner-pid"]))
		return badUsage(stderr)
	}
	dir, err := state.Open(a.opts["--state-root"], a.args[0])
	if err != nil {
		return egressFailed(stderr, err)
	}
	input, err := io.ReadAll(io.LimitReader(os.Stdin, maxUpInput+1))
	if err != nil {
		return egressFailed(stderr, fmt.Errorf("reading stdin: %w", err))
	}
	if len(input) > maxUpInput {
		return egressFailed(stderr, errors.New("stdin holds more than 1 MiB of hosts and variables"))
	}
	hosts, vars, err := inject.ParseInput(input)
	if err != nil {
		return egressFailed(stderr, err)
	}
	plan := inject.Decide(vars, inject.Providers)
	if notice := plan.Notice(); notice != "" {
		_, _ = fmt.Fprintln(stderr, notice)
	}
	// The keys go only on a private tmpfs; with none to inject, a missing
	// one changes nothing (the base is then "", and only an earlier
	// release's secrets in the state dir are cleaned up).
	runtime, err := state.RuntimeBase(state.HostRuntime())
	if err != nil && len(plan.Inject) > 0 {
		return egressFailed(stderr, err)
	}
	dir = dir.WithRuntime(runtime)
	// The engine commands Up runs inherit this process's environment,
	// which holds the injected keys when launch.sh's does: drop them, so a
	// key reaches the proxy only through its secrets dir.
	for _, c := range plan.Inject {
		if err := os.Unsetenv(c.Env); err != nil {
			return egressFailed(stderr, err)
		}
	}
	flags, err := pod.NewManager(a.opts["--engine"], stderr).Up(pod.UpRequest{
		Dir:         dir,
		SessionKey:  a.opts["--session-key"],
		OwnerPID:    pid,
		Image:       a.opts["--image"],
		AgentHosts:  hosts,
		Projects:    a.multi["--project"],
		SystemConf:  a.opts["--system-conf"],
		UserConf:    a.opts["--user-conf"],
		Credentials: plan.Inject,
	})
	if err != nil {
		return egressFailed(stderr, err)
	}
	return printLines(flags, stdout, stderr)
}

// egressDown removes a session's proxy pod and reports denied requests.
func egressDown(a parsedArgs, _, stderr io.Writer) int {
	dir, err := state.Open(a.opts["--state-root"], a.args[0])
	if err != nil {
		return egressFailed(stderr, err)
	}
	// Every qualifying runtime base, not just the first: the launch may
	// have seen another $XDG_RUNTIME_DIR. With none, Down still removes
	// the state dir's secrets.
	runtimes := state.RuntimeBases(state.HostRuntime())
	if err := pod.NewManager(a.opts["--engine"], stderr).Down(dir, true, runtimes...); err != nil {
		return egressFailed(stderr, err)
	}
	return 0
}

// egressSweep removes orphaned egress pods, stale state dirs and idle
// sessions' secrets.
func egressSweep(a parsedArgs, _, stderr io.Writer) int {
	// As in egressDown: every qualifying runtime base.
	runtimes := state.RuntimeBases(state.HostRuntime())
	if err := pod.NewManager(a.opts["--engine"], stderr).Sweep(a.opts["--state-root"], runtimes, sweepMaxAge, time.Now()); err != nil {
		return egressFailed(stderr, err)
	}
	return 0
}

// egressList prints each running session with when it started, the
// launch that owns it, its project dirs, its log, its strict setting, the
// keys its proxy injects and the allowlist its proxy enforces. What the
// engine or an older session did not record is "unknown".
func egressList(a parsedArgs, stdout, stderr io.Writer) int {
	running, err := pod.NewManager(a.opts["--engine"], stderr).RunningSessions()
	if err != nil {
		return egressFailed(stderr, err)
	}
	if len(running) == 0 {
		_, err := fmt.Fprintln(stdout, "No egress sessions are running.")
		return written(err, stderr)
	}
	var b strings.Builder
	for _, s := range running {
		dir, err := state.Open(a.opts["--state-root"], s.Name)
		if err != nil {
			return egressFailed(stderr, err)
		}
		projects, projectsErr := dir.Projects()
		if projectsErr != nil {
			// One session's corrupt record must not hide the others.
			_, _ = fmt.Fprintf(stderr, "riotbox-core: egress: %s: %v\n", s.Name, projectsErr)
		}
		entries, err := dir.Applied()
		if err != nil {
			return egressFailed(stderr, err)
		}
		strict, err := dir.AppliedStrict()
		if err != nil {
			return egressFailed(stderr, err)
		}
		if !knownStrictLabel(strict) {
			strict = "unknown"
		}
		injected, injectedErr := dir.Injected()
		if injectedErr != nil {
			// One session's corrupt record must not hide the others.
			_, _ = fmt.Fprintf(stderr, "riotbox-core: egress: %s: %v\n", s.Name, injectedErr)
		}
		started, owner := "unknown", "unknown"
		if !s.Started.IsZero() {
			started = s.Started.Format("2006-01-02 15:04:05 MST")
		}
		if s.OwnerPID != 0 {
			owner = "PID " + strconv.Itoa(s.OwnerPID)
		}
		fmt.Fprintf(&b, "%s\n  started: %s\n  owner:   %s\n", s.Name, started, owner)
		switch {
		case projectsErr != nil:
			b.WriteString("  project: unreadable\n")
		case len(projects) == 0:
			b.WriteString("  project: unknown\n")
		}
		for _, p := range projects {
			fmt.Fprintf(&b, "  project: %s\n", display.Quote(p))
		}
		fmt.Fprintf(&b, "  log:     %s\n", display.Quote(dir.AccessLog()))
		fmt.Fprintf(&b, "  strict:  %s\n", strict)
		if injectedErr != nil {
			b.WriteString("  inject:  unreadable\n")
		}
		for _, x := range injected {
			fmt.Fprintf(&b, "  inject:  %s → %s\n", x.Env, x.Host)
		}
		for _, e := range entries {
			fmt.Fprintf(&b, "  allow:   %s\n", e)
		}
	}
	_, err = io.WriteString(stdout, b.String())
	return written(err, stderr)
}

// knownStrictLabel reports whether label is one policy.Resolved.StrictLabel
// writes. applied-strict sits in a state dir another process can write, so
// anything else (empty for an older session, garbage, terminal escapes) is
// shown as unknown rather than printed.
func knownStrictLabel(label string) bool {
	for _, from := range []string{policy.SourceSession, policy.SourceUser, policy.SourceSystem, policy.SourceDefault} {
		for _, on := range []bool{true, false} {
			if label == (policy.Resolved{Strict: on, StrictFrom: from}).StrictLabel() {
				return true
			}
		}
	}
	return false
}

// sessionOption returns the --session value, or ok false after reporting a
// usage error when it was given empty.
func sessionOption(a parsedArgs, verbName string, stderr io.Writer) (name string, ok bool) {
	name, given := a.opts["--session"]
	if given && name == "" {
		_, _ = fmt.Fprintf(stderr, "riotbox-core: %s: --session must not be empty\n", verbName)
		badUsage(stderr)
		return "", false
	}
	return name, true
}

// saveToOption returns the --save-to value and whether it was given, or
// ok false after reporting a usage error when it names neither conf file:
// only those are checked before anything changes, so a save elsewhere
// could write into a file the launch would refuse.
func saveToOption(a parsedArgs, verbName string, stderr io.Writer) (path string, save, ok bool) {
	path, save = a.opts["--save-to"]
	if !save {
		return "", false, true
	}
	clean := filepath.Clean(path)
	if clean != filepath.Clean(a.opts["--system-conf"]) && clean != filepath.Clean(a.opts["--user-conf"]) {
		_, _ = fmt.Fprintf(stderr, "riotbox-core: %s: --save-to must be the --system-conf or --user-conf file, not %s\n", verbName, display.Quote(path))
		badUsage(stderr)
		return "", false, false
	}
	return path, true, true
}

// egressEdit returns egress-allow's run (remove false) or egress-deny's
// (remove true): record the entry or @group in the session overlay (a
// group as its reference, re-resolved at every reload), apply it live,
// and with --save-to also record it in that conf file.
func egressEdit(verbName string, remove bool) func(a parsedArgs, stdout, stderr io.Writer) int {
	return func(a parsedArgs, stdout, stderr io.Writer) int {
		sessionName, ok := sessionOption(a, verbName, stderr)
		if !ok {
			return 2
		}
		saveTo, save, ok := saveToOption(a, verbName, stderr)
		if !ok {
			return 2
		}
		raw := a.args[0]
		if strings.HasPrefix(raw, "-") {
			return egressFailed(stderr, fmt.Errorf("give the entry without a leading -: %s", display.Quote(raw)))
		}
		named, err := policy.ParseItem(raw)
		if err != nil {
			return egressFailed(stderr, err)
		}
		it := named
		it.Remove = remove
		m := pod.NewManager(a.opts["--engine"], stderr)
		dir, err := m.Target(a.opts["--state-root"], sessionName)
		if err != nil {
			return egressFailed(stderr, err)
		}
		if it.Group != "" {
			dropped, err := forgetGroup(m, dir, it.Group, save, a.opts["--system-conf"], a.opts["--user-conf"], stderr)
			if !dropped && err != nil {
				return egressFailed(stderr, fmt.Errorf("%s was not applied: %w", named, err))
			}
			if dropped {
				if _, werr := fmt.Fprintf(stdout, "egress: %s: dropped @%s from the session (no group named @%s any more)\n", dir.Name(), it.Group, it.Group); werr != nil {
					return written(werr, stderr)
				}
				if err != nil {
					return egressFailed(stderr, fmt.Errorf("the session's allowlist was not applied: %w", err))
				}
				return 0
			}
		}
		r, err := applyChange(m, dir, named.String(), func(before policy.Resolved) error {
			if _, known := before.Groups[it.Group]; it.Group != "" && !known {
				return fmt.Errorf("no group named @%s (riotbox egress groups lists them)", it.Group)
			}
			return dir.SetOverlay(it)
		}, a.opts["--system-conf"], a.opts["--user-conf"], stderr)
		if err != nil {
			return egressFailed(stderr, err)
		}
		if save {
			if err := state.SaveItem(saveTo, it, stderr); err != nil {
				return egressFailed(stderr, fmt.Errorf("the session was changed, but saving to %s failed: %w", display.Quote(saveTo), err))
			}
		}
		done := "allowed"
		if remove {
			done = "denied"
			noteStillAllowed(r, it, stderr)
		}
		if _, err := fmt.Fprintf(stdout, "egress: %s: %s %s\n", dir.Name(), done, named); err != nil {
			return written(err, stderr)
		}
		if !save {
			return 0
		}
		_, err = fmt.Fprintf(stdout, "egress: saved %s to %s\n", it, display.Quote(saveTo))
		return written(err, stderr)
	}
}

// forgetGroup is the way out of a session.conf line naming a group no
// file defines any more, which fails every reload (state.Dir.Dangles): it
// drops the line and applies the rest, and reports whether it dropped one.
// It changes nothing when there is no such line, and, with save, fails:
// there is no group to save. A drop stays when applying the rest fails
// (another such line, a session that stopped): the line could never apply
// again, and the proxy keeps enforcing what it last applied.
func forgetGroup(m pod.Manager, dir state.Dir, group string, save bool, systemConf, userConf string, stderr io.Writer) (dropped bool, err error) {
	release, err := dir.Lock(stderr)
	if err != nil {
		return false, err
	}
	defer func() { err = errors.Join(err, release()) }()
	dangles, err := dir.Dangles(systemConf, userConf, group)
	if err != nil || !dangles {
		return false, err
	}
	if save {
		return false, fmt.Errorf("no group named @%s, so it cannot be saved; nothing was changed (run it without --save to drop @%s from the session)", group, group)
	}
	if err := dir.DropOverlayGroup(group); err != nil {
		return false, err
	}
	if _, err := dir.Reload(systemConf, userConf); err != nil {
		return true, err
	}
	return true, checkRunning(m, dir)
}

// noteStillAllowed says on stderr which wildcard still allows each host a
// deny named: the entry, or each member of the group. The overlay applies
// last and in order, so nothing else can keep a denied host allowed.
func noteStillAllowed(r policy.Resolved, it policy.Item, stderr io.Writer) {
	denied := []policy.Entry{it.Entry}
	if it.Group != "" {
		denied = r.Groups[it.Group].Members
	}
	for _, e := range denied {
		for _, w := range policy.Covering(r.Entries, e) {
			_, _ = fmt.Fprintf(stderr, "egress: note: %s is still allowed by %s\n", e, w)
		}
	}
}

// applyChange makes change to dir's overlay and reloads the session, under
// its lock, and returns the policy now applied. change gets the policy as
// it was, to check the change against; it must leave the overlay as it
// found it when it fails. what names the change in errors. When the reload
// fails the overlay is put back as it was, so a rejected change does not
// linger in the next reload.
func applyChange(m pod.Manager, dir state.Dir, what string, change func(before policy.Resolved) error, systemConf, userConf string, stderr io.Writer) (r policy.Resolved, err error) {
	release, err := dir.Lock(stderr)
	if err != nil {
		return policy.Resolved{}, err
	}
	defer func() { err = errors.Join(err, release()) }()
	saved, readErr := os.ReadFile(dir.SessionConf())
	existed := readErr == nil
	if readErr != nil && !errors.Is(readErr, fs.ErrNotExist) {
		return policy.Resolved{}, readErr
	}
	// Reject unreadable conf files before changing anything: nothing is
	// then written that would need undoing.
	before, err := dir.Policy(systemConf, userConf)
	if err != nil {
		return policy.Resolved{}, fmt.Errorf("%s was not applied: %w", what, err)
	}
	if err := change(before); err != nil {
		return policy.Resolved{}, fmt.Errorf("%s was not applied: %w", what, err)
	}
	r, err = dir.Reload(systemConf, userConf)
	if err == nil {
		err = checkRunning(m, dir)
	}
	if err == nil {
		return r, nil
	}
	// Reload may have written rds.json before it or the check failed, and a
	// proxy that watches rds.json may be enforcing the change: put the
	// overlay back and reload it away.
	var restoreErr error
	if existed {
		restoreErr = state.WriteAtomic(dir.SessionConf(), saved)
	} else {
		restoreErr = os.Remove(dir.SessionConf())
	}
	if restoreErr != nil {
		return policy.Resolved{}, errors.Join(err, fmt.Errorf("%s may still be enforced: restoring the overlay failed: %w", what, restoreErr))
	}
	if _, undoErr := dir.Reload(systemConf, userConf); undoErr != nil {
		return policy.Resolved{}, errors.Join(fmt.Errorf("%s was not applied: %w", what, err), fmt.Errorf("the session's proxy may still enforce %s: %w", what, undoErr))
	}
	return policy.Resolved{}, fmt.Errorf("%s was not applied: %w", what, err)
}

// checkRunning fails unless dir's session is still running: it may have
// stopped while the command waited for the lock, and a reload of a dead
// session would be reported as applied. The caller holds the lock.
func checkRunning(m pod.Manager, dir state.Dir) error {
	running, err := m.Running()
	if err != nil {
		return fmt.Errorf("could not check that %s is still running: %w", display.Quote(dir.Name()), err)
	}
	if !slices.Contains(running, dir.Name()) {
		return fmt.Errorf("no egress session named %s is running", display.Quote(dir.Name()))
	}
	return nil
}

// egressReload re-reads the conf files into the named session, or into
// every running one.
func egressReload(a parsedArgs, stdout, stderr io.Writer) int {
	name, ok := sessionOption(a, "egress-reload", stderr)
	if !ok {
		return 2
	}
	m := pod.NewManager(a.opts["--engine"], stderr)
	var dirs []state.Dir
	if _, named := a.opts["--session"]; named {
		dir, err := m.Target(a.opts["--state-root"], name)
		if err != nil {
			return egressFailed(stderr, err)
		}
		dirs = append(dirs, dir)
	} else {
		running, err := m.Running()
		if err != nil {
			return egressFailed(stderr, err)
		}
		for _, name := range running {
			dir, err := state.Open(a.opts["--state-root"], name)
			if err != nil {
				return egressFailed(stderr, err)
			}
			dirs = append(dirs, dir)
		}
	}
	if len(dirs) == 0 {
		_, err := fmt.Fprintln(stdout, "No egress sessions are running.")
		return written(err, stderr)
	}
	status := 0
	for _, dir := range dirs {
		r, err := reloadLocked(m, dir, a.opts["--system-conf"], a.opts["--user-conf"], stderr)
		if err != nil {
			status = egressFailed(stderr, fmt.Errorf("%s: %w", dir.Name(), err))
			continue
		}
		if _, err := fmt.Fprintf(stdout, "egress: %s: reloaded, %d allowed\n", dir.Name(), len(r.Entries)); err != nil {
			return written(err, stderr)
		}
	}
	return status
}

// reloadLocked reloads dir under the session's lock.
func reloadLocked(m pod.Manager, dir state.Dir, systemConf, userConf string, stderr io.Writer) (r policy.Resolved, err error) {
	release, err := dir.Lock(stderr)
	if err != nil {
		return policy.Resolved{}, err
	}
	defer func() { err = errors.Join(err, release()) }()
	r, err = dir.Reload(systemConf, userConf)
	if err != nil {
		return policy.Resolved{}, err
	}
	return r, checkRunning(m, dir)
}

// egressStrict sets ("on", "off") or clears ("clear") the strict setting
// of a running session's overlay, live; with --save-to it also sets or
// removes the setting in that conf file. It warns when the session is left
// strict without the agent's own hosts. Open tunnels are not cut, as with
// deny.
func egressStrict(a parsedArgs, stdout, stderr io.Writer) int {
	sessionName, ok := sessionOption(a, "egress-strict", stderr)
	if !ok {
		return 2
	}
	saveTo, save, ok := saveToOption(a, "egress-strict", stderr)
	if !ok {
		return 2
	}
	var setting policy.StrictSetting
	switch a.args[0] {
	case "on":
		setting = policy.StrictOn
	case "off":
		setting = policy.StrictOff
	case "clear":
		setting = policy.StrictUnset
	default:
		_, _ = fmt.Fprintf(stderr, "riotbox-core: egress-strict: %s is not on, off or clear\n", display.Quote(a.args[0]))
		return badUsage(stderr)
	}
	m := pod.NewManager(a.opts["--engine"], stderr)
	dir, err := m.Target(a.opts["--state-root"], sessionName)
	if err != nil {
		return egressFailed(stderr, err)
	}
	r, err := applyChange(m, dir, "strict "+a.args[0], func(policy.Resolved) error { return dir.SetOverlayStrict(setting) },
		a.opts["--system-conf"], a.opts["--user-conf"], stderr)
	if err != nil {
		return egressFailed(stderr, err)
	}
	if w := r.LockoutWarning(); w != "" {
		_, _ = fmt.Fprintln(stderr, w)
	}
	changed := false
	if save {
		if changed, err = state.SaveStrict(saveTo, setting, stderr); err != nil {
			return egressFailed(stderr, fmt.Errorf("the session was changed, but saving to %s failed: %w", display.Quote(saveTo), err))
		}
	}
	if _, err := fmt.Fprintf(stdout, "egress: %s: strict %s\n", dir.Name(), r.StrictLabel()); err != nil {
		return written(err, stderr)
	}
	if !save {
		return 0
	}
	switch {
	case setting != policy.StrictUnset:
		_, err = fmt.Fprintf(stdout, "egress: saved %s to %s\n", setting, display.Quote(saveTo))
	case changed:
		_, err = fmt.Fprintf(stdout, "egress: removed the strict setting from %s\n", display.Quote(saveTo))
	default:
		_, err = fmt.Fprintf(stdout, "egress: %s has no strict setting\n", display.Quote(saveTo))
	}
	return written(err, stderr)
}

// egressGroups prints the group table the conf files make: each group,
// sorted by name, with where its definition comes from and its hosts.
// @agent differs per session, so it is listed once per running session
// with that session's agent hosts, or as "(per session)" when none runs; a
// session whose agent.conf cannot be read shows "(unreadable)" and the
// reason goes to stderr. It fails on a conf file the launch would refuse.
func egressGroups(a parsedArgs, stdout, stderr io.Writer) int {
	var s policy.Sources
	var err error
	if s.System, err = state.ReadConf(a.opts["--system-conf"]); err != nil {
		return egressFailed(stderr, err)
	}
	if s.User, err = state.ReadConf(a.opts["--user-conf"]); err != nil {
		return egressFailed(stderr, err)
	}
	r, err := policy.Resolve(s)
	if err != nil {
		return egressFailed(stderr, err)
	}
	running, err := pod.NewManager(a.opts["--engine"], stderr).Running()
	if err != nil {
		return egressFailed(stderr, err)
	}
	var b strings.Builder
	for _, name := range slices.Sorted(maps.Keys(r.Groups)) {
		if name != policy.AgentGroup {
			g := r.Groups[name]
			fmt.Fprintf(&b, "@%s (%s)\n", name, g.Source)
			for _, e := range g.Members {
				fmt.Fprintf(&b, "  %s\n", e)
			}
			continue
		}
		if len(running) == 0 {
			b.WriteString("@agent (per session)\n")
		}
		for _, session := range running {
			dir, err := state.Open(a.opts["--state-root"], session)
			if err != nil {
				return egressFailed(stderr, err)
			}
			fmt.Fprintf(&b, "@agent (%s)\n", session)
			hosts, err := dir.AgentHosts()
			if err != nil {
				// One session's unreadable record must not hide the others.
				var pathErr *fs.PathError
				if errors.As(err, &pathErr) {
					err = pathErr.Err
				}
				_, _ = fmt.Fprintf(stderr, "riotbox-core: egress: %s: cannot read %s: %v\n", session, display.Quote(dir.AgentConf()), err)
				b.WriteString("  (unreadable)\n")
				continue
			}
			for _, e := range policy.Groups(hosts, s.System, s.User)[policy.AgentGroup].Members {
				fmt.Fprintf(&b, "  %s\n", e)
			}
		}
	}
	_, err = io.WriteString(stdout, b.String())
	return written(err, stderr)
}
