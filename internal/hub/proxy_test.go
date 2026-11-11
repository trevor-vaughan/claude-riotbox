package hub_test

import (
	"bufio"
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gbytes"

	"github.com/trevor-vaughan/claude-riotbox/internal/hub"
)

// seen is what the fake Yep Anywhere last received. Its handler runs on
// the test server's goroutines, hence the lock.
type seen struct {
	mu                                sync.Mutex
	path, query, host, origin, cookie string
	hits                              int
}

func (s *seen) record(r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.path, s.query, s.host, s.origin, s.cookie = r.URL.Path, r.URL.RawQuery, r.Host, r.Header.Get("Origin"), r.Header.Get("Cookie")
	s.hits++
}

func (s *seen) snapshot() seen {
	s.mu.Lock()
	defer s.mu.Unlock()
	return seen{path: s.path, query: s.query, host: s.host, origin: s.origin, cookie: s.cookie, hits: s.hits}
}

// logins is what the fake Yep Anywhere's login route received.
type logins struct {
	mu                       sync.Mutex
	password, header, origin string
	statusCalls, calls       int
	// statusCookie is the Cookie header of the last status call; redirected
	// counts requests to the target of the 302 the status route can answer.
	statusCookie string
	redirected   int
}

func (l *logins) snapshot() logins {
	l.mu.Lock()
	defer l.mu.Unlock()
	return logins{password: l.password, header: l.header, origin: l.origin, statusCalls: l.statusCalls, calls: l.calls, statusCookie: l.statusCookie, redirected: l.redirected}
}

// countingLister answers List with sessions, or with err when set, and
// counts the calls. The hub calls it from its own goroutines.
type countingLister struct {
	mu       sync.Mutex
	sessions []hub.Session
	err      error
	calls    int
}

func (c *countingLister) List() ([]hub.Session, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.calls++
	return slices.Clone(c.sessions), c.err
}

func (c *countingLister) set(sessions []hub.Session, err error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.sessions, c.err = sessions, err
}

func (c *countingLister) count() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.calls
}

// blockingLister answers List with sessions; once setBlock is called, List
// waits until unblock.
type blockingLister struct {
	mu       sync.Mutex
	sessions []hub.Session
	block    bool
	inList   bool
	release  chan struct{}
	once     sync.Once
}

func (b *blockingLister) List() ([]hub.Session, error) {
	b.mu.Lock()
	if b.block {
		b.inList = true
		b.mu.Unlock()
		<-b.release
		b.mu.Lock()
	}
	defer b.mu.Unlock()
	return slices.Clone(b.sessions), nil
}

func (b *blockingLister) setBlock() {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.block = true
}

// waiting reports whether a List call has started waiting.
func (b *blockingLister) waiting() bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.inList
}

func (b *blockingLister) unblock() { b.once.Do(func() { close(b.release) }) }

// writeCert stores der where Yep Anywhere keeps its self-signed certificate.
func writeCert(stateDir string, der []byte) {
	dir := filepath.Join(stateDir, "yep-anywhere", "https")
	Expect(os.MkdirAll(dir, 0o700)).To(Succeed())
	pemBytes := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	Expect(os.WriteFile(filepath.Join(dir, "self-signed-cert.pem"), pemBytes, 0o600)).To(Succeed())
}

// otherCert is a self-signed certificate no upstream presents.
func otherCert() []byte {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	Expect(err).NotTo(HaveOccurred())
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "other"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	Expect(err).NotTo(HaveOccurred())
	return der
}

// prefixFor is the cookie prefix the hub gives container's cookies.
func prefixFor(container string) string {
	sum := sha256.Sum256([]byte(container))
	return "rb" + hex.EncodeToString(sum[:4]) + "-"
}

// portOf is the port a listener or server listens on.
func portOf(addr net.Addr) string {
	return strconv.Itoa(addr.(*net.TCPAddr).Port)
}

