#!/usr/bin/env python3
"""Background Agent input must preserve the user's workspace and native focus.

Both public engines run in a signed isolated app with private fixture owners,
tmux, profile and API socket. The native probe supplies an unrelated text editor.
"""
import argparse
import asyncio
import json
from pathlib import Path

from managed_engine import Managed


class BackgroundInput(Managed):
    mock_keychain = True

    async def validate(self, _):
        for run, tab in zip(self.runs, self.tabs):
            await self.request(run, "close", tab=tab)
        pids = [run["pid"] for run in self.runs]
        other = (await self.cli_action(1, "action", "open", "--url", self.url + "other"))["result"]["id"]
        await self.cli_action(1, "action", "wait", "--tab", other)
        await self.cli_action(1, "action", "show", "--tab", other)

        async def pages(index):
            return (await self.cli_action(index, "action", "tabs"))["result"]

        foreground = (1, other)

        async def foreground_visible():
            return next(page["presentation"]["visible"] for page in await pages(foreground[0])
                        if page["id"] == foreground[1])

        await self.wait(foreground_visible)
        contexts = [json.loads(p.read_text()) for p in (self.root / "agent-browser/runs").glob("*/context.json")]
        observer = next(c for c in contexts if c["pid"] == pids[1])
        focus = await self.request(observer, "probe.focus", tab=other, action="input")
        assert focus["inputFocused"], focus

        async def unchanged(label):
            state = await self.request(observer, "probe.focus", tab=other, action="status")
            assert state == focus, (label, focus, state)
            assert await foreground_visible(), label + ": changed the visible workspace"
            assert all(p["id"] == foreground[1] or not p["presentation"]["visible"] for p in await pages(0)), label
            self.passed(label + ": preserves workspace and native keyboard focus")

        target = (await self.cli_action(0, "action", "open", "--url", self.url + "background"))["result"]["id"]
        await self.cli_action(0, "action", "wait", "--tab", target)
        await unchanged("Agent creates a page")
        for engine in ("ctrlx", "vercel"):
            async def action(name, *args):
                result = await self.cli_action(0, "action", name, "--engine", engine, "--tab", target, *args)
                await unchanged(engine + " " + name)
                return result["result"]

            await action("read")
            if engine == "vercel":
                await action("snapshot")
            marker = "Background 中文 " + engine
            await action("fill", "--selector", "#message", "--text", marker)
            await action("click", "--selector", "#apply")
            await action("wait", "--selector", "#result", "--text", marker + "; trusted=true")
            await action("fill", "--selector", "#message", "--text", "ABC")
            await action("press", "--key", "ArrowLeft")
            await action("press", "--key", "Backspace")
            await action("type", "--selector", "#message", "--text", "中")
            value = await action("read", "--selector", "#message")
            assert value["controls"][0]["value"] == "A中C", value
            if engine == "ctrlx":
                await action("press", "--key", "Meta+A")
                await action("type", "--selector", "#message", "--text", "replaced")
                value = await action("read", "--selector", "#message")
                assert value["controls"][0]["value"] == "replaced", value
            await action("fill", "--selector", "#message", "--text", "")
            value = await action("read", "--selector", "#message")
            assert value["controls"][0]["value"] == "", value
            await action("screenshot", "--output", str(self.root / (engine + ".png")))
            assert (self.root / (engine + ".png")).read_bytes().startswith(b"\x89PNG")
            before = {page["id"] for page in await pages(0)}
            await action("click", "--selector", "#child")

            async def child_created():
                return next((p["id"] for p in await pages(0) if p["id"] not in before), None)

            child = await self.wait(child_created)
            await self.cli_action(0, "action", "wait", "--tab", child)
            await unchanged(engine + " popup")
            await self.cli_action(0, "action", "close", "--tab", child)
            await unchanged(engine + " closes background popup")
            await action("navigate", "--url", self.url + engine)
            await action("wait")
            reused = (await self.cli_action(0, "action", "open", "--url", self.url + engine))["result"]["id"]
            assert reused == target
            await unchanged(engine + " reuses the default page")

        sibling = (await self.cli_action(0, "action", "open", "--new", "--url", self.url + "sibling"))["result"]["id"]
        await self.cli_action(0, "action", "wait", "--tab", sibling)
        await unchanged("Agent creates an extra page")
        for displayed, label in ((sibling, "same-session sibling"), (target, "visible page beside another input")):
            await self.cli_action(0, "action", "show", "--tab", displayed)
            foreground = (0, displayed)
            await self.wait(foreground_visible)
            focus = await self.request(observer, "probe.focus", tab=other, action="input")
            assert focus["inputFocused"], focus
            for engine in ("ctrlx", "vercel"):
                await self.cli_action(0, "action", "fill", "--engine", engine, "--tab", target,
                                      "--selector", "#message", "--text", label + engine)
                await self.cli_action(0, "action", "click", "--engine", engine, "--tab", target,
                                      "--selector", "#apply")
                await self.cli_action(0, "action", "wait", "--tab", target,
                                      "--selector", "#result", "--text", label + engine + "; trusted=true")
                await unchanged(engine + " with " + label)

        await self.request(observer, "probe.focus", tab=other, action="stop")
        await self.cli_action(1, "action", "show", "--tab", other)
        foreground = (1, other)
        await self.wait(foreground_visible)
        await self.cli_action(0, "action", "show", "--tab", target)

        async def shown():
            return next(page["presentation"]["visible"] for page in await pages(0) if page["id"] == target)

        await self.wait(shown)
        assert not await foreground_visible()
        self.passed("Explicit show still selects the target workspace and page")


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=lambda p: Path(p).resolve())
    parser.add_argument("engine", type=lambda p: Path(p).resolve())
    parser.add_argument("identity", type=lambda p: Path(p).resolve())
    test = BackgroundInput(parser.parse_args())
    await test.run()
    assert test.host.returncode == 0, "Host did not quit normally"


if __name__ == "__main__":
    asyncio.run(main())
