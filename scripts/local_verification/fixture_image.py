#!/usr/bin/env python3
"""Verified packaging of the pinned Supabase filesystem for VFS test engines.

The derived image retains the entire upstream runtime config and filesystem.
Its image ID changes explicitly; the source digest is never a fake RepoDigest.
No production database, host Docker store path or daemon setting is accessed.
"""
import argparse
import copy
import datetime as dt
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import threading
import urllib.request

POLICY_PATH = Path(__file__).with_name('fixture_postgres_policy.json')


def policy():
    return json.loads(POLICY_PATH.read_text())


def policies():
    fixed = policy()
    return [fixed] + fixed.get('additionalImages', [])


def policy_for_ref(requested):
    matches = [fixed for fixed in policies() if fixed['requestedRef'] == requested]
    require(len(matches) == 1, 'Unreviewed or ambiguous fixture source reference')
    return matches[0]


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def file_digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def runtime_digest(config, fixed):
    return digest(canonical({key: config.get(key) for key in fixed['runtimeConfigKeys']}))


def projected_config(raw, fixed):
    require('sha256:' + digest(raw) == fixed['sourceConfigDigest'], 'Source config digest differs')
    original = json.loads(raw)
    require(original['os'] == fixed['os'] and original['architecture'] == fixed['architecture'],
            'Source image platform differs')
    require(runtime_digest(original['config'], fixed) == fixed['runtimeConfigSha256'],
            'Source runtime configuration differs')
    value = copy.deepcopy(original)
    value['rootfs'] = {'type': 'layers', 'diff_ids': ['sha256:' + fixed['rootfsArchiveSha256']]}
    value['history'] = [{'created': original['created'], 'created_by': 'POS verified rootfs projection v1',
                         'comment': fixed['sourceManifestDigest']}]
    result = canonical(value)
    require('sha256:' + digest(result) == fixed['derivedImageId'], 'Projected image ID differs')
    return result


def validate_image(value, fixed=None):
    fixed = fixed or policy()
    require(value['Id'] == fixed['derivedImageId'], 'Unreviewed fixture image ID')
    require(value['Os'] == fixed['os'] and value['Architecture'] == fixed['architecture'],
            'Fixture image platform differs')
    require(value['RootFS']['Layers'] == ['sha256:' + fixed['rootfsArchiveSha256']],
            'Fixture filesystem differs from verified source tar')
    require(runtime_digest(value['Config'], fixed) == fixed['runtimeConfigSha256'],
            'Fixture runtime configuration differs')
    return value['Id']


def verify_proof(value, run_id, source_sha, fixed=None):
    fixed = fixed or policy()
    require(value.get('schemaVersion') == 1 and value.get('representation') == fixed['representation'],
            'Fixture provenance representation missing')
    require(value.get('runId') == run_id and value.get('sourceSha') == source_sha,
            'Fixture provenance is foreign or stale')
    for key in ('requestedRef', 'sourceRef', 'sourceManifestDigest', 'sourceConfigDigest',
                'sourceRootfsInventorySha256', 'rootfsArchiveSha256', 'runtimeConfigSha256',
                'derivedImageId', 'os', 'architecture'):
        require(value.get(key) == fixed[key], 'Fixture provenance differs: ' + key)
    require(value.get('rootfsLayers') == ['sha256:' + fixed['rootfsArchiveSha256']],
            'Fixture provenance layer mismatch')


def inspect_image(docker, image_id):
    result = subprocess.run(docker + ['image', 'inspect', image_id], capture_output=True, text=True)
    return json.loads(result.stdout)[0] if result.returncode == 0 else None


def verified_fixture_id(image_id, docker):
    matches = [fixed for fixed in policies() if fixed['derivedImageId'] == image_id]
    require(len(matches) == 1, 'Unexpected fixture override')
    fixed = matches[0]
    image = inspect_image(docker, image_id)
    require(image is not None, 'Verified fixture image is missing')
    return validate_image(image, fixed)