// echoUpgrade accepts a WebSocket upgrade, then echoes every byte: enough
// to prove the hub relays an upgraded connection both ways.
func echoUpgrade(w http.ResponseWriter) {
	defer GinkgoRecover()
	conn, rw, err := http.NewResponseController(w).Hijack()
	Expect(err).NotTo(HaveOccurred())
	defer func() { _ = conn.Close() }()
	_, err = rw.WriteString("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
	Expect(err).NotTo(HaveOccurred())
	Expect(rw.Flush()).To(Succeed())
	_, _ = io.Copy(conn, rw) // ends when the client closes
}

var _ = Describe("A session port", func() {
	const hubIP = "192.168.1.20"
	var (
		upstream *httptest.Server
		port     string
		got      *seen
		auth     *logins
		lister   *countingLister
		stateDir string
		server   *hub.Server
		handler  http.Handler
		token    *http.Cookie
		stderr   *gbytes.Buffer
		clock    time.Time
		// statusAnswer picks how the fake's /api/auth/status answers: "" is
		// the real answer, "500", "302", "malformed" and "disabled" are the
		// ways it can go wrong, and "unauthenticated" refuses every cookie.
		// Set it before the request; read under auth.mu.
		statusAnswer string
		// loginGate, when set, runs in the fake's login route before it
		// answers. Set it under auth.mu; it is read under auth.mu.
		loginGate func()
	)

	BeforeEach(func() {
		got = &seen{}
		auth = &logins{}
		statusAnswer, loginGate = "", nil
		upstream = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			switch r.URL.Path {
			case "/api/auth/status":
				auth.mu.Lock()
				auth.statusCalls++
				auth.statusCookie = r.Header.Get("Cookie")
				answer := statusAnswer
				auth.mu.Unlock()
				w.Header().Set("Content-Type", "application/json")
				switch answer {
				case "500":
					http.Error(w, `{"error":"boom"}`, http.StatusInternalServerError)
				case "302":
					http.Redirect(w, r, "/after-redirect", http.StatusFound)
				case "malformed":
					_, _ = io.WriteString(w, `{"enabled":tr`)
				case "disabled":
					_, _ = io.WriteString(w, `{"enabled":false,"authenticated":false}`)
				case "unauthenticated":
					_, _ = io.WriteString(w, `{"enabled":true,"authenticated":false}`)
				default:
					ck, err := r.Cookie("yep-anywhere-session")
					_, _ = fmt.Fprintf(w, `{"enabled":true,"authenticated":%t}`, err == nil && ck.Value == "good")
				}
				return
			case "/after-redirect":
				auth.mu.Lock()
				auth.redirected++
				auth.mu.Unlock()
				return
			case "/api/auth/login":
				var body struct{ Password string }
				_ = json.NewDecoder(r.Body).Decode(&body)
				auth.mu.Lock()
				auth.calls++
				auth.password, auth.header, auth.origin = body.Password, r.Header.Get("X-Yep-Anywhere"), r.Header.Get("Origin")
				gate := loginGate
				auth.mu.Unlock()
				if gate != nil {
					gate()
				}
				if body.Password != "pw-123" {
					http.Error(w, `{"error":"Invalid password"}`, http.StatusUnauthorized)
					return
				}
				w.Header().Add("Set-Cookie", "yep-anywhere-session=good; Path=/; Max-Age=2592000; HttpOnly; Secure; SameSite=Lax")
				_, _ = io.WriteString(w, `{"success":true}`)
				return
			}
			got.record(r)
			if r.Header.Get("Upgrade") == "websocket" {
				echoUpgrade(w)
				return
			}
			switch r.URL.Path {
			case "/clear":
				w.Header().Set("Clear-Site-Data", `"cookies", "storage"`)
			case "/bad-cookie":
				w.Header().Add("Set-Cookie", "=no-name")
			case "/plain-cookie":
				w.Header().Add("Set-Cookie", "readable=1; Path=/")
			}
			w.Header().Set("Content-Security-Policy", "upstream-csp")
			w.Header().Add("Set-Cookie", "yep-anywhere-session=abc; Path=/; Domain=127.0.0.1; HttpOnly; Secure; SameSite=Strict")
			_, _ = io.WriteString(w, "yep:"+r.URL.Path)
		}))
		DeferCleanup(upstream.Close)
		port = portOf(upstream.Listener.Addr())
		stateDir = filepath.Join(GinkgoT().TempDir(), "key-x")
		writeCert(stateDir, upstream.Certificate().Raw)
		Expect(os.WriteFile(filepath.Join(stateDir, "anywhere-password"), []byte("pw-123\n"), 0o600)).To(Succeed())
		lister = &countingLister{sessions: []hub.Session{{Container: "riotbox-x", URL: upstream.URL, StateDir: stateDir}}}
		clock = time.Date(2026, 11, 10, 9, 0, 0, 0, time.UTC)
		stderr = gbytes.NewBuffer()
		server = &hub.Server{
			Addr: hubIP + ":3399", DataDir: filepath.Join(GinkgoT().TempDir(), "hub"),
			Lister: lister, Now: func() time.Time { return clock }, Stderr: stderr,
		}
		link, _, err := server.Prepare()
		Expect(err).NotTo(HaveOccurred())
		token = &http.Cookie{Name: "riotbox_hub", Value: strings.TrimPrefix(link, "https://"+hubIP+":3399/?k=")}
		handler = server.SessionHandler(port)
	})

	do := func(method, target string, header http.Header, cookies ...*http.Cookie) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, target, nil)
		r.Host = hubIP + ":" + port
		for k, v := range header {
			r.Header[k] = v
		}
		for _, c := range cookies {
			r.AddCookie(c)
		}
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		return w
	}

	navigation := http.Header{
		"Accept":         {"text/html,application/xhtml+xml"},
		"Sec-Fetch-Mode": {"navigate"}, "Sec-Fetch-Dest": {"document"}, "Sec-Fetch-Site": {"none"},
	}

	loginCookie := func(w *httptest.ResponseRecorder) *http.Cookie {
		for _, c := range w.Result().Cookies() {
			if c.Name == prefixFor("riotbox-x")+"yep-anywhere-session" && c.Value == "good" {
				return c
			}
		}
		return nil
	}

	It("signs a navigation in, and hands the browser the login cookie renamed", func() {
		w := do(http.MethodGet, "/", navigation, token)
		Expect(w.Code).To(Equal(http.StatusOK))
		Expect(got.snapshot().cookie).To(Equal("yep-anywhere-session=good"))
		ck := loginCookie(w)
		Expect(ck).NotTo(BeNil())
		Expect(ck.HttpOnly).To(BeTrue())
		Expect(ck.Domain).To(BeEmpty())
		a := auth.snapshot()
		Expect(a.calls).To(Equal(1))
		Expect(a.password).To(Equal("pw-123"))
		Expect(a.header).To(Equal("true"))
		Expect(a.origin).To(Equal(upstream.URL))
	})

	It("signs in a navigation from a browser without Sec-Fetch headers", func() {
		w := do(http.MethodGet, "/", http.Header{"Accept": {"text/html"}}, token)
		Expect(loginCookie(w)).NotTo(BeNil())
	})

	It("leaves a signed-in browser alone", func() {
		w := do(http.MethodGet, "/", navigation, token, &http.Cookie{Name: prefixFor("riotbox-x") + "yep-anywhere-session", Value: "good"})
		Expect(w.Code).To(Equal(http.StatusOK))
		Expect(auth.snapshot().calls).To(BeZero())
		Expect(got.snapshot().cookie).To(Equal("yep-anywhere-session=good"))
	})

	It("replaces a login the session no longer accepts", func() {
		w := do(http.MethodGet, "/", navigation, token, &http.Cookie{Name: prefixFor("riotbox-x") + "yep-anywhere-session", Value: "expired"})
		Expect(auth.snapshot().calls).To(Equal(1))
		Expect(got.snapshot().cookie).To(Equal("yep-anywhere-session=good"))
		Expect(loginCookie(w)).NotTo(BeNil())
	})

	It("never signs in a page's own requests", func() {
		do(http.MethodGet, "/api/x", nil, token)
		do(http.MethodPost, "/", http.Header{"Accept": {"text/html"}}, token)
		a := auth.snapshot()
		Expect(a.statusCalls).To(BeZero())
		Expect(a.calls).To(BeZero())
	})

	It("goes on unchanged, and says why, when the session refuses the password", func() {
		Expect(os.WriteFile(filepath.Join(stateDir, "anywhere-password"), []byte("wrong\n"), 0o600)).To(Succeed())
		w := do(http.MethodGet, "/", navigation, token)
		Expect(w.Code).To(Equal(http.StatusOK))
		Expect(loginCookie(w)).To(BeNil())
		Expect(got.snapshot().cookie).To(BeEmpty())
		Expect(stderr).To(gbytes.Say(`signing in to "riotbox-x" failed: login refused: 401`))
	})

	It("signs in with the first line of the password file, as the launcher reads it", func() {
		for _, content := range []string{"pw-123\nextra\n", "pw-123\r\n", "pw-123"} {
			Expect(os.WriteFile(filepath.Join(stateDir, "anywhere-password"), []byte(content), 0o600)).To(Succeed())
			w := do(http.MethodGet, "/", navigation, token)
			Expect(loginCookie(w)).NotTo(BeNil(), "file %q", content)
			Expect(auth.snapshot().password).To(Equal("pw-123"), "file %q", content)
		}
	})

	It("does not sign in a request whose Sec-Fetch-Mode says it is not a navigation, whatever its Accept", func() {
		w := do(http.MethodGet, "/", http.Header{"Accept": {"text/html"}, "Sec-Fetch-Mode": {"cors"}}, token)
		Expect(w.Code).To(Equal(http.StatusOK))
		a := auth.snapshot()
		Expect(a.statusCalls).To(BeZero())
		Expect(a.calls).To(BeZero())
		Expect(loginCookie(w)).To(BeNil())
	})

	It("signs in a browser holding only another session's login, without sending that login anywhere", func() {
		other := &http.Cookie{Name: prefixFor("riotbox-y") + "yep-anywhere-session", Value: "other-good"}
		w := do(http.MethodGet, "/", navigation, token, other)
		a := auth.snapshot()
		Expect(a.statusCalls).To(Equal(1))
		Expect(a.statusCookie).To(BeEmpty())
		Expect(a.calls).To(Equal(1))
		Expect(loginCookie(w)).NotTo(BeNil())
		Expect(got.snapshot().cookie).To(Equal("yep-anywhere-session=good"))
	})

	It("reuses a login it just made instead of making another", func() {
		Expect(loginCookie(do(http.MethodGet, "/", navigation, token))).NotTo(BeNil())
		Expect(loginCookie(do(http.MethodGet, "/", navigation, token))).NotTo(BeNil())
		Expect(auth.snapshot().calls).To(Equal(1))
		clock = clock.Add(11 * time.Second)
		Expect(loginCookie(do(http.MethodGet, "/", navigation, token))).NotTo(BeNil())
		Expect(auth.snapshot().calls).To(Equal(2))
	})

	It("makes one login for page loads that arrive together, each already past its status call", func() {
		const loads = 5
		auth.mu.Lock()
		loginGate = func() {
			// Answer once every load is in flight, so a login that was not
			// shared would show as a second call; bounded so a bug fails, not hangs.
			for deadline := time.Now().Add(3 * time.Second); time.Now().Before(deadline); time.Sleep(5 * time.Millisecond) {
				if auth.snapshot().statusCalls >= loads {
					return
				}
			}
		}
		auth.mu.Unlock()
		var wg sync.WaitGroup
		for range loads {
			wg.Add(1)
			go func() {
				defer GinkgoRecover()
				defer wg.Done()
				Expect(loginCookie(do(http.MethodGet, "/", navigation, token))).NotTo(BeNil())
			}()
		}
		wg.Wait()
		a := auth.snapshot()
		Expect(a.statusCalls).To(Equal(loads))
		Expect(a.calls).To(Equal(1))
	})

	It("logs in afresh when the browser's own login equals the cached one, which the session just refused", func() {
		Expect(loginCookie(do(http.MethodGet, "/", navigation, token))).NotTo(BeNil())
		Expect(auth.snapshot().calls).To(Equal(1))
		auth.mu.Lock()
		statusAnswer = "unauthenticated"
		auth.mu.Unlock()
		own := &http.Cookie{Name: prefixFor("riotbox-x") + "yep-anywhere-session", Value: "good"}
		Expect(loginCookie(do(http.MethodGet, "/", navigation, token, own))).NotTo(BeNil())
		Expect(auth.snapshot().calls).To(Equal(2))
	})

	It("keeps what it made for one session from another session's browser", func() {
		var mu sync.Mutex
		var upstreamSaw []string
		other := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			mu.Lock()
			upstreamSaw = append(upstreamSaw, r.URL.Path+" "+r.Header.Get("Cookie"))
			mu.Unlock()
			switch r.URL.Path {
			case "/api/auth/status":
				ck, err := r.Cookie("yep-anywhere-session")
				_, _ = fmt.Fprintf(w, `{"enabled":true,"authenticated":%t}`, err == nil && ck.Value == "y-good")
			case "/api/auth/login":
				w.Header().Add("Set-Cookie", "yep-anywhere-session=y-good; Path=/; HttpOnly; Secure")
				_, _ = io.WriteString(w, `{"success":true}`)
			default:
				_, _ = io.WriteString(w, "y:"+r.URL.Path)
			}
		}))
		DeferCleanup(other.Close)
		otherState := filepath.Join(GinkgoT().TempDir(), "key-y")
		writeCert(otherState, other.Certificate().Raw)
		Expect(os.WriteFile(filepath.Join(otherState, "anywhere-password"), []byte("pw-y\n"), 0o600)).To(Succeed())
		lister.set([]hub.Session{
			{Container: "riotbox-x", URL: upstream.URL, StateDir: stateDir},
			{Container: "riotbox-y", URL: other.URL, StateDir: otherState},
		}, nil)

		Expect(loginCookie(do(http.MethodGet, "/", navigation, token))).NotTo(BeNil())
		handler = server.SessionHandler(portOf(other.Listener.Addr()))
		w := do(http.MethodGet, "/", navigation, token)
		Expect(w.Body.String()).To(Equal("y:/"))
		mu.Lock()
		defer mu.Unlock()
		Expect(upstreamSaw).To(ContainElement("/ yep-anywhere-session=y-good"))
		for _, seen := range upstreamSaw {
			Expect(seen).NotTo(ContainSubstring("yep-anywhere-session=good"))
		}
	})

	It("keeps an entry nobody has finished a login on, and drops one that has gone stale", func() {
		server.TouchLogin("riotbox-x")
		server.TouchLogin("riotbox-y")
		Expect(server.HasLogin("riotbox-x")).To(BeTrue(), "a just-created entry was pruned")

		Expect(loginCookie(do(http.MethodGet, "/", navigation, token))).NotTo(BeNil())
		clock = clock.Add(11 * time.Second)
		server.TouchLogin("riotbox-y")
		Expect(server.HasLogin("riotbox-x")).To(BeFalse(), "a stale entry was kept")
	})

	DescribeTable("goes on unchanged, never logging in, when the status call goes wrong",
		func(answer, logged string) {
			statusAnswer = answer
			w := do(http.MethodGet, "/", navigation, token)
			Expect(w.Code).To(Equal(http.StatusOK))
			Expect(loginCookie(w)).To(BeNil())
			a := auth.snapshot()
			Expect(a.statusCalls).To(Equal(1))
			Expect(a.calls).To(BeZero())
			Expect(a.redirected).To(BeZero(), "the redirect was followed")
			Expect(got.snapshot().cookie).To(BeEmpty())
			if logged == "" {
				Expect(string(stderr.Contents())).NotTo(ContainSubstring("signing in"))
			} else {
				Expect(string(stderr.Contents())).To(MatchRegexp(`signing in to "riotbox-x" failed: ` + logged))
			}
			Expect(string(stderr.Contents())).NotTo(ContainSubstring("pw-123"))
		},
		Entry("a non-200 answer", "500", `auth status: 500`),
		Entry("a redirect, which is not followed", "302", `auth status: 302`),
		Entry("malformed JSON", "malformed", `auth status: `),
		Entry("authentication switched off, which is not a failure", "disabled", ""),
	)

	It("never logs the password when the session refuses it", func() {
		Expect(os.WriteFile(filepath.Join(stateDir, "anywhere-password"), []byte("pw-123-stale\n"), 0o600)).To(Succeed())
		w := do(http.MethodGet, "/", navigation, token)
		Expect(loginCookie(w)).To(BeNil())
		Expect(string(stderr.Contents())).To(ContainSubstring("login refused: 401"))
		Expect(string(stderr.Contents())).NotTo(ContainSubstring("pw-123"))
	})

	It("goes on unchanged, and says why, without a password file", func() {
		Expect(os.Remove(filepath.Join(stateDir, "anywhere-password"))).To(Succeed())
		w := do(http.MethodGet, "/", navigation, token)
		Expect(w.Code).To(Equal(http.StatusOK))
		Expect(auth.snapshot().calls).To(BeZero())
		Expect(stderr).To(gbytes.Say(`signing in to "riotbox-x" failed: .*anywhere-password`))
	})

	It("never sends the password to a session whose certificate is not the pinned one", func() {
		writeCert(stateDir, otherCert())
		w := do(http.MethodGet, "/", navigation, token)
		Expect(w.Code).To(Equal(http.StatusBadGateway))
		Expect(auth.snapshot().calls).To(BeZero())
	})

	It("proxies to the session on its port, addressed as the upstream, with its own headers", func() {
		w := do(http.MethodGet, "/api/x", http.Header{"Origin": {"https://" + hubIP + ":" + port}}, token)
		Expect(w.Code).To(Equal(http.StatusOK))
		Expect(w.Body.String()).To(Equal("yep:/api/x"))
		Expect(w.Header().Values("Content-Security-Policy")).To(Equal([]string{"upstream-csp"}))
		Expect(w.Header().Get("Cache-Control")).To(BeEmpty())
		s := got.snapshot()
		Expect(s.host).To(Equal(strings.TrimPrefix(upstream.URL, "https://")))
		Expect(s.origin).To(Equal(upstream.URL))
	})

	It("refuses without the hub token, before reaching the session", func() {
		Expect(do(http.MethodGet, "/api/x", nil).Code).To(Equal(http.StatusUnauthorized))
		Expect(got.snapshot().hits).To(BeZero())
	})

	DescribeTable("refuses a request from another origin, before reaching the session",
		func(origin string) {
			w := do(http.MethodPost, "/api/x", http.Header{"Origin": {origin}}, token)
			Expect(w.Code).To(Equal(http.StatusForbidden))
			Expect(got.snapshot().hits).To(BeZero())
		},
		Entry("another site", "https://evil.example"),
		Entry("another session's port on the hub", "https://"+hubIP+":1"),
		Entry("the list's port", "https://"+hubIP+":3399"),
		Entry("an opaque origin", "null"),
	)

	DescribeTable("refuses a subrequest from another port of the host, which carries no Origin",
		func(site, mode, dest string) {
			w := do(http.MethodGet, "/api/x", http.Header{
				"Sec-Fetch-Site": {site}, "Sec-Fetch-Mode": {mode}, "Sec-Fetch-Dest": {dest},
			}, token)
			Expect(w.Code).To(Equal(http.StatusForbidden))
			Expect(got.snapshot().hits).To(BeZero())
		},
		Entry("an image from another session's port", "same-site", "no-cors", "image"),
		Entry("a cross-site fetch", "cross-site", "cors", "empty"),
	)

	DescribeTable("lets a navigation in",
		func(site, mode, dest string) {
			w := do(http.MethodGet, "/api/x", http.Header{
				"Sec-Fetch-Site": {site}, "Sec-Fetch-Mode": {mode}, "Sec-Fetch-Dest": {dest},
			}, token)
			Expect(w.Code).To(Equal(http.StatusOK))
		},
		Entry("from the list's link", "same-site", "navigate", "document"),
		Entry("typed or bookmarked", "none", "navigate", "document"),
		Entry("the session's own fetch", "same-origin", "cors", "empty"),
	)

	It("accepts the token when a shadowing cookie comes first", func() {
		w := do(http.MethodGet, "/api/x", nil, &http.Cookie{Name: "riotbox_hub", Value: "planted"}, token)
		Expect(w.Code).To(Equal(http.StatusOK))
	})

	It("names the list when the token is missing", func() {
		w := do(http.MethodGet, "/api/x", nil)
		Expect(w.Code).To(Equal(http.StatusUnauthorized))
		Expect(w.Body.String()).To(ContainSubstring("https://" + hubIP + ":3399/"))
	})

	It("proxies a k parameter instead of taking it for the token", func() {
		w := do(http.MethodGet, "/api/x?k="+token.Value, nil)
		Expect(w.Code).To(Equal(http.StatusUnauthorized))
		w = do(http.MethodGet, "/api/x?k=whatever", nil, token)
		Expect(w.Code).To(Equal(http.StatusOK))
		Expect(w.Result().Cookies()).To(HaveLen(1)) // the session's, renamed; no hub cookie
		Expect(got.snapshot().path).To(Equal("/api/x"))
		Expect(got.snapshot().query).To(Equal("k=whatever"))
	})

	It("refuses a session whose certificate is not the one in its state dir, and logs why", func() {
		writeCert(stateDir, otherCert())
		w := do(http.MethodGet, "/api/x", nil, token)
		Expect(w.Code).To(Equal(http.StatusBadGateway))
		Expect(w.Body.String()).To(ContainSubstring("certificate mismatch"))
		Expect(w.Header().Get("Content-Security-Policy")).To(ContainSubstring("default-src 'none'"))
		Expect(stderr).To(gbytes.Say(`"riotbox-x": certificate mismatch\n`))
		Expect(got.snapshot().hits).To(BeZero())
	})

	It("refuses a session whose certificate changes after a request went through", func() {
		Expect(do(http.MethodGet, "/api/x", nil, token).Code).To(Equal(http.StatusOK))
		writeCert(stateDir, otherCert())
		w := do(http.MethodGet, "/api/y", nil, token)
		Expect(w.Code).To(Equal(http.StatusBadGateway))
		Expect(w.Body.String()).To(ContainSubstring("certificate mismatch"))
		Expect(got.snapshot().hits).To(Equal(1))
	})

	It("refuses a session with no certificate file", func() {
		Expect(os.Remove(filepath.Join(stateDir, "yep-anywhere", "https", "self-signed-cert.pem"))).To(Succeed())
		w := do(http.MethodGet, "/api/x", nil, token)
		Expect(w.Code).To(Equal(http.StatusBadGateway))
		Expect(w.Body.String()).To(ContainSubstring("certificate could not be read"))
		Expect(got.snapshot().hits).To(BeZero())
	})

	DescribeTable("refuses a certificate file the container could have planted, without hanging",
		func(plant func(path string)) {
			path := filepath.Join(stateDir, "yep-anywhere", "https", "self-signed-cert.pem")
			Expect(os.Remove(path)).To(Succeed())
			plant(path)
			done := make(chan int)
			go func() { done <- do(http.MethodGet, "/api/x", nil, token).Code }()
			Eventually(done, 3*time.Second).Should(Receive(Equal(http.StatusBadGateway)))
			Expect(got.snapshot().hits).To(BeZero())
		},
		Entry("a symlink out of the state dir, to the right certificate", func(path string) {
			outside := filepath.Join(GinkgoT().TempDir(), "cert.pem")
			pemBytes := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: upstream.Certificate().Raw})
			Expect(os.WriteFile(outside, pemBytes, 0o600)).To(Succeed())
			Expect(os.Symlink(outside, path)).To(Succeed())
		}),
		Entry("a symlink out of the state dir, to a device", func(path string) {
			Expect(os.Symlink("/dev/zero", path)).To(Succeed())
		}),
		Entry("a FIFO", func(path string) {
			Expect(syscall.Mkfifo(path, 0o600)).To(Succeed())
		}),
		Entry("a file over 64 KiB that starts with the right certificate", func(path string) {
			pemBytes := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: upstream.Certificate().Raw})
			Expect(os.WriteFile(path, append(pemBytes, bytes.Repeat([]byte("\n"), 64<<10)...), 0o600)).To(Succeed())
		}),
	)

	It("refreshes at once for a port it does not have, but at most once a second", func() {
		do(http.MethodGet, "/api/x", nil, token)
		Expect(lister.count()).To(Equal(1))
		handler = server.SessionHandler("1")
		Expect(do(http.MethodGet, "/api/x", nil, token).Code).To(Equal(http.StatusBadGateway))
		Expect(lister.count()).To(Equal(1))
		clock = clock.Add(1500 * time.Millisecond)
		do(http.MethodGet, "/api/x", nil, token)
		Expect(lister.count()).To(Equal(2))
		do(http.MethodGet, "/api/x", nil, token)
		Expect(lister.count()).To(Equal(2))
	})

	It("refuses a session with no state dir", func() {
		lister.set([]hub.Session{{Container: "riotbox-x", URL: upstream.URL}}, nil)
		w := do(http.MethodGet, "/api/x", nil, token)
		Expect(w.Code).To(Equal(http.StatusBadGateway))
		Expect(w.Body.String()).To(ContainSubstring("certificate could not be read"))
		Expect(stderr).To(gbytes.Say("the session has no state dir"))
		Expect(got.snapshot().hits).To(BeZero())
	})

	It("answers 502 when the session does not accept connections", func() {
		ln, err := net.Listen("tcp", "127.0.0.1:0")
		Expect(err).NotTo(HaveOccurred())
		port = portOf(ln.Addr())
		Expect(ln.Close()).To(Succeed())
		lister.set([]hub.Session{{Container: "riotbox-x", URL: "https://127.0.0.1:" + port, StateDir: stateDir}}, nil)
		handler = server.SessionHandler(port)
		w := do(http.MethodGet, "/api/x", nil, token)
		Expect(w.Code).To(Equal(http.StatusBadGateway))
		Expect(w.Body.String()).To(ContainSubstring("upstream unreachable"))
	})

	It("renames the session's cookies on the way down and forwards only its own on the way up", func() {
		w := do(http.MethodGet, "/api/x", nil, token,
			&http.Cookie{Name: prefixFor("riotbox-x") + "yep-anywhere-session", Value: "mine"},
			&http.Cookie{Name: prefixFor("riotbox-y") + "yep-anywhere-session", Value: "theirs"},
			&http.Cookie{Name: "plain", Value: "x"})
		Expect(w.Code).To(Equal(http.StatusOK))
		Expect(got.snapshot().cookie).To(Equal("yep-anywhere-session=mine"))
		raw := w.Header().Values("Set-Cookie")
		Expect(raw).To(HaveLen(1))
		Expect(raw[0]).NotTo(ContainSubstring("Domain"))
		set := w.Result().Cookies()
		Expect(set[0].Name).To(Equal(prefixFor("riotbox-x") + "yep-anywhere-session"))
		Expect(set[0].Value).To(Equal("abc"))
		Expect(set[0].HttpOnly).To(BeTrue())
	})

	It("forces HttpOnly on every cookie, so no script on another port can read it", func() {
		w := do(http.MethodGet, "/plain-cookie", nil, token)
		var plain *http.Cookie
		for _, c := range w.Result().Cookies() {
			if c.Name == prefixFor("riotbox-x")+"readable" {
				plain = c
			}
		}
		Expect(plain).NotTo(BeNil())
		Expect(plain.HttpOnly).To(BeTrue())
	})

	It("drops Clear-Site-Data, which would act on every port", func() {
		w := do(http.MethodGet, "/clear", nil, token)
		Expect(w.Code).To(Equal(http.StatusOK))
		Expect(w.Header().Get("Clear-Site-Data")).To(BeEmpty())
	})

	It("drops a Set-Cookie it cannot rename, and logs it", func() {
		w := do(http.MethodGet, "/bad-cookie", nil, token)
		Expect(w.Code).To(Equal(http.StatusOK))
		Expect(w.Header().Values("Set-Cookie")).To(HaveLen(1))
		Expect(w.Result().Cookies()[0].Name).To(Equal(prefixFor("riotbox-x") + "yep-anywhere-session"))
		Expect(stderr).To(gbytes.Say(`"riotbox-x": dropped a Set-Cookie`))
	})

	It("sends a navigation to a gone session back to the list, and answers anything else 502", func() {
		lister.set(nil, nil)
		nav := do(http.MethodGet, "/", http.Header{"Accept": {"text/html,application/xhtml+xml"}}, token)
		Expect(nav.Code).To(Equal(http.StatusSeeOther))
		Expect(nav.Header().Get("Location")).To(Equal("https://" + hubIP + ":3399/"))
		api := do(http.MethodGet, "/api/x", http.Header{"Accept": {"application/json"}}, token)
		Expect(api.Code).To(Equal(http.StatusBadGateway))
		Expect(api.Body.String()).To(ContainSubstring("session gone"))
		Expect(stderr).To(gbytes.Say(`"port ` + port + `": session gone`))
		Expect(got.snapshot().hits).To(BeZero())
	})

	It("lists at most every 5 seconds", func() {
		do(http.MethodGet, "/api/x", nil, token)
		do(http.MethodGet, "/api/x", nil, token)
		Expect(lister.count()).To(Equal(1))
		clock = clock.Add(6 * time.Second)
		do(http.MethodGet, "/api/x", nil, token)
		Expect(lister.count()).To(Equal(2))
	})

	It("answers 502 and logs when the engine fails before anything is known, then recovers with it", func() {
		lister.set(lister.sessions, errors.New("podman: not running"))
		w := do(http.MethodGet, "/api/x", nil, token)
		Expect(w.Code).To(Equal(http.StatusBadGateway))
		Expect(w.Body.String()).To(ContainSubstring("listing the sessions failed"))
		Expect(stderr).To(gbytes.Say(`"port ` + port + `": listing the sessions failed: podman: not running`))
		clock = clock.Add(2 * time.Second)
		lister.set(lister.sessions, nil)
		Expect(do(http.MethodGet, "/api/x", nil, token).Code).To(Equal(http.StatusOK))
	})

	It("serves a session it knows while the engine fails, and asks the engine at most once a second", func() {
		Expect(do(http.MethodGet, "/api/x", nil, token).Code).To(Equal(http.StatusOK))
		Expect(lister.count()).To(Equal(1))
		lister.set(lister.sessions, errors.New("podman: not running"))
		clock = clock.Add(6 * time.Second)
		Expect(do(http.MethodGet, "/api/x", nil, token).Code).To(Equal(http.StatusOK))
		Expect(lister.count()).To(Equal(2))
		Expect(stderr).To(gbytes.Say("listing the sessions failed: podman: not running"))
		Expect(do(http.MethodGet, "/api/x", nil, token).Code).To(Equal(http.StatusOK))
		Expect(lister.count()).To(Equal(2))
		handler = server.SessionHandler("1")
		w := do(http.MethodGet, "/api/x", nil, token)
		Expect(w.Code).To(Equal(http.StatusBadGateway))
		Expect(w.Body.String()).To(ContainSubstring("listing the sessions failed"))
		Expect(lister.count()).To(Equal(2))
		clock = clock.Add(2 * time.Second)
		lister.set(lister.sessions, nil)
		handler = server.SessionHandler(port)
		Expect(do(http.MethodGet, "/api/x", nil, token).Code).To(Equal(http.StatusOK))
		Expect(lister.count()).To(Equal(3))
	})

	It("does not hold a lookup behind a slow listing", func() {
		slow := &blockingLister{sessions: lister.sessions, release: make(chan struct{})}
		DeferCleanup(slow.unblock)
		server.Lister = slow
		Expect(do(http.MethodGet, "/api/x", nil, token).Code).To(Equal(http.StatusOK))
		slow.setBlock()
		clock = clock.Add(6 * time.Second)
		done1 := make(chan int, 1)
		go func() { done1 <- do(http.MethodGet, "/api/x", nil, token).Code }()
		Eventually(slow.waiting).Should(BeTrue())
		done2 := make(chan int, 1)
		go func() { done2 <- do(http.MethodGet, "/api/x", nil, token).Code }()
		Eventually(done2, time.Second).Should(Receive(Equal(http.StatusOK)))
		slow.unblock()
		Eventually(done1).Should(Receive(Equal(http.StatusOK)))
	})

	Describe("WebSocket", func() {
		var conn net.Conn

		BeforeEach(func() {
			hubSrv := httptest.NewServer(handler)
			DeferCleanup(hubSrv.Close)
			var err error
			conn, err = net.Dial("tcp", hubSrv.Listener.Addr().String())
			Expect(err).NotTo(HaveOccurred())
			DeferCleanup(conn.Close)
			Expect(conn.SetDeadline(time.Now().Add(5 * time.Second))).To(Succeed())
		})

		upgrade := func(origin string) (*http.Response, *bufio.Reader) {
			_, err := io.WriteString(conn, "GET /api/ws HTTP/1.1\r\nHost: "+hubIP+":"+port+"\r\nOrigin: "+origin+
				"\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nCookie: "+token.Name+"="+token.Value+
				"; "+prefixFor("riotbox-x")+"yep-anywhere-session=mine\r\n\r\n")
			Expect(err).NotTo(HaveOccurred())
			br := bufio.NewReader(conn)
			resp, err := http.ReadResponse(br, nil)
			Expect(err).NotTo(HaveOccurred())
			return resp, br
		}

		It("relays an upgrade both ways, addressed as the upstream", func() {
			resp, br := upgrade("https://" + hubIP + ":" + port)
			Expect(resp.StatusCode).To(Equal(http.StatusSwitchingProtocols))
			_, err := io.WriteString(conn, "ping")
			Expect(err).NotTo(HaveOccurred())
			echoed := make([]byte, 4)
			_, err = io.ReadFull(br, echoed)
			Expect(err).NotTo(HaveOccurred())
			Expect(string(echoed)).To(Equal("ping"))
			s := got.snapshot()
			Expect(s.origin).To(Equal(upstream.URL))
			Expect(s.host).To(Equal(strings.TrimPrefix(upstream.URL, "https://")))
			Expect(s.cookie).To(Equal("yep-anywhere-session=mine"))
		})

		It("refuses an upgrade from another origin", func() {
			resp, _ := upgrade("https://" + hubIP + ":1")
			Expect(resp.StatusCode).To(Equal(http.StatusForbidden))
			Expect(got.snapshot().hits).To(BeZero())
		})
	})
})

