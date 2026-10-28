package policy

import (
	"fmt"
	"regexp"
	"slices"
	"strings"
)

// AgentGroup is the reserved group of the active agent's own hosts: no
// file may define it.
const AgentGroup = "agent"

var (
	// groupName is a group's name, as [group NAME] defines it and @NAME
	// names it.
	groupName   = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,62}$`)
	groupHeader = regexp.MustCompile(`^\[group[ \t]+([^ \t\]]*)[ \t]*\]$`)
)

// Item is one line of an [allow] section, or of the preamble: an entry or
// an @group reference, either one possibly a "-" removal.
type Item struct {
	Entry  Entry  // the entry, when Group is empty
	Group  string // the group @Group names
	Remove bool
	Line   int // the line it was read from; 0 when it was not read from a file
}

// String is the item as a conf file spells it.
func (it Item) String() string {
	s := it.Entry.String()
	if it.Group != "" {
		s = "@" + it.Group
	}
	if it.Remove {
		return "-" + s
	}
	return s
}

// Names reports whether it and o name the same entry or the same group,
// whatever their signs and lines.
func (it Item) Names(o Item) bool {
	if it.Group != "" || o.Group != "" {
		return it.Group == o.Group
	}
	return it.Entry == o.Entry
}

// ParseItem reads one [allow] line: ["-"] entry (see Parse), or ["-"] "@"
// and a group name of lowercase letters, digits and "-" (at most 63,
// starting with a letter or digit).
func ParseItem(raw string) (Item, error) {
	body, remove := strings.CutPrefix(raw, "-")
	if name, isGroup := strings.CutPrefix(body, "@"); isGroup {
		if !groupName.MatchString(name) {
			return Item{}, fmt.Errorf("invalid group name %q: use lowercase letters, digits and -, at most 63", name)
		}
		return Item{Group: name, Remove: remove}, nil
	}
	e, remove, err := Parse(raw)
	if err != nil {
		return Item{}, fmt.Errorf("invalid egress entry %q: %w", raw, err)
	}
	return Item{Entry: e, Remove: remove}, nil
}

// StrictSetting is a file's strict setting.
type StrictSetting int

// The strict settings a file can hold.
const (
	StrictUnset StrictSetting = iota // the file does not set strict
	StrictOn
	StrictOff
)

// String is the setting as a conf file spells it; empty for StrictUnset.
func (s StrictSetting) String() string {
	switch s {
	case StrictOn:
		return "strict = on"
	case StrictOff:
		return "strict = off"
	default:
		return ""
	}
}

// GroupDef is one [group NAME] section.
type GroupDef struct {
	Name    string
	Members []Entry
	Line    int // the header's line
}

// Conf is one egress.conf file as read: its strict setting, the lines of
// its preamble and [allow] sections, in order, and its groups.
type Conf struct {
	Name       string // the file's path, for errors
	Strict     StrictSetting
	StrictLine int
	Items      []Item
	Groups     []GroupDef
}

// The sections a line can be in.
const (
	sectionPreamble = iota
	sectionAllow
	sectionGroup
)

// confParser holds ParseFile's state between lines.
type confParser struct {
	c       Conf
	section int
	defined map[string]int // group name -> its header's line
}

// ParseFile reads an egress.conf file: "#" starts a comment that runs to
// the end of the line, blank lines are skipped, and the rest is a preamble
// of settings and [allow] lines, then [allow] and [group NAME] sections
// (docs/dev/egress.md#egressconf-grammar). A file without sections, as
// every egress.conf was before sections existed, is all preamble. name is
// the file's path; every error reads "<name>:<line>: <reason>". An @
// reference is checked here only for its spelling: whether the group
// exists is up to Resolve, which knows every file's groups.
func ParseFile(name string, data []byte) (Conf, error) {
	p := confParser{c: Conf{Name: name}, defined: map[string]int{}}
	for i, line := range strings.Split(string(data), "\n") {
		if j := strings.IndexByte(line, '#'); j >= 0 {
			line = line[:j]
		}
		line = strings.Trim(line, " \t\r")
		if line == "" {
			continue
		}
		if err := p.line(i+1, line); err != nil {
			return Conf{}, err
		}
	}
	if err := p.endGroup(); err != nil {
		return Conf{}, err
	}
	return p.c, nil
}

func (p *confParser) errorf(n int, format string, args ...any) error {
	return fmt.Errorf("%s:%d: %s", p.c.Name, n, fmt.Sprintf(format, args...))
}

// line reads line n, already stripped of its comment and trimmed.
func (p *confParser) line(n int, line string) error {
	if strings.HasPrefix(line, "[") {
		return p.header(n, line)
	}
	if key, value, ok := cutSetting(line); ok {
		return p.setting(n, key, value)
	}
	if p.section == sectionGroup {
		return p.member(n, line)
	}
	it, err := ParseItem(line)
	if err != nil {
		return fmt.Errorf("%s:%d: %w", p.c.Name, n, err)
	}
	it.Line = n
	p.c.Items = append(p.c.Items, it)
	return nil
}

func (p *confParser) header(n int, line string) error {
	if err := p.endGroup(); err != nil {
		return err
	}
	if line == "[allow]" {
		p.section = sectionAllow
		return nil
	}
	m := groupHeader.FindStringSubmatch(line)
	if m == nil {
		return p.errorf(n, "unknown section %q (use [allow] or [group NAME])", line)
	}
	name := m[1]
	if name == AgentGroup {
		return p.errorf(n, "@agent is reserved: it is the active agent's own hosts")
	}
	if !groupName.MatchString(name) {
		return p.errorf(n, "invalid group name %q: use lowercase letters, digits and -, at most 63", name)
	}
	if first, dup := p.defined[name]; dup {
		return p.errorf(n, "group %s is already defined on line %d", name, first)
	}
	p.defined[name] = n
	p.c.Groups = append(p.c.Groups, GroupDef{Name: name, Line: n})
	p.section = sectionGroup
	return nil
}

func (p *confParser) setting(n int, key, value string) error {
	if key != "strict" {
		return p.errorf(n, "unknown setting %q (the only setting is strict)", key)
	}
	if p.section != sectionPreamble {
		return p.errorf(n, "the strict setting must come before the first [section]")
	}
	switch value {
	case "on":
		p.c.Strict = StrictOn
	case "off":
		p.c.Strict = StrictOff
	default:
		return p.errorf(n, "strict must be on or off, not %q", value)
	}
	p.c.StrictLine = n
	return nil
}

func (p *confParser) member(n int, line string) error {
	if strings.HasPrefix(line, "-") || strings.HasPrefix(line, "@") {
		return p.errorf(n, "a group lists hosts only: %q has a - or @", line)
	}
	e, _, err := Parse(line)
	if err != nil {
		return fmt.Errorf("%s:%d: invalid egress entry %q: %w", p.c.Name, n, line, err)
	}
	g := &p.c.Groups[len(p.c.Groups)-1]
	if !slices.Contains(g.Members, e) {
		g.Members = append(g.Members, e)
	}
	return nil
}

// endGroup fails when the [group] section that is ending has no members.
func (p *confParser) endGroup() error {
	if p.section != sectionGroup {
		return nil
	}
	if g := p.c.Groups[len(p.c.Groups)-1]; len(g.Members) == 0 {
		return p.errorf(g.Line, "group %s has no members", g.Name)
	}
	return nil
}

// cutSetting splits a setting line: "key = value", or the bare word
// strict, which means strict = on. No entry holds "=" and no bare word is
// an entry, so this cannot mistake an entry for a setting.
func cutSetting(line string) (key, value string, ok bool) {
	if k, v, found := strings.Cut(line, "="); found {
		return strings.Trim(k, " \t"), strings.Trim(v, " \t"), true
	}
	if line == "strict" {
		return "strict", "on", true
	}
	return "", "", false
}

// IsStrictLine reports whether line, stripped of its comment and trimmed,
// sets strict, whatever its value: the lines SaveStrict replaces.
func IsStrictLine(line string) bool {
	key, _, ok := cutSetting(line)
	return ok && key == "strict"
}

// ParseList reads a plain list of entries, one per line, as agent.conf
// and applied.conf hold: ParseFile's grammar restricted to host entries:
// no settings, no [group] sections, no group references or removals. An
// [allow] header, which changes nothing, is tolerated.
func ParseList(name string, data []byte) ([]Entry, error) {
	c, err := ParseFile(name, data)
	if err != nil {
		return nil, err
	}
	if c.Strict != StrictUnset {
		return nil, fmt.Errorf("%s:%d: a setting is not allowed here", name, c.StrictLine)
	}
	if len(c.Groups) > 0 {
		return nil, fmt.Errorf("%s:%d: a section is not allowed here", name, c.Groups[0].Line)
	}
	entries := make([]Entry, 0, len(c.Items))
	for _, it := range c.Items {
		if it.Group != "" || it.Remove {
			return nil, fmt.Errorf("%s:%d: only host entries are allowed here, not %s", name, it.Line, it)
		}
		entries = append(entries, it.Entry)
	}
	return entries, nil
}
