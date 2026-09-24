#!/usr/bin/env python3
"""Stage a source-only snapshot. Excludes credentials, local history and private evidence."""
import argparse
import hashlib
import json
import re
import shutil
from pathlib import Path
from public_documents import document_paths

ROOT = Path(__file__).resolve().parent.parent
TOP = ['README.md', 'MINT.md', 'LICENSE', 'THIRD_PARTY_NOTICES.md', 'VERSION', 'Package.swift', '.gitignore']
DIRECTORIES = ['Sources', 'Resources', 'prompts', 'evals', 'scripts', 'service/src', 'service/test']
ADDITIONAL = ['service/README.md', 'service/package.json', 'service/pnpm-lock.yaml', 'service/pnpm-workspace.yaml',
              'service/wrangler.toml', 'service/.gitignore']
SECRET = re.compile(rb'(?:-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|sk-(?:proj-)?[A-Za-z0-9_-]{40,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    destination = args.destination.resolve()
    if destination.exists() and any(destination.iterdir()):
        parser.error('destination must be empty; existing files are preserved')
    paths = [ROOT / name for name in TOP]
    for directory in DIRECTORIES:
        paths.extend(p for p in (ROOT / directory).rglob('*') if p.is_file())
    paths.extend(ROOT / name for name in ADDITIONAL if (ROOT / name).is_file())
    paths = set(p for p in paths if '__pycache__' not in p.parts and p.suffix not in ['.pyc', '.log'])
    try:
        # This explicitly includes the reviewed synthetic service-test log, not
        # arbitrary logs. It also keeps guide images and DMG requirements in sync.
        paths.update(document_paths(ROOT))
    except ValueError as error:
        parser.error(str(error))
    paths = sorted(paths)
    for path in paths:
        if path.is_symlink() or not path.resolve().is_relative_to(ROOT):
            parser.error('source snapshot refuses symlinks: ' + str(path.relative_to(ROOT)))
        if not path.is_file():
            parser.error('missing required source file: ' + str(path.relative_to(ROOT)))
        if SECRET.search(path.read_bytes()):
            parser.error('possible credential in ' + str(path.relative_to(ROOT)) + '; content was not printed')
    destination.mkdir(parents=True, exist_ok=True)
    manifest = {}
    for path in paths:
        relative = path.relative_to(ROOT)
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
        manifest[str(relative)] = hashlib.sha256(target.read_bytes()).hexdigest()
    (destination / 'SOURCE-MANIFEST.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'Staged {len(manifest)} source files; no build outputs, credentials or private evidence were included.')


if __name__ == '__main__':
    main()
