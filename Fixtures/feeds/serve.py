# SPDX-License-Identifier: GPL-3.0-or-later
# Local feed host for sudamp's M7 live checks (docs/spikes/M7-feed.md). Python 3 standard library only.
#
#   python3 -I Fixtures/feeds/serve.py <dir> --port 18471 [--log requests.jsonl]   serve <dir>/feed.json(.sig)
#   python3 -I Fixtures/feeds/serve.py --blackhole --port 18472                    accept, read, never answer
#
# The server binds 127.0.0.1 only, sends a strong ETag (first 16 hex digits of the body's SHA-256) and answers a
# matching If-None-Match with 304, like GitHub Pages. Each request's path, status and headers go to --log as JSON
# lines, so a check can prove the client sent `User-Agent: sudamp/<ver>`, `If-None-Match` and nothing identifying.
import argparse, hashlib, http.server, json, os, socket, threading, time

def serve(root, port, log):
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self):
            name = os.path.basename(self.path.split("?")[0])
            path = os.path.join(root, name)
            entry = {"t": time.time(), "path": self.path, "headers": dict(self.headers.items())}
            if not os.path.isfile(path):
                return self._reply(entry, 404, b"", {})
            body = open(path, "rb").read()
            etag = '"' + hashlib.sha256(body).hexdigest()[:16] + '"'
            if self.headers.get("If-None-Match") == etag:
                return self._reply(entry, 304, b"", {"ETag": etag})
            kind = "application/json" if name.endswith(".json") else "application/octet-stream"
            return self._reply(entry, 200, body, {"ETag": etag, "Content-Type": kind})

        def _reply(self, entry, status, body, headers):
            entry["status"] = status
            if log:
                with open(log, "a") as f:
                    f.write(json.dumps(entry) + "\n")
            self.send_response(status)
            for k, v in headers.items():
                self.send_header(k, v)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()

def blackhole(port):
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port))
    s.listen(16)

    def hold(c):
        try:
            while c.recv(65536):
                pass
        except OSError:
            pass

    while True:
        c, _ = s.accept()
        threading.Thread(target=hold, args=(c,), daemon=True).start()

if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("dir", nargs="?")
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--log")
    p.add_argument("--blackhole", action="store_true")
    a = p.parse_args()
    if a.blackhole:
        blackhole(a.port)
    else:
        serve(a.dir, a.port, a.log)
