// Command riotbox-core is the compiled half of RiotBox's host-side core. The
// bash CLI calls it as a subprocess, one verb per call; see
// docs/dev/riotbox-core.md for the contract.
package main

import (
	"fmt"
	"io"
	"os"
	"slices"
	"strings"

	"github.com/trevor-vaughan/claude-riotbox/internal/display"
	"github.com/trevor-vaughan/claude-riotbox/internal/engine"
	"github.com/trevor-vaughan/claude-riotbox/internal/migrate"
	"github.com/trevor-vaughan/claude-riotbox/internal/records"
	"github.com/trevor-vaughan/claude-riotbox/internal/sessionkey"
)

// version is set at build time with -ldflags "-X main.version=<VERSION>".
var version = "dev"

const usage = `usage: riotbox-core <verb> [--option <value>]... [--] [arg]...

Each option takes the next argument as its value, whatever it starts with. Options in [brackets] may be left out.
Positional arguments follow the options; put -- before them when the first
may start with a dash.

verbs:
  version                print the build version
  session-key <dir>...   print the session key of a resolved project set
  set-identity <dir>...  print a set's first_seg, n_more and hash, one per line
  recorded-projects <state-dir>
                         print the launch's project record; exit 1 if none
  session-projects <session-dir>
                         print the session's .projects list; exit 1 if none
  is-session <session-dir> <state-dir>
                         exit 0 if the dir is a RiotBox session, 1 if not
  same-project-set <list> <list>
                         exit 0 if two newline-separated path lists name
                         the same set, 1 if not
  overlay-scan --lib-dir <dir> --engine <engine> <overlay-dir> <project-dir>
                         print the overlay's holders and the project's
                         sharers as NUL-terminated records; exit 1 if the
                         engine cannot answer
  migrate-state --lib-dir <dir> <session-dir> <state-dir>
                         move the state an older RiotBox left in the session
                         dir to the state dir, once per pair; exit 1 on failure
  migrate-failed --lib-dir <dir> --engine <engine> <session-dir> <state-dir>
                         retry the pairs recorded as failed (session-migrate);
                         exit 1 if any is still stranded or a step failed
  migrate-all --lib-dir <dir> <data-dir> <state-root>
                         under the state root's lock, migrate-state every
                         session under the data dir; exit 1 if one fails
  headroom-notice --lib-dir <dir> <project-dir> <state-dir>
                         once per session, tell about headroom memory an older
                         RiotBox left; exit 1 if the check cannot be recorded
  migrate-key --lib-dir <dir> --engine <engine> --data-dir <dir>
              --state-root <dir> [--legacy-key <key>]... <dir>...
                         move the set's session from an old key to its own;
                         exit 1 if a move or the running check fails
  egress-up --engine <engine> --state-root <dir> --system-conf <file>
            --user-conf <file> --image <ref> --session-key <key>
            --owner-pid <pid> [--project <dir>]... <name>
                         start the session's egress proxy pod, reading the
                         agent's hosts on stdin, then optionally a NUL and
                         the agent's variables as NUL-terminated NAME=VALUE
                         records (1 MiB in all), whose provider keys the
                         proxy injects, keeping them in
                         $XDG_RUNTIME_DIR/riotbox-egress (else
                         /run/user/<uid>/riotbox-egress), which must be a
                         private tmpfs when there are any; record the
                         project dirs for egress-list; print the agent's
                         engine flags, one per line; exit 1 on failure
  egress-down --engine <engine> --state-root <dir> <name>
                         remove the session's egress pod, networks and
                         secrets and report denied requests; exit 1 if a
                         step failed
  egress-sweep --engine <engine> --state-root <dir>
                         remove egress pods whose launch is gone, their
                         secrets after an hour unused, and state dirs
                         unused for 7 days
  egress-list --engine <engine> --state-root <dir>
                         print each running egress session's start, owner
                         PID, projects, log, strict setting, injected keys
                         and allowlist
  egress-allow --engine <engine> --state-root <dir> --system-conf <file>
               --user-conf <file> [--session <name>] [--save-to <file>]
               <entry | @group>
  egress-deny  (same options)
                         allow or deny an entry or a group in a running
                         session, live; --save-to (the --system-conf or
                         --user-conf file) also records it there,
                         replacing any line for it
  egress-strict --engine <engine> --state-root <dir> --system-conf <file>
                --user-conf <file> [--session <name>] [--save-to <file>]
                <on | off | clear>
                         set or clear a running session's strict setting,
                         live; --save-to (the --system-conf or --user-conf
                         file) also sets or removes it there
  egress-groups --engine <engine> --state-root <dir> --system-conf <file>
                --user-conf <file>
                         print every group, where it is defined and its
                         hosts; @agent once per running session
  egress-reload --engine <engine> --state-root <dir> --system-conf <file>
                --user-conf <file> [--session <name>]
                         re-read the conf files into the named session, or
                         every running one
`

// unbounded is a verb's maxArgs when it takes any number of positionals.
const unbounded = -1

