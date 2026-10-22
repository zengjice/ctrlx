#!/usr/bin/env python3
"""Public recording CLI acceptance in an isolated signed Host; default full 600 s run.

Uses the existing native fixture owners, private profile/tmux socket and mock
Keychain. No personal pages, accounts or installed application are changed.
"""
import argparse
import asyncio
import json
import os
from pathlib import Path
import signal
import shlex
import subprocess
import time
import uuid

from page_capabilities import PageCapabilities


class LongRecording(PageCapabilities):
    mock_keychain = True

    async def cli_action(self, number, *args, ok=True, failure_json=False):
        # The fixture's canonical tty line is small. Execute a private script
        # under the same native owner instead of truncating long command lines.
        prefix = self.root / str(uuid.uuid4())
        words = ['/usr/bin/env', 'CTRLX_SOCKET=' + self.api,
                 'CTRLX_BROWSER_TEST_STATE_ROOT=' + str(self.root), self.cli, 'browser', *args]
        script = prefix.with_suffix('.sh')
        script.write_text(shlex.join(words) + ' > ' + shlex.quote(str(prefix) + '.out') +
                          ' 2> ' + shlex.quote(str(prefix) + '.err') +
                          '\necho $? > ' + shlex.quote(str(prefix) + '.exit') + '\n')
        pane = (await self.control('list-panes', '--window', ('upstream-alpha', 'upstream-beta')[number] + ':1'))['panes'][0]['id']
        await self.control('send', shlex.join(['/bin/sh', str(script)]), '--pane', pane, '--enter')
        async def done():
            path = Path(str(prefix) + '.exit')
            return path.read_text().strip() if path.exists() else None
        code = int(await self.wait(done, 60))
        error = Path(str(prefix) + '.err').read_text()
        assert (code == 0) == ok, (args, error)
        if not ok and not failure_json:
            return error
        return json.loads(Path(str(prefix) + '.out').read_text())

    async def status(self, tab=None, recording=None):
        args = ['record-status', '--tab', tab or self.tab]
        if recording:
            args += ['--recording', recording]
        return (await self.cli_action(0, *args))['result']

    async def start(self, name, seconds=600, tab=None, owner=0):
        output = self.root / name
        value = (await self.cli_action(owner, 'record-start', '--tab', tab or self.tab,
                                      '--seconds', str(seconds), '--output', str(output)))['result']
        assert value['state'] == 'starting' and value['path'] == str(output)
        assert value['maximumSeconds'] == seconds and value['fps'] == 10
        assert 'data' not in value
        return value

    async def finished(self, tab=None, timeout=20):
        async def done():
            value = await self.status(tab)
            if value['state'] in ('completed', 'failed'):
                assert value['state'] == 'completed' and 'error' not in value, value
                return value
        return await self.wait(done, timeout)

    def inspect_video(self, path, minimum, maximum, maximum_dimension=1920):
        value = json.loads(subprocess.check_output([
            '/opt/homebrew/bin/ffprobe', '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(path)]))
        duration = float(value['format']['duration'])
        assert minimum <= duration <= maximum, (duration, minimum, maximum)
        video = next(s for s in value['streams'] if s['codec_type'] == 'video')
        assert video['codec_name'] == 'h264', video
        if maximum_dimension is not None:
            assert max(video['width'], video['height']) <= maximum_dimension, video
        assert path.stat().st_mode & 0o777 == 0o600
        subprocess.run(['/opt/homebrew/bin/ffmpeg', '-v', 'error', '-i', str(path),
                        '-frames:v', '2', '-f', 'null', '-'], check=True, timeout=20)
        return value

    async def animate(self):
        script = self.root / 'recording-animation.js'
        script.write_text("""clearInterval(window.recordingTimer);document.body.innerHTML=`<input id="text"><button id="apply" onclick="this.textContent='clicked'">Apply</button><canvas id="video" width="640" height="360"></canvas>`;
          document.querySelector('canvas').style.cssText='display:block;width:95vw;height:75vh';
          window.recordingFrames=0;window.recordingTimer=setInterval(()=>{const c=document.querySelector('canvas');if(!c)return;
            const x=c.getContext('2d'),n=window.recordingFrames;for(let i=0;i<400;i++){x.fillStyle=`hsl(${(i*17+n*23)%360} 80% 50%)`;
              x.fillRect((i*53+n*7)%640,(i*31+n*11)%360,40,40)}window.recordingFrames++},100);true""")
        await self.cli_action(0, 'command', '--tab', self.tab, '--input-file', str(script), '--', 'eval')

    async def validate(self, _):
        self.tab = (await self.cli_action(0, 'action', 'open', '--url', self.url + 'recording'))['result']['id']
        await self.cli_action(0, 'action', 'wait', '--tab', self.tab)
        await self.animate()
        for seconds in ('0', '601'):
            await self.cli_action(0, 'record-start', '--tab', self.tab, '--seconds', seconds,
                                  '--output', str(self.root / 'invalid.mp4'), ok=False)
        # The native boundary must validate independently of the Swift CLI.
        for seconds in (0, 601, True, 2.5):
            try:
                await self.request(self.runs[0], 'record-start', tab=self.tabs[0], seconds=seconds,
                                   output=str(self.root / 'native-invalid.mp4'))
                raise AssertionError('Invalid native duration accepted')
            except AssertionError as error:
                assert '1...600' in str(error), error
        self.passed('CLI and native limits reject invalid durations before capture')

        start = await self.start('manual.mp4')
        await self.cli_action(1, 'record-status', '--tab', self.tab, ok=False)
        await self.cli_action(1, 'record-stop', '--tab', self.tab, ok=False)
        await self.cli_action(1, 'record-start', '--tab', self.tab, '--output', str(self.root / 'other.mp4'), ok=False)
        await self.cli_action(0, 'record-start', '--tab', self.tab, '--output', str(self.root / 'duplicate.mp4'), ok=False)
        await self.cli_action(0, 'record-stop', '--tab', self.tab, '--recording', str(uuid.uuid4()), ok=False)
        await self.command('fill', '#text', 'recording input')
        await self.command('click', '#apply')
        await self.verify("document.querySelector('#text').value==='recording input' && document.querySelector('#apply').textContent==='clicked'")
        await self.cli_action(0, 'record', '--tab', self.tab, '--seconds', '1',
                              '--output', str(self.root / 'overlap.webm'), ok=False)
        await self.cli_action(0, 'record-stop', '--tab', self.tab, '--recording', start['id'])
        done = await self.finished()
        assert done['reason'] == 'stopped' and done['frames'] > 1
        self.inspect_video(self.root / 'manual.mp4', .1, 30)
        await self.cli_action(0, 'record-start', '--tab', self.tab, '--output', str(self.root / 'manual.mp4'), ok=False)
        again = (await self.cli_action(0, 'record-stop', '--tab', self.tab))['result']
        assert again['state'] == 'completed' and again['id'] == start['id']
        self.passed('manual stop, usable MP4, input while recording, exclusive recording and owner/stale-ID isolation')

        await self.start('navigation.mp4', seconds=8)
        await asyncio.sleep(1)
        await self.cli_action(0, 'action', 'navigate', '--tab', self.tab, '--url', self.url + 'next')
        await self.command('wait', '--load', 'load')
        await self.animate()
        await self.command('set', 'viewport', '640', '500')
        done = await self.finished(timeout=15)
        assert done['reason'] == 'duration-limit'
        self.inspect_video(self.root / 'navigation.mp4', 7.8, 9)
        self.passed('navigation and viewport changes continue within one fixed-size recording; duration auto-finalizes')

        closing = (await self.cli_action(0, 'action', 'open', '--new', '--url', self.url + 'closing'))['result']['id']
        await self.start('closed-tab.mp4', tab=closing)
        await asyncio.sleep(1)
        await self.cli_action(0, 'action', 'close', '--tab', closing)
        assert (await self.finished(closing))['reason'] == 'tab-closed'
        self.inspect_video(self.root / 'closed-tab.mp4', .1, 10)
        self.passed('closing a tab finalizes its video and retains owner-scoped completion status')

        await self.command('set', 'viewport', '1280', '800')
        await self.animate()
        # Keep another session selected: capture must not reveal or focus its source.
        await self.control('select-session', 'upstream-beta')
        await self.start('duration.mp4', seconds=self.args.duration)
        samples = []
        deadline = time.monotonic() + self.args.duration + 25
        last_log = 0
        while time.monotonic() < deadline:
            status = await self.status()
            assert status['state'] != 'failed', status
            if status['state'] == 'completed':
                assert status['reason'] == 'duration-limit' and 'error' not in status, status
                break
            now = time.monotonic()
            if now - last_log >= 30:
                sample = {'elapsed': status['elapsedSeconds'], 'bytes': status['bytes'], 'frames': status['frames'],
                          'host': subprocess.check_output(['ps', '-p', str(self.host.pid), '-o', 'rss=,%cpu='], text=True).strip()}
                samples.append(sample)
                (self.root / 'recording-resources.json').write_text(json.dumps(samples, indent=2))
                print('Recording:', sample, flush=True)
                await self.verify('recordingFrames > 0')
                last_log = now
            await asyncio.sleep(1)
        else:
            raise AssertionError('Recording did not stop at its duration limit')
        info = self.inspect_video(self.root / 'duration.mp4', self.args.duration - .3, self.args.duration + 1)
        (self.root / 'duration-ffprobe.json').write_text(json.dumps(info, indent=2))
        if self.args.duration == 600:
            assert (self.root / 'duration.mp4').stat().st_size > 6 * 1024 * 1024
        self.passed(f'{self.args.duration}-second recording finalizes playable H.264 directly to Host file; page commands remain available')

        other = (await self.cli_action(1, 'action', 'open', '--url', self.url + 'owner-exit'))['result']['id']
        await self.start('owner-exit.mp4', tab=other, owner=1)
        await asyncio.sleep(1)
        os.kill(self.runs[1]['pid'], signal.SIGTERM)
        async def owner_finished():
            return (self.root / 'owner-exit.mp4').exists()
        await self.wait(owner_finished, 15)
        self.inspect_video(self.root / 'owner-exit.mp4', .1, 10)
        self.passed('native Agent exit stops and saves its recording')
        await self.start('host-exit.mp4')
        await asyncio.sleep(1)
        self.passed('Host shutdown test armed with an active recording')

    async def run(self):
        await super().run()
        self.inspect_video(self.root / 'host-exit.mp4', .1, 10)
        assert not list(self.root.glob('.ctrlx-browser-recording-*'))
        self.passed('Host shutdown finalizes active video and removes all recording staging directories')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('engine', type=Path)
    parser.add_argument('identity', type=Path)
    parser.add_argument('--duration', type=int, default=600, choices=range(1, 601))
    asyncio.run(LongRecording(parser.parse_args()).run())
