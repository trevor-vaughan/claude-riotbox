// Package migrate ports the one-time moves of what an older RiotBox left
// behind: a session from the key an older release gave it to its set's own
// key (SessionKey, migrate_session_key in scripts/mount-projects.sh); state
// an older RiotBox kept inside a session dir into the session's state dir
// (migrate_session_state and migrate_failed_state in
// scripts/lib/session-state.sh); and the once-per-session notice about
// headroom memory an older RiotBox left in the project
// (notice_project_headroom).
//
// The session dir is the container's read-write ~/.claude, so anything in
// it may have been planted by a running container. Migration moves it into
// the state dir as trusted data, which is why each pair runs automatically
// only once: <state-dir>/.migrated records it, and the state dir's top level
// is never mounted into a container.
//
// Marker format, one line per record, appended in order:
//
//	<name>          the pair ran; never run automatically again
//	failed:<name>   it left legacy data stranded (a failed move, or both
//	                copies exist); written after a <name> line
//	project-headroom-notice
//	                HeadroomNotice has checked (no pair has this name)
//
// A pair is failed while its last line is failed:<name>; a later <name>
// line makes it done. Every stranded pair also gets a plain line, so a reader
// that knows only plain names never retries it either.
//
// Every message goes to the io.Writer the caller passes (stderr in
// production), worded byte for byte as the bash printed it. Every error a
// function returns has already been written there.
package migrate

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"strings"
	"syscall"

	"github.com/trevor-vaughan/claude-riotbox/internal/display"
	"github.com/trevor-vaughan/claude-riotbox/internal/engine"
	"github.com/trevor-vaughan/claude-riotbox/internal/lock"
)

// waitMsg is what _with_migrate_lock printed for a session's state dir.
const waitMsg = "Waiting for another RiotBox command on this session to finish migrating its state…"

// errStranded is FailedState's result when a retried pair is still
// stranded; its warnings have been written.
var errStranded = errors.New("legacy session data is still stranded")

// entry is one pair: <session-dir>/<legacy> becomes <state-dir>/<new>. The
// overlay pair also cleans what is directly under the moved tree.
type entry struct {
	legacy, new string
	overlay     bool
}

// entries is everything an older RiotBox kept in the session dir, in the
// order the pass moves it (the bash SESSION_STATE_MIGRATIONS). To add a migration,
// append its pair: sessions that already have a marker run only the new
// pair, once, at their first launch after the upgrade.
var entries = []entry{
	{legacy: "headroom", new: "headroom"},
	{legacy: "git-ai", new: "git-ai"},
	{legacy: ".config-opencode", new: "opencode-config"},
	{legacy: ".local-share-opencode", new: "opencode-data"},
	{legacy: ".pi-agent", new: "pi-agent"},
	{legacy: "overlay", new: "overlay", overlay: true},
}

// SessionState runs each pair <stateDir>/.migrated does not list yet, and
// records it after it returns: <name> when it moved or there was nothing to
// move, <name> then failed:<name> when it left legacy data stranded. A pair
// that fails hard (an entry that must go and cannot be removed) is not
// recorded, and SessionState returns the error, so the next call retries it.
//
// Then, for each pair already failed before this call: while its legacy path
// is a real directory that holds anything, it prints one notice naming it
// and the riotbox session-migrate command; once it is gone, empty or not a
// real directory, it records the pair done, quietly. Nothing here retries a
// failed pair.
//
// The pass holds the session's migrate lock (<stateDir>/.migrate.lock).
// When <stateDir> is not a directory and the session dir holds no legacy
// entry, it returns nil without creating it; otherwise it creates <stateDir>
// and its parent, mode 0700, to hold the lock. <stateDir> may be a link the
// user made to another disk.
func SessionState(w io.Writer, libDir, sessionDir, stateDir string) error {
	return sessionState(w, libDir, sessionDir, stateDir, entries)
}

func sessionState(w io.Writer, libDir, sessionDir, stateDir string, list []entry) error {
	if info, err := os.Stat(stateDir); err != nil || !info.IsDir() {
		found := false
		for _, e := range list {
			if _, err := os.Lstat(sessionDir + "/" + e.legacy); err == nil {
				found = true
				break
			}
		}
		if !found {
			return nil
		}
		if errs := prepare(stateDir); len(errs) > 0 {
			for _, err := range errs {
				report(w, err)
			}
			return errs[0]
		}
	}
	return withLock(w, stateDir, waitMsg, func() error {
		return sessionLocked(w, libDir, sessionDir, stateDir, list)
	})
}

