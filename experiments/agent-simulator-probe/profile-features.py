#!/usr/bin/env python3
"""Verify balanced service configuration and actual UIKit/WebKit paste effects."""
import argparse
import json
from pathlib import Path
import socket
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", type=Path, required=True)
    parser.add_argument("--control", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error("Output must be a new path")
    host = json.loads(args.host.read_text())
    root = Path(host["root"]) / "state/agent-simulator/devices"
    bundle = "com.jicezeng.ctrlx.simulator-fixture"

    def event(value):
        with args.output.open("a") as file:
            file.write(json.dumps({"at": time.time(), **value}, ensure_ascii=False) + "\n")

    def request(words):
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(260)
            client.connect(str(args.control))
            client.sendall(json.dumps({"arguments": words}).encode() + b"\n")
            with client.makefile("rb") as stream:
                result = json.loads(stream.readline(10 * 1024 * 1024))
        event({"kind": "command", "arguments": words, **result})
        assert result["code"] == 0, result
        return json.loads(result["stdout"])

    assert not request(["devices"])["devices"]
    for requires, expected_disabled in [(None, 23), ("widgets,siri,maps,weather,news,game-center", 0)]:
        words = ["open", "--profile", "balanced", "--runtime", "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
                 "--device-type", "com.apple.CoreSimulator.SimDeviceType.iPhone-16"]
        if requires:
            words += ["--requires", requires]
        opened = request(words)
        device, udid = opened["device"], opened["udid"]

        def call(words):
            return request(words + ["--device", device])

        try:
            slim = subprocess.check_output([str(Path(host["app"]) / "Contents/Helpers/simslim"),
                "status", udid, "--set", str(root), "--json"], text=True)
            configuration = json.loads(slim)
            assert configuration["managedDisabled"] == expected_disabled, configuration
            event({"kind": "configuration", "requires": requires, "actual": configuration})
            call(["install", "--app", str(args.fixture.resolve())])
            call(["launch", "--bundle", bundle])
            call(["wait", "--identifier", "fixture.plain", "--timeout-ms", "60000"])
            data = subprocess.check_output(["xcrun", "simctl", "--set", str(root),
                "get_app_container", udid, bundle, "data"], text=True).strip()
            state_file = Path(data) / "Documents/state.json"
            time.sleep(20)
            ready_by = time.monotonic() + 60
            while True:
                warm = call(["snapshot", "--limit", "1000"])
                if not warm["partial"] and any(node.get("identifier") == "fixture.plain" for node in warm["nodes"]):
                    break
                assert time.monotonic() < ready_by, warm
                time.sleep(.5)

            def pasted(key, value):
                call(["paste", "--text", value])
                deadline = time.monotonic() + 15
                approved = False
                while True:
                    state = json.loads(state_file.read_text())
                    if state[key] == value:
                        event({"kind": "effect", "requires": requires, "key": key, "state": state})
                        return
                    assert time.monotonic() < deadline, (key, value, state)
                    tree = call(["snapshot", "--limit", "1000"])
                    permissions = [node for node in tree["nodes"] if node.get("role") == "AXButton"
                        and node.get("label") in ("允许粘贴", "Allow Paste")]
                    if permissions and not approved:
                        assert len(permissions) == 1, permissions
                        # AX exposes the button before the modal's opening
                        # animation accepts touches. Submit one approval only.
                        time.sleep(.5)
                        call(["tap", "--label", permissions[0]["label"], "--role", "AXButton"])
                        approved = True
                    time.sleep(.1)

            for identifier, key, value in [
                ("fixture.plain", "plain", "模拟器测试 🙂"),
                ("fixture.secure", "secure", "fixture-secret-123"),
                ("fixture.multiline", "multiline", "第一行\nsecond line 🙂"),
            ]:
                # The fixture can save its paste effect while UIKit is still
                # dismissing the permission sheet; observe the next field first.
                call(["wait", "--identifier", identifier, "--timeout-ms", "5000"])
                call(["tap", "--identifier", identifier])
                pasted(key, value)
            call(["wait", "--identifier", "fixture.multiline", "--timeout-ms", "5000"])
            tree = call(["snapshot", "--limit", "1000"])
            secure = [node for node in tree["nodes"] if node.get("identifier") == "fixture.secure"]
            assert len(secure) == 1 and "value" not in secure[0], secure
            # This deterministic fixture's WebKit input is not exposed by its AX tree.
            picture = args.output.with_name(args.output.stem + f"-{expected_disabled}-web.png").resolve()
            call(["screenshot", "--output", str(picture)])
            assert tree["geometry"]["orientation"] == 1, tree["geometry"]
            call(["tap", "--x", "196", "--y", "414"])
            pasted("web", "WebKit 测试 🙂")
            event({"kind": "profile-passed", "requires": requires, "managedDisabled": expected_disabled})
            print("balanced", expected_disabled, "disabled services: actual text/WebKit effects passed", flush=True)
        finally:
            call(["close"])


if __name__ == "__main__":
    main()
