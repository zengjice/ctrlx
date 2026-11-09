#!/usr/bin/env python3
"""Inline H.264/MP4 acceptance in the isolated signed CEF fixture.

Requires the existing acceptance app, native fixture identity, pinned engine and
ffmpeg with VideoToolbox, AAC and VP9 encoders. Uses generated media and a private
profile; never operates the installed App or personal browser pages.
"""
import argparse
import asyncio
import base64
import json
from pathlib import Path
import subprocess

from managed_engine import Managed


class MediaPlayback(Managed):
    mock_keychain = True

    def encode(self, name, audio=False, fragmented=False):
        path = self.root / name
        command = [str(self.args.ffmpeg), '-hide_banner', '-loglevel', 'error',
                   '-f', 'lavfi', '-i', 'testsrc2=size=160x96:rate=12']
        if audio:
            command += ['-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
                        '-c:a', 'aac', '-b:a', '24k']
        else:
            command += ['-an']
        command += ['-t', '1.5', '-b:v', '48k']
        if path.suffix == '.mp4':
            flags = '+frag_keyframe+empty_moov+default_base_moof' if fragmented else '+faststart'
            command += ['-c:v', 'h264_videotoolbox', '-profile:v', 'baseline', '-movflags', flags]
        else:
            command += ['-c:v', 'libvpx-vp9']
        subprocess.run(command + [str(path)], check=True, timeout=30)
        return base64.b64encode(path.read_bytes()).decode()

    async def evaluate(self, expression):
        reply = await self.request(self.runs[0], 'probe.cdp', tab=self.tabs[0],
                                   method='Runtime.evaluate', params={
                                       'expression': expression, 'awaitPromise': True,
                                       'returnByValue': True, 'userGesture': True})
        assert 'exceptionDetails' not in reply, reply
        return reply['result']['value']

    async def validate(self, _):
        report = {'browser': await self.request(self.runs[0], 'probe.cdp', tab=self.tabs[0],
                                                method='Browser.getVersion'), 'samples': {}}
        # VP9 is a positive control: autoplay, rendering or fixture failures must
        # not be mistaken for missing H.264 codecs.
        for name, mime, codecs, audio, mse in [
            ('vp9.webm', 'video/webm', 'vp9', False, False),
            ('h264.mp4', 'video/mp4', 'avc1.42E01E', False, False),
            ('h264-aac.mp4', 'video/mp4', 'avc1.42E01E, mp4a.40.2', True, False),
            ('h264-aac-fragmented.mp4', 'video/mp4', 'avc1.42E01E, mp4a.40.2', True, True),
        ]:
            data = await asyncio.to_thread(self.encode, name, audio, mse)
            content_type = f'{mime}; codecs="{codecs}"'
            expression = """(async () => {
                const video = document.createElement('video');
                video.muted = true; video.playsInline = true; video.controls = true;
                document.body.replaceChildren(video);
                const type = CONTENT_TYPE;
                const data = MEDIA_DATA;
                let objectURL;
                const capability = {canPlayType: video.canPlayType(type),
                    mediaSource: MediaSource.isTypeSupported(type)};
                const outcome = await new Promise(resolve => {
                    let interval;
                    let finished = false;
                    const finish = error => {
                        if (finished) return;
                        finished = true;
                        clearInterval(interval); clearTimeout(timeout);
                        resolve({error, mediaError: video.error?.code ?? null,
                            currentTime: video.currentTime, width: video.videoWidth,
                            height: video.videoHeight,
                            frames: video.getVideoPlaybackQuality().totalVideoFrames});
                    };
                    const timeout = setTimeout(() => finish('Playback timed out'), 4000);
                    video.onerror = () => finish(video.error.message);
                    interval = setInterval(() => {
                        if (video.currentTime > 0.1 && video.getVideoPlaybackQuality().totalVideoFrames >= 2)
                            finish(null);
                    }, 50);
                    if (USE_MSE) {
                        const stream = new MediaSource();
                        objectURL = URL.createObjectURL(stream);
                        stream.addEventListener('sourceopen', () => {
                            try {
                                const buffer = stream.addSourceBuffer(type);
                                buffer.addEventListener('error', () => finish('SourceBuffer error'));
                                buffer.addEventListener('updateend', () => stream.endOfStream(), {once: true});
                                buffer.appendBuffer(Uint8Array.from(atob(data), c => c.charCodeAt(0)));
                            } catch (error) { finish(error.message); }
                        }, {once: true});
                        video.src = objectURL;
                    } else {
                        video.src = 'data:' + MIME_TYPE + ';base64,' + data;
                    }
                    video.play().catch(error => finish(error.message));
                });
                video.pause(); video.removeAttribute('src'); video.load();
                if (objectURL) URL.revokeObjectURL(objectURL);
                return {...capability, ...outcome};
            })()""".replace('CONTENT_TYPE', json.dumps(content_type)).replace(
                'MEDIA_DATA', json.dumps(data)).replace('MIME_TYPE', json.dumps(mime)).replace(
                'USE_MSE', json.dumps(mse))
            report['samples'][name] = await self.evaluate(expression)
        (self.root / 'media-playback.json').write_text(json.dumps(report, indent=2))
        print(json.dumps(report, indent=2), flush=True)
        for name, value in report['samples'].items():
            assert value['canPlayType'] and value['mediaSource'], (name, value)
            assert value['error'] is None and value['mediaError'] is None, (name, value)
            assert value['width'] == 160 and value['height'] == 96 and value['frames'] >= 2, (name, value)
            self.passed(f'{name}: inline playback advances and decodes video frames')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=lambda value: Path(value).resolve())
    parser.add_argument('engine', type=lambda value: Path(value).resolve())
    parser.add_argument('identity', type=lambda value: Path(value).resolve())
    parser.add_argument('--ffmpeg', type=Path, default=Path('/opt/homebrew/bin/ffmpeg'))
    asyncio.run(MediaPlayback(parser.parse_args()).run())
