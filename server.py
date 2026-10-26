#!/usr/bin/env python3
"""HTTPS front end for qwd.

Serves the WebXR page under a secret path, starts qwd when the first viewer connects and
stops it when the last one leaves, fans its messages out on /stream (only the latest frame
per window is queued, so slow Wi-Fi drops frames instead of lagging) and feeds /input to it.
"""
import hmac, json, os, ssl, subprocess, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
PORT = int(os.environ.get("QW_PORT", "8443"))
TOKEN = open(os.path.join(HERE, "token")).read().strip().encode()

cv = threading.Condition()
inlock = threading.Lock()
clients = []    # one dict per viewer: message key -> pending message
state = {}      # latest message per key, replayed to new viewers
worker = None


def pump(proc):
    out = proc.stdout
    while True:
        hdr = out.read(9)
        if len(hdr) < 9:
            break
        msg = hdr + out.read(int.from_bytes(hdr[5:9], "big"))
        key = hdr[:5]   # type + window id
        with cv:
            if proc is not worker:
                return
            if hdr[0] == 2:   # window list: forget frames of closed windows
                live = {w["id"] for w in json.loads(msg[9:])}
                for k in [k for k in state if k[0] == 1 and int.from_bytes(k[1:5], "big") not in live]:
                    del state[k]
            state[key] = msg
            for q in clients:
                q[key] = msg
            cv.notify_all()
    with cv:   # qwd died: viewers reconnect, which respawns it
        for q in clients:
            q[None] = None
        cv.notify_all()


def start_worker():
    global worker
    if worker and worker.poll() is None:
        return
    state.clear()
    worker = subprocess.Popen([os.path.join(HERE, "qwd")], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    subprocess.Popen(["caffeinate", "-d", "-w", str(worker.pid)])   # a sleeping display stops the capture
    threading.Thread(target=pump, args=(worker,), daemon=True).start()


def stop_worker():
    global worker
    if worker:
        worker.terminate()
        worker = None
    state.clear()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def setup(self):
        self.request.settimeout(30)
        self.request.do_handshake()
        super().setup()

    def route(self):
        parts = self.path.split("?")[0].split("/")
        if len(parts) == 3 and hmac.compare_digest(parts[1].encode(), TOKEN):
            return parts[2]
        return None

    def reply(self, code, body=b"", ctype="text/plain"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        r = self.route()
        if r == "":
            with open(os.path.join(HERE, "index.html"), "rb") as f:
                self.reply(200, f.read(), "text/html; charset=utf-8")
        elif r == "stream":
            self.stream()
        else:
            self.reply(404)

    def do_POST(self):
        body = self.rfile.read(min(int(self.headers.get("Content-Length") or 0), 1 << 20))
        if self.route() != "input":
            return self.reply(404)
        try:
            lines = b"".join(json.dumps(e).encode() + b"\n" for e in json.loads(body) if isinstance(e, dict))
            with inlock:
                w = worker
                if w:
                    w.stdin.write(lines)
                    w.stdin.flush()
        except (ValueError, TypeError, OSError):
            pass
        self.reply(200)

    def stream(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        with cv:
            start_worker()
            q = dict(state)
            clients.append(q)
        try:
            while True:
                with cv:
                    if not q:
                        cv.wait(5)
                    if None in q:
                        return
                    # window lists before frames; an empty keepalive notices viewers that left
                    batch = sorted(q.values(), key=lambda m: m[0] != 2) or [bytes(9)]
                    q.clear()
                self.wfile.write(b"".join(batch))
                self.wfile.flush()
        except OSError:
            pass
        finally:
            with cv:
                clients.remove(q)
                if not clients:
                    stop_worker()


class Server(ThreadingHTTPServer):
    def handle_error(self, request, client_address):
        if not isinstance(sys.exc_info()[1], OSError):   # skip dropped viewers and browsers refusing the self-signed cert
            super().handle_error(request, client_address)


ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(os.path.join(HERE, "cert.pem"), os.path.join(HERE, "key.pem"))
httpd = Server(("", PORT), Handler)
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True, do_handshake_on_connect=False)
print(f"quest-windows listening on :{PORT}", flush=True)
httpd.serve_forever()