def temporary_volume_options(fixed):
    volumes = fixed.get('temporaryVolumes', {})
    require(isinstance(volumes, dict), 'Invalid temporary fixture volumes')
    for path, size in volumes.items():
        require(path == '/var/lib/postgresql/data' and size == 1073741824,
                'Unreviewed temporary database mount')
    return {path: 'rw,size=' + str(size) for path, size in volumes.items()}


def validate_temporary_storage(container, fixed):
    expected = temporary_volume_options(fixed)
    actual = container.get('HostConfig', {}).get('Tmpfs') or {}
    require(all(actual.get(path) == options for path, options in expected.items()),
            'Temporary fixture database storage differs')
    require(not any(m.get('Destination') in expected and m.get('Type') != 'tmpfs'
                    for m in container.get('Mounts', [])), 'Persistent fixture volume mounted unexpectedly')
    return expected


class DiskMonitor:
    """Record the observed shared filesystem peak without inspecting private paths."""
    def __init__(self, directory):
        self.directory = Path(directory)
        self.samples = []
        self.stop_event = threading.Event()
        self.thread = None
        self.result = None

    def sample(self):
        value = os.statvfs(self.directory)
        self.samples.append({'at': dt.datetime.now(dt.timezone.utc).isoformat(),
                             'availableBytes': value.f_bavail * value.f_frsize,
                             'usedBytes': (value.f_blocks - value.f_bfree) * value.f_frsize})

    def start(self):
        self.sample()
        def collect():
            while not self.stop_event.wait(1):
                self.sample()
        self.thread = threading.Thread(target=collect, daemon=True)
        self.thread.start()
        return self

    def stop(self):
        if self.result is not None:
            return self.result
        self.stop_event.set()
        if self.thread:
            self.thread.join(timeout=2)
        self.sample()
        self.result = {'samples': self.samples,
                       'minimumAvailableBytes': min(x['availableBytes'] for x in self.samples),
                       'maximumUsedBytes': max(x['usedBytes'] for x in self.samples),
                       'samplingIntervalSeconds': 1}
        return self.result


def crane_binary(directory, fixed):
    archive = directory / 'crane.tar.gz'
    with urllib.request.urlopen(fixed['crane']['archiveUrl'], timeout=60) as response, archive.open('wb') as stream:
        while chunk := response.read(1024 * 1024):
            stream.write(chunk)
    require(file_digest(archive) == fixed['crane']['archiveSha256'], 'Crane archive checksum differs')
    target = directory / 'crane'
    with tarfile.open(archive) as bundle, bundle.extractfile('crane') as source, target.open('wb') as stream:
        while chunk := source.read(1024 * 1024):
            stream.write(chunk)
    require(file_digest(target) == fixed['crane']['binarySha256'], 'Crane executable checksum differs')
    target.chmod(0o700)
    return target


def registry_read(argv, timeout=600):
    value = subprocess.run(argv, capture_output=True, timeout=timeout)
    # Registry errors can include signed redirects. Do not print their bodies/URLs.
    require(value.returncode == 0, 'Public pinned registry read failed; exit=' + str(value.returncode))
    return value.stdout


def load_projection(docker, rootfs, config, fixed):
    config_name = digest(config) + '.json'
    manifest = canonical([{'Config': config_name, 'RepoTags': [fixed['cacheTag']],
                           'Layers': ['rootfs/layer.tar']}])
    process = subprocess.Popen(docker + ['image', 'load'], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        with tarfile.open(fileobj=process.stdin, mode='w|') as archive:
            for name, data in [(config_name, config), ('manifest.json', manifest)]:
                header = tarfile.TarInfo(name)
                header.size, header.mode = len(data), 0o644
                archive.addfile(header, io.BytesIO(data))
            header = tarfile.TarInfo('rootfs/layer.tar')
            header.size, header.mode = rootfs.stat().st_size, 0o644
            with rootfs.open('rb') as stream:
                archive.addfile(header, stream)
        process.stdin.close()
        output, error = process.stdout.read(), process.stderr.read()
        code = process.wait(timeout=600)
        require(code == 0, 'Docker projection load failed; exit=' + str(code))
        return output.decode(errors='replace')
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=10)


