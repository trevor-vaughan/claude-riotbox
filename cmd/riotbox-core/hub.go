package main

import (
	"errors"
	"fmt"
	"io"

	"github.com/trevor-vaughan/claude-riotbox/internal/hub"
)

// hubServe is `riotbox hub`: print the link (with its token) and serve the
// session list and proxy the sessions until the process is killed.
// libexec/hub.sh has already validated --listen as an IP literal and a port.
func hubServe(a parsedArgs, stdout, stderr io.Writer) int {
	s := &hub.Server{
		Addr:    a.opts["--listen"],
		DataDir: a.opts["--data-dir"],
		Lister:  hub.Lister{Engine: a.opts["--engine"], StateRoot: a.opts["--state-root"]},
		Stderr:  stderr,
	}
	link, cert, err := s.Prepare()
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "riotbox-core: hub: %v\n", err)
		return 1
	}
	ln, err := s.Listen()
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "riotbox-core: hub: %v\n", err)
		return 1
	}
	if _, err := fmt.Fprintf(stdout, "RiotBox hub: %s\n", link); err != nil {
		return written(errors.Join(err, ln.Close()), stderr)
	}
	if err := s.Serve(ln, cert); err != nil {
		_, _ = fmt.Fprintf(stderr, "riotbox-core: hub: %v\n", err)
		return 1
	}
	return 0
}

// hubLink is `riotbox hub link`: print the hub's link, creating the token
// when there is none. It does not need a running hub.
func hubLink(a parsedArgs, stdout, stderr io.Writer) int {
	s := &hub.Server{Addr: a.opts["--listen"], DataDir: a.opts["--data-dir"]}
	return printHubLink(s.Link, stdout, stderr)
}

// hubNewToken is `riotbox hub new-token`: replace the token and print the
// new link. A running hub takes the new token from its next request.
func hubNewToken(a parsedArgs, stdout, stderr io.Writer) int {
	s := &hub.Server{Addr: a.opts["--listen"], DataDir: a.opts["--data-dir"]}
	return printHubLink(s.NewToken, stdout, stderr)
}

// printHubLink prints the link make returns, alone on stdout.
func printHubLink(mint func() (string, error), stdout, stderr io.Writer) int {
	link, err := mint()
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "riotbox-core: hub: %v\n", err)
		return 1
	}
	_, err = fmt.Fprintln(stdout, link)
	return written(err, stderr)
}
