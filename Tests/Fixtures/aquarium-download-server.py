"""Local HTTPS fixture for the native resource download checks; never contacts a remote host."""
import hashlib
import http.server
import json
from pathlib import Path
import ssl
import sys
import time
import zipfile

root = Path(sys.argv[1])
# Incompressible data lets the test observe progress and cancel an active request.
data = bytes(hashlib.sha256(str(i).encode()).digest()[0] for i in range(2 * 1024 * 1024))
with zipfile.ZipFile(root / 'pack.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
    archive.writestr('AquariumAssets/fixture.png', data)
packed = (root / 'pack.zip').read_bytes()
(root / 'manifest.json').write_text(json.dumps({
    'schema': 1, 'version': 1, 'url': 'https://localhost/fixture',
    'archiveBytes': len(packed), 'sha256': hashlib.sha256(packed).hexdigest(),
    'installedBytes': len(data), 'files': [
        {'path': 'fixture.png', 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
    ]}))


class Handler(http.server.BaseHTTPRequestHandler):
    failures = 0
    slow_requests = 0

    def log_message(self, *args):
        pass

    def do_GET(self):
        with (root / 'requests.log').open('a') as log:
            log.write(self.path + '\n')
        if self.path == '/missing':
            self.send_error(404)
            return
        if self.path == '/flaky' and Handler.failures == 0:
            Handler.failures += 1
            self.send_error(503)
            return
        if self.path == '/slow':
            Handler.slow_requests += 1
        slow = self.path == '/slow' and Handler.slow_requests == 1
        body = packed if self.path != '/corrupt' else bytes([packed[0] ^ 1]) + packed[1:]
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        if self.path == '/partial':
            body = body[:len(body) // 2]
        try:
            for offset in range(0, len(body), 16384):
                self.wfile.write(body[offset:offset + 16384])
                self.wfile.flush()
                if slow:
                    time.sleep(0.1)
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            pass


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(root / 'cert.pem', root / 'key.pem')
server.socket = context.wrap_socket(server.socket, server_side=True)
(root / 'server-url').write_text(f'https://localhost:{server.server_port}')
server.serve_forever()
