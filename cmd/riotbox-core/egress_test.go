package main_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gexec"

	"github.com/trevor-vaughan/claude-riotbox/internal/display"
	"github.com/trevor-vaughan/claude-riotbox/internal/egress/inject"
	"github.com/trevor-vaughan/claude-riotbox/internal/egress/policy"
	"github.com/trevor-vaughan/claude-riotbox/internal/egress/state"
)

// fakeEngineScript answers `ps` with $FAKE_GATEWAYS and `pod ps` with
// $FAKE_PODS (both default "[]"), succeeds silently at everything else,
// logs each call's argv to $FAKE_LOG and, when $FAKE_ENVIRON is set, its
// environment to that file.
const fakeEngineScript = `#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_LOG"
if [ -n "$FAKE_ENVIRON" ]; then env >>"$FAKE_ENVIRON"; fi
case "$1 $2" in
"pod ps") printf '%s\n' "${FAKE_PODS:-[]}"; exit 0 ;;
esac
[ "$1" = ps ] && printf '%s\n' "${FAKE_GATEWAYS:-[]}"
exit 0
`

// vanishingEngineScript is fakeEngineScript except that `ps` answers
// $FAKE_GATEWAYS on its first call only (counted in $FAKE_PS_COUNT) and "[]"
// afterwards: the session stops while a command is working on it.
const vanishingEngineScript = `#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_LOG"
if [ "$1" = ps ]; then
	if [ -e "$FAKE_PS_COUNT" ]; then echo '[]'; else touch "$FAKE_PS_COUNT"; printf '%s\n' "$FAKE_GATEWAYS"; fi
fi
exit 0
`

// failingPSEngineScript is vanishingEngineScript except that `ps` fails on
// every call after the first: the engine breaks while a command works.
const failingPSEngineScript = `#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_LOG"
if [ "$1" = ps ]; then
	if [ -e "$FAKE_PS_COUNT" ]; then echo 'engine is down' >&2; exit 1; fi
	touch "$FAKE_PS_COUNT"; printf '%s\n' "$FAKE_GATEWAYS"
fi
exit 0
`

