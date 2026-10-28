package inject

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"net"
	"strings"
	"time"
)

// CertValidity is how long a session's CA and leaves are valid. The CA's
// key is discarded at launch, so nothing can renew them: a session that
// runs longer loses TLS to its credential hosts until restarted (README
// "Egress proxy").
const CertValidity = 30 * 24 * time.Hour

// CertBackdate backdates NotBefore, so a client whose clock is slightly
// behind still accepts a fresh certificate.
const CertBackdate = 5 * time.Minute

// allIPs excludes every IP address from the CA's name constraints: with
// only DNS names permitted, RFC 5280 would leave IP addresses unconstrained.
var allIPs = []*net.IPNet{mustCIDR("0.0.0.0/0"), mustCIDR("::/0")}

func mustCIDR(s string) *net.IPNet {
	_, n, err := net.ParseCIDR(s)
	if err != nil {
		panic("inject: " + err.Error())
	}
	return n
}

// Leaf is one host's certificate and private key (PKCS#8), PEM-encoded.
type Leaf struct {
	Cert, Key []byte
}

// Certs is a session's interception PKI.
type Certs struct {
	CA []byte // the CA's certificate, PEM; its key is not kept
	// Leaves is by host. Map order is random: a caller that writes files
	// or config from it must sort the hosts for stable output.
	Leaves map[string]Leaf
}

// NewCerts makes session's CA, which may vouch only for hosts (critical
// X.509 name constraints; no IP address), and one leaf per host signed by
// it, each valid from now-CertBackdate to now+CertValidity. The CA's
// private key exists only inside this call: keys are read once, at launch,
// so no leaf is ever needed later, and the key is written nowhere. It
// refuses an empty host list or an invalid host (checkHosts): either would
// let the CA vouch for more names than the session's.
func NewCerts(session string, hosts []string, now time.Time) (Certs, error) {
	if len(hosts) == 0 {
		return Certs{}, errors.New("refusing to make a session CA for no hosts")
	}
	if err := checkHosts(hosts); err != nil {
		return Certs{}, err
	}
	ca, key, err := newCA(session, hosts, now)
	if err != nil {
		return Certs{}, err
	}
	c := Certs{CA: pemBlock("CERTIFICATE", ca.Raw), Leaves: map[string]Leaf{}}
	for _, h := range hosts {
		leaf, err := newLeaf(ca, key, h, now)
		if err != nil {
			return Certs{}, err
		}
		c.Leaves[h] = leaf
	}
	return c, nil
}

// checkHosts refuses a host that is not one exact, lower-case DNS name, or
// that repeats an earlier one. An empty permitted DNS constraint matches
// every name; a leading dot, a wildcard or an IP literal would not mean one
// host; x509 compares names case-insensitively, so case only blurs the
// list. Hosts are not secrets, so the error names the host.
func checkHosts(hosts []string) error {
	seen := make(map[string]bool, len(hosts))
	for _, h := range hosts {
		var reason string
		switch {
		case h == "":
			reason = "it is empty"
		case net.ParseIP(h) != nil:
			reason = "it is an IP address"
		case strings.HasPrefix(h, "."):
			reason = "it starts with a dot"
		case strings.Contains(h, "*"):
			reason = "it holds a wildcard"
		case h != strings.ToLower(h):
			reason = "it is not lower case"
		case seen[h]:
			reason = "it is listed twice"
		}
		if reason != "" {
			return fmt.Errorf("refusing to make a session CA for host %q: %s", h, reason)
		}
		seen[h] = true
	}
	return nil
}

// newCA makes a P-256 CA named after session, constrained to hosts, that
// may sign leaves only (path length zero, no CRLs).
func newCA(session string, hosts []string, now time.Time) (*x509.Certificate, *ecdsa.PrivateKey, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, fmt.Errorf("making the session CA's key: %w", err)
	}
	serial, err := randomSerial()
	if err != nil {
		return nil, nil, err
	}
	tmpl := &x509.Certificate{
		SerialNumber:                serial,
		Subject:                     pkix.Name{CommonName: "RiotBox egress " + session},
		NotBefore:                   now.Add(-CertBackdate),
		NotAfter:                    now.Add(CertValidity),
		IsCA:                        true,
		BasicConstraintsValid:       true,
		MaxPathLenZero:              true,
		KeyUsage:                    x509.KeyUsageCertSign,
		PermittedDNSDomainsCritical: true,
		PermittedDNSDomains:         hosts,
		ExcludedIPRanges:            allIPs,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return nil, nil, fmt.Errorf("making the session CA: %w", err)
	}
	ca, err := x509.ParseCertificate(der)
	if err != nil {
		return nil, nil, fmt.Errorf("reading the session CA back: %w", err)
	}
	return ca, key, nil
}

// newLeaf makes a P-256 server certificate for host, signed by ca.
func newLeaf(ca *x509.Certificate, caKey *ecdsa.PrivateKey, host string, now time.Time) (Leaf, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return Leaf{}, fmt.Errorf("making the key for %s: %w", host, err)
	}
	serial, err := randomSerial()
	if err != nil {
		return Leaf{}, err
	}
	tmpl := &x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: host},
		DNSNames:     []string{host},
		NotBefore:    now.Add(-CertBackdate),
		NotAfter:     now.Add(CertValidity),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, ca, &key.PublicKey, caKey)
	if err != nil {
		return Leaf{}, fmt.Errorf("making the certificate for %s: %w", host, err)
	}
	pkcs8, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return Leaf{}, fmt.Errorf("encoding the key for %s: %w", host, err)
	}
	return Leaf{Cert: pemBlock("CERTIFICATE", der), Key: pemBlock("PRIVATE KEY", pkcs8)}, nil
}

// randomSerial is a uniformly random serial number in [1, 2^128]: 128 bits
// of entropy (CA/B Forum asks for 64) and, as RFC 5280 requires, positive.
func randomSerial() (*big.Int, error) {
	n, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return nil, fmt.Errorf("making a certificate serial: %w", err)
	}
	return n.Add(n, big.NewInt(1)), nil
}

func pemBlock(typ string, der []byte) []byte {
	return pem.EncodeToMemory(&pem.Block{Type: typ, Bytes: der})
}