func sessionLocked(w io.Writer, libDir, sessionDir, stateDir string, list []entry) error {
	recorded, failed := readMarker(w, stateDir)
	for _, e := range list {
		if recorded[e.legacy] {
			continue
		}
		stranded, err := run(w, libDir, sessionDir, stateDir, false, e)
		if err != nil {
			return err
		}
		lines := []string{e.legacy}
		if stranded {
			lines = append(lines, "failed:"+e.legacy)
		}
		if err := record(w, stateDir, lines...); err != nil {
			return err
		}
	}
	// Only pairs failed before this pass: one stranded now has just warned.
	for _, e := range list {
		if !failed[e.legacy] {
			continue
		}
		legacy := sessionDir + "/" + e.legacy
		newPath := stateDir + "/" + e.new
		switch {
		case !dirHasData(legacy):
			if err := record(w, stateDir, e.legacy); err != nil {
				return err
			}
		case present(newPath) && !isEmptyRealDir(newPath):
			_, _ = fmt.Fprintf(w, "Notice: two copies of legacy session data need resolving, %s and %s; run %s to see how.\n",
				legacy, newPath, migrateHint(w, stateDir))
		default:
			_, _ = fmt.Fprintf(w, "Notice: legacy data is still at %s; once the cause is fixed, run %s.\n",
				legacy, migrateHint(w, stateDir))
		}
	}
	return nil
}

// FailedState is riotbox session-migrate: it retries each pair the marker
// records as failed, and only those, under the same lock as SessionState.
// Only the user runs it, never a launch, so a container cannot keep an import
// window open by forcing failures. A failed pair whose legacy path holds
// nothing is recorded done without a retry. Before the first retry it
// refuses, failing closed, while engine cannot confirm that no live container
// can write the session (engine.RefuseIfRunning). The retry may move over an
// empty real new dir: the launch that left the pair stranded went on to
// create it, and an empty one holds nothing to lose. A success is recorded
// done; a stranded result stays failed, with how to resolve two copies when
// the new one exists, and FailedState returns an error.
//
// It prints "Nothing to migrate." on stdout when no pair needed a retry.
func FailedState(stdout, w io.Writer, eng, libDir, sessionDir, stateDir string) error {
	if info, err := os.Stat(stateDir + "/.migrated"); err != nil || !info.Mode().IsRegular() {
		_, _ = fmt.Fprintln(stdout, "Nothing to migrate.")
		return nil
	}
	return withLock(w, stateDir, waitMsg, func() error {
		return failedLocked(stdout, w, eng, libDir, sessionDir, stateDir)
	})
}

func failedLocked(stdout, w io.Writer, eng, libDir, sessionDir, stateDir string) error {
	_, failed := readMarker(w, stateDir)
	pending, strandedAny := false, false
	for _, e := range entries {
		if !failed[e.legacy] {
			continue
		}
		legacy := sessionDir + "/" + e.legacy
		if !dirHasData(legacy) {
			if err := record(w, stateDir, e.legacy); err != nil {
				return err
			}
			continue
		}
		if !pending {
			// This narrows the race with a launch but does not close it: a
			// launch holds the lock only inside SessionState, so one already
			// past it whose container is not created yet is not seen.
			if err := engine.RefuseIfRunning(w, eng, libDir, sessionDir, stateDir, "", ""); err != nil {
				return err
			}
		}
		pending = true
		stranded, err := run(w, libDir, sessionDir, stateDir, true, e)
		if err != nil {
			return err
		}
		if !stranded {
			if err := record(w, stateDir, e.legacy); err != nil {
				return err
			}
			continue
		}
		strandedAny = true
		newPath := stateDir + "/" + e.new
		if present(newPath) {
			_, _ = fmt.Fprintln(w, "         RiotBox cannot merge the two copies. Exit every session of this project, then compare them:")
			_, _ = fmt.Fprintf(w, "           diff -rq %s %s\n", display.Quote(legacy), display.Quote(newPath))
			_, _ = fmt.Fprintf(w, "         Keep what you need, then delete one side (deleting %s keeps %s; delete or move aside %s to use %s instead) and run riotbox session-migrate again.\n",
				legacy, newPath, newPath, legacy)
			_, _ = fmt.Fprintln(w, `         See README.md, "Upgrading from a release that kept state in the session directory", for how to read the diff.`)
		}
	}
	if !pending {
		_, _ = fmt.Fprintln(stdout, "Nothing to migrate.")
	}
	if strandedAny {
		return errStranded
	}
	return nil
}

