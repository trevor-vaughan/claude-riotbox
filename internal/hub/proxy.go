package hub

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

// signInReuse is how long the hub reuses a login it made for a session:
// parallel tabs, and a browser that dropped the cookie, share it instead
// of each making a Yep Anywhere login (each is a bcrypt check and an entry
// in its auth.json).
const signInReuse = 10 * time.Second

// recentLogin is the last login the hub made for one session. Its mu is
// held across the login, so concurrent page loads wait for one login.
type recentLogin struct {
	mu sync.Mutex
	ck *http.Cookie
	at time.Time
}

// listMaxAge bounds how stale the list a session port resolves against may be.
const listMaxAge = 5 * time.Second

// missRefresh bounds refreshes for ports the list does not have: a browser still open on a gone session keeps asking.
const missRefresh = time.Second

// certFile is where Yep Anywhere's --https-self-signed keeps its
// certificate, under a session's state dir (scripts/mount-projects.sh
// mounts <state dir>/yep-anywhere as its data dir).
var certFile = filepath.Join("yep-anywhere", "https", "self-signed-cert.pem")

// passwordFile is where the launcher keeps a session's Yep Anywhere
// password, directly in its state dir, which no container mounts
// (anywhere_password in libexec/anywhere-lib.sh).
const passwordFile = "anywhere-password"

// maxPasswordSize bounds the password read.
const maxPasswordSize = 1 << 10

// loginCookie is the cookie Yep Anywhere's login sets.
const loginCookie = "yep-anywhere-session"

// errCertMismatch is a session presenting a certificate other than the one
// in its state dir.
var errCertMismatch = errors.New("certificate mismatch")

// relistEvery is how often the hub re-lists by itself, so a finished
// session's port is released even when no one looks at the list.
var relistEvery = 15 * time.Second

// sessionCache is the session list the hub serves from. Every successful
// listing goes to onList (the session ports' reconciliation).
type sessionCache struct {
	list   func() ([]Session, error)
	now    func() time.Time
	onList func([]Session)
	stderr io.Writer

	// refreshing serializes engine calls and reconciliation. It is held
	// without mu, so a lookup that has an answer never waits on the engine.
	refreshing sync.Mutex

	mu       sync.Mutex
	listed   bool
	at       time.Time // the last successful listing
	failedAt time.Time // the last failed listing; zero after a success
	lastErr  error
	sessions []Session // the last successful listing, kept through failures
}

// fresh lists now: the list page and the periodic re-list.
func (c *sessionCache) fresh() ([]Session, error) {
	c.refreshing.Lock()
	defer c.refreshing.Unlock()
	return c.refresh()
}

