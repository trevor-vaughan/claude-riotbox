package engine_test

import (
	"bytes"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/trevor-vaughan/claude-riotbox/internal/engine"
)

const inspectFormat = `{{$c := .ID}}{{$n := .Name}}{{range .Mounts}}{{$c}}{{"\x00"}}{{$n}}{{"\x00"}}{{.Source}}{{"\x00"}}{{.RW}}{{"\x00"}}{{end}}`

// fakeEngineScript answers from files beside it: <reply>.out on stdout,
// <reply>.err on stderr, <reply>.rc as the exit code (default 0). The reply
// of `ps` is ps-all, or ps-labelled with the label filter; that of
// `container inspect --format <f> <id>...` is inspect-<ids joined by _>.
// Every call's argv is appended to calls, one line per call, each argument
// in brackets.
const fakeEngineScript = `#!/bin/sh
d=$(dirname "$0")
for a in "$@"; do printf '[%s]' "$a"; done >>"$d/calls"
echo >>"$d/calls"
case "$1" in
ps) case "$*" in *label=riotbox.session*) f=ps-labelled ;; *) f=ps-all ;; esac ;;
container) shift 4; f="inspect-$(echo "$@" | tr ' ' '_')" ;;
*) exit 99 ;;
esac
[ ! -f "$d/$f.err" ] || cat "$d/$f.err" >&2
[ ! -f "$d/$f.out" ] || cat "$d/$f.out"
exit "$(cat "$d/$f.rc" 2>/dev/null || echo 0)"
`

type fakeEngine struct{ dir, path string }

func newFakeEngine() fakeEngine {
	dir := GinkgoT().TempDir()
	path := filepath.Join(dir, "engine")
	Expect(os.WriteFile(path, []byte(fakeEngineScript), 0o700)).To(Succeed())
	return fakeEngine{dir: dir, path: path}
}

// reply sets what the engine prints and returns for one call.
func (f fakeEngine) reply(name, stdout, stderr string, rc int) {
	Expect(os.WriteFile(filepath.Join(f.dir, name+".out"), []byte(stdout), 0o600)).To(Succeed())
	Expect(os.WriteFile(filepath.Join(f.dir, name+".err"), []byte(stderr), 0o600)).To(Succeed())
	Expect(os.WriteFile(filepath.Join(f.dir, name+".rc"), []byte(strconv.Itoa(rc)), 0o600)).To(Succeed())
}

func (f fakeEngine) calls() []string {
	content, err := os.ReadFile(filepath.Join(f.dir, "calls"))
	if os.IsNotExist(err) {
		return nil
	}
	Expect(err).NotTo(HaveOccurred())
	return strings.Split(strings.TrimSuffix(string(content), "\n"), "\n")
}

// libDir holds terminal-clean.jq, which cleans mount sources for display.
var libDir = func() string {
	dir, err := filepath.Abs(filepath.Join("..", "..", "scripts", "lib"))
	if err != nil {
		panic(err)
	}
	return dir
}()

// quad is one inspect record: ID, name, source, RW, each NUL-terminated.
func quad(id, name, source, rw string) string {
	return id + "\x00" + name + "\x00" + source + "\x00" + rw + "\x00"
}

// running lists the IDs of live containers: all, and those labelled.
func (f fakeEngine) running(all, labelled []string) {
	f.reply("ps-all", strings.Join(all, "\n")+"\n", "", 0)
	f.reply("ps-labelled", strings.Join(labelled, "\n")+"\n", "", 0)
}

