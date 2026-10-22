#!/usr/bin/env python3
"""Characterize the pinned CEF APIs. A completed probe is not a compatibility pass."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import threading
from extension_cors import CORSFixture


def run(app: Path, dynamic_install: bool = False, native_drag: bool = False, production_admin: bool = False,
        env_extension: Path = None, env_scenario: Path = None, env_restart_scenario: Path = None,
        fixture_packages: Path = None, native_window_capture: bool = False, native_window_input: bool = False,
        native_manager_input: bool = False, env_debugger: bool = False, cors: bool = False, options_mode: str = None) -> Path:
    executable = app / "Contents/MacOS/CtrlX Browser Probe"
    if not executable.is_file():
        raise ValueError("Expected the isolated extension probe app")
    if env_restart_scenario and not (env_extension and env_scenario):
        raise ValueError("Restart acceptance requires ENV installation and an initial scenario")
    if fixture_packages and env_extension:
        raise ValueError("Fixture updates and ENV acceptance use separate private profiles")
    native_window_capture = native_window_capture or native_window_input
    if native_window_capture and not env_extension:
        raise ValueError("Native window characterization currently requires the ENV popup scenario")
    if native_window_input and (not env_scenario or env_restart_scenario):
        raise ValueError("Native popup input requires the ENV header scenario and is separate from restart acceptance")
    if native_manager_input and env_extension:
        raise ValueError("Native manager input uses the disposable fixture, not ENV")
    if env_debugger and (not env_extension or env_restart_scenario or native_window_input):
        raise ValueError("Debugger characterization needs ENV and runs separately from restart/native input")
    if cors and env_extension and (not env_scenario or env_restart_scenario or native_window_input or env_debugger):
        raise ValueError("ENV CORS acceptance requires only the header popup scenario")
    root = Path(__file__).resolve().parents[2]
    evidence = root / ".build-local/diagnostics"
    evidence.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix="browser-extensions-", dir=evidence))
    production_admin = production_admin or env_extension is not None or fixture_packages is not None or native_manager_input or options_mode is not None
    packages = json.loads(fixture_packages.read_text()) if fixture_packages else None
    extension = output / ("profile/CtrlXExtensions/packages/fixture" if production_admin else "extension")
    shutil.copytree(env_extension or (Path(packages["first"]) if packages else Path(__file__).with_name("extension-fixture")), extension)
    popup_reports = []
    options_reports = []
    cors_fixture = CORSFixture()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_GET(self):
            if cors and cors_fixture.handle(self):
                return
            if self.path == "/echo":
                header = "x-maas-env" if cors and env_extension else "x-ctrlx-extension"
                body = json.dumps({"extensionHeader": self.headers.get(header),
                                   "boe": self.headers.get("x-use-boe"), "ppe": self.headers.get("x-use-ppe"),
                                   "environment": self.headers.get("x-tt-env")}).encode()
                content_type = "application/json"
            else:
                body = ("<!doctype html><meta charset='utf-8'><title>CtrlX extension fixture</title>"
                        "<h1>Isolated CtrlX extension test</h1><p>" + self.path + "</p>" +
                        ('<script src="/cors/probe.js"></script>' if cors else '')).encode()
                content_type = "text/html; charset=utf-8"
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            if cors and cors_fixture.handle(self):
                return
            size = int(self.headers.get("Content-Length", "0"))
            if self.path not in ("/popup-report", "/options-report") or not 0 < size <= 65536:
                self.send_error(400)
                return
            (options_reports if self.path == "/options-report" else popup_reports).append(json.loads(self.rfile.read(size)))
            if self.path == "/options-report":
                (output / "options-ready.json").write_text(json.dumps(options_reports[-1]))
            self.send_response(204)
            self.end_headers()

        def do_OPTIONS(self):
            if not cors or not cors_fixture.handle(self):
                self.send_error(404)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()
    configuration = {"extension": str(extension), "fixture": f"http://127.0.0.1:{server.server_port}",
                     "output": str(output), "dynamicInstall": dynamic_install or native_drag, "nativeDrag": native_drag,
                     "productionAdmin": production_admin, "envPlugin": env_extension is not None,
                     "nativeWindowCapture": native_window_capture, "nativeWindowInput": native_window_input,
                     "nativeManagerInput": native_manager_input, "envDebugger": env_debugger, "cors": cors}
    if packages:
        updated = extension.with_name("fixture-updated")
        shutil.copytree(packages["second"], updated)
        configuration["fixtureUpdate"] = str(updated)
        configuration["fixtureExpectedID"] = packages["id"]
    if env_scenario:
        if not env_extension:
            raise ValueError("ENV scenarios require a verified ENV extension directory")
        configuration["envScenario"] = env_scenario.read_text()
        if cors:
            configuration["envScenario"] = (
                "globalThis.ctrlxProbeHeaderName = 'x-maas-env';"
                "globalThis.ctrlxProbeHeaderValue = 'ark-chat-dev';\n" + configuration["envScenario"])
    if options_mode == "env":
        if not env_extension:
            raise ValueError("ENV options require a verified ENV extension directory")
        configuration["optionsMode"] = options_mode
    elif options_mode:
        if env_extension or fixture_packages:
            raise ValueError("Options fixtures use their own generated extension")
        configuration["optionsMode"] = options_mode
        manifest = json.loads((extension / "manifest.json").read_text())
        if options_mode == "legacy":
            manifest["options_page"] = "options.html"
        elif options_mode != "none":
            manifest["options_ui"] = {"page": "options.html", "open_in_tab": options_mode == "tab"}
        (extension / "manifest.json").write_text(json.dumps(manifest))
        (extension / "options.html").write_text('<!doctype html><title>Fixture Settings</title><style>body{min-width:360px;min-height:180px}</style><h1>Fixture Settings</h1><input id="setting" value="options fixture"><script src="options.js"></script>')
        (extension / "options.js").write_text("""
