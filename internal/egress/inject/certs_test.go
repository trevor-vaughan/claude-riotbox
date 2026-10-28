package inject_test

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"math/big"
	"net"
	"reflect"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/trevor-vaughan/claude-riotbox/internal/egress/inject"
)

// parseCert decodes data, which must be exactly one CERTIFICATE PEM block.
func parseCert(data []byte) *x509.Certificate {
	block, rest := pem.Decode(data)
	ExpectWithOffset(1, block).NotTo(BeNil())
	ExpectWithOffset(1, block.Type).To(Equal("CERTIFICATE"))
	ExpectWithOffset(1, rest).To(BeEmpty())
	c, err := x509.ParseCertificate(block.Bytes)
	ExpectWithOffset(1, err).NotTo(HaveOccurred())
	return c
}

var _ = Describe("NewCerts", func() {
	now := time.Date(2026, 10, 26, 12, 0, 0, 0, time.UTC)
	hosts := []string{"api.anthropic.com", "api.openai.com"}
	var (
		certs inject.Certs
		ca    *x509.Certificate
		roots *x509.CertPool
	)

	BeforeEach(func() {
		var err error
		certs, err = inject.NewCerts("s1", hosts, now)
		Expect(err).NotTo(HaveOccurred())
		ca = parseCert(certs.CA)
		roots = x509.NewCertPool()
		roots.AddCert(ca)
	})

	It("makes a P-256 CA that signs only leaves, for only the session's hosts, for 30 days", func() {
		Expect(ca.IsCA).To(BeTrue())
		Expect(ca.BasicConstraintsValid).To(BeTrue())
		Expect(ca.MaxPathLen).To(Equal(0))
		Expect(ca.MaxPathLenZero).To(BeTrue())
		Expect(ca.KeyUsage).To(Equal(x509.KeyUsageCertSign))
		Expect(ca.ExtKeyUsage).To(BeEmpty())
		Expect(ca.PermittedDNSDomainsCritical).To(BeTrue())
		Expect(ca.PermittedDNSDomains).To(Equal(hosts))
		Expect(ca.ExcludedDNSDomains).To(BeEmpty())
		Expect(ca.PermittedIPRanges).To(BeEmpty())
		Expect(ca.ExcludedIPRanges).To(HaveLen(2))
		Expect(ca.ExcludedIPRanges[0].String()).To(Equal("0.0.0.0/0"))
		Expect(ca.ExcludedIPRanges[1].String()).To(Equal("::/0"))
		Expect(ca.PermittedEmailAddresses).To(BeEmpty())
		Expect(ca.PermittedURIDomains).To(BeEmpty())
		Expect(ca.Subject.CommonName).To(Equal("RiotBox egress s1"))
		Expect(ca.NotBefore).To(BeTemporally("==", now.Add(-inject.CertBackdate)))
		Expect(ca.NotAfter).To(BeTemporally("==", now.Add(inject.CertValidity)))
		Expect(inject.CertValidity).To(Equal(30 * 24 * time.Hour))
		Expect(inject.CertBackdate).To(Equal(5 * time.Minute))
		Expect(ca.PublicKey.(*ecdsa.PublicKey).Curve).To(Equal(elliptic.P256()))
		Expect(ca.SignatureAlgorithm).To(Equal(x509.ECDSAWithSHA256))
		Expect(ca.SerialNumber.Sign()).To(Equal(1))
	})

	It("makes one server leaf per host that verifies against the CA for that host alone, until it expires", func() {
		Expect(certs.Leaves).To(HaveLen(len(hosts)))
		for _, h := range hosts {
			leaf := parseCert(certs.Leaves[h].Cert)
			Expect(leaf.DNSNames).To(Equal([]string{h}))
			Expect(leaf.IPAddresses).To(BeEmpty())
			Expect(leaf.EmailAddresses).To(BeEmpty())
			Expect(leaf.URIs).To(BeEmpty())
			Expect(leaf.IsCA).To(BeFalse())
			Expect(leaf.KeyUsage).To(Equal(x509.KeyUsageDigitalSignature))
			Expect(leaf.ExtKeyUsage).To(Equal([]x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}))
			Expect(leaf.PublicKey.(*ecdsa.PublicKey).Curve).To(Equal(elliptic.P256()))
			Expect(leaf.SerialNumber.Sign()).To(Equal(1))
			Expect(leaf.SerialNumber).NotTo(Equal(ca.SerialNumber))
			Expect(leaf.NotBefore).To(BeTemporally("==", now.Add(-inject.CertBackdate)))
			Expect(leaf.NotAfter).To(BeTemporally("==", now.Add(inject.CertValidity)))
			Expect(leaf.NotAfter).To(BeTemporally("<=", ca.NotAfter))
			Expect(leaf.CheckSignatureFrom(ca)).To(Succeed())
			_, err := leaf.Verify(x509.VerifyOptions{DNSName: h, Roots: roots, CurrentTime: now})
			Expect(err).NotTo(HaveOccurred())
			_, err = leaf.Verify(x509.VerifyOptions{DNSName: h, Roots: roots, CurrentTime: now.Add(-inject.CertBackdate)})
			Expect(err).NotTo(HaveOccurred())
			_, err = leaf.Verify(x509.VerifyOptions{DNSName: "other.example", Roots: roots, CurrentTime: now})
			Expect(err).To(HaveOccurred())
			_, err = leaf.Verify(x509.VerifyOptions{DNSName: h, Roots: roots, CurrentTime: now.Add(-inject.CertBackdate - time.Second)})
			Expect(err).To(HaveOccurred())
			_, err = leaf.Verify(x509.VerifyOptions{DNSName: h, Roots: roots, CurrentTime: now.Add(inject.CertValidity + time.Second)})
			Expect(err).To(HaveOccurred())
		}
	})

	It("does not verify a leaf against a different session's CA", func() {
		other, err := inject.NewCerts("s2", hosts, now)
		Expect(err).NotTo(HaveOccurred())
		otherRoots := x509.NewCertPool()
		otherRoots.AddCert(parseCert(other.CA))
		_, err = parseCert(certs.Leaves[hosts[0]].Cert).Verify(x509.VerifyOptions{DNSName: hosts[0], Roots: otherRoots, CurrentTime: now})
		var unknown x509.UnknownAuthorityError
		Expect(errors.As(err, &unknown)).To(BeTrue(), "%v", err)
	})

	It("pairs each leaf with its own PKCS#8 key, never the CA's, and puts no key in the CA's PEM", func() {
		for _, h := range hosts {
			block, rest := pem.Decode(certs.Leaves[h].Key)
			Expect(block).NotTo(BeNil())
			Expect(block.Type).To(Equal("PRIVATE KEY"))
			Expect(rest).To(BeEmpty())
			key, err := x509.ParsePKCS8PrivateKey(block.Bytes)
			Expect(err).NotTo(HaveOccurred())
			pub := &key.(*ecdsa.PrivateKey).PublicKey
			Expect(pub.Equal(parseCert(certs.Leaves[h].Cert).PublicKey)).To(BeTrue())
			Expect(pub.Equal(ca.PublicKey)).To(BeFalse())
		}
		Expect(string(certs.CA)).NotTo(ContainSubstring("PRIVATE KEY"))
	})

	It("returns only PEM bytes, so the CA's private key cannot leave the package", func() {
		byteSlice := reflect.TypeFor[[]byte]()
		certsType := reflect.TypeFor[inject.Certs]()
		Expect(certsType.NumField()).To(Equal(2))
		Expect(certsType.Field(0).Name).To(Equal("CA"))
		Expect(certsType.Field(0).Type).To(Equal(byteSlice))
		Expect(certsType.Field(1).Name).To(Equal("Leaves"))
		Expect(certsType.Field(1).Type).To(Equal(reflect.TypeFor[map[string]inject.Leaf]()))
		leafType := reflect.TypeFor[inject.Leaf]()
		Expect(leafType.NumField()).To(Equal(2))
		for i := range leafType.NumField() {
			Expect(leafType.Field(i).Type).To(Equal(byteSlice))
		}
		Expect(certsType.NumMethod()).To(Equal(0))
		Expect(leafType.NumMethod()).To(Equal(0))
	})

	It("makes a new CA, with a new key and serial, each time", func() {
		again, err := inject.NewCerts("s1", hosts, now)
		Expect(err).NotTo(HaveOccurred())
		other := parseCert(again.CA)
		Expect(other.SerialNumber).NotTo(Equal(ca.SerialNumber))
		Expect(other.PublicKey.(*ecdsa.PublicKey).Equal(ca.PublicKey)).To(BeFalse())
	})

	It("refuses to make a CA for no hosts, which would vouch for every name", func() {
		for _, none := range [][]string{nil, {}} {
			certs, err := inject.NewCerts("s1", none, now)
			Expect(err).To(MatchError("refusing to make a session CA for no hosts"))
			Expect(certs.CA).To(BeNil())
			Expect(certs.Leaves).To(BeNil())
		}
	})

	DescribeTable("refuses a host that would widen or blur the CA's name constraints, naming it",
		func(bad []string, msg string) {
			certs, err := inject.NewCerts("s1", bad, now)
			Expect(err).To(MatchError(msg))
			Expect(certs.CA).To(BeNil())
			Expect(certs.Leaves).To(BeNil())
		},
		Entry("an empty host, which permits every name", []string{"api.openai.com", ""},
			`refusing to make a session CA for host "": it is empty`),
		Entry("an IPv4 literal", []string{"127.0.0.1"},
			`refusing to make a session CA for host "127.0.0.1": it is an IP address`),
		Entry("an IPv6 literal", []string{"::1"},
			`refusing to make a session CA for host "::1": it is an IP address`),
		Entry("a leading dot", []string{".anthropic.com"},
			`refusing to make a session CA for host ".anthropic.com": it starts with a dot`),
		Entry("a wildcard", []string{"*.anthropic.com"},
			`refusing to make a session CA for host "*.anthropic.com": it holds a wildcard`),
		Entry("an inner wildcard", []string{"api.*.com"},
			`refusing to make a session CA for host "api.*.com": it holds a wildcard`),
		Entry("upper case", []string{"API.anthropic.com"},
			`refusing to make a session CA for host "API.anthropic.com": it is not lower case`),
		Entry("a repeat", []string{"api.anthropic.com", "api.openai.com", "api.anthropic.com"},
			`refusing to make a session CA for host "api.anthropic.com": it is listed twice`),
	)
})

