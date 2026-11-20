#!/usr/bin/env python3
"""Read Orbie recovery metadata without changing files or printing conversation text."""

import argparse
import json
from pathlib import Path
from uuid import UUID


def inspect(state_root):
    errors = {}

    def read(name, expected):
        path = state_root / name
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
            if not isinstance(value, expected):
                raise ValueError("Unexpected JSON structure")
            return value
        except FileNotFoundError:
            return expected()
        except (OSError, UnicodeError, ValueError) as error:
            errors[name] = type(error).__name__
            return expected()

    def object_value(value):
        return value if isinstance(value, dict) else {}

    def target(record):
        binding = object_value(record.get("binding"))
        creation = object_value(record.get("creation"))
        pane = object_value(binding.get("workspacePane") or creation.get("pane"))
        return binding.get("hostID") or record.get("hostID"), pane.get("paneID")

    current = read("binding.json", dict)
    current_target = target(current)
    report = {"report_version": 2, "read_only": True}
    for name, record in [
        ("binding.json", current),
        ("binding.json.pre-3fix.backup", read("binding.json.pre-3fix.backup", dict)),
    ]:
        binding = object_value(record.get("binding"))
        report[name] = {
            "exists": (state_root / name).exists(),
            "binding": bool(binding),
            "conversation": bool(binding.get("conversationID")),
            "directory": bool(binding.get("workingDirectory")),
            "messages": len(record.get("messageIDs") or []),
            "legacy_runs": len(record.get("legacyRunIDs") or record.get("runIDs") or []),
            "same_target": bool(all(current_target) and target(record) == current_target),
        }

    rows = read("resume.json", list)
    report["resume_file_exists"] = (state_root / "resume.json").exists()
    report["matching_resume_records"] = []
    for row in rows:
        row = object_value(row)
        agent = object_value(row.get("agentID"))
        if not all(current_target) or (agent.get("hostID"), agent.get("paneID")) != current_target:
            continue
        descriptor = object_value(row.get("descriptor"))
        identity = object_value(row.get("identity"))
        source = object_value(identity.get("source"))
        report["matching_resume_records"].append({
            "descriptor": bool(descriptor),
            "descriptor_conversation": bool(descriptor.get("sessionID")),
            "identity": bool(identity),
            "identity_conversation": bool(source.get("sessionID")),
            "invalidated": row.get("invalidated") is True,
            "intent": bool(row.get("intent")),
        })

    # Match the saved process incarnation, not a potentially reused tmux pane.
    binding = object_value(current.get("binding"))
    keys = ("pluginID", "paneID", "processID", "processRuntimeID")
    has_process = all(binding.get(key) for key in keys)
    bridges_name = "../AgentInteraction/bridges.json"
    bridges = read(bridges_name, list)
    report["hook_evidence"] = {
        "file_exists": (state_root / bridges_name).exists(),
        "binding_has_process_evidence": has_process,
        "matching_records": [],
    }
    for bridge in bridges:
        bridge = object_value(bridge)
        if not has_process or any(bridge.get(key) != binding.get(key) for key in keys):
            continue
        try:
            conversation = str(UUID(bridge.get("conversationID", "")))
        except (ValueError, TypeError, AttributeError):
            conversation = None
        report["hook_evidence"]["matching_records"].append({
            "conversation": bool(bridge.get("conversationID")),
            "native_conversation_id": conversation,
        })
    report["errors"] = errors
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-root", type=Path, default=Path.home() / ".ctrlx/state/orbie",
                        help="Orbie state directory (default: ~/.ctrlx/state/orbie)")
    args = parser.parse_args()
    print(json.dumps(inspect(args.state_root.expanduser()), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
