// Package engine asks the container engine (podman or docker, the
// CONTAINER_CMD executable) which live containers have which host paths
// mounted read-write. Host commands that change session data a container can
// also write use it to refuse while one can, and to refuse when the engine
// cannot answer. It ports scripts/lib/running-sessions.sh and the bash
// running check the session moves made (RefuseIfRunning).
//
// Every container that is created, running or paused is inspected, not only
// those launch.sh labels riotbox.session: releases up to v0.5.3 set no
// label, and a session one of them started is still running during the
// upgrade. Which ones are labelled is kept, because an unlabelled
// container's mounts are trusted less (Reaches).
package engine

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"regexp"
	"strings"

	"github.com/trevor-vaughan/claude-riotbox/internal/display"
	"github.com/trevor-vaughan/claude-riotbox/internal/realpath"
	"github.com/trevor-vaughan/claude-riotbox/internal/records"
)

// inspectFormat prints one record per mount: container ID, name, source and
// read-write flag, each NUL-terminated. These field names exist in both
// podman's and docker's container inspect output; NUL, because a path may
// hold anything.
const inspectFormat = `{{$c := .ID}}{{$n := .Name}}{{range .Mounts}}{{$c}}{{"\x00"}}{{$n}}{{"\x00"}}{{.Source}}{{"\x00"}}{{.RW}}{{"\x00"}}{{end}}`

// liveStates are the status filters of both listings. Both engines OR the
// values of a repeated status filter, AND it with a label filter, and list
// non-running containers once a status filter is given (-a says so
// explicitly). These three are the states both accept; docker's
// "restarting" is rejected by podman, and RiotBox runs every container with
// --rm and no restart policy. A container `run` has created but not yet
// started already has its mounts, and a paused one keeps them.
var liveStates = []string{"--filter", "status=created", "--filter", "status=running", "--filter", "status=paused"}

// gone matches the engine's message for a container that exited after `ps`
// listed it: podman says "no such object" (exit 125), docker "No such
// object" or "No such container".
var gone = regexp.MustCompile(`(?i)no such (object|container)`)

var (
	// ErrMalformed is returned when inspect output is not whole records.
	ErrMalformed = errors.New("malformed container inspect output")
	// ErrNoAnswer is returned by RefuseIfRunning when the engine cannot
	// list or inspect the containers.
	ErrNoAnswer = errors.New("the container engine could not answer")
	// ErrRunning is returned by RefuseIfRunning when a live container can
	// write the session.
	ErrRunning = errors.New("a live container can write the session")
)

// Mount is one read-write host mount of a live container.
type Mount struct {
	ID   string // the container's full ID
	Name string // its name, without docker's leading /
	// Source is the mount source as realpath -m prints it.
	Source string
	// Lexical is the source as realpath -ms prints it, links left alone:
	// the container keeps the dir it was given even when a component of
	// its path is later swapped for a link, which changes Source.
	Lexical  string
	Labelled bool // it has the riotbox.session label
}

// Label is how messages name the container of m: its name, else the first
// 12 characters of its ID.
func (m Mount) Label() string {
	if m.Name != "" {
		return m.Name
	}
	id := []rune(m.ID)
	if len(id) > 12 {
		id = id[:12]
	}
	return string(id)
}

// Scan returns the read-write host mounts of every live container, asking
// the engine executable (a name looked up on PATH, or a path). All
// containers are inspected in one call; when that fails (one exited since
// the listing, say), each is inspected on its own, and one whose inspection
// says it no longer exists is skipped. A tmpfs (empty source) is skipped:
// nothing on the host.
//
// It returns an error, failing closed, when the engine cannot list the
// containers, when an inspection fails any other way (its stderr is then
// copied to stderr), or when the output is malformed (which it says on
// stderr). The listing's own
// stderr goes to stderr as the engine prints it.
func Scan(engine string, stderr io.Writer) ([]Mount, error) {
	ids, err := list(engine, stderr)
	if err != nil || len(ids) == 0 {
		return nil, err
	}
	labelledIDs, err := list(engine, stderr, "--filter", "label=riotbox.session")
	if err != nil {
		return nil, err
	}
	mounts, _, err := inspect(engine, ids, stderr)
	if err != nil {
		mounts = nil
		for _, id := range ids {
			one, errText, err := inspect(engine, []string{id}, stderr)
			if err == nil {
				mounts = append(mounts, one...)
				continue
			}
			if gone.Match(errText) {
				continue
			}
			_, _ = stderr.Write(errText)
			return nil, err
		}
	}
	labelled := map[string]bool{}
	for _, id := range labelledIDs {
		labelled[id] = true
	}
	for i := range mounts {
		mounts[i].Labelled = labelled[mounts[i].ID]
	}
	return mounts, nil
}

