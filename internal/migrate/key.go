package migrate

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"regexp"
	"strings"

	"github.com/trevor-vaughan/claude-riotbox/internal/display"
	"github.com/trevor-vaughan/claude-riotbox/internal/engine"
	"github.com/trevor-vaughan/claude-riotbox/internal/records"
	"github.com/trevor-vaughan/claude-riotbox/internal/sessionkey"
)

// rootWaitMsg is what _with_migrate_lock printed for the state root.
const rootWaitMsg = "Waiting for another RiotBox command to finish moving sessions to their new keys…"

// currentKeyShape matches the end of a key sessionkey.Key makes: "-" and
// the 16-hex SetHash.
var currentKeyShape = regexp.MustCompile(`-[0-9a-f]{16}$`)

// evidence says how oldOwner found the set an old-key session belongs to:
// _old_session_owner's return codes 0 to 5, in order.
type evidence int

const (
	byRecord         evidence = iota // the old state dir's record
	byProjects                       // the old session dir's .projects; no record exists
	unreadableRecord                 // a record exists but names no set (refused)
	noSessionDir                     // no record and no session dir
	keyLooksCurrent                  // no record, and the old key has a current key's shape (refused)
	noReadableSet                    // no record, and .projects names no readable set
)

// SessionKey ports migrate_session_key: the one-time move of a project
// set's session from the key an older release gave it to its own
// (sessionkey.Key of set). legacyKeys are the old keys to try, in order, as
// bash's legacy_session_key computed them: the projects as given, then,
// when that list had repeats, each project once, so `riotbox /a /a` also
// finds the session `riotbox /a` made. Each goes through every rule below
// on its own. Once the first has moved both dirs, the second finds the
// set's own dirs taken and is left where it is; if the first moved one dir
// only, the second is held to the "both exist" rule for it. When the first
// moved the session in this call and the second old session's evidence
// names this set too, one warning names the one left behind. Nothing is
// ever merged. The move keeps an upgraded session's Claude copy, state and
// overlays.
//
// Old keys were shared by every set whose paths differ only by "-" for "/",
// so an old session moves only when it provably belongs to this set:
//   - the old state dir's record (records.Recorded; host-only) names this
//     set; or
//   - it has no record (an older release left it), and the old session
//     dir's .projects (records.SessionProjects) names this set. .projects is
//     container-written, but it is the only evidence such a session has, and
//     only a set that shared the old key can reach it, so this binds nothing
//     the old key did not. The move's notice says so.
//
// Old and new keys share one namespace: a project whose path ends in
// "-<16 hex>" has an old key that can equal another set's current key. So
// the .projects fallback is refused, with a warning, when the old key has
// that shape: a session under it may be a current one, which a session of
// its own could make name this set. A record that is there but names no set is a refusal too,
// never taken for no record. A session whose evidence names another set
// stays where it is, with a warning that shows that set cleaned
// (terminal_clean line, with the jq library in libDir); one whose .projects
// names no readable set is left alone with a notice. No record is written
// here: a record lets overlay-accept apply the session's overlays, and only
// a launch of the set may grant that (record_projects).
//
// Each dir moves by one `mv -T` (mvT), only while nothing is at the new
// path, and the one holding the evidence moves last (the session dir when
// it was .projects, else the state dir), so a call that stops between the
// two leaves the next call the same evidence to finish by. When both the
// old and the new path exist, both are left, with a warning. Nothing inside
// a dir is read except .projects, which is never followed, and an old dir
// that is a link moves as the link. Before moving it refuses, failing
// closed, while the engine cannot confirm that no live container can write
// the old dirs (engine.RefuseIfRunning): it would keep writing there.
//
// It runs again only while an old dir is left to move and the set's own
// dir is missing: once a launch has created the set's session, nothing about
// the old key is said again. Commands that create nothing (overlay-diff,
// overlay-reject, session-remove by path) repeat their warning until then.
// Concurrent calls serialise on the state root's
// .migrate.lock, created with the root (mode 0700) when a move is pending,
// and re-check under it. It returns an error, already written to w, when a
// move or the refusal check fails; the caller must then stop.
func SessionKey(w io.Writer, eng, libDir, dataDir, stateRoot string, legacyKeys, set []string) error {
	key := sessionkey.Key(set)
	newSession, newState := dataDir+"/"+key, stateRoot+"/"+key
	setList := strings.Join(set, "\n")
	moved := false
	for _, oldKey := range legacyKeys {
		oldSession, oldState := dataDir+"/"+oldKey, stateRoot+"/"+oldKey
		if !movePending(oldSession, newSession) && !movePending(oldState, newState) {
			// An earlier key's session took the set's dirs in this call. One
			// this set's evidence also names is left behind; say so once.
			if moved && (isDirFollow(oldSession) || isDirFollow(oldState)) {
				owner, ev := oldOwner(w, oldSession, oldState)
				if ev <= byProjects && records.SameSet(owner, setList) {
					_, _ = fmt.Fprintf(w, "Warning: both %s and %s hold a session of this project set; left %s untouched.\n", oldSession, newSession, oldSession)
					if isDirFollow(oldState) {
						_, _ = fmt.Fprintf(w, "         RiotBox now uses %s. Move anything you need out of %s and %s, then delete them.\n", newSession, oldSession, oldState)
					} else {
						_, _ = fmt.Fprintf(w, "         RiotBox now uses %s. Move anything you need out of %s, then delete it.\n", newSession, oldSession)
					}
				}
			}
			continue
		}
		if err := os.MkdirAll(stateRoot, 0o777); err != nil {
			report(w, err)
			return err
		}
		if err := os.Chmod(stateRoot, 0o700); err != nil {
			report(w, err)
			return err
		}
		err := withLock(w, stateRoot, rootWaitMsg, func() error {
			return sessionKeyLocked(w, eng, libDir, oldSession, oldState, newSession, newState, setList)
		})
		if err != nil {
			return err
		}
		if !present(oldSession) && !present(oldState) {
			moved = true
		}
	}
	return nil
}

