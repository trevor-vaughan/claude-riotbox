package hub_test

import (
	"crypto/tls"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gbytes"

	"github.com/trevor-vaughan/claude-riotbox/internal/hub"
)

// fakeEngine answers ps with ids and container inspect with inspect, and
// records every call. When gone is set, an inspect naming any of those ids
// fails the way the engine does for a container that has exited, and an
// inspect of one other id answers with byID[id].
type fakeEngine struct {
	ids, inspect string
	psErr        error
	gone         map[string]bool
	byID         map[string]string
	calls        [][]string
}

func (f *fakeEngine) output(_ string, args ...string) ([]byte, error) {
	f.calls = append(f.calls, args)
	switch args[0] {
	case "ps":
		return []byte(f.ids), f.psErr
	case "container":
		ids := args[2:]
		for _, id := range ids {
			if f.gone[id] {
				return nil, errors.New("podman container inspect: exit status 125: Error: no such container " + id)
			}
		}
		if len(ids) == 1 && f.byID != nil {
			return []byte(f.byID[ids[0]]), nil
		}
		return []byte(f.inspect), nil
	}
	return nil, errors.New("unexpected call")
}

// running is one container inspect entry for a running container with the
// given URL label and a 3400/tcp binding on hostIP:hostPort.
func running(name, url, hostIP, hostPort string) string {
	return `{"Name":"` + name + `","Config":{"Labels":{"riotbox.anywhere.url":"` + url + `"}},` +
		`"HostConfig":{"PortBindings":{"3400/tcp":[{"HostIp":"` + hostIP + `","HostPort":"` + hostPort + `"}]}},` +
		`"State":{"Running":true}}`
}

func writeRecord(root, key string, projects ...string) {
	dir := filepath.Join(root, key)
	Expect(os.MkdirAll(dir, 0o700)).To(Succeed())
	Expect(os.WriteFile(filepath.Join(dir, "projects"), []byte(strings.Join(projects, "\n")+"\n"), 0o600)).To(Succeed())
}

const inspectTwo = `[
 {"Name":"/riotbox-b","Config":{"Labels":{"riotbox.anywhere.url":"https://192.168.1.20:3401","riotbox.session":"key-b"}},"HostConfig":{"PortBindings":{"3400/tcp":[{"HostIp":"192.168.1.20","HostPort":"3401"}]}},"State":{"Running":true,"StartedAt":"2026-11-08T12:00:00.5Z"}},
 {"Name":"riotbox-a","Config":{"Labels":{"riotbox.anywhere.url":"https://127.0.0.1:3400","riotbox.session":"key-a"}},"HostConfig":{"PortBindings":{"3400/tcp":[{"HostIp":"127.0.0.1","HostPort":"3400"}]}},"State":{"Running":true,"StartedAt":"2026-11-08T10:00:00Z"}}
]`

