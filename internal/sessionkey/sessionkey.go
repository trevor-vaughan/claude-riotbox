// Package sessionkey computes RiotBox session keys: the on-disk identity of a
// resolved project set. It reproduces the bash in scripts/mount-projects.sh as
// of v0.7.0 byte for byte; testdata/keys.tsv pins that output. The one
// deliberate difference is a newline in a set's first basename (see Identity).
//
// Every function takes already-resolved absolute paths and needs at least one.
// Strings are treated as bytes throughout, matching the bash's LC_ALL=C.
package sessionkey

import (
	"crypto/sha256"
	"encoding/hex"
	"slices"
	"strconv"
	"strings"
)

// maxPrefix leaves room for "-" and the 16-hex hash within NAME_MAX (255).
const maxPrefix = 255 - 17

// canonical is the set the dirs name: sorted bytewise, each path once.
func canonical(dirs []string) []string {
	set := slices.Clone(dirs)
	slices.Sort(set)
	return slices.Compact(set)
}

// SetHash returns the first 16 hex characters of the SHA-256 of the set's
// paths, each followed by a NUL byte. A path cannot contain NUL, so two
// different sets never hash the same input. An empty set is not meaningful.
func SetHash(dirs []string) string {
	var input []byte
	for _, d := range canonical(dirs) {
		input = append(input, d...)
		input = append(input, 0)
	}
	sum := sha256.Sum256(input)
	return hex.EncodeToString(sum[:8])
}

// Identity returns the parts a set's key and container name are built from:
// the sanitized basename of the bytewise-first path, the number of distinct
// paths after it, and SetHash. Sanitizing maps every byte outside
// [a-zA-Z0-9_.-] to "-", squeezes runs of "-" and strips a leading and a
// trailing "-". A newline is such a byte; v0.7.0's per-line sed left it in
// place, which broke the three-line output that bash parsed.
// Panics if dirs is empty.
func Identity(dirs []string) (firstSeg string, nMore int, hash string) {
	set := canonical(dirs)
	return sanitize(basename(set[0])), len(set) - 1, SetHash(set)
}

// Key returns the session key: a readable prefix, "-", and SetHash, or SetHash
// alone when no prefix survives. One project's prefix is its path with "/"
// mapped to "-" and the leading "-" dropped. A set's is
// "<firstSeg>-<nMore>more". Either is cut so the key fits NAME_MAX: a
// project's from the front (then up to its first letter or digit, keeping
// the leaf), a set's firstSeg from its end. Panics if dirs is empty.
//
// A newline in a set's first basename (see Identity) also changes that set's
// key relative to v0.7.0, so a v0.7.0 session for such a set is not found
// under the new key.
func Key(dirs []string) string {
	set := canonical(dirs)
	hash := SetHash(set)
	var prefix string
	if len(set) == 1 {
		prefix = projectPrefix(set[0])
	} else {
		first, nMore, _ := Identity(set)
		suffix := "-" + strconv.Itoa(nMore) + "more"
		if len(first)+len(suffix) > maxPrefix {
			first = first[:maxPrefix-len(suffix)]
		}
		prefix = first + suffix
	}
	if prefix == "" {
		return hash
	}
	return prefix + "-" + hash
}

// projectPrefix reproduces `printf '%s\n' "$p" | sed 's|/|-|g; s|^-||'`
// captured by $(...): sed edits each line separately and $(...) drops every
// trailing newline.
func projectPrefix(p string) string {
	lines := strings.Split(p, "\n")
	for i, line := range lines {
		lines[i] = strings.TrimPrefix(strings.ReplaceAll(line, "/", "-"), "-")
	}
	prefix := strings.TrimRight(strings.Join(lines, "\n"), "\n")
	if len(prefix) <= maxPrefix {
		return prefix
	}
	prefix = prefix[len(prefix)-maxPrefix:]
	for i := 0; i < len(prefix); i++ {
		if isAlnum(prefix[i]) {
			return prefix[i:]
		}
	}
	return ""
}

// basename follows coreutils basename(1): trailing slashes are ignored and a
// path of only slashes is "/".
func basename(p string) string {
	trimmed := strings.TrimRight(p, "/")
	if trimmed == "" {
		if p == "" {
			return ""
		}
		return "/"
	}
	return trimmed[strings.LastIndexByte(trimmed, '/')+1:]
}

func sanitize(s string) string {
	out := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !isAlnum(c) && c != '_' && c != '.' && c != '-' {
			c = '-'
		}
		if c == '-' && len(out) > 0 && out[len(out)-1] == '-' {
			continue
		}
		out = append(out, c)
	}
	return strings.TrimSuffix(strings.TrimPrefix(string(out), "-"), "-")
}

func isAlnum(c byte) bool {
	return 'a' <= c && c <= 'z' || 'A' <= c && c <= 'Z' || '0' <= c && c <= '9'
}