// verb is one entry of the dispatch table: the options it takes, how many
// positionals, and what it runs once parseArgs has checked both.
type verb struct {
	options  []string // each must be given exactly once
	optional []string // each may be given at most once
	repeated []string // each may be given any number of times
	minArgs  int
	maxArgs  int // or unbounded
	run      func(a parsedArgs, stdout, stderr io.Writer) int
}

// parsedArgs is a verb's command line once parseArgs has checked it.
type parsedArgs struct {
	opts  map[string]string   // the value of each of verb.options and of each verb.optional given
	multi map[string][]string // the values of each of verb.repeated, in order
	args  []string            // the positionals
}

var verbs = map[string]verb{
	"version": {run: func(_ parsedArgs, stdout, stderr io.Writer) int {
		_, err := fmt.Fprintln(stdout, version)
		return written(err, stderr)
	}},
	"session-key": {minArgs: 1, maxArgs: unbounded, run: func(a parsedArgs, stdout, stderr io.Writer) int {
		_, err := fmt.Fprintln(stdout, sessionkey.Key(a.args))
		return written(err, stderr)
	}},
	"set-identity": {minArgs: 1, maxArgs: unbounded, run: func(a parsedArgs, stdout, stderr io.Writer) int {
		first, nMore, hash := sessionkey.Identity(a.args)
		_, err := fmt.Fprintf(stdout, "%s\n%d\n%s\n", first, nMore, hash)
		return written(err, stderr)
	}},
	"recorded-projects": {minArgs: 1, maxArgs: 1, run: func(a parsedArgs, stdout, stderr io.Writer) int {
		lines, err := records.Recorded(a.args[0])
		if err != nil {
			_, _ = fmt.Fprintf(stderr, "riotbox-core: %v\n", err)
			return 1
		}
		return printLines(lines, stdout, stderr)
	}},
	"session-projects": {minArgs: 1, maxArgs: 1, run: func(a parsedArgs, stdout, stderr io.Writer) int {
		// The bash ran dd with 2>/dev/null: a .projects the container made
		// unreadable is reported only as "no list".
		lines, _ := records.SessionProjects(a.args[0])
		return printLines(lines, stdout, stderr)
	}},
	"is-session": {minArgs: 2, maxArgs: 2, run: func(a parsedArgs, _, _ io.Writer) int {
		return exitCode(records.IsSession(a.args[0], a.args[1]))
	}},
	"same-project-set": {minArgs: 2, maxArgs: 2, run: func(a parsedArgs, _, _ io.Writer) int {
		return exitCode(records.SameSet(a.args[0], a.args[1]))
	}},
	"overlay-scan": {options: []string{"--lib-dir", "--engine"}, minArgs: 2, maxArgs: 2, run: overlayScan},
	"migrate-state": {options: []string{"--lib-dir"}, minArgs: 2, maxArgs: 2, run: func(a parsedArgs, _, stderr io.Writer) int {
		return failed(migrate.SessionState(stderr, a.opts["--lib-dir"], a.args[0], a.args[1]))
	}},
	"migrate-failed": {options: []string{"--lib-dir", "--engine"}, minArgs: 2, maxArgs: 2, run: func(a parsedArgs, stdout, stderr io.Writer) int {
		return failed(migrate.FailedState(stdout, stderr, a.opts["--engine"], a.opts["--lib-dir"], a.args[0], a.args[1]))
	}},
	"migrate-all": {options: []string{"--lib-dir"}, minArgs: 2, maxArgs: 2, run: func(a parsedArgs, _, stderr io.Writer) int {
		return failed(migrate.AllSessions(stderr, a.opts["--lib-dir"], a.args[0], a.args[1]))
	}},
	"headroom-notice": {options: []string{"--lib-dir"}, minArgs: 2, maxArgs: 2, run: func(a parsedArgs, _, stderr io.Writer) int {
		return failed(migrate.HeadroomNotice(stderr, a.opts["--lib-dir"], a.args[0], a.args[1]))
	}},
	"migrate-key": {
		options:  []string{"--lib-dir", "--engine", "--data-dir", "--state-root"},
		repeated: []string{"--legacy-key"},
		minArgs:  1, maxArgs: unbounded,
		run: migrateKey,
	},
	"egress-up": {
		options:  []string{"--engine", "--state-root", "--system-conf", "--user-conf", "--image", "--session-key", "--owner-pid"},
		repeated: []string{"--project"},
		minArgs:  1, maxArgs: 1,
		run: egressUp,
	},
	"egress-down":   {options: []string{"--engine", "--state-root"}, minArgs: 1, maxArgs: 1, run: egressDown},
	"egress-sweep":  {options: []string{"--engine", "--state-root"}, run: egressSweep},
	"egress-list":   {options: []string{"--engine", "--state-root"}, run: egressList},
	"egress-allow":  {options: egressConfOptions, optional: []string{"--session", "--save-to"}, minArgs: 1, maxArgs: 1, run: egressEdit("egress-allow", false)},
	"egress-deny":   {options: egressConfOptions, optional: []string{"--session", "--save-to"}, minArgs: 1, maxArgs: 1, run: egressEdit("egress-deny", true)},
	"egress-strict": {options: egressConfOptions, optional: []string{"--session", "--save-to"}, minArgs: 1, maxArgs: 1, run: egressStrict},
	"egress-groups": {options: egressConfOptions, run: egressGroups},
	"egress-reload": {options: egressConfOptions, optional: []string{"--session"}, run: egressReload},
}

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

