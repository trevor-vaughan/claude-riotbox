package migrate

import (
	"fmt"
	"io"
	"os"
	"slices"
	"strings"

	"github.com/trevor-vaughan/claude-riotbox/internal/display"
)

// headroomNoticeName is the marker record HeadroomNotice writes.
const headroomNoticeName = "project-headroom-notice"

// HeadroomNotice runs once per session, under the session's migrate lock:
// for each of <projectDir>/.headroom and <stateDir>/overlay/*/upper/.headroom
// that is a real directory, it says that it may hold headroom memory an
// older RiotBox left there, and how to delete it or copy it to
// <stateDir>/headroom, where memory is kept now. Older releases let headroom
// default its memory DB to the container's working directory: for one
// project the user's checkout, or in overlay mode the overlay upper. Nothing
// is moved or deleted: a .headroom the user made with their own headroom
// looks the same. Overlay names come from a tree the container wrote, so
// the notice line shows them cleaned (display.CleanName, with the jq library in
// libDir); the commands quote them. The check is recorded in the marker whether or not it
// printed anything; an error means it could not be recorded.
func HeadroomNotice(w io.Writer, libDir, projectDir, stateDir string) error {
	return withLock(w, stateDir, waitMsg, func() error {
		return headroomLocked(w, libDir, projectDir, stateDir)
	})
}

func headroomLocked(w io.Writer, libDir, projectDir, stateDir string) error {
	recorded, _ := readMarker(w, stateDir)
	if recorded[headroomNoticeName] {
		return nil
	}
	projectCopy := projectDir + "/.headroom"
	printed := false
	for _, old := range append([]string{projectCopy}, overlayHeadroomCopies(stateDir)...) {
		if !isDirFollow(old) || isLink(old) {
			continue
		}
		// A session can replace its upper, or the overlay's own dir, with a
		// link; the glob follows it, and the printed rm -rf would delete
		// through it.
		if old != projectCopy && (isLink(strings.TrimSuffix(old, "/.headroom")) || isLink(strings.TrimSuffix(old, "/upper/.headroom"))) {
			continue
		}
		printed = true
		headroom := stateDir + "/headroom"
		shown := old
		if old != projectCopy {
			name := strings.TrimSuffix(strings.TrimPrefix(old, stateDir+"/overlay/"), "/upper/.headroom")
			shown = stateDir + "/overlay/" + display.CleanName(w, libDir, name) + "/upper/.headroom"
		}
		_, _ = fmt.Fprintf(w, "Notice: %s may hold headroom memory from an older RiotBox.\n", shown)
		if old == projectCopy {
			_, _ = fmt.Fprintln(w, "        It was written into the project; RiotBox leaves it alone.")
		} else {
			_, _ = fmt.Fprintln(w, "        It was written into this session's overlay; overlay-accept never copies it into")
			_, _ = fmt.Fprintln(w, "        the project, and overlay-reject keeps it.")
		}
		_, _ = fmt.Fprintf(w, "        RiotBox now keeps headroom memory in %s. To delete the old copy:\n", headroom)
		_, _ = fmt.Fprintf(w, "          rm -rf -- %s\n", display.Quote(old))
		_, _ = fmt.Fprintln(w, "        To keep it instead, exit every RiotBox session of this project, then replace the")
		_, _ = fmt.Fprintln(w, "        memory the new location holds (its SQLite -wal/-shm files included) with it:")
		_, _ = fmt.Fprintf(w, "          rm -rf -- %s/memory*.db* %s && cp -a -- %s %s && rm -rf -- %s\n",
			display.Quote(headroom), display.Quote(headroom+"/memories"), display.Quote(old+"/."), display.Quote(headroom+"/"), display.Quote(old))
		if old == projectCopy {
			_, _ = fmt.Fprintln(w, "        If .headroom/ was committed, untrack it and add it to .gitignore:")
			_, _ = fmt.Fprintf(w, "          git -C %s rm -r --cached -- .headroom && echo .headroom/ >>%s\n",
				display.Quote(projectDir), display.Quote(projectDir+"/.gitignore"))
		}
	}
	if printed {
		_, _ = fmt.Fprintln(w, "        This notice is shown once per session.")
	}
	return record(w, stateDir, headroomNoticeName)
}

// overlayHeadroomCopies is bash's "<stateDir>"/overlay/*/upper/.headroom
// glob without the paths that do not exist, which the caller's checks drop
// anyway: one candidate per overlay name, dot names included (an overlay is
// named after its project's basename, so ".dotfiles" is one), in byte order,
// following a link at overlay/ as the glob does.
func overlayHeadroomCopies(stateDir string) []string {
	base := stateDir + "/overlay"
	f, err := os.Open(base)
	if err != nil {
		return nil
	}
	names, _ := f.Readdirnames(-1) // the glob lists what it could read
	_ = f.Close()                  // read-only
	slices.Sort(names)
	var copies []string
	for _, name := range names {
		copies = append(copies, base+"/"+name+"/upper/.headroom")
	}
	return copies
}
