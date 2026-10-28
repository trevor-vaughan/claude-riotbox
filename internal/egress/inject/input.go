package inject

import (
	"bytes"
	"fmt"
	"regexp"
)

var envName = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

// IsEnvName reports whether s is a shell variable name.
func IsEnvName(s string) bool { return envName.MatchString(s) }

// ParseInput splits what riotbox-core egress-up reads on stdin: the
// agent's egress hosts as text, then, when launch.sh has variables to
// pass, one NUL byte and the variables the agent container would get from
// the host, each NAME=VALUE ended by a NUL. launch.sh writes them with
// bash's printf builtin, so no value is on a command line, and a bash
// variable cannot hold a NUL, so neither part can contain one. Anything
// else is an error that names the record by number, never by content (it
// may be a key): a record without its NUL, one that is not NAME=VALUE
// with NAME a shell variable name, and a NAME given twice. Guessing at
// malformed input could inject the wrong key.
func ParseInput(data []byte) (hosts []byte, vars map[string]string, err error) {
	hosts, rest, found := bytes.Cut(data, []byte{0})
	vars = map[string]string{}
	if !found {
		return hosts, vars, nil
	}
	for n := 1; len(rest) > 0; n++ {
		record, after, ok := bytes.Cut(rest, []byte{0})
		if !ok {
			return nil, nil, fmt.Errorf("variable record %d on stdin has no terminating NUL", n)
		}
		name, value, ok := bytes.Cut(record, []byte("="))
		if !ok || !IsEnvName(string(name)) {
			return nil, nil, fmt.Errorf("variable record %d on stdin is not NAME=VALUE", n)
		}
		if _, dup := vars[string(name)]; dup {
			return nil, nil, fmt.Errorf("variable record %d on stdin repeats %s", n, name)
		}
		vars[string(name)] = string(value)
		rest = after
	}
	return hosts, vars, nil
}
