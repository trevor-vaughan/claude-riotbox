package hostlink_test

import (
	"os"
	"path/filepath"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/trevor-vaughan/claude-riotbox/internal/egress/hostlink"
	"github.com/trevor-vaughan/claude-riotbox/internal/egress/policy"
)

var _ = Describe("the ports file", func() {
	It("renders the host-loopback tunnel entries alone, one port or range per line", func() {
		entries := []policy.Entry{
			{Host: "example.com", Port: 443},
			{Host: policy.HostLink, Port: 18000},
			{Host: policy.HostLink, Port: 18100, PortEnd: 18199},
			{Host: "*.internal", Port: 443},
		}
		Expect(string(hostlink.RenderPorts(entries))).To(Equal("18000\n18100-18199\n"))
	})

	It("renders every port as 1-65535", func() {
		Expect(string(hostlink.RenderPorts([]policy.Entry{{Host: policy.HostLink, Port: 1, PortEnd: 65535}}))).To(Equal("1-65535\n"))
	})

	It("ignores a plain host-loopback entry, which never gets a port", func() {
		entries := []policy.Entry{{Host: policy.HostLink, Port: 80, Plain: true}, {Host: policy.HostLink, Port: 2222}}
		Expect(string(hostlink.RenderPorts(entries))).To(Equal("2222\n"))
	})

	It("renders nothing without host-loopback entries", func() {
		Expect(hostlink.RenderPorts([]policy.Entry{{Host: "example.com", Port: 443}})).To(BeEmpty())
	})

	It("reads back what it renders", func() {
		p, err := hostlink.ParsePorts([]byte("18000\n18100-18199\n"))
		Expect(err).NotTo(HaveOccurred())
		Expect(p).To(Equal(hostlink.Ports{{Lo: 18000, Hi: 18000}, {Lo: 18100, Hi: 18199}}))
		Expect(p.Has(18000)).To(BeTrue())
		Expect(p.Has(18150)).To(BeTrue())
		Expect(p.Has(18001)).To(BeFalse())
		Expect(p.Has(18200)).To(BeFalse())
	})

	It("reads an empty file as no ports", func() {
		p, err := hostlink.ParsePorts(nil)
		Expect(err).NotTo(HaveOccurred())
		Expect(p.Has(1)).To(BeFalse())
	})

	DescribeTable("refuses the whole file on any malformed line",
		func(data string) {
			_, err := hostlink.ParsePorts([]byte(data))
			Expect(err).To(HaveOccurred())
		},
		Entry("zero", "0\n"),
		Entry("no final newline", "22"),
		Entry("leading zero", "0443\n"),
		Entry("too high", "65536\n"),
		Entry("range too high", "65000-65536\n"),
		Entry("reversed range", "200-100\n"),
		Entry("text", "ssh\n"),
		Entry("blank line", "22\n\n23\n"),
		Entry("space", "22 \n"),
		Entry("a trailing blank line", "22\n\n"),
	)

	It("loads a missing file as no ports, and a present one by its content", func() {
		path := filepath.Join(GinkgoT().TempDir(), hostlink.PortsFile)
		p, err := hostlink.LoadPorts(path)
		Expect(err).NotTo(HaveOccurred())
		Expect(p).To(BeEmpty())
		Expect(os.WriteFile(path, []byte("22\n"), 0o600)).To(Succeed())
		p, err = hostlink.LoadPorts(path)
		Expect(err).NotTo(HaveOccurred())
		Expect(p.Has(22)).To(BeTrue())
	})
})