var _ = Describe("Scan", func() {
	var (
		fake   fakeEngine
		stderr *bytes.Buffer
		dir    string
	)

	BeforeEach(func() {
		fake = newFakeEngine()
		stderr = &bytes.Buffer{}
		var err error
		dir, err = filepath.EvalSymlinks(GinkgoT().TempDir())
		Expect(err).NotTo(HaveOccurred())
	})

	It("returns no mounts, and asks no more, when nothing runs", func() {
		fake.reply("ps-all", "\n", "", 0)
		Expect(engine.Scan(fake.path, stderr)).To(BeEmpty())
		Expect(fake.calls()).To(Equal([]string{
			"[ps][-a][--no-trunc][--filter][status=created][--filter][status=running][--filter][status=paused][--format][{{.ID}}]",
		}))
	})

	It("lists with the bash's exact ps and inspect arguments", func() {
		fake.running([]string{"aaa", "bbb"}, []string{"bbb"})
		fake.reply("inspect-aaa_bbb", quad("aaa", "one", "/x", "true")+"\n"+quad("bbb", "two", "/y", "true")+"\n", "", 0)
		_, err := engine.Scan(fake.path, stderr)
		Expect(err).NotTo(HaveOccurred())
		Expect(fake.calls()).To(Equal([]string{
			"[ps][-a][--no-trunc][--filter][status=created][--filter][status=running][--filter][status=paused][--format][{{.ID}}]",
			"[ps][-a][--no-trunc][--filter][label=riotbox.session][--filter][status=created][--filter][status=running][--filter][status=paused][--format][{{.ID}}]",
			"[container][inspect][--format][" + inspectFormat + "][aaa][bbb]",
		}))
	})

	It("keeps which containers are labelled, and strips a leading / from names", func() {
		fake.running([]string{"aaa", "", "bbb"}, []string{"bbb"})
		fake.reply("inspect-aaa_bbb", quad("aaa", "/one", dir+"/x", "true")+"\n"+quad("bbb", "two", dir+"/y/../z", "true")+"\n", "", 0)
		Expect(engine.Scan(fake.path, stderr)).To(Equal([]engine.Mount{
			{ID: "aaa", Name: "one", Source: dir + "/x", Lexical: dir + "/x"},
			{ID: "bbb", Name: "two", Source: dir + "/z", Lexical: dir + "/z", Labelled: true},
		}))
	})

	It("canonicalises the source, and keeps the lexical form a later link would change", func() {
		Expect(os.MkdirAll(dir+"/real", 0o700)).To(Succeed())
		Expect(os.Symlink(dir+"/real", dir+"/link")).To(Succeed())
		fake.running([]string{"aaa"}, nil)
		fake.reply("inspect-aaa", quad("aaa", "one", dir+"/link/sub", "true")+"\n", "", 0)
		Expect(engine.Scan(fake.path, stderr)).To(Equal([]engine.Mount{
			{ID: "aaa", Name: "one", Source: dir + "/real/sub", Lexical: dir + "/link/sub"},
		}))
	})

	It("skips a read-only mount and a tmpfs (empty source)", func() {
		fake.running([]string{"aaa"}, []string{"aaa"})
		fake.reply("inspect-aaa", quad("aaa", "one", "/ro", "false")+quad("aaa", "one", "", "true")+
			quad("aaa", "one", "/odd", "TRUE")+quad("aaa", "one", "/rw", "true")+"\n", "", 0)
		Expect(engine.Scan(fake.path, stderr)).To(Equal([]engine.Mount{
			{ID: "aaa", Name: "one", Source: "/rw", Lexical: "/rw", Labelled: true},
		}))
	})

	It("strips the newlines the engine puts before each container's records", func() {
		fake.running([]string{"aaa", "bbb", "ccc"}, nil)
		// aaa has no mounts: its newline lands before bbb's ID as well.
		fake.reply("inspect-aaa_bbb_ccc", "\n"+quad("bbb", "b", "/b", "true")+"\n"+quad("ccc", "c", "/c", "true")+"\n\n", "", 0)
		mounts, err := engine.Scan(fake.path, stderr)
		Expect(err).NotTo(HaveOccurred())
		Expect(mounts).To(HaveLen(2))
		Expect(mounts[0].ID).To(Equal("bbb"))
		Expect(mounts[1].ID).To(Equal("ccc"))
	})

	It("accepts output with no trailing newline field", func() {
		fake.running([]string{"aaa"}, nil)
		fake.reply("inspect-aaa", quad("aaa", "a", "/a", "true"), "", 0)
		Expect(engine.Scan(fake.path, stderr)).To(HaveLen(1))
	})

	It("drops an empty last field, as the bash's newline-only check does", func() {
		fake.running([]string{"aaa"}, nil)
		// The empty RW field is the last one, so it is dropped and the
		// count is no longer a multiple of four.
		fake.reply("inspect-aaa", "aaa\x00a\x00/a\x00\x00", "", 0)
		_, err := engine.Scan(fake.path, stderr)
		Expect(err).To(HaveOccurred())
	})

	DescribeTable("fails, closed, on malformed inspect output",
		func(output string) {
			fake.running([]string{"aaa"}, nil)
			fake.reply("inspect-aaa", output, "", 0)
			_, err := engine.Scan(fake.path, stderr)
			Expect(err).To(MatchError(engine.ErrMalformed))
			Expect(stderr.String()).To(Equal("riotbox-core: malformed container inspect output\n"))
		},
		Entry("a field count that is not a multiple of four", "aaa\x00a\x00/a\x00\n"),
		Entry("a stray field after a record", quad("aaa", "a", "/a", "true")+"extra"),
		Entry("an ID of newlines only, even on a read-only mount", "\n\n\x00a\x00/a\x00false\x00\n"),
	)

	It("returns no partial result when a later record is malformed", func() {
		fake.running([]string{"aaa"}, nil)
		fake.reply("inspect-aaa", quad("aaa", "a", "/a", "true")+quad("", "b", "/b", "true"), "", 0)
		mounts, err := engine.Scan(fake.path, stderr)
		Expect(err).To(HaveOccurred())
		Expect(mounts).To(BeEmpty())
	})

	It("fails, closed, rather than hang on a mount source through a self-growing link", func() {
		Expect(os.Symlink("q/../q", dir+"/q")).To(Succeed())
		fake.running([]string{"aaa"}, nil)
		fake.reply("inspect-aaa", quad("aaa", "a", dir+"/q/x", "true")+"\n", "", 0)
		done := make(chan error, 1)
		go func() {
			_, err := engine.Scan(fake.path, stderr)
			done <- err
		}()
		var err error
		Eventually(done).WithTimeout(10 * time.Second).Should(Receive(&err))
		Expect(err).To(HaveOccurred())
		Expect(stderr.String()).To(ContainSubstring("Too many levels of symbolic links"))
	})

	It("fails, closed, when the engine cannot list containers, passing its message on", func() {
		fake.reply("ps-all", "", "cannot connect\n", 125)
		_, err := engine.Scan(fake.path, stderr)
		Expect(err).To(HaveOccurred())
		Expect(stderr.String()).To(Equal("cannot connect\n"))
	})

	It("fails, closed, when the engine cannot list labelled containers", func() {
		fake.reply("ps-all", "aaa\n", "", 0)
		fake.reply("ps-labelled", "", "", 1)
		_, err := engine.Scan(fake.path, stderr)
		Expect(err).To(HaveOccurred())
		Expect(fake.calls()).To(HaveLen(2))
	})

	It("fails, closed, when the engine is not there", func() {
		_, err := engine.Scan(filepath.Join(fake.dir, "no-such-engine"), stderr)
		Expect(err).To(HaveOccurred())
		Expect(stderr.String()).To(ContainSubstring("no-such-engine"))
	})

	DescribeTable("on a batch failure, inspects one by one and skips a container that is gone",
		func(goneErr string, goneRC int) {
			fake.running([]string{"aaa", "gone", "ccc"}, nil)
			fake.reply("inspect-aaa_gone_ccc", quad("aaa", "a", "/a", "true"), goneErr, goneRC)
			fake.reply("inspect-aaa", quad("aaa", "a", "/a", "true")+"\n", "", 0)
			fake.reply("inspect-gone", "\n", goneErr, goneRC)
			fake.reply("inspect-ccc", quad("ccc", "c", "/c", "true")+"\n", "", 0)
			mounts, err := engine.Scan(fake.path, stderr)
			Expect(err).NotTo(HaveOccurred())
			Expect(mounts).To(Equal([]engine.Mount{
				{ID: "aaa", Name: "a", Source: "/a", Lexical: "/a"},
				{ID: "ccc", Name: "c", Source: "/c", Lexical: "/c"},
			}))
			Expect(stderr.String()).To(BeEmpty())
			Expect(fake.calls()).To(HaveLen(6))
		},
		Entry("podman", "Error: no such object: \"gone\"\n", 125),
		Entry("docker, object", "Error: No such object: gone\n", 1),
		Entry("docker, container", "Error: No such container: gone\n", 1),
	)

	It("fails, closed, when one container's inspection fails another way, printing why", func() {
		fake.running([]string{"aaa", "bad"}, nil)
		fake.reply("inspect-aaa_bad", "", "boom\n", 125)
		fake.reply("inspect-aaa", quad("aaa", "a", "/a", "true")+"\n", "", 0)
		fake.reply("inspect-bad", "", "Error: permission denied\n", 125)
		_, err := engine.Scan(fake.path, stderr)
		Expect(err).To(HaveOccurred())
		Expect(stderr.String()).To(Equal("Error: permission denied\n"))
	})

	It("fails, closed, when one container's output is malformed in the fallback", func() {
		fake.running([]string{"aaa"}, nil)
		fake.reply("inspect-aaa", "x\x00", "", 0)
		_, err := engine.Scan(fake.path, stderr)
		Expect(err).To(HaveOccurred())
		Expect(stderr.String()).To(Equal("riotbox-core: malformed container inspect output\n"))
	})

	It("says nothing of a malformed batch answer when the fallback succeeds", func() {
		fake.running([]string{"aaa", "bbb"}, nil)
		fake.reply("inspect-aaa_bbb", "x\x00", "", 0)
		fake.reply("inspect-aaa", quad("aaa", "a", "/a", "true")+"\n", "", 0)
		fake.reply("inspect-bbb", quad("bbb", "b", "/b", "true")+"\n", "", 0)
		mounts, err := engine.Scan(fake.path, stderr)
		Expect(err).NotTo(HaveOccurred())
		Expect(mounts).To(HaveLen(2))
		Expect(stderr.String()).To(BeEmpty())
	})
})

