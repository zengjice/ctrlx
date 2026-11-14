#!/usr/bin/env python3
"""Native Browser + Simulator conversation-ownership acceptance in a private Host.

Extends resource_resume.py with a single private Simulator device. Uses the
codex-named native fixture, not real Codex or any user's running Agent/device.
Arguments: isolated signed app, bundled engine, engine_identity.cc built as codex.
"""
import argparse
import asyncio
import json
from pathlib import Path
import shlex
import uuid

from resource_resume import ResourceResume


class ResourceIdentity(ResourceResume):
    async def ios(self, number, *words, ok=True):
        output = self.root / str(uuid.uuid4())
        argv = [self.cli, 'ios', *words, '--socket', self.api]
        command = shlex.join(argv) + f' > {output}.out 2> {output}.err; echo $? > {output}.exit'
        session = ('upstream-alpha', 'upstream-beta')[number]
        pane = (await self.control('list-panes', '--window', session + ':1'))['panes'][0]['id']
        await self.control('send', command, '--pane', pane, '--enter')

        async def done():
            path = Path(str(output) + '.exit')
            return path.read_text().strip() if path.exists() else None

        code = int(await self.wait(done, 260))
        error = Path(str(output) + '.err').read_text()
        assert (code == 0) == ok, (words, error)
        return json.loads(Path(str(output) + '.out').read_text()) if ok else error

    async def validate(self, port):
        # Both engines finish and close their pages before booting a device.
        await super().validate(port)
        conversation = str(uuid.uuid4())
        await self.restart(0, conversation)
        await self.ios(0, 'identity')
        assert (await self.ios(0, 'devices'))['devices'] == []
        inventory = await self.ios(0, 'inventory')
        (self.root / 'simulator-inventory.json').write_text(json.dumps(inventory, indent=2))
        device = await self.ios(0, 'open')
        (self.root / 'simulator-open.json').write_text(json.dumps(device, indent=2))
        device_id = device['device']
        await self.ios(0, 'status', '--device', device_id)
        self.passed('native Simulator opens under the fixture conversation')

        await self.restart(0, conversation)
        devices = (await self.ios(0, 'devices'))['devices']
        assert [item['device'] for item in devices] == [device_id], devices
        await self.ios(0, 'status', '--device', device_id)
        self.passed('same conversation in a new process retains the same Simulator device')

        await self.restart(1, conversation)
        assert (await self.ios(1, 'devices'))['devices'] == []
        await self.ios(1, 'status', '--device', device_id, ok=False)
        await self.restart(0, str(uuid.uuid4()))
        assert (await self.ios(0, 'devices'))['devices'] == []
        await self.ios(0, 'status', '--device', device_id, ok=False)
        self.passed('another pane and a new conversation cannot inherit Simulator access')

        await self.restart(0, conversation)
        assert [item['device'] for item in (await self.ios(0, 'devices'))['devices']] == [device_id]
        await self.ios(0, 'close', '--device', device_id)
        assert (await self.ios(0, 'devices'))['devices'] == []
        self.passed('original conversation resumes ownership and closes its private device')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('app', 'engine', 'identity'):
        parser.add_argument(name, type=lambda value: Path(value).resolve())
    asyncio.run(ResourceIdentity(parser.parse_args()).run())
