package hostlink_test

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gbytes"

	"github.com/trevor-vaughan/claude-riotbox/internal/egress/hostlink"
)

// fakeProxy answers each CONNECT with 200 and then echoes, or with 403
// when its port is refused; it records each request line. A banner follows
// the 200 head in the same write.
type fakeProxy struct {
	mu      sync.Mutex
	lines   []string
	refused int
	banner  string // sent in the same write as the 200 head
}

func (f *fakeProxy) requests() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.lines...)
}

func (f *fakeProxy) start() string {
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
				defer func() { _ = c.Close() }() // the exchange is over; its close result is moot
				r := bufio.NewReader(c)
				first, _ := r.ReadString('\n')
				for {
					line, err := r.ReadString('\n')
					if err != nil || line == "\r\n" {
						break
					}
				}
				first = strings.TrimRight(first, "\r\n")
				f.mu.Lock()
				f.lines = append(f.lines, first)
				refused := f.refused != 0 && strings.Contains(first, fmt.Sprintf(":%d ", f.refused))
				banner := f.banner
				f.mu.Unlock()
				if refused {
					_, _ = io.WriteString(c, "HTTP/1.1 403 Forbidden\r\ncontent-length: 0\r\n\r\n")
					return
				}
				_, _ = io.WriteString(c, "HTTP/1.1 200 OK\r\n\r\n"+banner)
				_, _ = io.Copy(c, r)
				_ = c.(*net.TCPConn).CloseWrite()
			}()
		}
	}()
	return l.Addr().String()
}

var _ = Describe("Listener", func() {
	var (
		ports string
		proxy *fakeProxy
		logs  *gbytes.Buffer
	)

	write := func(lines string) {
		tmp := ports + ".tmp"
		Expect(os.WriteFile(tmp, []byte(lines), 0o600)).To(Succeed())
		Expect(os.Rename(tmp, ports)).To(Succeed())
	}

	BeforeEach(func() {
		ports = filepath.Join(GinkgoT().TempDir(), hostlink.PortsFile)
		proxy = &fakeProxy{}
		logs = gbytes.NewBuffer()
	})

	run := func() {
		ctx, cancel := context.WithCancel(context.Background())
		done := make(chan struct{})
		l := hostlink.Listener{PortsFile: ports, Proxy: proxy.start(), Poll: 10 * time.Millisecond, Log: log.New(logs, "", 0)}
		go func() { l.Run(ctx); close(done) }()
		DeferCleanup(func() { cancel(); Eventually(done).Should(BeClosed()) })
	}

	dial := func(port int) (net.Conn, error) {
		return net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), time.Second)
	}

	// probe dials port and drops the connection at once.
	probe := func(port int) error {
		c, err := dial(port)
		if err == nil {
			err = c.Close()
		}
		return err
	}

	It("tunnels each listed port through the proxy as a CONNECT to the host, half-close included", func() {
		port := freePort()
		write(fmt.Sprintf("%d\n", port))
		run()
		var c net.Conn
		Eventually(func() (err error) { c, err = dial(port); return err }).Should(Succeed())
		DeferCleanup(c.Close)
		Expect(c.SetDeadline(time.Now().Add(10 * time.Second))).To(Succeed())
		Expect(echoThrough(c, c, "ping")).To(Equal("ping"))
		Expect(proxy.requests()).To(ConsistOf(fmt.Sprintf("CONNECT host.containers.internal:%d HTTP/1.1", port)))
	})

	It("passes on bytes the proxy sends in the same write as its answer", func() {
		port := freePort()
		proxy.banner = "hello "
		write(fmt.Sprintf("%d\n", port))
		run()
		var c net.Conn
		Eventually(func() (err error) { c, err = dial(port); return err }).Should(Succeed())
		DeferCleanup(c.Close)
		Expect(c.SetDeadline(time.Now().Add(10 * time.Second))).To(Succeed())
		Expect(echoThrough(c, c, "ping")).To(Equal("hello ping"))
	})

	It("adds a listener for a new port and closes one for a removed port", func() {
		a, b := freePort(), freePort()
		write(fmt.Sprintf("%d\n", a))
		run()
		Eventually(func() error { return probe(a) }).Should(Succeed())
		write(fmt.Sprintf("%d\n", b))
		Eventually(func() error { return probe(b) }).Should(Succeed())
		Eventually(func() error { return probe(a) }).Should(HaveOccurred())
	})

	It("starts with no listeners when the ports file is missing, and picks it up when written", func() {
		port := freePort()
		run()
		Consistently(func() error { return probe(port) }, 50*time.Millisecond).Should(HaveOccurred())
		write(fmt.Sprintf("%d\n", port))
		Eventually(func() error { return probe(port) }).Should(Succeed())
	})

	It("closes the connection, logging why, when the proxy refuses the port", func() {
		port := freePort()
		proxy.refused = port
		write(fmt.Sprintf("%d\n", port))
		run()
		var c net.Conn
		Eventually(func() (err error) { c, err = dial(port); return err }).Should(Succeed())
		DeferCleanup(c.Close)
		Expect(c.SetDeadline(time.Now().Add(10 * time.Second))).To(Succeed())
		got, err := io.ReadAll(c)
		Expect(err).NotTo(HaveOccurred())
		Expect(got).To(BeEmpty())
		Eventually(logs).Should(gbytes.Say(fmt.Sprintf(`port %d: the proxy refused: "HTTP/1.1 403 Forbidden"`, port)))
	})

	It("warns about a busy port and retries it when the file next changes", func() {
		busy, other := freePort(), freePort()
		held, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", busy))
		Expect(err).NotTo(HaveOccurred())
		write(fmt.Sprintf("%d\n", busy))
		run()
		Eventually(logs).Should(gbytes.Say(fmt.Sprintf("WARNING: port %d: .*retrying when the allowlist changes", busy)))
		Expect(held.Close()).To(Succeed())
		write(fmt.Sprintf("%d\n%d\n", busy, other))
		Eventually(logs).Should(gbytes.Say(fmt.Sprintf("port %d: listening", busy)))
	})

	It("gives no listeners for every port, saying how to reach them instead", func() {
		write("1-65535\n")
		run()
		Eventually(logs).Should(gbytes.Say("ports 1-65535: no 127.0.0.1 listeners .*host.containers.internal:PORT"))
	})

	It("keeps its listeners when the ports file turns malformed", func() {
		port := freePort()
		write(fmt.Sprintf("%d\n", port))
		run()
		Eventually(func() error { return probe(port) }).Should(Succeed())
		write("ssh\n")
		Eventually(logs).Should(gbytes.Say("keeping the current listeners"))
		Consistently(func() error { return probe(port) }, 100*time.Millisecond, 10*time.Millisecond).Should(Succeed())
	})
})
