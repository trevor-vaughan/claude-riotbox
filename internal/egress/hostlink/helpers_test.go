package hostlink_test

import (
	"bufio"
	"io"
	"net"
	"os"
	"strings"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

// shortTempDir is a temp dir with a short path: a Unix socket path must
// fit in 108 bytes, which GinkgoT().TempDir() can exceed.
func shortTempDir() string {
	dir, err := os.MkdirTemp("", "hl")
	Expect(err).NotTo(HaveOccurred())
	DeferCleanup(os.RemoveAll, dir)
	return dir
}

// freePort returns a 127.0.0.1 port nothing listens on.
func freePort() int {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	Expect(err).NotTo(HaveOccurred())
	port := l.Addr().(*net.TCPAddr).Port
	Expect(l.Close()).To(Succeed())
	return port
}

// echoServer listens on 127.0.0.1 and copies each connection back to
// itself until EOF, then half-closes it: a peer that half-closes after
// writing reads back exactly what it wrote. It returns the port.
func echoServer() int {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	Expect(err).NotTo(HaveOccurred())
	DeferCleanup(l.Close)
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			go func() {
				defer func() { _ = c.Close() }() // the echo is over; its close result is moot
				_, _ = io.Copy(c, c)
				_ = c.(*net.TCPConn).CloseWrite()
			}()
		}
	}()
	return l.Addr().(*net.TCPAddr).Port
}

// statusLine reads a response head from r and returns its first line.
func statusLine(r *bufio.Reader) string {
	var first string
	for {
		line, err := r.ReadString('\n')
		Expect(err).NotTo(HaveOccurred())
		line = strings.TrimRight(line, "\r\n")
		if line == "" {
			return first
		}
		if first == "" {
			first = line
		}
	}
}

// echoThrough writes msg to c, half-closes it and returns all c then reads.
func echoThrough(c net.Conn, r io.Reader, msg string) string {
	_, err := io.WriteString(c, msg)
	Expect(err).NotTo(HaveOccurred())
	Expect(c.(interface{ CloseWrite() error }).CloseWrite()).To(Succeed())
	got, err := io.ReadAll(r)
	Expect(err).NotTo(HaveOccurred())
	return string(got)
}
