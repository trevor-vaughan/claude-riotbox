// Package realpath ports the two GNU `realpath` modes the bash used to
// compare paths with container mount sources: `realpath -m` (Canonical) and
// `realpath -ms` (Lexical). No component has to exist in either mode.
//
// Canonical follows gnulib's canonicalize_filename_mode with CAN_MISSING, as
// coreutils 9.5 builds it: components are walked left to right; each one is
// read with readlink(2) and, when it is a link, its target replaces it (an
// absolute target restarts at /, a relative one at the parent); any readlink
// error (missing, not a link, not a directory) keeps the component as
// written; ".." drops the last resolved component, so it applies after the
// links before it are followed. After 20 links, a link met again with the
// same parent directory and the same remaining path is a cycle: it is kept as
// written instead of an error, which is what `-m` prints.
//
// One deliberate difference from GNU: Canonical follows at most maxLinks
// links and then fails with ELOOP. A link that grows the path it expands to,
// such as q -> q/../q or s -> s/., never repeats a (parent, remaining path)
// pair, so GNU's cycle check never fires and `realpath -m` runs forever. A
// container with a read-write mount could plant one to hang every command
// that asks which containers can write a session; with the bound, those
// commands fail closed instead. The bound is the Linux kernel's own
// (MAXSYMLINKS): a path that needs more links than that cannot be opened by
// any process, so no usable path trips it. Every cycle of up to 20 links is
// still resolved as GNU does, since its check fires within 20 + the cycle's
// length expansions.
package realpath

import (
	"errors"
	"fmt"
	"os"
	"strings"
	"syscall"
)

// linksBeforeCycleCheck is gnulib's count of links followed before it starts
// looking for cycles.
const linksBeforeCycleCheck = 20

// maxLinks is the most links Canonical follows: Linux's MAXSYMLINKS, the
// links the kernel follows in one path lookup before it fails with ELOOP.
const maxLinks = 40

// Canonical returns `realpath -m -- path`.
func Canonical(path string) (string, error) {
	dest, rest, err := start(path)
	if err != nil {
		return "", err
	}
	type seenKey struct {
		rest     string
		dev, ino uint64
	}
	seen := map[seenKey]bool{}
	links, followed := 0, 0
	for {
		rest = strings.TrimLeft(rest, "/")
		if rest == "" {
			return dest, nil
		}
		comp, after := rest, ""
		if i := strings.IndexByte(rest, '/'); i >= 0 {
			comp, after = rest[:i], rest[i:]
		}
		switch comp {
		case ".":
			rest = after
			continue
		case "..":
			dest = parent(dest)
			rest = after
			continue
		}
		dir := dest
		if !strings.HasSuffix(dir, "/") {
			dir += "/"
		}
		dest = dir + comp
		target, readErr := os.Readlink(dest)
		if readErr != nil {
			rest = after
			continue
		}
		if links < linksBeforeCycleCheck {
			links++
		} else {
			var st syscall.Stat_t
			if err := syscall.Stat(dir, &st); err != nil {
				return "", failure(path, err)
			}
			key := seenKey{rest: rest, dev: st.Dev, ino: st.Ino}
			if seen[key] {
				rest = after
				continue
			}
			seen[key] = true
		}
		if followed == maxLinks {
			return "", failure(path, syscall.ELOOP)
		}
		followed++
		rest = target + after
		if strings.HasPrefix(target, "/") {
			dest = "/"
		} else {
			dest = parent(dest)
		}
	}
}

// Lexical returns `realpath -ms -- path`: the same walk with no link read.
func Lexical(path string) (string, error) {
	dest, rest, err := start(path)
	if err != nil {
		return "", err
	}
	for _, comp := range strings.Split(rest, "/") {
		switch comp {
		case "", ".":
		case "..":
			dest = parent(dest)
		default:
			if !strings.HasSuffix(dest, "/") {
				dest += "/"
			}
			dest += comp
		}
	}
	return dest, nil
}

// start returns where the walk begins: / for an absolute path, else the
// physical working directory (getcwd(2), as gnulib calls it, never $PWD),
// and the path left to walk. An empty path fails as realpath does.
func start(path string) (dest, rest string, err error) {
	if path == "" {
		return "", "", failure(path, syscall.ENOENT)
	}
	if strings.HasPrefix(path, "/") {
		return "/", path, nil
	}
	cwd, err := syscall.Getwd()
	if err != nil {
		return "", "", failure(path, err)
	}
	return cwd, path, nil
}

// parent drops the last component of a resolved path; / stays /.
func parent(dest string) string {
	i := strings.LastIndexByte(dest, '/')
	if i <= 0 {
		return "/"
	}
	return dest[:i]
}

// failure formats err as realpath reports it: "realpath: <name>: <strerror>".
// An empty name prints as ”, as GNU's quoting does; other names print as
// given.
func failure(path string, err error) error {
	name := path
	if name == "" {
		name = "''"
	}
	msg := err.Error()
	var errno syscall.Errno
	if errors.As(err, &errno) && msg != "" {
		// Go's errno strings are strerror(3)'s with a lowercase first letter.
		msg = strings.ToUpper(msg[:1]) + msg[1:]
	}
	return fmt.Errorf("realpath: %s: %s", name, msg)
}
