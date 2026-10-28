package policy

import (
	"fmt"
	"slices"
	"strings"
)

// builtinGroups are the groups every egress.conf can name. A member is an
// entry, or "@" and another built-in group of hosts only (registries and
// forges nest, one level); a file's [group NAME] replaces the built-in of
// that name. Every host is one its vendor documents (the Source lines); a
// host no vendor page names was left out, not guessed. Contents may change
// between releases (README "Egress proxy"), so a user who needs a fixed set
// defines their own group.
var builtinGroups = map[string][]string{
	// Source: https://docs.npmjs.com/cli/v11/using-npm/registry
	"npm": {"registry.npmjs.org"},
	// Source: https://docs.pypi.org/api/index-api/ (the index, and files.pythonhosted.org for the files it lists)
	"pypi": {"pypi.org", "files.pythonhosted.org"},
	// Source: https://go.dev/ref/mod#environment-variables (GOPROXY and GOSUMDB defaults);
	// https://go.dev/doc/security/vuln/database (vuln.go.dev, the database govulncheck reads)
	"go": {"proxy.golang.org", "sum.golang.org", "vuln.go.dev"},
	// Source: https://doc.rust-lang.org/cargo/reference/registry-index.html (sparse index);
	// https://index.crates.io/config.json ("dl")
	"crates": {"index.crates.io", "static.crates.io"},
	// Source: https://api.github.com/meta (.domains.actions_inbound.full_domains for github.com,
	// api.github.com and codeload.github.com; .domains.website for *.githubusercontent.com)
	"github": {"github.com", "api.github.com", "codeload.github.com", "*.githubusercontent.com"},
	// The package registries: allowed in every session unless strict mode is on.
	"registries": {"@npm", "@pypi", "@go", "@crates", "@github"},
	// Source: https://www.google.com/search/howsearchworks/;
	// https://www.bing.com/webmasters/help/webmaster-guidelines-30fba23a;
	// https://duckduckgo.com/duckduckgo-help-pages/; https://brave.com/search/ (search.brave.com);
	// https://api-dashboard.search.brave.com/app/documentation/web-search/get-started (api.search.brave.com).
	// html.duckduckgo.com is left out: DuckDuckGo's help pages do not name it.
	"search": {"www.google.com", "www.bing.com", "duckduckgo.com", "search.brave.com", "api.search.brave.com"},
	// Source: https://developer.mozilla.org/en-US/about; https://docs.python.org/3/about.html;
	// https://go.dev/doc/; https://pkg.go.dev/about; https://docs.github.com/en/contributing;
	// https://docs.rs/about; https://stackexchange.com/sites (stackoverflow.com and the
	// *.stackexchange.com sites); https://docs.readthedocs.io/en/stable/custom-domains.html
	// (<project>.readthedocs.io)
	"docs": {"developer.mozilla.org", "docs.python.org", "go.dev", "pkg.go.dev", "docs.github.com", "docs.rs", "stackoverflow.com", "*.stackexchange.com", "*.readthedocs.io"},
	// Source: https://meta.wikimedia.org/wiki/Special:SiteMatrix (every <lang>.wikipedia.org and
	// *.wikimedia.org wiki); https://meta.wikimedia.org/wiki/Wikimedia_servers
	"wikipedia": {"*.wikipedia.org", "*.wikimedia.org"},
	// Source: https://guides.rubygems.org/rubygems-org-compact-index-api/ (served from rubygems.org).
	// index.rubygems.org is left out: no RubyGems guide names it.
	"rubygems": {"rubygems.org"},
	// Source: https://maven.apache.org/guides/introduction/introduction-to-repositories.html
	// (repo.maven.apache.org); https://central.sonatype.org/consume/ (repo1.maven.org, from Central's operator)
	"maven": {"repo.maven.apache.org", "repo1.maven.org"},
	// Source: https://docs.gitlab.com/user/gitlab_com/ (container registry domain name)
	"gitlab": {"gitlab.com", "registry.gitlab.com"},
	// Source: https://support.atlassian.com/bitbucket-cloud/docs/what-are-the-bitbucket-cloud-ip-addresses-i-should-use-to-configure-my-corporate-firewall/
	// (bitbucket.org, api.bitbucket.org); https://docs.codeberg.org/git/clone-commit-via-cli/ (codeberg.org);
	// https://docs.gitea.com/usage/repo-mirror (gitea.com); https://man.sr.ht/git.sr.ht/ (git.sr.ht);
	// https://man.sr.ht/hg.sr.ht/ (hg.sr.ht);
	// https://learn.microsoft.com/en-us/azure/devops/organizations/security/allow-list-ip-url (dev.azure.com);
	// https://documentation.ubuntu.com/launchpad/user/explanation/working-with-code/git-hosting/
	// (git.launchpad.net, code.launchpad.net). bbuseruploads.s3.amazonaws.com is left out: Atlassian's
	// page does not name it. Opt-in: not part of @registries.
	"forges": {"@github", "@gitlab", "bitbucket.org", "api.bitbucket.org", "codeberg.org", "gitea.com",
		"git.sr.ht", "hg.sr.ht", "dev.azure.com", "git.launchpad.net", "code.launchpad.net"},
	// Source: https://docs.docker.com/desktop/setup/allow-list/ (registry-1.docker.io, auth.docker.io,
	// production.cloudfront.docker.com); https://docs.quay.io/ (quay.io);
	// https://access.redhat.com/articles/7084334 (the cdn*.quay.io hosts, covered by *.quay.io);
	// https://docs.github.com/en/actions/reference/runners/github-hosted-runners
	// (ghcr.io, pkg-containers.githubusercontent.com)
	"containers": {"registry-1.docker.io", "auth.docker.io", "production.cloudfront.docker.com", "quay.io", "*.quay.io", "ghcr.io", "pkg-containers.githubusercontent.com"},
	// Source: https://huggingface.co/docs/hub/en/models-downloading#downloading-behind-a-proxy-or-firewall
	// (huggingface.co and the *.hf.co storage and CDN hosts). cdn-lfs.huggingface.co is left out:
	// Hugging Face's firewall list names only the *.hf.co CDN hosts.
	"huggingface": {"huggingface.co", "*.hf.co"},
	// Every OS plugin's mirrors: Groups fills it from the OS groups it is given (no hosts are
	// listed here, so none is named without a plugin). Opt-in: not part of @registries.
	osGroup: {},
}

