package pod_test

import (
	"bytes"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/trevor-vaughan/claude-riotbox/internal/egress/inject"
	"github.com/trevor-vaughan/claude-riotbox/internal/egress/pod"
	"github.com/trevor-vaughan/claude-riotbox/internal/egress/policy"
	"github.com/trevor-vaughan/claude-riotbox/internal/egress/state"
)

const image = "registry.example/envoy@sha256:abc"

// networksFormat is the inspect format Up reads the proxy's addresses with.
const networksFormat = "{{json .NetworkSettings.Networks}}"

// proxyNetworks is how podman 6 reports the networks of session s1's proxy.
const proxyNetworks = `{"s1-ext":{"Gateway":"10.89.1.1","IPAddress":"10.89.1.2","GlobalIPv6Address":""},` +
	`"s1-int":{"Gateway":"","IPAddress":"10.89.0.1","GlobalIPv6Address":""}}`

// healthy answers like an engine whose proxy starts: `run -d` makes Envoy
// log its readiness line, and inspect says the proxy runs and has the
// addresses in proxyNetworks.
func healthy(dir state.Dir) func([]string) ([]byte, error) {
	return func(args []string) ([]byte, error) {
		switch {
		case args[0] == "run":
			return []byte("0123abcd\n"), appendFile(dir.EnvoyLog(), "[info] all dependencies initialized. starting workers\n")
		case args[0] == "container" && args[1] == "inspect" && args[3] == networksFormat:
			return []byte(proxyNetworks + "\n"), nil
		case args[0] == "container" && args[1] == "inspect":
			return []byte("true\n"), nil
		}
		return nil, nil
	}
}

