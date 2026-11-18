"""Exercise production model switching against a private Codex and loopback catalog.

No user credentials or model prompts. Requires installed codex and tmux.
Run from any directory: python3 scripts/tests/run_codex_model_refresh.py
"""
import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time

repo = Path(__file__).resolve().parents[2]
root = Path(tempfile.mkdtemp(prefix='ctrlx-model-refresh-', dir='/tmp'))
home = root / 'home'
config = home / '.codex'
config.mkdir(parents=True)
env = {'HOME': str(home), 'CODEX_HOME': str(config), 'PATH': '/opt/homebrew/bin:/usr/bin:/bin',
       'TERM': 'xterm-256color', 'LANG': 'en_US.UTF-8', 'FIXTURE_API_KEY': 'fixture-not-a-secret'}
catalog = json.loads(subprocess.run(['/opt/homebrew/bin/codex', 'debug', 'models', '--bundled'], env=env, capture_output=True, check=True, timeout=15).stdout)
old = next(m for m in catalog['models'] if m['slug'] == 'gpt-6.1-sol')
new = dict(old, slug='gpt-6.2-sol', display_name='GPT-6.2-Sol')
models = [old]
requests = []

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        requests.append(self.path)
        data = json.dumps({'models': models}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def do_POST(self):
        requests.append('POST ' + self.path)
        self.send_error(400, 'No prompts allowed in this fixture')

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
(config / 'config.toml').write_text(f'''model = "gpt-6.1-sol"
model_provider = "fixture"
check_for_update_on_startup = false
[features]
api_key_model_discovery = true
[model_providers.fixture]
name = "Fixture"
base_url = "http://127.0.0.1:{server.server_port}/v1"
model_catalog_url = "http://127.0.0.1:{server.server_port}/models"
wire_api = "responses"
env_key = "FIXTURE_API_KEY"
requires_openai_auth = false
[projects."{root}"]
trust_level = "trusted"
[tui]
status_line = ["model-with-reasoning", "current-dir"]
''')
(config / 'auth.json').write_text(json.dumps({'OPENAI_API_KEY': 'fixture-not-a-secret'}))
base = ['/opt/homebrew/bin/tmux', '-S', str(root / 'tmux.sock'), '-f', '/dev/null']
def tmux(*args):
    return subprocess.run(base + list(args), env=env, capture_output=True, check=True, timeout=8).stdout.decode()
def capture(label):
    s = tmux('capture-pane', '-p', '-t', 'probe:0.0')
    (root / f'{label}.txt').write_text(s)
    print(label, s[-6000:], flush=True)
    return s

try:
    tmux('new-session', '-d', '-s', 'probe', '-x', '150', '-y', '45', '-c', str(root), '/bin/sleep', '600')
    tmux('set-window-option', '-t', 'probe', 'remain-on-exit', 'on')
    tmux('respawn-pane', '-k', '-t', 'probe:0.0', '-c', str(root), '/usr/bin/env', *[f'{k}={v}' for k,v in env.items()],
         '/opt/homebrew/bin/codex', '--no-daemon', '--no-alt-screen')
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        screen = tmux('capture-pane', '-p', '-t', 'probe:0.0')
        if 'GPT-6.1-Sol default · ' in screen:
            break
        time.sleep(.1)
    else:
        raise AssertionError('Native fixture did not become ready: ' + screen)
    capture('startup')
    models.append(new)
    cache_path = config / 'models_cache.json'
    cache = json.loads(cache_path.read_text())
    cache['fetched_at'] = '2000-01-01T00:00:00Z'
    cache_path.write_text(json.dumps(cache))
    (root / 'environment.json').write_text(json.dumps(env))
    test_env = dict(os.environ, CTRLX_MODEL_REFRESH_FIXTURE=str(root))
    result = subprocess.run([str(repo / 'scripts/unit-tests.sh'), '--', '--filter', 'CodexModelRefreshNativeTests'],
                            cwd=repo, env=test_env, timeout=600)
    assert result.returncode == 0, 'Native adapter test failed'
    assert not any(r.startswith('POST ') for r in requests), requests
    print('requests', requests, flush=True)

finally:
    subprocess.run(base + ['kill-server'], env=env, capture_output=True, timeout=8)
    server.shutdown()
    print('root', root, flush=True)
