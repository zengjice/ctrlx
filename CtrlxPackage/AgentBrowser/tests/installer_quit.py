#!/usr/bin/env python3
"""Expired installer Quit and fresh Quit in the isolated signed CEF app."""
import argparse
import asyncio
from pathlib import Path
import subprocess
import time
from managed_engine import Managed


class InstallerQuit(Managed):
    mock_keychain = True

    async def quit(self, deadline):
        script = (f'with timeout of 45 seconds\n'
                  f'    tell application "{self.args.app}" to «event aevtquit» '
                  f'given «class cxdl»:"{deadline}"\nend timeout')
        caller = await asyncio.create_subprocess_exec(
            '/usr/bin/osascript', '-e', script,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        stdout, stderr = await asyncio.wait_for(caller.communicate(), 50)
        return caller.returncode, stderr.decode()

    async def validate(self, _):
        try:
            code, error = await self.quit(1)
            assert code != 0 and '-128' in error, (code, error)
            assert self.host.poll() is None, 'Expired request terminated the Host'
            await self.control('list-sessions')
            self.passed('expired installer Quit is rejected without disconnecting the Host')
            code, error = await self.quit(int(time.time()) + 10)
            assert code == 0, error
            assert await asyncio.to_thread(self.host.wait, 20) == 0
            self.passed('a subsequent fresh Quit completes native cleanup and exits normally')
        finally:
            # The shared harness only stops tmux when it also needs to quit its
            # App. This test deliberately exits the App itself.
            subprocess.run(['/opt/homebrew/bin/tmux', '-S', self.socket, 'kill-server'], capture_output=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('app', 'engine', 'identity'):
        parser.add_argument(name, type=lambda value: Path(value).resolve())
    asyncio.run(InstallerQuit(parser.parse_args()).run())
