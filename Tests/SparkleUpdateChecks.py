"""Exercise real Sparkle downloads/signatures/installations in disposable .build app copies."""
import functools
import hashlib
import http.server
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import threading
import time
import uuid
import xml.etree.ElementTree as ET

root, driver, sparkle = map(Path, sys.argv[1:])
app = root / 'dist/While AI Works.app'
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
arch = subprocess.check_output(['lipo', '-archs', str(app / 'Contents/MacOS/WhileAIWorks')], text=True).strip()
archive = root / f'dist/releases/{version}/While-AI-Works-{version}-macOS-{arch}.zip'
work = root / '.build' / ('sparkle-check-' + str(uuid.uuid4()))
work.mkdir()
namespace = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', namespace)

def run(*args):
    return subprocess.run(list(map(str, args)), check=True, capture_output=True, text=True)

def sign(file):
    run(sparkle / 'bin/sign_update', '--account', 'local.whileaiworks.mac', file)

def fingerprints(target):
    return {name: hashlib.sha256((target / name).read_bytes()).hexdigest()
            for name in ['Contents/Info.plist', 'Contents/MacOS/WhileAIWorks']}

class QuietServer(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(QuietServer, directory=str(work)))
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f'http://127.0.0.1:{server.server_port}/'

try:
    # Let the official tool derive the app version, hardware requirement, archive signature and feed format.
    source = work / 'archives'
    source.mkdir()
    os.link(archive, source / archive.name)
    run(sparkle / 'bin/generate_appcast', '--account', 'local.whileaiworks.mac', '--maximum-deltas', '0',
        '--download-url-prefix', base, '-o', source / 'appcast.xml', source)
    os.link(archive, work / archive.name)
    bad_archive = work / 'damaged.zip'
    shutil.copyfile(archive, bad_archive)
    with bad_archive.open('r+b') as f:
        first = f.read(1)
        f.seek(0)
        f.write(bytes([first[0] ^ 1]))

    for case, mode, expected in [('cancel', 'cancel', 'success'), ('current', 'cancel', 'success'),
                                 ('bad-feed', 'cancel', 'feed-error'), ('bad-archive', 'install', 'archive-error'),
                                 ('install', 'install', 'success')]:
        target = work / case / 'While AI Works.app'
        target.parent.mkdir()
        run('ditto', app, target)
        shutil.copy2(driver, target / 'Contents/MacOS/WhileAIWorks')
        metadata = dict(info)
        metadata.update(CFBundleVersion=build if case == 'current' else str(int(build) - 1),
                        SUFeedURL=base + case + '.xml', SUEnableAutomaticChecks=False,
                        SUDefaultsDomain='WhileAIWorks.SparkleChecks.' + str(uuid.uuid4()),
                        NSAppTransportSecurity={'NSAllowsArbitraryLoads': True})
        (target / 'Contents/Info.plist').write_bytes(plistlib.dumps(metadata))
        run('codesign', '--force', '--deep', '--sign', '-', target)
        before = fingerprints(target)

        feed = work / (case + '.xml')
        xml = ET.parse(source / 'appcast.xml')
        if case == 'bad-archive':
            xml.find('.//enclosure').set('url', base + 'damaged.zip')
        xml.write(feed, encoding='utf-8', xml_declaration=True)
        sign(feed)
        run(sparkle / 'bin/sign_update', '--account', 'local.whileaiworks.mac', '--verify', feed)
        if case == 'bad-feed':
            data = feed.read_text()
            assert '<title>' in data
            feed.write_text(data.replace('<title>', '<title>tampered ', 1))

        receipt = work / (case + '.receipt')
        with (work / (case + '.log')).open('w') as log:
            process = subprocess.run([str(target / 'Contents/MacOS/WhileAIWorks'), str(receipt), mode, expected],
                                     stdout=log, stderr=log, timeout=100)
        events = receipt.read_text() if receipt.exists() else ''
        assert process.returncode == 0, f'{case}: exit {process.returncode}; {events}; see {work}'
        if case == 'install':
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                try:
                    installed = plistlib.loads((target / 'Contents/Info.plist').read_bytes())
                    if installed['CFBundleVersion'] == build:
                        break
                except (FileNotFoundError, plistlib.InvalidFileException):
                    pass
                time.sleep(0.25)
            else:
                raise AssertionError('Sparkle did not replace the disposable application: ' + events)
            assert 'ready-to-install' in events and 'will-relaunch' in events, events
            run('diff', '-qr', app, target)
            run('codesign', '--verify', '--deep', '--strict', target)
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                entries = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True).splitlines()
                launched = [line.strip().split(None, 1) for line in entries if line.strip()]
                matches = [int(pid) for pid, command in launched if command == str(target / 'Contents/MacOS/WhileAIWorks')]
                if matches:
                    (work / 'relaunched.pid').write_text(str(matches[0]))
                    os.kill(matches[0], signal.SIGTERM)
                    break
                time.sleep(0.1)
            else:
                raise AssertionError('Updated app was not relaunched; quit other While AI Works instances before testing')
        elif case == 'current':
            assert 'no-update' in events and 'downloading' not in events, events
            assert fingerprints(target) == before
        else:
            assert fingerprints(target) == before
            assert 'dismissed' in events if case == 'cancel' else 'rejected' in events, events
        print(f'SparkleUpdateChecks: {case} passed', flush=True)
        shutil.rmtree(target)
    print('SparkleUpdateChecks: actual signed release archive installed byte-for-byte and relaunched; installed app untouched', flush=True)
finally:
    server.shutdown()
    server.server_close()