var _ = Describe("Manager", func() {
	var (
		root   string
		dir    state.Dir
		engine *fakeEngine
		stderr *bytes.Buffer
		m      pod.Manager
		req    pod.UpRequest
	)

	BeforeEach(func() {
		root = filepath.Join(GinkgoT().TempDir(), "riotbox-egress")
		var err error
		dir, err = state.Open(root, "s1")
		Expect(err).NotTo(HaveOccurred())
		dir = dir.WithRuntime(filepath.Join(GinkgoT().TempDir(), "riotbox-egress"))
		engine = &fakeEngine{}
		stderr = &bytes.Buffer{}
		m = pod.Manager{Engine: engine, Stderr: stderr, ReadyTimeout: time.Second, PollInterval: time.Millisecond}
		core := filepath.Join(GinkgoT().TempDir(), "riotbox-core")
		Expect(os.WriteFile(core, []byte("core-binary"), 0o755)).To(Succeed())
		req = pod.UpRequest{
			Dir: dir, SessionKey: "key1", OwnerPID: 42, Image: image, Core: core,
			AgentHosts: []byte("api.agent.example\n"), Projects: []string{"/home/u/proj"},
			SystemConf: filepath.Join(root, "none-sys"), UserConf: filepath.Join(root, "none-user"),
		}
	})

	Describe("Up", func() {
		It("records the session's own egress.conf, which then decides the allowlist", func() {
			own := filepath.Join(GinkgoT().TempDir(), "own.conf")
			Expect(os.WriteFile(own, []byte("own.example\n"), 0o600)).To(Succeed())
			req.OwnConf = own
			engine.respond = healthy(dir)
			_, err := m.Up(req)
			Expect(err).NotTo(HaveOccurred())
			Expect(dir.OwnConf()).To(Equal(own))
			Expect(dir.Applied()).To(ContainElement(policy.Entry{Host: "own.example", Port: 443}))
		})

		It("clears an earlier launch's own egress.conf from a reused state dir", func() {
			Expect(dir.Create()).To(Succeed())
			Expect(dir.WriteOwnConf("/earlier/own.conf")).To(Succeed())
			engine.respond = healthy(dir)
			_, err := m.Up(req)
			Expect(err).NotTo(HaveOccurred())
			Expect(dir.OwnConf()).To(BeEmpty())
		})

		It("saves the OS plugins' groups as os.conf before the proxy starts", func() {
			osDir := GinkgoT().TempDir()
			Expect(os.MkdirAll(filepath.Join(osDir, "fedora"), 0o755)).To(Succeed())
			Expect(os.WriteFile(filepath.Join(osDir, "fedora", "egress-hosts"), []byte("dl.fedoraproject.org\n"), 0o644)).To(Succeed())
			req.OSDir = osDir
			engine.respond = healthy(dir)
			_, err := m.Up(req)
			Expect(err).NotTo(HaveOccurred())
			Expect(os.ReadFile(dir.OSConf())).To(Equal([]byte("[group fedora]\ndl.fedoraproject.org\n")))
		})

		It("refuses a broken OS plugin before creating anything", func() {
			osDir := GinkgoT().TempDir()
			Expect(os.MkdirAll(filepath.Join(osDir, "fedora"), 0o755)).To(Succeed())
			Expect(os.WriteFile(filepath.Join(osDir, "fedora", "manifest.sh"), nil, 0o644)).To(Succeed())
			req.OSDir = osDir
			_, err := m.Up(req)
			Expect(err).To(MatchError(ContainSubstring("an OS plugin needs egress-hosts")))
			Expect(engine.lines()).To(BeEmpty())
			Expect(dir.Path()).NotTo(BeADirectory())
		})

		It("creates the networks and the proxy in order, and returns the agent's flags", func() {
			engine.respond = healthy(dir)
			flags, err := m.Up(req)
			Expect(err).NotTo(HaveOccurred())

			labels := fmt.Sprintf("--label riotbox.egress=s1 --label riotbox.session=key1 --label riotbox.owner-pid=42 --label riotbox.owner-pidns=%s", pod.PIDNamespace())
			lines := engine.lines()
			Expect(lines[0]).To(Equal("image exists " + image))
			Expect(lines[1]).To(Equal("network create --internal --disable-dns " + labels + " s1-int"))
			Expect(lines[2]).To(Equal("network create " + labels + " s1-ext"))
			// No pod: podman before 6.0 refuses --userns on a pod's member.
			Expect(lines[3]).To(HavePrefix("run -d --name s1-egress " + labels + " --label riotbox.egress-role=gateway"))
			Expect(lines[3]).To(ContainSubstring(fmt.Sprintf(" --network s1-int,s1-ext --userns=keep-id --user %d:%d --read-only --cap-drop=ALL --security-opt no-new-privileges --ulimit core=0 --log-driver=none ", os.Getuid(), os.Getgid())))
			Expect(lines[3]).To(ContainSubstring(" -v " + dir.ConfigDir() + ":/etc/riotbox-egress:ro,z "))
			Expect(lines[3]).To(ContainSubstring(" -v " + dir.LogDir() + ":/var/log/riotbox-egress:rw,z "))
			Expect(lines[3]).To(ContainSubstring(" -v " + dir.HostlinkDir() + ":/run/riotbox-hostlink:ro,z "))
			Expect(lines[3]).To(HaveSuffix(" --entrypoint /usr/local/bin/envoy " + image + " -c /etc/riotbox-egress/bootstrap.json --log-path /var/log/riotbox-egress/envoy.log --file-flush-interval-msec 1000"))

			Expect(lines[len(lines)-1]).To(Equal("container inspect --format " + networksFormat + " s1-egress"))

			proxy := "http://s1-egress:3128"
			Expect(flags).To(Equal([]string{
				"--network", "s1-int", "--cap-drop=NET_ADMIN,NET_RAW",
				"--dns", "none", "--add-host", "s1-egress:10.89.0.1",
				"-e", "HTTP_PROXY=" + proxy, "-e", "HTTPS_PROXY=" + proxy,
				"-e", "http_proxy=" + proxy, "-e", "https_proxy=" + proxy,
				"-e", "NO_PROXY=localhost,127.0.0.1", "-e", "no_proxy=localhost,127.0.0.1",
				"-e", "RIOTBOX_EGRESS_SESSION=s1",
			}))
			Expect(stderr.String()).NotTo(ContainSubstring("WARNING"))
		})

		It("saves the agent's hosts and writes Envoy's config including them", func() {
			engine.respond = healthy(dir)
			_, err := m.Up(req)
			Expect(err).NotTo(HaveOccurred())
			Expect(os.ReadFile(dir.AgentConf())).To(Equal([]byte("api.agent.example\n")))
			Expect(dir.Projects()).To(Equal([]string{"/home/u/proj"}))
			rds, err := os.ReadFile(filepath.Join(dir.ConfigDir(), "rds.json"))
			Expect(err).NotTo(HaveOccurred())
			Expect(string(rds)).To(ContainSubstring(`"api.agent.example:443"`))
			Expect(filepath.Join(dir.ConfigDir(), "bootstrap.json")).To(BeARegularFile())
		})

		It("warns, and still starts, when strict mode leaves out the agent's hosts", func() {
			engine.respond = healthy(dir)
			req.UserConf = filepath.Join(GinkgoT().TempDir(), "user.conf")
			Expect(os.WriteFile(req.UserConf, []byte("strict\n"), 0o600)).To(Succeed())
			flags, err := m.Up(req)
			Expect(err).NotTo(HaveOccurred())
			Expect(flags).To(ContainElement("RIOTBOX_EGRESS_SESSION=s1"))
			Expect(stderr.String()).To(ContainSubstring("WARNING: strict mode does not allow the agent's own API hosts (api.agent.example); add @agent\n"))
		})

		It("does not warn when strict mode allows @agent", func() {
			engine.respond = healthy(dir)
			req.UserConf = filepath.Join(GinkgoT().TempDir(), "user.conf")
			Expect(os.WriteFile(req.UserConf, []byte("strict\n@agent\n"), 0o600)).To(Succeed())
			_, err := m.Up(req)
			Expect(err).NotTo(HaveOccurred())
			Expect(stderr.String()).NotTo(ContainSubstring("WARNING"))
		})

		It("refuses a broken conf file, naming its line, before touching the engine", func() {
			req.UserConf = filepath.Join(GinkgoT().TempDir(), "user.conf")
			Expect(os.WriteFile(req.UserConf, []byte("[bogus]\n"), 0o600)).To(Succeed())
			_, err := m.Up(req)
			Expect(err).To(MatchError(HavePrefix(req.UserConf + `:1: unknown section "[bogus]"`)))
			Expect(engine.calls).To(BeEmpty())
		})

		It("pulls the image when it is not present, saying so", func() {
			base := healthy(dir)
			engine.respond = func(args []string) ([]byte, error) {
				if args[0] == "image" {
					return []byte("absent"), nil
				}
				return base(args)
			}
			_, err := m.Up(req)
			Expect(err).NotTo(HaveOccurred())
			Expect(engine.index("pull " + image)).To(Equal(1))
			Expect(stderr.String()).To(ContainSubstring("egress: pulling " + image))
		})

		It("creates nothing on the engine when the pull fails", func() {
			engine.respond = func(args []string) ([]byte, error) {
				switch args[0] {
				case "image":
					return []byte("absent"), nil
				case "pull":
					return nil, errors.New("pull: unauthorized")
				}
				return nil, nil
			}
			_, err := m.Up(req)
			Expect(err).To(MatchError(ContainSubstring("pulling the egress proxy image")))
			Expect(engine.index("network create")).To(Equal(-1))
		})

		It("refuses an invalid agent host before touching the engine", func() {
			req.AgentHosts = []byte("10.0.0.1\n")
			_, err := m.Up(req)
			Expect(err).To(MatchError(ContainSubstring(dir.AgentConf() + ":1: invalid egress entry")))
			Expect(engine.calls).To(BeEmpty())
		})

		It("tears down what it created when a step fails", func() {
			engine.respond = func(args []string) ([]byte, error) {
				if args[0] == "network" && args[1] == "create" && args[len(args)-1] == "s1-ext" {
					return nil, errors.New("network create: boom")
				}
				return nil, nil
			}
			_, err := m.Up(req)
			Expect(err).To(MatchError(ContainSubstring("network create: boom")))
			Expect(engine.index("run -d")).To(Equal(-1))
			Expect(engine.index("stop --ignore --time 10 s1-egress")).To(BeNumerically(">", 0))
			Expect(engine.index("rm --force --ignore s1 s1-egress")).To(BeNumerically(">", 0))
			Expect(engine.index("network rm s1-int")).To(BeNumerically(">", 0))
			Expect(engine.index("network rm s1-ext")).To(BeNumerically(">", 0))
		})

		It("fails fast, showing the end of Envoy's log, when the proxy exits during startup", func() {
			engine.respond = func(args []string) ([]byte, error) {
				switch args[0] {
				case "run":
					var b strings.Builder
					for i := 1; i <= 25; i++ {
						fmt.Fprintf(&b, "line %d\n", i)
					}
					b.WriteString("evil \x1b]0;pwned\x07 end\n")
					return nil, appendFile(dir.EnvoyLog(), b.String())
				case "container":
					return []byte("false\n"), nil
				}
				return nil, nil
			}
			_, err := m.Up(req)
			Expect(err).To(MatchError(ContainSubstring("the egress proxy exited during startup")))
			Expect(stderr.String()).To(ContainSubstring("  line 25\n"))
			Expect(stderr.String()).NotTo(ContainSubstring("  line 6\n"))
			Expect(stderr.String()).To(ContainSubstring("  line 7\n"))
			Expect(stderr.String()).To(ContainSubstring("  evil ?]0;pwned? end\n"))
			Expect(stderr.String()).NotTo(ContainSubstring("\x1b"))
			Expect(engine.index("rm --force --ignore s1 s1-egress")).To(BeNumerically(">", 0))
		})

		It("gives up after ReadyTimeout when Envoy never reports ready", func() {
			m.ReadyTimeout = 20 * time.Millisecond
			engine.respond = func(args []string) ([]byte, error) {
				if args[0] == "container" {
					return []byte("true\n"), nil
				}
				return nil, nil
			}
			_, err := m.Up(req)
			Expect(err).To(MatchError(ContainSubstring("the egress proxy was not ready after 20ms")))
			Expect(engine.index("rm --force --ignore s1 s1-egress")).To(BeNumerically(">", 0))
		})

		It("does not take a stale ready line or stale denials from a reused session dir", func() {
			Expect(dir.Create()).To(Succeed())
			Expect(os.WriteFile(dir.EnvoyLog(), []byte("[info] all dependencies initialized. starting workers\n"), 0o600)).To(Succeed())
			Expect(os.WriteFile(dir.AccessLog(), []byte(`{"status":403}`+"\n"), 0o600)).To(Succeed())
			m.ReadyTimeout = 20 * time.Millisecond
			engine.respond = func(args []string) ([]byte, error) {
				if args[0] == "container" {
					return []byte("true\n"), nil
				}
				return nil, nil
			}
			_, err := m.Up(req)
			Expect(err).To(MatchError(ContainSubstring("was not ready")))
			Expect(m.Down(dir, true)).To(Succeed())
			Expect(stderr.String()).NotTo(ContainSubstring("denied request"))
		})

		It("removes the previous run's logs before starting the proxy", func() {
			Expect(dir.Create()).To(Succeed())
			Expect(os.WriteFile(dir.EnvoyLog(), []byte("old\n"), 0o600)).To(Succeed())
			Expect(os.WriteFile(dir.AccessLog(), []byte("old\n"), 0o600)).To(Succeed())
			base := healthy(dir)
			var envoyGone, accessGone bool
			engine.respond = func(args []string) ([]byte, error) {
				if args[0] == "run" {
					_, e1 := os.Lstat(dir.EnvoyLog())
					_, e2 := os.Lstat(dir.AccessLog())
					envoyGone, accessGone = os.IsNotExist(e1), os.IsNotExist(e2)
				}
				return base(args)
			}
			_, err := m.Up(req)
			Expect(err).NotTo(HaveOccurred())
			Expect(envoyGone).To(BeTrue())
			Expect(accessGone).To(BeTrue())
		})

		DescribeTable("refuses an image that podman would read as a flag or split",
			func(bad string) {
				req.Image = bad
				_, err := m.Up(req)
				Expect(err).To(MatchError(ContainSubstring("invalid egress proxy image")))
				Expect(engine.calls).To(BeEmpty())
			},
			Entry("empty", ""),
			Entry("leading dash", "--privileged"),
			Entry("whitespace", "img with space"),
		)

		DescribeTable("refuses a state path that would corrupt the -v argument",
			func(sep string) {
				bad, err := state.Open(filepath.Join(root, "a"+sep+"b"), "s1")
				Expect(err).NotTo(HaveOccurred())
				req.Dir = bad
				_, err = m.Up(req)
				Expect(err).To(MatchError(ContainSubstring(bad.ConfigDir())))
				Expect(engine.calls).To(BeEmpty())
			},
			Entry("colon", ":"),
			Entry("comma", ","),
		)

		It("returns the inspect error and rolls back when the engine cannot inspect the proxy", func() {
			engine.respond = func(args []string) ([]byte, error) {
				if args[0] == "container" {
					return nil, errors.New("inspect: boom")
				}
				return nil, nil
			}
			_, err := m.Up(req)
			Expect(err).To(MatchError(ContainSubstring("inspect: boom")))
			Expect(engine.index("rm --force --ignore s1 s1-egress")).To(BeNumerically(">", 0))
		})

		It("maps the proxy's name to its IPv6 address when it has no IPv4 one", func() {
			base := healthy(dir)
			engine.respond = func(args []string) ([]byte, error) {
				if args[0] == "container" && args[3] == networksFormat {
					return []byte(`{"s1-int":{"IPAddress":"","GlobalIPv6Address":"fd00:0:0::5"}}`), nil
				}
				return base(args)
			}
			flags, err := m.Up(req)
			Expect(err).NotTo(HaveOccurred())
			Expect(flags).To(ContainElements("--add-host", "s1-egress:fd00::5"))
		})

		DescribeTable("refuses, and rolls back, a proxy address that is not an IP literal",
			func(networks, want string) {
				base := healthy(dir)
				engine.respond = func(args []string) ([]byte, error) {
					if args[0] == "container" && args[3] == networksFormat {
						return []byte(networks), nil
					}
					return base(args)
				}
				flags, err := m.Up(req)
				Expect(err).To(MatchError(ContainSubstring(want)))
				Expect(flags).To(BeNil())
				Expect(engine.index("rm --force --ignore s1 s1-egress")).To(BeNumerically(">", 0))
			},
			Entry("not on the internal network", `{"s1-ext":{"IPAddress":"10.89.1.2"}}`, "has no address on s1-int"),
			Entry("no address", `{"s1-int":{"IPAddress":"","GlobalIPv6Address":""}}`, "has no address on s1-int"),
			Entry("a flag", `{"s1-int":{"IPAddress":"--privileged"}}`, `is not an IP address: "--privileged"`),
			Entry("an address and more", `{"s1-int":{"IPAddress":"10.89.0.1 --privileged"}}`, "is not an IP address"),
			Entry("a host name", `{"s1-int":{"IPAddress":"evil.example"}}`, "is not an IP address"),
			Entry("not JSON", `true`, "reading the egress proxy's networks"),
		)

		It("returns the inspect error and rolls back when the proxy's networks cannot be read", func() {
			base := healthy(dir)
			engine.respond = func(args []string) ([]byte, error) {
				if args[0] == "container" && args[3] == networksFormat {
					return nil, errors.New("inspect: gone")
				}
				return base(args)
			}
			_, err := m.Up(req)
			Expect(err).To(MatchError(ContainSubstring("inspect: gone")))
			Expect(engine.index("rm --force --ignore s1 s1-egress")).To(BeNumerically(">", 0))
		})

		It("returns both the cause and the teardown failure when rollback also fails", func() {
			engine.respond = func(args []string) ([]byte, error) {
				switch args[0] {
				case "run":
					return nil, errors.New("run: boom")
				case "stop":
					return nil, errors.New("stop: wedged")
				}
				return nil, nil
			}
			_, err := m.Up(req)
			Expect(err).To(MatchError(ContainSubstring("run: boom")))
			Expect(err).To(MatchError(ContainSubstring("stop: wedged")))
		})

		Describe("reaching the host's loopback", func() {
			// withPasta answers `info` with pasta and, when the sidecar
			// starts, opens its socket, as the relay does.
			withPasta := func() {
				base := healthy(dir)
				engine.respond = func(args []string) ([]byte, error) {
					switch {
					case args[0] == "info":
						return []byte("pasta\n"), nil
					case args[0] == "run" && slices.Contains(args, "s1-hostlink"):
						l, err := net.Listen("unix", dir.HostlinkSocket())
						Expect(err).NotTo(HaveOccurred())
						DeferCleanup(l.Close)
						return []byte("0123abcd\n"), nil
					}
					return base(args)
				}
			}

			// The sidecar starts only for a launch whose allowlist names
			// the host.
			BeforeEach(func() {
				req.AgentHosts = []byte("api.agent.example\nhost.containers.internal:2222\n")
			})

			It("on pasta, starts no sidecar, copies no riotbox-core and mounts nothing new when the allowlist does not name the host", func() {
				req.AgentHosts = []byte("api.agent.example\n*.containers.internal:2222\n")
				withPasta()
				flags, err := m.Up(req)
				Expect(err).NotTo(HaveOccurred())
				Expect(engine.lines()).NotTo(ContainElement(ContainSubstring("s1-hostlink")))
				Expect(engine.lines()).NotTo(ContainElement(HavePrefix("info ")))
				Expect(strings.Join(flags, " ")).NotTo(ContainSubstring("riotbox-egress-share"))
				Expect(dir.Core()).NotTo(BeAnExistingFile())
				Expect(stderr.String()).NotTo(ContainSubstring("WARNING"))
			})

			It("refuses an empty riotbox-core path before creating any engine object", func() {
				req.Core = ""
				withPasta()
				_, err := m.Up(req)
				Expect(err).To(MatchError(ContainSubstring("no riotbox-core")))
				Expect(engine.lines()).NotTo(ContainElement(HavePrefix("network create")))
				Expect(engine.lines()).NotTo(ContainElement(HavePrefix("run ")))
			})

			It("creates no engine object, and removes the secrets, when riotbox-core cannot be copied", func() {
				req.Core = filepath.Join(GinkgoT().TempDir(), "missing")
				req.Credentials = []inject.Credential{{Env: "ANTHROPIC_API_KEY", Host: "api.anthropic.com", Header: "x-api-key", Value: "sk-ant-for-core-spec"}}
				withPasta()
				_, err := m.Up(req)
				Expect(err).To(MatchError(ContainSubstring("copying riotbox-core for the hostlink relay")))
				Expect(engine.lines()).NotTo(ContainElement(HavePrefix("network create")))
				Expect(engine.lines()).NotTo(ContainElement(HavePrefix("run ")))
				Expect(dir.SecretsDir()).NotTo(BeAnExistingFile())
			})

			It("removes the sidecar when the proxy fails to start after it", func() {
				withPasta()
				pasta := engine.respond
				engine.respond = func(args []string) ([]byte, error) {
					if args[0] == "run" && slices.Contains(args, "s1-egress") {
						return nil, errors.New("run: boom")
					}
					return pasta(args)
				}
				_, err := m.Up(req)
				Expect(err).To(MatchError(ContainSubstring("run: boom")))
				Expect(engine.lines()).To(ContainElement(HavePrefix("run -d --name s1-hostlink ")))
				Expect(engine.lines()).To(ContainElement("rm --force --ignore s1 s1-egress s1-hostlink"))
			})

			It("starts the relay sidecar on pasta alone, after the networks and before the proxy, and gives the agent the share dir", func() {
				withPasta()
				flags, err := m.Up(req)
				Expect(err).NotTo(HaveOccurred())
				labels := fmt.Sprintf("--label riotbox.egress=s1 --label riotbox.session=key1 --label riotbox.owner-pid=42 --label riotbox.owner-pidns=%s", pod.PIDNamespace())
				lines := engine.lines()
				Expect(lines[2]).To(HavePrefix("network create --internal"))
				Expect(lines[3]).To(HavePrefix("network create "))
				Expect(lines[4]).To(Equal("run -d --name s1-hostlink " + labels + " --label riotbox.egress-role=hostlink" +
					" --network pasta:--map-host-loopback,169.254.1.2" +
					fmt.Sprintf(" --userns=keep-id --user %d:%d", os.Getuid(), os.Getgid()) +
					" --read-only --cap-drop=ALL --security-opt no-new-privileges --ulimit core=0 --log-driver=none" +
					" -v " + dir.ShareDir() + ":/run/riotbox-egress-share:ro,z" +
					" -v " + dir.HostlinkDir() + ":/run/riotbox-hostlink:rw,z" +
					" --entrypoint /run/riotbox-egress-share/riotbox-core " + image +
					" hostlink-relay --socket /run/riotbox-hostlink/relay.sock --ports /run/riotbox-egress-share/hostlink.ports --target 169.254.1.2"))
				envoy := slices.IndexFunc(lines, func(l string) bool { return strings.HasPrefix(l, "run -d --name s1-egress ") })
				Expect(envoy).To(BeNumerically(">", 4))
				Expect(os.ReadFile(dir.Core())).To(Equal([]byte("core-binary")))
				Expect(flags[len(flags)-2:]).To(Equal([]string{"-v", dir.ShareDir() + ":/run/riotbox-egress-share:ro,z"}))
			})

			It("rolls back, without starting the proxy, when the sidecar exits before its socket appears", func() {
				base := healthy(dir)
				engine.respond = func(args []string) ([]byte, error) {
					switch {
					case args[0] == "info":
						return []byte("pasta\n"), nil
					case args[0] == "container" && args[1] == "inspect" && args[len(args)-1] == "s1-hostlink":
						return []byte("false\n"), nil
					}
					return base(args)
				}
				_, err := m.Up(req)
				Expect(err).To(MatchError(ContainSubstring("the egress hostlink relay exited during startup")))
				Expect(engine.lines()).NotTo(ContainElement(HavePrefix("run -d --name s1-egress ")))
				Expect(engine.lines()).To(ContainElement(HavePrefix("rm --force --ignore s1 s1-egress s1-hostlink")))
			})

			It("without pasta starts no sidecar and mounts nothing new into the agent", func() {
				engine.respond = healthy(dir)
				flags, err := m.Up(req)
				Expect(err).NotTo(HaveOccurred())
				Expect(engine.lines()).NotTo(ContainElement(ContainSubstring("s1-hostlink")))
				Expect(strings.Join(flags, " ")).NotTo(ContainSubstring("riotbox-egress-share"))
				Expect(dir.Core()).NotTo(BeAnExistingFile())
			})

			It("without pasta warns when the allowlist names the host", func() {
				engine.respond = healthy(dir)
				_, err := m.Up(req)
				Expect(err).NotTo(HaveOccurred())
				Expect(stderr.String()).To(ContainSubstring("WARNING: egress: host.containers.internal is on the allowlist, but reaching the host's loopback needs rootless podman with pasta"))
			})

			It("removes a reused session dir's stale socket before starting", func() {
				Expect(dir.Create()).To(Succeed())
				Expect(os.WriteFile(dir.HostlinkSocket(), nil, 0o600)).To(Succeed())
				engine.respond = healthy(dir)
				_, err := m.Up(req)
				Expect(err).NotTo(HaveOccurred())
				Expect(dir.HostlinkSocket()).NotTo(BeAnExistingFile())
			})
		})

		Describe("with keys to inject", func() {
			const key = "sk-ant-s3cret-for-pod-specs"

			BeforeEach(func() {
				req.Credentials = []inject.Credential{{Env: "ANTHROPIC_API_KEY", Host: "api.anthropic.com", Header: "x-api-key", Value: key}}
			})

			It("mounts the secrets dir into the proxy alone, and gives the agent the CA and a placeholder", func() {
				engine.respond = healthy(dir)
				flags, err := m.Up(req)
				Expect(err).NotTo(HaveOccurred())
				run := engine.lines()[engine.index("run -d ")]
				Expect(run).To(ContainSubstring(" -v " + dir.SecretsDir() + ":/etc/riotbox-egress-secrets:ro,z "))
				Expect(run).To(HaveSuffix(" --entrypoint /usr/local/bin/envoy " + image + " -c /etc/riotbox-egress/bootstrap.json --log-path /var/log/riotbox-egress/envoy.log --file-flush-interval-msec 1000"))
				Expect(run).NotTo(ContainSubstring(dir.CACert()))
				Expect(flags).To(HaveLen(29))
				Expect(flags[21:]).To(Equal([]string{
					"-v", dir.CACert() + ":/run/riotbox-egress/ca.crt:ro,z",
					"-e", "NODE_EXTRA_CA_CERTS=/run/riotbox-egress/ca.crt",
					"-e", "RIOTBOX_EGRESS_CA=/run/riotbox-egress/ca.crt",
					"-e", "ANTHROPIC_API_KEY=riotbox-egress-placeholder",
				}))
				Expect(pod.AgentCACert).To(Equal("/run/riotbox-egress/ca.crt"))
				Expect(strings.Join(flags, " ")).NotTo(ContainSubstring(dir.SecretsDir()))
				Expect(filepath.Join(dir.SecretsDir(), "api.anthropic.com.credential.json")).To(BeARegularFile())
				Expect(dir.CACert()).To(BeARegularFile())
				lds, err := os.ReadFile(filepath.Join(dir.ConfigDir(), "lds.json"))
				Expect(err).NotTo(HaveOccurred())
				Expect(string(lds)).To(ContainSubstring(`"intercept-api.anthropic.com"`))
			})

			It("never puts the key on an engine command line or in the agent's flags", func() {
				engine.respond = healthy(dir)
				flags, err := m.Up(req)
				Expect(err).NotTo(HaveOccurred())
				for _, l := range engine.lines() {
					Expect(strings.Contains(l, key)).To(BeFalse(), "an engine call holds the key")
				}
				Expect(strings.Contains(strings.Join(flags, " "), key)).To(BeFalse(), "the agent's flags hold the key")
			})

			It("removes the secrets dir when a later step fails", func() {
				engine.respond = func(args []string) ([]byte, error) {
					if args[0] == "run" {
						return nil, errors.New("run failed")
					}
					return healthy(dir)(args)
				}
				_, err := m.Up(req)
				Expect(err).To(MatchError(ContainSubstring("run failed")))
				Expect(strings.Contains(err.Error(), key)).To(BeFalse(), "the error holds the key")
				Expect(dir.SecretsDir()).NotTo(BeAnExistingFile())
			})

			DescribeTable("removes the secrets dir when a step before the engine objects fails",
				func(breakIt func()) {
					breakIt()
					_, err := m.Up(req)
					Expect(err).To(HaveOccurred())
					Expect(strings.Contains(err.Error(), key)).To(BeFalse(), "the error holds the key")
					Expect(dir.SecretsDir()).NotTo(BeAnExistingFile())
					Expect(engine.index("network create")).To(Equal(-1))
				},
				Entry("a broken conf file", func() {
					req.UserConf = filepath.Join(GinkgoT().TempDir(), "user.conf")
					Expect(os.WriteFile(req.UserConf, []byte("[bogus]\n"), 0o600)).To(Succeed())
				}),
				Entry("an image check that fails", func() {
					engine.respond = func(args []string) ([]byte, error) {
						if args[0] == "image" {
							return nil, errors.New("image exists: boom")
						}
						return nil, nil
					}
				}),
				Entry("a pull that fails", func() {
					engine.respond = func(args []string) ([]byte, error) {
						switch args[0] {
						case "image":
							return []byte("absent"), nil
						case "pull":
							return nil, errors.New("pull: boom")
						}
						return nil, nil
					}
				}),
			)

			It("refuses a session dir without a runtime base before creating anything", func() {
				bare, err := state.Open(root, "s1")
				Expect(err).NotTo(HaveOccurred())
				req.Dir = bare
				_, err = m.Up(req)
				Expect(err).To(MatchError(state.ErrNoRuntimeDir))
				Expect(engine.calls).To(BeEmpty())
				Expect(root).NotTo(BeAnExistingFile())
			})

			It("fails before any engine call when the secrets cannot be written", func() {
				if os.Getuid() == 0 {
					Skip("root ignores directory permissions")
				}
				Expect(dir.Create()).To(Succeed())
				Expect(os.MkdirAll(filepath.Join(dir.SecretsDir(), "sub"), 0o700)).To(Succeed())
				Expect(os.Chmod(dir.SecretsDir(), 0o500)).To(Succeed())
				DeferCleanup(os.Chmod, dir.SecretsDir(), os.FileMode(0o700))
				_, err := m.Up(req)
				Expect(err).To(HaveOccurred())
				Expect(engine.calls).To(BeEmpty())
			})
		})

		It("mounts no secrets and gives no CA when there is no key", func() {
			engine.respond = healthy(dir)
			flags, err := m.Up(req)
			Expect(err).NotTo(HaveOccurred())
			Expect(engine.lines()[engine.index("run -d ")]).NotTo(ContainSubstring("riotbox-egress-secrets"))
			Expect(strings.Join(flags, " ")).NotTo(ContainSubstring("riotbox-egress/ca.crt"))
			Expect(dir.SecretsDir()).NotTo(BeAnExistingFile())
			Expect(dir.CACert()).NotTo(BeAnExistingFile())
		})

		It("drops a reused session dir's secrets and CA when there is no key", func() {
			Expect(dir.Create()).To(Succeed())
			Expect(dir.WriteInjection([]inject.Credential{{Env: "K", Host: "api.anthropic.com", Header: "x-api-key", Value: "v"}}, time.Now())).To(Succeed())
			engine.respond = healthy(dir)
			_, err := m.Up(req)
			Expect(err).NotTo(HaveOccurred())
			Expect(engine.lines()[engine.index("run -d ")]).NotTo(ContainSubstring("riotbox-egress-secrets"))
			Expect(dir.SecretsDir()).NotTo(BeAnExistingFile())
			Expect(dir.CACert()).NotTo(BeAnExistingFile())
		})
	})

	Describe("Down", func() {
		It("removes the session's secrets under every runtime base it is given", func() {
			bases := []string{filepath.Join(GinkgoT().TempDir(), "riotbox-egress"), filepath.Join(GinkgoT().TempDir(), "riotbox-egress")}
			for _, b := range bases {
				Expect(os.MkdirAll(filepath.Join(b, "s1", "secrets"), 0o700)).To(Succeed())
			}
			other := filepath.Join(bases[1], "s2", "secrets")
			Expect(os.MkdirAll(other, 0o700)).To(Succeed())
			Expect(m.Down(dir, false, bases...)).To(Succeed())
			for _, b := range bases {
				Expect(filepath.Join(b, "s1")).NotTo(BeAnExistingFile())
			}
			Expect(other).To(BeADirectory())
		})

		It("removes the secrets dir an earlier release kept in the state dir", func() {
			Expect(dir.Create()).To(Succeed())
			legacy := filepath.Join(dir.Path(), "secrets")
			Expect(os.Mkdir(legacy, 0o700)).To(Succeed())
			Expect(m.Down(dir, false)).To(Succeed())
			Expect(legacy).NotTo(BeAnExistingFile())
		})

		It("removes the secrets dir after the containers, keeping the logs", func() {
			Expect(dir.Create()).To(Succeed())
			Expect(dir.WriteInjection([]inject.Credential{{Env: "K", Host: "api.anthropic.com", Header: "x-api-key", Value: "v"}}, time.Now())).To(Succeed())
			engine.respond = func(args []string) ([]byte, error) {
				if args[0] == "rm" {
					Expect(dir.SecretsDir()).To(BeADirectory(), "secrets removed before the containers")
				}
				return nil, nil
			}
			Expect(m.Down(dir, false)).To(Succeed())
			Expect(dir.SecretsDir()).NotTo(BeAnExistingFile())
			Expect(dir.LogDir()).To(BeADirectory())
		})

		It("removes the relay's socket", func() {
			Expect(dir.Create()).To(Succeed())
			Expect(os.WriteFile(dir.HostlinkSocket(), nil, 0o600)).To(Succeed())
			Expect(m.Down(dir, false)).To(Succeed())
			Expect(dir.HostlinkSocket()).NotTo(BeAnExistingFile())
		})

		It("removes the session's riotbox-core copy", func() {
			Expect(dir.Create()).To(Succeed())
			Expect(os.WriteFile(dir.Core(), []byte("core-binary"), 0o700)).To(Succeed())
			Expect(m.Down(dir, false)).To(Succeed())
			Expect(dir.Core()).NotTo(BeAnExistingFile())
			Expect(dir.ShareDir()).To(BeADirectory())
		})

		It("succeeds when there is no secrets dir, or no state dir at all", func() {
			Expect(m.Down(dir, false)).To(Succeed())
			Expect(dir.Create()).To(Succeed())
			Expect(m.Down(dir, false)).To(Succeed())
		})

		It("stops the proxy first, then removes the agent, the proxy and each network that exists", func() {
			engine.respond = func(args []string) ([]byte, error) {
				if args[0] == "network" && args[1] == "exists" && args[2] == "s1-ext" {
					return []byte("absent"), nil
				}
				return nil, nil
			}
			Expect(m.Down(dir, false)).To(Succeed())
			Expect(engine.lines()).To(Equal([]string{
				"stop --ignore --time 10 s1-egress",
				"rm --force --ignore s1 s1-egress s1-hostlink",
				"network exists s1-int",
				"network rm s1-int",
				"network exists s1-ext",
			}))
		})

		It("carries on past a failed step and returns every failure", func() {
			engine.respond = func(args []string) ([]byte, error) {
				switch {
				case args[0] == "stop":
					return nil, errors.New("stop failed")
				case args[0] == "network" && args[1] == "rm":
					return nil, errors.New("network rm failed: " + args[2])
				}
				return nil, nil
			}
			err := m.Down(dir, false)
			Expect(err).To(MatchError(ContainSubstring("stop failed")))
			Expect(err).To(MatchError(ContainSubstring("network rm failed: s1-int")))
			Expect(err).To(MatchError(ContainSubstring("network rm failed: s1-ext")))
			Expect(engine.index("rm --force")).To(Equal(1))
		})

		It("treats a network that vanished between exists and rm as removed", func() {
			engine.respond = func(args []string) ([]byte, error) {
				if args[0] == "network" && args[1] == "rm" {
					return nil, errors.New("Error: no such network s1-int")
				}
				return nil, nil
			}
			Expect(m.Down(dir, false)).To(Succeed())
		})

		It("truncates a very long log line when printing the tail", func() {
			engine.respond = func(args []string) ([]byte, error) {
				if args[0] == "run" {
					return nil, appendFile(dir.EnvoyLog(), strings.Repeat("x", 2000)+"\n")
				}
				if args[0] == "container" {
					return []byte("false\n"), nil
				}
				return nil, nil
			}
			_, err := m.Up(req)
			Expect(err).To(HaveOccurred())
			Expect(stderr.String()).To(ContainSubstring("  " + strings.Repeat("x", 512) + " [truncated]\n"))
			Expect(stderr.String()).NotTo(ContainSubstring(strings.Repeat("x", 513)))
		})

		It("reports denied requests when asked to", func() {
			Expect(dir.Create()).To(Succeed())
			Expect(os.WriteFile(dir.AccessLog(), []byte(`{"status":403}`+"\n"+`{"status":200}`+"\n"), 0o600)).To(Succeed())
			Expect(m.Down(dir, true)).To(Succeed())
			Expect(stderr.String()).To(Equal("egress: 1 denied request(s), see " + dir.AccessLog() + "\n"))
		})

		It("says nothing when nothing was denied, or when not asked", func() {
			Expect(dir.Create()).To(Succeed())
			Expect(os.WriteFile(dir.AccessLog(), []byte(`{"status":403}`+"\n"), 0o600)).To(Succeed())
			Expect(m.Down(dir, false)).To(Succeed())
			Expect(os.WriteFile(dir.AccessLog(), []byte(`{"status":200}`+"\n"), 0o600)).To(Succeed())
			Expect(m.Down(dir, true)).To(Succeed())
			Expect(stderr.String()).To(BeEmpty())
		})
	})
})

