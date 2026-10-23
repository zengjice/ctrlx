#!/usr/bin/env python3
"""CLI parsing/fail-closed checks; no browser or real agent is started."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile

cli = str(Path(sys.argv[1]).resolve())

# Tests can themselves be launched by an agent. Reparent a fixture process to
# launchd before invoking the CLI so negative tests have NO agent ancestor.
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

clean_env = {k: v for k, v in os.environ.items()
             if k not in ('CTRLX_BROWSER_CONTEXT', 'CTRLX_BROWSER_LABEL')}
for operation in ('identity', 'action tabs'):
    missing = run(['browser', *operation.split()], env=clean_env)
    assert missing.returncode != 0 and 'Cannot identify a calling agent' in missing.stderr, missing
    borrowed = run(['browser', *operation.split()], env=dict(clean_env, CTRLX_BROWSER_CONTEXT='/another/instance/context.json'))
    assert borrowed.returncode != 0 and 'Cannot identify a calling agent' in borrowed.stderr, borrowed

unsupported = run(['browser', 'action', 'Runtime.evaluate'])
assert unsupported.returncode != 0 and 'Unsupported browser operation' in unsupported.stderr
for operation, flags in (
    ('open', ['--url', 'https://example.test']),
    ('open', ['--new', '--url', 'https://example.test']),
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
    assert parsed.returncode != 0 and 'Cannot identify a calling agent' in parsed.stderr, (operation, parsed.stderr)
for operation, flags, error in (
    ('read', ['--new'], '--new is only supported by open'),
    ('fill', ['--selector', '#input'], '--text'),
    ('press', [], '--key'), ('select', ['--selector', '#input'], '--value'),
    ('check', ['--selector', '#input'], '--checked'),
):
    invalid = run(['browser', 'action', operation, '--tab', 'test', *flags], env=clean_env)
    assert invalid.returncode != 0 and error in invalid.stderr, invalid.stderr

for arguments, message in (
    (['command', '--tab', 'test', '--', 'frame', '--url'], 'Use frame'),
    (['command', '--tab', 'test', '--', 'screenshot', '--format', 'gif'], 'format'),
    (['batch', '--tab', 'test', '--commands-json', '[["get","title"],["close"]]'], 'Unsupported'),
    (['batch', '--tab', 'test', '--commands-json', '[["screenshot"]]'], 'Artifact'),
    (['command', '--tab', 'test', '--', 'init', 'remove', 'init-script-1'], 'returned-id'),
    (['record', '--tab', 'test', '--output', '/tmp/not-created.webm', '--seconds', '99'], '1...10'),
    (['record', '--tab', 'test', '--output', '/tmp/not-created.mp4', '--fps', '0'], 'fps'),
    (['record', '--tab', 'test', '--output', '/tmp/not-created.mp4', '--format', 'invalid'], 'format'),
    (['record', '--tab', 'test', '--output', '/tmp/not-created.mp4', '--contact-sheet-threshold', 'nan'], 'threshold'),
    (['command', '--tab', 'test', '--input-file', '/not-read', '--input-stdin', '--', 'eval'], 'not both'),
    (['command', '--tab', 'test', '--', 'network', 'har', 'start', '--content', 'bad'], 'content'),
    (['command', '--tab', 'test', '--', 'network', 'request'], 'request'),
):
    invalid = run(['browser', *arguments], env=clean_env)
    assert invalid.returncode != 0 and message in invalid.stderr, invalid.stderr

for arguments in (
    ['command', '--tab', 'test', '--', 'frame', '--name', 'nested'],
    ['batch', '--tab', 'test', '--commands-json', '[["get","title"]]'],
    ['batch', '--tab', 'test', '--continue-on-error', '--commands-json', '[["get","title"]]'],
    ['command', '--tab', 'test', '--', 'init', 'list'],
    ['setup', '--tab', 'test', '--react'],
    ['command', '--tab', 'test', '--', 'network', 'request', '123.4'],
    ['command', '--tab', 'test', '--', 'network', 'har', 'start', '--content', 'none'],
):
    parsed = run(['browser', *arguments], env=clean_env)
    assert parsed.returncode != 0 and 'Cannot identify a calling agent' in parsed.stderr, parsed.stderr

parsed = run(['browser', 'command', '--tab', 'test', '--input-stdin', '--', 'eval'], env=clean_env, input='1 + 1')
assert parsed.returncode != 0 and 'Cannot identify a calling agent' in parsed.stderr, parsed.stderr
invalid = run(['browser', 'command', '--tab', 'test', '--input-stdin', '--', 'eval'], env=clean_env, input='x' * 48001)
assert invalid.returncode != 0 and '48 KB' in invalid.stderr, invalid.stderr

# The optional launcher preserves quoting/functions, but creates no credentials.
script = 'import os,json,sys; print(json.dumps([os.environ.get("CTRLX_BROWSER_CONTEXT"),sys.argv[1:]]))'
values = ['space here', "single'quote", 'double"quote', '中文', '$literal']
child = run(['browser', 'run', '--', sys.executable, '-c', script, *values], env=clean_env)
assert child.returncode == 0 and json.loads(child.stdout) == [None, values], child
function = 'codex() { ' + shlex.join([sys.executable, '-c', script]) + ' "$@"; }; codex ' + shlex.join(values)
shell = run(['browser', 'run', '--', '/bin/zsh', '-fc', function], env=clean_env)
assert shell.returncode == 0 and json.loads(shell.stdout) == [None, values], shell
# Real kernel ancestry and context persistence, using native fixtures, not agents.
# All saved engine preferences stay under a disposable private state root.
with tempfile.TemporaryDirectory(prefix='ctrlx-browser-callers-') as tmp:
    root = Path(tmp)
    binary = root / 'identity-fixture'
    subprocess.run(['clang++', '-std=c++20', str(Path(__file__).with_name('engine_identity.cc')),
                    '-o', str(binary)], check=True, capture_output=True, timeout=30)
    runtimes = set()
    for relative in ('codex', 'claude', 'share/claude/versions/2.1.276'):
        executable = root / relative
        executable.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(binary, executable)
        state = root / ('state-' + executable.name)
        env = dict(clean_env, CTRLX_BROWSER_TEST_STATE_ROOT=str(state),
                   CTRLX_BROWSER_CONTEXT='/another/instance/context.json')
        commands = '\n'.join(shlex.join([cli, 'browser', *args]) for args in (
            ['identity'], ['engine', 'ctrlx'], ['engine'])) + '\n'
        result = subprocess.run([str(executable)], input=commands, text=True, env=env,
                                capture_output=True, check=True, timeout=15)
        assert not result.stderr, result.stderr
        kernel, identity, selected, saved = map(json.loads, result.stdout.splitlines())
        assert identity['pid'] == kernel['pid'], (kernel, identity)
        assert identity['runtime'] == f"{kernel['pid']}-{kernel['startSeconds']}-{kernel['startMicros']}"
        assert identity['runtime'] not in runtimes
        runtimes.add(identity['runtime'])
        assert selected == saved and selected['engine'] == 'ctrlx' and selected['scope'] == 'calling-agent'
        contexts = list((state / 'agent-browser/runs').glob('*/context.json'))
        assert len(contexts) == 1
        context = json.loads(contexts[0].read_text())
        assert ('Codex' if relative == 'codex' else 'Claude Code') in context['label']
        assert 'socket' not in context  # identity/engine must not connect to the Host
print('PASS: caller identity/context for Codex and Claude native fixtures, no-ancestor/token refusal, launcher/quoting, bounded CLI parsing')
