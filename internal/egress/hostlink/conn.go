package hostlink

import (
	"bufio"
	"errors"
	"io"
	"net"
	"strings"
	"sync"
)

var errHeadTooLong = errors.New("the head is longer than 8 KiB")

// readHead reads an HTTP/1 head from r, which must be a bufio.Reader of
// at least maxHead bytes: its lines without their line ends, up to the
// blank line. It refuses a head of more than maxHead bytes.
func readHead(r *bufio.Reader) ([]string, error) {
	var lines []string
	n := 0
	for {
		line, err := r.ReadSlice('\n')
		n += len(line)
		if n > maxHead || errors.Is(err, bufio.ErrBufferFull) {
			return nil, errHeadTooLong
		}
		if err != nil {
			return nil, err
		}
		s := strings.TrimSuffix(strings.TrimSuffix(string(line), "\n"), "\r")
		if s == "" {
			return lines, nil
		}
		lines = append(lines, s)
	}
}

// pipe copies aIn (a's reader, which may hold bytes buffered past a head)
// to b and bIn to a until both directions end, half-closing each
// destination when its source ends, so a client that shuts down its
// sending side still gets the reply. It then closes both and returns the
// bytes copied each way. A copy error ends its direction as EOF does: the
// peer sees the half-close or the close.
func pipe(a net.Conn, aIn io.Reader, b net.Conn, bIn io.Reader) (aToB, bToA int64) {
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		aToB, _ = io.Copy(b, aIn)
		closeWrite(b)
	}()
	bToA, _ = io.Copy(a, bIn)
	closeWrite(a)
	wg.Wait()
	_ = a.Close()
	_ = b.Close()
	return aToB, bToA
}

// closeWrite shuts down c's sending side, or closes c when it cannot
// half-close. The connection is ending either way, so its error changes
// nothing.
func closeWrite(c net.Conn) {
	if cw, ok := c.(interface{ CloseWrite() error }); ok {
		_ = cw.CloseWrite()
		return
	}
	_ = c.Close()
}
