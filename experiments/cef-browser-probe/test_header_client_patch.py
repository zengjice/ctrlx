#!/usr/bin/env python3
"""Check patched continuations without building Chromium; not CEF acceptance."""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile


def continuation(source, name):
    start = source.index(f'void InterceptedRequest::{name}(')
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    declaration_start = source.index(f'  void {name}(')
    declaration_end = source.index(';', declaration_start) + 1
    declaration = source[declaration_start:declaration_end].strip()
    definition_signature = source[start:opening].replace('InterceptedRequest::', '').strip() + ';'
    assert declaration.split() == definition_signature.split(), f'{name}: declaration/definition mismatch'
    return declaration, source[start:end]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cef-source', type=Path, required=True, help='Unpatched, pinned CEF source tree')
    parser.add_argument('--cef-sdk', type=Path, required=True, help='Pinned CEF SDK with include/base headers')
    parser.add_argument('--patch', type=Path, default=Path(__file__).resolve().parents[2] /
                        'CtrlxPackage/AgentBrowser/cef-patches/extension-header-client.patch')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='ctrlx-header-client-test-') as temporary:
        work = Path(temporary)
        paths = ('libcef/browser/chrome/chrome_content_browser_client_cef.cc',
                 'libcef/browser/net_service/proxy_url_loader_factory.h',
                 'libcef/browser/net_service/proxy_url_loader_factory.cc')
        for path in paths:
            target = work / path
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(args.cef_source / path, target)
        subprocess.run(['git', 'apply', '--check', str(args.patch.resolve())], cwd=work, check=True)
        subprocess.run(['git', 'apply', str(args.patch.resolve())], cwd=work, check=True)
        source = (work / paths[-1]).read_text()
        methods = [continuation(source, name) for name in (
            'ContinueBeforeSendHeaders', 'ContinueHeadersReceived', 'FinishHeadersReceived')]
        (work / 'declarations.inc').write_text('\n'.join(m[0] for m in methods))
        # Compile the actual request/response finishing bodies, not copies of
        # their implementation. The response-receive method needs the full CEF
        # pipeline; only its binding signature is checked here.
        (work / 'continuations.inc').write_text(methods[0][1] + '\n' + methods[2][1])
        harness = Path(__file__).with_name('header-client-patch-test.cc')
        compiler = ['xcrun', 'clang++', '-std=c++20', '-Wall', '-Wextra', '-Werror', '-I', str(work)]
        subprocess.run(compiler + ['-DCTRLX_NATIVE_BIND_CHECK', '-isystem', str(args.cef_sdk.resolve()),
                                   '-fsyntax-only', str(harness)], check=True)
        print('CEF callback signature checks passed.', flush=True)
        executable = work / 'continuations-test'
        subprocess.run(compiler + [str(harness), '-o', str(executable)], check=True)
        subprocess.run([str(executable)], check=True)


if __name__ == '__main__':
    main()
