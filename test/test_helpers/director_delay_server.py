"""Loopback-only HTTP fixture for Director browser transport tests."""
import argparse
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class DelayHandler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "content-type")
        self.end_headers()

    def do_POST(self):
        try:
            self.rfile.read(int(self.headers.get("Content-Length", 0)))
            if self.path in ("/late", "/cancel"):
                time.sleep(0.15)
            self.send_response(200)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            if self.path == "/silent":
                time.sleep(0.3)
            self.wfile.write(b"first")
            self.wfile.flush()
            if self.path == "/idle":
                time.sleep(0.3)
        except (BrokenPipeError, ConnectionResetError):
            pass


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), DelayHandler)
    print(server.server_port, flush=True)
    server.serve_forever()
