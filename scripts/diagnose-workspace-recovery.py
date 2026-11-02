#!/usr/bin/env python3
"""Read-only report of saved native identities for unresolved workspace panes."""

import argparse
import json
from pathlib import Path
import sys


def diagnose(state_root):
    workspace = json.loads((state_root / "Recovery/workspace.json").read_text())
    identities_file = state_root / "agent-session-identities.json"
    identities = json.loads(identities_file.read_text()) if identities_file.exists() else {}
    failures = []
    for session in workspace.get("sessions", []):
        for window in session.get("windows", []):
            for pane in window.get("panes", []):
                if pane.get("agent") or not pane.get("unavailableAgentReason"):
                    continue
                matches = []
                for record in identities.values():
                    source = record.get("source", {})
                    identity = source.get("workspaceIdentity") or {}
                    if identity.get("paneID") != pane["id"]:
                        continue
                    matches.append({
                        "agent": source.get("pluginID"),
                        "conversation": source.get("sessionID"),
                        "sameSession": identity.get("sessionID") == session["id"],
                        "sameWindow": identity.get("windowID") == window["id"],
                    })
                failures.append({
                    "tab": session["name"] + " / " + window["name"],
                    "paneIdentity": pane["id"],
                    "lastCaptureError": pane["unavailableAgentReason"],
                    "matches": matches,
                })
    return {
        "snapshotGeneration": workspace.get("generation"),
        "identityFileExists": identities_file.exists(),
        "identityRecordCount": len(identities),
        "unresolvedPanes": failures,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-root", type=Path, default=Path.home() / ".ctrlx/state")
    args = parser.parse_args()
    try:
        report = diagnose(args.state_root.expanduser())
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        print(f"Cannot read workspace recovery records: {error}", file=sys.stderr)
        return 1
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