var _ = Describe("egress verbs", func() {
	var tmp, engine, root, sys, user, log string
	var env []string

	runEgressIn := func(stdin string, args ...string) *gexec.Session {
		cmd := exec.Command(binary, args...)
		cmd.Env = append(os.Environ(), env...)
		cmd.Stdin = strings.NewReader(stdin)
		s, err := gexec.Start(cmd, GinkgoWriter, GinkgoWriter)
		Expect(err).NotTo(HaveOccurred())
		Eventually(s).Should(gexec.Exit())
		return s
	}
	runEgress := func(args ...string) *gexec.Session { return runEgressIn("", args...) }
	confArgs := func(verb string) []string {
		return []string{verb, "--engine", engine, "--state-root", root, "--system-conf", sys, "--user-conf", user}
	}
	seed := func(name string, entries ...policy.Entry) state.Dir {
		d, err := state.Open(root, name)
		Expect(err).NotTo(HaveOccurred())
		Expect(d.Create()).To(Succeed())
		Expect(d.WriteConfig(policy.Resolved{Entries: entries, StrictFrom: policy.SourceDefault})).To(Succeed())
		return d
	}
	gatewaysJSON := func(names ...string) string {
		var parts []string
		for _, n := range names {
			parts = append(parts, `{"Names":["`+n+`-egress"],"Labels":{"riotbox.egress":"`+n+`","riotbox.egress-role":"gateway"}}`)
		}
		return "FAKE_GATEWAYS=[" + strings.Join(parts, ",") + "]"
	}

	BeforeEach(func() {
		tmp = GinkgoT().TempDir()
		engine = filepath.Join(tmp, "podman")
		Expect(os.WriteFile(engine, []byte(fakeEngineScript), 0o755)).To(Succeed())
		root = filepath.Join(tmp, "riotbox-egress")
		sys = filepath.Join(tmp, "etc-egress.conf")
		user = filepath.Join(tmp, "config", "riotbox", "egress.conf")
		log = filepath.Join(tmp, "engine.log")
		env = []string{"FAKE_LOG=" + log}
	})

	Describe("egress-up", func() {
		upArgs := func(pid, name string) []string {
			return append(confArgs("egress-up"), "--image", "img", "--session-key", "k", "--owner-pid", pid, "--", name)
		}

		It("is a usage error when --owner-pid is not a process ID", func() {
			s := runEgress(upArgs("x", "s1")...)
			Expect(s.ExitCode()).To(Equal(2))
			Expect(string(s.Err.Contents())).To(ContainSubstring("--owner-pid x is not a process ID"))
		})

		It("refuses a name that is not a session name, before touching the engine", func() {
			s := runEgress(upArgs("1", "../x")...)
			Expect(s.ExitCode()).To(Equal(1))
			Expect(string(s.Err.Contents())).To(ContainSubstring("is not a session name"))
			Expect(log).NotTo(BeAnExistingFile())
		})

		DescribeTable("refuses malformed variables on stdin before touching the engine, never echoing them",
			func(stdin, want string) {
				s := runEgressIn(stdin, upArgs("1", "s1")...)
				Expect(s.ExitCode()).To(Equal(1))
				Expect(string(s.Err.Contents())).To(ContainSubstring(want))
				Expect(string(s.Err.Contents())).NotTo(ContainSubstring("s3cret"))
				Expect(log).NotTo(BeAnExistingFile())
				Expect(filepath.Join(root, "s1")).NotTo(BeAnExistingFile())
			},
			Entry("a record without =", "api.example.com\n\x00s3cret\x00", "variable record 1 on stdin is not NAME=VALUE"),
			Entry("a record without its NUL", "api.example.com\n\x00ANTHROPIC_API_KEY=s3cret", "variable record 1 on stdin has no terminating NUL"),
			Entry("a name that is not a variable name", "\x00A=1\x00BAD-NAME=s3cret\x00", "variable record 2 on stdin is not NAME=VALUE"),
			Entry("a repeated name", "\x00ANTHROPIC_API_KEY=s3cret\x00ANTHROPIC_API_KEY=s3cret2\x00", "variable record 2 on stdin repeats ANTHROPIC_API_KEY"),
			Entry("more than 1 MiB", "\x00ANTHROPIC_API_KEY="+strings.Repeat("s3cret", 1<<20/6+1)+"\x00", "stdin holds more than 1 MiB"),
		)

		It("accepts exactly 1 MiB on stdin", func() {
			stdin := "\x00K=" + strings.Repeat("x", 1<<20-4) + "\x00"
			Expect(stdin).To(HaveLen(1 << 20))
			s := runEgressIn(stdin, upArgs("1", "s1")...)
			Expect(string(s.Err.Contents())).NotTo(ContainSubstring("MiB"))
			Expect(log).To(BeAnExistingFile())
		})

		// privateRuntime makes a private dir on /dev/shm, a tmpfs, for
		// $XDG_RUNTIME_DIR, removed after the spec; it skips the spec
		// where there is none.
		privateRuntime := func() string {
			run, err := os.MkdirTemp("/dev/shm", "riotbox-core-spec-")
			if err != nil {
				Skip("no /dev/shm to make a tmpfs runtime dir in: " + err.Error())
			}
			DeferCleanup(os.RemoveAll, run)
			if ok, err := state.HostRuntime().IsTmpfs(run); err != nil || !ok {
				Skip("/dev/shm is not a tmpfs here")
			}
			return run
		}
		// noRuntime points $XDG_RUNTIME_DIR at a dir that does not
		// qualify (mode 0755), and skips the spec when /run/user/<uid>
		// does.
		noRuntime := func() {
			h := state.HostRuntime()
			h.Getenv = func(string) string { return "" }
			if _, err := state.RuntimeBase(h); err == nil {
				Skip("/run/user/<uid> is a private tmpfs here, so egress-up has a runtime dir")
			}
			run := filepath.Join(tmp, "run")
			Expect(os.Mkdir(run, 0o755)).To(Succeed())
			Expect(os.Chmod(run, 0o755)).To(Succeed())
			env = append(env, "XDG_RUNTIME_DIR="+run)
		}
		keyStdin := "api.example.com\n\x00ANTHROPIC_API_KEY=sk-ant-s3cret-injected\x00"

		// The fake engine runs no Envoy, so these starts fail at the
		// readiness wait, after every engine object was created, and roll
		// back.
		It("mounts the injected key's secrets from the runtime tmpfs, keeps the CA and record in the state dir, and removes the secrets on rollback", func() {
			run := privateRuntime()
			env = append(env, "XDG_RUNTIME_DIR="+run)
			s := runEgressIn(keyStdin, upArgs("1", "s1")...)
			Expect(string(s.Err.Contents())).To(ContainSubstring("the egress proxy exited during startup"))
			secrets := filepath.Join(run, "riotbox-egress", "s1", "secrets")
			engineLog, err := os.ReadFile(log)
			Expect(err).NotTo(HaveOccurred())
			Expect(string(engineLog)).To(ContainSubstring(" -v " + secrets + ":/etc/riotbox-egress-secrets:ro,z "))
			Expect(filepath.Join(root, "s1", "ca.crt")).To(BeARegularFile())
			Expect(filepath.Join(root, "s1", "injected")).To(BeARegularFile())
			Expect(filepath.Join(root, "s1", "secrets")).NotTo(BeAnExistingFile())
			Expect(filepath.Dir(secrets)).NotTo(BeAnExistingFile())
		})

		It("fails with keys to inject and no private tmpfs runtime dir, creating nothing", func() {
			noRuntime()
			s := runEgressIn(keyStdin, upArgs("1", "s1")...)
			Expect(s.ExitCode()).To(Equal(1))
			Expect(string(s.Err.Contents())).To(ContainSubstring("credential injection needs a private tmpfs runtime dir ($XDG_RUNTIME_DIR or /run/user/<uid>) so keys never reach disk; none found — unset the keys to run without injection, or start the session from a login session"))
			Expect(string(s.Err.Contents())).To(ContainSubstring("is mode 0755, not 0700"))
			Expect(string(s.Err.Contents())).NotTo(ContainSubstring("s3cret"))
			Expect(root).NotTo(BeAnExistingFile())
			Expect(log).NotTo(BeAnExistingFile())
		})

		It("starts a session with no key to inject without a runtime dir", func() {
			noRuntime()
			s := runEgressIn("api.example.com\n\x00GITHUB_TOKEN=ghp-passthrough-value\x00", upArgs("1", "s1")...)
			Expect(string(s.Err.Contents())).NotTo(ContainSubstring("runtime dir"))
			engineLog, err := os.ReadFile(log)
			Expect(err).NotTo(HaveOccurred())
			Expect(string(engineLog)).To(ContainSubstring("run -d "))
			Expect(string(engineLog)).NotTo(ContainSubstring("riotbox-egress-secrets"))
		})

		It("removes the runtime secrets at egress-down, and an idle orphan's at egress-sweep", func() {
			run := privateRuntime()
			env = append(env, "XDG_RUNTIME_DIR="+run)
			secrets := filepath.Join(run, "riotbox-egress", "s1", "secrets")
			Expect(os.MkdirAll(secrets, 0o700)).To(Succeed())
			Expect(runEgress("egress-down", "--engine", engine, "--state-root", root, "--", "s1").ExitCode()).To(Equal(0))
			Expect(filepath.Dir(secrets)).NotTo(BeAnExistingFile())

			orphan := filepath.Join(run, "riotbox-egress", "gone", "secrets")
			Expect(os.MkdirAll(orphan, 0o700)).To(Succeed())
			old := time.Now().Add(-2 * time.Hour)
			Expect(os.Chtimes(filepath.Dir(orphan), old, old)).To(Succeed())
			Expect(runEgress("egress-sweep", "--engine", engine, "--state-root", root).ExitCode()).To(Equal(0))
			Expect(filepath.Dir(orphan)).NotTo(BeAnExistingFile())
		})

		It("drops the injected keys from the engine's environment, keeps the others, and names them without values", func() {
			environ := filepath.Join(tmp, "environ")
			env = append(env, "XDG_RUNTIME_DIR="+privateRuntime(), "FAKE_ENVIRON="+environ,
				"ANTHROPIC_API_KEY=sk-ant-s3cret-injected", "GITHUB_TOKEN=ghp-passthrough-value")
			s := runEgressIn("api.example.com\n\x00ANTHROPIC_API_KEY=sk-ant-s3cret-injected\x00GITHUB_TOKEN=ghp-passthrough-value\x00",
				upArgs("1", "s1")...)
			Expect(string(s.Err.Contents())).To(ContainSubstring("egress: these keys still enter the container: GITHUB_TOKEN (not injectable: not in the provider table)"))
			Expect(string(s.Err.Contents())).NotTo(ContainSubstring("ANTHROPIC_API_KEY ("))
			Expect(string(s.Err.Contents())).NotTo(ContainSubstring("s3cret"))
			Expect(string(s.Err.Contents())).NotTo(ContainSubstring("ghp-passthrough-value"))
			// Booleans, not ContainSubstring: a failure must not print the
			// engine's environment, which holds this session's own tokens.
			got, err := os.ReadFile(environ)
			Expect(err).NotTo(HaveOccurred())
			Expect(strings.Contains(string(got), "s3cret")).To(BeFalse(), "an engine command inherited the injected key")
			Expect(strings.Contains("\n"+string(got), "\nGITHUB_TOKEN=ghp-passthrough-value\n")).To(BeTrue(), "an engine command lost the pass-through key")
		})
	})

	Describe("egress-allow and egress-deny", func() {
		It("allows an entry in the only running session, live, and saves it on request", func() {
			d := seed("s1")
			env = append(env, gatewaysJSON("s1"))
			save := filepath.Join(tmp, "config", "riotbox", "egress.conf")
			s := runEgress(append(confArgs("egress-allow"), "--save-to", save, "--", "Example.ORG")...)
			Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
			Expect(string(s.Out.Contents())).To(Equal("egress: s1: allowed example.org\negress: saved example.org to " + save + "\n"))
			Expect(os.ReadFile(d.SessionConf())).To(Equal([]byte("example.org\n")))
			rds, err := os.ReadFile(filepath.Join(d.ConfigDir(), "rds.json"))
			Expect(err).NotTo(HaveOccurred())
			Expect(string(rds)).To(ContainSubstring(`"example.org:443"`))
			Expect(os.ReadFile(save)).To(Equal([]byte("example.org\n")))
		})

		It("denies an entry, saving it as a removal, and notes a wildcard that still covers it", func() {
			Expect(os.MkdirAll(filepath.Dir(user), 0o700)).To(Succeed())
			Expect(os.WriteFile(user, []byte("*.example.org\n"), 0o600)).To(Succeed())
			d := seed("s1")
			env = append(env, gatewaysJSON("s1"))
			s := runEgress(append(confArgs("egress-deny"), "--save-to", user, "--", "a.example.org")...)
			Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
			Expect(string(s.Out.Contents())).To(ContainSubstring("egress: s1: denied a.example.org\n"))
			Expect(string(s.Out.Contents())).To(ContainSubstring("egress: saved -a.example.org to " + user + "\n"))
			Expect(string(s.Err.Contents())).To(ContainSubstring("egress: note: a.example.org is still allowed by *.example.org\n"))
			Expect(os.ReadFile(d.SessionConf())).To(Equal([]byte("-a.example.org\n")))
			Expect(os.ReadFile(user)).To(Equal([]byte("*.example.org\n-a.example.org\n")))
		})

		It("refuses an entry written with a leading dash", func() {
			s := runEgress(append(confArgs("egress-deny"), "--", "-a.example.org")...)
			Expect(s.ExitCode()).To(Equal(1))
			Expect(string(s.Err.Contents())).To(ContainSubstring("give the entry without a leading -"))
		})

		It("refuses an invalid entry", func() {
			s := runEgress(append(confArgs("egress-allow"), "--", "10.0.0.1")...)
			Expect(s.ExitCode()).To(Equal(1))
			Expect(string(s.Err.Contents())).To(ContainSubstring(`invalid egress entry "10.0.0.1"`))
		})

		It("refuses when no session runs, and when several do and none is named", func() {
			s := runEgress(append(confArgs("egress-allow"), "--", "a.example")...)
			Expect(s.ExitCode()).To(Equal(1))
			Expect(string(s.Err.Contents())).To(ContainSubstring("no egress session is running"))
			env = append(env, gatewaysJSON("s1", "s2"))
			s = runEgress(append(confArgs("egress-allow"), "--", "a.example")...)
			Expect(s.ExitCode()).To(Equal(1))
			Expect(string(s.Err.Contents())).To(ContainSubstring("pick one with --session: s1 s2"))
		})

		It("acts on the session named with --session", func() {
			d1 := seed("s1")
			d2 := seed("s2")
			env = append(env, gatewaysJSON("s1", "s2"))
			s := runEgress(append(confArgs("egress-allow"), "--session", "s2", "--", "b.example")...)
			Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
			Expect(os.ReadFile(d2.SessionConf())).To(Equal([]byte("b.example\n")))
			Expect(d1.SessionConf()).NotTo(BeAnExistingFile())
		})

		It("prints no note when no wildcard covers a denied entry", func() {
			seed("s1")
			env = append(env, gatewaysJSON("s1"))
			s := runEgress(append(confArgs("egress-deny"), "--", "a.example.org")...)
			Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
			Expect(string(s.Err.Contents())).NotTo(ContainSubstring("note"))
		})

		It("lets a saved allow undo an earlier saved deny of the same entry", func() {
			seed("s1")
			env = append(env, gatewaysJSON("s1"))
			for _, verb := range []string{"egress-deny", "egress-allow"} {
				s := runEgress(append(confArgs(verb), "--save-to", user, "--", "x.example")...)
				Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
			}
			c, err := state.ReadConf(user)
			Expect(err).NotTo(HaveOccurred())
			Expect(c.Items).To(Equal([]policy.Item{{Entry: policy.Entry{Host: "x.example", Port: 443}, Line: 1}}))
		})

		It("saves into [allow], not into the [group] section the user conf ends with", func() {
			seed("s1")
			env = append(env, gatewaysJSON("s1"))
			Expect(os.MkdirAll(filepath.Dir(user), 0o700)).To(Succeed())
			Expect(os.WriteFile(user, []byte("a.example\n[group corp]\ncorp.example\n"), 0o600)).To(Succeed())
			s := runEgress(append(confArgs("egress-allow"), "--save-to", user, "--", "x.example")...)
			Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
			s = runEgress(append(confArgs("egress-deny"), "--save-to", user, "--", "y.example")...)
			Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
			Expect(os.ReadFile(user)).To(Equal([]byte("a.example\n[group corp]\ncorp.example\n\n[allow]\nx.example\n-y.example\n")))
			c, err := state.ReadConf(user)
			Expect(err).NotTo(HaveOccurred())
			Expect(c.Groups).To(Equal([]policy.GroupDef{{Name: "corp", Members: []policy.Entry{{Host: "corp.example", Port: 443}}, Line: 2}}))
		})

		It("quotes a save path that needs it", func() {
			seed("s1")
			env = append(env, gatewaysJSON("s1"))
			user = filepath.Join(tmp, "my dir", "egress.conf")
			s := runEgress(append(confArgs("egress-allow"), "--save-to", user, "--", "x.example")...)
			Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
			Expect(string(s.Out.Contents())).To(ContainSubstring("egress: saved x.example to " + display.Quote(user) + "\n"))
		})

		It("saves to the system conf, named by an equivalent path", func() {
			seed("s1")
			env = append(env, gatewaysJSON("s1"))
			s := runEgress(append(confArgs("egress-allow"), "--save-to", filepath.Dir(sys)+"/./"+filepath.Base(sys), "--", "x.example")...)
			Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
			Expect(os.ReadFile(sys)).To(Equal([]byte("x.example\n")))
		})

		DescribeTable("refuses, as a usage error and changing nothing, a --save-to that is neither conf file",
			func(verb, arg string) {
				d := seed("s1")
				env = append(env, gatewaysJSON("s1"))
				for _, other := range []string{filepath.Join(tmp, "other.conf"), ""} {
					s := runEgress(append(confArgs(verb), "--save-to", other, "--", arg)...)
					Expect(s.ExitCode()).To(Equal(2), other)
					Expect(string(s.Err.Contents())).To(ContainSubstring("riotbox-core: " + verb + ": --save-to must be the --system-conf or --user-conf file, not " + display.Quote(other) + "\n"))
					Expect(string(s.Out.Contents())).To(BeEmpty())
					Expect(d.SessionConf()).NotTo(BeAnExistingFile())
					Expect(filepath.Join(tmp, "other.conf")).NotTo(BeAnExistingFile())
				}
			},
			Entry("egress-allow", "egress-allow", "x.example"),
			Entry("egress-deny", "egress-deny", "x.example"),
			Entry("egress-strict", "egress-strict", "on"),
		)

		It("refuses an empty --session as a usage error", func() {
			for _, verb := range []string{"egress-allow", "egress-deny"} {
				s := runEgress(append(confArgs(verb), "--session", "", "--", "x.example")...)
				Expect(s.ExitCode()).To(Equal(2), verb)
			}
			s := runEgress(append(confArgs("egress-reload"), "--session", "")...)
			Expect(s.ExitCode()).To(Equal(2))
		})

		It("leaves session.conf as it was and says so when the conf files cannot be loaded", func() {
			d := seed("s1")
			env = append(env, gatewaysJSON("s1"))
			Expect(os.MkdirAll(filepath.Dir(user), 0o700)).To(Succeed())
			Expect(os.WriteFile(user, []byte("10.0.0.1\n"), 0o600)).To(Succeed())

			s := runEgress(append(confArgs("egress-allow"), "--", "x.example")...)
			Expect(s.ExitCode()).To(Equal(1))
			Expect(string(s.Err.Contents())).To(ContainSubstring("x.example was not applied: " + user + ":1:"))
			Expect(string(s.Err.Contents())).NotTo(ContainSubstring("may still enforce"))
			Expect(string(s.Out.Contents())).NotTo(ContainSubstring("allowed"))
			Expect(d.SessionConf()).NotTo(BeAnExistingFile())

			Expect(os.WriteFile(d.SessionConf(), []byte("-old.example\n"), 0o600)).To(Succeed())
			s = runEgress(append(confArgs("egress-deny"), "--", "x.example")...)
			Expect(s.ExitCode()).To(Equal(1))
			Expect(os.ReadFile(d.SessionConf())).To(Equal([]byte("-old.example\n")))
		})

		It("changes nothing the proxy enforces when a conf file names no such group", func() {
			d := seed("s1", policy.Entry{Host: "kept.example", Port: 443})
			env = append(env, gatewaysJSON("s1"))
			rds := filepath.Join(d.ConfigDir(), "rds.json")
			applied := filepath.Join(d.Path(), "applied.conf")
			rdsBefore, err := os.ReadFile(rds)
			Expect(err).NotTo(HaveOccurred())
			appliedBefore, err := os.ReadFile(applied)
			Expect(err).NotTo(HaveOccurred())
			Expect(os.MkdirAll(filepath.Dir(user), 0o700)).To(Succeed())
			Expect(os.WriteFile(user, []byte("ok.example\n@nosuch\n"), 0o600)).To(Succeed())

			s := runEgress(append(confArgs("egress-allow"), "--", "x.example")...)
			Expect(s.ExitCode()).To(Equal(1))
			Expect(string(s.Err.Contents())).To(ContainSubstring("x.example was not applied: " + user + ":2: no group named @nosuch"))
			Expect(d.SessionConf()).NotTo(BeAnExistingFile())

			s = runEgress(append(confArgs("egress-reload"), "--session", "s1")...)
			Expect(s.ExitCode()).To(Equal(1))
			Expect(string(s.Err.Contents())).To(ContainSubstring("s1: " + user + ":2: no group named @nosuch"))
			Expect(string(s.Out.Contents())).NotTo(ContainSubstring("reloaded"))

			Expect(os.ReadFile(rds)).To(Equal(rdsBefore))
			Expect(os.ReadFile(applied)).To(Equal(appliedBefore))
		})

		It("takes the change back out of the live proxy when the engine fails after it was applied", func() {
			d := seed("s1")
			Expect(os.WriteFile(engine, []byte(failingPSEngineScript), 0o755)).To(Succeed())
			env = append(env, gatewaysJSON("s1"), "FAKE_PS_COUNT="+filepath.Join(tmp, "ps-count"))
			s := runEgress(append(confArgs("egress-allow"), "--", "x.example")...)
			Expect(s.ExitCode()).To(Equal(1))
			Expect(string(s.Err.Contents())).To(ContainSubstring("x.example was not applied: could not check that s1 is still running"))
			Expect(string(s.Out.Contents())).To(BeEmpty())
			Expect(d.SessionConf()).NotTo(BeAnExistingFile())
			rds, err := os.ReadFile(filepath.Join(d.ConfigDir(), "rds.json"))
			Expect(err).NotTo(HaveOccurred())
			Expect(string(rds)).NotTo(ContainSubstring("x.example"))
			applied, err := d.Applied()
			Expect(err).NotTo(HaveOccurred())
			Expect(applied).NotTo(ContainElement(policy.Entry{Host: "x.example", Port: 443}))
		})

		It("fails, without saying it allowed anything, when the session stops during the command", func() {
			seed("s1")
			counter := filepath.Join(tmp, "ps-count")
			Expect(os.WriteFile(engine, []byte(vanishingEngineScript), 0o755)).To(Succeed())
			env = append(env, gatewaysJSON("s1"), "FAKE_PS_COUNT="+counter)
			s := runEgress(append(confArgs("egress-allow"), "--", "x.example")...)
			Expect(s.ExitCode()).To(Equal(1))
			Expect(string(s.Err.Contents())).To(ContainSubstring("no egress session named s1 is running"))
			Expect(string(s.Out.Contents())).To(BeEmpty())
		})

		It("allows a group, live, storing the reference so a reload re-resolves it", func() {
			d := seed("s1")
			env = append(env, gatewaysJSON("s1"))
			Expect(os.MkdirAll(filepath.Dir(user), 0o700)).To(Succeed())
			Expect(os.WriteFile(user, []byte("strict\n"), 0o600)).To(Succeed())
			s := runEgress(append(confArgs("egress-allow"), "--", "@pypi")...)
			Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
			Expect(string(s.Out.Contents())).To(Equal("egress: s1: allowed @pypi\n"))
			Expect(os.ReadFile(d.SessionConf())).To(Equal([]byte("@pypi\n")))
			Expect(d.Applied()).To(Equal([]policy.Entry{{Host: "files.pythonhosted.org", Port: 443}, {Host: "pypi.org", Port: 443}}))
			Expect(os.WriteFile(user, []byte("strict\n[group pypi]\npypi.corp.example\n"), 0o600)).To(Succeed())
			s = runEgress(confArgs("egress-reload")...)
			Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
			Expect(d.Applied()).To(Equal([]policy.Entry{{Host: "pypi.corp.example", Port: 443}}))
		})

		It("denies a group, saving it as -@group, and notes members a wildcard still allows", func() {
			Expect(os.MkdirAll(filepath.Dir(user), 0o700)).To(Succeed())
			Expect(os.WriteFile(user, []byte("[group corp]\na.corp.example\nb.corp.example\n[allow]\n@corp\n*.corp.example\n"), 0o600)).To(Succeed())
			d := seed("s1")
			env = append(env, gatewaysJSON("s1"))
			s := runEgress(append(confArgs("egress-deny"), "--save-to", user, "--", "@corp")...)
			Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
			Expect(string(s.Out.Contents())).To(Equal("egress: s1: denied @corp\negress: saved -@corp to " + user + "\n"))
			Expect(string(s.Err.Contents())).To(ContainSubstring("egress: note: a.corp.example is still allowed by *.corp.example\n"))
			Expect(string(s.Err.Contents())).To(ContainSubstring("egress: note: b.corp.example is still allowed by *.corp.example\n"))
			Expect(os.ReadFile(d.SessionConf())).To(Equal([]byte("-@corp\n")))
			Expect(os.ReadFile(user)).To(Equal([]byte("[group corp]\na.corp.example\nb.corp.example\n[allow]\n*.corp.example\n-@corp\n")))
		})

		It("refuses a group no file defines, leaving the overlay as it was", func() {
			d := seed("s1")
			env = append(env, gatewaysJSON("s1"))
			s := runEgress(append(confArgs("egress-allow"), "--", "@nosuch")...)
			Expect(s.ExitCode()).To(Equal(1))
			Expect(string(s.Err.Contents())).To(ContainSubstring("@nosuch was not applied: no group named @nosuch"))
			Expect(string(s.Out.Contents())).To(BeEmpty())
			Expect(d.SessionConf()).NotTo(BeAnExistingFile())
		})

		It("refuses a misspelt group name, and a group with a leading dash", func() {
			s := runEgress(append(confArgs("egress-allow"), "--", "@PyPI")...)
			Expect(s.ExitCode()).To(Equal(1))
			Expect(string(s.Err.Contents())).To(ContainSubstring(`invalid group name "PyPI"`))
			s = runEgress(append(confArgs("egress-deny"), "--", "-@npm")...)
			Expect(s.ExitCode()).To(Equal(1))
			Expect(string(s.Err.Contents())).To(ContainSubstring("give the entry without a leading -"))
		})

		It("refuses to deny a group no file defines, changing nothing", func() {
			d := seed("s1", policy.Entry{Host: "kept.example", Port: 443})
			env = append(env, gatewaysJSON("s1"))
			s := runEgress(append(confArgs("egress-deny"), "--", "@nosuch")...)
			Expect(s.ExitCode()).To(Equal(1))
			Expect(string(s.Err.Contents())).To(ContainSubstring("@nosuch was not applied: no group named @nosuch"))
			Expect(string(s.Out.Contents())).To(BeEmpty())
			Expect(d.SessionConf()).NotTo(BeAnExistingFile())
			Expect(d.Applied()).To(Equal([]policy.Entry{{Host: "kept.example", Port: 443}}))
		})

		It("refuses a bare @, before touching the engine", func() {
			s := runEgress(append(confArgs("egress-allow"), "--", "@")...)
			Expect(s.ExitCode()).To(Equal(1))
			Expect(string(s.Err.Contents())).To(ContainSubstring(`invalid group name ""`))
			Expect(log).NotTo(BeAnExistingFile())
		})

		It("allows @agent, the active agent's own hosts, when strict left them out", func() {
			d := seed("s1")
			Expect(os.WriteFile(d.AgentConf(), []byte("api.agent.example\n"), 0o600)).To(Succeed())
			env = append(env, gatewaysJSON("s1"))
			Expect(os.MkdirAll(filepath.Dir(user), 0o700)).To(Succeed())
			Expect(os.WriteFile(user, []byte("strict\n"), 0o600)).To(Succeed())
			s := runEgress(append(confArgs("egress-allow"), "--", "@agent")...)
			Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
			Expect(string(s.Out.Contents())).To(Equal("egress: s1: allowed @agent\n"))
			Expect(d.Applied()).To(Equal([]policy.Entry{{Host: "api.agent.example", Port: 443}}))
		})

		It("saves an allowed group as its reference in [allow]", func() {
			Expect(os.MkdirAll(filepath.Dir(user), 0o700)).To(Succeed())
			Expect(os.WriteFile(user, []byte("strict\n[group corp]\ncorp.example\n"), 0o600)).To(Succeed())
			d := seed("s1")
			env = append(env, gatewaysJSON("s1"))
			s := runEgress(append(confArgs("egress-allow"), "--save-to", user, "--", "@corp")...)
			Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
			Expect(string(s.Out.Contents())).To(Equal("egress: s1: allowed @corp\negress: saved @corp to " + user + "\n"))
			Expect(os.ReadFile(user)).To(Equal([]byte("strict\n[group corp]\ncorp.example\n\n[allow]\n@corp\n")))
			Expect(d.Applied()).To(Equal([]policy.Entry{{Host: "corp.example", Port: 443}}))
		})

		It("denies a group the default allowlist holds, with no note when no wildcard covers its members", func() {
			d := seed("s1")
			env = append(env, gatewaysJSON("s1"))
			s := runEgress(append(confArgs("egress-deny"), "--", "@pypi")...)
			Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
			Expect(string(s.Out.Contents())).To(Equal("egress: s1: denied @pypi\n"))
			Expect(string(s.Err.Contents())).NotTo(ContainSubstring("still allowed"))
			applied, err := d.Applied()
			Expect(err).NotTo(HaveOccurred())
			Expect(applied).To(ContainElement(policy.Entry{Host: "registry.npmjs.org", Port: 443}))
			Expect(applied).NotTo(ContainElement(policy.Entry{Host: "pypi.org", Port: 443}))
			Expect(applied).NotTo(ContainElement(policy.Entry{Host: "files.pythonhosted.org", Port: 443}))
		})

		Context("when a session line names a group the conf files no longer define", func() {
			var d state.Dir
			var rds string
			hint := func(line string) string {
				return d.SessionConf() + ":" + line + ": no group named @corp; run riotbox egress deny --session s1 @corp to drop it from the session"
			}

			BeforeEach(func() {
				Expect(os.MkdirAll(filepath.Dir(user), 0o700)).To(Succeed())
				Expect(os.WriteFile(user, []byte("strict\nkept.example\n"), 0o600)).To(Succeed())
				d = seed("s1", policy.Entry{Host: "old.example", Port: 443})
				rds = filepath.Join(d.ConfigDir(), "rds.json")
				env = append(env, gatewaysJSON("s1"))
			})

			DescribeTable("drops the line on allow or deny of that group, and applies the rest",
				func(verb, line string) {
					Expect(os.WriteFile(d.SessionConf(), []byte("extra.example\n"+line+"\n"), 0o600)).To(Succeed())
					s := runEgress(append(confArgs(verb), "--", "@corp")...)
					Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
					Expect(string(s.Out.Contents())).To(Equal("egress: s1: dropped @corp from the session (no group named @corp any more)\n"))
					Expect(os.ReadFile(d.SessionConf())).To(Equal([]byte("extra.example\n")))
					Expect(d.Applied()).To(Equal([]policy.Entry{{Host: "extra.example", Port: 443}, {Host: "kept.example", Port: 443}}))
					Expect(os.ReadFile(rds)).To(ContainSubstring(`"extra.example:443"`))
					Expect(os.ReadFile(rds)).NotTo(ContainSubstring(`"old.example:443"`))
				},
				Entry("allow, for an allowed group", "egress-allow", "@corp"),
				Entry("deny, for an allowed group", "egress-deny", "@corp"),
				Entry("allow, for a denied group", "egress-allow", "-@corp"),
				Entry("deny, for a denied group", "egress-deny", "-@corp"),
			)

			It("refuses to drop it with --save, changing nothing, and says so", func() {
				Expect(os.WriteFile(d.SessionConf(), []byte("-@corp\n"), 0o600)).To(Succeed())
				rdsBefore, err := os.ReadFile(rds)
				Expect(err).NotTo(HaveOccurred())
				s := runEgress(append(confArgs("egress-deny"), "--save-to", user, "--", "@corp")...)
				Expect(s.ExitCode()).To(Equal(1))
				Expect(string(s.Err.Contents())).To(ContainSubstring("@corp was not applied: no group named @corp, so it cannot be saved; nothing was changed (run it without --save to drop @corp from the session)"))
				Expect(string(s.Out.Contents())).To(BeEmpty())
				Expect(os.ReadFile(d.SessionConf())).To(Equal([]byte("-@corp\n")))
				Expect(os.ReadFile(user)).To(Equal([]byte("strict\nkept.example\n")))
				Expect(os.ReadFile(rds)).To(Equal(rdsBefore))
			})

			It("never ignores a dangling -@group: every other change fails, says how to recover, and changes nothing", func() {
				Expect(os.WriteFile(d.SessionConf(), []byte("x.example\n-@corp\n"), 0o600)).To(Succeed())
				rdsBefore, err := os.ReadFile(rds)
				Expect(err).NotTo(HaveOccurred())

				s := runEgress(append(confArgs("egress-reload"), "--session", "s1")...)
				Expect(s.ExitCode()).To(Equal(1))
				Expect(string(s.Err.Contents())).To(ContainSubstring("s1: " + hint("2")))
				Expect(string(s.Out.Contents())).NotTo(ContainSubstring("reloaded"))

				s = runEgress(append(confArgs("egress-strict"), "--", "off")...)
				Expect(s.ExitCode()).To(Equal(1))
				Expect(string(s.Err.Contents())).To(ContainSubstring("strict off was not applied: " + hint("2")))

				s = runEgress(append(confArgs("egress-allow"), "--", "y.example")...)
				Expect(s.ExitCode()).To(Equal(1))
				Expect(string(s.Err.Contents())).To(ContainSubstring("y.example was not applied: " + hint("2")))

				Expect(os.ReadFile(d.SessionConf())).To(Equal([]byte("x.example\n-@corp\n")))
				Expect(os.ReadFile(rds)).To(Equal(rdsBefore))
				Expect(d.Applied()).To(Equal([]policy.Entry{{Host: "old.example", Port: 443}}))
			})

			It("keeps today's error for a group that is unknown and not in the session", func() {
				Expect(os.WriteFile(d.SessionConf(), []byte("x.example\n"), 0o600)).To(Succeed())
				s := runEgress(append(confArgs("egress-deny"), "--", "@other")...)
				Expect(s.ExitCode()).To(Equal(1))
				Expect(string(s.Err.Contents())).To(ContainSubstring("@other was not applied: no group named @other (riotbox egress groups lists them)"))
				Expect(os.ReadFile(d.SessionConf())).To(Equal([]byte("x.example\n")))
			})

			It("drops one dangling group at a time, applying nothing until none is left", func() {
				Expect(os.WriteFile(d.SessionConf(), []byte("-@corp\n@gone\n"), 0o600)).To(Succeed())
				s := runEgress(append(confArgs("egress-deny"), "--", "@corp")...)
				Expect(s.ExitCode()).To(Equal(1))
				Expect(string(s.Out.Contents())).To(Equal("egress: s1: dropped @corp from the session (no group named @corp any more)\n"))
				Expect(string(s.Err.Contents())).To(ContainSubstring("the session's allowlist was not applied: " + d.SessionConf() + ":1: no group named @gone; run riotbox egress deny --session s1 @gone to drop it from the session"))
				Expect(os.ReadFile(d.SessionConf())).To(Equal([]byte("@gone\n")))
				Expect(d.Applied()).To(Equal([]policy.Entry{{Host: "old.example", Port: 443}}))

				s = runEgress(append(confArgs("egress-allow"), "--", "@gone")...)
				Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
				Expect(string(s.Out.Contents())).To(Equal("egress: s1: dropped @gone from the session (no group named @gone any more)\n"))
				Expect(os.ReadFile(d.SessionConf())).To(BeEmpty())
				Expect(d.Applied()).To(Equal([]policy.Entry{{Host: "kept.example", Port: 443}}))
			})

			It("fails closed, keeping the line, when a conf file cannot be read", func() {
				Expect(os.WriteFile(d.SessionConf(), []byte("-@corp\n"), 0o600)).To(Succeed())
				Expect(os.WriteFile(user, []byte("strict\n10.0.0.1\n"), 0o600)).To(Succeed())
				s := runEgress(append(confArgs("egress-deny"), "--", "@corp")...)
				Expect(s.ExitCode()).To(Equal(1))
				Expect(string(s.Err.Contents())).To(ContainSubstring("@corp was not applied: " + user + ":2:"))
				Expect(string(s.Out.Contents())).To(BeEmpty())
				Expect(os.ReadFile(d.SessionConf())).To(Equal([]byte("-@corp\n")))
				Expect(d.Applied()).To(Equal([]policy.Entry{{Host: "old.example", Port: 443}}))
			})
		})
	})

	Describe("egress-list", func() {
		It("says when no session runs", func() {
			s := runEgress("egress-list", "--engine", engine, "--state-root", root)
			Expect(s.ExitCode()).To(Equal(0))
			Expect(string(s.Out.Contents())).To(Equal("No egress sessions are running.\n"))
		})

		It("prints each running session's start, owner, projects, log and applied allowlist", func() {
			d := seed("s1", policy.Entry{Host: "a.example", Port: 443}, policy.Entry{Host: "b.example", Port: 8443})
			Expect(d.WriteConfig(policy.Resolved{Entries: []policy.Entry{{Host: "a.example", Port: 443}, {Host: "b.example", Port: 8443}}, Strict: true, StrictFrom: policy.SourceUser})).To(Succeed())
			Expect(d.WriteProjects([]string{"/home/u/b", "/home/u/a"})).To(Succeed())
			seed("s2")
			env = append(env, "TZ=UTC", "FAKE_GATEWAYS=["+
				`{"Names":["s1-egress"],"Labels":{"riotbox.egress":"s1","riotbox.egress-role":"gateway","riotbox.owner-pid":"42"},"StartedAt":1792811831},`+
				`{"Names":["s2-egress"],"Labels":{"riotbox.egress":"s2","riotbox.egress-role":"gateway","riotbox.owner-pid":"43"},"StartedAt":1792811900}]`)
			s := runEgress("egress-list", "--engine", engine, "--state-root", root)
			Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
			d2, err := state.Open(root, "s2")
			Expect(err).NotTo(HaveOccurred())
			Expect(string(s.Out.Contents())).To(Equal("s1\n" +
				"  started: 2026-10-24 03:17:11 UTC\n" +
				"  owner:   PID 42\n" +
				"  project: /home/u/b\n" +
				"  project: /home/u/a\n" +
				"  log:     " + d.AccessLog() + "\n" +
				"  strict:  on (user conf)\n" +
				"  allow:   a.example\n" +
				"  allow:   b.example:8443\n" +
				"s2\n" +
				"  started: 2026-10-24 03:18:20 UTC\n" +
				"  owner:   PID 43\n" +
				"  project: unknown\n" +
				"  log:     " + d2.AccessLog() + "\n" +
				"  strict:  off (default)\n"))
		})

		It("names each injected key's variable and host, never its value, between strict and allow", func() {
			d := seed("s1", policy.Entry{Host: "api.anthropic.com", Port: 443}).WithRuntime(filepath.Join(tmp, "run"))
			Expect(d.WriteInjection([]inject.Credential{
				{Env: "ANTHROPIC_API_KEY", Host: "api.anthropic.com", Header: "x-api-key", Value: "sk-s3cret"},
				{Env: "OPENAI_API_KEY", Host: "api.openai.com", Header: "authorization", Value: "Bearer sk-s3cret"},
			}, time.Now())).To(Succeed())
			env = append(env, gatewaysJSON("s1"))
			s := runEgress("egress-list", "--engine", engine, "--state-root", root)
			Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
			Expect(string(s.Out.Contents())).To(Equal("s1\n  started: unknown\n  owner:   unknown\n  project: unknown\n" +
				"  log:     " + d.AccessLog() + "\n  strict:  off (default)\n" +
				"  inject:  ANTHROPIC_API_KEY → api.anthropic.com\n" +
				"  inject:  OPENAI_API_KEY → api.openai.com\n" +
				"  allow:   api.anthropic.com\n"))
			Expect(string(s.Out.Contents())).NotTo(ContainSubstring("s3cret"))
		})

		It("shows inject unreadable, says why, and lists the session, when the injection record is corrupt", func() {
			d := seed("s1")
			Expect(os.WriteFile(filepath.Join(d.Path(), "injected"), []byte("K \x1b[31m x-api-key\n"), 0o600)).To(Succeed())
			env = append(env, gatewaysJSON("s1"))
			s := runEgress("egress-list", "--engine", engine, "--state-root", root)
			Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
			Expect(string(s.Out.Contents())).To(ContainSubstring("  strict:  off (default)\n  inject:  unreadable\n"))
			Expect(string(s.Out.Contents())).NotTo(ContainSubstring("\x1b"))
			Expect(string(s.Err.Contents())).To(ContainSubstring("riotbox-core: egress: s1: "))
			Expect(string(s.Err.Contents())).To(ContainSubstring("injected:1: not a variable, a host and a header"))
		})

		It("says unknown for what the engine does not report", func() {
			d := seed("s1")
			env = append(env, gatewaysJSON("s1"))
			s := runEgress("egress-list", "--engine", engine, "--state-root", root)
			Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
			Expect(string(s.Out.Contents())).To(Equal("s1\n  started: unknown\n  owner:   unknown\n  project: unknown\n  log:     " + d.AccessLog() + "\n  strict:  off (default)\n"))
		})

		It("quotes a project path holding a control character", func() {
			d := seed("s1")
			dir := "/p/\x1b[31mred"
			Expect(d.WriteProjects([]string{dir})).To(Succeed())
			env = append(env, gatewaysJSON("s1"))
			s := runEgress("egress-list", "--engine", engine, "--state-root", root)
			Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
			Expect(string(s.Out.Contents())).To(ContainSubstring("  project: " + display.Quote(dir) + "\n"))
			Expect(string(s.Out.Contents())).NotTo(ContainSubstring("\x1b"))
		})

		It("shows project unreadable, says why, and lists the other sessions, when a recorded project list is corrupt", func() {
			d := seed("s1")
			Expect(os.WriteFile(filepath.Join(d.Path(), "projects.json"), []byte("not json"), 0o600)).To(Succeed())
			seed("s2")
			env = append(env, gatewaysJSON("s1", "s2"))
			s := runEgress("egress-list", "--engine", engine, "--state-root", root)
			Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
			Expect(string(s.Out.Contents())).To(ContainSubstring("s1\n  started: unknown\n  owner:   unknown\n  project: unreadable\n"))
			Expect(string(s.Out.Contents())).To(ContainSubstring("s2\n  started: unknown\n  owner:   unknown\n  project: unknown\n"))
			Expect(string(s.Err.Contents())).To(ContainSubstring("riotbox-core: egress: s1: reading "))
			Expect(string(s.Err.Contents())).To(ContainSubstring("projects.json"))
		})

		It("says strict unknown for a session started before strict mode existed", func() {
			d := seed("s1")
			Expect(os.Remove(filepath.Join(d.Path(), "applied-strict"))).To(Succeed())
			env = append(env, gatewaysJSON("s1"))
			s := runEgress("egress-list", "--engine", engine, "--state-root", root)
			Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
			Expect(string(s.Out.Contents())).To(ContainSubstring("  strict:  unknown\n"))
		})

		DescribeTable("says strict unknown, not what the file holds, when the recorded setting is not one strict mode writes",
			func(recorded string) {
				d := seed("s1")
				Expect(os.WriteFile(filepath.Join(d.Path(), "applied-strict"), []byte(recorded), 0o600)).To(Succeed())
				env = append(env, gatewaysJSON("s1"))
				s := runEgress("egress-list", "--engine", engine, "--state-root", root)
				Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
				Expect(string(s.Out.Contents())).To(ContainSubstring("  strict:  unknown\n"))
				Expect(string(s.Out.Contents())).NotTo(ContainSubstring("\x1b"))
			},
			Entry("an unknown source", "on (agent)\n"),
			Entry("an unknown state", "maybe (default)\n"),
			Entry("trailing text", "on (default) extra\n"),
			Entry("two lines", "on (default)\noff (default)\n"),
			Entry("a control character", "\x1b[31mon (default)\n"),
		)
	})

	Describe("egress-reload", func() {
		It("re-reads the conf files into every running session when none is named", func() {
			d1, d2 := seed("s1"), seed("s2")
			Expect(os.MkdirAll(filepath.Dir(user), 0o700)).To(Succeed())
			Expect(os.WriteFile(user, []byte("new.example\n"), 0o600)).To(Succeed())
			env = append(env, gatewaysJSON("s1", "s2"))
			s := runEgress(confArgs("egress-reload")...)
			Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
			for _, d := range []state.Dir{d1, d2} {
				rds, err := os.ReadFile(filepath.Join(d.ConfigDir(), "rds.json"))
				Expect(err).NotTo(HaveOccurred())
				Expect(string(rds)).To(ContainSubstring(`"new.example:443"`))
			}
			Expect(string(s.Out.Contents())).To(ContainSubstring("egress: s1: reloaded"))
			Expect(string(s.Out.Contents())).To(ContainSubstring("egress: s2: reloaded"))
		})

		It("reloads the others and exits 1 when one session cannot be reloaded", func() {
			d1, d2 := seed("s1"), seed("s2")
			Expect(os.RemoveAll(d1.ConfigDir())).To(Succeed())
			env = append(env, gatewaysJSON("s1", "s2"))
			s := runEgress(confArgs("egress-reload")...)
			Expect(s.ExitCode()).To(Equal(1))
			Expect(string(s.Err.Contents())).To(ContainSubstring("s1: "))
			Expect(string(s.Out.Contents())).To(ContainSubstring("egress: s2: reloaded"))
			Expect(filepath.Join(d2.ConfigDir(), "rds.json")).To(BeAnExistingFile())
		})

		It("fails, without saying it reloaded, when the session stops during the command", func() {
			seed("s1")
			Expect(os.WriteFile(engine, []byte(vanishingEngineScript), 0o755)).To(Succeed())
			env = append(env, gatewaysJSON("s1"), "FAKE_PS_COUNT="+filepath.Join(tmp, "ps-count"))
			s := runEgress(confArgs("egress-reload")...)
			Expect(s.ExitCode()).To(Equal(1))
			Expect(string(s.Err.Contents())).To(ContainSubstring("no egress session named s1 is running"))
			Expect(string(s.Out.Contents())).NotTo(ContainSubstring("reloaded"))
		})

		It("refuses a named session that is not running", func() {
			s := runEgress(append(confArgs("egress-reload"), "--session", "gone")...)
			Expect(s.ExitCode()).To(Equal(1))
			Expect(string(s.Err.Contents())).To(ContainSubstring("no egress session named gone is running"))
		})
	})

	Describe("egress-strict", func() {
		BeforeEach(func() {
			Expect(os.WriteFile(filepath.Join(seed("s1").Path(), "agent.conf"), []byte("api.agent.example\n"), 0o600)).To(Succeed())
			env = append(env, gatewaysJSON("s1"))
		})

		It("turns strict mode on in the session, live, and warns that the agent's hosts are left out", func() {
			d, err := state.Open(root, "s1")
			Expect(err).NotTo(HaveOccurred())
			s := runEgress(append(confArgs("egress-strict"), "--", "on")...)
			Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
			Expect(string(s.Out.Contents())).To(Equal("egress: s1: strict on (session)\n"))
			Expect(string(s.Err.Contents())).To(ContainSubstring("WARNING: strict mode does not allow the agent's own API hosts (api.agent.example); add @agent\n"))
			Expect(os.ReadFile(d.SessionConf())).To(Equal([]byte("strict = on\n")))
			Expect(d.Applied()).To(BeEmpty())
			Expect(d.AppliedStrict()).To(Equal("on (session)"))
		})

		It("does not warn when the session still allows @agent", func() {
			Expect(os.MkdirAll(filepath.Dir(user), 0o700)).To(Succeed())
			Expect(os.WriteFile(user, []byte("@agent\n"), 0o600)).To(Succeed())
			s := runEgress(append(confArgs("egress-strict"), "--", "on")...)
			Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
			Expect(string(s.Err.Contents())).NotTo(ContainSubstring("WARNING"))
		})

		It("turns it off, then clears the session's choice so the conf files decide", func() {
			Expect(os.MkdirAll(filepath.Dir(user), 0o700)).To(Succeed())
			Expect(os.WriteFile(user, []byte("strict\n"), 0o600)).To(Succeed())
			s := runEgress(append(confArgs("egress-strict"), "--", "off")...)
			Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
			Expect(string(s.Out.Contents())).To(Equal("egress: s1: strict off (session)\n"))
			Expect(string(s.Err.Contents())).NotTo(ContainSubstring("WARNING"))
			s = runEgress(append(confArgs("egress-strict"), "--", "clear")...)
			Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
			Expect(string(s.Out.Contents())).To(Equal("egress: s1: strict on (user conf)\n"))
		})

		It("saves the setting to the conf file, replacing it, and removes it on clear", func() {
			s := runEgress(append(confArgs("egress-strict"), "--save-to", user, "--", "on")...)
			Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
			Expect(string(s.Out.Contents())).To(HaveSuffix("egress: saved strict = on to " + user + "\n"))
			Expect(os.ReadFile(user)).To(Equal([]byte("strict = on\n")))
			s = runEgress(append(confArgs("egress-strict"), "--save-to", user, "--", "off")...)
			Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
			Expect(os.ReadFile(user)).To(Equal([]byte("strict = off\n")))
			s = runEgress(append(confArgs("egress-strict"), "--save-to", user, "--", "clear")...)
			Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
			Expect(string(s.Out.Contents())).To(HaveSuffix("egress: removed the strict setting from " + user + "\n"))
			Expect(os.ReadFile(user)).To(BeEmpty())
			s = runEgress(append(confArgs("egress-strict"), "--save-to", user, "--", "clear")...)
			Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
			Expect(string(s.Out.Contents())).To(HaveSuffix("egress: " + user + " has no strict setting\n"))
		})

		It("is a usage error for anything but on, off or clear, or an empty --session", func() {
			for _, arg := range []string{"enable", "ON", ""} {
				s := runEgress(append(confArgs("egress-strict"), "--", arg)...)
				Expect(s.ExitCode()).To(Equal(2), arg)
			}
			s := runEgress(confArgs("egress-strict")...)
			Expect(s.ExitCode()).To(Equal(2))
			s = runEgress(append(confArgs("egress-strict"), "--session", "", "--", "on")...)
			Expect(s.ExitCode()).To(Equal(2))
		})

		It("warns when clearing the session's choice leaves the conf files' strict mode without @agent", func() {
			Expect(os.MkdirAll(filepath.Dir(user), 0o700)).To(Succeed())
			Expect(os.WriteFile(user, []byte("strict\n"), 0o600)).To(Succeed())
			s := runEgress(append(confArgs("egress-strict"), "--", "off")...)
			Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
			s = runEgress(append(confArgs("egress-strict"), "--", "clear")...)
			Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
			Expect(string(s.Out.Contents())).To(Equal("egress: s1: strict on (user conf)\n"))
			Expect(string(s.Err.Contents())).To(ContainSubstring("WARNING: strict mode does not allow the agent's own API hosts (api.agent.example); add @agent\n"))
		})

		It("is a usage error with more than one positional", func() {
			s := runEgress(append(confArgs("egress-strict"), "--", "on", "off")...)
			Expect(s.ExitCode()).To(Equal(2))
		})

		It("puts session.conf back as it was when the engine fails after the change was applied", func() {
			d, err := state.Open(root, "s1")
			Expect(err).NotTo(HaveOccurred())
			overlay := []byte("-a.example\nb.example\n")
			Expect(os.WriteFile(d.SessionConf(), overlay, 0o600)).To(Succeed())
			Expect(os.WriteFile(engine, []byte(failingPSEngineScript), 0o755)).To(Succeed())
			env = append(env, "FAKE_PS_COUNT="+filepath.Join(tmp, "ps-count"))
			s := runEgress(append(confArgs("egress-strict"), "--", "on")...)
			Expect(s.ExitCode()).To(Equal(1))
			Expect(string(s.Err.Contents())).To(ContainSubstring("strict on was not applied: could not check that s1 is still running"))
			Expect(string(s.Err.Contents())).NotTo(ContainSubstring("WARNING"))
			Expect(string(s.Out.Contents())).To(BeEmpty())
			Expect(os.ReadFile(d.SessionConf())).To(Equal(overlay))
			Expect(d.AppliedStrict()).To(Equal("off (default)"))
		})

		It("changes nothing when a conf file is broken", func() {
			Expect(os.MkdirAll(filepath.Dir(user), 0o700)).To(Succeed())
			Expect(os.WriteFile(user, []byte("[bogus]\n"), 0o600)).To(Succeed())
			s := runEgress(append(confArgs("egress-strict"), "--", "on")...)
			Expect(s.ExitCode()).To(Equal(1))
			Expect(string(s.Err.Contents())).To(ContainSubstring("strict on was not applied: " + user + `:1: unknown section "[bogus]"`))
			d, err := state.Open(root, "s1")
			Expect(err).NotTo(HaveOccurred())
			Expect(d.SessionConf()).NotTo(BeAnExistingFile())
		})

		It("neither applies nor saves when the conf file to save to is broken", func() {
			Expect(os.MkdirAll(filepath.Dir(user), 0o700)).To(Succeed())
			Expect(os.WriteFile(user, []byte("@nosuch\n"), 0o600)).To(Succeed())
			s := runEgress(append(confArgs("egress-strict"), "--save-to", user, "--", "on")...)
			Expect(s.ExitCode()).To(Equal(1))
			Expect(string(s.Err.Contents())).To(ContainSubstring("strict on was not applied: " + user + ":1: no group named @nosuch"))
			Expect(string(s.Out.Contents())).To(BeEmpty())
			Expect(os.ReadFile(user)).To(Equal([]byte("@nosuch\n")))
			d, err := state.Open(root, "s1")
			Expect(err).NotTo(HaveOccurred())
			Expect(d.SessionConf()).NotTo(BeAnExistingFile())
		})
	})

	Describe("egress-groups", func() {
		groupsArgs := func() []string { return confArgs("egress-groups") }

		It("lists every group with its source and hosts, and @agent as per session when none runs", func() {
			Expect(os.WriteFile(sys, []byte("[group corp]\ncorp.sys.example\n"), 0o600)).To(Succeed())
			Expect(os.MkdirAll(filepath.Dir(user), 0o700)).To(Succeed())
			Expect(os.WriteFile(user, []byte("[group pypi]\npypi.corp.example\n"), 0o600)).To(Succeed())
			s := runEgress(groupsArgs()...)
			Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
			out := string(s.Out.Contents())
			Expect(out).To(HavePrefix("@agent (per session)\n@centos (built-in)\n"))
			Expect(out).To(ContainSubstring("@corp (system conf)\n  corp.sys.example\n"))
			Expect(out).To(ContainSubstring("@pypi (user conf)\n  pypi.corp.example\n@registries (built-in)\n"))
			Expect(out).To(ContainSubstring("@npm (built-in)\n  registry.npmjs.org\n"))
		})

		It("shows a user's redefinition of a built-in group as the user's alone", func() {
			Expect(os.MkdirAll(filepath.Dir(user), 0o700)).To(Succeed())
			Expect(os.WriteFile(user, []byte("[group npm]\nnpm.corp.example\n"), 0o600)).To(Succeed())
			s := runEgress(groupsArgs()...)
			Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
			out := string(s.Out.Contents())
			Expect(out).To(ContainSubstring("@npm (user conf)\n  npm.corp.example\n@"))
			Expect(out).NotTo(ContainSubstring("@npm (built-in)"))
			Expect(out).NotTo(ContainSubstring("registry.npmjs.org"))
		})

		It("lists a session's agent hosts sorted and each once", func() {
			d := seed("s1")
			Expect(os.WriteFile(d.AgentConf(), []byte("z.agent.example\na.agent.example\nz.agent.example\n"), 0o600)).To(Succeed())
			env = append(env, gatewaysJSON("s1"))
			s := runEgress(groupsArgs()...)
			Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
			Expect(string(s.Out.Contents())).To(HavePrefix("@agent (s1)\n  a.agent.example\n  z.agent.example\n@centos (built-in)\n"))
		})

		It("lists @agent once per running session, with that session's agent hosts", func() {
			d1, d2 := seed("s1"), seed("s2")
			Expect(os.WriteFile(d1.AgentConf(), []byte("api.one.example\n"), 0o600)).To(Succeed())
			Expect(os.WriteFile(d2.AgentConf(), []byte("api.two.example\n"), 0o600)).To(Succeed())
			env = append(env, gatewaysJSON("s1", "s2"))
			s := runEgress(groupsArgs()...)
			Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
			Expect(string(s.Out.Contents())).To(HavePrefix("@agent (s1)\n  api.one.example\n@agent (s2)\n  api.two.example\n@centos (built-in)\n"))
		})

		It("lists the other sessions, and says why, when one session's agent hosts cannot be read", func() {
			d1, d2 := seed("s1"), seed("s2")
			Expect(os.Mkdir(d1.AgentConf(), 0o700)).To(Succeed())
			Expect(os.WriteFile(d2.AgentConf(), []byte("api.two.example\n"), 0o600)).To(Succeed())
			env = append(env, gatewaysJSON("s1", "s2"))
			s := runEgress(groupsArgs()...)
			Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
			Expect(string(s.Out.Contents())).To(HavePrefix("@agent (s1)\n  (unreadable)\n@agent (s2)\n  api.two.example\n@centos (built-in)\n"))
			Expect(string(s.Err.Contents())).To(ContainSubstring("riotbox-core: egress: s1: cannot read " + display.Quote(d1.AgentConf()) + ": is a directory\n"))
		})

		It("fails, naming the file and line, when a conf file is broken", func() {
			Expect(os.MkdirAll(filepath.Dir(user), 0o700)).To(Succeed())
			Expect(os.WriteFile(user, []byte("@nosuch\n"), 0o600)).To(Succeed())
			s := runEgress(groupsArgs()...)
			Expect(s.ExitCode()).To(Equal(1))
			Expect(string(s.Err.Contents())).To(ContainSubstring(user + ":1: no group named @nosuch"))
			Expect(string(s.Out.Contents())).To(BeEmpty())
		})

		It("is a usage error with a positional or a --session", func() {
			s := runEgress(append(groupsArgs(), "--", "x")...)
			Expect(s.ExitCode()).To(Equal(2))
			s = runEgress(append(confArgs("egress-groups"), "--session", "s1")...)
			Expect(s.ExitCode()).To(Equal(2))
		})
	})

	Describe("egress-down and egress-sweep", func() {
		It("tears down a session that never fully started without complaint", func() {
			s := runEgress("egress-down", "--engine", engine, "--state-root", root, "--", "s1")
			Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
			calls, err := os.ReadFile(log)
			Expect(err).NotTo(HaveOccurred())
			Expect(string(calls)).To(HavePrefix("stop --ignore --time 10 s1-egress\npod rm --force --ignore s1-pod\n"))
		})

		It("sweeps with nothing to do", func() {
			s := runEgress("egress-sweep", "--engine", engine, "--state-root", root)
			Expect(s.ExitCode()).To(Equal(0), string(s.Err.Contents()))
		})
	})
})
