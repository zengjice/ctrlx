"""Loopback CORS fixture and strict acceptance for extension header injection."""
import json
from pathlib import Path
from urllib.parse import urlsplit


class CORSFixture:
    def __init__(self):
        self.requests = []

    def handle(self, handler):
        path = urlsplit(handler.path).path
        if not path.startswith('/cors/'):
            return False
        header = handler.headers.get('x-maas-env')
        self.requests.append({
            'method': handler.command, 'path': path,
            'origin': handler.headers.get('Origin'),
            'requestedHeaders': handler.headers.get('Access-Control-Request-Headers'),
            'injectedHeader': header,
        })
        if handler.command == 'POST':
            size = int(handler.headers.get('Content-Length', '0'))
            if not 0 <= size <= 1024:
                handler.send_error(400)
                return True
            handler.rfile.read(size)
        content_type = 'application/json'
        body = json.dumps({'header': header}).encode()
        status = 200
        redirects = {
            '/cors/redirect': '/cors/redirect-final',
            '/cors/redirect-chain': '/cors/redirect',
            '/cors/same-to-cross': f'http://localhost:{handler.server.server_port}/cors/redirect-final',
            '/cors/page-env-redirect': f'http://localhost:{handler.server.server_port}/cors/page-env-header',
        }
        if handler.command == 'OPTIONS':
            status, body = 204, b''
        elif path in redirects:
            status, body = 302, b''
        elif path == '/cors/script.js':
            content_type = 'application/javascript'
            body = ('window.ctrlxCORSScript = ' + json.dumps(header) + ';').encode()
        elif path == '/cors/probe.js':
            content_type = 'application/javascript'
            body = Path(__file__).with_name('extension-cors.js').read_bytes()
        handler.send_response(status)
        if path != '/cors/no-origin':
            handler.send_header('Access-Control-Allow-Origin', f'http://127.0.0.1:{handler.server.server_port}')
        # Deliberately exclude the extension header and the page's forbidden
        # header. Only Chrome's trusted extension path should add x-maas-env.
        handler.send_header('Access-Control-Allow-Headers', 'content-type')
        handler.send_header('Access-Control-Allow-Methods', 'GET, POST')
        handler.send_header('Access-Control-Expose-Headers', 'x-ctrlx-response')
        if status == 302:
            handler.send_header('Location', redirects[path])
        handler.send_header('Cache-Control', 'no-store')
        handler.send_header('Content-Type', content_type)
        handler.send_header('Content-Length', str(len(body)))
        handler.end_headers()
        handler.wfile.write(body)
        return True

    def acceptance(self, phases, env):
        names = ('env-cors-alloy', 'env-cors-chrome') if env else (
            'alloy-with-manager', 'alloy-without-manager', 'chrome-control', 'chrome-other-window')
        checks = {}
        for name in names:
            result = phases.get(name, {})
            result = result if env else (result.get('cors') or {})
            passed = all(result.get(key, {}).get('ok') is True and
                         result[key].get('body', {}).get('header') == 'ark-chat-dev'
                         for key in ('same', 'get', 'post', 'redirect', 'sameToCross', 'redirectChain'))
            passed &= (result.get('script', {}).get('ok') is True and
                       result['script'].get('header') == 'ark-chat-dev')
            passed &= all(result.get(key, {}).get('ok') is False and
                          'TypeError' in result[key].get('error', '')
                          for key in ('deniedOrigin', 'deniedHeader', 'deniedSameHeader', 'deniedRedirectHeader'))
            if not env:
                passed &= result.get('get', {}).get('responseHeader') == 'response-active'
            checks[name] = passed
        preflights = [r for r in self.requests if r['method'] == 'OPTIONS']
        checks['normalPreflightPreserved'] = any(
            r['path'] == '/cors/post' and r['requestedHeaders'] == 'content-type' for r in preflights)
        checks['pageHeaderStillChecked'] = any(
            r['path'] == '/cors/page-header' and 'x-ctrlx-page' in (r['requestedHeaders'] or '')
            for r in preflights)
        checks['pageAddedEnvironmentHeaderStillChecked'] = any(
            r['path'] == '/cors/page-env-header' and 'x-maas-env' in (r['requestedHeaders'] or '')
            for r in preflights)
        checks['extensionHeaderNotPreflighted'] = bool(preflights) and not any(
            'x-maas-env' in (r['requestedHeaders'] or '') for r in preflights
            if r['path'] != '/cors/page-env-header')
        checks['redirectTargetReceivedExtensionHeader'] = any(
            r['path'] == '/cors/redirect-final' and r['method'] == 'GET' and
            r['injectedHeader'] == 'ark-chat-dev' for r in self.requests)
        return checks