var _ = Describe("Reaches and Overlaps", func() {
	DescribeTable("Reaches",
		func(labelled bool, source, lexical, path, pathLexical string, want bool) {
			m := engine.Mount{ID: "i", Source: source, Lexical: lexical, Labelled: labelled}
			Expect(engine.Reaches(m, path, pathLexical)).To(Equal(want))
		},
		Entry("labelled: the path itself", true, "/s/d", "/s/d", "/s/d", "/s/d", true),
		Entry("labelled: inside the path", true, "/s/d/x", "/s/d/x", "/s/d", "/s/d", true),
		Entry("labelled: an ancestor of the path", true, "/s", "/s", "/s/d", "/s/d", true),
		Entry("labelled: the root", true, "/", "/", "/s/d", "/s/d", true),
		Entry("labelled: a sibling sharing a prefix", true, "/s/dd", "/s/dd", "/s/d", "/s/d", false),
		Entry("labelled: unrelated", true, "/t", "/t", "/s/d", "/s/d", false),
		Entry("labelled: only the lexical forms overlap", true, "/r", "/s/d/x", "/s/d", "/s/d", true),
		Entry("labelled: lexical source against resolved path does not count", true, "/r", "/s/d", "/s/d", "/q", false),
		Entry("unlabelled: the path itself", false, "/s/d", "/s/d", "/s/d", "/s/d", true),
		Entry("unlabelled: inside the path", false, "/s/d/x", "/s/d/x", "/s/d", "/s/d", true),
		Entry("unlabelled: an ancestor does not count", false, "/s", "/s", "/s/d", "/s/d", false),
		Entry("unlabelled: the root does not count", false, "/", "/", "/s/d", "/s/d", false),
		Entry("unlabelled: a sibling sharing a prefix", false, "/s/dd", "/s/dd", "/s/d", "/s/d", false),
		Entry("unlabelled: only the lexical forms match", false, "/r", "/s/d/x", "/s/d", "/s/d", true),
		Entry("unlabelled: the path is the root", false, "/a", "/a", "/", "/", true),
	)

	DescribeTable("Overlaps ignores the label",
		func(labelled bool) {
			m := engine.Mount{ID: "i", Source: "/s", Lexical: "/s", Labelled: labelled}
			Expect(engine.Overlaps(m, "/s/d", "/s/d")).To(BeTrue())
			Expect(engine.Overlaps(m, "/t", "/t")).To(BeFalse())
		},
		Entry("labelled", true),
		Entry("unlabelled", false),
	)

	It("labels a mount by its name, else the first 12 characters of its ID", func() {
		Expect(engine.Mount{ID: "0123456789abcdef", Name: "n"}.Label()).To(Equal("n"))
		Expect(engine.Mount{ID: "0123456789abcdef"}.Label()).To(Equal("0123456789ab"))
		Expect(engine.Mount{ID: "short"}.Label()).To(Equal("short"))
	})
})

