package pod_test

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/trevor-vaughan/claude-riotbox/internal/egress/pod"
	"github.com/trevor-vaughan/claude-riotbox/internal/egress/state"
)

func gateways(names ...string) []byte {
	var parts []string
	for _, n := range names {
		parts = append(parts, fmt.Sprintf(`{"Names":[%q],"Labels":{"riotbox.egress":%q,"riotbox.egress-role":"gateway"}}`, n+"-egress", n))
	}
	return []byte("[" + strings.Join(parts, ",") + "]\n")
}

func podJSON(name, pid, pidns string) string {
	return namedPodJSON(name+"-pod", name, pid, pidns)
}

// namedPodJSON is a pod called podName that claims to belong to session.
func namedPodJSON(podName, session, pid, pidns string) string {
	return fmt.Sprintf(`{"Name":%q,"Labels":{"riotbox.egress":%q,"riotbox.owner-pid":%q,"riotbox.owner-pidns":%q}}`, podName, session, pid, pidns)
}

// networkJSON is a network as podman lists it: lowercase keys.
func networkJSON(netName, session, pid, pidns string) string {
	return fmt.Sprintf(`{"name":%q,"labels":{"riotbox.egress":%q,"riotbox.owner-pid":%q,"riotbox.owner-pidns":%q}}`, netName, session, pid, pidns)
}

// deadPID returns the PID of a process that has exited and been reaped.
func deadPID() int {
	cmd := exec.Command("true")
	ExpectWithOffset(1, cmd.Run()).To(Succeed())
	return cmd.Process.Pid
}

