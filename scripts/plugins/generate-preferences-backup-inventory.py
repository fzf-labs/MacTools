#!/usr/bin/env python3
"""Generate the backup coverage inventory from canonical source manifests."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from plugin_source_manifest import load_known_plugin_ids, validate_and_project_manifest

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "docs/plugins/preferences-backup-inventory.md"


def render() -> str:
    known_ids = load_known_plugin_ids(ROOT / "Plugins")
    rows = []
    counts: dict[str, int] = {}
    for path in sorted((ROOT / "Plugins").glob("*/plugin.json")):
        source = json.loads(path.read_text())
        manifest, _ = validate_and_project_manifest(source, path, known_ids)
        coverage = manifest["preferencesBackup"]
        status = coverage["status"]
        counts[status] = counts.get(status, 0) + 1
        title = manifest["localizedMetadata"]["en"]["displayName"].replace("|", "\\|")
        reasons = ", ".join(coverage["exclusions"]) or "—"
        rows.append(f"| [{title}](../../Plugins/{path.parent.name}) | `{manifest['id']}` | {status} | {reasons} |")
    return "\n".join([
        "# Preferences Backup coverage inventory", "",
        "Generated from `Plugins/*/plugin.json`; do not edit this table by hand.",
        "Run `python3 scripts/plugins/generate-preferences-backup-inventory.py` after changing a declaration.", "",
        "Declarations describe supported field boundaries. Runtime availability and export/restore failures are reported separately.",
        "See [the backup contract](preferences-backup.md) for exclusions and recovery limits.", "",
        "; ".join(f"{status}: {count}" for status, count in sorted(counts.items())) + ".", "",
        "| Plugin | ID | Coverage | Exclusion codes |", "| --- | --- | --- | --- |", *rows, "",
    ])


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    expected = render()
    if args.check:
        if not OUTPUT.exists() or OUTPUT.read_text() != expected:
            parser.exit(1, "Backup inventory is stale; regenerate it.\n")
    else:
        OUTPUT.write_text(expected)


if __name__ == "__main__":
    main()