// lookup returns the listed session publishing port. The list is
// refreshed when older than listMaxAge, or at once (at most every
// missRefresh) when it does not have the port. While the engine fails, or
// another lookup is refreshing, a port the last list has is served from
// it; pinning still guards the connection.
func (c *sessionCache) lookup(port string) (Session, bool, error) {
	c.mu.Lock()
	s, ok := c.find(port)
	now := c.now()
	at, failedAt, lastErr := c.at, c.failedAt, c.lastErr
	fresh := c.listed && now.Sub(at) < listMaxAge
	c.mu.Unlock()
	switch {
	case ok && fresh:
		return s, true, nil
	case !ok && fresh && now.Sub(at) < missRefresh:
		return Session{}, false, nil
	case !failedAt.IsZero() && now.Sub(failedAt) < missRefresh:
		if ok {
			return s, true, nil
		}
		return Session{}, false, lastErr
	}
	if ok {
		if !c.refreshing.TryLock() {
			return s, true, nil
		}
	} else {
		c.refreshing.Lock()
	}
	defer c.refreshing.Unlock()
	c.mu.Lock()
	moved := c.at != at || c.failedAt != failedAt
	c.mu.Unlock()
	if !moved {
		if _, err := c.refresh(); err != nil && !ok {
			return Session{}, false, err
		}
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if s, ok := c.find(port); ok {
		return s, true, nil
	}
	if c.lastErr != nil {
		return Session{}, false, c.lastErr
	}
	return Session{}, false, nil
}

// find returns the one listed session publishing port; c.mu must be held.
// A port two sessions publish is nobody's (reconcile does not serve it).
func (c *sessionCache) find(port string) (Session, bool) {
	var found []Session
	for _, s := range c.sessions {
		if publishedPort(s) == port {
			found = append(found, s)
		}
	}
	if len(found) != 1 {
		return Session{}, false
	}
	return found[0], true
}

// refresh calls the engine; c.refreshing must be held. A failure is
// logged when it differs from the one before.
func (c *sessionCache) refresh() ([]Session, error) {
	sessions, err := c.list()
	now := c.now()
	c.mu.Lock()
	if err != nil {
		if c.lastErr == nil || c.lastErr.Error() != err.Error() {
			_, _ = fmt.Fprintf(c.stderr, "riotbox-core: hub: listing the sessions failed: %v\n", err)
		}
		c.failedAt, c.lastErr = now, err
	} else {
		c.listed, c.at, c.failedAt, c.lastErr, c.sessions = true, now, time.Time{}, nil, sessions
	}
	c.mu.Unlock()
	if err != nil {
		return nil, err
	}
	c.onList(sessions)
	return sessions, nil
}

// publishedPort is the port s publishes Yep Anywhere on; Lister has checked
// its URL has one.
func publishedPort(s Session) string {
	u, err := url.Parse(s.URL)
	if err != nil {
		return ""
	}
	return u.Port()
}

// sessionPorts are the hub's listeners for the sessions: one per port a
// listed session publishes on, on the hub's own address, so that each
// session is its own origin in the browser.
type sessionPorts struct {
	host    string                         // the hub's listen host
	handler func(port string) http.Handler // what a session port serves
	stderr  io.Writer

	mu      sync.Mutex
	cert    *tls.Certificate // nil until start: no session port opens before the hub serves
	servers map[string]*http.Server
	failed  map[string]string // the last listen error, by port
}

func (p *sessionPorts) start(cert tls.Certificate) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.cert = &cert
}