(async () => {
  const previous = await chrome.storage.local.get('optionsLoads');
  const count = (previous.optionsLoads || 0) + 1;
  await chrome.storage.local.set({optionsLoads: count});
  const saved = await chrome.storage.local.get('optionsLoads');
  await fetch(%s, {method: 'POST', body: JSON.stringify({saved: saved.optionsLoads})});
})();
""" % json.dumps(configuration["fixture"] + "/options-report"))
    config_path = output / "config.json"
    config_path.write_text(json.dumps(configuration))
    def launch(log_name):
        with (output / log_name).open("wb") as native_log:
            process = subprocess.Popen([str(executable), str(config_path)], stdout=native_log,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            try:
                process.wait(timeout=(105 if env_extension else 60) + (25 if options_mode else 0))
            except (subprocess.TimeoutExpired, KeyboardInterrupt):
                # Stop only this test's own process group; never target an app by name.
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
                raise
        return process.returncode, (output / log_name).read_bytes()

    restart = None
    try:
        exit_code, raw = launch("native.log")
        if exit_code == 0 and env_restart_scenario:
            shutil.copyfile(config_path, output / "config-initial.json")
            configuration["envRestart"] = True
            configuration["envScenario"] = env_restart_scenario.read_text()
            config_path.write_text(json.dumps(configuration))
            restart_code, restart_raw = launch("restart-native.log")
            restart_observations = [json.loads(line.removeprefix("EXTENSION_PROBE "))
                                    for line in restart_raw.decode(errors="replace").splitlines()
                                    if line.startswith("EXTENSION_PROBE ")]
            restart_phases = {entry["phase"]: entry["result"] for entry in restart_observations}
            restored = (restart_code == 0 and "failure" not in restart_phases
                        and {"env-restored", "env-popup", "env-scenario", "env-popup-capture", "shutdown"} <= restart_phases.keys()
                        and restart_phases["shutdown"]["complete"])
            restart = {"probeCompleted": restored, "exitCode": restart_code, "observations": restart_observations}
    finally:
        server.shutdown()
        server.server_close()
        server_thread.join()

    observations = [json.loads(line.removeprefix("EXTENSION_PROBE "))
                    for line in raw.decode(errors="replace").splitlines()
                    if line.startswith("EXTENSION_PROBE ")]
    phases = {entry["phase"]: entry["result"] for entry in observations}
    required = {"manager", "alloy-with-manager", "alloy-without-manager", "chrome-control", "chrome-other-window", "popup-capture", "shutdown"}
    if dynamic_install:
        required |= {"install-dialog", "dynamic-install"}
    if native_drag:
        required |= {"native-drag", "dynamic-install"}
    if production_admin and env_extension is None:
        required |= {"production-admin-install", "production-admin-disabled", "production-admin-enabled",
                     "production-admin-reloaded", "production-admin-uninstalled", "uninstall-confirmation", "background-management-focus"}
        if packages:
            required |= {"fixture-updated", "fixture-restored", "fixture-updated-again"}
        if native_manager_input:
            required |= {"native-window-capture", "native-window-input"}
    if env_extension is not None:
        required = {"env-install", "env-popup", "env-popup-capture", "shutdown"}
        if env_scenario:
            required.add("env-scenario")
        if native_window_capture:
            required.add("native-window-capture")
        if native_window_input:
            required |= {"native-window-input", "native-popup-effect", "native-popup-keyboard", "product-native-surface", "product-surface-geometry"}
        if env_debugger:
            required |= {"env-debugger-with-page-cdp", "page-cdp-with-env-debugger",
                         "env-debugger-with-devtools", "page-cdp-with-devtools", "devtools-window-ready"}
    if options_mode == "env":
        required = {"env-install", "options-reused", "options-native-surface", "shutdown"}
    complete = (exit_code == 0 and required <= phases.keys()
                and "failure" not in phases and phases["shutdown"]["complete"])
    if env_restart_scenario:
        complete &= restart is not None and restart["probeCompleted"]
    if production_admin and env_extension is None and complete:
        installed = phases["production-admin-install"]["extensions"]
        fixture = next((item for item in installed if item.get("path") == str(extension)), None)
        complete = bool(fixture) and fixture["state"] == "ENABLED"
        if fixture:
            complete &= all(item["id"] != fixture["id"] for item in phases["production-admin-uninstalled"]["extensions"])
            for phase, state in (("production-admin-disabled", "DISABLED"), ("production-admin-enabled", "ENABLED"),
                                 ("production-admin-reloaded", "ENABLED")):
                complete &= any(item["id"] == fixture["id"] and item["state"] == state for item in phases[phase]["extensions"])
    compatibility = {}
    for phase in ("alloy-with-manager", "alloy-without-manager", "chrome-control", "chrome-other-window"):
        if phase not in phases:
            continue
        result = phases[phase]
        extension = result["extension"]
        queries = extension.get("queries", {})
        url = result["url"]
        popups = [report for report in popup_reports if report.get("source") == url]
        compatibility[phase] = {
            "contentScript": bool(extension.get("id")),
            "requestHeaderModified": result["echo"].get("extensionHeader") == "active",
            "tabEnumerated": any(tab.get("url") == url for tab in queries.get("all", [])),
            "currentTabCorrect": any(tab.get("url") == url for tab in queries.get("activeCurrentWindow", [])),
            "popupObserved": bool(popups),
            "popupCurrentTabCorrect": bool(popups) and all(
                any(tab.get("url") == url for tab in popup["queries"]["activeCurrentWindow"])
                for popup in popups),
        }
        if phase in ("chrome-control", "chrome-other-window"):
            complete &= all(compatibility[phase].values())
    scenario = phases.get("env-scenario", {})
    if env_debugger:
        compatibility["env-debugger"] = {
            "attachedWithPageCDP": phases.get("env-debugger-with-page-cdp", {}).get("attached") is True,
            "stillAttachedWithDevTools": bool(phases.get("env-debugger-with-devtools", {}).get("alive")),
            "pageControlSurvived": "page-cdp-with-env-debugger" in phases and "page-cdp-with-devtools" in phases,
        }
    if scenario.get("configuredThroughPopup"):
        expected = "ark-chat-dev" if cors else "env-active"
        compatibility["env-request-headers"] = {
            "baselineClear": scenario.get("before", {}).get("extensionHeader") is None,
            "active": scenario.get("active", {}).get("extensionHeader") == expected,
            "paused": scenario.get("paused", {}).get("extensionHeader") is None,
            "resumed": scenario.get("resumed", {}).get("extensionHeader") == expected,
        }
        complete &= all(compatibility["env-request-headers"].values())
    if cors:
        compatibility["cors"] = cors_fixture.acceptance(phases, env_extension is not None)
        complete &= all(compatibility["cors"].values())
    if options_mode:
        if options_mode == "env":
            valid = (phases.get("options-reused", {}).get("sameBrowser") is True
                     and phases.get("options-native-surface", {}).get("captured") is True
                     and phases.get("options-native-surface", {}).get("url") == "chrome-extension://imebogohheacbbmhfiiddakclhifpbde/options.html")
        elif options_mode == "none":
            valid = phases.get("options-unavailable", {}).get("rejected") is True and not options_reports
        else:
            valid = (phases.get("options-reused", {}).get("sameBrowser") is True
                     and phases.get("options-native-surface", {}).get("captured") is True
                     and phases.get("options-native-surface", {}).get("visible") is True
                     and len(options_reports) == 1 and options_reports[0]["saved"] == 1
                     and phases["options-native-surface"]["url"].startswith(
                         "chrome://extensions/?options=" if options_mode == "embedded" else "chrome-extension://"))
        compatibility["store-routing"] = phases.get("store-routing", {})
        takeover_phases = ("store-host-takeover", "store-host-after-release", "store-host-after-expiry")
        for phase in takeover_phases:
            compatibility[phase] = phases.get(phase, {})
        compatibility["options"] = {"mode": options_mode, "passed": valid}
        complete &= (valid and phases.get("store-routing", {}).get("passed") is True
                     and all(phases.get(phase, {}).get("passed") is True for phase in takeover_phases))
    report = {"probeCompleted": complete, "exitCode": exit_code,
              "compatibility": compatibility, "observations": observations, "popups": popup_reports,
              "restart": restart, "networkEvents": cors_fixture.requests, "options": options_reports,
              "scope": "ENV-Plugin: only operations recorded in observations and compatibility; native messaging and remote clients not covered" if env_extension is not None else
                       "Local fixture only; not ENV-Plugin, CRX verification or Web Store installation acceptance"}
    (output / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"evidence": str(output), "probeCompleted": complete, "compatibility": compatibility}, indent=2))
    if not complete:
        raise RuntimeError(f"The extension probe did not complete. See {output / 'native.log'}")
    return output


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--dynamic-install", action="store_true")
    parser.add_argument("--native-drag", action="store_true")
    parser.add_argument("--production-admin", action="store_true")
    parser.add_argument("--env-extension", type=Path, help="ENV directory prepared by the product CRX verifier; never a live profile")
    parser.add_argument("--env-scenario", type=Path, help="Test-only popup script executed in the disposable ENV profile")
    parser.add_argument("--env-restart-scenario", type=Path, help="Restart the same private profile without reinstalling, then run this popup script")
    parser.add_argument("--fixture-packages", type=Path, help="Versioned ZIP packages exported by BrowserExtensionStoreTests")
    parser.add_argument("--native-window-capture", action="store_true", help="Capture only the probe process's Chrome window with child popups")
    parser.add_argument("--native-window-input", action="store_true", help="Also pause ENV through a native click restricted to the source window's child popup")
    parser.add_argument("--native-manager-input", action="store_true", help="Capture and confirm fixture removal through only the manager window's owned tree")
    parser.add_argument("--env-debugger", action="store_true", help="Characterize ENV debugger API coexistence with CEF page control and native DevTools")
    parser.add_argument("--cors", action="store_true", help="Require Chrome-compatible cross-origin header injection and preserve page CORS checks")
    parser.add_argument("--options-mode", choices=["tab", "embedded", "legacy", "none", "env"], help="Verify declared options mode, reuse, storage and native capture")
    args = parser.parse_args()
    run(args.app.resolve(), args.dynamic_install, args.native_drag, args.production_admin,
        args.env_extension, args.env_scenario, args.env_restart_scenario, args.fixture_packages,
        args.native_window_capture, args.native_window_input, args.native_manager_input, args.env_debugger, args.cors, args.options_mode)
