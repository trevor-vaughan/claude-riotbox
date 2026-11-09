package hostlink_test

import (
	"bufio"
	"fmt"
	"log"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gbytes"

	"github.com/trevor-vaughan/claude-riotbox/internal/egress/hostlink"
)

var _ = Describe("Relay", func() {
	var (
		socket, ports string
		logs          *gbytes.Buffer
	)

	BeforeEach(func() {
		dir := shortTempDir()
		socket = filepath.Join(dir, "relay.sock")
		ports = filepath.Join(dir, hostlink.PortsFile)
		logs = gbytes.NewBuffer()
		l, err := net.Listen("unix", socket)
		Expect(err).NotTo(HaveOccurred())
		r := hostlink.Relay{PortsFile: ports, Target: "127.0.0.1", Log: log.New(logs, "", 0)}
		done := make(chan error, 1)
		go func() { done <- r.Serve(l) }()
		DeferCleanup(func() {
			Expect(l.Close()).To(Succeed())
			Eventually(done).Should(Receive(BeNil()))
		})
	})

	allow := func(lines string) { Expect(os.WriteFile(ports, []byte(lines), 0o600)).To(Succeed()) }

	// connect sends head to the relay and returns the connection, a reader
	// past the response head, and the status line.
	connect := func(head string) (net.Conn, *bufio.Reader, string) {
		c, err := net.Dial("unix", socket)
		Expect(err).NotTo(HaveOccurred())
		DeferCleanup(c.Close)
		Expect(c.SetDeadline(time.Now().Add(10 * time.Second))).To(Succeed())
		_, err = c.Write([]byte(head))
		Expect(err).NotTo(HaveOccurred())
		r := bufio.NewReader(c)
		return c, r, statusLine(r)
	}
	// Envoy's form of a passed-on CONNECT.
	envoyConnect := func(authority string) string {
		return "CONNECT " + authority + " HTTP/1.1\r\nhost: " + authority + "\r\nx-forwarded-proto: http\r\nx-request-id: 1\r\n\r\n"
	}

	It("tunnels an allowed port both ways, half-close included, and logs it", func() {
		port := echoServer()
		allow(fmt.Sprintf("%d\n", port))
		c, r, status := connect(envoyConnect(fmt.Sprintf("host.containers.internal:%d", port)))
		Expect(status).To(Equal("HTTP/1.1 200 Connection established"))
		Expect(echoThrough(c, r, "ping")).To(Equal("ping"))
		Eventually(logs).Should(gbytes.Say(fmt.Sprintf("port %d: 200, 4 bytes sent, 4 received", port)))
	})

	It("passes on bytes that arrive in the same write as the head", func() {
		port := echoServer()
		allow(fmt.Sprintf("%d\n", port))
		c, r, status := connect(envoyConnect(fmt.Sprintf("host.containers.internal:%d", port)) + "ping")
		Expect(status).To(Equal("HTTP/1.1 200 Connection established"))
		Expect(echoThrough(c, r, "")).To(Equal("ping"))
	})

	It("matches the host case-insensitively and allows a port inside a range", func() {
		port := echoServer()
		allow(fmt.Sprintf("%d-%d\n", port-1, port+1))
		_, _, status := connect(envoyConnect(fmt.Sprintf("HOST.Containers.Internal:%d", port)))
		Expect(status).To(HavePrefix("HTTP/1.1 200 "))
	})

	It("refuses an unlisted port with 403", func() {
		port := echoServer()
		allow(fmt.Sprintf("%d\n", port+1))
		_, _, status := connect(envoyConnect(fmt.Sprintf("host.containers.internal:%d", port)))
		Expect(status).To(Equal("HTTP/1.1 403 Forbidden"))
	})

	It("reads the ports file again for each connection", func() {
		port := echoServer()
		_, _, status := connect(envoyConnect(fmt.Sprintf("host.containers.internal:%d", port)))
		Expect(status).To(Equal("HTTP/1.1 403 Forbidden"))
		allow(fmt.Sprintf("%d\n", port))
		_, _, status = connect(envoyConnect(fmt.Sprintf("host.containers.internal:%d", port)))
		Expect(status).To(HavePrefix("HTTP/1.1 200 "))
	})

	It("refuses every port, saying why, when the ports file is damaged", func() {
		port := echoServer()
		allow(fmt.Sprintf("%d\nssh\n", port))
		_, _, status := connect(envoyConnect(fmt.Sprintf("host.containers.internal:%d", port)))
		Expect(status).To(Equal("HTTP/1.1 403 Forbidden"))
		Eventually(logs).Should(gbytes.Say("refusing every port"))
	})

	It("answers 502 when the listed port does not answer on the host", func() {
		port := freePort()
		allow(fmt.Sprintf("%d\n", port))
		_, _, status := connect(envoyConnect(fmt.Sprintf("host.containers.internal:%d", port)))
		Expect(status).To(Equal("HTTP/1.1 502 Bad Gateway"))
	})

	DescribeTable("refuses anything but a CONNECT to the host with 400",
		func(head string) {
			allow("1-65535\n")
			_, _, status := connect(head)
			Expect(status).To(Equal("HTTP/1.1 400 Bad Request"))
		},
		Entry("a GET", "GET / HTTP/1.1\r\nhost: host.containers.internal\r\n\r\n"),
		Entry("another host", "CONNECT example.com:443 HTTP/1.1\r\n\r\n"),
		Entry("a lookalike host", "CONNECT host.containers.internal.example.com:443 HTTP/1.1\r\n\r\n"),
		Entry("no port", "CONNECT host.containers.internal HTTP/1.1\r\n\r\n"),
		Entry("port 0", "CONNECT host.containers.internal:0 HTTP/1.1\r\n\r\n"),
		Entry("a leading zero", "CONNECT host.containers.internal:022 HTTP/1.1\r\n\r\n"),
		Entry("port 65536", "CONNECT host.containers.internal:65536 HTTP/1.1\r\n\r\n"),
		Entry("a non-ASCII lookalike host", "CONNECT ho\u017ft.containers.internal:22 HTTP/1.1\r\n\r\n"),
		Entry("a bracketed host", "CONNECT [host.containers.internal]:22 HTTP/1.1\r\n\r\n"),
		Entry("HTTP/1.0", "CONNECT host.containers.internal:22 HTTP/1.0\r\n\r\n"),
		Entry("a head over 8 KiB", "CONNECT host.containers.internal:22 HTTP/1.1\r\nx-pad: "+strings.Repeat("a", 9000)+"\r\n\r\n"),
	)
})
