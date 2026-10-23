// Command riotbox-core is the compiled half of RiotBox's host-side core. The
// bash CLI calls it as a subprocess, one verb per call; see
// docs/dev/riotbox-core.md for the contract.
package main

import (
	"fmt"
	"io"
	"os"

	"github.com/trevor-vaughan/claude-riotbox/internal/sessionkey"
)

// version is set at build time with -ldflags "-X main.version=<VERSION>".
var version = "dev"

const usage = `usage: riotbox-core <verb> [args]

verbs:
  version                print the build version
  session-key <dir>...   print the session key of a resolved project set
  set-identity <dir>...  print a set's first_seg, n_more and hash, one per line
`

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

// run dispatches one verb and returns the exit code: 0 on success, 1 when
// writing to stdout returns an error (e.g. ENOSPC), 2 on bad usage.
func run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		return badUsage(stderr)
	}
	verb, rest := args[0], args[1:]
	var err error
	switch {
	case verb == "version" && len(rest) == 0:
		_, err = fmt.Fprintln(stdout, version)
	case verb == "session-key" && len(rest) > 0:
		_, err = fmt.Fprintln(stdout, sessionkey.Key(rest))
	case verb == "set-identity" && len(rest) > 0:
		first, nMore, hash := sessionkey.Identity(rest)
		_, err = fmt.Fprintf(stdout, "%s\n%d\n%s\n", first, nMore, hash)
	default:
		return badUsage(stderr)
	}
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "riotbox-core: writing output: %v\n", err)
		return 1
	}
	return 0
}

func badUsage(stderr io.Writer) int {
	_, _ = fmt.Fprint(stderr, usage)
	return 2
}