// reconcile serves exactly the ports sessions publish on. A port the hub
// cannot listen on is retried on the next call; its error is logged once
// and shown on the list.
func (p *sessionPorts) reconcile(sessions []Session) {
	count := map[string]int{}
	bySession := map[string]Session{}
	for _, s := range sessions {
		if port := publishedPort(s); port != "" {
			count[port]++
			bySession[port] = s
		}
	}
	want := map[string]bool{}
	for port, n := range count {
		if n == 1 {
			want[port] = true
		}
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.cert == nil {
		return
	}
	// Shut down in the background: the request whose refresh removed its
	// own port still gets its answer.
	for port, srv := range p.servers {
		if !want[port] {
			delete(p.servers, port)
			go func() {
				ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
				defer cancel()
				if err := srv.Shutdown(ctx); err != nil {
					_, _ = fmt.Fprintf(p.stderr, "riotbox-core: hub: port %s: %v\n", port, err)
					_ = srv.Close()
				}
			}()
		}
	}
	for port := range p.failed {
		if !want[port] && count[port] < 2 {
			delete(p.failed, port)
		}
	}
	// A port two sessions publish is fronted for neither: which one the
	// browser reached would depend on the list's order.
	for port, n := range count {
		if n > 1 {
			msg := fmt.Sprintf("two sessions publish port %s", port)
			if p.failed[port] != msg {
				_, _ = fmt.Fprintf(p.stderr, "riotbox-core: hub: port %s: %s\n", port, msg)
			}
			p.failed[port] = msg
		}
	}
	for port := range want {
		if _, ok := p.servers[port]; ok {
			continue
		}
		ln, err := net.Listen("tcp", net.JoinHostPort(p.host, port))
		if err != nil {
			msg := busyReason(p.host, bySession[port], port, err)
			if p.failed[port] != msg {
				_, _ = fmt.Fprintf(p.stderr, "riotbox-core: hub: port %s: %s\n", port, msg)
			}
			p.failed[port] = msg
			continue
		}
		delete(p.failed, port)
		srv := &http.Server{
			Handler:           p.handler(port),
			ReadHeaderTimeout: 10 * time.Second,
			TLSConfig:         &tls.Config{Certificates: []tls.Certificate{*p.cert}, MinVersion: tls.VersionTLS12},
		}
		p.servers[port] = srv
		go func() {
			if err := srv.ServeTLS(ln, "", ""); !errors.Is(err, http.ErrServerClosed) {
				_, _ = fmt.Fprintf(p.stderr, "riotbox-core: hub: port %s: %v\n", port, err)
			}
		}()
	}
}

// busyReason says why the hub could not listen on hubHost:port for s. A
// port in use is most often the session's own: it was published on the
// hub's address or the wildcard, or the hub is bound where the session is.
// The system's "address already in use" names none of that.
func busyReason(hubHost string, s Session, port string, err error) string {
	if !errors.Is(err, syscall.EADDRINUSE) {
		return err.Error()
	}
	hub := net.ParseIP(hubHost)
	var published string
	var ip net.IP
	if u, perr := url.Parse(s.URL); perr == nil {
		published, ip = u.Host, net.ParseIP(u.Hostname())
	}
	switch {
	case hub != nil && ip != nil && (hub.IsUnspecified() || hub.IsLoopback() && ip.Equal(hub)):
		return fmt.Sprintf("the hub is bound to %s, which overlaps the session's %s; bind the hub to this host's LAN address (RIOTBOX_HUB_BIND) to front it", hubHost, published)
	case hub != nil && ip != nil && (ip.Equal(hub) || ip.IsUnspecified()):
		return fmt.Sprintf("the session is published on %s itself, so the hub cannot take the port; start it with RIOTBOX_ANYWHERE_BIND on loopback (the default) for the hub to front it", published)
	default:
		return fmt.Sprintf("%s is taken by another program", net.JoinHostPort(hubHost, port))
	}
}

// status reports whether the hub serves port, or why not.
func (p *sessionPorts) status(port string) (served bool, reason string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.cert == nil {
		return false, "the hub is not serving session ports yet"
	}
	if _, ok := p.servers[port]; ok {
		return true, ""
	}
	if reason, ok := p.failed[port]; ok {
		return false, reason
	}
	return false, "the hub has not listened for it yet"
}

// sessionHandler is what the hub serves on port: the guard without the
// token exchange (a k parameter there is the session's), then the proxy.
func (s *Server) sessionHandler(port string) http.Handler {
	return s.guard(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.proxy(w, r, port)
	}), false)
}

