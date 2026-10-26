#!/usr/bin/env python3
"""Page audio capture and live output routing in the isolated signed CEF app."""
import argparse
import array
import asyncio
import base64
import json
import math
from pathlib import Path
import uuid
from managed_engine import Managed
from integration import call


class Audio(Managed):
    mock_keychain = True

    async def validate(self, _):
        run = self.runs[0]
        tab, other = self.tabs
        lease = str(uuid.uuid4())

        async def audio(action='status', target=tab, **values):
            owner = self.runs[0 if target == tab else 1]
            return await self.request(owner, 'probe.audio', tab=target, action=action, **values)

        await self.request(run, 'probe.cdp', tab=tab, method='Runtime.evaluate', params={
            'expression': """(async()=>{window.audioFixture=new AudioContext({sampleRate:48000});
              window.tone=audioFixture.createOscillator();tone.frequency.value=440;
              const gain=audioFixture.createGain();gain.gain.value=0.02;
              tone.connect(gain).connect(audioFixture.destination);tone.start();
              await audioFixture.resume();return audioFixture.state})()""",
            'awaitPromise': True, 'returnByValue': True, 'userGesture': True})

        async def local_playing():
            value = await audio()
            assert not value['error'], value
            return value if value['captured'] > 4096 and value['local'] > 4096 else None

        before = await self.wait(local_playing)
        self.passed('page audio reaches Host output before Viewer takeover')
        assert (await self.request(run, 'probe.remote-control', tab=tab, lease=lease))['accepted']
        assert (await audio('route', lease=lease, enabled=True))['accepted']
        await asyncio.sleep(.12)
        samples = array.array('f', base64.b64decode((await audio('read', lease=lease))['pcm']))
        assert len(samples) >= 2048 and all(math.isfinite(value) for value in samples)
        assert sum(value * value for value in samples) / len(samples) > .00001
        self.passed('a page already playing can be captured midstream without reload or restarting media')
        remote = await audio()
        await asyncio.sleep(.1)
        stable = await audio()
        assert stable['remote'] and stable['local'] == remote['local'], (remote, stable)
        assert stable['buffered'] <= 8192
        self.passed('remote output suppresses the Host sink and slow reads remain bounded')

        wrong = await audio('route', lease=str(uuid.uuid4()), enabled=True)
        assert not wrong['accepted']
        assert not (await audio(target=other))['remote']
        self.passed('audio routing checks the native page control token and preserves sibling pages')

        assert (await audio('route', lease=lease, enabled=False))['accepted']
        await asyncio.sleep(.1)
        assert not base64.b64decode((await audio('read', lease=lease))['pcm'])
        muted = await audio()
        assert muted['remote'] and not muted['enabled'] and muted['local'] == stable['local']
        self.passed('Viewer mute discards audio without sending it back to the Host')

        assert (await audio('release'))['accepted']
        async def restored():
            value = await audio()
            return value if not value['remote'] and value['local'] > muted['local'] + 4096 else None
        await self.wait(restored)
        self.passed('release restores Host playback while the same oscillator keeps playing')
        assert not (await audio('route', lease=lease, enabled=True))['accepted']

        # Reacquire during the same playing source; no new audible-state event.
        lease = str(uuid.uuid4())
        assert (await self.request(run, 'probe.remote-control', tab=tab, lease=lease))['accepted']
        assert (await audio('route', lease=lease, enabled=True))['accepted']
        await asyncio.sleep(.1)
        assert base64.b64decode((await audio('read', lease=lease))['pcm'])
        await audio('release')
        self.passed('repeated takeover works and retired control tokens cannot redirect sound')
        await self.request(run, 'close', tab=tab)
        await asyncio.sleep(.3)
        assert self.host.poll() is None
        self.passed('closing a page while its audio is playing safely retires the capture and local sink')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=lambda value: Path(value).resolve())
    parser.add_argument('engine', type=lambda value: Path(value).resolve())
    parser.add_argument('identity', type=lambda value: Path(value).resolve())
    asyncio.run(Audio(parser.parse_args()).run())
