// Package pod runs the container-engine side of a RIOTBOX_EGRESS=1
// session: an internal network without DNS for the agent, a DNS-enabled
// external one, a pod grouping them (--infra=false: lifecycle only, no
// shared namespaces), and the Envoy proxy container on both networks
// (Up); their removal (Down); and the lookups the egress CLI and the
// orphan sweep need (sessions.go). See docs/dev/egress.md for the topology
// and the security argument.
package pod

import (
	"bytes"
	"cmp"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/trevor-vaughan/claude-riotbox/internal/egress/envoyconfig"
	"github.com/trevor-vaughan/claude-riotbox/internal/egress/inject"
	"github.com/trevor-vaughan/claude-riotbox/internal/egress/state"
)

// Labels on every object Up creates. LabelRole marks the proxy container.
const (
	LabelEgress     = "riotbox.egress"
	LabelSession    = "riotbox.session"
	LabelOwnerPID   = "riotbox.owner-pid"
	LabelOwnerPIDNS = "riotbox.owner-pidns"
	LabelRole       = "riotbox.egress-role"
	roleGateway     = "gateway"
)

// readyMarker is the line Envoy 1.40 logs once CDS, LDS and the listener's
// RDS dependency have all loaded: the proxy then accepts CONNECTs. The E2E
// suite starts the pinned image, so a release that rewords it fails CI.
const readyMarker = "all dependencies initialized. starting workers"

// AgentCACert is where the agent finds the session CA's certificate when
// the proxy injects keys.
const AgentCACert = "/run/riotbox-egress/ca.crt"

// networkGone matches the engine's message for a network that is already
// removed, which Down treats as success (a concurrent Down got there first).
var networkGone = regexp.MustCompile(`(?i)network not found|no such network`)

// maxLogLine caps each printed line of Envoy's log.
const maxLogLine = 512

// Runner runs the container engine. Exec is the real one.
type Runner interface {
	// Output runs the engine and returns its stdout; a failure's error
	// carries the engine's stderr.
	Output(args ...string) ([]byte, error)
	// Stream runs the engine with its output going to the user, so a pull
	// shows progress.
	Stream(args ...string) error
	// Exists runs an engine "exists" query: true on exit 0, false on exit
	// 1, an error otherwise.
	Exists(args ...string) (bool, error)
}

// Exec runs the engine executable Cmd (a name on PATH, or a path).
type Exec struct {
	Cmd    string
	Stderr io.Writer
}

// Output implements Runner.
func (x Exec) Output(args ...string) ([]byte, error) {
	var out, errOut bytes.Buffer
	cmd := exec.Command(x.Cmd, args...)
	cmd.Stdout, cmd.Stderr = &out, &errOut
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("%s %s: %w: %s", filepath.Base(x.Cmd), strings.Join(args, " "), err, strings.TrimSpace(errOut.String()))
	}
	return out.Bytes(), nil
}

// Stream implements Runner.
func (x Exec) Stream(args ...string) error {
	cmd := exec.Command(x.Cmd, args...)
	cmd.Stdout, cmd.Stderr = x.Stderr, x.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("%s %s: %w", filepath.Base(x.Cmd), strings.Join(args, " "), err)
	}
	return nil
}

// Exists implements Runner.
func (x Exec) Exists(args ...string) (bool, error) {
	_, err := x.Output(args...)
	if err == nil {
		return true, nil
	}
	var exit *exec.ExitError
	if errors.As(err, &exit) && exit.ExitCode() == 1 {
		return false, nil
	}
	return false, err
}

// Manager does the engine work of the egress verbs.
type Manager struct {
	Engine       Runner
	Stderr       io.Writer
	ReadyTimeout time.Duration
	PollInterval time.Duration
}

// NewManager returns a Manager running the engine executable engine, with
// the production readiness timing.
func NewManager(engine string, stderr io.Writer) Manager {
	return Manager{
		Engine:       Exec{Cmd: engine, Stderr: stderr},
		Stderr:       stderr,
		ReadyTimeout: 30 * time.Second,
		PollInterval: 250 * time.Millisecond,
	}
}