// The engine's own words for a taken port do not say who took it; the
// list does.
var _ = DescribeTable("BusyReason",
	func(hubHost, sessionURL string, err error, want string) {
		Expect(hub.BusyReason(hubHost, hub.Session{URL: sessionURL}, "3400", err)).To(ContainSubstring(want))
	},
	Entry("the session published on the hub's own address",
		"172.16.10.105", "https://172.16.10.105:3400", syscall.EADDRINUSE,
		"the session is published on 172.16.10.105:3400 itself"),
	Entry("the session published on the wildcard",
		"172.16.10.105", "https://0.0.0.0:3400", syscall.EADDRINUSE,
		"the session is published on 0.0.0.0:3400 itself"),
	Entry("the hub bound to the wildcard",
		"0.0.0.0", "https://127.0.0.1:3400", syscall.EADDRINUSE,
		"the hub is bound to 0.0.0.0, which overlaps the session's 127.0.0.1:3400"),
	Entry("the hub bound to loopback, as the session is",
		"127.0.0.1", "https://127.0.0.1:3400", syscall.EADDRINUSE,
		"the hub is bound to 127.0.0.1, which overlaps the session's 127.0.0.1:3400"),
	Entry("something else on the hub's address",
		"172.16.10.105", "https://127.0.0.1:3400", syscall.EADDRINUSE,
		"172.16.10.105:3400 is taken by another program"),
	Entry("any other failure, in the system's words",
		"172.16.10.105", "https://127.0.0.1:3400", syscall.EACCES,
		"permission denied"),
)

