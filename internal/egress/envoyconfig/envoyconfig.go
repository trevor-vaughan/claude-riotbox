// Package envoyconfig renders a session's egress allowlist as the Envoy
// configuration its proxy runs. The bootstrap loads a listener (LDS) and a
// cluster (CDS) from files, and the listener loads the allowlist as a route
// configuration (RDS) from rds.json, so the allowlist is swapped at runtime
// by replacing that one file. A route update leaves the listener and its
// open tunnels alone; a listener update would drain them (see
// docs/dev/egress.md).
//
// Values come only from entries and are serialised by encoding/json, never
// spliced into text. Output is deterministic: encoding/json sorts map keys.
//
// The proxy has no admin interface: nothing uses it, and an allowlisted name
// that resolves to loopback could otherwise reach its /quitquitquit.
//
// A session whose launch passed API keys (internal/egress/inject) also
// intercepts each key's provider host: an allowed CONNECT to it goes to
// an internal listener that terminates TLS with a leaf for that host,
// sets the key's header from an SDS file in SecretsDir and forwards the
// request to the host over verified TLS. No key is in these files: only
// RenderCredential's output, which goes to the secrets dir alone, holds
// one.
package envoyconfig

import (
	"cmp"
	"encoding/json"
	"fmt"
	"maps"
	"regexp"
	"slices"
	"strings"

	"github.com/trevor-vaughan/claude-riotbox/internal/egress/policy"
)

// ListenPort is where the proxy listens, inside its own network namespace.
const ListenPort = 3128

// Paths inside the proxy container: the config dir (mounted read-only from
// the host) and the log dir (mounted read-write), and the files in them.
const (
	ConfigDir     = "/etc/riotbox-egress"
	LogDir        = "/var/log/riotbox-egress"
	BootstrapFile = "bootstrap.json"
	CDSFile       = "cds.json"
	LDSFile       = "lds.json"
	RDSFile       = "rds.json"
	AccessLogName = "access.log"
	EnvoyLogName  = "envoy.log"
)

// SecretsDir is where the proxy reads each credential host's leaf
// certificate, key and credential: the session's secrets dir, mounted
// read-only into the proxy alone.
const SecretsDir = "/etc/riotbox-egress-secrets"

// SystemCABundle is the pinned Envoy image's CA bundle, which the proxy
// verifies credential hosts against.
const SystemCABundle = "/etc/ssl/certs/ca-certificates.crt"

// DeniedHeader is set on every response the proxy refuses with: "denied"
// and the authority the client asked for.
const DeniedHeader = "x-riotbox-egress"

const (
	typeListener   = "type.googleapis.com/envoy.config.listener.v3.Listener"
	typeCluster    = "type.googleapis.com/envoy.config.cluster.v3.Cluster"
	typeRoute      = "type.googleapis.com/envoy.config.route.v3.RouteConfiguration"
	typeHCM        = "type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager"
	typeDFPFilter  = "type.googleapis.com/envoy.extensions.filters.http.dynamic_forward_proxy.v3.FilterConfig"
	typeDFPCluster = "type.googleapis.com/envoy.extensions.clusters.dynamic_forward_proxy.v3.ClusterConfig"
	typeRouter     = "type.googleapis.com/envoy.extensions.filters.http.router.v3.Router"
	typeFileLog    = "type.googleapis.com/envoy.extensions.access_loggers.file.v3.FileAccessLog"

	typeTLSInspector        = "type.googleapis.com/envoy.extensions.filters.listener.tls_inspector.v3.TlsInspector"
	typeDownstreamTLS       = "type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.DownstreamTlsContext"
	typeUpstreamTLS         = "type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.UpstreamTlsContext"
	typeSecret              = "type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.Secret"
	typeCredentialInjector  = "type.googleapis.com/envoy.extensions.filters.http.credential_injector.v3.CredentialInjector"
	typeGenericCredential   = "type.googleapis.com/envoy.extensions.http.injected_credentials.generic.v3.Generic"
	typeHTTPProtocolOptions = "type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions"
	typeInternalListener    = "type.googleapis.com/envoy.extensions.bootstrap.internal_listener.v3.InternalListener"
)

type obj = map[string]any

// Files is one proxy's configuration, a field per file in ConfigDir.
type Files struct {
	Bootstrap, CDS, LDS, RDS []byte
}