// proxy serves a request on a session port from the session publishing
// that port.
func (s *Server) proxy(w http.ResponseWriter, r *http.Request, port string) {
	// The browser's own origin is the Host guard has already accepted, so
	// another session's port is another origin and is refused.
	if o := r.Header.Get("Origin"); o != "" && o != "https://"+r.Host {
		http.Error(w, "cross-origin request refused", http.StatusForbidden)
		return
	}
	// Ports are not sites: a subrequest from another session's port is
	// same-site and may carry no Origin, yet it carries the cookies.
	switch r.Header.Get("Sec-Fetch-Site") {
	case "", "same-origin", "none":
	case "same-site":
		if r.Header.Get("Sec-Fetch-Mode") != "navigate" || r.Header.Get("Sec-Fetch-Dest") != "document" {
			http.Error(w, "cross-origin request refused", http.StatusForbidden)
			return
		}
	default:
		http.Error(w, "cross-origin request refused", http.StatusForbidden)
		return
	}
	sess, ok, err := s.cache.lookup(port)
	if err != nil {
		s.fail(w, "port "+port, "listing the sessions failed", err)
		return
	}
	if !ok {
		if isNavigation(r) {
			http.Redirect(w, r, s.listURL(r), http.StatusSeeOther)
			return
		}
		s.fail(w, "port "+port, "session gone", nil)
		return
	}
	addr, err := upstreamAddr(sess)
	if err != nil {
		s.fail(w, sess.Container, "upstream unreachable", err)
		return
	}
	der, err := pinnedCert(sess.StateDir)
	if err != nil {
		s.fail(w, sess.Container, "the session's certificate could not be read", err)
		return
	}
	// Every session's Yep Anywhere names its login cookie the same, and
	// cookies ignore ports: each session's cookies carry its own prefix in
	// the browser.
	sum := sha256.Sum256([]byte(sess.Container))
	prefix := "rb" + hex.EncodeToString(sum[:4]) + "-"
	transport := s.upstreams.transport(addr, der)
	var signedIn *http.Cookie
	if isNavigation(r) {
		signedIn = s.signIn(r, sess, addr, transport, prefix)
	}
	rp := &httputil.ReverseProxy{
		Transport:     transport,
		FlushInterval: -1,
		ErrorLog:      log.New(s.stderr(), fmt.Sprintf("riotbox-core: hub: %q: ", sess.Container), 0),
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.SetURL(&url.URL{Scheme: "https", Host: addr})
			if pr.In.Header.Get("Origin") != "" {
				pr.Out.Header.Set("Origin", "https://"+addr)
			}
			pr.Out.Header.Del("Cookie")
			for _, ck := range pr.In.Cookies() {
				if name, ok := strings.CutPrefix(ck.Name, prefix); ok && name != "" {
					if signedIn != nil && name == loginCookie {
						continue
					}
					pr.Out.AddCookie(&http.Cookie{Name: name, Value: ck.Value})
				}
			}
			if signedIn != nil {
				pr.Out.AddCookie(&http.Cookie{Name: loginCookie, Value: signedIn.Value})
			}
		},
		ModifyResponse: func(resp *http.Response) error {
			// It acts on the whole host, every port and the hub's token too.
			resp.Header.Del("Clear-Site-Data")
			lines := resp.Header.Values("Set-Cookie")
			resp.Header.Del("Set-Cookie")
			for _, line := range lines {
				ck, err := http.ParseSetCookie(line)
				if err != nil {
					// Passing it on unrenamed would let it reach other sessions.
					_, _ = fmt.Fprintf(s.stderr(), "riotbox-core: hub: %q: dropped a Set-Cookie: %v\n", sess.Container, err)
					continue
				}
				if v := renamed(ck, prefix); v != "" {
					resp.Header.Add("Set-Cookie", v)
				}
			}
			if signedIn != nil {
				if v := renamed(signedIn, prefix); v != "" {
					resp.Header.Add("Set-Cookie", v)
				}
			}
			return nil
		},
		ErrorHandler: func(w http.ResponseWriter, _ *http.Request, err error) {
			cause := "upstream unreachable"
			if errors.Is(err, errCertMismatch) {
				// The cause already says it; logging err too would repeat it.
				cause, err = "certificate mismatch", nil
			}
			s.fail(w, sess.Container, cause, err)
		},
	}
	for k := range hubHeaders {
		w.Header().Del(k)
	}
	rp.ServeHTTP(w, r)
}

// fail answers 502 naming cause, and logs one line naming what failed
// (quoted: it may come from the request).
func (s *Server) fail(w http.ResponseWriter, name, cause string, err error) {
	line := fmt.Sprintf("%q: %s", name, cause)
	if err != nil {
		line += ": " + err.Error()
	}
	_, _ = fmt.Fprintf(s.stderr(), "riotbox-core: hub: %s\n", line)
	for k, v := range hubHeaders {
		w.Header().Set(k, v)
	}
	http.Error(w, cause, http.StatusBadGateway)
}

// upstreamAddr is where the hub dials s: the address it publishes on, with
// a wildcard replaced by the loopback of the same family.
func upstreamAddr(s Session) (string, error) {
	u, err := url.Parse(s.URL)
	if err != nil {
		return "", err
	}
	ip := net.ParseIP(u.Hostname())
	if ip == nil || u.Port() == "" {
		return "", fmt.Errorf("%q is not an IP address and port", s.URL)
	}
	if ip.IsUnspecified() {
		if ip.To4() != nil {
			ip = net.IPv4(127, 0, 0, 1)
		} else {
			ip = net.IPv6loopback
		}
	}
	return net.JoinHostPort(ip.String(), u.Port()), nil
}

// maxCertSize bounds the certificate read: the file is container-writable.
const maxCertSize = 64 << 10