// run dispatches one verb and returns the exit code: 0 on success, 1 on
// failure (including a failed write to stdout, e.g. ENOSPC), 2 on bad usage.
// The list verbs also exit 1 when there is no list, as their bash functions
// return 1.
func run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		return badUsage(stderr)
	}
	v, ok := verbs[args[0]]
	if !ok {
		return badUsage(stderr)
	}
	parsed, ok := parseArgs(v, args[1:])
	if !ok {
		return badUsage(stderr)
	}
	return v.run(parsed, stdout, stderr)
}

// parseArgs is the one argument parser every verb shares. Options come
// first; each takes the next argument as its value verbatim, so a value
// that starts with a dash is never read as an option. The positionals start
// at the first argument that does not start with a dash, or after a "--",
// which lets a positional start with a dash. It reports false for an
// unknown option, an option the verb does not take, one of v.options or
// v.optional repeated, one of v.options missing, an option without a value,
// or a positional count outside v's bounds.
func parseArgs(v verb, args []string) (parsedArgs, bool) {
	p := parsedArgs{opts: map[string]string{}, multi: map[string][]string{}}
	for len(args) > 0 && strings.HasPrefix(args[0], "-") {
		name := args[0]
		if name == "--" {
			args = args[1:]
			break
		}
		if len(args) < 2 {
			return parsedArgs{}, false
		}
		value := args[1]
		args = args[2:]
		switch {
		case slices.Contains(v.repeated, name):
			p.multi[name] = append(p.multi[name], value)
		case slices.Contains(v.options, name) || slices.Contains(v.optional, name):
			if _, seen := p.opts[name]; seen {
				return parsedArgs{}, false
			}
			p.opts[name] = value
		default:
			return parsedArgs{}, false
		}
	}
	required := 0
	for _, name := range v.options {
		if _, ok := p.opts[name]; ok {
			required++
		}
	}
	if required != len(v.options) || len(args) < v.minArgs || (v.maxArgs != unbounded && len(args) > v.maxArgs) {
		return parsedArgs{}, false
	}
	p.args = args
	return p, true
}

// written maps the error of writing a verb's output to its exit code,
// saying why on stderr when the write failed.
func written(err error, stderr io.Writer) int {
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "riotbox-core: writing output: %v\n", err)
		return 1
	}
	return 0
}

// printLines writes each line and a newline, and returns 1 when there are
// none or the write fails, 0 otherwise.
func printLines(lines []string, stdout, stderr io.Writer) int {
	if len(lines) == 0 {
		return 1
	}
	for _, line := range lines {
		if _, err := fmt.Fprintln(stdout, line); err != nil {
			return written(err, stderr)
		}
	}
	return 0
}

// overlayScan prints engine.OverlayUsers as records of two NUL-terminated
// fields: "holder" and a container's label, or "sharer" and "<label>
// <source>". It prints nothing and returns 1 when the engine cannot answer.
func overlayScan(a parsedArgs, stdout, stderr io.Writer) int {
	holders, sharers, err := engine.OverlayUsers(a.opts["--engine"], a.opts["--lib-dir"], a.args[0], a.args[1], stderr)
	if err != nil {
		return 1
	}
	var out []byte
	for _, h := range holders {
		out = append(out, "holder\x00"+h+"\x00"...)
	}
	for _, s := range sharers {
		out = append(out, "sharer\x00"+s+"\x00"...)
	}
	_, err = stdout.Write(out)
	return written(err, stderr)
}

// migrateKey checks migrate-key's legacy keys and runs migrate.SessionKey.
func migrateKey(a parsedArgs, _, stderr io.Writer) int {
	legacyKeys := a.multi["--legacy-key"]
	for _, key := range legacyKeys {
		// A key names one entry under the data dir and the state root;
		// anything else would point at either root itself or outside it.
		// The same rule as valid_session_key in
		// scripts/lib/session-state.sh; change both together.
		if key == "" || key == "." || key == ".." || strings.Contains(key, "/") {
			_, _ = fmt.Fprintf(stderr, "riotbox-core: migrate-key: --legacy-key %s is not a session key: it must be one path component, not empty, . or ..\n", display.Quote(key))
			return badUsage(stderr)
		}
	}
	return failed(migrate.SessionKey(stderr, a.opts["--engine"], a.opts["--lib-dir"], a.opts["--data-dir"], a.opts["--state-root"], legacyKeys, a.args))
}

// exitCode maps a yes/no answer to exit 0 or 1.
func exitCode(yes bool) int {
	if yes {
		return 0
	}
	return 1
}

// failed maps the result of a verb that has already said why it failed.
func failed(err error) int {
	if err != nil {
		return 1
	}
	return 0
}

func badUsage(stderr io.Writer) int {
	_, _ = fmt.Fprint(stderr, usage)
	return 2
}