// list returns the full IDs of the live containers matching the filters,
// with the engine's stderr passed to stderr.
func list(engine string, stderr io.Writer, filters ...string) ([]string, error) {
	args := append([]string{"ps", "-a", "--no-trunc"}, filters...)
	args = append(args, liveStates...)
	args = append(args, "--format", "{{.ID}}")
	var out bytes.Buffer
	cmd := exec.Command(engine, args...)
	cmd.Stdout = &out
	cmd.Stderr = stderr
	if err := cmd.Run(); err != nil {
		reportStartFailure(err, stderr)
		return nil, err
	}
	// The bash read it through a command substitution, which drops NULs,
	// and skipped empty lines.
	var ids []string
	for _, id := range strings.Split(strings.ReplaceAll(out.String(), "\x00", ""), "\n") {
		if id != "" {
			ids = append(ids, id)
		}
	}
	return ids, nil
}

// reportStartFailure prints why the engine could not be run at all (missing,
// not executable), where bash printed its own "command not found". An engine
// that ran and exited non-zero has already said why.
func reportStartFailure(err error, stderr io.Writer) {
	var exit *exec.ExitError
	if !errors.As(err, &exit) {
		_, _ = fmt.Fprintf(stderr, "riotbox-core: %v\n", err)
	}
}

// inspect returns the read-write host mounts of the containers ids, and the
// engine's stderr, to which it adds the reason when the output is
// malformed. It returns no mounts and an error when the engine fails or its
// output is malformed.
func inspect(engine string, ids []string, stderr io.Writer) ([]Mount, []byte, error) {
	var out, errOut bytes.Buffer
	cmd := exec.Command(engine, append([]string{"container", "inspect", "--format", inspectFormat}, ids...)...)
	cmd.Stdout = &out
	cmd.Stderr = &errOut
	if err := cmd.Run(); err != nil {
		var exit *exec.ExitError
		if !errors.As(err, &exit) {
			_, _ = fmt.Fprintf(&errOut, "riotbox-core: %v\n", err)
		}
		return nil, errOut.Bytes(), err
	}
	mounts, err := parse(out.String(), stderr)
	if errors.Is(err, ErrMalformed) {
		// With the engine's own stderr, so it is printed only when no
		// fallback inspection succeeds.
		_, _ = fmt.Fprintf(&errOut, "riotbox-core: %v\n", err)
	}
	return mounts, errOut.Bytes(), err
}

// parse reads inspect output as the bash did with `mapfile -d ”`: fields
// end at each NUL, and text after the last NUL is one more field. The engine
// ends each container's output with a newline, so a record's ID starts with
// the newlines of the containers before it, and the output ends with a
// field of newlines only, which is dropped (an empty last field too, as the
// bash's test of it does). The field count must then be a multiple of
// four, and every ID non-empty once its leading newlines are stripped.
func parse(output string, stderr io.Writer) ([]Mount, error) {
	fields := strings.Split(output, "\x00")
	if fields[len(fields)-1] == "" {
		fields = fields[:len(fields)-1]
	}
	if len(fields) > 0 && strings.Trim(fields[len(fields)-1], "\n") == "" {
		fields = fields[:len(fields)-1]
	}
	if len(fields)%4 != 0 {
		return nil, ErrMalformed
	}
	var mounts []Mount
	for i := 0; i < len(fields); i += 4 {
		id := strings.TrimLeft(fields[i], "\n")
		if id == "" {
			return nil, ErrMalformed
		}
		source, rw := fields[i+2], fields[i+3]
		if source == "" || rw != "true" {
			continue
		}
		resolved, err := realpath.Canonical(source)
		if err != nil {
			_, _ = fmt.Fprintln(stderr, err)
			return nil, err
		}
		lexical, err := realpath.Lexical(source)
		if err != nil {
			_, _ = fmt.Fprintln(stderr, err)
			return nil, err
		}
		mounts = append(mounts, Mount{
			ID:      id,
			Name:    strings.TrimPrefix(fields[i+1], "/"),
			Source:  resolved,
			Lexical: lexical,
		})
	}
	return mounts, nil
}

// Reaches reports whether m can write to a path, given as realpath -m
// (resolved) and realpath -ms (lexical) print it; either form matching the
// mount's own form of it is enough. For a container with the
// riotbox.session label, when they overlap either way (Overlaps): a RiotBox
// session mounting an ancestor (a project that contains the data dir)
// writes there too. For an unlabelled one, only when its source is the path
// or inside it: v0.5.3 mounted nothing above a session, while toolbox and
// distrobox keep containers running with / mounted read-write, which would
// otherwise block every session command. Use it for refusals; use Overlaps
// for warnings.
func Reaches(m Mount, resolved, lexical string) bool {
	if m.Labelled {
		return Overlaps(m, resolved, lexical)
	}
	return within(m.Source, resolved) || within(m.Lexical, lexical)
}

// Overlaps reports whether m and the path (as for Reaches) overlap either
// way, whatever the container's label.
func Overlaps(m Mount, resolved, lexical string) bool {
	return pathsOverlap(m.Source, resolved) || pathsOverlap(m.Lexical, lexical)
}

// pathsOverlap reports whether two canonical paths are equal or one
// contains the other.
func pathsOverlap(a, b string) bool {
	return within(a, b) || within(b, a)
}

// within reports whether path is dir or inside it, comparing them as the
// bash did: one trailing slash dropped from each, then a slash added.
func within(path, dir string) bool {
	return strings.HasPrefix(strings.TrimSuffix(path, "/")+"/", strings.TrimSuffix(dir, "/")+"/")
}

