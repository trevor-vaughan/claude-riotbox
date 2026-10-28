package state

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"

	"github.com/trevor-vaughan/claude-riotbox/internal/display"
)

// tmpfsMagic is TMPFS_MAGIC (linux/magic.h), the f_type statfs(2) reports
// for a tmpfs.
const tmpfsMagic = 0x01021994

// runtimeSubdir is the dir RuntimeBase names under the runtime dir: one
// <session>/secrets per session that injects keys.
const runtimeSubdir = "riotbox-egress"

// ErrNoRuntimeDir is RuntimeBase's failure: no runtime dir can keep the
// keys off persistent disk.
var ErrNoRuntimeDir = errors.New("credential injection needs a private tmpfs runtime dir ($XDG_RUNTIME_DIR or /run/user/<uid>) so keys never reach disk; none found — unset the keys to run without injection, or start the session from a login session")

// RuntimeHost is what RuntimeBase reads about the host. HostRuntime is
// this process's; specs substitute their own.
type RuntimeHost struct {
	Getenv  func(string) string
	UID     int
	RunUser string // systemd's per-user runtime dirs' parent, /run/user
	IsTmpfs func(path string) (bool, error)
}

// HostRuntime is the RuntimeHost of this process.
func HostRuntime() RuntimeHost {
	return RuntimeHost{Getenv: os.Getenv, UID: os.Getuid(), RunUser: "/run/user", IsTmpfs: isTmpfs}
}

func isTmpfs(path string) (bool, error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil {
		return false, err
	}
	return st.Type == tmpfsMagic, nil
}

// RuntimeBase is the dir the sessions' secrets dirs go under
// (Dir.WithRuntime): riotbox-egress in the first of $XDG_RUNTIME_DIR (when
// absolute; the XDG spec says to ignore a relative one) and
// /run/user/<uid> that is a directory owned by the uid, mode 0700, on a
// tmpfs. So the keys never reach persistent disk, and only the user can
// reach them. A link to such a dir is followed. When neither qualifies it
// returns ErrNoRuntimeDir, with why each was refused.
func RuntimeBase(h RuntimeHost) (string, error) {
	bases, why := runtimeBases(h)
	if len(bases) == 0 {
		return "", fmt.Errorf("%w (%s)", ErrNoRuntimeDir, strings.Join(why, "; "))
	}
	return bases[0], nil
}

// RuntimeBases is riotbox-egress under every candidate RuntimeBase
// considers that qualifies, in its order, each dir once. Teardown and the
// sweep remove secrets under all of them, so a session started with the
// other runtime dir in its environment is still cleaned up.
func RuntimeBases(h RuntimeHost) []string {
	bases, _ := runtimeBases(h)
	return bases
}

// runtimeBases returns riotbox-egress under each qualifying candidate, and
// why each other one was refused.
func runtimeBases(h RuntimeHost) (bases, why []string) {
	var dirs []string
	xdg := h.Getenv("XDG_RUNTIME_DIR")
	switch {
	case xdg == "":
		why = append(why, "$XDG_RUNTIME_DIR is unset")
	case !filepath.IsAbs(xdg):
		why = append(why, "$XDG_RUNTIME_DIR is not an absolute path")
	default:
		dirs = append(dirs, xdg)
	}
	dirs = append(dirs, filepath.Join(h.RunUser, strconv.Itoa(h.UID)))
	for _, dir := range dirs {
		base := filepath.Join(dir, runtimeSubdir)
		if slices.Contains(bases, base) {
			continue
		}
		if err := privateTmpfs(h, dir); err != nil {
			why = append(why, err.Error())
			continue
		}
		bases = append(bases, base)
	}
	return bases, why
}

// privateTmpfs returns why dir cannot hold keys, or nil when it is a
// directory owned by h.UID, mode 0700, on a tmpfs.
func privateTmpfs(h RuntimeHost, dir string) error {
	q := display.Quote(dir)
	info, err := os.Stat(dir)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return fmt.Errorf("%s does not exist", q)
	case err != nil:
		return err
	case !info.IsDir():
		return fmt.Errorf("%s is not a directory", q)
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return fmt.Errorf("%s has no owner the system reports", q)
	}
	if int(st.Uid) != h.UID {
		return fmt.Errorf("%s is owned by uid %d, not %d", q, st.Uid, h.UID)
	}
	if p := info.Mode().Perm(); p != 0o700 {
		return fmt.Errorf("%s is mode %04o, not 0700", q, p)
	}
	tmpfs, err := h.IsTmpfs(dir)
	if err != nil {
		return fmt.Errorf("%s: %w", q, err)
	}
	if !tmpfs {
		return fmt.Errorf("%s is not on tmpfs", q)
	}
	return nil
}