// The case session-state.venom.yml used to run on running_session_mounts and
// running_mount_reaches directly.
var _ = Describe("a mount whose path a link replaced after the container started", func() {
	It("still reaches the state dir, and does not reach an unrelated one", func() {
		fake := newFakeEngine()
		dir, err := filepath.EvalSymlinks(GinkgoT().TempDir())
		Expect(err).NotTo(HaveOccurred())
		state := dir + "/state"
		Expect(os.MkdirAll(state+"/git-ai", 0o700)).To(Succeed())
		Expect(os.MkdirAll(dir+"/elsewhere", 0o700)).To(Succeed())
		// The container was given state/git-ai; then git-ai became a link
		// out of the state dir. The container still writes the old dir.
		fake.running([]string{"old1"}, nil)
		fake.reply("inspect-old1", quad("old1", "old1", state+"/git-ai", "true")+"\n", "", 0)
		Expect(os.Rename(state+"/git-ai", dir+"/moved")).To(Succeed())
		Expect(os.Symlink(dir+"/elsewhere", state+"/git-ai")).To(Succeed())
		mounts, err := engine.Scan(fake.path, &bytes.Buffer{})
		Expect(err).NotTo(HaveOccurred())
		Expect(mounts).To(HaveLen(1))
		Expect(mounts[0].Source).To(Equal(dir + "/elsewhere"))
		Expect(engine.Reaches(mounts[0], state, state)).To(BeTrue(), "the resolved source hid the mount")
		Expect(engine.Reaches(mounts[0], dir+"/unrelated", dir+"/unrelated")).To(BeFalse())
	})
})

