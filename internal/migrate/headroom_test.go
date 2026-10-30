package migrate_test

import (
	"os"
	"strings"
	"syscall"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gbytes"

	"github.com/trevor-vaughan/claude-riotbox/internal/migrate"
)

var _ = Describe("HeadroomNotice (notice_project_headroom)", func() {
	var proj string

	BeforeEach(func() {
		proj = tmp + "/proj"
		mkdirs(proj, state)
	})

	It("prints the notice for a project .headroom once, and records that it checked", func() {
		mkdirs(proj + "/.headroom")
		Expect(migrate.HeadroomNotice(errOut, libDir, proj, state)).To(Succeed())
		Expect(errOut.String()).To(Equal(
			"Notice: " + proj + "/.headroom may hold headroom memory from an older RiotBox.\n" +
				"        It was written into the project; RiotBox leaves it alone.\n" +
				"        RiotBox now keeps headroom memory in " + state + "/headroom. To delete the old copy:\n" +
				"          rm -rf -- " + proj + "/.headroom\n" +
				"        To keep it instead, exit every RiotBox session of this project, then replace the\n" +
				"        memory the new location holds (its SQLite -wal/-shm files included) with it:\n" +
				"          rm -rf -- " + state + "/headroom/memory*.db* " + state + "/headroom/memories && cp -a -- " + proj + "/.headroom/. " + state + "/headroom/ && rm -rf -- " + proj + "/.headroom\n" +
				"        If .headroom/ was committed, untrack it and add it to .gitignore:\n" +
				"          git -C " + proj + " rm -r --cached -- .headroom && echo .headroom/ >>" + proj + "/.gitignore\n" +
				"        This notice is shown once per session.\n"))
		Expect(read(state + "/.migrated")).To(Equal("project-headroom-notice\n"))

		errOut.Reset()
		Expect(migrate.HeadroomNotice(errOut, libDir, proj, state)).To(Succeed())
		Expect(errOut.String()).To(BeEmpty())
		Expect(read(state + "/.migrated")).To(Equal("project-headroom-notice\n"))
	})

	It("waits for the session's migrate lock, so concurrent launches print it once", func() {
		mkdirs(proj + "/.headroom")
		held, err := os.OpenFile(state+"/.migrate.lock", os.O_WRONLY|os.O_CREATE, 0o600)
		Expect(err).NotTo(HaveOccurred())
		defer func() { _ = held.Close() }()
		Expect(syscall.Flock(int(held.Fd()), syscall.LOCK_EX)).To(Succeed())
		out := gbytes.NewBuffer()
		done := make(chan error, 1)
		go func() { done <- migrate.HeadroomNotice(out, libDir, proj, state) }()
		Eventually(out).Should(gbytes.Say("^Waiting for another RiotBox command on this session to finish migrating its state…\n"))
		Consistently(done, "200ms").ShouldNot(Receive())
		Expect(exists(state + "/.migrated")).To(BeFalse())
		Expect(syscall.Flock(int(held.Fd()), syscall.LOCK_UN)).To(Succeed())
		Eventually(done).Should(Receive(BeNil()))
		Expect(out).To(gbytes.Say("Notice: " + proj + "/.headroom may hold headroom memory"))
	})

	It("records the check, silently, when there is nothing to notice", func() {
		write(state+"/.migrated", "headroom")
		Expect(migrate.HeadroomNotice(errOut, libDir, proj, state)).To(Succeed())
		Expect(errOut.String()).To(BeEmpty())
		Expect(read(state + "/.migrated")).To(Equal("headroom\nproject-headroom-notice\n"))
	})

	It("prints the overlay variant for an overlay upper, without git advice", func() {
		up := state + "/overlay/project/upper/.headroom"
		mkdirs(up)
		Expect(migrate.HeadroomNotice(errOut, libDir, proj, state)).To(Succeed())
		Expect(errOut.String()).To(Equal(
			"Notice: " + up + " may hold headroom memory from an older RiotBox.\n" +
				"        It was written into this session's overlay; overlay-accept never copies it into\n" +
				"        the project, and overlay-reject keeps it.\n" +
				"        RiotBox now keeps headroom memory in " + state + "/headroom. To delete the old copy:\n" +
				"          rm -rf -- " + up + "\n" +
				"        To keep it instead, exit every RiotBox session of this project, then replace the\n" +
				"        memory the new location holds (its SQLite -wal/-shm files included) with it:\n" +
				"          rm -rf -- " + state + "/headroom/memory*.db* " + state + "/headroom/memories && cp -a -- " + up + "/. " + state + "/headroom/ && rm -rf -- " + up + "\n" +
				"        This notice is shown once per session.\n"))
	})

	It("skips a link at .headroom, at upper, or at the overlay's name, and never follows one", func() {
		mkdirs(state + "/overlay/other/upper")
		Expect(os.Symlink(victim, proj+"/.headroom")).To(Succeed())
		Expect(os.Symlink(proj, state+"/overlay/other/upper/.headroom")).To(Succeed())
		mkdirs(tmp+"/upper-target/.headroom", state+"/overlay/linked", tmp+"/name-target/upper/.headroom")
		Expect(os.Symlink(tmp+"/upper-target", state+"/overlay/linked/upper")).To(Succeed())
		Expect(os.Symlink(tmp+"/name-target", state+"/overlay/named")).To(Succeed())
		Expect(migrate.HeadroomNotice(errOut, libDir, proj, state)).To(Succeed())
		Expect(errOut.String()).To(BeEmpty())
		Expect(read(state + "/.migrated")).To(Equal("project-headroom-notice\n"))
		expectVictimIntact()
	})

	It("reports a copy in an overlay whose name starts with a dot", func() {
		mkdirs(state + "/overlay/.dotfiles/upper/.headroom")
		Expect(migrate.HeadroomNotice(errOut, libDir, proj, state)).To(Succeed())
		Expect(errOut.String()).To(HavePrefix("Notice: " + state + "/overlay/.dotfiles/upper/.headroom may hold headroom memory from an older RiotBox.\n"))
	})

	It("prints one footer for several copies", func() {
		mkdirs(proj+"/.headroom", state+"/overlay/a/upper/.headroom", state+"/overlay/b/upper/.headroom")
		Expect(migrate.HeadroomNotice(errOut, libDir, proj, state)).To(Succeed())
		Expect(lineCount(errOut.String(), "may hold headroom memory")).To(Equal(3))
		Expect(lineCount(errOut.String(), "shown once per session")).To(Equal(1))
		Expect(strings.Index(errOut.String(), "/overlay/a/")).To(BeNumerically("<", strings.Index(errOut.String(), "/overlay/b/")))
	})

	It("cleans a container-chosen overlay name in the notice line, and still quotes it in the commands", func() {
		name := "\x1b[31mred\nx"
		mkdirs(state + "/overlay/" + name + "/upper/.headroom")
		Expect(migrate.HeadroomNotice(errOut, libDir, proj, state)).To(Succeed())
		Expect(errOut.String()).To(HavePrefix("Notice: " + state + "/overlay/?[31mred?x/upper/.headroom may hold headroom memory from an older RiotBox.\n"))
		Expect(errOut.String()).To(ContainSubstring("\n          rm -rf -- $'" + state + "/overlay/\\E[31mred\\nx/upper/.headroom'\n"))
		Expect(errOut.String()).NotTo(ContainSubstring("\x1b"))
	})

	It("shows a placeholder for the overlay name when it cannot be cleaned", func() {
		mkdirs(state + "/overlay/\x1b[31mred/upper/.headroom")
		Expect(migrate.HeadroomNotice(errOut, tmp+"/no-lib", proj, state)).To(Succeed())
		Expect(errOut.String()).To(ContainSubstring("Notice: " + state + "/overlay/(name not shown)/upper/.headroom may hold headroom memory from an older RiotBox.\n"))
		Expect(errOut.String()).NotTo(ContainSubstring("\x1b"))
		Expect(read(state + "/.migrated")).To(Equal("project-headroom-notice\n"))
	})

	It("quotes a project path with spaces and shell metacharacters", func() {
		odd := tmp + "/my proj $(x);y"
		mkdirs(odd + "/.headroom")
		Expect(migrate.HeadroomNotice(errOut, libDir, odd, state)).To(Succeed())
		q := tmp + "/my\\ proj\\ \\$\\(x\\)\\;y"
		Expect(errOut.String()).To(ContainSubstring("\n          rm -rf -- " + q + "/.headroom\n"))
		Expect(errOut.String()).To(ContainSubstring("\n          git -C " + q + " rm -r --cached -- .headroom && echo .headroom/ >>" + q + "/.gitignore\n"))
	})

	It("fails when the check cannot be recorded", func() {
		skipIfRoot()
		mkdirs(proj + "/.headroom")
		Expect(os.WriteFile(state+"/.migrate.lock", nil, 0o600)).To(Succeed())
		Expect(os.Chmod(state, 0o500)).To(Succeed())
		Expect(migrate.HeadroomNotice(errOut, libDir, proj, state)).NotTo(Succeed())
		Expect(errOut.String()).To(ContainSubstring("may hold headroom memory"))
		Expect(exists(state + "/.migrated")).To(BeFalse())
	})
})