// names are the engine objects of one session, named after it.
type names struct {
	pod, gateway, internal, external string
}

func namesFor(session string) names {
	return names{
		pod:      session + "-pod",
		gateway:  session + "-egress",
		internal: session + "-int",
		external: session + "-ext",
	}
}

// UpRequest is what Up needs to start one session's proxy.
type UpRequest struct {
	Dir        state.Dir
	SessionKey string
	OwnerPID   int      // the launch.sh process that owns the session
	Image      string   // the Envoy image, by digest
	AgentHosts []byte   // the agent's egress_hosts output, saved as agent.conf
	Projects   []string // the launch's project dirs, saved for riotbox egress list
	OSDir      string   // the OS plugins (state.LoadOS), saved as os.conf; "" for none
	SystemConf string
	UserConf   string
	// Credentials are the keys the proxy injects (inject.Decide); none
	// for a session that injects nothing. With any, Dir must have a
	// runtime base (state.Dir.WithRuntime).
	Credentials []inject.Credential
}

// Up starts the session's proxy and returns the flags the agent's engine
// run needs to join it: the pod, the internal network only, no
// NET_ADMIN/NET_RAW (with NET_ADMIN a process could route around the
// proxy), no resolver, the proxy's name mapped to its address in
// /etc/hosts, the proxy env vars and the session's name
// (RIOTBOX_EGRESS_SESSION). With Credentials, Up first writes the
// session's secrets (on the runtime tmpfs), CA and record
// (state.Dir.WriteInjection) — a failure there stops it before any engine
// call, and a Dir without a runtime base stops it before anything is
// created — mounts the secrets dir into the proxy alone, and adds to the
// agent's flags the CA certificate at AgentCACert, NODE_EXTRA_CA_CERTS
// and RIOTBOX_EGRESS_CA naming it, and each injected variable set to
// inject.Placeholder. No key is ever on an engine command line, and a
// failed Up leaves no secrets dir. Without Credentials it removes any a
// reused session dir holds.
//
// The internal network has no DNS and the agent no resolv.conf, so no
// name lookup can leave the agent: some aardvark-dns and CNI versions
// forward an internal network's queries upstream, a channel past the
// proxy. NO_PROXY keeps headroom's loopback proxy direct.
// Once the proxy is up, when strict mode leaves out any of the agent's own
// hosts, Up warns on m.Stderr and goes on: the user may mean it. When a
// step fails, Up removes what it created. That rollback is by name: an
// object that already carries the session's name would be removed too,
// which the random suffix on session names makes
// improbable.
//
// Up loads the OS plugins (UpRequest.OSDir) before it creates anything, so a
// broken plugin stops the launch with no engine call and no state dir, and
// saves them as os.conf after agent.conf.
func (m Manager) Up(r UpRequest) (_ []string, err error) {
	// The image is a positional engine argument and the state paths are
	// part of a -v src:dst:opts argument, so neither may be able to change
	// how the engine parses its command line.
	if r.Image == "" || strings.HasPrefix(r.Image, "-") || strings.ContainsFunc(r.Image, unicode.IsSpace) {
		return nil, fmt.Errorf("invalid egress proxy image %q", r.Image)
	}
	if len(r.Credentials) > 0 && r.Dir.SecretsDir() == "" {
		return nil, state.ErrNoRuntimeDir
	}
	for _, p := range []string{r.Dir.ConfigDir(), r.Dir.LogDir(), r.Dir.SecretsDir(), r.Dir.CACert()} {
		if strings.ContainsAny(p, ":,") {
			return nil, fmt.Errorf("the egress state path %q contains ':' or ','", p)
		}
	}
	osGroups, err := state.LoadOS(r.OSDir)
	if err != nil {
		return nil, err
	}
	if err := r.Dir.Create(); err != nil {
		return nil, err
	}
	if err := state.WriteAtomic(r.Dir.AgentConf(), r.AgentHosts); err != nil {
		return nil, err
	}
	if err := r.Dir.WriteOSGroups(osGroups); err != nil {
		return nil, err
	}
	if err := r.Dir.WriteProjects(r.Projects); err != nil {
		return nil, err
	}
	if err := r.Dir.WriteInjection(r.Credentials, time.Now()); err != nil {
		return nil, err
	}
	// The steps from here to the engine objects can fail too; no key may
	// stay on disk for the sweep's grace period after they do. A failure
	// after them rolls back through Down, which removes it as well.
	defer func() {
		if err != nil {
			err = errors.Join(err, r.Dir.RemoveSecrets())
		}
	}()
	resolved, err := r.Dir.Policy(r.SystemConf, r.UserConf)
	if err != nil {
		return nil, err
	}
	if err := r.Dir.WriteConfig(resolved); err != nil {
		return nil, err
	}
	// Envoy appends to its logs and Create keeps them, so a reused session
	// dir would show the last run's ready line and denials. Unlink is safe
	// on a symlink planted in the proxy-writable log dir.
	for _, stale := range []string{r.Dir.EnvoyLog(), r.Dir.AccessLog()} {
		if err := os.Remove(stale); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return nil, err
		}
	}
	present, err := m.Engine.Exists("image", "exists", r.Image)
	if err != nil {
		return nil, err
	}
	if !present {
		_, _ = fmt.Fprintf(m.Stderr, "egress: pulling %s\n", r.Image)
		if err := m.Engine.Stream("pull", r.Image); err != nil {
			return nil, fmt.Errorf("pulling the egress proxy image: %w", err)
		}
	}
	n := namesFor(r.Dir.Name())
	labels := []string{
		"--label", LabelEgress + "=" + r.Dir.Name(),
		"--label", LabelSession + "=" + r.SessionKey,
		"--label", LabelOwnerPID + "=" + strconv.Itoa(r.OwnerPID),
		"--label", LabelOwnerPIDNS + "=" + pidNamespace(),
	}
	var secretsMount []string
	if len(r.Credentials) > 0 {
		secretsMount = []string{"-v", r.Dir.SecretsDir() + ":" + envoyconfig.SecretsDir + ":ro,z"}
	}
	steps := [][]string{
		slices.Concat([]string{"network", "create", "--internal", "--disable-dns"}, labels, []string{n.internal}),
		slices.Concat([]string{"network", "create"}, labels, []string{n.external}),
		slices.Concat([]string{"pod", "create", "--infra=false", "--name", n.pod}, labels),
		slices.Concat([]string{"run", "-d", "--pod", n.pod, "--name", n.gateway}, labels, []string{
			"--label", LabelRole + "=" + roleGateway,
			"--network", n.internal + "," + n.external,
			"--userns=keep-id", "--user", fmt.Sprintf("%d:%d", os.Getuid(), os.Getgid()),
			"--read-only", "--cap-drop=ALL", "--security-opt", "no-new-privileges",
			// Envoy holds the injected keys in memory: a crash must not
			// write them to disk in a core file.
			"--ulimit", "core=0",
			"--log-driver=none",
			"-v", r.Dir.ConfigDir() + ":" + envoyconfig.ConfigDir + ":ro,z",
			"-v", r.Dir.LogDir() + ":" + envoyconfig.LogDir + ":rw,z",
		}, secretsMount, []string{
			"--entrypoint", "/usr/local/bin/envoy",
			r.Image,
			"-c", envoyconfig.ConfigDir + "/" + envoyconfig.BootstrapFile,
			"--log-path", envoyconfig.LogDir + "/" + envoyconfig.EnvoyLogName,
			"--file-flush-interval-msec", "1000",
		}),
	}
	for _, step := range steps {
		if _, err := m.Engine.Output(step...); err != nil {
			return nil, errors.Join(err, m.Down(r.Dir, false))
		}
	}
	if err := m.waitReady(r.Dir, n.gateway); err != nil {
		m.printLogTail(r.Dir)
		return nil, errors.Join(err, m.Down(r.Dir, false))
	}
	ip, err := m.gatewayIP(n)
	if err != nil {
		return nil, errors.Join(err, m.Down(r.Dir, false))
	}
	proxy := fmt.Sprintf("http://%s:%d", n.gateway, envoyconfig.ListenPort)
	const noProxy = "localhost,127.0.0.1"
	if w := resolved.LockoutWarning(); w != "" {
		_, _ = fmt.Fprintln(m.Stderr, w)
	}
	flags := []string{
		"--pod", n.pod,
		"--network", n.internal,
		"--cap-drop=NET_ADMIN,NET_RAW",
		"--dns", "none", "--add-host", n.gateway + ":" + ip,
		"-e", "HTTP_PROXY=" + proxy, "-e", "HTTPS_PROXY=" + proxy,
		"-e", "http_proxy=" + proxy, "-e", "https_proxy=" + proxy,
		"-e", "NO_PROXY=" + noProxy, "-e", "no_proxy=" + noProxy,
		// The agent's prompt section names the session in the allow
		// command it tells the agent to pass on (scripts/lib/egress-prompt.sh).
		"-e", "RIOTBOX_EGRESS_SESSION=" + r.Dir.Name(),
	}
	if len(r.Credentials) == 0 {
		return flags, nil
	}
	flags = append(flags,
		"-v", r.Dir.CACert()+":"+AgentCACert+":ro,z",
		// Node (Pi) and Bun (Claude Code, opencode) add this to their own
		// roots; scripts/lib/egress-trust.sh builds, from
		// RIOTBOX_EGRESS_CA, the bundle curl and Python need. headroom
		// uses that bundle (SSL_CERT_FILE/REQUESTS_CA_BUNDLE first) and
		// falls back to this when neither is set.
		"-e", "NODE_EXTRA_CA_CERTS="+AgentCACert,
		"-e", "RIOTBOX_EGRESS_CA="+AgentCACert)
	for _, c := range r.Credentials {
		flags = append(flags, "-e", c.Env+"="+inject.Placeholder)
	}
	return flags, nil
}