// sessionKeyLocked is _migrate_session_key_locked: SessionKey's decision and
// moves for one old key; the caller holds the state root's lock.
func sessionKeyLocked(w io.Writer, eng, libDir, oldSession, oldState, newSession, newState, setList string) error {
	if !movePending(oldSession, newSession) && !movePending(oldState, newState) {
		return nil
	}
	owner, ev := oldOwner(w, oldSession, oldState)
	how := ""
	switch ev {
	case byRecord:
	case byProjects:
		how = " (matched by its .projects: an older RiotBox left no record)"
	case unreadableRecord:
		_, _ = fmt.Fprintf(w, "Warning: %s/projects is not a readable project record, so %s cannot be shown to be this set's; left it in place. This set uses %s.\n", oldState, oldSession, newSession)
		return nil
	case noSessionDir:
		_, _ = fmt.Fprintf(w, "Notice: %s is under this project set's old key, with no record and no session dir to show whose it is; left it in place. This set uses %s.\n", oldState, newState)
		return nil
	case keyLooksCurrent:
		_, _ = fmt.Fprintf(w, "Warning: %s has no record and a name a current session key can have, so its .projects is not trusted; left it in place. This set uses %s.\n", oldSession, newSession)
		_, _ = fmt.Fprintf(w, "         If it is this set's session (check what %s/.projects names first), exit every session using it and move it by hand:\n", oldSession)
		_, _ = fmt.Fprintf(w, "           mv -T -- %s\n", display.QuoteWords(oldSession, newSession))
		if isDirFollow(oldState) {
			_, _ = fmt.Fprintf(w, "           mv -T -- %s\n", display.QuoteWords(oldState, newState))
		}
		return nil
	default:
		_, _ = fmt.Fprintf(w, "Notice: %s is under this project set's old key, but its .projects names no readable set; left it in place. This set uses %s.\n", oldSession, newSession)
		return nil
	}
	if !records.SameSet(owner, setList) {
		_, _ = fmt.Fprintf(w, "Warning: %s is the session an older RiotBox kept under this project\n", oldSession)
		_, _ = fmt.Fprintln(w, "         set's old key, but it belongs to another project set; left it in place.")
		_, _ = fmt.Fprintf(w, "         This set uses %s. The old session's set:\n", newSession)
		printCleanedSet(w, libDir, owner)
		return nil
	}
	if err := engine.RefuseIfRunning(w, eng, libDir, oldSession, oldState, "RiotBox's move to the new session key", "launch again"); err != nil {
		_, _ = fmt.Fprintf(w, "       Nothing was moved: %s gets the session once nothing runs on %s.\n", newSession, oldSession)
		return err
	}
	if how != "" {
		if err := moveKeyDir(w, oldState, newState, ""); err != nil {
			return err
		}
		return moveKeyDir(w, oldSession, newSession, how)
	}
	if err := moveKeyDir(w, oldSession, newSession, ""); err != nil {
		return err
	}
	return moveKeyDir(w, oldState, newState, "")
}

