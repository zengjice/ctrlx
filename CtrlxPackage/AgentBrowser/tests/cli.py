#!/usr/bin/env python3
"""CLI parsing/fail-closed checks; no browser or real agent is started."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

cli = str(Path(sys.argv[1]).resolve())

# Tests can themselves be launched by Codex. Reparent a fixture process to
# launchd before invoking the CLI so negative tests have NO Codex ancestor.
detached = '''import os,sys,time,json,subprocess
if os.fork(): os._exit(0)
deadline=time.monotonic()+5
while os.getppid()!=1 and time.monotonic()<deadline: time.sleep(.01)
assert os.getppid()==1
result=subprocess.run(sys.argv[1:],text=True,capture_output=True,timeout=10)
print(json.dumps([result.returncode,result.stdout,result.stderr]),flush=True)
'''

def run(words, **kwargs):
    fixture = subprocess.run([sys.executable, '-c', detached, cli, *words],
                             text=True, capture_output=True, timeout=15, **kwargs)
    assert fixture.returncode == 0 and not fixture.stderr, fixture
    code, stdout, stderr = json.loads(fixture.stdout)
    return subprocess.CompletedProcess(words, code, stdout, stderr)

clean_env = {k: v for k, v in os.environ.items() if k != 'CTRLX_BROWSER_CONTEXT'}
for operation in ('identity', 'action tabs'):
    missing = run(['browser', *operation.split()], env=clean_env)
    assert missing.returncode != 0 and 'Cannot identify a calling Codex' in missing.stderr, missing
    borrowed = run(['browser', *operation.split()], env=dict(clean_env, CTRLX_BROWSER_CONTEXT='/another/instance/context.json'))
    assert borrowed.returncode != 0 and 'Cannot identify a calling Codex' in borrowed.stderr, borrowed

unsupported = run(['browser', 'action', 'Runtime.evaluate'])
assert unsupported.returncode != 0 and 'Unsupported browser operation' in unsupported.stderr
for operation, flags in (
    ('fill', ['--selector', '#input', '--text', '']),
    ('press', ['--key', 'Shift+Tab']),
    ('scroll', ['--delta-y', '-300']),
    ('wait', ['--selector', '#result', '--state', 'visible', '--timeout-ms', '800']),
    ('select', ['--selector', '#select', '--value', 'value']),
    ('check', ['--selector', '#check', '--checked', 'true']),
    ('check', ['--selector', '#check', '--checked', 'false']),
    ('read', ['--text-offset', '20000', '--text-limit', '2000', '--control-offset', '100', '--control-limit', '10']),
):
    parsed = run(['browser', 'action', operation, '--tab', 'test', *flags], env=clean_env)
    assert parsed.returncode != 0 and 'Cannot identify a calling Codex' in parsed.stderr, (operation, parsed.stderr)
for operation, flags, error in (
    ('fill', ['--selector', '#input'], '--text'),
    ('press', [], '--key'), ('select', ['--selector', '#input'], '--value'),
    ('check', ['--selector', '#input'], '--checked'),
):
    invalid = run(['browser', 'action', operation, '--tab', 'test', *flags], env=clean_env)
    assert invalid.returncode != 0 and error in invalid.stderr, invalid.stderr

# The optional launcher preserves quoting/functions, but creates no credentials.
script = 'import os,json,sys; print(json.dumps([os.environ.get("CTRLX_BROWSER_CONTEXT"),sys.argv[1:]]))'
values = ['space here', "single'quote", 'double"quote', '中文', '$literal']
child = run(['browser', 'run', '--', sys.executable, '-c', script, *values], env=clean_env)
assert child.returncode == 0 and json.loads(child.stdout) == [None, values], child
function = 'codex() { ' + shlex.join([sys.executable, '-c', script]) + ' "$@"; }; codex ' + shlex.join(values)
shell = run(['browser', 'run', '--', '/bin/zsh', '-fc', function], env=clean_env)
assert shell.returncode == 0 and json.loads(shell.stdout) == [None, values], shell
print('PASS: no-ancestor refusal, inherited-token refusal, optional launcher, quoting, shell functions, bounded actions')
