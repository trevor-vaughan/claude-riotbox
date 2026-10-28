// Package state owns one egress session's directory on the host,
// <root>/<name>/ where root is RIOTBOX_EGRESS_ROOT and name the agent
// container's name:
//
//	config/        Envoy's config files, mounted read-only into the proxy
//	log/           access.log and envoy.log, mounted read-write
//	agent.conf     the active agent's egress_hosts, saved at start
//	session.conf   the session's allow/deny overlay (riotbox egress)
//	applied.conf   the allowlist last written to rds.json
//	applied-strict the strict setting last applied, as riotbox egress list shows it
//	projects.json  the launch's project dirs, for riotbox egress list
//	ca.crt         the session CA's certificate, mounted read-only into the agent
//	injected       each injected key's variable, host and header (never its value)
//	.lock          serialises the commands that change the session
//
// The proxy's leaf certificates, keys and credentials (credential
// injection) are not in it: they are in <runtime>/<name>/secrets, on a
// tmpfs (RuntimeBase, SecretsDir), never written to persistent disk
// unless the system swaps them out.
//
// See docs/dev/egress.md.
package state

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"syscall"
	"time"

	"github.com/trevor-vaughan/claude-riotbox/internal/display"
	"github.com/trevor-vaughan/claude-riotbox/internal/egress/envoyconfig"
	"github.com/trevor-vaughan/claude-riotbox/internal/egress/inject"
	"github.com/trevor-vaughan/claude-riotbox/internal/egress/policy"
	"github.com/trevor-vaughan/claude-riotbox/internal/lock"
)