// Intercept is a credential host whose CONNECTs the proxy terminates, and
// the header its credential goes in. Hosts must be unique across the
// intercepts rendered together: Envoy refuses one domain in two virtual
// hosts, and two listeners of one name.
type Intercept struct {
	Host   string // a DNS name, port 443
	Header string // matched case-insensitively, as HTTP header names are
}

// CertFile names host's leaf certificate in the secrets dir.
func CertFile(host string) string { return host + ".crt" }

// KeyFile names the private key of host's leaf in the secrets dir.
func KeyFile(host string) string { return host + ".key" }

// CredentialFile names host's credential (RenderCredential) in the
// secrets dir.
func CredentialFile(host string) string { return host + ".credential.json" }

// RenderCredential returns host's SDS file: the whole header value as a
// generic secret, named as the host's credential injector reads it. It is
// the only rendering that holds a key; it goes only into the secrets dir.
func RenderCredential(host, value string) []byte {
	return mustMarshal(resources(typeSecret, obj{
		"name":           interceptName(host),
		"generic_secret": obj{"secret": obj{"inline_string": value}},
	}))
}

// Render returns the four files of session's proxy enforcing entries and
// intercepting intercepts. session goes into the denial message
// (localReply); it is a state.Dir name, which holds no "%", so Envoy
// reads no command operator in it. The listeners and clusters depend on
// intercepts alone, never on entries, so lds.json and cds.json never
// change after start.
func Render(session string, entries []policy.Entry, intercepts []Intercept) Files {
	intercepts = byHost(intercepts)
	listeners, clusters := interceptResources(intercepts)
	return Files{
		Bootstrap: mustMarshal(addInternalListeners(obj{
			"node": node(),
			"dynamic_resources": obj{
				"lds_config": fileSource(LDSFile),
				"cds_config": fileSource(CDSFile),
			},
		}, intercepts)),
		CDS: mustMarshal(resources(typeCluster, append([]obj{cluster()}, clusters...)...)),
		LDS: mustMarshal(resources(typeListener, append([]obj{listener(session, obj{
			"rds": obj{"route_config_name": "egress", "config_source": fileSource(RDSFile)},
		})}, listeners...)...)),
		RDS: RenderRDS(entries, intercepts),
	}
}

// RenderRDS returns rds.json: the route configuration enforcing entries
// and routing the allowed intercepts into their listeners.
func RenderRDS(entries []policy.Entry, intercepts []Intercept) []byte {
	return mustMarshal(resources(typeRoute, routeConfig(entries, byHost(intercepts))))
}

// RenderStatic returns one bootstrap with the listeners, clusters and
// routes inlined. It exists for tests: `envoy --mode validate` does not
// load dynamic resources from files, so this is the form that can be
// validated.
func RenderStatic(session string, entries []policy.Entry, intercepts []Intercept) []byte {
	intercepts = byHost(intercepts)
	listeners, clusters := interceptResources(intercepts)
	return mustMarshal(addInternalListeners(obj{
		"node": node(),
		"static_resources": obj{
			"listeners": append([]obj{listener(session, obj{"route_config": routeConfig(entries, intercepts)})}, listeners...),
			"clusters":  append([]obj{cluster()}, clusters...),
		},
	}, intercepts))
}

// byHost returns a copy of intercepts sorted by host, so the rendering
// does not depend on the caller's order (inject.Certs keeps leaves in a
// map).
func byHost(intercepts []Intercept) []Intercept {
	return slices.SortedFunc(slices.Values(intercepts), func(a, b Intercept) int { return cmp.Compare(a.Host, b.Host) })
}

// addInternalListeners loads the internal listener extension into
// bootstrap when there is something to intercept; without, the bootstrap
// is what it was before interception existed.
func addInternalListeners(bootstrap obj, intercepts []Intercept) obj {
	if len(intercepts) > 0 {
		bootstrap["bootstrap_extensions"] = []any{obj{
			"name":         "envoy.bootstrap.internal_listener",
			"typed_config": obj{"@type": typeInternalListener},
		}}
	}
	return bootstrap
}

func node() obj { return obj{"id": "riotbox-egress", "cluster": "riotbox-egress"} }

func socketAddress(address string, port int) obj {
	return obj{"socket_address": obj{"address": address, "port_value": port}}
}