// gatewayIP returns the proxy's address on the internal network, as the
// engine reports it. It goes into the agent's --add-host argument, so it
// must be an IP literal: anything else is refused.
func (m Manager) gatewayIP(n names) (string, error) {
	out, err := m.Engine.Output("container", "inspect", "--format", "{{json .NetworkSettings.Networks}}", n.gateway)
	if err != nil {
		return "", err
	}
	var networks map[string]struct {
		IPAddress         string
		GlobalIPv6Address string
	}
	if err := json.Unmarshal(out, &networks); err != nil {
		return "", fmt.Errorf("reading the egress proxy's networks: %w", err)
	}
	attached := networks[n.internal]
	addr := cmp.Or(attached.IPAddress, attached.GlobalIPv6Address)
	if addr == "" {
		return "", fmt.Errorf("the egress proxy has no address on %s", n.internal)
	}
	ip := net.ParseIP(addr)
	if ip == nil {
		return "", fmt.Errorf("the egress proxy's address on %s is not an IP address: %q", n.internal, addr)
	}
	return ip.String(), nil
}

// waitReady polls Envoy's log for readyMarker, checking each time that the
// proxy container still runs, until ReadyTimeout. Only the last MiB of the
// log is searched, which suffices: at the default log level the marker is
// logged within the first few KB.
func (m Manager) waitReady(dir state.Dir, gateway string) error {
	deadline := time.Now().Add(m.ReadyTimeout)
	for {
		// Envoy writes this file, so it is read as untrusted: no symlinks,
		// no FIFOs, at most its last MiB (state.EnvoyLogTail).
		log, err := dir.EnvoyLogTail()
		if err != nil {
			return err
		}
		if bytes.Contains(log, []byte(readyMarker)) {
			return nil
		}
		out, err := m.Engine.Output("container", "inspect", "--format", "{{.State.Running}}", gateway)
		if err != nil {
			return err
		}
		if strings.TrimSpace(string(out)) != "true" {
			return errors.New("the egress proxy exited during startup")
		}
		if !time.Now().Before(deadline) {
			return fmt.Errorf("the egress proxy was not ready after %s", m.ReadyTimeout)
		}
		time.Sleep(m.PollInterval)
	}
}

