#!/usr/bin/env python3
"""Debug-mode recording breadcrumbs in a disposable signed Host/private profile."""
import argparse
import asyncio
import json
from pathlib import Path
import signal
import socket
import subprocess
import urllib.request

from long_recording import LongRecording
from page_capabilities import PageCapabilities


class RecordingDiagnostics(LongRecording):
    async def run(self):
        await PageCapabilities.run(self)

    async def setup(self):
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1', 0))
            self.debug_port = reservation.getsockname()[1]
        self.extra_host_arguments = ['--test-accessibility-port', str(self.debug_port)]
        await super().setup()

    async def toggle(self, enabled):
        def update():
            request = urllib.request.Request(
                f'http://127.0.0.1:{self.debug_port}/set-debug-mode?enabled={str(enabled).lower()}', method='POST')
            with urllib.request.urlopen(request, timeout=5) as response:
                assert response.read() == b'ok'
        await asyncio.to_thread(update)

    def reports(self):
        path = self.root / 'browser-diagnostics/browser-current.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    async def validate(self, _):
        self.tab = (await self.cli_action(0, 'action', 'open', '--url', self.url + 'diagnostics'))['result']['id']
        await self.cli_action(0, 'action', 'wait', '--tab', self.tab)
        await self.start('disabled.mp4', seconds=3)
        await self.finished()
        assert not (self.root / 'browser-diagnostics').exists()
        self.passed('Debug Mode defaults off: recording creates no diagnostic files')

        # Enable after recording has already started; keep the other terminal in front.
        await self.start('enabled.mp4', seconds=30)
        await self.control('select-session', 'upstream-beta')
        await self.toggle(True)
        async def sampled():
            return next((r for r in self.reports() if r['browser']['event'] == 'recording-progress'), None)
        sample = await self.wait(sampled, 10)
        assert sample['processID'] == self.host.pid
        assert sample['memory']['residentBytes'] > 0 and sample['memory']['footprintBytes'] > 0
        assert not sample['browser']['pageVisible'], sample
        assert any(w['context']['kind'] == 'main' and not w['context']['browserSelected'] for w in sample['windows'])
        async def twice():
            samples = [r for r in self.reports() if r['browser']['event'] == 'recording-progress']
            return samples if len(samples) >= 2 else None
        samples = await self.wait(twice, 12)
        assert samples[1]['uptimeSeconds'] - samples[0]['uptimeSeconds'] >= 4.9
        self.passed('Enabling during background recording writes 5-second samples, memory and terminal layout')

        await self.toggle(False)
        saved = self.reports()
        frames = (await self.status())['frames']
        await asyncio.sleep(5.5)
        assert self.reports() == saved
        assert (await self.status())['frames'] > frames
        await self.cli_action(0, 'record-stop', '--tab', self.tab)
        await self.finished()
        assert self.reports() == saved
        self.passed('Disabling immediately stops writes and preserves earlier evidence without stopping capture')

        await self.toggle(True)
        await self.start('lifecycle.mp4', seconds=3)
        await self.finished()
        names = {r['browser']['event'] for r in self.reports()}
        assert {'recording-start', 'recording-prepared', 'recording-first-frame', 'recording-stop',
                'recording-finalize', 'recording-finished'} <= names, names
        raw = (self.root / 'browser-diagnostics/browser-current.jsonl').read_text()
        assert str(self.root) not in raw and self.url not in raw
        assert '"path"' not in raw and '"url"' not in raw and '"owner"' not in raw
        self.passed('Lifecycle is complete; diagnostics omit output paths, page URLs and owner secrets')

        interrupted = await self.start('interrupted.mp4', seconds=60)
        async def before_crash():
            return next((r for r in self.reports() if r['browser']['event'] == 'recording-progress'
                         and r['browser']['recording'] == interrupted['id'] and r['browser']['frames'] > 0), None)
        await self.wait(before_crash, 15)
        # Deliberately kill only this disposable fixture to prove no exit-time flush is needed.
        self.host.send_signal(signal.SIGKILL)
        await asyncio.to_thread(self.host.wait, 10)
        assert self.host.returncode == -signal.SIGKILL
        assert self.reports()[-1]['browser']['event'] == 'recording-progress'
        self.passed('Pre-crash breadcrumbs remain readable after abrupt isolated Host termination')
        subprocess.run(['/opt/homebrew/bin/tmux', '-S', self.socket, 'kill-server'], check=True)
        async def helpers_stopped():
            processes = await asyncio.to_thread(subprocess.check_output, ['ps', '-axo', 'comm='], text=True)
            return str(self.args.app) not in processes
        await self.wait(helpers_stopped, 15)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('app', type=Path)
    parser.add_argument('engine', type=Path)
    parser.add_argument('identity', type=Path)
    asyncio.run(RecordingDiagnostics(parser.parse_args()).run())
