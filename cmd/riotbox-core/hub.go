package main

import (
	"fmt"
	"io"

	"github.com/trevor-vaughan/claude-riotbox/internal/hub"
)

// hubServe is `riotbox hub`: print the link (with its token) and serve the
// session list until the process is killed. libexec/hub.sh has already
// validated --listen as an IP literal and a port.
func hubServe(a parsedArgs, stdout, stderr io.Writer) int {
	s := &hub.Server{
		Addr:    a.opts["--listen"],
		DataDir: a.opts["--data-dir"],
		Lister:  hub.Lister{Engine: a.opts["--engine"], StateRoot: a.opts["--state-root"]},
	}
	link, cert, err := s.Prepare()
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "riotbox-core: hub: %v\n", err)
		return 1
	}
	if _, err := fmt.Fprintf(stdout, "RiotBox hub: %s\n", link); err != nil {
		return written(err, stderr)
	}
	if err := s.Serve(cert); err != nil {
		_, _ = fmt.Fprintf(stderr, "riotbox-core: hub: %v\n", err)
		return 1
	}
	return 0
}
