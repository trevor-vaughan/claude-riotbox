package hub

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"fmt"
	"html/template"
	"io"
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"syscall"
	"time"
)

// cookieName carries the token after the first visit to the printed link.
const cookieName = "riotbox_hub"

// maxTokenFile bounds what readToken reads per request.
const maxTokenFile = 1024

// cookieMaxAge is how long the token cookie lasts.
const cookieMaxAge = 400 * 24 * time.Hour

// hubHeaders go on every response the hub writes itself. A session port's
// proxied responses carry Yep Anywhere's own instead: proxy removes these
// first, as ReverseProxy adds upstream headers to what is set and two CSP
// headers are both enforced.
var hubHeaders = map[string]string{
	"Cache-Control":           "no-store",
	"X-Content-Type-Options":  "nosniff",
	"Referrer-Policy":         "no-referrer",
	"Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
}

// certLifetime stays under the 398 days browsers accept for a server
// certificate; the certificate is reissued when less than certRenew remains.
const (
	certLifetime = 397 * 24 * time.Hour
	certRenew    = 30 * 24 * time.Hour
)

// Server is the hub's HTTPS server. Addr is the host:port to listen on;
// DataDir holds the token and the certificate, created 0700.
type Server struct {
	Addr    string
	DataDir string
	Lister  interface{ List() ([]Session, error) }
	Now     func() time.Time
	Stderr  io.Writer // where proxy failures are logged; nil means os.Stderr

	tokenMu     sync.Mutex
	tokenWarned string // the last token error logged, so it is logged once

	loginsMu sync.Mutex
	logins   map[string]*recentLogin // by container name

	cache     *sessionCache
	ports     *sessionPorts
	upstreams upstreams
}

// Prepare creates DataDir and loads or creates the token and the
// certificate. It returns the link to print, which carries the token.
func (s *Server) Prepare() (link string, cert tls.Certificate, err error) {
	link, err = s.Link()
	if err != nil {
		return "", tls.Certificate{}, err
	}
	host, _, err := net.SplitHostPort(s.Addr)
	if err != nil {
		return "", tls.Certificate{}, err
	}
	cert, err = loadOrCreateCert(s.DataDir, host, s.now())
	if err != nil {
		return "", tls.Certificate{}, err
	}
	s.logins = map[string]*recentLogin{}
	s.ports = &sessionPorts{
		host: host, handler: s.sessionHandler, stderr: s.stderr(),
		servers: map[string]*http.Server{}, failed: map[string]string{},
	}
	s.cache = &sessionCache{
		list:   func() ([]Session, error) { return s.Lister.List() },
		now:    s.now,
		onList: s.ports.reconcile,
		stderr: s.stderr(),
	}
	return link, cert, nil
}

func (s *Server) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

func (s *Server) stderr() io.Writer {
	if s.Stderr != nil {
		return s.Stderr
	}
	return os.Stderr
}

// Listen opens Addr. The caller prints the link only after this succeeds,
// so an address the hub cannot serve on never yields a link. An address no
// interface of this host carries (a mistyped RIOTBOX_HUB_BIND) is named as
// such: the kernel's "cannot assign requested address" does not say which
// setting is wrong.
func (s *Server) Listen() (net.Listener, error) {
	ln, err := net.Listen("tcp", s.Addr)
	if errors.Is(err, syscall.EADDRNOTAVAIL) {
		host, _, _ := net.SplitHostPort(s.Addr)
		return nil, fmt.Errorf("%s is not an address of this host; set RIOTBOX_HUB_BIND to one that is (ip -br addr lists them): %w", host, err)
	}
	return ln, err
}

// Serve serves the list on ln, and the session ports, until ln fails. Prepare must have run.
func (s *Server) Serve(ln net.Listener, cert tls.Certificate) error {
	s.ports.start(cert)
	_, _ = s.cache.fresh() // a failure is logged by refresh
	tick := time.Tick(relistEvery)
	go func() {
		for range tick {
			_, _ = s.cache.fresh() // a failure is logged by refresh
		}
	}()
	srv := &http.Server{
		Handler:           s.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		TLSConfig:         &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12},
	}
	return srv.ServeTLS(ln, "", "")
}

