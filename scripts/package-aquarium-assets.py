#!/usr/bin/env python3
"""Build an immutable, data-only aquarium pack; keep authored resources in the repo."""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'Sources/WhileAIWorks/Resources/AquariumAssets'
MANIFEST = ROOT / 'Sources/WhileAIWorks/Resources/AquariumPack.json'


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', default=None)
    parser.add_argument('--check', action='store_true', help='Validate source inventory against the pinned manifest without rebuilding the archive')
    parser.add_argument('--update-manifest', action='store_true')
    args = parser.parse_args()
    old = json.loads(MANIFEST.read_text()) if MANIFEST.exists() else None
    args.version = args.version or str(old['version'] if old else 1)
    if not args.version.isdecimal():
        parser.error('version must be a positive integer')
    version = int(args.version)
    if version < 1:
        parser.error('version must be a positive integer')
    files = []
    for path in sorted(SOURCE.rglob('*')):
        if not path.is_file() or path.is_symlink():
            continue
        relative = path.relative_to(SOURCE)
        if relative.parts[0] == 'Aquascape' or path.name.startswith('.'):
            continue
        if path.suffix == '.json' and not path.name.endswith('.meta.json') and path.with_suffix('.meta.json').exists():
            meta = json.loads(path.with_suffix('.meta.json').read_text())
            if meta['_sourceSHA256'] != digest(path) or not path.with_suffix('.meshbin').is_file():
                raise SystemExit(f'Repack stale mesh before packaging: {relative}')
            continue
        files.append({'path': relative.as_posix(), 'bytes': path.stat().st_size, 'sha256': digest(path)})
    if args.check:
        if not old or old['version'] != version or old['files'] != files:
            raise SystemExit('Resource pack differs from its pinned manifest; generate a new version with --update-manifest')
        print(f'Aquarium pack v{version}: source inventory verified ({len(files)} files); excluded from app bundle')
        return
    if old and old['version'] == version and old['files'] != files:
        raise SystemExit('Existing pack versions are immutable; increment --version for changed resources')
    folder = ROOT / f'dist/resource-packs/aquarium-v{version}'
    folder.mkdir(parents=True, exist_ok=True)
    archive = folder / f'While-AI-Works-Aquarium-v{version}.zip'
    # Stable file order, timestamps and permissions make the pinned archive reproducible.
    with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as packed:
        for entry in files:
            info = zipfile.ZipInfo('AquariumAssets/' + entry['path'], date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            packed.writestr(info, (SOURCE / entry['path']).read_bytes())
    manifest = {'schema': 1, 'version': version,
                'url': f'https://github.com/xiaoyan648/while-ai-works/releases/download/aquarium-assets-v{version}/{archive.name}',
                'archiveBytes': archive.stat().st_size, 'sha256': digest(archive),
                'installedBytes': sum(entry['bytes'] for entry in files), 'files': files}
    encoded = json.dumps(manifest, ensure_ascii=False, indent=2) + '\n'
    if args.update_manifest:
        if MANIFEST.exists():
            old = json.loads(MANIFEST.read_text())
            if old['version'] == version and old != manifest:
                raise SystemExit('Existing pack versions are immutable; increment --version for changed resources')
        MANIFEST.write_text(encoded)
    elif not MANIFEST.exists() or json.loads(MANIFEST.read_text()) != manifest:
        raise SystemExit('Resource pack differs from its pinned manifest; generate a new version with --update-manifest')
    (folder / 'AquariumPack.json').write_text(encoded)
    (folder / 'SHA256SUMS.txt').write_text(manifest['sha256'] + '  ' + archive.name + '\n')
    print(f'Pack: {archive}\nDownload: {manifest["archiveBytes"] / 1048576:.1f} MiB; installed: {manifest["installedBytes"] / 1048576:.1f} MiB; files: {len(files)}')


if __name__ == '__main__':
    main()