var _ = DescribeTable("UpstreamAddr",
	func(url, want string) {
		got, err := hub.UpstreamAddr(hub.Session{URL: url})
		if want == "" {
			Expect(err).To(HaveOccurred())
			return
		}
		Expect(err).NotTo(HaveOccurred())
		Expect(got).To(Equal(want))
	},
	Entry("loopback", "https://127.0.0.1:3400", "127.0.0.1:3400"),
	Entry("a LAN address", "https://192.168.1.20:3401", "192.168.1.20:3401"),
	Entry("the IPv4 wildcard, reached on loopback", "https://0.0.0.0:3400", "127.0.0.1:3400"),
	Entry("the IPv6 wildcard, reached on loopback", "https://[::]:3400", "[::1]:3400"),
	Entry("an IPv6 address", "https://[fd00::20]:3401", "[fd00::20]:3401"),
	Entry("a host name", "https://example.com:3400", ""),
	Entry("no port", "https://127.0.0.1", ""),
)

// The hub listens on 127.0.0.2 so it can take the port number the fake
// session holds on 127.0.0.1, as it takes a loopback session's port on the
// LAN address.
var _ = Describe("Serving session ports", func() {
	var (
		port     string
		stateDir string
		lister   *countingLister
		server   *hub.Server
		cert     tls.Certificate
		listAddr string
		token    string
		client   *http.Client
		stderr   *gbytes.Buffer
		advance  func(time.Duration)
		relist   time.Duration
	)

	BeforeEach(func() {
		upstream := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			_, _ = io.WriteString(w, "yep:"+r.URL.Path)
		}))
		DeferCleanup(upstream.Close)
		port = portOf(upstream.Listener.Addr())
		stateDir = filepath.Join(GinkgoT().TempDir(), "key-x")
		writeCert(stateDir, upstream.Certificate().Raw)
		lister = &countingLister{sessions: []hub.Session{{Container: "riotbox-x", URL: upstream.URL, StateDir: stateDir}}}
		// The list's port is fixed up front: the hub names its list by Addr,
		// which a ":0" would leave without a port.
		probe, err := net.Listen("tcp", "127.0.0.2:0")
		Expect(err).NotTo(HaveOccurred())
		listAddr = probe.Addr().String()
		Expect(probe.Close()).To(Succeed())
		var clockMu sync.Mutex
		clock := time.Now()
		advance = func(d time.Duration) {
			clockMu.Lock()
			defer clockMu.Unlock()
			clock = clock.Add(d)
		}
		stderr = gbytes.NewBuffer()
		server = &hub.Server{
			Addr: listAddr, DataDir: filepath.Join(GinkgoT().TempDir(), "hub"), Lister: lister,
			Now: func() time.Time {
				clockMu.Lock()
				defer clockMu.Unlock()
				return clock
			},
			Stderr: io.MultiWriter(GinkgoWriter, stderr),
		}
		var link string
		link, cert, err = server.Prepare()
		Expect(err).NotTo(HaveOccurred())
		token = link[strings.Index(link, "?k=")+3:]
		client = &http.Client{
			Timeout: 5 * time.Second,
			// The test trusts the hub's own certificate blindly; the hub's
			// pinning of the session's certificate is what is under test. No
			// keep-alive: a closed port must refuse the next request, not
			// leave it an idle connection.
			Transport:     &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}, DisableKeepAlives: true},
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		}
		relist = time.Hour // no re-list by itself unless a spec asks for it
	})

	JustBeforeEach(func() {
		DeferCleanup(hub.SetRelistEvery(relist))
		ln, err := server.Listen()
		Expect(err).NotTo(HaveOccurred())
		go func() { _ = server.Serve(ln, cert) }()
		DeferCleanup(func() {
			// An empty list closes the session ports before the next spec.
			lister.set(nil, nil)
			req, err := http.NewRequest(http.MethodGet, "https://"+listAddr+"/", nil)
			Expect(err).NotTo(HaveOccurred())
			req.AddCookie(&http.Cookie{Name: "riotbox_hub", Value: token})
			resp, err := client.Do(req)
			Expect(err).NotTo(HaveOccurred())
			Expect(resp.Body.Close()).To(Succeed())
			_ = ln.Close()
		})
	})

	get := func(addr, path string) (int, string) {
		req, err := http.NewRequest(http.MethodGet, "https://"+addr+path, nil)
		Expect(err).NotTo(HaveOccurred())
		req.AddCookie(&http.Cookie{Name: "riotbox_hub", Value: token})
		resp, err := client.Do(req)
		Expect(err).NotTo(HaveOccurred())
		defer func() { _ = resp.Body.Close() }()
		b, err := io.ReadAll(resp.Body)
		Expect(err).NotTo(HaveOccurred())
		return resp.StatusCode, string(b)
	}

	// dial is a request to addr, for whether anything listens there.
	dial := func(addr string) func() error {
		return func() error {
			resp, err := client.Get("https://" + addr + "/")
			if err == nil {
				_ = resp.Body.Close()
			}
			return err
		}
	}

	It("links a session to its own port on the hub and serves it there", func() {
		_, page := get(listAddr, "/")
		Expect(page).To(ContainSubstring(`href="https://127.0.0.2:` + port + `/"`))
		code, body := get("127.0.0.2:"+port, "/api/x")
		Expect(code).To(Equal(http.StatusOK))
		Expect(body).To(Equal("yep:/api/x"))
	})

	It("stops serving a session's port once the list no longer has it", func() {
		get(listAddr, "/")
		lister.set(nil, nil)
		get(listAddr, "/")
		Eventually(dial("127.0.0.2:" + port)).Should(MatchError(ContainSubstring("connection refused")))
	})

	It("still answers the navigation whose refresh closes its port", func() {
		_, page := get(listAddr, "/")
		Expect(page).To(ContainSubstring(`href="https://127.0.0.2:` + port + `/"`))
		lister.set(nil, nil)
		advance(6 * time.Second)
		req, err := http.NewRequest(http.MethodGet, "https://127.0.0.2:"+port+"/", nil)
		Expect(err).NotTo(HaveOccurred())
		req.Header.Set("Accept", "text/html")
		req.AddCookie(&http.Cookie{Name: "riotbox_hub", Value: token})
		resp, err := client.Do(req)
		Expect(err).NotTo(HaveOccurred())
		Expect(resp.Body.Close()).To(Succeed())
		Expect(resp.StatusCode).To(Equal(http.StatusSeeOther))
		Expect(resp.Header.Get("Location")).To(Equal("https://" + listAddr + "/"))
		Eventually(dial("127.0.0.2:" + port)).Should(MatchError(ContainSubstring("connection refused")))
	})

	It("fronts neither of two sessions publishing one port", func() {
		get(listAddr, "/")
		lister.set([]hub.Session{
			{Container: "riotbox-x", URL: "https://127.0.0.1:" + port, StateDir: stateDir},
			{Container: "riotbox-y", URL: "https://127.0.0.3:" + port, StateDir: stateDir},
		}, nil)
		_, page := get(listAddr, "/")
		Expect(page).To(ContainSubstring(`href="https://127.0.0.1:` + port + `/"`))
		Expect(page).To(ContainSubstring(`href="https://127.0.0.3:` + port + `/"`))
		Expect(strings.Count(page, "two sessions publish port "+port)).To(Equal(2))
		Eventually(dial("127.0.0.2:" + port)).Should(MatchError(ContainSubstring("connection refused")))
	})

	It("links directly, saying why, to a session whose port the hub cannot take; retries it, and logs the failure once", func() {
		busy, err := net.Listen("tcp", "127.0.0.2:0")
		Expect(err).NotTo(HaveOccurred())
		DeferCleanup(func() { _ = busy.Close() })
		busyPort := portOf(busy.Addr())
		lister.set([]hub.Session{{Container: "riotbox-busy", URL: "https://127.0.0.1:" + busyPort}}, nil)
		_, page := get(listAddr, "/")
		Expect(page).To(ContainSubstring(`href="https://127.0.0.1:` + busyPort + `/"`))
		Expect(page).To(ContainSubstring("Not through the hub"))
		Expect(page).To(ContainSubstring("127.0.0.2:" + busyPort + " is taken by another program"))
		get(listAddr, "/")
		Expect(strings.Count(string(stderr.Contents()), "is taken by another program")).To(Equal(1))
		Expect(busy.Close()).To(Succeed())
		_, page = get(listAddr, "/")
		Expect(page).To(ContainSubstring(`href="https://127.0.0.2:` + busyPort + `/"`))
	})

	Describe("re-listing by itself", func() {
		BeforeEach(func() { relist = 50 * time.Millisecond })

		It("releases a finished session's port without anyone looking at the list", func() {
			get(listAddr, "/")
			lister.set(nil, nil)
			Eventually(dial("127.0.0.2:" + port)).Should(MatchError(ContainSubstring("connection refused")))
		})
	})
})