// fileSource is a config source that reads name from ConfigDir and reloads
// it when a file is renamed into the directory.
func fileSource(name string) obj {
	return obj{
		"resource_api_version": "V3",
		"path_config_source": obj{
			"path":              ConfigDir + "/" + name,
			"watched_directory": obj{"path": ConfigDir},
		},
	}
}

// resources wraps freshly built resources (each is modified in place) as
// an xDS discovery file, typed by typeURL.
func resources(typeURL string, items ...obj) obj {
	for _, r := range items {
		r["@type"] = typeURL
	}
	return obj{"resources": items}
}

func dnsCache() obj { return obj{"name": "egress", "dns_lookup_family": "V4_ONLY"} }

func cluster() obj {
	return obj{
		"name":            "egress",
		"connect_timeout": "5s",
		"lb_policy":       "CLUSTER_PROVIDED",
		"cluster_type": obj{
			"name":         "envoy.clusters.dynamic_forward_proxy",
			"typed_config": obj{"@type": typeDFPCluster, "dns_cache_config": dnsCache()},
		},
	}
}

// listener is the CONNECT proxy listener of session; routes is either
// {"rds": ...} or {"route_config": ...}.
func listener(session string, routes obj) obj {
	hcm := obj{
		"@type":       typeHCM,
		"stat_prefix": "egress",
		// HTTP/1 only: AUTO would also accept cleartext HTTP/2, whose codec
		// lets an :authority holding ; $ ( ' & reach the denial text
		// (localReply). HTTP/1's codec refuses those with a bare 400, and
		// proxy clients send HTTP/1.1 CONNECT.
		"codec_type":      "HTTP1",
		"upgrade_configs": []any{obj{"upgrade_type": "CONNECT"}},
		// Envoy's default (300s) would close a tunnel quiet for five minutes,
		// such as a long model stream. An hour still reaps abandoned tunnels.
		"stream_idle_timeout": "3600s",
		"local_reply_config":  localReply(session),
		"access_log": []any{obj{
			"name": "envoy.access_loggers.file",
			"typed_config": obj{
				"@type": typeFileLog,
				"path":  LogDir + "/" + AccessLogName,
				"log_format": obj{"json_format": obj{
					"time":      "%START_TIME%",
					"method":    "%REQ(:METHOD)%",
					"authority": "%REQ(:AUTHORITY)%",
					"status":    "%RESPONSE_CODE%",
					"flags":     "%RESPONSE_FLAGS%",
				}},
			},
		}},
		"http_filters": []any{
			obj{"name": "envoy.filters.http.dynamic_forward_proxy", "typed_config": obj{"@type": typeDFPFilter, "dns_cache_config": dnsCache()}},
			obj{"name": "envoy.filters.http.router", "typed_config": obj{"@type": typeRouter}},
		},
	}
	maps.Copy(hcm, routes)
	return obj{
		"name":    "egress",
		"address": socketAddress("0.0.0.0", ListenPort),
		"filter_chains": []any{obj{"filters": []any{obj{
			"name":         "envoy.filters.network.http_connection_manager",
			"typed_config": hcm,
		}}}},
	}
}