// readStateFile reads name in stateDir, at most limit bytes. Parts of the
// state dir are container-writable, so the file is opened inside it (no
// symlink out of it), non-blocking (a FIFO cannot hang the hub), and must
// be a regular file.
func readStateFile(stateDir, name string, limit int64) ([]byte, error) {
	if stateDir == "" {
		return nil, errors.New("the session has no state dir")
	}
	root, err := os.OpenRoot(stateDir)
	if err != nil {
		return nil, err
	}
	defer func() { _ = root.Close() }()
	f, err := root.OpenFile(name, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	defer func() { _ = f.Close() }()
	path := filepath.Join(stateDir, name)
	info, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() {
		return nil, fmt.Errorf("%s is not a regular file", path)
	}
	b, err := io.ReadAll(io.LimitReader(f, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(b)) > limit {
		return nil, fmt.Errorf("%s is larger than %d bytes", path, limit)
	}
	return b, nil
}

// pinnedCert returns the DER certificate Yep Anywhere keeps in the
// session's state dir, read afresh for each request.
func pinnedCert(stateDir string) ([]byte, error) {
	b, err := readStateFile(stateDir, certFile, maxCertSize)
	if err != nil {
		return nil, err
	}
	path := filepath.Join(stateDir, certFile)
	block, _ := pem.Decode(b)
	if block == nil || block.Type != "CERTIFICATE" {
		return nil, fmt.Errorf("%s holds no PEM certificate", path)
	}
	if _, err := x509.ParseCertificate(block.Bytes); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return block.Bytes, nil
}

// isNavigation reports a top-level page load, as opposed to a page's own
// requests. Browsers without Sec-Fetch headers are judged by Accept.
func isNavigation(r *http.Request) bool {
	if r.Method != http.MethodGet {
		return false
	}
	if mode := r.Header.Get("Sec-Fetch-Mode"); mode != "" {
		return mode == "navigate"
	}
	return strings.Contains(r.Header.Get("Accept"), "text/html")
}

// renamed is ck as the browser gets it: with the session's prefix, no
// Domain, and HttpOnly. Cookies ignore ports: a script on any session port
// could read another session's cookie; Yep Anywhere's client never reads
// cookies (no document.cookie), so HttpOnly breaks nothing. String drops
// attributes Cookie does not model (Unparsed); Yep Anywhere 0.11.0 sets
// none.
func renamed(ck *http.Cookie, prefix string) string {
	c := *ck
	c.Name = prefix + c.Name
	c.Domain = ""
	c.HttpOnly = true
	return c.String()
}

// signIn logs the browser in to sess when it is not signed in: the hub has
// the session's password (passwordFile) and the browser does not. It
// returns the login cookie the session set, or nil when the browser is
// signed in already or signing in failed; a failure is logged, and the
// navigation then goes on unchanged to Yep Anywhere's own login page. Both
// calls go over t, the session's pinned transport, so the password reaches
// only the holder of the pinned certificate's key.
func (s *Server) signIn(r *http.Request, sess Session, addr string, t http.RoundTripper, prefix string) *http.Cookie {
	failed := func(err error) *http.Cookie {
		_, _ = fmt.Fprintf(s.stderr(), "riotbox-core: hub: signing in to %q failed: %v\n", sess.Container, err)
		return nil
	}
	client := &http.Client{
		Transport:     t,
		Timeout:       10 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	base := "https://" + addr
	req, err := http.NewRequestWithContext(r.Context(), http.MethodGet, base+"/api/auth/status", nil)
	if err != nil {
		return failed(err)
	}
	var ownLogin string // the login the browser sent for this session, if any
	for _, ck := range r.Cookies() {
		if name, ok := strings.CutPrefix(ck.Name, prefix); ok && name == loginCookie {
			req.AddCookie(&http.Cookie{Name: name, Value: ck.Value})
			ownLogin = ck.Value
		}
	}
	resp, err := client.Do(req)
	if err != nil {
		return failed(err)
	}
	var status struct{ Enabled, Authenticated bool }
	err = json.NewDecoder(io.LimitReader(resp.Body, 64<<10)).Decode(&status)
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return failed(fmt.Errorf("auth status: %s", resp.Status))
	}
	if err != nil {
		return failed(fmt.Errorf("auth status: %w", err))
	}
	if !status.Enabled || status.Authenticated {
		return nil
	}
	rl := s.recentLoginFor(sess.Container)
	rl.mu.Lock()
	defer rl.mu.Unlock()
	if rl.ck != nil && ownLogin == rl.ck.Value {
		// The session has just refused the very login we would hand back
		// (the browser logged out, say): it is no good, so make a new one.
		rl.ck = nil
	}
	if rl.ck != nil && s.now().Sub(rl.at) < signInReuse {
		return rl.ck
	}
	password, err := readStateFile(sess.StateDir, passwordFile, maxPasswordSize)
	if err != nil {
		return failed(err)
	}
	// The launcher reads the first line (anywhere_password).
	firstLine, _, _ := strings.Cut(string(password), "\n")
	body, err := json.Marshal(map[string]string{"password": strings.TrimRight(firstLine, "\r")})
	if err != nil {
		return failed(err)
	}
	login, err := http.NewRequestWithContext(r.Context(), http.MethodPost, base+"/api/auth/login", bytes.NewReader(body))
	if err != nil {
		return failed(err)
	}
	login.Header.Set("Content-Type", "application/json")
	login.Header.Set("X-Yep-Anywhere", "true")
	login.Header.Set("Origin", base)
	resp, err = client.Do(login)
	if err != nil {
		return failed(err)
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return failed(fmt.Errorf("login refused: %s", resp.Status))
	}
	for _, line := range resp.Header.Values("Set-Cookie") {
		if ck, err := http.ParseSetCookie(line); err == nil && ck.Name == loginCookie {
			rl.ck, rl.at = ck, s.now()
			return ck
		}
	}
	return failed(errors.New("login answered without a login cookie"))
}

// recentLoginFor returns container's entry, dropping entries too old to
// reuse that no login is using. An entry with no login time has not made its
// login yet and stays.
func (s *Server) recentLoginFor(container string) *recentLogin {
	s.loginsMu.Lock()
	defer s.loginsMu.Unlock()
	for name, rl := range s.logins {
		if name != container && rl.mu.TryLock() {
			if !rl.at.IsZero() && s.now().Sub(rl.at) >= signInReuse {
				delete(s.logins, name)
			}
			rl.mu.Unlock()
		}
	}
	rl, ok := s.logins[container]
	if !ok {
		rl = &recentLogin{}
		s.logins[container] = rl
	}
	return rl
}

// upstreams holds one Transport per upstream address, pinned to the
// certificate last read for it; a new certificate there replaces it. The
// addresses are the few the sessions publish on, so the map stays small.
type upstreams struct {
	mu     sync.Mutex
	byAddr map[string]pinnedTransport
}

type pinnedTransport struct {
	der []byte
	t   *http.Transport
}

func (u *upstreams) transport(addr string, der []byte) *http.Transport {
	u.mu.Lock()
	defer u.mu.Unlock()
	if p, ok := u.byAddr[addr]; ok {
		if bytes.Equal(p.der, der) {
			return p.t
		}
		p.t.CloseIdleConnections()
	}
	if u.byAddr == nil {
		u.byAddr = map[string]pinnedTransport{}
	}
	t := &http.Transport{
		DialContext:         (&net.Dialer{Timeout: 10 * time.Second}).DialContext,
		TLSHandshakeTimeout: 10 * time.Second,
		IdleConnTimeout:     90 * time.Second,
		TLSClientConfig: &tls.Config{
			MinVersion: tls.VersionTLS12,
			// Yep Anywhere's certificate is self-signed and names no address
			// the hub dials, so chain and name checks cannot pass. The exact
			// certificate is pinned instead: VerifyConnection runs regardless
			// of InsecureSkipVerify, and there is no unpinned fallback.
			InsecureSkipVerify: true,
			VerifyConnection: func(cs tls.ConnectionState) error {
				if len(cs.PeerCertificates) == 0 || !bytes.Equal(cs.PeerCertificates[0].Raw, der) {
					return errCertMismatch
				}
				return nil
			},
		},
	}
	u.byAddr[addr] = pinnedTransport{der: der, t: t}
	return t
}