var _ = Describe("Exec", func() {
	script := func(body string) pod.Exec {
		path := filepath.Join(GinkgoT().TempDir(), "engine")
		Expect(os.WriteFile(path, []byte("#!/bin/sh\n"+body+"\n"), 0o755)).To(Succeed())
		return pod.Exec{Cmd: path, Stderr: &bytes.Buffer{}}
	}

	It("Output returns stdout on success", func() {
		out, err := script(`echo hello`).Output("x")
		Expect(err).NotTo(HaveOccurred())
		Expect(string(out)).To(Equal("hello\n"))
	})

	It("Output returns an error carrying the engine's stderr on failure", func() {
		_, err := script(`echo "engine says no" >&2; exit 125`).Output("x")
		Expect(err).To(MatchError(ContainSubstring("engine says no")))
	})

	It("Exists is true on exit 0, false without error on exit 1, an error otherwise", func() {
		ok, err := script(`exit 0`).Exists("x")
		Expect(err).NotTo(HaveOccurred())
		Expect(ok).To(BeTrue())

		ok, err = script(`exit 1`).Exists("x")
		Expect(err).NotTo(HaveOccurred())
		Expect(ok).To(BeFalse())

		ok, err = script(`exit 125`).Exists("x")
		Expect(err).To(HaveOccurred())
		Expect(ok).To(BeFalse())
	})

	It("Exists is an error when the engine cannot be run", func() {
		ok, err := pod.Exec{Cmd: filepath.Join(GinkgoT().TempDir(), "missing")}.Exists("x")
		Expect(err).To(HaveOccurred())
		Expect(ok).To(BeFalse())
	})
})
