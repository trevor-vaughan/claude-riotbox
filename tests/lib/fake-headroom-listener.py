#!/usr/bin/env python3
"""Fake listener for the headroom helper tests.

usage: fake-headroom-listener.py <port> [headroom|foreign] [lifetime]

Serves HTTP on 127.0.0.1:<port> for <lifetime> seconds (default 30), then
exits whatever happened, so no case can leave one behind. http.server reads
each request whole, however the client segments it. "headroom" answers like
headroom 0.39.0's /livez (proxy/server.py:3832-3847):
{"service":"headroom-proxy","status":"healthy"}. "foreign" answers like any
other dev server on the port (wrangler dev defaults to 8787).

With FAKE_PIDFILE set, appends its PID to that file before binding, so a
case's EXIT trap can kill every fake it started, including those the fake
`headroom proxy` execs.
"""

import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port = int(sys.argv[1])
mode = sys.argv[2] if len(sys.argv) > 2 else "headroom"
lifetime = float(sys.argv[3]) if len(sys.argv) > 3 else 30.0

pidfile = os.environ.get("FAKE_PIDFILE")
if pidfile:
    with open(pidfile, "a", encoding="utf-8") as f:
        f.write(f"{os.getpid()}\n")

if mode == "headroom":
    BODY = json.dumps(
        {"service": "headroom-proxy", "status": "healthy", "alive": True},
        separators=(",", ":"),
    ).encode()
    CONTENT_TYPE = "application/json"
else:
    BODY = b"<html>wrangler dev</html>"
    CONTENT_TYPE = "text/html"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802 - http.server's naming
        self.send_response(200)
        self.send_header("Content-Type", CONTENT_TYPE)
        self.send_header("Content-Length", str(len(BODY)))
        self.end_headers()
        self.wfile.write(BODY)

    def log_message(self, *args):  # silence per-request logging
        pass


ThreadingHTTPServer.allow_reuse_address = True
server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
server.daemon_threads = True
threading.Thread(target=server.serve_forever, daemon=True).start()
threading.Event().wait(lifetime)
server.shutdown()
server.server_close()