// osGroup is the built-in @os: the union of every OS plugin's group. It is
// listed in builtinGroups with no hosts; Groups fills it.
const osGroup = "os"

// Group is one group of the table @ references resolve against: its
// hosts, expanded and sorted, and where its definition comes from
// (SourceBuiltin, SourceOS, SourceSystem, SourceUser or SourceAgent).
type Group struct {
	Name    string
	Source  string
	Members []Entry
}

// groupDef is a definition before its references are expanded.
type groupDef struct {
	source  string
	members []Entry
	refs    []string
}

// Groups returns the group table: the built-ins, then the OS plugins'
// groups (os), replaced by the system file's definitions, replaced in turn
// by the user file's, and the agent's hosts as @agent, which no file can
// define. The built-in @os is the union of the OS groups' members in that
// final table (a conf's [group centos] shows in it), empty without OS
// plugins; a file's [group os] replaces it. A built-in that names other
// groups (@registries, @forges) is expanded against this final table, so a
// user's [group pypi] changes @registries too.
func Groups(agent []Entry, osGroups []GroupDef, system, user Conf) map[string]Group {
	defs := map[string]groupDef{}
	for name, raw := range builtinGroups {
		d := groupDef{source: SourceBuiltin}
		for _, m := range raw {
			if ref, isRef := strings.CutPrefix(m, "@"); isRef {
				target, exists := builtinGroups[ref]
				if !exists || ref == osGroup || slices.ContainsFunc(target, func(t string) bool { return strings.HasPrefix(t, "@") }) {
					panic(fmt.Sprintf("policy: built-in group %s: @%s must name a built-in group of hosts only, not @os (exists=%t)", name, ref, exists))
				}
				d.refs = append(d.refs, ref)
				continue
			}
			e, remove, err := Parse(m)
			if err != nil || remove {
				panic(fmt.Sprintf("policy: built-in group %s: entry %q is invalid (err=%v, removal=%t)", name, m, err, remove))
			}
			d.members = append(d.members, e)
		}
		defs[name] = d
	}
	for _, g := range osGroups {
		defs[g.Name] = groupDef{source: SourceOS, members: g.Members}
	}
	for _, f := range []struct {
		conf   Conf
		source string
	}{{system, SourceSystem}, {user, SourceUser}} {
		for _, g := range f.conf.Groups {
			defs[g.Name] = groupDef{source: f.source, members: g.Members}
		}
	}
	defs[AgentGroup] = groupDef{source: SourceAgent, members: agent}
	table := make(map[string]Group, len(defs))
	for name, d := range defs {
		members := slices.Clone(d.members)
		for _, ref := range d.refs {
			members = append(members, defs[ref].members...)
		}
		table[name] = Group{Name: name, Source: d.source, Members: merge(members, nil)}
	}
	if d := defs[osGroup]; d.source == SourceBuiltin {
		var members []Entry
		for _, g := range osGroups {
			members = append(members, table[g.Name].Members...)
		}
		table[osGroup] = Group{Name: osGroup, Source: SourceBuiltin, Members: merge(members, nil)}
	}
	return table
}

// OSGroup reads data, the egress-hosts file at path of the OS plugin name
// (docs/dev/os-contract.md), as the group name: one entry per line, as
// agent.conf holds (ParseList). It fails, naming path, on a name that is
// not a group name or is already a group (@agent, a built-in), on an
// invalid line, and on a file that lists no hosts.
func OSGroup(name, path string, data []byte) (GroupDef, error) {
	if !groupName.MatchString(name) {
		return GroupDef{}, fmt.Errorf("%s: %q is not a group name: use lowercase letters, digits and -, at most 63", path, name)
	}
	if _, builtin := builtinGroups[name]; builtin || name == AgentGroup {
		return GroupDef{}, fmt.Errorf("%s: @%s is already a group; an OS plugin cannot redefine it", path, name)
	}
	members, err := ParseList(path, data)
	if err != nil {
		return GroupDef{}, err
	}
	if len(members) == 0 {
		return GroupDef{}, fmt.Errorf("%s: lists no hosts", path)
	}
	return GroupDef{Name: name, Members: members}, nil
}
