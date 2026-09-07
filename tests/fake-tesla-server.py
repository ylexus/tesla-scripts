import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs

LOG = sys.argv[1]

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(n).decode()
        with open(LOG, 'w') as f:
            json.dump({k: v[0] for k, v in parse_qs(body, keep_blank_values=True).items()}, f)
        if self.path == '/token':
            out = json.dumps({"access_token": "ACCESS.TOKEN.aaa-_1", "refresh_token": "REFRESH.TOKEN.bbb-_2",
                              "id_token": "ID.TOKEN", "expires_in": 28800, "token_type": "Bearer"})
            code = 200
        elif self.path == '/token-noref':
            out = json.dumps({"access_token": "A", "expires_in": 300}); code = 200
        elif self.path == '/token-badredirect':
            out = json.dumps({"error": "invalid_request",
                              "error_description": "The 'redirect_uri' supplied is not registered for this 'client_id'."})
            code = 400
        else:
            out = '{}'; code = 404
        b = out.encode()
        self.send_response(code); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b)
srv = HTTPServer(('127.0.0.1', 0), H)
print(srv.server_port, flush=True)
srv.serve_forever()