// printLogTail shows the last 20 lines of Envoy's log on Stderr. The log
// is written by the proxy container, so every byte that is not printable
// ASCII or a tab is shown as "?": it must not reach the terminal as an
// escape sequence.
func (m Manager) printLogTail(dir state.Dir) {
	data, err := dir.EnvoyLogTail()
	if err != nil {
		_, _ = fmt.Fprintf(m.Stderr, "egress: no proxy log to show: %v\n", err)
		return
	}
	lines := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	if len(lines) > 20 {
		lines = lines[len(lines)-20:]
	}
	_, _ = fmt.Fprintf(m.Stderr, "egress: the last lines of %s:\n", dir.EnvoyLog())
	for _, l := range lines {
		l = printable(l)
		if len(l) > maxLogLine {
			l = l[:maxLogLine] + " [truncated]"
		}
		_, _ = fmt.Fprintln(m.Stderr, "  "+l)
	}
}

// printable replaces every byte of s that is not printable ASCII or a tab
// with "?".
func printable(s string) string {
	b := []byte(s)
	for i, c := range b {
		if (c < 0x20 && c != '\t') || c > 0x7e {
			b[i] = '?'
		}
	}
	return string(b)
}

// Down removes the session's proxy, pod and networks, each only if
// present, and then its secrets: under each of runtimes (runtime bases,
// state.RuntimeBases) or, with none given, under dir's own; and any an
// earlier release kept in the state dir. So it is safe to repeat. The proxy
// is stopped first, with SIGTERM, so Envoy flushes its access log; with
// report, Down then says how many requests were denied. It carries on
// past a failed step and returns every failure. Networks are checked
// with `network exists` before removal because `network rm --ignore` is
// missing from older podman.
func (m Manager) Down(dir state.Dir, report bool, runtimes ...string) error {
	n := namesFor(dir.Name())
	var errs []error
	if _, err := m.Engine.Output("stop", "--ignore", "--time", "10", n.gateway); err != nil {
		errs = append(errs, err)
	}
	if _, err := m.Engine.Output("pod", "rm", "--force", "--ignore", n.pod); err != nil {
		errs = append(errs, err)
	}
	for _, network := range []string{n.internal, n.external} {
		present, err := m.Engine.Exists("network", "exists", network)
		if err == nil && present {
			_, err = m.Engine.Output("network", "rm", network)
		}
		if err != nil && !networkGone.MatchString(err.Error()) {
			errs = append(errs, err)
		}
	}
	if err := removeSecrets(dir, runtimes); err != nil {
		errs = append(errs, err)
	}
	if report {
		denied, err := state.CountDenied(dir.AccessLog())
		switch {
		case err != nil:
			errs = append(errs, fmt.Errorf("counting denied requests: %w", err))
		case denied > 0:
			_, _ = fmt.Fprintf(m.Stderr, "egress: %d denied request(s), see %s\n", denied, dir.AccessLog())
		}
	}
	return errors.Join(errs...)
}

// removeSecrets removes dir's secrets under each of runtimes or, with none,
// under dir's own runtime base (state.Dir.RemoveSecrets).
func removeSecrets(dir state.Dir, runtimes []string) error {
	if len(runtimes) == 0 {
		return dir.RemoveSecrets()
	}
	var errs []error
	for _, rt := range runtimes {
		errs = append(errs, dir.WithRuntime(rt).RemoveSecrets())
	}
	return errors.Join(errs...)
}

// pidNamespace identifies this process's PID namespace ("pid:[4026531836]"),
// or is empty when /proc cannot say. Owner PIDs are only comparable within
// one namespace.
func pidNamespace() string {
	ns, err := os.Readlink("/proc/self/ns/pid")
	if err != nil {
		return ""
	}
	return ns
}
