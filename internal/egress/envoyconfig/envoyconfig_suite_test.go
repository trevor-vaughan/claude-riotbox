package envoyconfig_test

import (
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestEnvoyconfig(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "egress/envoyconfig")
}
