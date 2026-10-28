package state_test

import (
	"crypto/ecdsa"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/trevor-vaughan/claude-riotbox/internal/egress/envoyconfig"
	"github.com/trevor-vaughan/claude-riotbox/internal/egress/inject"
	"github.com/trevor-vaughan/claude-riotbox/internal/egress/policy"
	"github.com/trevor-vaughan/claude-riotbox/internal/egress/state"
)

var _ = Describe("credential injection state", func() {
	creds := []inject.Credential{
		{Env: "ANTHROPIC_API_KEY", Host: "api.anthropic.com", Header: "x-api-key", Value: "sk-ant-s3cret-1"},
		{Env: "OPENAI_API_KEY", Host: "api.openai.com", Header: "authorization", Value: "Bearer sk-openai-s3cret-2"},
	}
	// where says which file alone may hold each key.
	where := map[string]string{"sk-ant-s3cret-1": "api.anthropic.com.credential.json", "sk-openai-s3cret-2": "api.openai.com.credential.json"}
	now := time.Now()
	var (
		d       state.Dir
		runtime string // the runtime base: <tmpfs runtime dir>/riotbox-egress
	)

	BeforeEach(func() {
		runtime = filepath.Join(GinkgoT().TempDir(), "riotbox-egress")
		d = mustOpen(filepath.Join(GinkgoT().TempDir(), "riotbox-egress"), "s1").WithRuntime(runtime)
		Expect(d.Create()).To(Succeed())
	})

	readCert := func(path string) *x509.Certificate {
		data, err := os.ReadFile(path)
		ExpectWithOffset(1, err).NotTo(HaveOccurred())
		block, _ := pem.Decode(data)
		ExpectWithOffset(1, block).NotTo(BeNil())
		c, err := x509.ParseCertificate(block.Bytes)
		ExpectWithOffset(1, err).NotTo(HaveOccurred())
		return c
	}

	It("writes each host's leaf, key and credential into a 0700 secrets dir, each 0600", func() {
		Expect(d.WriteInjection(creds, now)).To(Succeed())
		Expect(d.SecretsDir()).To(Equal(filepath.Join(runtime, "s1", "secrets")))
		Expect(perm(runtime)).To(Equal(os.FileMode(0o700)))
		Expect(perm(filepath.Join(runtime, "s1"))).To(Equal(os.FileMode(0o700)))
		Expect(perm(d.SecretsDir())).To(Equal(os.FileMode(0o700)))
		entries, err := os.ReadDir(d.SecretsDir())
		Expect(err).NotTo(HaveOccurred())
		var names []string
		for _, e := range entries {
			names = append(names, e.Name())
			Expect(perm(filepath.Join(d.SecretsDir(), e.Name()))).To(Equal(os.FileMode(0o600)), e.Name())
		}
		Expect(names).To(ConsistOf(
			"api.anthropic.com.crt", "api.anthropic.com.key", "api.anthropic.com.credential.json",
			"api.openai.com.crt", "api.openai.com.key", "api.openai.com.credential.json"))
		Expect(os.ReadFile(filepath.Join(d.SecretsDir(), "api.openai.com.credential.json"))).
			To(Equal(envoyconfig.RenderCredential("api.openai.com", "Bearer sk-openai-s3cret-2")))
	})

	It("writes the CA certificate outside the secrets dir, and each leaf verifies against it", func() {
		Expect(d.WriteInjection(creds, now)).To(Succeed())
		Expect(d.CACert()).To(Equal(filepath.Join(d.Path(), "ca.crt")))
		Expect(perm(d.CACert())).To(Equal(os.FileMode(0o600)))
		ca := readCert(d.CACert())
		Expect(ca.PermittedDNSDomains).To(Equal([]string{"api.anthropic.com", "api.openai.com"}))
		roots := x509.NewCertPool()
		roots.AddCert(ca)
		for _, c := range creds {
			_, err := readCert(filepath.Join(d.SecretsDir(), c.Host+".crt")).
				Verify(x509.VerifyOptions{DNSName: c.Host, Roots: roots, CurrentTime: now})
			Expect(err).NotTo(HaveOccurred(), c.Host)
		}
	})

	It("writes the CA's private key nowhere, and each key only into its own credential file", func() {
		Expect(d.WriteInjection(creds, now)).To(Succeed())
		ca := readCert(d.CACert())
		Expect(filepath.WalkDir(d.Path(), func(path string, e fs.DirEntry, err error) error {
			if err != nil || e.IsDir() {
				return err
			}
			data, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			for rest := data; ; {
				var block *pem.Block
				if block, rest = pem.Decode(rest); block == nil {
					break
				}
				if block.Type == "PRIVATE KEY" {
					key, err := x509.ParsePKCS8PrivateKey(block.Bytes)
					Expect(err).NotTo(HaveOccurred(), path)
					Expect(key.(*ecdsa.PrivateKey).PublicKey.Equal(ca.PublicKey)).To(BeFalse(), path)
				}
			}
			for secret, file := range where {
				if strings.Contains(string(data), secret) {
					Expect(path).To(Equal(filepath.Join(d.SecretsDir(), file)))
				}
			}
			return nil
		})).To(Succeed())
	})

	It("records each key's variable, host and header, never its value, and reads them back", func() {
		Expect(d.WriteInjection(creds, now)).To(Succeed())
		Expect(os.ReadFile(filepath.Join(d.Path(), "injected"))).To(Equal([]byte(
			"ANTHROPIC_API_KEY api.anthropic.com x-api-key\nOPENAI_API_KEY api.openai.com authorization\n")))
		Expect(perm(filepath.Join(d.Path(), "injected"))).To(Equal(os.FileMode(0o600)))
		Expect(d.Injected()).To(Equal([]state.Injected{
			{Env: "ANTHROPIC_API_KEY", Host: "api.anthropic.com", Header: "x-api-key"},
			{Env: "OPENAI_API_KEY", Host: "api.openai.com", Header: "authorization"},
		}))
	})

	It("intercepts the recorded hosts in the config it writes, and keeps doing so on reload", func() {
		Expect(d.WriteInjection(creds, now)).To(Succeed())
		Expect(d.WriteConfig(policy.Resolved{Entries: []policy.Entry{{Host: "api.anthropic.com", Port: 443}}, StrictFrom: policy.SourceDefault})).To(Succeed())
		lds, err := os.ReadFile(filepath.Join(d.ConfigDir(), "lds.json"))
		Expect(err).NotTo(HaveOccurred())
		Expect(string(lds)).To(ContainSubstring(`"intercept-api.anthropic.com"`))
		Expect(string(lds)).To(ContainSubstring(`"intercept-api.openai.com"`))
		Expect(os.WriteFile(d.SessionConf(), []byte("strict = on\napi.openai.com\n"), 0o600)).To(Succeed())
		_, err = d.Reload("/nonexistent/sys", "/nonexistent/user")
		Expect(err).NotTo(HaveOccurred())
		rds, err := os.ReadFile(filepath.Join(d.ConfigDir(), "rds.json"))
		Expect(err).NotTo(HaveOccurred())
		Expect(string(rds)).To(ContainSubstring(`"name": "intercept-api.openai.com"`))
		Expect(string(rds)).NotTo(ContainSubstring(`"name": "intercept-api.anthropic.com"`))
	})

	It("writes nothing for no keys, and the config is then what it was without injection", func() {
		Expect(d.WriteInjection(nil, now)).To(Succeed())
		for _, p := range []string{d.SecretsDir(), d.CACert(), filepath.Join(d.Path(), "injected")} {
			Expect(p).NotTo(BeAnExistingFile())
		}
		Expect(d.Injected()).To(BeEmpty())
		Expect(d.WriteConfig(policy.Resolved{StrictFrom: policy.SourceDefault})).To(Succeed())
		bootstrap, err := os.ReadFile(filepath.Join(d.ConfigDir(), "bootstrap.json"))
		Expect(err).NotTo(HaveOccurred())
		Expect(string(bootstrap)).NotTo(ContainSubstring("internal_listener"))
	})

	It("clears an earlier injection that a reused session dir holds", func() {
		Expect(d.WriteInjection(creds, now)).To(Succeed())
		Expect(d.WriteInjection(nil, now)).To(Succeed())
		for _, p := range []string{d.SecretsDir(), d.CACert(), filepath.Join(d.Path(), "injected")} {
			Expect(p).NotTo(BeAnExistingFile())
		}
	})

	It("refuses a credential that cannot name a file or a record line, before writing anything, without its value", func() {
		bad := []inject.Credential{{Env: "K", Host: "../evil", Header: "x-api-key", Value: "sk-s3cret"}}
		err := d.WriteInjection(bad, now)
		Expect(err).To(MatchError("credential 1 is not a variable, a host and a header"))
		Expect(d.SecretsDir()).NotTo(BeAnExistingFile())
	})

	It("refuses two credentials for one host, before writing anything, without their values", func() {
		dup := []inject.Credential{creds[0], {Env: "OTHER_KEY", Host: "api.anthropic.com", Header: "x-api-key", Value: "sk-other-s3cret"}}
		err := d.WriteInjection(dup, now)
		Expect(err).To(MatchError("credential 2 names host api.anthropic.com again"))
		Expect(err.Error()).NotTo(ContainSubstring("s3cret"))
		for _, p := range []string{d.SecretsDir(), d.CACert(), filepath.Join(d.Path(), "injected")} {
			Expect(p).NotTo(BeAnExistingFile())
		}
	})

	DescribeTable("removes the secrets and the CA certificate when a later write fails, leaving no key on disk",
		func(failing func() string) {
			DeferCleanup(state.FailWriting(failing(), errors.New("disk full")))
			err := d.WriteInjection(creds, now)
			Expect(err).To(MatchError(ContainSubstring("disk full")))
			Expect(err.Error()).NotTo(ContainSubstring("s3cret"))
			for _, p := range []string{d.SecretsDir(), d.CACert(), filepath.Join(d.Path(), "injected")} {
				Expect(p).NotTo(BeAnExistingFile())
			}
			Expect(filepath.WalkDir(d.Path(), func(path string, e fs.DirEntry, err error) error {
				if err != nil || e.IsDir() {
					return err
				}
				data, err := os.ReadFile(path)
				Expect(err).NotTo(HaveOccurred())
				Expect(string(data)).NotTo(ContainSubstring("PRIVATE KEY"), path)
				Expect(string(data)).NotTo(ContainSubstring("s3cret"), path)
				return nil
			})).To(Succeed())
		},
		Entry("the CA certificate's", func() string { return d.CACert() }),
		Entry("the record's", func() string { return filepath.Join(d.Path(), "injected") }),
	)

	It("refuses a record that names one host twice", func() {
		Expect(os.WriteFile(filepath.Join(d.Path(), "injected"), []byte(
			"ANTHROPIC_API_KEY api.anthropic.com x-api-key\nOTHER_KEY api.anthropic.com authorization\n"), 0o600)).To(Succeed())
		_, err := d.Injected()
		Expect(err).To(MatchError(ContainSubstring("injected:2: names host api.anthropic.com again")))
		Expect(d.WriteConfig(policy.Resolved{StrictFrom: policy.SourceDefault})).NotTo(Succeed())
	})

	It("keeps the CA certificate and the record in the session dir, not with the secrets", func() {
		Expect(d.WriteInjection(creds, now)).To(Succeed())
		Expect(d.CACert()).To(Equal(filepath.Join(d.Path(), "ca.crt")))
		Expect(d.CACert()).To(BeARegularFile())
		Expect(filepath.Join(d.Path(), "injected")).To(BeARegularFile())
		Expect(filepath.Join(d.Path(), "secrets")).NotTo(BeAnExistingFile())
	})

	It("has no secrets dir without a runtime base, and refuses keys then, writing nothing", func() {
		bare := mustOpen(filepath.Dir(d.Path()), "s2")
		Expect(bare.Create()).To(Succeed())
		Expect(bare.SecretsDir()).To(BeEmpty())
		err := bare.WriteInjection(creds, now)
		Expect(err).To(MatchError(state.ErrNoRuntimeDir))
		Expect(err.Error()).NotTo(ContainSubstring("s3cret"))
		Expect(bare.CACert()).NotTo(BeAnExistingFile())
		Expect(filepath.Join(bare.Path(), "injected")).NotTo(BeAnExistingFile())
		Expect(filepath.Join(bare.Path(), "secrets")).NotTo(BeAnExistingFile())
		Expect(bare.WriteInjection(nil, now)).To(Succeed())
	})

	It("removes the secrets dir an earlier release kept in the session dir, with or without keys", func() {
		legacy := filepath.Join(d.Path(), "secrets")
		Expect(os.Mkdir(legacy, 0o700)).To(Succeed())
		Expect(d.WriteInjection(creds, now)).To(Succeed())
		Expect(legacy).NotTo(BeAnExistingFile())
		Expect(os.Mkdir(legacy, 0o700)).To(Succeed())
		Expect(mustOpen(filepath.Dir(d.Path()), "s1").WriteInjection(nil, now)).To(Succeed())
		Expect(legacy).NotTo(BeAnExistingFile())
	})

	Describe("a secrets path that is not a real directory", func() {
		It("refuses a link in place of the runtime base, writing nothing through it", func() {
			target := GinkgoT().TempDir()
			Expect(os.Chmod(target, 0o755)).To(Succeed())
			Expect(os.Symlink(target, runtime)).To(Succeed())
			err := d.WriteInjection(creds, now)
			Expect(err).To(MatchError(ContainSubstring("is not a directory")))
			Expect(os.ReadDir(target)).To(BeEmpty())
			Expect(perm(target)).To(Equal(os.FileMode(0o755)), "must not chmod through the link")
			Expect(filepath.Join(d.Path(), "injected")).NotTo(BeAnExistingFile())
		})

		It("replaces a link in place of the session's runtime dir, writing nothing through it", func() {
			target := GinkgoT().TempDir()
			Expect(os.Chmod(target, 0o755)).To(Succeed())
			Expect(os.Mkdir(runtime, 0o700)).To(Succeed())
			Expect(os.Symlink(target, filepath.Join(runtime, "s1"))).To(Succeed())
			Expect(d.WriteInjection(creds, now)).To(Succeed())
			Expect(os.ReadDir(target)).To(BeEmpty())
			Expect(perm(target)).To(Equal(os.FileMode(0o755)), "must not chmod through the link")
			info, err := os.Lstat(filepath.Join(runtime, "s1"))
			Expect(err).NotTo(HaveOccurred())
			Expect(info.IsDir()).To(BeTrue())
		})

		It("refuses a symlink there, writing nothing through it", func() {
			target := GinkgoT().TempDir()
			Expect(os.Chmod(target, 0o755)).To(Succeed())
			Expect(os.MkdirAll(filepath.Dir(d.SecretsDir()), 0o700)).To(Succeed())
			Expect(os.Symlink(target, d.SecretsDir())).To(Succeed())
			err := d.WriteInjection(creds, now)
			Expect(err).To(MatchError(ContainSubstring(d.SecretsDir())))
			Expect(err.Error()).NotTo(ContainSubstring("s3cret"))
			Expect(os.ReadDir(target)).To(BeEmpty())
			Expect(perm(target)).To(Equal(os.FileMode(0o755)), "must not chmod through the link")
			Expect(filepath.Join(d.Path(), "injected")).NotTo(BeAnExistingFile())
		})

		It("refuses a file there", func() {
			Expect(os.MkdirAll(filepath.Dir(d.SecretsDir()), 0o700)).To(Succeed())
			Expect(os.WriteFile(d.SecretsDir(), nil, 0o600)).To(Succeed())
			err := d.WriteInjection(creds, now)
			Expect(err).To(MatchError(ContainSubstring("is not a directory")))
			Expect(d.CACert()).NotTo(BeAnExistingFile())
		})
	})

	It("removes the secrets dir and its emptied session dir alone, and is safe to repeat", func() {
		Expect(d.WriteInjection(creds, now)).To(Succeed())
		Expect(d.RemoveSecrets()).To(Succeed())
		Expect(d.SecretsDir()).NotTo(BeAnExistingFile())
		Expect(filepath.Join(runtime, "s1")).NotTo(BeAnExistingFile())
		Expect(runtime).To(BeADirectory())
		Expect(d.CACert()).To(BeARegularFile())
		Expect(d.RemoveSecrets()).To(Succeed())
	})

	It("keeps a session runtime dir that holds something else", func() {
		Expect(d.WriteInjection(creds, now)).To(Succeed())
		other := filepath.Join(runtime, "s1", "other")
		Expect(os.WriteFile(other, nil, 0o600)).To(Succeed())
		Expect(d.RemoveSecrets()).To(Succeed())
		Expect(d.SecretsDir()).NotTo(BeAnExistingFile())
		Expect(other).To(BeARegularFile())
	})

	It("removes a symlinked secrets dir as the link alone", func() {
		target := GinkgoT().TempDir()
		kept := filepath.Join(target, "kept")
		Expect(os.WriteFile(kept, nil, 0o600)).To(Succeed())
		Expect(os.MkdirAll(filepath.Dir(d.SecretsDir()), 0o700)).To(Succeed())
		Expect(os.Symlink(target, d.SecretsDir())).To(Succeed())
		Expect(d.RemoveSecrets()).To(Succeed())
		_, err := os.Lstat(d.SecretsDir())
		Expect(err).To(MatchError(fs.ErrNotExist))
		Expect(kept).To(BeARegularFile())
	})

	DescribeTable("refuses a record line that is not a variable, a host and a header",
		func(line string) {
			Expect(os.WriteFile(filepath.Join(d.Path(), "injected"), []byte(line+"\n"), 0o600)).To(Succeed())
			_, err := d.Injected()
			Expect(err).To(MatchError(ContainSubstring("injected:1: not a variable, a host and a header")))
			Expect(d.WriteConfig(policy.Resolved{StrictFrom: policy.SourceDefault})).NotTo(Succeed())
		},
		Entry("two fields", "ANTHROPIC_API_KEY api.anthropic.com"),
		Entry("four fields", "ANTHROPIC_API_KEY api.anthropic.com x-api-key sk-ant-s3cret"),
		Entry("a bad variable name", "1KEY api.anthropic.com x-api-key"),
		Entry("a wildcard host", "K *.anthropic.com x-api-key"),
		Entry("a host with a port", "K api.anthropic.com:8443 x-api-key"),
		Entry("a host with port 443 spelled out", "K api.anthropic.com:443 x-api-key"),
		Entry("a removal", "K -api.anthropic.com x-api-key"),
		Entry("a path", "K ../evil x-api-key"),
		Entry("an uppercase host", "K API.anthropic.com x-api-key"),
		Entry("an uppercase header", "K api.anthropic.com X-Api-Key"),
		Entry("a terminal escape", "K api.anthropic.com x-api-key\x1b[31m"),
	)
})
