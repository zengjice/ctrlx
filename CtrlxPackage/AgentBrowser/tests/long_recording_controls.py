#!/usr/bin/env python3
"""Targeted Viewer-control/focus/legacy regression; isolated probe build only."""
import argparse
import asyncio
import json
from pathlib import Path
import shlex
import uuid

from long_recording import LongRecording


class RecordingControls(LongRecording):
    async def validate(self, _):
        run, tab = self.runs[0], self.tabs[0]
        observer, other = self.runs[1], self.tabs[1]
        output = self.root / 'viewer.mp4'
        await self.request(run, 'probe.cdp', tab=tab, method='Runtime.evaluate', params={
            'expression': "document.body.innerHTML='<button id=target style=\"position:fixed;left:20px;top:20px;width:120px;height:60px\">Press</button>';document.querySelector('#target').onclick=e=>document.body.dataset.clicked=e.isTrusted;true",
            'returnByValue': True})
        await self.request(observer, 'show', tab=other)
        focus = await self.request(observer, 'probe.focus', tab=other, action='input')
        view = await self.request(run, 'probe.remote-view', tab=tab, action='start')
        started = await self.request(run, 'record-start', tab=tab, seconds=10, output=str(output))
        await asyncio.sleep(1)
        lease = str(uuid.uuid4())
        assert (await self.request(run, 'probe.remote-control', tab=tab, lease=lease))['accepted']
        shot = await self.request(run, 'probe.remote', tab=tab, request={'action': 'frame'})
        for event, buttons in [('mousePressed', 1), ('mouseReleased', 0)]:
            await self.request(run, 'probe.remote', tab=tab, request={
                'action': 'mouse', 'lease': lease, 'generation': shot['generation'], 'type': event,
                'button': 'left', 'buttons': buttons, 'clickCount': 1,
                'x': 60, 'y': 45})
        # The recording owner can stop/query even while a Viewer has input control.
        stopped = await self.request(run, 'record-stop', tab=tab, recording=started['id'])
        assert stopped['state'] in ('stopping', 'completed')
        async def done():
            state = await self.request(run, 'record-status', tab=tab, recording=started['id'])
            assert state['state'] != 'failed', state
            return state if state['state'] == 'completed' else None
        await self.wait(done)
        await self.request(run, 'probe.remote-control', tab=tab)
        clicked = await self.request(run, 'probe.cdp', tab=tab, method='Runtime.evaluate', params={
            'expression': 'document.body.dataset.clicked', 'returnByValue': True})
        assert clicked['result']['value'] == 'true', clicked
        after = await self.request(observer, 'probe.focus', tab=other, action='status')
        assert (focus['keyWindow'], focus['firstResponder']) == (after['keyWindow'], after['firstResponder']), (focus, after)
        after_view = await self.request(run, 'probe.remote-view', tab=tab, action='stop')
        assert after_view['sizeChanges'] == 0 and after_view['width'] == view['width'], after_view
        await self.request(observer, 'probe.focus', tab=other, action='stop')
        self.inspect_video(output, .5, 8)
        self.passed('Viewer takes control and clicks during capture; owner can stop; no focus or live-viewport changes')

        # A queued wait owns the ordinary CLI lock; status/stop must still work.
        self.tab = (await self.cli_action(0, 'action', 'open', '--url', self.url + 'wait'))['result']['id']
        await self.start('during-wait.mp4')
        prefix = ['/usr/bin/env', 'CTRLX_SOCKET=' + self.api,
                  'CTRLX_BROWSER_TEST_STATE_ROOT=' + str(self.root), self.cli, 'browser']
        def invocation(name, *args):
            return shlex.join(prefix + list(args)) + ' > ' + shlex.quote(str(self.root / (name + '.json')))
        script = self.root / 'concurrent-recording.sh'
        script.write_text('set -e\n' + invocation('wait', 'command', '--tab', self.tab, '--', 'wait', '12000') +
                          ' &\npage_job=$!\nsleep 0.5\n' +
                          invocation('status', 'record-status', '--tab', self.tab) + '\n' +
                          invocation('stop', 'record-stop', '--tab', self.tab) + '\n' +
                          'kill -0 "$page_job"\n' +
                          'touch ' + shlex.quote(str(self.root / 'concurrent-passed')) + '\nwait "$page_job"\n')
        pane = (await self.control('list-panes', '--window', 'upstream-alpha:1'))['panes'][0]['id']
        await self.control('send', shlex.join(['/bin/sh', str(script)]), '--pane', pane, '--enter')
        async def concurrent_done():
            return (self.root / 'concurrent-passed').exists()
        await self.wait(concurrent_done, 20)
        state = json.loads((self.root / 'status.json').read_text())['result']
        assert state['state'] == 'recording', state
        await self.finished()
        self.passed('record-status and record-stop bypass a concurrent long page-operation lock')

        result = await self.cli_action(0, 'record', '--tab', self.tab, '--seconds', '1',
                                      '--format', 'mp4', '--output', str(self.root / 'legacy.mp4'))
        assert result['result']['bytes'] > 0
        self.inspect_video(self.root / 'legacy.mp4', .5, 8, maximum_dimension=None)
        self.passed('legacy short MP4 recording remains usable after background recording')
        await self.start('host-exit.mp4')
        await asyncio.sleep(1)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('engine', type=Path)
    parser.add_argument('identity', type=Path)
    asyncio.run(RecordingControls(parser.parse_args()).run())
