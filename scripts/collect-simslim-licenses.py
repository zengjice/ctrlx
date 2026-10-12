#!/usr/bin/env python3
"""Bundle notices for the modules actually linked into the pinned simslim CLI."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

go, source, output, commit, archive_sha = sys.argv[1:]
source, output = Path(source), Path(output)
template = '{{if .Module}}{{.Module.Path}}\t{{.Module.Dir}}{{end}}'
linked = subprocess.check_output([go, 'list', '-mod=readonly', '-deps', '-f', template, './cmd/simslim'], cwd=source, text=True)
modules = dict(line.split('\t', 1) for line in linked.splitlines() if line)
modules['Go standard library'] = subprocess.check_output([go, 'env', 'GOROOT'], text=True).strip()
notices, manifest = [], []
for module, directory in sorted(modules.items()):
    files = sorted(p for p in Path(directory).iterdir() if p.is_file()
                   and p.name.lower() in {'license', 'license.md', 'license.txt', 'copying', 'notice', 'notice.md', 'notice.txt', 'patents'})
    if module == 'Go standard library' and not (Path(directory) / 'LICENSE').exists():
        # Homebrew puts the distribution license beside libexec/GOROOT.
        license_path = Path(directory).parent / 'LICENSE'
        if license_path.is_file(): files.append(license_path)
    licenses = [p for p in files if p.name.lower() not in {'notice', 'notice.md', 'notice.txt', 'patents'}]
    if not licenses:
        raise SystemExit('Missing license for linked module: ' + module)
    text = '\n'.join(p.read_text() for p in licenses)
    if 'Permission is hereby granted' in text:
        kind = 'MIT'
    elif 'Redistribution and use in source and binary forms' in text:
        kind = 'BSD-3-Clause' if 'Neither the name' in text or '3.' in text else 'BSD-2-Clause'
    elif 'Apache License' in text and 'Version 2.0' in text:
        kind = 'Apache-2.0'
    elif 'Permission to use, copy, modify, and distribute' in text:
        kind = 'ISC'
    else:
        raise SystemExit('Unreviewed license for linked module: ' + module)
    records = []
    for path in files:
        data = path.read_bytes()
        notices.append(module + ' — ' + path.name + '\n\n' + data.decode() + '\n')
        records.append({'file': path.name, 'sha256': hashlib.sha256(data).hexdigest()})
    manifest.append({'module': module, 'license': kind, 'notices': records})
(output / 'simslim-NOTICES.txt').write_text('\n' + ('\n' + '=' * 72 + '\n').join(notices))
data = {'commit': commit, 'sourceArchiveSHA256': archive_sha,
        'goVersion': subprocess.check_output([go, 'version'], text=True).strip(),
        'binarySHA256': hashlib.sha256((output / 'simslim').read_bytes()).hexdigest(), 'modules': manifest}
(output / 'simslim-build.json').write_text(json.dumps(data, indent=2) + '\n')
print('Collected notices for', len(manifest), 'linked modules:', ', '.join(sorted({row['license'] for row in manifest})))