// localReply rewrites every 403 the proxy answers itself — each one a
// refusal, as the routes answer 403 to everything they do not allow — to
// say what was refused: a text/plain body and DeniedHeader. Two mappers,
// first match wins: a refused CONNECT is told how the user allows the
// host; any other method (plain HTTP, refused unless an http:// entry
// allows it) is told to use HTTPS, or how the user allows plain HTTP to
// the host. %REQ(:AUTHORITY)% is the
// authority the client asked for (host:port for a CONNECT); the client
// chooses it, so the text asks the user to check it before running the
// command. Clients drop the body of a refused CONNECT (curl prints only
// "CONNECT tunnel failed, response 403"), so the agent learns the same
// from its system prompt (scripts/lib/egress-prompt.sh). The status is
// kept, and no runtime key is given, so nothing outside this file can
// change the reply. It holds no secret.
func localReply(session string) obj {
	const authority = "%REQ(:AUTHORITY)%"
	denied := func(filter obj, body string) obj {
		return obj{
			"filter": filter,
			"headers_to_add": []any{obj{
				"header":        obj{"key": DeniedHeader, "value": "denied " + authority},
				"append_action": "OVERWRITE_IF_EXISTS_OR_ADD",
			}},
			"body_format_override": obj{
				"text_format_source": obj{"inline_string": body},
				"content_type":       "text/plain; charset=utf-8",
			},
		}
	}
	refused := obj{"status_code_filter": obj{"comparison": obj{
		"op":    "EQ",
		"value": obj{"default_value": 403},
	}}}
	connect := obj{"and_filter": obj{"filters": []any{
		refused,
		obj{"header_filter": obj{"header": obj{
			"name":         ":method",
			"string_match": obj{"exact": "CONNECT"},
		}}},
	}}}
	return obj{"mappers": []any{
		denied(connect, "riotbox egress: "+authority+" is not on this session's allowlist.\n"+
			"This is not a network fault: retrying, or trying other hosts, IP addresses, DNS or proxies, will not get through.\n"+
			"Stop and ask the user to allow it. If the user agrees after checking the host, they run on the host:\n"+
			"  riotbox egress allow --session "+session+" "+authority+"\n"),
		denied(refused, "riotbox egress: plain HTTP to "+authority+" is not on this session's allowlist.\n"+
			"Use HTTPS. If the host serves only plain HTTP, this is not a network fault: stop and ask the user to allow it.\n"+
			"If the user agrees after checking the host, they run on the host:\n"+
			"  riotbox egress allow --session "+session+" http://"+authority+"\n"),
	}}
}

// domain is one virtual-host domain: host (a name or *.suffix) on one
// port, or a name on every port (all).
type domain struct {
	host string
	port int
	all  bool
}

// MaxDomains is the most single-port domains a rendering may hold. Each
// port of a range is a domain, and where a wildcard range meets each
// host:* under it their intersection adds more, so the count can grow as
// their product.
const MaxDomains = 65536

// Check returns an error when entries would render more than MaxDomains
// single-port domains. RenderRDS and the others do not check it; a caller
// that writes their output calls Check first.
func Check(entries []policy.Entry, intercepts []Intercept) error {
	domains, _, _ := planDomains(entries, byHost(intercepts))
	n := 0
	for _, d := range domains {
		if !d.all {
			n++
		}
	}
	if n > MaxDomains {
		return fmt.Errorf("the allowlist needs %d single-port domains, more than the %d allowed; use fewer or narrower port ranges, or host:* for every port", n, MaxDomains)
	}
	return nil
}

// planDomains returns the virtual-host domains of entries (see
// routeConfig), the *.s:* entries that only the "*" host's regex routes
// can say, and the intercepted host:port entries that get a virtual host
// of their own.
func planDomains(entries []policy.Entry, intercepts []Intercept) (domains []domain, wildAll []policy.Entry, intercepted map[policy.Entry]bool) {
	intercepted = map[policy.Entry]bool{}
	for _, i := range intercepts {
		if e := (policy.Entry{Host: i.Host, Port: policy.DefaultPort}); policy.Allows(entries, e) {
			intercepted[e] = true
		}
	}
	seen := map[domain]bool{}
	add := func(d domain) {
		if !seen[d] && (d.all || !intercepted[policy.Entry{Host: d.host, Port: d.port}]) {
			seen[d] = true
			domains = append(domains, d)
		}
	}
	isWild := func(host string) bool { return strings.HasPrefix(host, "*.") }
	for _, e := range entries {
		switch {
		case e.AllPorts() && isWild(e.Host):
			wildAll = append(wildAll, e)
		case e.AllPorts():
			add(domain{host: e.Host, all: true})
		default:
			for p := e.Port; p <= e.Last(); p++ {
				add(domain{host: e.Host, port: p})
			}
		}
	}
	// A *.t:p domain outranks both the "*" host's *.s:* routes and an h:*
	// domain, so where it matches their hosts add the narrower *.s:p or
	// h:p, which the ways below give both entries' allows. *.s:p first:
	// it can itself outrank an h:*.
	for _, e := range wildAll {
		for _, d := range slices.Clone(domains) {
			if !d.all && isWild(d.host) && d.host != e.Host && policy.HostCovers(d.host, e.Host) {
				add(domain{host: e.Host, port: d.port})
			}
		}
	}
	for _, a := range slices.Clone(domains) {
		if !a.all {
			continue
		}
		for _, d := range slices.Clone(domains) {
			if !d.all && isWild(d.host) && policy.HostCovers(d.host, a.host) {
				add(domain{host: a.host, port: d.port})
			}
		}
	}
	return domains, wildAll, intercepted
}

