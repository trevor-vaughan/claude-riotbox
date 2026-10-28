package policy

import (
	"fmt"
	"slices"
	"strings"
)

// builtinGroups are the groups every egress.conf can name. A member is an
// entry, or "@" and another built-in group (only registries nests, one
// level); a file's [group NAME] replaces the built-in of that name. Every
// host is one its vendor documents (the Source lines); a host no vendor
// page names was left out, not guessed. Contents may change between
// releases (README "Egress proxy"), so a user who needs a fixed set
// defines their own group.
var builtinGroups = map[string][]string{
	// Source: https://docs.npmjs.com/cli/v11/using-npm/registry
	"npm": {"registry.npmjs.org"},
	// Source: https://docs.pypi.org/api/index-api/ (the index, and files.pythonhosted.org for the files it lists)
	"pypi": {"pypi.org", "files.pythonhosted.org"},
	// Source: https://go.dev/ref/mod#environment-variables (GOPROXY and GOSUMDB defaults)
	"go": {"proxy.golang.org", "sum.golang.org"},
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
	// https://pkg.go.dev/about; https://docs.rs/about; https://stackexchange.com/sites (stackoverflow.com
	// and the *.stackexchange.com sites); https://docs.readthedocs.io/en/stable/custom-domains.html
	// (<project>.readthedocs.io)
	"docs": {"developer.mozilla.org", "docs.python.org", "pkg.go.dev", "docs.rs", "stackoverflow.com", "*.stackexchange.com", "*.readthedocs.io"},
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
	// Source: https://docs.docker.com/desktop/setup/allow-list/ (registry-1.docker.io, auth.docker.io,
	// production.cloudfront.docker.com); https://docs.quay.io/ (quay.io);
	// https://access.redhat.com/articles/7084334 (the cdn*.quay.io hosts, covered by *.quay.io);
	// https://docs.github.com/en/actions/reference/runners/github-hosted-runners
	// (ghcr.io, pkg-containers.githubusercontent.com)
	"containers": {"registry-1.docker.io", "auth.docker.io", "production.cloudfront.docker.com", "quay.io", "*.quay.io", "ghcr.io", "pkg-containers.githubusercontent.com"},
	// Source: the metalink URLs in /etc/yum.repos.d/centos.repo in quay.io/centos/centos:stream10
	// (mirrors.centos.org); https://mirror.stream.centos.org/ (the CentOS Stream mirror)
	"centos": {"mirrors.centos.org", "mirror.stream.centos.org"},
	// Source: https://huggingface.co/docs/hub/en/models-downloading#downloading-behind-a-proxy-or-firewall
	// (huggingface.co and the *.hf.co storage and CDN hosts). cdn-lfs.huggingface.co is left out:
	// Hugging Face's firewall list names only the *.hf.co CDN hosts.
	"huggingface": {"huggingface.co", "*.hf.co"},
}

// Group is one group of the table @ references resolve against: its
// hosts, expanded and sorted, and where its definition comes from
// (SourceBuiltin, SourceSystem, SourceUser or SourceAgent).
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

// Groups returns the group table: the built-ins, replaced by the system
// file's definitions, replaced in turn by the user file's, and the agent's
// hosts as @agent, which no file can define. A built-in that names other
// groups (@registries) is expanded against this final table, so a user's
// [group pypi] changes @registries too.
func Groups(agent []Entry, system, user Conf) map[string]Group {
	defs := map[string]groupDef{}
	for name, raw := range builtinGroups {
		d := groupDef{source: SourceBuiltin}
		for _, m := range raw {
			if ref, isRef := strings.CutPrefix(m, "@"); isRef {
				target, exists := builtinGroups[ref]
				if !exists || slices.ContainsFunc(target, func(t string) bool { return strings.HasPrefix(t, "@") }) {
					panic(fmt.Sprintf("policy: built-in group %s: @%s must name a built-in group of hosts only (exists=%t)", name, ref, exists))
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
	return table
}
