package migrate

import (
	"io"
	"os"
	"strings"

	"github.com/trevor-vaughan/claude-riotbox/internal/records"
)

// AllSessions ports riotbox overlays' migration pass (overlay_list in
// scripts/overlay.sh, which ran _overlay_migrate_sessions under the root
// lock and now runs riotbox-core migrate-all): SessionState for every
// session under <dataDir>, so an upgrade does not hide pending overlay data
// until each project's next launch.
//
// A session is what bash's "${dataDir}"/*/ glob and is_session accept: an
// entry whose name does not start with a dot and that records.IsSession
// accepts with <stateRoot>/<name> as its state dir. A link to a directory
// counts, as the glob and [[ -d ]] follow it, and is migrated through the
// link. Sessions run in bytewise name order. The bash glob sorted by the
// caller's LC_COLLATE, so under a locale other than C the bash could take
// them in another order: their messages, and which ran before one that
// failed, could differ.
//
// When there is no session it does nothing and creates nothing. Otherwise
// it creates <stateRoot> mode 0700 and holds its lock (rootWaitMsg, the
// lock SessionKey's move holds) for the whole pass, so an old-key session
// is either not moved yet or gone, never half moved; each SessionState then
// takes its session's lock inside it, the order every caller takes them in.
// The sessions are listed again under the root lock. The pass stops at the
// first session that fails and returns its error, already written to w.
func AllSessions(w io.Writer, libDir, dataDir, stateRoot string) error {
	if len(sessions(dataDir, stateRoot)) == 0 {
		return nil
	}
	if err := os.MkdirAll(stateRoot, 0o777); err != nil {
		report(w, err)
		return err
	}
	if err := os.Chmod(stateRoot, 0o700); err != nil {
		report(w, err)
		return err
	}
	return withLock(w, stateRoot, rootWaitMsg, func() error {
		for _, name := range sessions(dataDir, stateRoot) {
			if err := SessionState(w, libDir, dataDir+"/"+name, stateRoot+"/"+name); err != nil {
				return err
			}
		}
		return nil
	})
}

// sessions lists the names under dataDir that are sessions, in bytewise
// order. A dataDir that cannot be listed has none, as the glob then
// matches nothing.
func sessions(dataDir, stateRoot string) []string {
	entries, err := os.ReadDir(dataDir)
	if err != nil {
		return nil
	}
	var names []string
	for _, e := range entries {
		name := e.Name()
		if !strings.HasPrefix(name, ".") && records.IsSession(dataDir+"/"+name, stateRoot+"/"+name) {
			names = append(names, name)
		}
	}
	return names
}