// portRE matches exactly the ports 1 to 65535, written without leading
// zeros. Envoy matches a domain such as api.s:443 by string, so a looser
// :authority regex (0443, 0, 65536) would let a request miss an exact
// domain, the interception virtual host among them, and fall to a raw
// tunnel.
const portRE = "(?:[1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])"

// routeConfig allows CONNECT to what tunnel entries name and plain HTTP to
// what plain entries name, and answers every other request 403. Envoy
// picks a request's virtual host by its most specific matching domain
// (exact, then the longest *.suffix, then host:*, then "*"), and only then
// its routes, so:
//
//   - each domain is in one virtual host (Envoy refuses one in two):
//     "allowed" for CONNECT only, "plain" for plain HTTP only,
//     "allowed-plain" for both, "ports-HOST" for HOST:*, whose routes
//     also require the authority to be HOST:digits;
//   - a range is one host:port domain per port (at most
//     policy.MaxPortRange); *.s:*, which no domain can say, is a route in
//     the "*" host matching the authority by regex;
//   - each domain allows every way any entry covering it does
//     (policy.Covers), and where a more specific domain would take a
//     request only a less specific one's entries allow, their
//     intersection is added as a domain of its own;
//   - a plain request without a port (HTTP clients leave out :80) matches
//     a bare host, emitted for each domain host plain HTTP reaches on
//     port 80.
//
// A CONNECT to an intercepted host that entries allow on port 443 goes to
// that host's internal listener, from a virtual host of its own that no
// other domain shares; its 403 refuses plain HTTP there, so plain HTTP
// never reaches an interception. Ports are never stripped. With no
// entries only the deny host is emitted.
func routeConfig(entries []policy.Entry, intercepts []Intercept) obj {
	forbidden := obj{"status": 403}
	domains, wildAll, intercepted := planDomains(entries, intercepts)
	// waysOf is how entries allow host on port, or on every port.
	waysOf := func(host string, port int, all bool) (connect, plain bool) {
		want := policy.Entry{Host: host, Port: port}
		if all {
			want.Port, want.PortEnd = 1, 65535
		}
		for _, e := range entries {
			if policy.Covers(e, want) {
				plain = plain || e.Plain
				connect = connect || !e.Plain
			}
		}
		return connect, plain
	}
	refuseConnect := obj{"match": obj{"connect_matcher": obj{}}, "direct_response": forbidden}
	refuseRest := obj{"match": obj{"prefix": "/"}, "direct_response": forbidden}
	var connectOnly, plainOnly, both, portHosts []any
	group := func(name string, connect, plain bool) {
		switch {
		case connect && plain:
			both = append(both, name)
		case plain:
			plainOnly = append(plainOnly, name)
		case connect:
			connectOnly = append(connectOnly, name)
		}
	}
	bare := map[string]bool{}
	for _, d := range domains {
		if d.all {
			connect, plain := waysOf(d.host, 0, true)
			guard := "(?i)^" + regexp.QuoteMeta(d.host) + ":" + portRE + "$"
			var routes []any
			if connect {
				routes = append(routes, matchAuthority(connectRoute("egress"), guard))
			}
			if plain {
				routes = append(routes, matchAuthority(plainRoute(), guard))
			}
			portHosts = append(portHosts, obj{
				"name":    "ports-" + d.host,
				"domains": []any{d.host + ":*"},
				"routes":  append(routes, refuseConnect, refuseRest),
			})
		} else {
			connect, plain := waysOf(d.host, d.port, false)
			group(policy.Entry{Host: d.host, Port: d.port}.Authority(), connect, plain)
		}
	}
	for _, d := range domains {
		if bare[d.host] {
			continue
		}
		bare[d.host] = true
		if connect, plain := waysOf(d.host, policy.PlainPort, false); plain {
			group(d.host, connect, plain)
		}
	}
	var vhosts []any
	for _, v := range []struct {
		name    string
		domains []any
		routes  []any
	}{
		{"allowed", connectOnly, []any{connectRoute("egress"), refuseRest}},
		{"plain", plainOnly, []any{refuseConnect, plainRoute()}},
		{"allowed-plain", both, []any{connectRoute("egress"), plainRoute()}},
	} {
		if len(v.domains) > 0 {
			vhosts = append(vhosts, obj{"name": v.name, "domains": v.domains, "routes": v.routes})
		}
	}
	vhosts = append(vhosts, portHosts...)
	for _, i := range intercepts {
		e := policy.Entry{Host: i.Host, Port: policy.DefaultPort}
		if !intercepted[e] {
			continue
		}
		vhosts = append(vhosts, obj{
			"name":    interceptName(i.Host),
			"domains": []any{e.Authority()},
			"routes":  []any{connectRoute(interceptName(i.Host)), refuseRest},
		})
	}
	var denyRoutes []any
	for _, e := range wildAll {
		sub := "(?i)^([a-z0-9-]+\\.)+" + regexp.QuoteMeta(strings.TrimPrefix(e.Host, "*."))
		if e.Plain {
			denyRoutes = append(denyRoutes, matchAuthority(plainRoute(), sub+"(:"+portRE+")?$"))
		} else {
			denyRoutes = append(denyRoutes, matchAuthority(connectRoute("egress"), sub+":"+portRE+"$"))
		}
	}
	vhosts = append(vhosts, obj{
		"name":    "deny",
		"domains": []any{"*"},
		"routes":  append(denyRoutes, refuseConnect, refuseRest),
	})
	return obj{"name": "egress", "virtual_hosts": vhosts}
}

