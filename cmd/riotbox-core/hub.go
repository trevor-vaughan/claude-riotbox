package main

import (
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/mdp/qrterminal/v4"
	"golang.org/x/term"

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
	drawQR(link, stderr)
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

// printHubLink prints the link make returns, alone on stdout, and draws it
// as a QR code on a terminal's stderr.
func printHubLink(mint func() (string, error), stdout, stderr io.Writer) int {
	link, err := mint()
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "riotbox-core: hub: %v\n", err)
		return 1
	}
	if _, err := fmt.Fprintln(stdout, link); err != nil {
		return written(err, stderr)
	}
	drawQR(link, stderr)
	return 0
}

// drawQR draws link as a QR code, for a phone camera, when stderr is a
// terminal. On a pipe or the service's journal it draws nothing, and stdout
// keeps the link alone for scripts. GenerateHalfBlock, unlike Generate, does
// not probe the terminal for sixel support by writing to stdout and reading
// stdin. The link (an IP literal, a port and a 43-character token) is far
// below a QR code's capacity, the one case in which qrterminal panics.
func drawQR(link string, stderr io.Writer) {
	f, ok := stderr.(*os.File)
	if !ok || !term.IsTerminal(int(f.Fd())) {
		return
	}
	qrterminal.GenerateHalfBlock(link, qrterminal.L, stderr)
}