def prepare(output, run_id, source_sha, endpoint, rebuild=False, requested=None):
    require(endpoint.startswith('unix:///'), 'Only the verified local Docker socket is permitted')
    require(len(run_id) == 32 and all(c in '0123456789abcdef' for c in run_id), 'Invalid fixture run ID')
    require(len(source_sha) == 40 and all(c in '0123456789abcdef' for c in source_sha), 'Invalid source SHA')
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    require(not output.exists(), 'Preserve existing fixture provenance; use a fresh output')
    fixed, docker = policy_for_ref(requested) if requested else policy(), ['docker', '--host=' + endpoint]
    monitor = DiskMonitor(output.parent).start()
    value = {key: fixed[key] for key in ('representation', 'requestedRef', 'sourceRef',
             'sourceManifestDigest', 'sourceConfigDigest', 'sourceRootfsInventorySha256',
             'rootfsArchiveSha256', 'runtimeConfigSha256', 'derivedImageId', 'os', 'architecture')}
    value.update(schemaVersion=1, runId=run_id, sourceSha=source_sha,
                 startedAt=dt.datetime.now(dt.timezone.utc).isoformat())
    try:
        existing = inspect_image(docker, fixed['derivedImageId'])
        if existing is not None:
            validate_image(existing, fixed)
        value['cacheHit'] = existing is not None and not rebuild
        if not value['cacheHit']:
            tag = inspect_image(docker, fixed['cacheTag'])
            require(tag is None or tag['Id'] == fixed['derivedImageId'], 'Another image owns the fixture cache tag')
            with tempfile.TemporaryDirectory(prefix='fixture-projection-', dir=output.parent) as temporary:
                area = Path(temporary)
                tool = crane_binary(area, fixed)
                raw = registry_read([str(tool), 'config', fixed['sourceRef']], timeout=60)
                config = projected_config(raw, fixed)
                rootfs = area / 'source-rootfs.tar'
                registry_read([str(tool), 'export', fixed['sourceRef'], str(rootfs)])
                require(rootfs.stat().st_size == fixed['rootfsArchiveBytes'] and
                        file_digest(rootfs) == fixed['rootfsArchiveSha256'], 'Exported rootfs tar differs')
                value['loadOutput'] = load_projection(docker, rootfs, config, fixed).strip()
        image = inspect_image(docker, fixed['derivedImageId'])
        require(image is not None, 'Projected image is missing after preparation')
        validate_image(image, fixed)
        value['rootfsLayers'] = image['RootFS']['Layers']
        value['imageLogicalBytes'] = image['Size']
        value['verificationMethod'] = 'Pinned immutable image/rootfs/config digests; cached images are not prior test receipts'
        verify_proof(value, run_id, source_sha, fixed)
        value['finishedAt'] = dt.datetime.now(dt.timezone.utc).isoformat()
        value['disk'] = monitor.stop()
        output.write_text(json.dumps(value, indent=2) + '\n')
        print(json.dumps({'derivedImageId': image['Id'], 'sourceManifestDigest': fixed['sourceManifestDigest'],
                          'cacheHit': value['cacheHit'], 'runtimeConfigEqual': True, 'rootfsLayers': 1}))
        return value
    except Exception:
        monitor.stop()
        # A failed load is never blindly retried; any resulting immutable image
        # remains inspectable by ID on the next independently requested run.
        raise


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', required=True)
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--source-sha', required=True)
    parser.add_argument('--docker-endpoint', required=True)
    parser.add_argument('--rebuild-proof', action='store_true')
    parser.add_argument('--requested-ref')
    args = parser.parse_args()
    prepare(args.output, args.run_id, args.source_sha, args.docker_endpoint, args.rebuild_proof, args.requested_ref)
