package migrate

// The filesystem predicates and directory listings the migrations share.
// Each says which bash test it ports and whether it follows a link.

import (
	"errors"
	"io"
	"io/fs"
	"os"
	"syscall"
)

// dirHasData reports whether path is a real directory, not a link, that
// holds at least one entry or cannot be listed: an unreadable directory may
// be the very cause of a failed move, and must not be taken for empty.
func dirHasData(path string) bool {
	return isRealDir(path) && listsEntries(path)
}

// listsEntries is dirHasData's listing. The path is container-writable, so
// it may have been swapped since the Lstat: an open that blocked on a FIFO
// would hang every later launch behind .migrate.lock, and one that followed
// a link would list its target. Opening fails instead on anything but a
// real directory, which counts as no data.
func listsEntries(path string) bool {
	var fd int
	var err error
	for {
		fd, err = syscall.Open(path, syscall.O_RDONLY|syscall.O_DIRECTORY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
		if !errors.Is(err, syscall.EINTR) {
			break
		}
	}
	switch {
	case errors.Is(err, syscall.ENOTDIR), errors.Is(err, syscall.ELOOP):
		return false
	case err != nil:
		return true
	}
	f := os.NewFile(uintptr(fd), path)
	defer func() { _ = f.Close() }() // read-only
	names, err := f.Readdirnames(1)
	return len(names) > 0 || err != io.EOF
}

// isEmptyRealDir reports whether path is a real directory, not a link, that
// lists as empty.
func isEmptyRealDir(path string) bool {
	return isRealDir(path) && !dirHasData(path)
}

// isRealDir is bash's `[[ -d path && ! -L path ]]`.
func isRealDir(path string) bool {
	info, err := os.Lstat(path)
	return err == nil && info.IsDir()
}

// isDirFollow is bash's `-d`, which follows links.
func isDirFollow(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

// isLink is bash's `-L`.
func isLink(path string) bool {
	info, err := os.Lstat(path)
	return err == nil && info.Mode()&os.ModeSymlink != 0
}

// readDirInOrder lists dir in directory order, as find does.
func readDirInOrder(dir string) ([]os.DirEntry, error) {
	f, err := os.Open(dir)
	if err != nil {
		return nil, err
	}
	defer func() { _ = f.Close() }() // read-only
	return f.ReadDir(-1)
}

// present reports whether anything, a dangling link included, is at path.
// A path that cannot be checked counts as present, so the caller refuses.
func present(path string) bool {
	_, err := os.Lstat(path)
	return !errors.Is(err, fs.ErrNotExist)
}