var _ = Describe("Lister", func() {
	var root string
	BeforeEach(func() { root = GinkgoT().TempDir() })

	It("gives up on an engine that does not answer, even when its child holds the output open", func() {
		DeferCleanup(hub.SetEngineTimeout(200 * time.Millisecond))
		engine := filepath.Join(GinkgoT().TempDir(), "engine")
		Expect(os.WriteFile(engine, []byte("#!/bin/sh\nsleep 30\n"), 0o700)).To(Succeed())
		start := time.Now()
		_, err := hub.Lister{Engine: engine}.List()
		Expect(err).To(MatchError(ContainSubstring("no answer within 200ms")))
		Expect(time.Since(start)).To(BeNumerically("<", 3*time.Second))
	})

	It("lists running sessions oldest first, with their recorded projects", func() {
		writeRecord(root, "key-a", "/home/u/alpha")
		writeRecord(root, "key-b", "/home/u/beta", "/home/u/lib")
		f := &fakeEngine{ids: "id1\nid2\n", inspect: inspectTwo}
		sessions, err := hub.Lister{Engine: "podman", StateRoot: root, Output: f.output}.List()
		Expect(err).NotTo(HaveOccurred())
		Expect(sessions).To(HaveLen(2))
		Expect(sessions[0].Container).To(Equal("riotbox-a"))
		Expect(sessions[0].StateDir).To(Equal(filepath.Join(root, "key-a")))
		Expect(sessions[0].Projects).To(Equal([]string{"/home/u/alpha"}))
		Expect(sessions[1].Container).To(Equal("riotbox-b"))
		Expect(sessions[1].URL).To(Equal("https://192.168.1.20:3401"))
		Expect(sessions[1].StateDir).To(Equal(filepath.Join(root, "key-b")))
		Expect(sessions[1].Projects).To(Equal([]string{"/home/u/beta", "/home/u/lib"}))
		Expect(f.calls).To(Equal([][]string{
			{"ps", "--filter", "label=riotbox.anywhere.url", "--format", "{{.ID}}"},
			{"container", "inspect", "id1", "id2"},
		}))
	})

	It("asks the engine nothing more when no container carries the label", func() {
		f := &fakeEngine{ids: "\n"}
		sessions, err := hub.Lister{Engine: "podman", Output: f.output}.List()
		Expect(err).NotTo(HaveOccurred())
		Expect(sessions).To(BeEmpty())
		Expect(f.calls).To(HaveLen(1))
	})

	It("passes on an engine failure", func() {
		f := &fakeEngine{psErr: errors.New("engine down")}
		_, err := hub.Lister{Engine: "podman", Output: f.output}.List()
		Expect(err).To(MatchError(ContainSubstring("engine down")))
	})

	DescribeTable("leaves out a container whose URL label RiotBox would not have written",
		func(url string) {
			f := &fakeEngine{ids: "id1", inspect: `[{"Name":"x","Config":{"Labels":{"riotbox.anywhere.url":"` + url + `"}},"State":{"Running":true}}]`}
			sessions, err := hub.Lister{Engine: "podman", Output: f.output}.List()
			Expect(err).NotTo(HaveOccurred())
			Expect(sessions).To(BeEmpty())
		},
		Entry("plain http", "http://192.168.1.20:3400"),
		Entry("a script URL", "javascript:alert(1)"),
		Entry("credentials", "https://u:p@192.168.1.20:3400"),
		Entry("a path", "https://192.168.1.20:3400/elsewhere"),
		Entry("a query", "https://192.168.1.20:3400/?x=1"),
		Entry("empty", ""),
	)

	// The label is only a claim: an image can carry it (the engine copies
	// image labels onto every container), so a session is listed only when
	// the container really publishes Yep Anywhere's port at that URL.
	DescribeTable("lists a container only when its URL is where it publishes Yep Anywhere's port",
		func(entry string, listed bool) {
			f := &fakeEngine{ids: "id1", inspect: "[" + entry + "]"}
			sessions, err := hub.Lister{Engine: "podman", Output: f.output}.List()
			Expect(err).NotTo(HaveOccurred())
			if listed {
				Expect(sessions).To(HaveLen(1))
			} else {
				Expect(sessions).To(BeEmpty())
			}
		},
		Entry("the matching LAN binding", running("x", "https://192.168.1.20:3400", "192.168.1.20", "3400"), true),
		Entry("an IPv6 binding, which the engine prints unbracketed", running("x", "https://[fd00::20]:3400", "fd00::20", "3400"), true),
		Entry("a wildcard binding", running("x", "https://0.0.0.0:3400", "0.0.0.0", "3400"), true),
		Entry("no port binding at all",
			`{"Name":"x","Config":{"Labels":{"riotbox.anywhere.url":"https://192.168.1.20:3400"}},"State":{"Running":true}}`, false),
		Entry("a host name, which no binding can match", running("x", "https://phish.example:3400", "0.0.0.0", "3400"), false),
		Entry("another host address", running("x", "https://192.168.1.99:3400", "192.168.1.20", "3400"), false),
		Entry("another host port", running("x", "https://192.168.1.20:3400", "192.168.1.20", "3401"), false),
		Entry("no port in the URL", running("x", "https://192.168.1.20", "192.168.1.20", "443"), false),
		Entry("the URL published from another container port",
			`{"Name":"x","Config":{"Labels":{"riotbox.anywhere.url":"https://192.168.1.20:3400"}},"HostConfig":{"PortBindings":{"8080/tcp":[{"HostIp":"192.168.1.20","HostPort":"3400"}]}},"State":{"Running":true}}`, false),
	)

	It("skips a container that exits between ps and inspect, and lists the rest", func() {
		f := &fakeEngine{
			ids:  "id1\nid2\n",
			gone: map[string]bool{"id1": true},
			byID: map[string]string{"id2": "[" + running("riotbox-b", "https://192.168.1.20:3400", "192.168.1.20", "3400") + "]"},
		}
		sessions, err := hub.Lister{Engine: "podman", Output: f.output}.List()
		Expect(err).NotTo(HaveOccurred())
		Expect(sessions).To(HaveLen(1))
		Expect(sessions[0].Container).To(Equal("riotbox-b"))
	})

	It("passes on an inspect failure that is not a container having gone", func() {
		f := &fakeEngine{ids: "id1", inspect: "not json"}
		_, err := hub.Lister{Engine: "podman", Output: f.output}.List()
		Expect(err).To(HaveOccurred())
	})

	It("skips stopped containers", func() {
		f := &fakeEngine{ids: "id1", inspect: `[{"Name":"x","Config":{"Labels":{"riotbox.anywhere.url":"https://10.0.0.2:3400"}},"State":{"Running":false}}]`}
		sessions, err := hub.Lister{Engine: "podman", Output: f.output}.List()
		Expect(err).NotTo(HaveOccurred())
		Expect(sessions).To(BeEmpty())
	})

	It("never reads a state dir outside the root when the session label is not one path element", func() {
		outside := GinkgoT().TempDir()
		writeRecord(outside, "secret", "/etc")
		rel, err := filepath.Rel(root, filepath.Join(outside, "secret"))
		Expect(err).NotTo(HaveOccurred())
		f := &fakeEngine{ids: "id1", inspect: `[{"Name":"x","Config":{"Labels":{"riotbox.anywhere.url":"https://10.0.0.2:3400","riotbox.session":"` + rel + `"}},"HostConfig":{"PortBindings":{"3400/tcp":[{"HostIp":"10.0.0.2","HostPort":"3400"}]}},"State":{"Running":true}}]`}
		sessions, err := hub.Lister{Engine: "podman", StateRoot: root, Output: f.output}.List()
		Expect(err).NotTo(HaveOccurred())
		Expect(sessions).To(HaveLen(1))
		Expect(sessions[0].Projects).To(BeNil())
		Expect(sessions[0].StateDir).To(BeEmpty())
	})

	It("gives no state dir without a state root", func() {
		f := &fakeEngine{ids: "id1", inspect: inspectTwo}
		sessions, err := hub.Lister{Engine: "podman", Output: f.output}.List()
		Expect(err).NotTo(HaveOccurred())
		Expect(sessions).NotTo(BeEmpty())
		for _, s := range sessions {
			Expect(s.StateDir).To(BeEmpty())
		}
	})
})

