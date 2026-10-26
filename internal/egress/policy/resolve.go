package policy

import (
	"fmt"
	"slices"
	"strings"
)

// Where a group's definition, or the strict setting, comes from.
const (
	SourceBuiltin = "built-in"
	SourceSystem  = "system conf"
	SourceUser    = "user conf"
	SourceSession = "session"
	SourceAgent   = "agent"
	SourceDefault = "default"
)

// Sources is what a session's allowlist is resolved from.
type Sources struct {
	Agent        []Entry // the active agent's hosts (agent.conf): @agent
	System, User Conf    // the egress.conf files; a zero Conf for a missing file
	Overlay      Conf    // session.conf, which riotbox egress writes
}

// Resolved is a session's allowlist and how it came about.
type Resolved struct {
	Entries    []Entry // the allowlist, each entry once, sorted
	Strict     bool
	StrictFrom string           // SourceSession, SourceUser, SourceSystem or SourceDefault
	Groups     map[string]Group // the table @ references resolved against
}

// Resolve computes a session's allowlist (docs/dev/egress.md#resolution):
//
//  1. the group table (Groups);
//  2. strict: the overlay's setting, else the user file's, else the
//     system file's, else off;
//  3. every addition of the system and user files, plus @registries and
//     @agent unless strict is on, minus every removal in either file (a
//     removal wins whichever file it is in); -@g removes each member of g;
//  4. the overlay's lines on top, in file order, so a live allow re-allows
//     what a file removed and the latest allow or deny of a host wins.
//
// It fails, naming the file and line, on an @ reference to no group and
// on a group defined in the overlay.
func Resolve(s Sources) (Resolved, error) {
	if len(s.Overlay.Groups) > 0 {
		return Resolved{}, fmt.Errorf("%s:%d: a session overlay cannot define groups", s.Overlay.Name, s.Overlay.Groups[0].Line)
	}
	r := Resolved{Groups: Groups(s.Agent, s.System, s.User), StrictFrom: SourceDefault}
	for _, f := range []struct {
		conf   Conf
		source string
	}{{s.System, SourceSystem}, {s.User, SourceUser}, {s.Overlay, SourceSession}} {
		if f.conf.Strict != StrictUnset {
			r.Strict, r.StrictFrom = f.conf.Strict == StrictOn, f.source
		}
	}
	var add, remove []Entry
	if !r.Strict {
		add = slices.Concat(r.Groups["registries"].Members, r.Groups[AgentGroup].Members)
	}
	for _, c := range []Conf{s.System, s.User} {
		for _, it := range c.Items {
			entries, err := r.expand(c.Name, it)
			if err != nil {
				return Resolved{}, err
			}
			if it.Remove {
				remove = append(remove, entries...)
			} else {
				add = append(add, entries...)
			}
		}
	}
	r.Entries = merge(add, remove)
	for _, it := range s.Overlay.Items {
		entries, err := r.expand(s.Overlay.Name, it)
		if err != nil {
			return Resolved{}, err
		}
		if it.Remove {
			r.Entries = merge(r.Entries, entries)
		} else {
			r.Entries = merge(slices.Concat(r.Entries, entries), nil)
		}
	}
	return r, nil
}

// expand returns the entries it names: its entry, or its group's members.
// file is where it was read, for the error when it names no group.
func (r Resolved) expand(file string, it Item) ([]Entry, error) {
	if it.Group == "" {
		return []Entry{it.Entry}, nil
	}
	g, ok := r.Groups[it.Group]
	if !ok {
		return nil, &UnknownGroupError{File: file, Line: it.Line, Group: it.Group}
	}
	return g.Members, nil
}

// UnknownGroupError is Resolve's error for an @ reference to no group, so
// a caller can say how to get rid of the line.
type UnknownGroupError struct {
	File  string // the file the reference was read from
	Line  int
	Group string
}

func (e *UnknownGroupError) Error() string {
	return fmt.Sprintf("%s:%d: no group named @%s (riotbox egress groups lists them)", e.File, e.Line, e.Group)
}

// StrictLabel is the strict setting as riotbox egress list shows it, e.g.
// "on (user conf)" or "off (default)".
func (r Resolved) StrictLabel() string {
	state := "off"
	if r.Strict {
		state = "on"
	}
	return state + " (" + r.StrictFrom + ")"
}

// Allows reports whether entries let e through: e itself is listed, or a
// wildcard on its port matches it.
func Allows(entries []Entry, e Entry) bool {
	return slices.Contains(entries, e) || len(Covering(entries, e)) > 0
}

// LockoutWarning is what to print when strict mode leaves out any of the
// agent's own hosts, so the agent cannot reach its API; "" when it does
// not. It is a warning, not a refusal: the user may intend it.
func (r Resolved) LockoutWarning() string {
	if !r.Strict {
		return ""
	}
	var missing []string
	for _, e := range r.Groups[AgentGroup].Members {
		if !Allows(r.Entries, e) {
			missing = append(missing, e.String())
		}
	}
	if len(missing) == 0 {
		return ""
	}
	return "WARNING: strict mode does not allow the agent's own API hosts (" + strings.Join(missing, ", ") + "); add @agent"
}
