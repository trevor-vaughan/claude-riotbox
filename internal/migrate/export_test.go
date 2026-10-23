package migrate

import "io"

// MoveLegacy exposes one pair of the pass, as the bash called
// migrate_legacy_state, so specs can check a pair without the marker.
func MoveLegacy(w io.Writer, sessionDir, stateDir string, replaceEmpty bool, legacy, newName string) (bool, error) {
	return moveLegacy(w, sessionDir, stateDir, replaceEmpty, entry{legacy: legacy, new: newName})
}

// MoveOverlay exposes the overlay pair, as the bash called
// migrate_overlay_state.
func MoveOverlay(w io.Writer, libDir, sessionDir, stateDir string, replaceEmpty bool) (bool, error) {
	return moveOverlay(w, libDir, sessionDir, stateDir, replaceEmpty)
}

// SessionStateWith runs SessionState with extra pairs appended to the list,
// as a later release that adds a pair would.
func SessionStateWith(w io.Writer, libDir, sessionDir, stateDir, legacy, newName string) error {
	list := append(append([]entry{}, entries...), entry{legacy: legacy, new: newName})
	return sessionState(w, libDir, sessionDir, stateDir, list)
}

// LegacyNames are the legacy names of the list, in order.
func LegacyNames() []string {
	names := make([]string, len(entries))
	for i, e := range entries {
		names[i] = e.legacy
	}
	return names
}

// ListsEntries exposes dirHasData's guarded open and listing, so specs can
// exercise what a swap after its Lstat check would meet.
var ListsEntries = listsEntries