var _ = DescribeTable("HostAllowed",
	func(hostHeader, listen string, want bool) {
		Expect(hub.HostAllowed(hostHeader, listen)).To(Equal(want))
	},
	Entry("the listen address", "192.168.1.20:3399", "192.168.1.20", true),
	Entry("another address", "192.168.1.21:3399", "192.168.1.20", false),
	Entry("a name that resolves anywhere", "evil.example:3399", "192.168.1.20", false),
	Entry("localhost", "localhost:3399", "192.168.1.20", true),
	Entry("loopback", "127.0.0.1:3399", "192.168.1.20", true),
	Entry("IPv6 listen address", "[fd00::20]:3399", "fd00::20", true),
	Entry("wildcard accepts any IP", "10.1.2.3:3399", "0.0.0.0", true),
	Entry("wildcard still refuses a name", "evil.example:3399", "0.0.0.0", false),
)

type staticLister struct {
	sessions []hub.Session
	err      error
}

func (s staticLister) List() ([]hub.Session, error) { return s.sessions, s.err }

var _ = Describe("Server", func() {
	var (
		dir    string
		server *hub.Server
		link   string
	)
	now := time.Date(2026, 11, 8, 13, 0, 0, 0, time.UTC)

	BeforeEach(func() {
		dir = filepath.Join(GinkgoT().TempDir(), "hub")
		server = &hub.Server{
			Addr: "192.168.1.20:3399", DataDir: dir, Now: func() time.Time { return now },
			Lister: staticLister{sessions: []hub.Session{{
				Container: "riotbox-x", URL: "https://192.168.1.20:3401",
				Projects: []string{"/home/u/<b>proj</b>"}, Started: now.Add(-90 * time.Minute),
			}}},
		}
		var err error
		link, _, err = server.Prepare()
		Expect(err).NotTo(HaveOccurred())
	})

	get := func(target string, cookies ...*http.Cookie) *httptest.ResponseRecorder {
		r := httptest.NewRequest(http.MethodGet, target, nil)
		r.Host = "192.168.1.20:3399"
		for _, c := range cookies {
			r.AddCookie(c)
		}
		w := httptest.NewRecorder()
		server.Handler().ServeHTTP(w, r)
		return w
	}

	It("keeps the token and the key private", func() {
		for _, f := range []string{"token", "key.pem", "cert.pem"} {
			info, err := os.Stat(filepath.Join(dir, f))
			Expect(err).NotTo(HaveOccurred())
			Expect(info.Mode().Perm()).To(Equal(os.FileMode(0o600)), f)
		}
		info, err := os.Stat(dir)
		Expect(err).NotTo(HaveOccurred())
		Expect(info.Mode().Perm()).To(Equal(os.FileMode(0o700)))
	})

	It("refuses a visit without the token", func() {
		Expect(get("/").Code).To(Equal(http.StatusUnauthorized))
		Expect(get("/?k=wrong").Code).To(Equal(http.StatusForbidden))
	})

	It("turns the printed link into a cookie, then serves the list with the input escaped", func() {
		Expect(link).To(HavePrefix("https://192.168.1.20:3399/?k="))
		w := get(strings.TrimPrefix(link, "https://192.168.1.20:3399"))
		Expect(w.Code).To(Equal(http.StatusSeeOther))
		Expect(w.Header().Get("Location")).To(Equal("/"))
		cookies := w.Result().Cookies()
		Expect(cookies).To(HaveLen(1))
		Expect(cookies[0].HttpOnly).To(BeTrue())
		Expect(cookies[0].Secure).To(BeTrue())
		Expect(cookies[0].SameSite).To(Equal(http.SameSiteStrictMode))

		page := get("/", cookies[0])
		Expect(page.Code).To(Equal(http.StatusOK))
		body := page.Body.String()
		Expect(body).To(ContainSubstring(`href="https://192.168.1.20:3401/"`))
		Expect(body).To(ContainSubstring("&lt;b&gt;proj&lt;/b&gt;"))
		Expect(body).NotTo(ContainSubstring("<b>proj</b>"))
		Expect(body).To(ContainSubstring("started 1 h ago"))
		Expect(page.Header().Get("Content-Security-Policy")).To(ContainSubstring("default-src 'none'"))
	})

	It("accepts the token when a shadowing cookie comes first", func() {
		cookie := get(strings.TrimPrefix(link, "https://192.168.1.20:3399")).Result().Cookies()[0]
		Expect(get("/", &http.Cookie{Name: "riotbox_hub", Value: "planted"}, cookie).Code).To(Equal(http.StatusOK))
	})

	It("takes a new token from the next request, with no restart", func() {
		old := get(strings.TrimPrefix(link, "https://192.168.1.20:3399")).Result().Cookies()[0]
		Expect(get("/", old).Code).To(Equal(http.StatusOK))
		newLink, err := server.NewToken()
		Expect(err).NotTo(HaveOccurred())
		Expect(newLink).NotTo(Equal(link))
		Expect(get("/", old).Code).To(Equal(http.StatusUnauthorized))
		fresh := get(strings.TrimPrefix(newLink, "https://192.168.1.20:3399")).Result().Cookies()[0]
		Expect(get("/", fresh).Code).To(Equal(http.StatusOK))
		info, err := os.Stat(filepath.Join(dir, "token"))
		Expect(err).NotTo(HaveOccurred())
		Expect(info.Mode().Perm()).To(Equal(os.FileMode(0o600)))
	})

	It("refuses everything while the token file is missing, and says so once", func() {
		errs := gbytes.NewBuffer()
		server.Stderr = errs
		c := get(strings.TrimPrefix(link, "https://192.168.1.20:3399")).Result().Cookies()[0]
		Expect(os.Remove(filepath.Join(dir, "token"))).To(Succeed())
		Expect(get("/", c).Code).To(Equal(http.StatusUnauthorized))
		Expect(get("/", c).Code).To(Equal(http.StatusUnauthorized))
		Expect(strings.Count(string(errs.Contents()), "refusing every request")).To(Equal(1))
	})

	It("reads the token on every request, even when a rewrite keeps the size and modification time", func() {
		path := filepath.Join(dir, "token")
		old, err := os.ReadFile(path)
		Expect(err).NotTo(HaveOccurred())
		c := get(strings.TrimPrefix(link, "https://192.168.1.20:3399")).Result().Cookies()[0]
		Expect(get("/", c).Code).To(Equal(http.StatusOK))
		info, err := os.Stat(path)
		Expect(err).NotTo(HaveOccurred())
		Expect(os.WriteFile(path, []byte(strings.Repeat("x", len(old)-1)+"\n"), 0o600)).To(Succeed())
		Expect(os.Chtimes(path, info.ModTime(), info.ModTime())).To(Succeed())
		Expect(get("/", c).Code).To(Equal(http.StatusUnauthorized))
	})

	DescribeTable("refuses everything while the token file is unusable, logs each distinct failure once, and recovers when a valid file returns",
		func(damage func(path string)) {
			path := filepath.Join(dir, "token")
			valid, err := os.ReadFile(path)
			Expect(err).NotTo(HaveOccurred())
			errs := gbytes.NewBuffer()
			server.Stderr = errs
			c := get(strings.TrimPrefix(link, "https://192.168.1.20:3399")).Result().Cookies()[0]
			refusals := func() int { return strings.Count(string(errs.Contents()), "refusing every request") }

			damage(path)
			Expect(get("/", c).Code).To(Equal(http.StatusUnauthorized))
			Expect(get("/", c).Code).To(Equal(http.StatusUnauthorized))
			Expect(refusals()).To(Equal(1))

			Expect(os.Chmod(path, 0o600)).To(Succeed())
			Expect(os.WriteFile(path, valid, 0o600)).To(Succeed())
			Expect(get("/", c).Code).To(Equal(http.StatusOK))

			damage(path)
			Expect(get("/", c).Code).To(Equal(http.StatusUnauthorized))
			Expect(refusals()).To(Equal(2))
		},
		Entry("emptied", func(path string) { Expect(os.WriteFile(path, nil, 0o600)).To(Succeed()) }),
		Entry("shorter than 32 characters", func(path string) {
			Expect(os.WriteFile(path, []byte("short\n"), 0o600)).To(Succeed())
		}),
		Entry("unreadable", func(path string) {
			if os.Geteuid() == 0 {
				Skip("root reads a mode 0000 file")
			}
			Expect(os.WriteFile(path, []byte("unreadable"), 0o600)).To(Succeed())
			Expect(os.Chmod(path, 0o000)).To(Succeed())
		}),
	)

	It("gives the same link Prepare printed, without touching the certificate", func() {
		again := &hub.Server{Addr: server.Addr, DataDir: dir}
		Expect(again.Link()).To(Equal(link))
	})

	It("refuses a request addressed to another host", func() {
		r := httptest.NewRequest(http.MethodGet, "/", nil)
		r.Host = "evil.example:3399"
		w := httptest.NewRecorder()
		server.Handler().ServeHTTP(w, r)
		Expect(w.Code).To(Equal(http.StatusMisdirectedRequest))
	})

	It("reuses the token and certificate on the next start, and reissues the certificate for a new address", func() {
		cert1, err := os.ReadFile(filepath.Join(dir, "cert.pem"))
		Expect(err).NotTo(HaveOccurred())
		again := &hub.Server{Addr: server.Addr, DataDir: dir, Now: server.Now, Lister: staticLister{}}
		link2, c2, err := again.Prepare()
		Expect(err).NotTo(HaveOccurred())
		Expect(link2).To(Equal(link))
		cert2, err := os.ReadFile(filepath.Join(dir, "cert.pem"))
		Expect(err).NotTo(HaveOccurred())
		Expect(cert2).To(Equal(cert1))
		Expect(leafIPs(c2)).To(ContainElement("192.168.1.20"))

		moved := &hub.Server{Addr: "10.0.0.5:3399", DataDir: dir, Now: server.Now, Lister: staticLister{}}
		_, c3, err := moved.Prepare()
		Expect(err).NotTo(HaveOccurred())
		Expect(leafIPs(c3)).To(ContainElement("10.0.0.5"))
	})

	It("shows the engine's error instead of an empty list", func() {
		server.Lister = staticLister{err: errors.New("podman: not running")}
		w := get(strings.TrimPrefix(link, "https://192.168.1.20:3399"))
		page := get("/", w.Result().Cookies()[0])
		Expect(page.Body.String()).To(ContainSubstring("podman: not running"))
		Expect(page.Body.String()).NotTo(ContainSubstring("No <code>riotbox anywhere</code> session is running"))
	})
})

func leafIPs(c tls.Certificate) []string {
	var ips []string
	for _, ip := range c.Leaf.IPAddresses {
		ips = append(ips, ip.String())
	}
	return ips
}
