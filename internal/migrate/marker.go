package migrate

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/trevor-vaughan/claude-riotbox/internal/display"
	"github.com/trevor-vaughan/claude-riotbox/internal/records"
)

// readMarker returns every name a line of <stateDir>/.migrated mentions, and
// whether each one's last line is failed:<name>. A missing marker, or one
// that is not a regular file, records nothing. NUL bytes are dropped and a
// last line without a newline still counts, as with bash's
// `while IFS= read -r line || [[ -n ${line} ]]`. A marker that cannot be read
// is reported and records nothing, as bash's failed redirect did.
func readMarker(w io.Writer, stateDir string) (recorded, failed map[string]bool) {
	recorded, failed = map[string]bool{}, map[string]bool{}
	marker := stateDir + "/.migrated"
	if info, err := os.Stat(marker); err != nil || !info.Mode().IsRegular() {
		return recorded, failed
	}
	content, err := os.ReadFile(marker)
	if err != nil {
		report(w, err)
		return recorded, failed
	}
	content = bytes.ReplaceAll(content, []byte{0}, nil)
	for line := range strings.SplitSeq(string(content), "\n") {
		name := strings.TrimPrefix(line, "failed:")
		if name == "" {
			continue
		}
		recorded[name] = true
		failed[name] = strings.HasPrefix(line, "failed:")
	}
	return recorded, failed
}

// record appends each line to <stateDir>/.migrated. The top of the state dir
// is host-only, so a temp file and a rename are enough to keep the marker
// whole if this is interrupted. The existing content first gets its missing
// final newline; like bash's `$(tail -c 1)`, a final NUL counts as none
// missing.
func record(w io.Writer, stateDir string, lines ...string) error {
	marker := stateDir + "/.migrated"
	tmp, err := os.CreateTemp(stateDir, ".migrated.*")
	if err != nil {
		report(w, err)
		return err
	}
	var buf bytes.Buffer
	if info, statErr := os.Stat(marker); statErr == nil && info.Mode().IsRegular() {
		content, readErr := os.ReadFile(marker)
		if readErr != nil {
			return discard(w, tmp, readErr)
		}
		buf.Write(content)
		if n := len(content); n > 0 && content[n-1] != '\n' && content[n-1] != 0 {
			buf.WriteByte('\n')
		}
	}
	for _, line := range lines {
		buf.WriteString(line + "\n")
	}
	if _, err := tmp.Write(buf.Bytes()); err != nil {
		return discard(w, tmp, err)
	}
	if err := tmp.Close(); err != nil {
		return discard(w, tmp, err)
	}
	if err := os.Rename(tmp.Name(), marker); err != nil {
		return discard(w, tmp, err)
	}
	return nil
}

// discard reports err and removes the temp file record was writing.
func discard(w io.Writer, tmp *os.File, err error) error {
	report(w, err)
	_ = tmp.Close()           // already closed on the rename path
	_ = os.Remove(tmp.Name()) // the error being reported is the one that matters
	return err
}

// migrateHint is how to run riotbox session-migrate for the session: the
// command with the project paths of the host-only record, quoted, or, for a
// session without one, where to run it.
func migrateHint(w io.Writer, stateDir string) string {
	projects, err := records.Recorded(stateDir)
	if err != nil {
		report(w, err)
	}
	if len(projects) > 0 {
		return "riotbox session-migrate " + display.QuoteWords(projects...)
	}
	return "riotbox session-migrate from the project's directory (pass every project of a multi-project session)"
}

// report writes err the way the verbs report an error of their own. The bash
// printed the failing tool's message here (rm, mkdir, mktemp, the shell).
func report(w io.Writer, err error) {
	_, _ = fmt.Fprintf(w, "riotbox-core: %v\n", err)
}
