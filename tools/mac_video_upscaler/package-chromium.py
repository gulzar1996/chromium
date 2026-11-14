#!/usr/bin/env python3
"""Package the local arm64 component build as a self-contained, ad-hoc signed DMG."""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import tempfile

ROOT = next(parent for parent in Path(__file__).resolve().parents if (parent / '.git').exists())
LOAD_DYLIB = {0xc, 0x80000018, 0x8000001f, 0x80000023}


def run(*args):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f'{args[0]} failed: {result.stderr or result.stdout}')
    return result


def macho(path):
    if path.is_symlink() or not path.is_file():
        return False
    with path.open('rb') as stream:
        return stream.read(4) == b'\xcf\xfa\xed\xfe'


def commands(path):
    with path.open('rb') as stream:
        header = stream.read(32)
        count, size = struct.unpack_from('<II', header, 16)
        data = stream.read(size)
    offset = 0
    for _ in range(count):
        command, size = struct.unpack_from('<II', data, offset)
        if command in LOAD_DYLIB | {0x8000001c}:
            start = offset + struct.unpack_from('<I', data, offset + 8)[0]
            yield command, data[start:data.index(0, start)].decode()
        offset += size


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    default_build = ROOT / ('out/Upscale' if (ROOT / 'chrome').is_dir() else 'chromium-work/browser/src/out/Upscale')
    parser.add_argument('--build-dir', type=Path, default=default_build)
    parser.add_argument('--output-dir', type=Path, default=ROOT / 'dist/releases')
    parser.add_argument('--version', default='0.1.0')
    args = parser.parse_args()
    build = args.build_dir.resolve()
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    dmg = output / f'Chromium-Video-Effects-{args.version}-macOS-arm64.dmg'
    if dmg.exists():
        raise SystemExit(f'Refusing to overwrite {dmg}')
    with tempfile.TemporaryDirectory(prefix='chromium-package-') as directory:
        stage = Path(directory).resolve()
        app = stage / 'Chromium.app'
        run('ditto', build / 'Chromium.app', app)
        framework = app / 'Contents/Frameworks/Chromium Framework.framework'
        libraries = (framework / 'Versions/Current/Libraries').resolve()
        binaries = [p for p in app.rglob('*') if macho(p)]
        queue = list(binaries)
        copied = set()
        # Follow the dependency closure, including every helper executable.
        # Do not ship unrelated test libraries from the build directory.
        while queue:
            binary = queue.pop()
            for command, name in commands(binary):
                if command not in LOAD_DYLIB:
                    continue
                if name.startswith(('/usr/lib/', '/System/Library/')):
                    continue
                if name.startswith('@rpath/Chromium Framework.framework/'):
                    continue
                if name.startswith('@rpath/') and '/' not in name[len('@rpath/'):]:
                    dest = libraries / name.removeprefix('@rpath/')
                    if dest.exists():
                        continue
                    source = build / dest.name
                    if not source.is_file():
                        raise RuntimeError(f'Missing dependency {name} required by {binary}')
                    shutil.copy2(source, dest)
                    copied.add(dest)
                    queue.append(dest)
                else:
                    raise RuntimeError(f'Unexpected non-system dependency {name} in {binary}')
        print(f'Bundled {len(copied)} component libraries', flush=True)
        # Standalone helpers also need to find the bundled libraries.
        for binary in binaries:
            rpaths = [name for command, name in commands(binary) if command == 0x8000001c]
            if any(Path(name.replace('@loader_path', str(binary.parent)).replace(
                    '@executable_path', str(binary.parent))).resolve() == libraries for name in rpaths):
                continue
            # These binaries have no load-command padding. Their existing
            # @loader_path/. search path can use relative, in-bundle links.
            if '@loader_path/.' not in rpaths:
                raise RuntimeError(f'No local library search path in {binary}')
            for command, name in commands(binary):
                if command in LOAD_DYLIB and name.startswith('@rpath/') and '/' not in name[7:]:
                    target = libraries / name[7:]
                    link = binary.parent / target.name
                    if not link.exists():
                        link.symlink_to(os.path.relpath(target, link.parent))
        # Keep the original entitlements and sign nested code before containers.
        for binary in binaries + sorted(copied):
            run('codesign', '--force', '--sign', '-', '--preserve-metadata=entitlements', binary)
        bundles = [p for p in app.rglob('*') if p.is_dir() and not p.is_symlink() and p.suffix in ('.app', '.framework')]
        for bundle in sorted(bundles, key=lambda p: len(p.parts), reverse=True) + [app]:
            run('codesign', '--force', '--sign', '-', '--preserve-metadata=entitlements', bundle)
        run('codesign', '--verify', '--deep', '--strict', app)
        with (app / 'Contents/Info.plist').open('rb') as stream:
            info = plistlib.load(stream)
        (stage / 'Applications').symlink_to('/Applications')
        (stage / 'READ ME.txt').write_text(
            f'Chromium Video Effects {args.version}\n'
            f'Chromium {info["CFBundleShortVersionString"]}; Apple silicon; macOS 26 or later.\n\n'
            'Drag Chromium.app to Applications, then launch it and open chrome://video-effects/.\n'
            'Enable effects and choose VideoToolbox 2x or MetalFX 2x upscaling.\n'
            'Motion processing, output frame rate, and temporal noise controls are hidden.\n'
            'Effects start disabled in a fresh profile.\n\n'
            'This experimental build is ad-hoc signed and is not notarized by Apple.\n'
            'macOS may require an explicit approval in System Settings > Privacy & Security.\n'
            'No automatic updates are configured.\n'
            'Uses the standard Chromium profile; keep a backup if you already use Chromium.\n\n'
            'Third-party notices are available at chrome://credits/.\n'
        )
        shutil.copy2(build.parent.parent / 'LICENSE', stage / 'CHROMIUM-LICENSE.txt')
        run('hdiutil', 'create', '-volname', f'Chromium Video Effects {args.version}',
            '-srcfolder', stage, '-format', 'UDZO', '-imagekey', 'zlib-level=9', dmg)
    run('hdiutil', 'verify', dmg)
    with dmg.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    checksum = dmg.with_suffix('.dmg.sha256')
    checksum.write_text(f'{digest}  {dmg.name}\n')
    print(f'Created {dmg} ({dmg.stat().st_size / 1024**2:.1f} MiB)')
    print(f'SHA-256: {digest}')


if __name__ == '__main__':
    main()
