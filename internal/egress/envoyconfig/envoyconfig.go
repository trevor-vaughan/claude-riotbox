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
package envoyconfig

import (
	"encoding/json"
	"maps"

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
)

type obj = map[string]any

// Files is one proxy's configuration, a field per file in ConfigDir.
type Files struct {
	Bootstrap, CDS, LDS, RDS []byte
}

// Render returns the four files of session's proxy enforcing entries.
// session goes into the denial message (localReply); it is a state.Dir
// name, which holds no "%", so Envoy reads no command operator in it.
func Render(session string, entries []policy.Entry) Files {
	return Files{
		Bootstrap: mustMarshal(obj{
			"node": node(),
			"dynamic_resources": obj{
				"lds_config": fileSource(LDSFile),
				"cds_config": fileSource(CDSFile),
			},
		}),
		CDS: mustMarshal(resources(typeCluster, cluster())),
		LDS: mustMarshal(resources(typeListener, listener(session, obj{
			"rds": obj{"route_config_name": "egress", "config_source": fileSource(RDSFile)},
		}))),
		RDS: RenderRDS(entries),
	}
}

// RenderRDS returns rds.json: the route configuration enforcing entries.
func RenderRDS(entries []policy.Entry) []byte {
	return mustMarshal(resources(typeRoute, routeConfig(entries)))
}

// RenderStatic returns one bootstrap with the listener, cluster and routes
// inlined. It exists for tests: `envoy --mode validate` does not load
// dynamic resources from files, so this is the form that can be validated.
func RenderStatic(session string, entries []policy.Entry) []byte {
	return mustMarshal(obj{
		"node": node(),
		"static_resources": obj{
			"listeners": []any{listener(session, obj{"route_config": routeConfig(entries)})},
			"clusters":  []any{cluster()},
		},
	})
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

// resources wraps one freshly built resource (it is modified in place) as an xDS discovery file, typed by typeURL.
func resources(typeURL string, resource obj) obj {
	resource["@type"] = typeURL
	return obj{"resources": []any{resource}}
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
// host; any other method (plain HTTP, never proxied) is told to use
// HTTPS, since allowing the host cannot help it. %REQ(:AUTHORITY)% is the
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
		denied(refused, "riotbox egress: "+authority+" was refused: plain HTTP is never proxied by this session's egress proxy.\n"+
			"Use HTTPS; allowing the host will not help.\n"),
	}}
}

// routeConfig allows CONNECT to each entry's host:port and answers every
// other request 403. With no entries only the deny host is emitted (an
// empty domains list is invalid).
func routeConfig(entries []policy.Entry) obj {
	forbidden := obj{"status": 403}
	var vhosts []any
	if len(entries) > 0 {
		domains := make([]any, 0, len(entries))
		for _, e := range entries {
			domains = append(domains, e.Authority())
		}
		vhosts = append(vhosts, obj{
			"name":    "allowed",
			"domains": domains,
			"routes": []any{
				obj{
					"match": obj{"connect_matcher": obj{}},
					"route": obj{
						"cluster": "egress",
						// The default 15s route timeout starts at downstream
						// end-of-stream and would cut a half-closed tunnel.
						"timeout":         "0s",
						"upgrade_configs": []any{obj{"upgrade_type": "CONNECT", "connect_config": obj{}}},
					},
				},
				obj{"match": obj{"prefix": "/"}, "direct_response": forbidden},
			},
		})
	}
	vhosts = append(vhosts, obj{
		"name":    "deny",
		"domains": []any{"*"},
		"routes": []any{
			obj{"match": obj{"connect_matcher": obj{}}, "direct_response": forbidden},
			obj{"match": obj{"prefix": "/"}, "direct_response": forbidden},
		},
	})
	return obj{"name": "egress", "virtual_hosts": vhosts}
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