// oldOwner is _old_session_owner: the project set, newline-separated, that
// the evidence names for an old-key session, and which evidence that was.
// The set is empty unless the evidence is byRecord or byProjects. An
// unreadable record is reported on w, as the recorded-projects verb the
// bash ran reported it; an unreadable .projects is not, as session_projects
// discarded dd's message.
func oldOwner(w io.Writer, oldSession, oldState string) (string, evidence) {
	if present(oldState + "/projects") {
		lines, err := records.Recorded(oldState)
		if err != nil {
			report(w, err)
		}
		if len(lines) == 0 {
			return "", unreadableRecord
		}
		return strings.Join(lines, "\n"), byRecord
	}
	if !isDirFollow(oldSession) {
		return "", noSessionDir
	}
	if currentKeyShape.MatchString(oldSession[strings.LastIndexByte(oldSession, '/')+1:]) {
		return "", keyLooksCurrent
	}
	lines, _ := records.SessionProjects(oldSession)
	if len(lines) == 0 {
		return "", noReadableSet
	}
	return strings.Join(lines, "\n"), byProjects
}

// printCleanedSet writes each line of a container-written set to w,
// indented, cleaned by terminal_clean line. When jq cannot clean it, nothing
// of the set is printed, as the bash pipeline printed nothing: jq's own
// message is already on w, and why jq could not run is reported.
func printCleanedSet(w io.Writer, libDir, set string) {
	cleaned, err := display.CleanLines(libDir, set+"\n", w)
	if err != nil {
		var exitErr *exec.ExitError
		if !errors.As(err, &exitErr) {
			report(w, err)
		}
		return
	}
	for line := range strings.Lines(cleaned) {
		if strings.HasSuffix(line, "\n") {
			_, _ = fmt.Fprintf(w, "           %s", line)
		}
	}
}

// moveKeyDir is _move_key_dir: rename old to new, printing a notice with
// note appended when it moved. Nothing to do when old is not a directory (or
// a link to one); both left, with a warning, when anything is at new. It
// returns an error, saying why, when the rename fails.
func moveKeyDir(w io.Writer, old, newPath, note string) error {
	if !isDirFollow(old) {
		return nil
	}
	if present(newPath) {
		_, _ = fmt.Fprintf(w, "Warning: both %s and %s exist; left both untouched.\n", old, newPath)
		_, _ = fmt.Fprintf(w, "         RiotBox now uses %s. Move anything you need out of %s, then delete it.\n", newPath, old)
		return nil
	}
	if msg, err := mvT(old, newPath); err != nil {
		_, _ = fmt.Fprintf(w, "Error: could not move %s to %s:\n", old, newPath)
		_, _ = fmt.Fprintln(w, msg)
		_, _ = fmt.Fprintln(w, "       Fix the cause and run the command again; the next run finishes the move.")
		return err
	}
	_, _ = fmt.Fprintf(w, "Notice: moved %s to %s%s\n", old, newPath, note)
	return nil
}

// movePending is _key_move_pending: old is a directory, or a link to one,
// and nothing, not even a dangling link, is at newPath. A newPath that
// cannot be checked counts as taken.
func movePending(old, newPath string) bool {
	return isDirFollow(old) && !present(newPath)
}