// Handler is the list's routes, exported for the tests. Each session is
// served on its own port (sessionHandler).
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", s.index)
	return s.guard(mux, true)
}

// guard applies, in order: the Host check (DNS rebinding: a page on another
// origin that resolves a name to this address must not be served), the
// token in ?k= (on the list only: a session port passes k on to the session),
// which becomes a cookie, and the cookie.
func (s *Server) guard(next http.Handler, exchange bool) http.Handler {
	listenHost, _, _ := net.SplitHostPort(s.Addr)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		for k, v := range hubHeaders {
			w.Header().Set(k, v)
		}
		if !hostAllowed(r.Host, listenHost) {
			http.Error(w, "unexpected Host header", http.StatusMisdirectedRequest)
			return
		}
		if exchange {
			if k := r.URL.Query().Get("k"); k != "" {
				if !s.tokenMatches(k) {
					http.Error(w, "this link is not valid; open the one riotbox hub printed", http.StatusForbidden)
					return
				}
				http.SetCookie(w, &http.Cookie{
					Name: cookieName, Value: k, Path: "/",
					HttpOnly: true, Secure: true, SameSite: http.SameSiteStrictMode,
					MaxAge: int(cookieMaxAge.Seconds()),
				})
				http.Redirect(w, r, "/", http.StatusSeeOther)
				return
			}
		}
		// Any matching cookie will do: a session's script can set another
		// riotbox_hub cookie with a longer Path, which browsers send first.
		if !slices.ContainsFunc(r.CookiesNamed(cookieName), func(c *http.Cookie) bool { return s.tokenMatches(c.Value) }) {
			msg := "open the hub's link (riotbox hub link prints it)"
			if !exchange {
				msg = "open the RiotBox hub's list first: " + s.listURL(r)
			}
			http.Error(w, msg, http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) tokenMatches(v string) bool {
	t := s.currentToken()
	return t != "" && subtle.ConstantTimeCompare([]byte(v), []byte(t)) == 1
}

// hostAllowed accepts the listen address itself and loopback names. A
// wildcard listen address accepts any IP literal, never a name.
func hostAllowed(hostHeader, listenHost string) bool {
	h := hostHeader
	if hh, _, err := net.SplitHostPort(hostHeader); err == nil {
		h = hh
	}
	h = strings.TrimSuffix(strings.TrimPrefix(h, "["), "]")
	if h == "localhost" {
		return true
	}
	ip := net.ParseIP(h)
	if ip == nil {
		return false
	}
	if ip.IsLoopback() {
		return true
	}
	listen := net.ParseIP(listenHost)
	if listen == nil {
		return false
	}
	if listen.IsUnspecified() {
		return true
	}
	return ip.Equal(listen)
}

// requestHost is the host the browser addressed, without port or brackets.
// guard has already checked it.
func requestHost(r *http.Request) string {
	h := r.Host
	if hh, _, err := net.SplitHostPort(h); err == nil {
		h = hh
	}
	return strings.TrimSuffix(strings.TrimPrefix(h, "["), "]")
}

// listURL is the list's address as this browser reaches the hub.
func (s *Server) listURL(r *http.Request) string {
	_, port, _ := net.SplitHostPort(s.Addr)
	return "https://" + net.JoinHostPort(requestHost(r), port) + "/"
}

type pageSession struct {
	Session
	Title   string
	Running string
	Link    string // where the card goes
	Note    string // why the hub does not front the session; empty when it does
}

var page = template.Must(template.New("hub").Parse(`<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="15">
<title>RiotBox sessions</title>
<style>
:root{--bg:#f6f6f4;--fg:#1d1d1b;--muted:#6b6b66;--card:#fff;--line:#e2e2dc;--accent:#2f5bd3;--warn:#a15c00}
@media (prefers-color-scheme:dark){:root{--bg:#141413;--fg:#ecece8;--muted:#9a9a93;--card:#1f1f1d;--line:#33332f;--accent:#8aa8ff;--warn:#f0b35a}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.45 system-ui,-apple-system,"Segoe UI",sans-serif}
main{max-width:640px;margin:0 auto;padding:16px}
h1{font-size:1.25rem;margin:8px 0 16px}
ul{list-style:none;margin:0;padding:0;display:grid;gap:12px}
a.card{display:block;text-decoration:none;color:inherit;background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px 16px}
a.card:active{border-color:var(--accent)}
.title{font-weight:600;font-size:1.05rem;color:var(--accent);overflow-wrap:anywhere}
.paths{margin:4px 0 0;color:var(--muted);font-size:.85rem;overflow-wrap:anywhere}
.meta{margin-top:6px;color:var(--muted);font-size:.85rem}
.warn{color:var(--warn)}
.empty,.foot{color:var(--muted)}
.foot{font-size:.8rem;margin-top:20px}
code{font-size:.9em}
</style></head><body><main>
<h1>RiotBox sessions</h1>
{{if .Err}}<p class="warn">Could not list sessions: {{.Err}}</p>{{end}}
{{if .Sessions}}<ul>
{{range .Sessions}}<li><a class="card" href="{{.Link}}" rel="noreferrer">
<div class="title">{{.Title}}</div>
{{range .Projects}}<div class="paths">{{.}}</div>{{end}}
<div class="meta">{{.Container}}{{if .Running}} · started {{.Running}}{{end}}</div>
{{if .Note}}<div class="meta warn">Not through the hub: {{.Note}}</div>{{end}}
</a></li>
{{end}}</ul>
{{else if not .Err}}<p class="empty">No <code>riotbox anywhere</code> session is running. Start one with <code>riotbox anywhere [projects...]</code>.</p>{{end}}
<p class="foot">Each project set has its own password, and the hub serves each session on its own port. This page refreshes every 15 seconds.</p>
</main></body></html>
`))

func (s *Server) index(w http.ResponseWriter, r *http.Request) {
	var data struct {
		Sessions []pageSession
		Err      string
	}
	sessions, err := s.cache.fresh()
	if err != nil {
		data.Err = err.Error()
	}
	now := s.now()
	for _, ss := range sessions {
		p := pageSession{Session: ss, Title: title(ss), Link: ss.URL + "/"}
		port := publishedPort(ss)
		if served, reason := s.ports.status(port); served {
			p.Link = "https://" + net.JoinHostPort(requestHost(r), port) + "/"
		} else {
			p.Note = reason
		}
		if !ss.Started.IsZero() {
			p.Running = ago(now.Sub(ss.Started))
		}
		data.Sessions = append(data.Sessions, p)
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_ = page.Execute(w, data)
}

// title is the projects' base names, or the container name without them.
func title(s Session) string {
	if len(s.Projects) == 0 {
		return s.Container
	}
	names := make([]string, 0, len(s.Projects))
	for _, p := range s.Projects {
		names = append(names, filepath.Base(p))
	}
	return strings.Join(names, " + ")
}

func ago(d time.Duration) string {
	switch {
	case d < time.Minute:
		return "just now"
	case d < time.Hour:
		return fmt.Sprintf("%d min ago", int(d.Minutes()))
	case d < 48*time.Hour:
		return fmt.Sprintf("%d h ago", int(d.Hours()))
	default:
		return fmt.Sprintf("%d days ago", int(d.Hours()/24))
	}
}

// errNoToken marks a token file that exists but holds no token.
var errNoToken = errors.New("holds no token")

// readToken returns the token in path; one shorter than 32 characters is
// not one the hub wrote.
func readToken(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer func() { _ = f.Close() }() // read-only: nothing to lose on close
	// A token is under 100 bytes; the cap keeps a mistaken huge file from being read on every request.
	b, err := io.ReadAll(io.LimitReader(f, maxTokenFile))
	if err != nil {
		return "", err
	}
	t := strings.TrimSpace(string(b))
	if len(t) < 32 {
		return "", fmt.Errorf("%s %w", path, errNoToken)
	}
	return t, nil
}

// newToken writes a fresh token (32 random bytes, base64url) to path.
func newToken(path string) (string, error) {
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	t := base64.RawURLEncoding.EncodeToString(raw)
	return t, writePrivate(path, []byte(t+"\n"))
}

// loadOrCreateToken returns the token in path, writing a new one (32 random
// bytes, base64url) when the file is missing or empty.
func loadOrCreateToken(path string) (string, error) {
	t, err := readToken(path)
	if errors.Is(err, os.ErrNotExist) || errors.Is(err, errNoToken) {
		return newToken(path)
	}
	return t, err
}

// prepareDir creates DataDir 0700.
func (s *Server) prepareDir() error {
	if err := os.MkdirAll(s.DataDir, 0o700); err != nil {
		return err
	}
	return os.Chmod(s.DataDir, 0o700)
}

// Link returns the link that carries the token, creating DataDir and the
// token when missing. It does not touch the certificate.
func (s *Server) Link() (string, error) {
	if err := s.prepareDir(); err != nil {
		return "", err
	}
	t, err := loadOrCreateToken(filepath.Join(s.DataDir, "token"))
	if err != nil {
		return "", err
	}
	return "https://" + s.Addr + "/?k=" + t, nil
}

// NewToken replaces the token and returns the new link. A running hub
// takes it from its next request (currentToken), so every browser must
// open the new link: this is how the hub's key is revoked.
func (s *Server) NewToken() (string, error) {
	if err := s.prepareDir(); err != nil {
		return "", err
	}
	t, err := newToken(filepath.Join(s.DataDir, "token"))
	if err != nil {
		return "", err
	}
	return "https://" + s.Addr + "/?k=" + t, nil
}

// currentToken is the token in DataDir/token, read on every request (it is
// 44 bytes), so `riotbox hub new-token` takes effect on a running hub. A
// token file that is missing or unusable matches nothing: the hub fails
// closed, and logs each distinct reason once.
func (s *Server) currentToken() string {
	t, err := readToken(filepath.Join(s.DataDir, "token"))
	s.tokenMu.Lock()
	defer s.tokenMu.Unlock()
	if err == nil {
		s.tokenWarned = ""
		return t
	}
	if err.Error() != s.tokenWarned {
		_, _ = fmt.Fprintf(s.stderr(), "riotbox-core: hub: refusing every request: %v (riotbox hub new-token writes a new token)\n", err)
		s.tokenWarned = err.Error()
	}
	return ""
}

// loadOrCreateCert reuses cert.pem/key.pem when they parse, name host, and
// are not about to expire; otherwise it issues a new self-signed ECDSA P-256
// certificate for host, localhost and 127.0.0.1. Keeping it means the phone
// accepts it once, not on every start.
func loadOrCreateCert(dir, host string, now time.Time) (tls.Certificate, error) {
	certFile, keyFile := filepath.Join(dir, "cert.pem"), filepath.Join(dir, "key.pem")
	if c, err := tls.LoadX509KeyPair(certFile, keyFile); err == nil && c.Leaf != nil &&
		now.Add(certRenew).Before(c.Leaf.NotAfter) && certNames(c.Leaf, host) {
		return c, nil
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 127))
	if err != nil {
		return tls.Certificate{}, err
	}
	tmpl := &x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: "riotbox hub"},
		NotBefore:    now.Add(-time.Hour),
		NotAfter:     now.Add(certLifetime),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames:     []string{"localhost"},
		IPAddresses:  []net.IP{net.IPv4(127, 0, 0, 1), net.IPv6loopback},
	}
	if ip := net.ParseIP(host); ip != nil && !ip.IsUnspecified() && !ip.IsLoopback() {
		tmpl.IPAddresses = append(tmpl.IPAddresses, ip)
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, err
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return tls.Certificate{}, err
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})
	if err := writePrivate(keyFile, keyPEM); err != nil {
		return tls.Certificate{}, err
	}
	if err := writePrivate(certFile, certPEM); err != nil {
		return tls.Certificate{}, err
	}
	return tls.X509KeyPair(certPEM, keyPEM)
}

// certNames reports whether leaf names host (an IP literal), or host is a
// wildcard or loopback address, which every issued certificate covers.
func certNames(leaf *x509.Certificate, host string) bool {
	ip := net.ParseIP(host)
	if ip == nil {
		return false
	}
	if ip.IsUnspecified() || ip.IsLoopback() {
		return true
	}
	return slices.ContainsFunc(leaf.IPAddresses, ip.Equal)
}

// writePrivate writes data to path, mode 0600, through a temp file and a
// rename so a reader never sees half a key.
func writePrivate(path string, data []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".tmp-*")
	if err != nil {
		return err
	}
	defer func() { _ = os.Remove(tmp.Name()) }()
	if err := tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}