var _ = Describe("RefuseIfRunning", func() {
	var (
		fake           fakeEngine
		w              *bytes.Buffer
		session, state string
	)

	BeforeEach(func() {
		fake = newFakeEngine()
		w = &bytes.Buffer{}
		dir, err := filepath.EvalSymlinks(GinkgoT().TempDir())
		Expect(err).NotTo(HaveOccurred())
		session, state = dir+"/data/key", dir+"/state/key"
		Expect(os.MkdirAll(session, 0o700)).To(Succeed())
		Expect(os.MkdirAll(state, 0o700)).To(Succeed())
	})

	It("passes, silently, when nothing reaches the session or state dir", func() {
		fake.running([]string{"aaa"}, []string{"aaa"})
		fake.reply("inspect-aaa", quad("aaa", "a", "/elsewhere", "true")+quad("aaa", "a", state, "false")+"\n", "", 0)
		Expect(engine.RefuseIfRunning(w, fake.path, libDir, session, state, "", "")).To(Succeed())
		Expect(w.String()).To(BeEmpty())
	})

	It("refuses, once per container, naming its first reaching mount and the recorded projects", func() {
		Expect(os.WriteFile(state+"/projects", []byte("/p one\n/p2\n"), 0o600)).To(Succeed())
		fake.running([]string{"aaa", "0123456789abcdef"}, []string{"aaa"})
		fake.reply("inspect-aaa_0123456789abcdef",
			quad("aaa", "/web", state+"/git-ai", "true")+quad("aaa", "/web", session, "true")+"\n"+
				quad("0123456789abcdef", "", session+"/x", "true")+"\n", "", 0)
		Expect(engine.RefuseIfRunning(w, fake.path, libDir, session, state, "", "")).NotTo(Succeed())
		Expect(w.String()).To(Equal(
			"ERROR: container web mounts " + state + "/git-ai read-write, which reaches the session of /p\\ one /p2, and is still running.\n" +
				"ERROR: container 0123456789ab mounts " + session + "/x read-write, which reaches the session of /p\\ one /p2, and is still running.\n" +
				"       It can still write to what session-migrate would move. Stop that container (exit its session), then run riotbox session-migrate again.\n"))
	})

	It("names the session dir when there is no record, and uses the given mover and retry", func() {
		fake.running([]string{"aaa"}, nil)
		fake.reply("inspect-aaa", quad("aaa", "a", session, "true")+"\n", "", 0)
		err := engine.RefuseIfRunning(w, fake.path, libDir, session, state, "RiotBox's move to the new session key", "launch again")
		Expect(err).To(HaveOccurred())
		Expect(w.String()).To(Equal(
			"ERROR: container a mounts " + session + " read-write, which reaches the session of " + session + ", and is still running.\n" +
				"       It can still write to what RiotBox's move to the new session key would move. Stop that container (exit its session), then launch again.\n"))
	})

	It("refuses, failing closed, when the engine cannot answer", func() {
		fake.reply("ps-all", "", "cannot connect\n", 125)
		Expect(engine.RefuseIfRunning(w, fake.path, libDir, session, state, "", "")).NotTo(Succeed())
		Expect(w.String()).To(Equal("cannot connect\n" +
			"ERROR: could not ask '" + fake.path + "' whether a running container mounts the session of " + session + ".\n" +
			"       session-migrate refuses while it cannot tell: a running session can still write to what it would move.\n" +
			"       Make sure the container engine works (and that the session has exited), then retry.\n"))
	})

	It("cleans the mount source it names, as a container can shape it", func() {
		fake.running([]string{"aaa"}, nil)
		fake.reply("inspect-aaa", quad("aaa", "a", session+"/\x1b[31mx\ny", "true")+"\n", "", 0)
		Expect(engine.RefuseIfRunning(w, fake.path, libDir, session, state, "", "")).NotTo(Succeed())
		Expect(w.String()).To(HavePrefix("ERROR: container a mounts " + session + "/?[31mx?y read-write, which reaches the session of "))
		Expect(w.String()).NotTo(ContainSubstring("\x1b"))
	})

	It("names the mount source by the placeholder when it cannot be cleaned", func() {
		fake.running([]string{"aaa"}, nil)
		fake.reply("inspect-aaa", quad("aaa", "a", session+"/\x1b[31mx", "true")+"\n", "", 0)
		Expect(engine.RefuseIfRunning(w, fake.path, GinkgoT().TempDir(), session, state, "", "")).NotTo(Succeed())
		Expect(w.String()).To(ContainSubstring("ERROR: container a mounts (name not shown) read-write, which reaches the session of "))
		Expect(w.String()).NotTo(ContainSubstring("\x1b"))
	})

	It("does not let an unlabelled container mounting an ancestor block it", func() {
		fake.running([]string{"toolbox"}, nil)
		fake.reply("inspect-toolbox", quad("toolbox", "toolbox", "/", "true")+"\n", "", 0)
		Expect(engine.RefuseIfRunning(w, fake.path, libDir, session, state, "", "")).To(Succeed())
	})

	It("refuses for a labelled container mounting an ancestor", func() {
		fake.running([]string{"proj"}, []string{"proj"})
		fake.reply("inspect-proj", quad("proj", "proj", filepath.Dir(filepath.Dir(state)), "true")+"\n", "", 0)
		Expect(engine.RefuseIfRunning(w, fake.path, libDir, session, state, "", "")).NotTo(Succeed())
		Expect(w.String()).To(ContainSubstring("ERROR: container proj mounts "))
	})
})

