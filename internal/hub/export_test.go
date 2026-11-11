package hub

import (
	"net/http"
	"time"
)

// HostAllowed exposes hostAllowed to the tests.
var HostAllowed = hostAllowed

// UpstreamAddr exposes upstreamAddr to the tests.
var UpstreamAddr = upstreamAddr

// BusyReason exposes busyReason to the tests.
var BusyReason = busyReason

// SessionHandler exposes what the hub serves on a session's port, without
// a listener.
func (s *Server) SessionHandler(port string) http.Handler { return s.sessionHandler(port) }

// SetEngineTimeout sets engineTimeout for a test and returns the restore.
func SetEngineTimeout(d time.Duration) func() {
	old := engineTimeout
	engineTimeout = d
	return func() { engineTimeout = old }
}

// SetRelistEvery sets relistEvery for a test and returns the restore.
func SetRelistEvery(d time.Duration) func() {
	old := relistEvery
	relistEvery = d
	return func() { relistEvery = old }
}

// TouchLogin makes the entry recentLoginFor keeps for container, as a
// request about to sign in does.
func (s *Server) TouchLogin(container string) { s.recentLoginFor(container) }

// HasLogin reports whether recentLoginFor still keeps an entry for container.
func (s *Server) HasLogin(container string) bool {
	s.loginsMu.Lock()
	defer s.loginsMu.Unlock()
	_, ok := s.logins[container]
	return ok
}