// validName is a session name: one path component, starting with a letter
// or digit (so never . or ..), in the characters generate_container_name
// (scripts/mount-projects.sh) produces.
var validName = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$`)

// ValidName returns an error unless name can name a session dir.
func ValidName(name string) error {
	if !validName.MatchString(name) {
		return fmt.Errorf("%s is not a session name: it must start with a letter or digit and hold only letters, digits, _ . and - (at most 128)", display.Quote(name))
	}
	return nil
}

// Dir is one session's directory. Open is the only way to make one, so
// its name is always valid.
type Dir struct {
	root, name string
	runtime    string // RuntimeBase's dir, or "" when none was given
}

// Open returns the dir of session name under root. It touches nothing on
// disk.
func Open(root, name string) (Dir, error) {
	if err := ValidName(name); err != nil {
		return Dir{}, err
	}
	return Dir{root: root, name: name}, nil
}

// Name is the session's name: the agent container's.
func (d Dir) Name() string { return d.name }

// Path is the session dir.
func (d Dir) Path() string { return filepath.Join(d.root, d.name) }

// ConfigDir holds Envoy's config files.
func (d Dir) ConfigDir() string { return filepath.Join(d.Path(), "config") }

// LogDir holds Envoy's logs.
func (d Dir) LogDir() string { return filepath.Join(d.Path(), "log") }

// AccessLog is Envoy's per-request JSON log.
func (d Dir) AccessLog() string { return filepath.Join(d.LogDir(), envoyconfig.AccessLogName) }

// EnvoyLog is Envoy's own log (its --log-path).
func (d Dir) EnvoyLog() string { return filepath.Join(d.LogDir(), envoyconfig.EnvoyLogName) }

// AgentConf holds the active agent's egress hosts.
func (d Dir) AgentConf() string { return filepath.Join(d.Path(), "agent.conf") }

// SessionConf holds the session's allow/deny overlay.
func (d Dir) SessionConf() string { return filepath.Join(d.Path(), "session.conf") }

func (d Dir) appliedConf() string { return filepath.Join(d.Path(), "applied.conf") }

func (d Dir) projectsFile() string { return filepath.Join(d.Path(), "projects.json") }

// WithRuntime is d with its secrets under base, RuntimeBase's dir.
func (d Dir) WithRuntime(base string) Dir {
	d.runtime = base
	return d
}

// SecretsDir holds what only the proxy may read: per credential host its
// leaf certificate and key and its credential file
// (envoyconfig.RenderCredential). It is <base>/<name>/secrets on the
// runtime tmpfs (WithRuntime), or "" when d has no runtime base. It is
// mounted read-only into the proxy alone and removed at teardown
// (RemoveSecrets).
func (d Dir) SecretsDir() string {
	if d.runtime == "" {
		return ""
	}
	return filepath.Join(d.runtime, d.name, "secrets")
}

// legacySecretsDir is where releases before the runtime tmpfs kept the
// secrets: in the session dir. RemoveSecrets still removes it.
func (d Dir) legacySecretsDir() string { return filepath.Join(d.Path(), "secrets") }

// CACert is the session CA's certificate, mounted read-only into the
// agent. The CA's private key is never written (inject.NewCerts). Mode
// 0600 is enough because the agent runs as the owning uid
// (launch.sh: --userns=keep-id with --user); a change to the agent's
// uid mapping must revisit it.
func (d Dir) CACert() string { return filepath.Join(d.Path(), "ca.crt") }

func (d Dir) injectedFile() string { return filepath.Join(d.Path(), "injected") }

// headerName is a lowercase HTTP header name, as the provider table
// spells them.
var headerName = regexp.MustCompile(`^[a-z0-9-]+$`)

// Injected is one key the session's proxy injects, as the record names
// it: never its value.
type Injected struct {
	Env    string // the variable the agent holds a placeholder in
	Host   string // the provider host the proxy puts the key on
	Header string // the header it goes in
}

// validInjected reports whether env, host and header can name an
// injected key: a variable name, a provider host (a lowercase DNS name,
// no wildcard, port 443) and a lowercase header name. They become file
// names in the secrets dir and lines riotbox egress list prints.
func validInjected(env, host, header string) bool {
	e, remove, err := policy.Parse(host)
	return inject.IsEnvName(env) && headerName.MatchString(header) &&
		err == nil && !remove && !strings.HasPrefix(host, "*") &&
		(e == policy.Entry{Host: host, Port: policy.DefaultPort})
}

// WriteInjection makes the session's interception for creds: the CA and
// a leaf per host (inject.NewCerts, valid from now), each leaf, its key
// and its credential in SecretsDir, the CA certificate at CACert, and the
// record Injected reads. It first removes any of these a reused session
// dir holds, so with no creds the session intercepts nothing. A
// credential whose variable, host or header is not valid, or whose host
// an earlier one names, is refused before anything is written, as are
// creds for a d without a runtime base (ErrNoRuntimeDir) and a
// SecretsDir that is not a real directory (a link planted there would
// redirect the keys). A failed write removes SecretsDir and CACert
// again, so no key stays on disk without the record that names it. No
// error shows a value.
func (d Dir) WriteInjection(creds []inject.Credential, now time.Time) error {
	hosts := make([]string, len(creds))
	seen := make(map[string]bool, len(creds))
	for i, c := range creds {
		if !validInjected(c.Env, c.Host, c.Header) {
			return fmt.Errorf("credential %d is not a variable, a host and a header", i+1)
		}
		if seen[c.Host] {
			return fmt.Errorf("credential %d names host %s again", i+1, c.Host)
		}
		seen[c.Host] = true
		hosts[i] = c.Host
	}
	if len(creds) > 0 && d.runtime == "" {
		return ErrNoRuntimeDir
	}
	if d.runtime != "" {
		if err := realDirOrAbsent(d.SecretsDir()); err != nil {
			return err
		}
	}
	if err := d.RemoveSecrets(); err != nil {
		return err
	}
	for _, p := range []string{d.CACert(), d.injectedFile()} {
		if err := os.Remove(p); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return err
		}
	}
	if len(creds) == 0 {
		return nil
	}
	certs, err := inject.NewCerts(d.name, hosts, now)
	if err != nil {
		return err
	}
	if err := d.writeSecrets(creds, certs); err != nil {
		return errors.Join(err, d.RemoveSecrets())
	}
	var record strings.Builder
	for _, c := range creds {
		record.WriteString(c.Env + " " + c.Host + " " + c.Header + "\n")
	}
	err = writeFile(d.CACert(), certs.CA)
	if err == nil {
		err = writeFile(d.injectedFile(), []byte(record.String()))
	}
	if err != nil {
		rmErr := os.Remove(d.CACert())
		if errors.Is(rmErr, fs.ErrNotExist) {
			rmErr = nil
		}
		return errors.Join(err, d.RemoveSecrets(), rmErr)
	}
	return nil
}

// writeFile is WriteAtomic for WriteInjection's CA certificate and
// record; specs replace it to fail one of those writes (export_test.go),
// which no file planted beforehand can do without also failing the
// clean-up that runs before or after it.
var writeFile = WriteAtomic

// realDirOrAbsent returns an error unless path is missing or a real
// directory: a link there could redirect what is written under it.
func realDirOrAbsent(path string) error {
	info, err := os.Lstat(path)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return nil
	case err != nil:
		return err
	case !info.IsDir():
		return fmt.Errorf("%s is not a directory (it is %s); remove it", display.Quote(path), info.Mode().Type())
	}
	return nil
}

// writeSecrets makes SecretsDir and the runtime dirs above it up to the
// runtime base, each 0700, and writes into it each credential's leaf, key
// and credential file, each 0600. An existing base or session dir must be
// a real directory, and Mkdir of SecretsDir fails on anything already
// there, so nothing is written through a link.
func (d Dir) writeSecrets(creds []inject.Credential, certs inject.Certs) error {
	for _, dir := range []string{d.runtime, filepath.Dir(d.SecretsDir())} {
		if err := os.Mkdir(dir, 0o700); err != nil && !errors.Is(err, fs.ErrExist) {
			return err
		}
		if err := realDirOrAbsent(dir); err != nil {
			return err
		}
		if err := os.Chmod(dir, 0o700); err != nil {
			return err
		}
	}
	if err := os.Mkdir(d.SecretsDir(), 0o700); err != nil {
		return err
	}
	if err := os.Chmod(d.SecretsDir(), 0o700); err != nil {
		return err
	}
	for _, c := range creds {
		leaf := certs.Leaves[c.Host]
		for _, f := range []struct {
			name string
			data []byte
		}{
			{envoyconfig.CertFile(c.Host), leaf.Cert},
			{envoyconfig.KeyFile(c.Host), leaf.Key},
			{envoyconfig.CredentialFile(c.Host), envoyconfig.RenderCredential(c.Host, c.Value)},
		} {
			if err := WriteAtomic(filepath.Join(d.SecretsDir(), f.name), f.data); err != nil {
				return err
			}
		}
	}
	return nil
}

// Injected is the record WriteInjection wrote: none for a session that
// injects nothing or that an older release started. A line that is not a
// valid variable, host and header (validInjected), or that names a host
// an earlier line names, is an error naming it:
// the config is rendered from the record and riotbox egress list prints
// it.
func (d Dir) Injected() ([]Injected, error) {
	data, err := readOptional(d.injectedFile())
	if err != nil || len(data) == 0 {
		return nil, err
	}
	lines := strings.Split(strings.TrimSuffix(string(data), "\n"), "\n")
	out := make([]Injected, 0, len(lines))
	seen := make(map[string]bool, len(lines))
	for n, line := range lines {
		f := strings.Fields(line)
		if len(f) != 3 || !validInjected(f[0], f[1], f[2]) {
			return nil, fmt.Errorf("%s:%d: not a variable, a host and a header", display.Quote(d.injectedFile()), n+1)
		}
		if seen[f[1]] {
			return nil, fmt.Errorf("%s:%d: names host %s again", display.Quote(d.injectedFile()), n+1, f[1])
		}
		seen[f[1]] = true
		out = append(out, Injected{Env: f[0], Host: f[1], Header: f[2]})
	}
	return out, nil
}

// RemoveSecrets deletes SecretsDir and everything in it, then its session
// dir in the runtime base when that is left empty, and the secrets dir an
// earlier release kept in the session dir. A link is removed as the link
// alone. A missing dir is not an error.
func (d Dir) RemoveSecrets() error {
	var errs []error
	if d.runtime != "" {
		errs = append(errs, os.RemoveAll(d.SecretsDir()))
		err := os.Remove(filepath.Dir(d.SecretsDir()))
		if err != nil && !errors.Is(err, fs.ErrNotExist) && !errors.Is(err, syscall.ENOTEMPTY) {
			errs = append(errs, err)
		}
	}
	errs = append(errs, os.RemoveAll(d.legacySecretsDir()))
	return errors.Join(errs...)
}

// intercepts is the record as envoyconfig takes it.
func (d Dir) intercepts() ([]envoyconfig.Intercept, error) {
	injected, err := d.Injected()
	if err != nil {
		return nil, err
	}
	out := make([]envoyconfig.Intercept, len(injected))
	for i, x := range injected {
		out[i] = envoyconfig.Intercept{Host: x.Host, Header: x.Header}
	}
	return out, nil
}

// Create makes root (and any missing parents), the session dir and its
// config and log dirs, each mode 0700, tightening any that already exist:
// they hold the session's allowlist and a log of its traffic. It refuses a
// session, config or log dir that is not a real directory (a link planted
// there would redirect writes and the proxy's bind mounts); root itself may
// be a link, as users link their data dirs.
func (d Dir) Create() error {
	if err := os.MkdirAll(filepath.Dir(d.root), 0o700); err != nil {
		return err
	}
	for _, dir := range []string{d.root, d.Path(), d.ConfigDir(), d.LogDir()} {
		if err := os.Mkdir(dir, 0o700); err != nil && !errors.Is(err, fs.ErrExist) {
			return err
		}
		if dir != d.root {
			info, err := os.Lstat(dir)
			if err != nil {
				return err
			}
			if !info.IsDir() {
				return fmt.Errorf("%s is not a directory (it is %s); remove it", display.Quote(dir), info.Mode().Type())
			}
		}
		if err := os.Chmod(dir, 0o700); err != nil {
			return err
		}
	}
	return nil
}

// Remove deletes the session dir and everything in it. Deleting the lock
// file lets a later Lock bypass any holder or waiter, so call Remove only
// when no other command can be using the session. A session dir that is a
// link is removed as the link alone.
func (d Dir) Remove() error { return os.RemoveAll(d.Path()) }

// Lock takes the session's lock (interoperable with flock(1)), saying on w
// that it waits when another command holds it. Hold it around a change to
// session.conf and the Reload that applies it.
func (d Dir) Lock(w io.Writer) (release func() error, err error) {
	return lock.Acquire(filepath.Join(d.Path(), ".lock"), "Waiting for another riotbox egress command on "+d.name+"…", w)
}

// Policy resolves the session's allowlist as the files now say
// (policy.Resolve): agent.conf as @agent, the system and user conf files
// (each optional) and, on top, session.conf. A session.conf line naming a
// group no file defines any more fails it, as it fails every reload, with
// the command that drops the line (Dangles).
func (d Dir) Policy(systemConf, userConf string) (policy.Resolved, error) {
	s, err := d.sources(systemConf, userConf)
	if err != nil {
		return policy.Resolved{}, err
	}
	r, err := policy.Resolve(s)
	var unknown *policy.UnknownGroupError
	if errors.As(err, &unknown) && unknown.File == d.SessionConf() {
		return policy.Resolved{}, fmt.Errorf("%s:%d: no group named @%s; run riotbox egress deny --session %s @%s to drop it from the session",
			unknown.File, unknown.Line, unknown.Group, d.name, unknown.Group)
	}
	return r, err
}

// sources reads the files Policy resolves.
func (d Dir) sources(systemConf, userConf string) (policy.Sources, error) {
	agent, err := d.AgentHosts()
	if err != nil {
		return policy.Sources{}, err
	}
	s := policy.Sources{Agent: agent}
	for _, f := range []struct {
		path string
		conf *policy.Conf
	}{{systemConf, &s.System}, {userConf, &s.User}, {d.SessionConf(), &s.Overlay}} {
		if *f.conf, err = ReadConf(f.path); err != nil {
			return policy.Sources{}, err
		}
	}
	return s, nil
}

// Dangles reports whether session.conf names @group, with either sign,
// though neither agent.conf nor a conf file defines group any more: the
// user deleted its [group] section. Such a line fails every Policy until
// DropOverlayGroup removes it; it is never skipped, as skipping a -@group
// would widen the allowlist unasked.
func (d Dir) Dangles(systemConf, userConf, group string) (bool, error) {
	s, err := d.sources(systemConf, userConf)
	if err != nil {
		return false, err
	}
	if _, known := policy.Groups(s.Agent, s.System, s.User)[group]; known {
		return false, nil
	}
	return slices.ContainsFunc(s.Overlay.Items, func(it policy.Item) bool { return it.Group == group }), nil
}

// DropOverlayGroup removes every session.conf line naming @group, with
// either sign. The caller holds Lock.
func (d Dir) DropOverlayGroup(group string) error {
	c, err := ReadConf(d.SessionConf())
	if err != nil {
		return err
	}
	c.Items = slices.DeleteFunc(c.Items, func(it policy.Item) bool { return it.Group == group })
	return d.writeOverlay(c)
}

// AgentHosts is the active agent's hosts as saved at start (agent.conf):
// the session's @agent. None when the file is missing.
func (d Dir) AgentHosts() ([]policy.Entry, error) {
	data, err := readOptional(d.AgentConf())
	if err != nil {
		return nil, err
	}
	return policy.ParseList(d.AgentConf(), data)
}

// ReadConf parses the egress.conf at path (policy.ParseFile); a missing
// file is an empty Conf named path.
func ReadConf(path string) (policy.Conf, error) {
	data, err := readOptional(path)
	if err != nil {
		return policy.Conf{}, err
	}
	return policy.ParseFile(path, data)
}

// readOptional returns the file at path, or nothing when it does not exist.
func readOptional(path string) ([]byte, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	return data, err
}

// SetOverlay records it in session.conf, replacing any earlier line that
// names the same entry or group with either sign. The new line goes last:
// policy.Resolve applies the overlay in order, so the latest allow or deny
// is the one that counts. The caller holds Lock.
func (d Dir) SetOverlay(it policy.Item) error {
	c, err := ReadConf(d.SessionConf())
	if err != nil {
		return err
	}
	c.Items = append(slices.DeleteFunc(c.Items, it.Names), it)
	return d.writeOverlay(c)
}

// SetOverlayStrict sets session.conf's strict setting; policy.StrictUnset
// removes it, so the conf files decide. The caller holds Lock.
func (d Dir) SetOverlayStrict(s policy.StrictSetting) error {
	c, err := ReadConf(d.SessionConf())
	if err != nil {
		return err
	}
	c.Strict = s
	return d.writeOverlay(c)
}

// writeOverlay writes c as session.conf: its strict setting, if any, then
// one line per item.
func (d Dir) writeOverlay(c policy.Conf) error {
	var b strings.Builder
	if c.Strict != policy.StrictUnset {
		b.WriteString(c.Strict.String() + "\n")
	}
	for _, it := range c.Items {
		b.WriteString(it.String() + "\n")
	}
	return WriteAtomic(d.SessionConf(), []byte(b.String()))
}

// WriteConfig writes all of Envoy's config files for r, intercepting the
// hosts the injection record names, for a proxy about to start.
func (d Dir) WriteConfig(r policy.Resolved) error {
	intercepts, err := d.intercepts()
	if err != nil {
		return err
	}
	files := envoyconfig.Render(d.name, r.Entries, intercepts)
	for _, f := range []struct {
		name string
		data []byte
	}{
		{envoyconfig.BootstrapFile, files.Bootstrap},
		{envoyconfig.CDSFile, files.CDS},
		{envoyconfig.LDSFile, files.LDS},
		{envoyconfig.RDSFile, files.RDS},
	} {
		if err := WriteAtomic(filepath.Join(d.ConfigDir(), f.name), f.data); err != nil {
			return err
		}
	}
	return d.recordApplied(r)
}

// Reload resolves the policy again (Policy) and replaces rds.json alone,
// which a running proxy applies without touching open tunnels. It returns
// the new policy.
func (d Dir) Reload(systemConf, userConf string) (policy.Resolved, error) {
	r, err := d.Policy(systemConf, userConf)
	if err != nil {
		return policy.Resolved{}, err
	}
	intercepts, err := d.intercepts()
	if err != nil {
		return policy.Resolved{}, err
	}
	if err := WriteAtomic(filepath.Join(d.ConfigDir(), envoyconfig.RDSFile), envoyconfig.RenderRDS(r.Entries, intercepts)); err != nil {
		return policy.Resolved{}, err
	}
	if err := d.recordApplied(r); err != nil {
		return policy.Resolved{}, err
	}
	return r, nil
}

// Applied is the allowlist last written to rds.json: what the proxy
// enforces, which can differ from Policy when a conf file changed since.
func (d Dir) Applied() ([]policy.Entry, error) {
	data, err := readOptional(d.appliedConf())
	if err != nil {
		return nil, err
	}
	return policy.ParseList(d.appliedConf(), data)
}

// AppliedStrict is the strict setting last applied, as
// policy.Resolved.StrictLabel spells it; "" for a session started by a
// release without strict mode.
func (d Dir) AppliedStrict() (string, error) {
	data, err := readOptional(d.appliedStrict())
	return strings.TrimSuffix(string(data), "\n"), err
}

func (d Dir) appliedStrict() string { return filepath.Join(d.Path(), "applied-strict") }

func (d Dir) recordApplied(r policy.Resolved) error {
	var b strings.Builder
	for _, e := range r.Entries {
		b.WriteString(e.String() + "\n")
	}
	if err := WriteAtomic(d.appliedConf(), []byte(b.String())); err != nil {
		return err
	}
	return WriteAtomic(d.appliedStrict(), []byte(r.StrictLabel()+"\n"))
}

// WriteProjects records the launch's project dirs. They are a JSON list so
// that any path, even one holding a newline, reads back whole.
func (d Dir) WriteProjects(dirs []string) error {
	data, err := json.Marshal(dirs)
	if err != nil {
		return err
	}
	return WriteAtomic(d.projectsFile(), append(data, '\n'))
}

// Projects is what WriteProjects recorded; none for a session started by
// a release that did not record them.
func (d Dir) Projects() ([]string, error) {
	data, err := os.ReadFile(d.projectsFile())
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("reading %s: %w", display.Quote(d.projectsFile()), err)
	}
	var dirs []string
	if err := json.Unmarshal(data, &dirs); err != nil {
		return nil, fmt.Errorf("reading %s: %w", display.Quote(d.projectsFile()), err)
	}
	return dirs, nil
}

// WriteAtomic replaces the file at path with data, mode 0600, through a
// temporary file in the same dir and a rename, so a reader (Envoy's file
// watch) sees the old file or the new one, never part of one. It then syncs
// the parent dir so the rename survives a crash.
func WriteAtomic(path string, data []byte) error { return writeAtomicMode(path, data, 0o600) }

// writeAtomicMode is WriteAtomic with the permission bits of the new file
// given, for replacing a file whose mode the user chose.
func writeAtomicMode(path string, data []byte, mode os.FileMode) (err error) {
	f, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".tmp-*")
	if err != nil {
		return err
	}
	defer func() {
		if err != nil {
			_ = os.Remove(f.Name())
		}
	}()
	if _, err = f.Write(data); err != nil {
		_ = f.Close() // the write error is the one to report
		return err
	}
	if err = f.Chmod(mode); err != nil {
		_ = f.Close() // the chmod error is the one to report
		return err
	}
	if err = f.Sync(); err != nil {
		_ = f.Close() // the sync error is the one to report
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	if err = os.Rename(f.Name(), path); err != nil {
		return err
	}
	parent, err := os.Open(filepath.Dir(path))
	if err != nil {
		return err
	}
	if err = parent.Sync(); err != nil {
		_ = parent.Close() // the sync error is the one to report
		return err
	}
	return parent.Close()
}

// SaveItem records it in the egress.conf at path as the user's latest word
// on it (docs/dev/egress.md#saving). Every line in the preamble or an
// [allow] section that names the same entry or group, with either sign, is
// dropped, and one new line is written, keeping the trailing comment of
// the last line dropped, so an earlier opposite choice cannot outvote this
// one. The new line ends the last [allow] section; a file with sections
// but no [allow] gains one at its end; a file with no sections, or no file,
// gets a bare last line. Every other line is kept verbatim, including
// lines that do not parse (ParseFile reports them). See editConf for
// locking, links and permissions.
func SaveItem(path string, it policy.Item, w io.Writer) error {
	_, err := editConf(path, w, func(lines []string) ([]string, bool) {
		return saveItemLines(lines, it), true
	})
	return err
}

// saveItemLines is SaveItem's edit.
func saveItemLines(lines []string, it policy.Item) []string {
	var out []string
	var comment string
	inAllow, inOther, sawSection := false, false, false
	insertAt := -1 // in out: after the last line with content in the last [allow] section
	for _, line := range lines {
		body, c := splitComment(line)
		if strings.HasPrefix(body, "[") {
			sawSection = true
			inAllow, inOther = body == "[allow]", body != "[allow]"
		} else if body != "" && !inOther {
			if old, err := policy.ParseItem(body); err == nil && old.Names(it) {
				comment = c
				continue
			}
		}
		out = append(out, line)
		if inAllow && body != "" {
			insertAt = len(out)
		}
	}
	newLine := it.String() + comment
	switch {
	case insertAt >= 0:
		return slices.Insert(out, insertAt, newLine)
	case sawSection:
		if strings.TrimSpace(out[len(out)-1]) != "" {
			out = append(out, "")
		}
		return append(out, "[allow]", newLine)
	default:
		return append(out, newLine)
	}
}

// SaveStrict sets the strict setting of the egress.conf at path to s, or
// with policy.StrictUnset removes it. Every strict line in the preamble is
// dropped; the new one takes the first one's place, keeping its comment,
// or, when there was none, goes after the file's leading comment and blank
// lines, which is still the preamble. A missing file is created only to
// set a value. It reports whether the file changed. See editConf for
// locking, links and permissions.
func SaveStrict(path string, s policy.StrictSetting, w io.Writer) (bool, error) {
	return editConf(path, w, func(lines []string) ([]string, bool) {
		return saveStrictLines(lines, s)
	})
}

// saveStrictLines is SaveStrict's edit; it reports false when there is
// nothing to change.
func saveStrictLines(lines []string, s policy.StrictSetting) ([]string, bool) {
	var out []string
	at, comment := -1, ""
	lead, leading, inPreamble := 0, true, true
	for _, line := range lines {
		body, c := splitComment(line)
		if strings.HasPrefix(body, "[") {
			inPreamble = false
		}
		if inPreamble && policy.IsStrictLine(body) {
			if at < 0 {
				at, comment = len(out), c
			}
			continue
		}
		out = append(out, line)
		if leading && body == "" {
			lead = len(out)
		} else {
			leading = false
		}
	}
	switch {
	case s == policy.StrictUnset:
		return out, at >= 0
	case at < 0:
		at, comment = lead, ""
	}
	return slices.Insert(out, at, s.String()+comment), true
}

// splitComment splits a conf line into its text before any "#", trimmed,
// and its comment with the blanks before it, or "" when it has none.
func splitComment(line string) (body, comment string) {
	text, rest, hasComment := strings.Cut(line, "#")
	body = strings.Trim(text, " \t\r")
	if hasComment {
		comment = text[len(strings.TrimRight(text, " \t\r")):] + "#" + rest
	}
	return body, comment
}

// editConf rewrites the conf file at path with edit, which gets its lines
// (none for a missing file) without their newlines and returns the new
// lines and whether to write them. It reports whether it wrote. The file
// is shared by sessions, so the read and the write happen under a lock
// file beside it, saying on w that it waits when another command holds
// it. A symlinked file is written through, and an existing file keeps its
// permissions; a new file is created 0600, with its parent dirs 0700. An
// edit that would not write a missing file creates nothing, not even the
// dirs the lock needs: edit is asked first, so it must have no side
// effects.
func editConf(path string, w io.Writer, edit func(lines []string) ([]string, bool)) (bool, error) {
	if _, err := os.Lstat(path); errors.Is(err, fs.ErrNotExist) {
		if _, write := edit(nil); !write {
			return false, nil
		}
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return false, err
	}
	if info, err := os.Lstat(path); err == nil && info.Mode()&os.ModeSymlink != 0 {
		if path, err = filepath.EvalSymlinks(path); err != nil {
			return false, err
		}
	}
	release, err := lock.Acquire(filepath.Join(filepath.Dir(path), "."+filepath.Base(path)+".lock"),
		"Waiting for another riotbox egress command to save "+display.Quote(path)+"…", w)
	if err != nil {
		return false, err
	}
	wrote, editErr := editConfLocked(path, edit)
	return wrote, errors.Join(editErr, release())
}

// editConfLocked is editConf's read-modify-write; the caller holds the
// lock on path.
func editConfLocked(path string, edit func(lines []string) ([]string, bool)) (bool, error) {
	mode := os.FileMode(0o600)
	if info, err := os.Stat(path); err == nil {
		mode = info.Mode().Perm()
	}
	data, err := readOptional(path)
	if err != nil {
		return false, err
	}
	var lines []string
	if text := strings.TrimSuffix(string(data), "\n"); text != "" {
		lines = strings.Split(text, "\n")
	}
	out, write := edit(lines)
	if !write {
		return false, nil
	}
	content := ""
	if len(out) > 0 {
		content = strings.Join(out, "\n") + "\n"
	}
	return true, writeAtomicMode(path, []byte(content), mode)
}

// maxLogLine bounds one access-log line, and the tail EnvoyLogTail returns.
const maxLogLine = 1 << 20

// openUntrusted opens the regular file at path for reading. Files under log/
// are written by the proxy container and are untrusted: it may have swapped
// one for a link (which a plain open would follow to read an arbitrary host
// file) or a FIFO (which a plain open would block on, hanging the command).
// Opening refuses a link; the file is then checked, by the descriptor it
// holds, to be a regular file. The returned info is of the open file. A
// missing file is an error wrapping fs.ErrNotExist.
func openUntrusted(path string) (*os.File, os.FileInfo, error) {
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK|syscall.O_CLOEXEC, 0)
	if err != nil {
		return nil, nil, err
	}
	info, err := f.Stat()
	if err != nil {
		_ = f.Close() // read-only; the stat error is the one to report
		return nil, nil, err
	}
	if !info.Mode().IsRegular() {
		_ = f.Close() // read-only
		return nil, nil, fmt.Errorf("%s is not a regular file (it is %s); the proxy container can write there, so it was not read", display.Quote(path), info.Mode().Type())
	}
	return f, info, nil
}

// CountDenied returns how many requests the access log at path records as
// answered 403. A missing log counts none; a line of over 1 MiB, or one that
// ends in a newline yet does not decode as JSON, is an error naming the
// line. A final line with no newline is skipped when it does not decode:
// Envoy may have been killed mid-write. The log is untrusted (see
// openUntrusted) and is read a line at a time.
func CountDenied(path string) (int, error) {
	f, _, err := openUntrusted(path)
	if errors.Is(err, fs.ErrNotExist) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	defer func() { _ = f.Close() }() // read-only
	r := bufio.NewReaderSize(f, maxLogLine+1)
	denied := 0
	for n := 1; ; n++ {
		line, err := r.ReadSlice('\n')
		if errors.Is(err, bufio.ErrBufferFull) {
			return 0, fmt.Errorf("%s:%d: line longer than 1 MiB", path, n)
		}
		if err != nil && !errors.Is(err, io.EOF) {
			return 0, fmt.Errorf("%s:%d: %w", path, n, err)
		}
		terminated := err == nil
		if len(bytes.TrimSpace(line)) > 0 {
			var rec struct {
				Status int `json:"status"`
			}
			switch jerr := json.Unmarshal(line, &rec); {
			case jerr == nil && rec.Status == 403:
				denied++
			case jerr != nil && terminated:
				return 0, fmt.Errorf("%s:%d: %w", path, n, jerr)
			}
		}
		if !terminated {
			return denied, nil
		}
	}
}

// EnvoyLogTail returns the last 1 MiB of Envoy's own log: all of it when it
// is smaller. A log not yet written is empty, not an error. It is the only
// way to read that file: the log is untrusted (see openUntrusted).
func (d Dir) EnvoyLogTail() ([]byte, error) {
	f, info, err := openUntrusted(d.EnvoyLog())
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	defer func() { _ = f.Close() }() // read-only
	if info.Size() > maxLogLine {
		if _, err := f.Seek(info.Size()-maxLogLine, io.SeekStart); err != nil {
			return nil, err
		}
	}
	return io.ReadAll(io.LimitReader(f, maxLogLine))
}

// Stale returns the names of the session dirs under root that live does not
// name and whose last sign of use (log/envoy.log, written as the proxy
// starts and stops; else the dir itself) is older than maxAge at now.
// Entries that are not dirs (symlinks included) or not valid names are
// left alone, as is an envoy.log that is not a regular file. A missing root
// has none. One session that cannot be examined does not stop the sweep: the
// error returned joins one error per such session, and the names returned
// are valid whether or not it is non-nil, so callers should act on them.
func Stale(root string, live map[string]bool, maxAge time.Duration, now time.Time) ([]string, error) {
	entries, err := os.ReadDir(root)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var stale []string
	var errs []error
	for _, e := range entries {
		name := e.Name()
		if !e.IsDir() || live[name] || ValidName(name) != nil {
			continue
		}
		d := Dir{root: root, name: name}
		info, err := os.Lstat(d.EnvoyLog())
		if err == nil && !info.Mode().IsRegular() {
			err = fs.ErrNotExist
		}
		if errors.Is(err, fs.ErrNotExist) {
			info, err = os.Lstat(d.Path())
		}
		if errors.Is(err, fs.ErrNotExist) {
			continue // removed since ReadDir; nothing left to sweep
		}
		if err != nil {
			errs = append(errs, err)
			continue
		}
		if now.Sub(info.ModTime()) > maxAge {
			stale = append(stale, name)
		}
	}
	return stale, errors.Join(errs...)
}
