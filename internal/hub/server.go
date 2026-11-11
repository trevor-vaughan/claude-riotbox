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
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"time"
)

// cookieName carries the token after the first visit to the printed link.
const cookieName = "riotbox_hub"

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
	token   string
}

// Prepare creates DataDir and loads or creates the token and the
// certificate. It returns the link to print, which carries the token.
func (s *Server) Prepare() (link string, cert tls.Certificate, err error) {
	if err := os.MkdirAll(s.DataDir, 0o700); err != nil {
		return "", tls.Certificate{}, err
	}
	if err := os.Chmod(s.DataDir, 0o700); err != nil {
		return "", tls.Certificate{}, err
	}
	s.token, err = loadOrCreateToken(filepath.Join(s.DataDir, "token"))
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
	return "https://" + s.Addr + "/?k=" + s.token, cert, nil
}

func (s *Server) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
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

// Serve serves on ln until it fails. Prepare must have run.
func (s *Server) Serve(ln net.Listener, cert tls.Certificate) error {
	srv := &http.Server{
		Handler:           s.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		TLSConfig:         &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12},
	}
	return srv.ServeTLS(ln, "", "")
}

// Handler is the hub's routes, exported for the tests.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", s.index)
	return s.guard(mux)
}

// guard applies, in order: the Host check (DNS rebinding: a page on another
// origin that resolves a name to this address must not be served), the
// token in ?k=, which becomes a cookie, and the cookie.
func (s *Server) guard(next http.Handler) http.Handler {
	listenHost, _, _ := net.SplitHostPort(s.Addr)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
		if !hostAllowed(r.Host, listenHost) {
			http.Error(w, "unexpected Host header", http.StatusMisdirectedRequest)
			return
		}
		if k := r.URL.Query().Get("k"); k != "" {
			if !s.tokenMatches(k) {
				http.Error(w, "this link is not valid; open the one riotbox hub printed", http.StatusForbidden)
				return
			}
			http.SetCookie(w, &http.Cookie{
				Name: cookieName, Value: s.token, Path: "/",
				HttpOnly: true, Secure: true, SameSite: http.SameSiteStrictMode,
				MaxAge: int((400 * 24 * time.Hour).Seconds()),
			})
			http.Redirect(w, r, "/", http.StatusSeeOther)
			return
		}
		c, err := r.Cookie(cookieName)
		if err != nil || !s.tokenMatches(c.Value) {
			http.Error(w, "open the link riotbox hub printed in its terminal", http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) tokenMatches(v string) bool {
	return s.token != "" && subtle.ConstantTimeCompare([]byte(v), []byte(s.token)) == 1
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

type pageSession struct {
	Session
	Title   string
	Running string
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
{{range .Sessions}}<li><a class="card" href="{{.URL}}/" rel="noreferrer">
<div class="title">{{.Title}}</div>
{{range .Projects}}<div class="paths">{{.}}</div>{{end}}
<div class="meta">{{.URL}}{{if .Running}} · started {{.Running}}{{end}}</div>
{{if .LocalOnly}}<div class="meta warn">Published on loopback: only reachable from the host itself.</div>{{end}}
</a></li>
{{end}}</ul>
{{else if not .Err}}<p class="empty">No <code>riotbox anywhere</code> session is running. Start one with <code>riotbox anywhere [projects...]</code>.</p>{{end}}
<p class="foot">Each project set has its own password and certificate. This page refreshes every 15 seconds.</p>
</main></body></html>
`))

func (s *Server) index(w http.ResponseWriter, _ *http.Request) {
	var data struct {
		Sessions []pageSession
		Err      string
	}
	sessions, err := s.Lister.List()
	if err != nil {
		data.Err = err.Error()
	}
	now := s.now()
	for _, ss := range sessions {
		p := pageSession{Session: ss, Title: title(ss)}
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

// loadOrCreateToken returns the token in path, writing a new one (32 random
// bytes, base64url) when the file is missing or empty.
func loadOrCreateToken(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err == nil {
		if t := strings.TrimSpace(string(b)); len(t) >= 32 {
			return t, nil
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	t := base64.RawURLEncoding.EncodeToString(raw)
	return t, writePrivate(path, []byte(t+"\n"))
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
