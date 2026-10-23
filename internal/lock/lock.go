// Package lock ports _with_migrate_lock from scripts/lib/session-state.sh:
// an exclusive flock(2) on a lock file that is interoperable with flock(1),
// so Go and bash callers exclude each other.
package lock

import (
	"fmt"
	"io"
	"os"
	"syscall"
)

// Acquire opens path, creating it if absent, and takes an exclusive flock on
// it. The file is created with mode 0o666 before the umask, which is what
// bash's `exec {fd}>file` produces; the bash never chmods it.
//
// It first tries a non-blocking lock. If the lock is busy it writes waitMsg
// and a newline to w, then blocks until the lock is free. The caller chooses
// waitMsg. A failing write to w is ignored and the lock is still awaited, as
// with bash's `echo >&2`. The returned func releases the lock and closes the
// file.
//
// Two deliberate differences from bash. The descriptor is close-on-exec
// (bash's is inherited), so a child that outlives the caller cannot keep the
// lock. And a flock error other than contention is returned, where bash would
// wait.
func Acquire(path, waitMsg string, w io.Writer) (release func() error, err error) {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o666)
	if err != nil {
		return nil, err
	}
	fd := int(f.Fd())
	err = syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB)
	if err == syscall.EWOULDBLOCK {
		_, _ = fmt.Fprintln(w, waitMsg)
		err = flockRetryEINTR(fd)
	}
	if err != nil {
		_ = f.Close() // the lock error is the one to report
		return nil, err
	}
	return f.Close, nil
}

// flockRetryEINTR blocks for an exclusive lock, retrying when a signal
// interrupts the wait.
func flockRetryEINTR(fd int) error {
	for {
		err := syscall.Flock(fd, syscall.LOCK_EX)
		if err != syscall.EINTR {
			return err
		}
	}
}