var _ = Describe("OverlayUsers", func() {
	It("names the holders of the overlay once each, and the other mounts overlapping the project", func() {
		fake := newFakeEngine()
		overlay, project := "/st/key/overlay/app", "/home/u/app"
		fake.running([]string{"h", "s", "t", "u"}, []string{"h", "s"})
		fake.reply("inspect-h_s_t_u",
			quad("h", "/holder", overlay+"/upper", "true")+quad("h", "/holder", overlay, "true")+"\n"+
				quad("s", "sibling", project, "true")+"\n"+
				quad("t", "", "/home/u", "true")+quad("t", "", "/st", "true")+"\n"+
				quad("u", "far", "/other", "true")+"\n", "", 0)
		holders, sharers, err := engine.OverlayUsers(fake.path, libDir, overlay, project, &bytes.Buffer{})
		Expect(err).NotTo(HaveOccurred())
		Expect(holders).To(Equal([]string{"holder"}))
		Expect(sharers).To(Equal([]string{"sibling " + project, "t /home/u"}))
	})

	It("cleans a sharer's mount source, as a container can shape it", func() {
		fake := newFakeEngine()
		project, err := filepath.EvalSymlinks(GinkgoT().TempDir())
		Expect(err).NotTo(HaveOccurred())
		fake.running([]string{"s"}, nil)
		fake.reply("inspect-s", quad("s", "sib", project+"/\x1b[31mx\ny", "true")+"\n", "", 0)
		var stderr bytes.Buffer
		_, sharers, err := engine.OverlayUsers(fake.path, libDir, "/o", project, &stderr)
		Expect(err).NotTo(HaveOccurred())
		Expect(sharers).To(Equal([]string{"sib " + project + "/?[31mx?y"}))
		Expect(stderr.String()).To(BeEmpty())
	})

	It("fails, closed, when the engine cannot answer", func() {
		fake := newFakeEngine()
		fake.reply("ps-all", "", "", 125)
		_, _, err := engine.OverlayUsers(fake.path, libDir, "/o", "/p", &bytes.Buffer{})
		Expect(err).To(HaveOccurred())
	})
})
