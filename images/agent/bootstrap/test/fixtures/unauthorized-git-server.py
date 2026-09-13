#!/usr/bin/env python3
"""An always-401 HTTP server standing in for a git host that demands credentials.

git clones over file:// are never challenged, so this is what makes the suite exercise
sandcastle-askpass: git asks, the helper answers, and every Authorization header the server
receives is written to the log file for the test to inspect. No network, no real credential.

Usage: unauthorized-git-server.py <port-file> <auth-log>
"""

import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT_FILE, AUTH_LOG = sys.argv[1], sys.argv[2]


class UnauthorizedHandler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802 - name fixed by BaseHTTPRequestHandler
        authorization = self.headers.get("Authorization")
        if authorization:
            with open(AUTH_LOG, "a", encoding="utf-8") as log:
                log.write(authorization + "\n")
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="git"')
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *args):
        pass  # keep the fixture out of the test output


server = HTTPServer(("127.0.0.1", 0), UnauthorizedHandler)
with open(PORT_FILE, "w", encoding="utf-8") as handle:
    handle.write(str(server.server_port))
server.serve_forever()