var _ = Describe("sessions", func() {
	var (
		root   string
		engine *fakeEngine
		stderr *bytes.Buffer
		m      pod.Manager
	)

	BeforeEach(func() {
		root = GinkgoT().TempDir()
		engine = &fakeEngine{}
		stderr = &bytes.Buffer{}
		m = pod.Manager{Engine: engine, Stderr: stderr, ReadyTimeout: time.Second, PollInterval: time.Millisecond}
	})

	Describe("Running", func() {
		It("lists the sessions whose proxy runs, sorted", func() {
			engine.respond = func([]string) ([]byte, error) { return gateways("s2", "s1"), nil }
			Expect(m.Running()).To(Equal([]string{"s1", "s2"}))
			Expect(engine.lines()).To(Equal([]string{"ps --filter label=riotbox.egress-role=gateway --format json"}))
		})

		It("reads empty output as none", func() {
			engine.respond = func([]string) ([]byte, error) { return []byte("\n"), nil }
			Expect(m.Running()).To(BeEmpty())
		})

		It("skips, and warns about, a label that is not a session name", func() {
			engine.respond = func([]string) ([]byte, error) { return gateways("../escape", "s1"), nil }
			Expect(m.Running()).To(Equal([]string{"s1"}))
			Expect(stderr.String()).To(ContainSubstring("is not a session name"))
		})

		It("skips a container whose name does not match its label", func() {
			engine.respond = func([]string) ([]byte, error) {
				return []byte(`[{"Names":["junk"],"Labels":{"riotbox.egress":"victim","riotbox.egress-role":"gateway"}}]`), nil
			}
			Expect(m.Running()).To(BeEmpty())
			Expect(stderr.String()).To(ContainSubstring("victim"))
		})

		It("lists a session once however many containers claim it", func() {
			engine.respond = func([]string) ([]byte, error) { return gateways("s1", "s1"), nil }
			Expect(m.Running()).To(Equal([]string{"s1"}))
		})

		It("fails on output that is not a JSON list", func() {
			engine.respond = func([]string) ([]byte, error) { return []byte("Names\n"), nil }
			_, err := m.Running()
			Expect(err).To(MatchError(ContainSubstring("reading the engine's container list")))
		})
	})

	Describe("RunningSessions", func() {
		It("reads each session's start and owner PID off its proxy container, sorted by name", func() {
			engine.respond = func([]string) ([]byte, error) {
				return []byte(`[{"Names":["s2-egress"],"Labels":{"riotbox.egress":"s2","riotbox.egress-role":"gateway","riotbox.owner-pid":"42"},"StartedAt":1792811831},` +
					`{"Names":["s1-egress"],"Labels":{"riotbox.egress":"s1","riotbox.egress-role":"gateway","riotbox.owner-pid":"7"},"StartedAt":1792800000}]`), nil
			}
			Expect(m.RunningSessions()).To(Equal([]pod.RunningSession{
				{Name: "s1", Started: time.Unix(1792800000, 0), OwnerPID: 7},
				{Name: "s2", Started: time.Unix(1792811831, 0), OwnerPID: 42},
			}))
			Expect(engine.lines()).To(Equal([]string{"ps --filter label=riotbox.egress-role=gateway --format json"}))
		})

		DescribeTable("leaves out a start or an owner PID it cannot trust",
			func(pid, started string) {
				engine.respond = func([]string) ([]byte, error) {
					return []byte(`[{"Names":["s1-egress"],"Labels":{"riotbox.egress":"s1","riotbox.egress-role":"gateway"` + pid + `}` + started + `}]`), nil
				}
				Expect(m.RunningSessions()).To(Equal([]pod.RunningSession{{Name: "s1"}}))
			},
			Entry("neither recorded", "", ""),
			Entry("a PID that is not a number, and a zero start", `,"riotbox.owner-pid":"x"`, `,"StartedAt":0`),
			Entry("a PID of 0, and a negative start", `,"riotbox.owner-pid":"0"`, `,"StartedAt":-5`),
			Entry("a PID past the largest PID", `,"riotbox.owner-pid":"4294967296"`, ""),
		)
	})

	Describe("Target", func() {
		It("picks the only running session", func() {
			engine.respond = func([]string) ([]byte, error) { return gateways("s1"), nil }
			d, err := m.Target(root, "")
			Expect(err).NotTo(HaveOccurred())
			Expect(d.Path()).To(Equal(filepath.Join(root, "s1")))
		})

		It("refuses when none runs", func() {
			engine.respond = func([]string) ([]byte, error) { return []byte("[]"), nil }
			_, err := m.Target(root, "")
			Expect(err).To(MatchError("no egress session is running"))
		})

		It("refuses to guess between several, naming them", func() {
			engine.respond = func([]string) ([]byte, error) { return gateways("s1", "s2"), nil }
			_, err := m.Target(root, "")
			Expect(err).To(MatchError("2 egress sessions are running; pick one with --session: s1 s2"))
		})

		It("takes a named session only while it runs", func() {
			engine.respond = func([]string) ([]byte, error) { return gateways("s1", "s2"), nil }
			d, err := m.Target(root, "s2")
			Expect(err).NotTo(HaveOccurred())
			Expect(d.Name()).To(Equal("s2"))
			_, err = m.Target(root, "s3")
			Expect(err).To(MatchError("no egress session named s3 is running"))
		})
	})

	Describe("Sweep", func() {
		now := time.Now()
		week := 7 * 24 * time.Hour

		var (
			networks []string
			// inPod is the engine's `ps --filter pod=<key>` answer: the
			// containers running in that pod.
			inPod map[string]string
			// rt is the runtime base the sessions' secrets are under.
			rt string
		)
		pods := func(entries ...string) {
			engine.respond = func(args []string) ([]byte, error) {
				switch {
				case args[0] == "pod" && args[1] == "ps":
					return []byte("[" + strings.Join(entries, ",") + "]"), nil
				case args[0] == "network" && args[1] == "ls":
					return []byte("[" + strings.Join(networks, ",") + "]"), nil
				case args[0] == "ps" && args[1] == "--filter":
					return []byte(inPod[strings.TrimPrefix(args[2], "pod=")]), nil
				}
				return nil, nil
			}
		}
		// oldDir creates a state dir for name last used age ago.
		oldDir := func(name string, age time.Duration) state.Dir {
			d, err := state.Open(root, name)
			ExpectWithOffset(1, err).NotTo(HaveOccurred())
			ExpectWithOffset(1, d.Create()).To(Succeed())
			t := now.Add(-age)
			ExpectWithOffset(1, os.Chtimes(d.Path(), t, t)).To(Succeed())
			return d.WithRuntime(rt)
		}
		// runtimeSecrets makes name's secrets dir under rt, its session
		// dir there last changed age ago.
		runtimeSecrets := func(name string, age time.Duration) string {
			secrets := filepath.Join(rt, name, "secrets")
			ExpectWithOffset(1, os.MkdirAll(secrets, 0o700)).To(Succeed())
			t := now.Add(-age)
			ExpectWithOffset(1, os.Chtimes(filepath.Join(rt, name), t, t)).To(Succeed())
			return secrets
		}

		BeforeEach(func() {
			networks, inPod = nil, nil
			rt = filepath.Join(GinkgoT().TempDir(), "riotbox-egress")
		})

		It("removes the secrets of a session no launch owns once it is an hour idle, keeping its logs", func() {
			pods()
			for name, age := range map[string]time.Duration{"idle": 2 * time.Hour, "starting": time.Minute} {
				d := oldDir(name, 0)
				Expect(os.MkdirAll(d.SecretsDir(), 0o700)).To(Succeed())
				t := now.Add(-age)
				Expect(os.Chtimes(d.Path(), t, t)).To(Succeed())
			}
			Expect(m.Sweep(root, []string{rt}, week, now)).To(Succeed())
			Expect(filepath.Join(rt, "idle")).NotTo(BeAnExistingFile())
			Expect(filepath.Join(root, "idle", "log")).To(BeADirectory())
			Expect(filepath.Join(rt, "starting", "secrets")).To(BeADirectory())
		})

		It("removes the secrets an earlier release kept in an idle state dir, keeping a starting one's", func() {
			pods()
			for name, age := range map[string]time.Duration{"idle": 2 * time.Hour, "starting": time.Minute} {
				d := oldDir(name, 0)
				Expect(os.Mkdir(filepath.Join(d.Path(), "secrets"), 0o700)).To(Succeed())
				t := now.Add(-age)
				Expect(os.Chtimes(d.Path(), t, t)).To(Succeed())
			}
			Expect(m.Sweep(root, []string{rt}, week, now)).To(Succeed())
			Expect(filepath.Join(root, "idle", "secrets")).NotTo(BeAnExistingFile())
			Expect(filepath.Join(root, "starting", "secrets")).To(BeADirectory())
		})

		It("removes the runtime secrets of a state dir it deletes as stale", func() {
			pods()
			oldDir("old", 8*24*time.Hour)
			secrets := runtimeSecrets("old", 8*24*time.Hour)
			Expect(m.Sweep(root, []string{rt}, week, now)).To(Succeed())
			Expect(filepath.Join(root, "old")).NotTo(BeAnExistingFile())
			Expect(secrets).NotTo(BeAnExistingFile())
		})

		It("removes runtime secrets whose state dir is gone once they are an hour old", func() {
			pods()
			gone := runtimeSecrets("gone", 2*time.Hour)
			young := runtimeSecrets("young", time.Minute)
			Expect(m.Sweep(root, []string{rt}, week, now)).To(Succeed())
			Expect(filepath.Dir(gone)).NotTo(BeAnExistingFile())
			Expect(young).To(BeADirectory())
		})

		It("sweeps the secrets under every runtime base it is given", func() {
			pods(podJSON("orphan", fmt.Sprint(deadPID()), pod.PIDNamespace()))
			rt2 := filepath.Join(GinkgoT().TempDir(), "riotbox-egress")
			oldDir("idle", 2*time.Hour)
			oldDir("orphan", time.Minute)
			var made []string
			for _, base := range []string{rt, rt2} {
				for _, name := range []string{"idle", "gone", "orphan"} {
					secrets := filepath.Join(base, name, "secrets")
					Expect(os.MkdirAll(secrets, 0o700)).To(Succeed())
					old := now.Add(-2 * time.Hour)
					Expect(os.Chtimes(filepath.Join(base, name), old, old)).To(Succeed())
					made = append(made, secrets)
				}
			}
			Expect(m.Sweep(root, []string{rt, rt2}, week, now)).To(Succeed())
			for _, secrets := range made {
				Expect(secrets).NotTo(BeAnExistingFile())
			}
		})

		It("keeps the runtime secrets of a live session whose state dir is gone", func() {
			secrets := runtimeSecrets("busy", 30*24*time.Hour)
			pods(podJSON("busy", fmt.Sprint(os.Getpid()), pod.PIDNamespace()))
			Expect(m.Sweep(root, []string{rt}, week, now)).To(Succeed())
			Expect(secrets).To(BeADirectory())
		})

		It("leaves runtime secrets to the idle check while their state dir shows recent use", func() {
			pods()
			oldDir("recent", time.Minute)
			secrets := runtimeSecrets("recent", 2*time.Hour)
			Expect(m.Sweep(root, []string{rt}, week, now)).To(Succeed())
			Expect(secrets).To(BeADirectory())
		})

		It("sweeps only the state dirs' secrets when there is no runtime base", func() {
			pods()
			d := oldDir("idle", 2*time.Hour)
			Expect(os.Mkdir(filepath.Join(d.Path(), "secrets"), 0o700)).To(Succeed())
			Expect(os.Chtimes(d.Path(), now.Add(-2*time.Hour), now.Add(-2*time.Hour))).To(Succeed())
			Expect(m.Sweep(root, nil, week, now)).To(Succeed())
			Expect(filepath.Join(d.Path(), "secrets")).NotTo(BeAnExistingFile())
		})

		It("keeps a live session's secrets however long it has run", func() {
			d := oldDir("busy", 30*24*time.Hour)
			Expect(os.MkdirAll(d.SecretsDir(), 0o700)).To(Succeed())
			Expect(os.Chtimes(d.Path(), now.Add(-30*24*time.Hour), now.Add(-30*24*time.Hour))).To(Succeed())
			pods(podJSON("busy", fmt.Sprint(os.Getpid()), pod.PIDNamespace()))
			Expect(m.Sweep(root, []string{rt}, week, now)).To(Succeed())
			Expect(d.SecretsDir()).To(BeADirectory())
		})

		It("keeps the secrets of a session whose agent runs, though its owner is gone", func() {
			d := oldDir("orphan", 0)
			Expect(os.MkdirAll(d.SecretsDir(), 0o700)).To(Succeed())
			Expect(os.Chtimes(d.Path(), now.Add(-2*time.Hour), now.Add(-2*time.Hour))).To(Succeed())
			pods(podJSON("orphan", fmt.Sprint(deadPID()), pod.PIDNamespace()))
			inPod = map[string]string{"orphan-pod": `[{"Names":["orphan-egress"]},{"Names":["orphan"]}]`}
			Expect(m.Sweep(root, []string{rt}, week, now)).To(Succeed())
			Expect(d.SecretsDir()).To(BeADirectory())
		})

		It("keeps the secrets of a session whose owner is in another PID namespace", func() {
			d := oldDir("elsewhere", 0)
			Expect(os.MkdirAll(d.SecretsDir(), 0o700)).To(Succeed())
			Expect(os.Chtimes(d.Path(), now.Add(-2*time.Hour), now.Add(-2*time.Hour))).To(Succeed())
			pods(podJSON("elsewhere", fmt.Sprint(deadPID()), "pid:[1]"))
			Expect(m.Sweep(root, []string{rt}, week, now)).To(Succeed())
			Expect(d.SecretsDir()).To(BeADirectory())
		})

		It("removes an orphaned pod's secrets when it tears the pod down", func() {
			d := oldDir("orphan", time.Minute)
			Expect(os.MkdirAll(d.SecretsDir(), 0o700)).To(Succeed())
			pods(podJSON("orphan", fmt.Sprint(deadPID()), pod.PIDNamespace()))
			Expect(m.Sweep(root, []string{rt}, week, now)).To(Succeed())
			Expect(d.SecretsDir()).NotTo(BeAnExistingFile())
		})

		It("tears down a pod whose owner is gone from this PID namespace", func() {
			pods(podJSON("orphan", fmt.Sprint(deadPID()), pod.PIDNamespace()))
			Expect(m.Sweep(root, []string{rt}, week, now)).To(Succeed())
			Expect(engine.index("stop --ignore --time 10 orphan-egress")).To(BeNumerically(">", 0))
			Expect(engine.index("pod rm --force --ignore orphan-pod")).To(BeNumerically(">", 0))
		})

		It("leaves a session alone while its agent runs, though its owner is gone", func() {
			pods(podJSON("orphan", fmt.Sprint(deadPID()), pod.PIDNamespace()))
			inPod = map[string]string{"orphan-pod": `[{"Names":["orphan-egress"]},{"Names":["orphan"]}]`}
			Expect(m.Sweep(root, []string{rt}, week, now)).To(Succeed())
			Expect(engine.lines()).To(ContainElement("ps --filter pod=orphan-pod --format json"))
			Expect(engine.index("stop")).To(Equal(-1))
			Expect(engine.index("pod rm")).To(Equal(-1))
		})

		It("tears down a session whose pod runs only its proxy, or a container not named as its agent", func() {
			pods(podJSON("orphan", fmt.Sprint(deadPID()), pod.PIDNamespace()))
			inPod = map[string]string{"orphan-pod": `[{"Names":["orphan-egress"]},{"Names":["orphan-x"]}]`}
			Expect(m.Sweep(root, []string{rt}, week, now)).To(Succeed())
			Expect(engine.index("pod rm --force --ignore orphan-pod")).To(BeNumerically(">", 0))
		})

		It("leaves a session alone, and reports, when its pod's containers cannot be listed", func() {
			pods(podJSON("orphan", fmt.Sprint(deadPID()), pod.PIDNamespace()))
			base := engine.respond
			engine.respond = func(args []string) ([]byte, error) {
				if args[0] == "ps" {
					return nil, errors.New("ps: boom")
				}
				return base(args)
			}
			err := m.Sweep(root, []string{rt}, week, now)
			Expect(err).To(MatchError(ContainSubstring("ps: boom")))
			Expect(err).To(MatchError(ContainSubstring("orphan")))
			Expect(engine.index("stop")).To(Equal(-1))
		})

		It("leaves a session alone when its pod's container list is not JSON", func() {
			pods(podJSON("orphan", fmt.Sprint(deadPID()), pod.PIDNamespace()))
			inPod = map[string]string{"orphan-pod": `nope`}
			Expect(m.Sweep(root, []string{rt}, week, now)).To(MatchError(ContainSubstring("orphan")))
			Expect(engine.index("stop")).To(Equal(-1))
		})

		DescribeTable("leaves a pod alone when its owner cannot be judged dead",
			func(pid func() string, pidns func() string) {
				pods(podJSON("keep", pid(), pidns()))
				Expect(m.Sweep(root, []string{rt}, week, now)).To(Succeed())
				Expect(engine.index("stop")).To(Equal(-1))
			},
			Entry("its owner is alive", func() string { return fmt.Sprint(os.Getpid()) }, pod.PIDNamespace),
			Entry("its owner is in another PID namespace", func() string { return fmt.Sprint(deadPID()) }, func() string { return "pid:[1]" }),
			Entry("its owner PID label is not a number", func() string { return "x" }, pod.PIDNamespace),
			Entry("its owner PID label is missing", func() string { return "" }, pod.PIDNamespace),
			Entry("its owner PID is negative", func() string { return "-5" }, pod.PIDNamespace),
			Entry("its owner PID is above MaxInt32", func() string { return "99999999999" }, pod.PIDNamespace),
			Entry("its owner is PID 1, which a non-root sweep may not signal (EPERM)", func() string {
				if err := syscall.Kill(1, 0); !errors.Is(err, syscall.EPERM) {
					Skip("PID 1 is signalable here, so EPERM cannot be provoked")
				}
				return "1"
			}, pod.PIDNamespace),
		)

		It("deletes state dirs no pod uses that are older than maxAge, and keeps fresh ones", func() {
			pods()
			for name, age := range map[string]time.Duration{"old": 8 * 24 * time.Hour, "fresh": time.Hour} {
				d, err := state.Open(root, name)
				Expect(err).NotTo(HaveOccurred())
				Expect(d.Create()).To(Succeed())
				t := now.Add(-age)
				Expect(os.Chtimes(d.Path(), t, t)).To(Succeed())
			}
			Expect(m.Sweep(root, []string{rt}, week, now)).To(Succeed())
			Expect(filepath.Join(root, "old")).NotTo(BeADirectory())
			Expect(filepath.Join(root, "fresh")).To(BeADirectory())
		})

		It("keeps the state of a live pod even when it is older than maxAge", func() {
			d := oldDir("busy", 30*24*time.Hour)
			pods(podJSON("busy", fmt.Sprint(os.Getpid()), pod.PIDNamespace()))
			Expect(m.Sweep(root, []string{rt}, week, now)).To(Succeed())
			Expect(d.Path()).To(BeADirectory())
		})

		It("does not touch a session when a pod with another name claims it with a dead owner", func() {
			pods(
				podJSON("victim", fmt.Sprint(os.Getpid()), pod.PIDNamespace()),
				namedPodJSON("junk", "victim", fmt.Sprint(deadPID()), pod.PIDNamespace()),
			)
			Expect(m.Sweep(root, []string{rt}, week, now)).To(Succeed())
			Expect(engine.index("stop")).To(Equal(-1))
			Expect(engine.index("pod rm")).To(Equal(-1))
			Expect(stderr.String()).To(ContainSubstring("junk"))
		})

		DescribeTable("never tears a session down while any entry of it has a live owner",
			func(liveFirst bool) {
				live := podJSON("dup", fmt.Sprint(os.Getpid()), pod.PIDNamespace())
				dead := podJSON("dup", fmt.Sprint(deadPID()), pod.PIDNamespace())
				if liveFirst {
					pods(live, dead)
				} else {
					pods(dead, live)
				}
				Expect(m.Sweep(root, []string{rt}, week, now)).To(Succeed())
				Expect(engine.index("stop")).To(Equal(-1))
			},
			Entry("live entry first", true),
			Entry("dead entry first", false),
		)

		It("fails, touching nothing, when the pods cannot be listed", func() {
			d := oldDir("old", 30*24*time.Hour)
			engine.respond = func(args []string) ([]byte, error) {
				if args[0] == "pod" && args[1] == "ps" {
					return nil, fmt.Errorf("engine down")
				}
				return nil, nil
			}
			Expect(m.Sweep(root, []string{rt}, week, now)).To(MatchError(ContainSubstring("listing egress pods: ")))
			Expect(engine.index("stop")).To(Equal(-1))
			Expect(engine.index("pod rm")).To(Equal(-1))
			Expect(d.Path()).To(BeADirectory())
		})

		It("fails, touching nothing, when the networks cannot be listed", func() {
			d := oldDir("old", 30*24*time.Hour)
			engine.respond = func(args []string) ([]byte, error) {
				if args[0] == "network" && args[1] == "ls" {
					return nil, fmt.Errorf("engine down")
				}
				return []byte("[]"), nil
			}
			Expect(m.Sweep(root, []string{rt}, week, now)).To(MatchError(ContainSubstring("listing egress networks: ")))
			Expect(engine.index("stop")).To(Equal(-1))
			Expect(d.Path()).To(BeADirectory())
		})

		It("removes the networks of a session whose pod is gone, when its owner is gone", func() {
			pods()
			networks = []string{
				networkJSON("orphan-int", "orphan", fmt.Sprint(deadPID()), pod.PIDNamespace()),
				networkJSON("orphan-ext", "orphan", fmt.Sprint(deadPID()), pod.PIDNamespace()),
			}
			Expect(m.Sweep(root, []string{rt}, week, now)).To(Succeed())
			Expect(engine.index("network rm orphan-int")).To(BeNumerically(">", 0))
			Expect(engine.index("network rm orphan-ext")).To(BeNumerically(">", 0))
		})

		It("leaves the networks of a live owner alone", func() {
			pods()
			networks = []string{networkJSON("busy-int", "busy", fmt.Sprint(os.Getpid()), pod.PIDNamespace())}
			Expect(m.Sweep(root, []string{rt}, week, now)).To(Succeed())
			Expect(engine.index("network rm")).To(Equal(-1))
			Expect(engine.index("stop")).To(Equal(-1))
		})

		It("skips, and warns about, a network whose name does not match its label", func() {
			pods()
			networks = []string{networkJSON("junk", "victim", fmt.Sprint(deadPID()), pod.PIDNamespace())}
			Expect(m.Sweep(root, []string{rt}, week, now)).To(Succeed())
			Expect(engine.index("stop")).To(Equal(-1))
			Expect(stderr.String()).To(ContainSubstring("junk"))
		})

		It("keeps an orphan's state, and reports, when its teardown fails", func() {
			engine.respond = func(args []string) ([]byte, error) {
				switch args[0] {
				case "pod":
					if args[1] == "ps" {
						return []byte("[" + podJSON("orphan", fmt.Sprint(deadPID()), pod.PIDNamespace()) + "]"), nil
					}
					return nil, fmt.Errorf("pod rm: engine down")
				}
				return nil, nil
			}
			d, err := state.Open(root, "orphan")
			Expect(err).NotTo(HaveOccurred())
			Expect(d.Create()).To(Succeed())
			old := now.Add(-30 * 24 * time.Hour)
			Expect(os.Chtimes(d.Path(), old, old)).To(Succeed())
			err = m.Sweep(root, []string{rt}, week, now)
			Expect(err).To(MatchError(ContainSubstring("tearing down the orphaned egress session orphan")))
			Expect(d.Path()).To(BeADirectory())
		})
	})
})