var _ = Describe("an empty permitted DNS constraint", func() {
	It("would let a CA vouch for any name, which is why NewCerts refuses an empty host", func() {
		now := time.Date(2026, 10, 26, 12, 0, 0, 0, time.UTC)
		ca, key, err := inject.NewCA("s1", []string{""}, now)
		Expect(err).NotTo(HaveOccurred())
		roots := x509.NewCertPool()
		roots.AddCert(ca)
		out, err := inject.NewLeaf(ca, key, "www.google.com", now)
		Expect(err).NotTo(HaveOccurred())
		_, err = parseCert(out.Cert).Verify(x509.VerifyOptions{DNSName: "www.google.com", Roots: roots, CurrentTime: now})
		Expect(err).NotTo(HaveOccurred())
	})
})

var _ = Describe("the session CA's name constraints", func() {
	now := time.Date(2026, 10, 26, 12, 0, 0, 0, time.UTC)
	var (
		ca    *x509.Certificate
		key   *ecdsa.PrivateKey
		roots *x509.CertPool
	)

	BeforeEach(func() {
		var err error
		ca, key, err = inject.NewCA("s1", []string{"api.anthropic.com"}, now)
		Expect(err).NotTo(HaveOccurred())
		roots = x509.NewCertPool()
		roots.AddCert(ca)
	})

	notAuthorized := func(err error) {
		var invalid x509.CertificateInvalidError
		ExpectWithOffset(1, errors.As(err, &invalid)).To(BeTrue(), "%v", err)
		ExpectWithOffset(1, invalid.Reason).To(Equal(x509.CANotAuthorizedForThisName))
	}

	It("stop it vouching for a host outside its list, even when it signed the leaf", func() {
		for _, h := range []string{"evil.example", "anthropic.com", "api.anthropic.com.evil.example", "xapi.anthropic.com"} {
			out, err := inject.NewLeaf(ca, key, h, now)
			Expect(err).NotTo(HaveOccurred())
			_, err = parseCert(out.Cert).Verify(x509.VerifyOptions{DNSName: h, Roots: roots, CurrentTime: now})
			notAuthorized(err)
		}
	})

	It("stop it vouching for an IP address", func() {
		for _, ip := range []string{"127.0.0.1", "::1"} {
			ipKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
			Expect(err).NotTo(HaveOccurred())
			tmpl := &x509.Certificate{
				SerialNumber: big.NewInt(7), IPAddresses: []net.IP{net.ParseIP(ip)},
				NotBefore: now.Add(-time.Minute), NotAfter: now.Add(time.Hour),
				ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
			}
			der, err := x509.CreateCertificate(rand.Reader, tmpl, ca, &ipKey.PublicKey, key)
			Expect(err).NotTo(HaveOccurred())
			leaf, err := x509.ParseCertificate(der)
			Expect(err).NotTo(HaveOccurred())
			_, err = leaf.Verify(x509.VerifyOptions{Roots: roots, CurrentTime: now})
			notAuthorized(err)
		}
	})

	It("stop it signing an intermediate CA", func() {
		subKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		Expect(err).NotTo(HaveOccurred())
		subTmpl := &x509.Certificate{
			SerialNumber: big.NewInt(8), NotBefore: now.Add(-time.Minute), NotAfter: now.Add(time.Hour),
			IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign,
		}
		der, err := x509.CreateCertificate(rand.Reader, subTmpl, ca, &subKey.PublicKey, key)
		Expect(err).NotTo(HaveOccurred())
		sub, err := x509.ParseCertificate(der)
		Expect(err).NotTo(HaveOccurred())
		out, err := inject.NewLeaf(sub, subKey, "api.anthropic.com", now)
		Expect(err).NotTo(HaveOccurred())
		inter := x509.NewCertPool()
		inter.AddCert(sub)
		_, err = parseCert(out.Cert).Verify(x509.VerifyOptions{DNSName: "api.anthropic.com", Roots: roots, Intermediates: inter, CurrentTime: now})
		var invalid x509.CertificateInvalidError
		Expect(errors.As(err, &invalid)).To(BeTrue(), "%v", err)
		Expect(invalid.Reason).To(Equal(x509.TooManyIntermediates))
	})

	It("let it vouch for a listed host's subdomain, as RFC 5280 constraints must; it never signs one", func() {
		out, err := inject.NewLeaf(ca, key, "x.api.anthropic.com", now)
		Expect(err).NotTo(HaveOccurred())
		_, err = parseCert(out.Cert).Verify(x509.VerifyOptions{DNSName: "x.api.anthropic.com", Roots: roots, CurrentTime: now})
		Expect(err).NotTo(HaveOccurred())
	})
})
