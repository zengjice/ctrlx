#!/usr/bin/env python3
"""Build pinned upstream sources into a relocatable, signed macOS helper set."""
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / '.build-local/device-installer'
PREFIX = CACHE / 'prefix'
OUTPUT = CACHE / 'Runtime'
LICENSES = CACHE / 'Licenses'
SOURCES = ROOT / 'CtrlxPackage/DeviceInstaller/ThirdParty/sources.json'
TOOLS = ('ideviceinstaller', 'idevice_id', 'ideviceinfo', 'idevicepair')
# Bump when upstream configure/compiler options change. Relocation is separate.
BUILD_RECIPE = 'macos15-shared-1'


def run(*args, cwd=None, env=None):
    print('+', *map(str, args), flush=True)
    subprocess.run(list(map(str, args)), check=True, cwd=cwd, env=env)


def digest(path):
    with path.open('rb') as stream:
        value = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
        return value.hexdigest()


def dependencies(path):
    result = subprocess.check_output(['/usr/bin/otool', '-L', str(path)], text=True)
    return [line.strip().split(' (')[0] for line in result.splitlines()[1:]]


def main():
    if platform.system() != 'Darwin':
        raise RuntimeError('Device installer builds require macOS.')
    packages = json.loads(SOURCES.read_text())
    architecture = platform.machine()
    identity = os.environ.get('CTRLX_DEVICE_INSTALLER_SIGN_IDENTITY')
    if not identity:
        found = subprocess.check_output(['security', 'find-identity', '-v', '-p', 'codesigning'], text=True)
        match = re.search(r'([0-9A-F]{40}) "Apple Development:', found)
        if not match:
            raise RuntimeError('An Apple Development signing identity is required.')
        identity = match[1]
    fingerprint = hashlib.sha256(SOURCES.read_bytes() + Path(__file__).read_bytes() + architecture.encode() + identity.encode()).hexdigest()
    source_fingerprint = hashlib.sha256(SOURCES.read_bytes() + architecture.encode() + BUILD_RECIPE.encode()).hexdigest()
    record = CACHE / 'build.json'
    if record.exists():
        previous = json.loads(record.read_text())
        if previous.get('fingerprint') == fingerprint and all(
                (OUTPUT / name).is_file() and digest(OUTPUT / name) == sha
                for name, sha in previous['files'].items()):
            print('Verified cached device installer:', OUTPUT)
            return
    CACHE.mkdir(parents=True, exist_ok=True)
    record.unlink(missing_ok=True)
    PREFIX.mkdir(exist_ok=True)
    LICENSES.mkdir(exist_ok=True)
    env = dict(os.environ, MACOSX_DEPLOYMENT_TARGET='15.0',
               CC='/usr/bin/clang', CXX='/usr/bin/clang++',
               CFLAGS='-O2 -fPIC -mmacosx-version-min=15.0',
               CXXFLAGS='-O2 -fPIC -mmacosx-version-min=15.0',
               CPPFLAGS='-I' + str(PREFIX / 'include'), LDFLAGS='-L' + str(PREFIX / 'lib'),
               PKG_CONFIG_PATH=str(PREFIX / 'lib/pkgconfig'),
               PKG_CONFIG_LIBDIR=str(PREFIX / 'lib/pkgconfig'), MAKEINFO='true')
    # macOS supplies libcurl, but its pkg-config metadata is not installed.
    # Describe the SDK library explicitly rather than linking Homebrew's curl.
    sdk = subprocess.check_output(['/usr/bin/xcrun', '--show-sdk-path'], text=True).strip()
    curl_version = subprocess.check_output(['/usr/bin/curl-config', '--version'], text=True).split()[-1]
    metadata = PREFIX / 'lib/pkgconfig'
    metadata.mkdir(parents=True, exist_ok=True)
    (metadata / 'libcurl.pc').write_text(
        'Name: libcurl\nDescription: macOS system libcurl\nVersion: ' + curl_version +
        '\nLibs: -lcurl\nCflags: -isystem ' + sdk + '/usr/include\n')
    flags = {'libplist': ['--without-cython'],
             'libimobiledevice': ['--without-cython', '--without-readline']}
    for package in packages:
        archive = CACHE / package['url'].rsplit('/', 1)[1]
        if not archive.exists():
            partial = archive.with_suffix(archive.suffix + '.part')
            run('/usr/bin/curl', '--fail', '--location', '--retry', '2', '--connect-timeout', '20',
                '--max-time', '600', '--output', partial, package['url'])
            if digest(partial) != package['sha256']:
                raise RuntimeError('Source checksum mismatch: ' + package['name'])
            partial.rename(archive)
        if digest(archive) != package['sha256']:
            raise RuntimeError('Cached source checksum mismatch: ' + package['name'])
        source = CACHE / (package['name'] + '-' + package['version'])
        if not source.exists():
            run('/usr/bin/tar', '-xf', archive, '-C', CACHE)
        stamp = source / '.ctrlx-built'
        if not stamp.exists() or stamp.read_text() != source_fingerprint:
            if package['name'] == 'openssl':
                target = 'darwin64-arm64-cc' if architecture == 'arm64' else 'darwin64-x86_64-cc'
                run('./Configure', target, '--prefix=' + str(PREFIX), '--libdir=lib',
                    'shared', 'no-tests', 'no-docs', 'no-module', cwd=source, env=env)
                run('make', '-j4', cwd=source, env=env)
                run('make', 'install_sw', cwd=source, env=env)
            elif package['name'] == 'libzip':
                run('cmake', '-S', source, '-B', source / 'build',
                    '-DCMAKE_INSTALL_PREFIX=' + str(PREFIX), '-DCMAKE_BUILD_TYPE=Release',
                    '-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0', '-DBUILD_SHARED_LIBS=ON',
                    '-DENABLE_BZIP2=OFF', '-DENABLE_LZMA=OFF', '-DENABLE_ZSTD=OFF',
                    '-DENABLE_OPENSSL=OFF', '-DENABLE_GNUTLS=OFF', '-DENABLE_MBEDTLS=OFF',
                    '-DBUILD_TOOLS=OFF', '-DBUILD_REGRESS=OFF', '-DBUILD_EXAMPLES=OFF',
                    '-DBUILD_DOC=OFF', env=env)
                run('cmake', '--build', source / 'build', '--parallel', '4', env=env)
                run('cmake', '--install', source / 'build', env=env)
            else:
                run('./configure', '--prefix=' + str(PREFIX), '--disable-static', '--enable-shared',
                    *flags.get(package['name'], []), cwd=source, env=env)
                run('make', '-j4', cwd=source, env=env)
                run('make', 'install', cwd=source, env=env)
            stamp.write_text(source_fingerprint)
        notices = LICENSES / package['name']
        notices.mkdir(exist_ok=True)
        for notice in list(source.glob('COPYING*')) + list(source.glob('LICENSE*')):
            if notice.is_file():
                shutil.copy2(notice, notices / notice.name)
        if not any(notices.iterdir()):
            raise RuntimeError('Missing upstream license: ' + package['name'])
    if OUTPUT.exists():
        shutil.rmtree(OUTPUT)
    (OUTPUT / 'lib').mkdir(parents=True)
    queue = []
    for name in TOOLS:
        target = OUTPUT / name
        shutil.copy2(PREFIX / 'bin' / name, target)
        queue.append(target)
    visited = set()
    while queue:
        target = queue.pop()
        if target in visited:
            continue
        visited.add(target)
        is_library = target.parent.name == 'lib'
        for dependency in dependencies(target):
            if dependency.startswith(('/usr/lib/', '/System/Library/')):
                continue
            name = Path(dependency).name
            source_library = PREFIX / 'lib' / name if dependency.startswith('@rpath/') else Path(dependency)
            if not str(source_library).startswith(str(PREFIX) + '/') or not source_library.is_file():
                raise RuntimeError('Unbundled dependency: ' + dependency)
            library = OUTPUT / 'lib' / name
            if not library.exists():
                shutil.copy2(source_library.resolve(), library)
                queue.append(library)
            replacement = '@loader_path/' + ('' if is_library else 'lib/') + name
            run('/usr/bin/install_name_tool', '-change', dependency, replacement, target)
        if is_library:
            run('/usr/bin/install_name_tool', '-id', '@loader_path/' + target.name, target)
    for target in sorted(visited):
        run('/usr/bin/codesign', '--force', '--sign', identity, '--options', 'runtime', target)
        run('/usr/bin/codesign', '--verify', '--strict', target)
    for name in TOOLS:
        run(OUTPUT / name, '--help', env={'PATH': '/usr/bin:/bin'})
    record.write_text(json.dumps({'fingerprint': fingerprint, 'architecture': architecture, 'signingIdentity': identity,
                                 'sources': packages, 'files': {str(p.relative_to(OUTPUT)): digest(p) for p in sorted(visited)}}, indent=2) + '\n')
    print('Built self-contained device installer:', OUTPUT)


if __name__ == '__main__':
    main()
