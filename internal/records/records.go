// Package records reads the two lists of a session's project paths: the
// launch's record in the host-only state dir (recorded_projects in
// scripts/lib/session-state.sh) and the .projects marker in the
// container-writable session dir (session_projects). Both return the
// non-empty lines; an empty result means "no list", which the bash reports
// as return code 1.
// IsSession (is_session) decides from the two whether a dir is a session.
package records

import (
	"bytes"
	"errors"
	"os"
	"slices"
	"strings"
	"syscall"
)

// sessionProjectsCap is dd's bs=64K count=1: one read of at most 64 KiB.
const sessionProjectsCap = 64 << 10

// Recorded ports recorded_projects: the non-empty lines of
// <stateDir>/projects. A record that is absent, not a regular file, or a
// link yields no lines and no error. A record that cannot be read yields an
// error, where bash printed the failed redirect and returned 1.
//
// It matches bash's `while IFS= read -r` loop: NUL bytes are dropped and an
// unterminated last line is not returned. record_projects always ends the
// file with a newline, so only a damaged record has one.
func Recorded(stateDir string) ([]string, error) {
	file := stateDir + "/projects"
	if !isRegular(file) {
		return nil, nil
	}
	content, err := os.ReadFile(file)
	if err != nil {
		return nil, err
	}
	if i := bytes.LastIndexByte(content, '\n'); i >= 0 {
		content = content[:i]
	} else {
		content = nil
	}
	return nonEmptyLines(content), nil
}

// SessionProjects ports session_projects: the non-empty lines of
// <sessionDir>/.projects, which the container can replace with anything at
// any moment. Anything other than a regular file yields no lines and no
// error. A failed open or read yields an error; the bash discarded dd's
// message, so callers should not print it either.
//
// Only the first 64 KiB are read, NUL bytes are dropped, and an
// unterminated last line counts, as with bash's here-string.
func SessionProjects(sessionDir string) ([]string, error) {
	file := sessionDir + "/.projects"
	if !isRegular(file) {
		return nil, nil
	}
	content, err := readNoFollow(file)
	if err != nil {
		return nil, err
	}
	return nonEmptyLines(content), nil
}

// readNoFollow is session_projects' dd: the entry can be swapped after the
// Lstat, so this one open is what enforces it. O_NOFOLLOW fails on a link
// (ELOOP), O_NONBLOCK keeps a FIFO from blocking the open or the read, a
// directory fails the read (EISDIR), and a single read caps the size. It
// uses syscall directly: os.File would park a non-blocking FIFO read on the
// runtime poller, which waits where dd fails.
func readNoFollow(path string) ([]byte, error) {
	var fd int
	var err error
	for {
		fd, err = syscall.Open(path, syscall.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK|syscall.O_CLOEXEC, 0)
		if !errors.Is(err, syscall.EINTR) {
			break
		}
	}
	if err != nil {
		return nil, err
	}
	defer func() { _ = syscall.Close(fd) }() // read-only: nothing to flush
	buf := make([]byte, sessionProjectsCap)
	var n int
	for {
		n, err = syscall.Read(fd, buf)
		if !errors.Is(err, syscall.EINTR) {
			break
		}
	}
	if err != nil {
		return nil, err
	}
	return buf[:n], nil
}

// IsSession ports is_session: whether <sessionDir> is a RiotBox session.
// It is a directory, a link to one included, that carries a .projects
// regular file, a link to one included, or whose <stateDir> carries the
// launch's record as a regular file that is not a link. These are bash's
// [[ -d ]], [[ -f ]] and [[ -f && ! -L ]]: the first two follow links.
//
// The record matters because a running session can replace its own
// .projects to hide from the session commands until its next launch; the
// record sits in the state dir, which the container cannot reach.
func IsSession(sessionDir, stateDir string) bool {
	info, err := os.Stat(sessionDir)
	if err != nil || !info.IsDir() {
		return false
	}
	if info, err := os.Stat(sessionDir + "/.projects"); err == nil && info.Mode().IsRegular() {
		return true
	}
	return isRegular(stateDir + "/projects")
}

// SameSet ports same_project_set: whether two newline-separated path lists
// name the same set. Each list is split into lines, sorted bytewise (LC_ALL=C
// sort) with repeats dropped, and compared. A blank line, from a trailing
// newline too, is a member; only the sorted result's trailing newlines are
// trimmed, as the bash's command substitutions trimmed them, so a list of
// blank lines equals an empty one.
func SameSet(a, b string) bool {
	return sortedSet(a) == sortedSet(b)
}

// sortedSet is `printf '%s\n' "$list" | LC_ALL=C sort -u` as a command
// substitution captures it.
func sortedSet(list string) string {
	lines := strings.Split(list, "\n")
	slices.Sort(lines)
	return strings.TrimRight(strings.Join(slices.Compact(lines), "\n"), "\n")
}

// isRegular is bash's `[[ -f file && ! -L file ]]`.
func isRegular(path string) bool {
	info, err := os.Lstat(path)
	return err == nil && info.Mode().IsRegular()
}

// nonEmptyLines drops NUL bytes, splits on newlines and keeps the non-empty
// lines.
func nonEmptyLines(content []byte) []string {
	content = bytes.ReplaceAll(content, []byte{0}, nil)
	var lines []string
	for line := range bytes.SplitSeq(content, []byte{'\n'}) {
		if len(line) > 0 {
			lines = append(lines, string(line))
		}
	}
	return lines
}