// run moves one pair, the overlay pair with its cleanup.
func run(w io.Writer, libDir, sessionDir, stateDir string, replaceEmpty bool, e entry) (bool, error) {
	if e.overlay {
		return moveOverlay(w, libDir, sessionDir, stateDir, replaceEmpty)
	}
	return moveLegacy(w, sessionDir, stateDir, replaceEmpty, e)
}

// moveLegacy moves <sessionDir>/<legacy> to <stateDir>/<new>:
//
//	legacy absent                    nothing
//	legacy a link or not a dir       removed without being followed; warning
//	legacy a dir, new absent         moved; one notice
//	legacy a dir, new an empty real  with replaceEmpty only (the user's retry):
//	  dir                            moved over it, as when new is absent
//	legacy a dir, new present        both left untouched; warning naming both.
//	                                 Never merged. Stranded.
//	the move fails                   warning naming riotbox session-migrate and
//	                                 the command that finishes the move by
//	                                 hand; legacy left in place. Stranded.
//	moved entry is no longer a dir   (the container swapped it for a link after
//	                                 the check; rename moves the link itself)
//	                                 removed from <new>; warning
//
// It creates <stateDir> and its parent (mode 0700) only when a real legacy
// dir is about to move. It reports whether the pair was left stranded, and
// returns an error, failing closed, when an entry that must go cannot be
// removed.
//
// The move runs mv -T, as the bash did: mv copies across filesystems (a state
// dir the user linked to another disk), where rename(2) fails with EXDEV, and
// with -T it replaces <new> only if that is an empty directory, failing
// otherwise instead of moving the legacy dir into it.
func moveLegacy(w io.Writer, sessionDir, stateDir string, replaceEmpty bool, e entry) (bool, error) {
	legacy := sessionDir + "/" + e.legacy
	newPath := stateDir + "/" + e.new
	info, err := os.Lstat(legacy)
	if err != nil {
		return false, nil
	}
	if !info.IsDir() {
		_, _ = fmt.Fprintf(w, "Warning: %s is not a real directory; removed it without following it.\n", legacy)
		return false, unlink(w, legacy)
	}
	// A launch that left a pair stranded goes on to create <new>, so the
	// retry finds it, usually still empty. rename(2) replaces an empty
	// directory atomically, and fails (ENOTEMPTY) if it filled since.
	if present(newPath) && (!replaceEmpty || !isEmptyRealDir(newPath)) {
		_, _ = fmt.Fprintf(w, "Warning: both %s and %s exist; left both untouched.\n", legacy, newPath)
		_, _ = fmt.Fprintf(w, "         RiotBox now uses %s. Move anything you need out of %s, then delete it.\n", newPath, legacy)
		return true, nil
	}
	if errs := prepare(stateDir); len(errs) > 0 {
		_, _ = fmt.Fprintf(w, "Warning: could not prepare %s; left %s in place:\n", stateDir, legacy)
		for _, err := range errs {
			_, _ = fmt.Fprintln(w, err)
		}
		_, _ = fmt.Fprintf(w, "         Once the cause is fixed, run %s.\n", migrateHint(w, stateDir))
		return true, nil
	}
	if msg, err := mvT(legacy, newPath); err != nil {
		_, _ = fmt.Fprintf(w, "Warning: could not move %s to %s; left it in place:\n", legacy, newPath)
		_, _ = fmt.Fprintln(w, msg)
		_, _ = fmt.Fprintf(w, "         RiotBox will not retry this move on its own. Once the cause is fixed, run %s, or move it by hand:\n", migrateHint(w, stateDir))
		_, _ = fmt.Fprintf(w, "           mv -T -- %s %s\n", display.Quote(legacy), display.Quote(newPath))
		_, _ = fmt.Fprintf(w, "         If %s exists by then (empty, partly copied from another disk, or written by a later launch), move it aside first.\n", newPath)
		return true, nil
	}
	// rename(2) moves the entry itself. If the container swapped the legacy
	// dir for a link after the check above, the link is now at <new>; discard
	// it rather than let a launch mount its target.
	if info, err := os.Lstat(newPath); err != nil || !info.IsDir() {
		_, _ = fmt.Fprintf(w, "Warning: %s changed during the move; discarded it.\n", legacy)
		return false, unlink(w, newPath)
	}
	_, _ = fmt.Fprintf(w, "Notice: moved %s to %s\n", legacy, newPath)
	return false, nil
}