// connectRoute terminates a CONNECT and sends the tunnel's bytes to
// cluster.
func connectRoute(cluster string) obj {
	return obj{
		"match": obj{"connect_matcher": obj{}},
		"route": obj{
			"cluster": cluster,
			// The default 15s route timeout starts at downstream
			// end-of-stream and would cut a half-closed tunnel.
			"timeout":         "0s",
			"upgrade_configs": []any{obj{"upgrade_type": "CONNECT", "connect_config": obj{}}},
		},
	}
}

// plainRoute forwards a plain-HTTP request to the forward-proxy cluster,
// which resolves the authority the virtual host matched. Its timeout is
// off as connectRoute's is: the default 15s would cut a slow download,
// and the connection manager's stream_idle_timeout still reaps a stalled
// one.
func plainRoute() obj {
	return obj{
		"match": obj{"prefix": "/"},
		"route": obj{"cluster": "egress", "timeout": "0s"},
	}
}

// matchAuthority narrows route to requests whose :authority matches re
// (RE2): a host:* domain matches any text after the colon, and *.s:* has
// no domain at all, so the regex is what holds them to host:digits.
func matchAuthority(route obj, re string) obj {
	route["match"].(obj)["headers"] = []any{obj{
		"name":         ":authority",
		"string_match": obj{"safe_regex": obj{"regex": re}},
	}}
	return route
}

// interceptName names host's internal listener, the cluster that reaches
// it and its credential; upstreamName names the cluster to the host
// itself.
func interceptName(host string) string { return "intercept-" + host }
func upstreamName(host string) string  { return "upstream-" + host }

// interceptResources are the listeners and clusters that terminate each
// intercepted host's CONNECTs and forward its requests.
func interceptResources(intercepts []Intercept) (listeners, clusters []obj) {
	for _, i := range intercepts {
		listeners = append(listeners, interceptListener(i))
		clusters = append(clusters, interceptCluster(i.Host), upstreamCluster(i.Host))
	}
	return listeners, clusters
}