// RefuseIfRunning returns an error, saying why on w, unless the engine
// confirms that no live container has a read-write mount that reaches the
// session dir or the state dir (Reaches). A retry moves the legacy dir and
// may replace the new one, so a running session would keep writing into a
// dir that is no longer where RiotBox looks, and those writes would be lost.
// Fails closed: an engine that cannot answer is a refusal (ErrNoAnswer). A
// container that can write is ErrRunning. mover names what refuses (default
// session-migrate) and retry what to do once the session has exited
// (default: run riotbox session-migrate again). The session is named by the
// launch's project record, shell-quoted, else by sessionDir. A container
// can shape the path a mount source resolves to (through links in a dir it
// writes), so each is printed cleaned (display.CleanName, with the jq
// library in libDir).
func RefuseIfRunning(w io.Writer, engine, libDir, sessionDir, stateDir, mover, retry string) error {
	if mover == "" {
		mover = "session-migrate"
	}
	if retry == "" {
		retry = "run riotbox session-migrate again"
	}
	label := sessionDir
	projects, err := records.Recorded(stateDir)
	switch {
	case err != nil:
		// As the riotbox-core recorded-projects call the bash made said it.
		_, _ = fmt.Fprintf(w, "riotbox-core: %v\n", err)
	case len(projects) > 0:
		label = display.QuoteWords(projects...)
	}
	paths, err := resolveAll(w, sessionDir, stateDir)
	if err != nil {
		return err
	}
	session, state, sessionLexical, stateLexical := paths[0], paths[1], paths[2], paths[3]
	mounts, err := Scan(engine, w)
	if err != nil {
		_, _ = fmt.Fprintf(w, "ERROR: could not ask '%s' whether a running container mounts the session of %s.\n", engine, label)
		_, _ = fmt.Fprintf(w, "       %s refuses while it cannot tell: a running session can still write to what it would move.\n", mover)
		_, _ = fmt.Fprintln(w, "       Make sure the container engine works (and that the session has exited), then retry.")
		return ErrNoAnswer
	}
	var holders []Mount
	held := map[string]bool{}
	for _, m := range mounts {
		if (Reaches(m, session, sessionLexical) || Reaches(m, state, stateLexical)) && !held[m.ID] {
			held[m.ID] = true
			holders = append(holders, m)
		}
	}
	if len(holders) == 0 {
		return nil
	}
	for _, m := range holders {
		_, _ = fmt.Fprintf(w, "ERROR: container %s mounts %s read-write, which reaches the session of %s, and is still running.\n", m.Label(), display.CleanName(w, libDir, m.Source), label)
	}
	_, _ = fmt.Fprintf(w, "       It can still write to what %s would move. Stop that container (exit its session), then %s.\n", mover, retry)
	return ErrRunning
}

// OverlayUsers classifies the read-write mounts of every live container
// against one overlay dir and its project dir:
//   - holders: the labels of containers with a mount reaching overlayDir
//     (Reaches), each once: they run on this overlay, and block accept and
//     reject;
//   - sharers: "<label> <source>" for every other mount overlapping
//     projectDir either way (Overlaps): other sessions on the project, or a
//     toolbox with $HOME mounted, which can change the project during an
//     apply; they only warn. The source is cleaned for display
//     (display.CleanName, with the jq library in libDir), as a container
//     can shape the path it resolves to.
//
// It returns an error, failing closed, when the engine cannot answer (Scan).
func OverlayUsers(engine, libDir, overlayDir, projectDir string, stderr io.Writer) (holders, sharers []string, err error) {
	paths, err := resolveAll(stderr, overlayDir, projectDir)
	if err != nil {
		return nil, nil, err
	}
	overlay, project, overlayLexical, projectLexical := paths[0], paths[1], paths[2], paths[3]
	mounts, err := Scan(engine, stderr)
	if err != nil {
		return nil, nil, err
	}
	held := map[string]bool{}
	for _, m := range mounts {
		switch {
		case Reaches(m, overlay, overlayLexical):
			if !held[m.ID] {
				held[m.ID] = true
				holders = append(holders, m.Label())
			}
		case Overlaps(m, project, projectLexical):
			sharers = append(sharers, m.Label()+" "+display.CleanName(stderr, libDir, m.Source))
		}
	}
	return holders, sharers, nil
}

// resolveAll returns realpath -m of a and b, then realpath -ms of a and b,
// in the order the bash ran them, printing realpath's error on w and
// stopping at the first failure.
func resolveAll(w io.Writer, a, b string) ([]string, error) {
	var paths []string
	for _, step := range []struct {
		resolve func(string) (string, error)
		path    string
	}{{realpath.Canonical, a}, {realpath.Canonical, b}, {realpath.Lexical, a}, {realpath.Lexical, b}} {
		p, err := step.resolve(step.path)
		if err != nil {
			_, _ = fmt.Fprintln(w, err)
			return nil, err
		}
		paths = append(paths, p)
	}
	return paths, nil
}