// moveOverlay is moveLegacy for overlay/, then removes every entry directly
// under <stateDir>/overlay that is a link or not a directory, with a
// warning. Each overlay/<name> is a mount source of its own, one level below
// what moveLegacy checks, and while overlay/ sat in the session dir the
// container could swap one for a link. Safe on every call: nothing but
// RiotBox writes directly under <stateDir>/overlay. The names were chosen by
// the container, so the warnings show them cleaned (display.CleanName), with the jq
// library in libDir. When that dir cannot be
// listed it returns an error, so the pair stays unrecorded and runs again.
func moveOverlay(w io.Writer, libDir, sessionDir, stateDir string, replaceEmpty bool) (bool, error) {
	stranded, err := moveLegacy(w, sessionDir, stateDir, replaceEmpty, entry{legacy: "overlay", new: "overlay"})
	if err != nil {
		return false, err
	}
	base := stateDir + "/overlay"
	if !isRealDir(base) {
		return stranded, nil
	}
	// The tree was container-written: a cleanup that cannot see everything
	// in it must not let the pair be recorded as done.
	list, err := readDirInOrder(base)
	if err != nil {
		_, _ = fmt.Fprintf(w, "ERROR: could not list %s to remove what is not a real directory in it:\n", base)
		_, _ = fmt.Fprintln(w, err)
		_, _ = fmt.Fprintf(w, "       RiotBox will not use it until it can. Make it readable (chmod u+rwx -- %s), then run the command again.\n", display.Quote(base))
		return false, err
	}
	for _, ent := range list {
		if ent.IsDir() {
			continue
		}
		_, _ = fmt.Fprintf(w, "Warning: %s/%s is not a real directory; removed it without following it.\n", base, display.CleanName(w, libDir, ent.Name()))
		if err := unlink(w, base+"/"+ent.Name()); err != nil {
			return false, err
		}
	}
	return stranded, nil
}

// mvT runs `mv -T -- from to`. On failure it returns mv's message, as the
// bash's err="$(mv ... 2>&1)" captured it (trailing newlines trimmed), or
// why mv could not be run.
func mvT(from, to string) (string, error) {
	out, err := exec.Command("mv", "-T", "--", from, to).CombinedOutput()
	if err == nil {
		return "", nil
	}
	var exitErr *exec.ExitError
	if !errors.As(err, &exitErr) {
		return err.Error(), err
	}
	return strings.TrimRight(string(out), "\n"), err
}

// prepare is `mkdir -p <stateDir> && chmod 700 <parent> <stateDir>`, the
// parent being bash's ${stateDir%/*}. It returns the failures, none when
// both steps succeeded.
func prepare(stateDir string) []error {
	if err := os.MkdirAll(stateDir, 0o777); err != nil {
		return []error{err}
	}
	parent := stateDir
	if i := strings.LastIndexByte(stateDir, '/'); i >= 0 {
		parent = stateDir[:i]
	}
	var errs []error
	for _, dir := range []string{parent, stateDir} {
		if err := os.Chmod(dir, 0o700); err != nil {
			errs = append(errs, err)
		}
	}
	return errs
}

// unlink is `rm -f` on an entry that is not a directory: it removes the entry
// itself, never what a link names, and a missing entry is not an error.
// Unlike os.Remove it never falls back to rmdir, so an entry swapped for a
// directory in the meantime makes it fail, as rm -f did.
func unlink(w io.Writer, path string) error {
	if err := syscall.Unlink(path); err != nil && !errors.Is(err, syscall.ENOENT) {
		err = &fs.PathError{Op: "unlink", Path: path, Err: err}
		report(w, err)
		return err
	}
	return nil
}

// withLock runs fn holding the flock on <dir>/.migrate.lock
// (_with_migrate_lock), writing msg to w if it has to wait: waitMsg for a
// session's state dir, rootWaitMsg for the state root.
func withLock(w io.Writer, dir, msg string, fn func() error) error {
	release, err := lock.Acquire(dir+"/.migrate.lock", msg, w)
	if err != nil {
		report(w, err)
		return err
	}
	defer func() { _ = release() }() // closing a lock file cannot lose data
	return fn()
}