// interceptListener terminates TLS for i.Host with its leaf, sets i's
// header from its credential file, overwriting whatever the agent sent,
// and routes every request to the host itself, whatever its Host header
// says. Only a ClientHello naming i.Host gets a filter chain, so a tunnel
// allowed for one credential host cannot ask for another's. It keeps no
// access log: the outer listener logs the CONNECT, and no log records
// request headers. h2 or HTTP/1.1 is what the client's ALPN chose.
func interceptListener(i Intercept) obj {
	hcm := obj{
		"@type":       typeHCM,
		"stat_prefix": "intercept",
		"codec_type":  "AUTO",
		// As on the outer listener: a model stream may be quiet a while.
		"stream_idle_timeout": "3600s",
		"route_config": obj{
			"name": interceptName(i.Host),
			"virtual_hosts": []any{obj{
				"name":    i.Host,
				"domains": []any{"*"},
				"routes": []any{obj{
					"match": obj{"prefix": "/"},
					// No route timeout: a streamed response may run long.
					// The upstream sees i.Host whatever Host the agent
					// sent, so on a shared CDN the key cannot be fronted
					// to another tenant's origin.
					"route": obj{"cluster": upstreamName(i.Host), "timeout": "0s", "host_rewrite_literal": i.Host},
				}},
			}},
		},
		"http_filters": []any{
			obj{"name": "envoy.filters.http.credential_injector", "typed_config": obj{
				"@type":     typeCredentialInjector,
				"overwrite": true,
				"credential": obj{"name": "envoy.http.injected_credentials.generic", "typed_config": obj{
					"@type": typeGenericCredential,
					"credential": obj{
						"name":       interceptName(i.Host),
						"sds_config": obj{"path_config_source": obj{"path": SecretsDir + "/" + CredentialFile(i.Host)}},
					},
					"header": i.Header,
				}},
			}},
			obj{"name": "envoy.filters.http.router", "typed_config": obj{"@type": typeRouter}},
		},
	}
	return obj{
		"name":              interceptName(i.Host),
		"internal_listener": obj{},
		"listener_filters":  []any{obj{"name": "envoy.filters.listener.tls_inspector", "typed_config": obj{"@type": typeTLSInspector}}},
		"filter_chains": []any{obj{
			"filter_chain_match": obj{"server_names": []any{i.Host}},
			"transport_socket": obj{"name": "envoy.transport_sockets.tls", "typed_config": obj{
				"@type": typeDownstreamTLS,
				"common_tls_context": obj{
					"alpn_protocols": []any{"h2", "http/1.1"},
					"tls_certificates": []any{obj{
						"certificate_chain": obj{"filename": SecretsDir + "/" + CertFile(i.Host)},
						"private_key":       obj{"filename": SecretsDir + "/" + KeyFile(i.Host)},
					}},
				},
			}},
			"filters": []any{obj{"name": "envoy.filters.network.http_connection_manager", "typed_config": hcm}},
		}},
	}
}

// interceptCluster reaches host's internal listener.
func interceptCluster(host string) obj {
	return obj{
		"name":            interceptName(host),
		"connect_timeout": "5s",
		"load_assignment": obj{
			"cluster_name": interceptName(host),
			"endpoints": []any{obj{"lb_endpoints": []any{obj{"endpoint": obj{"address": obj{
				"envoy_internal_address": obj{"server_listener_name": interceptName(host)},
			}}}}}},
		},
	}
}

// upstreamCluster is host itself on port 443, over TLS with SNI host,
// verified against SystemCABundle and required to name host. A failed
// verification is a 503 to the agent.
func upstreamCluster(host string) obj {
	return obj{
		"name":              upstreamName(host),
		"connect_timeout":   "5s",
		"type":              "LOGICAL_DNS",
		"dns_lookup_family": "V4_ONLY",
		"load_assignment": obj{
			"cluster_name": upstreamName(host),
			"endpoints":    []any{obj{"lb_endpoints": []any{obj{"endpoint": obj{"address": socketAddress(host, 443)}}}}},
		},
		"typed_extension_protocol_options": obj{"envoy.extensions.upstreams.http.v3.HttpProtocolOptions": obj{
			"@type":       typeHTTPProtocolOptions,
			"auto_config": obj{"http2_protocol_options": obj{}, "http_protocol_options": obj{}},
		}},
		"transport_socket": obj{"name": "envoy.transport_sockets.tls", "typed_config": obj{
			"@type": typeUpstreamTLS,
			"sni":   host,
			"common_tls_context": obj{
				"alpn_protocols": []any{"h2", "http/1.1"},
				"validation_context": obj{
					"trusted_ca":                    obj{"filename": SystemCABundle},
					"match_typed_subject_alt_names": []any{obj{"san_type": "DNS", "matcher": obj{"exact": host}}},
				},
			},
		}},
	}
}

// mustMarshal encodes v as indented JSON with a trailing newline. It panics on
// error, which cannot happen: v holds only maps, slices, strings and ints.
func mustMarshal(v any) []byte {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		panic("envoyconfig: " + err.Error())
	}
	return append(b, '\n')
}
