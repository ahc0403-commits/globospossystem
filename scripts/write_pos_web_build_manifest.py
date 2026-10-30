#!/usr/bin/env python3
"""Check public frontend configuration where it is built; never emit values."""
import argparse
import base64
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PUBLIC_NAMES = ('SUPABASE_URL', 'SUPABASE_ANON_KEY', 'FIREBASE_API_KEY',
                'FIREBASE_APP_ID', 'FIREBASE_MESSAGING_SENDER_ID',
                'FIREBASE_PROJECT_ID', 'FIREBASE_WEB_VAPID_KEY')


def check_public_config(env):
    for name in PUBLIC_NAMES:
        if not env.get(name, '').strip():
            raise ValueError('Missing public frontend configuration: ' + name)
    if env['SUPABASE_URL'].rstrip('/') != 'https://ynriuoomotxuwhuxxmhj.supabase.co':
        raise ValueError('Public Supabase project differs from POS production')
    key = env['SUPABASE_ANON_KEY']
    if not key.startswith('sb_publishable_'):
        try:
            payload = key.split('.')[1]
            claims = json.loads(base64.urlsafe_b64decode(payload + '=' * (-len(payload) % 4)))
            if claims.get('role') != 'anon' or claims.get('ref') != 'ynriuoomotxuwhuxxmhj':
                raise ValueError()
        except (IndexError, ValueError, TypeError):
            raise ValueError('Frontend Supabase key must be a public key for POS production') from None
    app = env['FIREBASE_APP_ID'].split(':')
    if len(app) != 4 or app[0] != '1' or app[2] != 'web' or app[1] != env['FIREBASE_MESSAGING_SENDER_ID']:
        raise ValueError('Firebase public app/sender identity mismatch')
    if not re.fullmatch(r'[a-z0-9][a-z0-9-]+', env['FIREBASE_PROJECT_ID']):
        raise ValueError('Invalid Firebase public project identity')
    try:
        value = env['FIREBASE_WEB_VAPID_KEY']
        point = base64.urlsafe_b64decode(value + '=' * (-len(value) % 4))
        if len(point) != 65 or point[0] != 4:
            raise ValueError()
    except (ValueError, TypeError):
        raise ValueError('Invalid public Web Push VAPID key') from None


def source_sha(env):
    provider = env.get('VERCEL_GIT_COMMIT_SHA')
    local = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=ROOT,
                           text=True, capture_output=True)
    actual = local.stdout.strip() if local.returncode == 0 else None
    if provider and actual and provider != actual:
        raise ValueError('Provider and checkout Git identities differ')
    sha = provider or actual or ''
    if not re.fullmatch(r'[0-9a-f]{40}', sha):
        raise ValueError('Missing exact Git build identity')
    return sha


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['check', 'write'])
    parser.add_argument('--flutter-bin', required=True)
    args = parser.parse_args()
    check_public_config(os.environ)
    sha = source_sha(os.environ)
    version = json.loads(subprocess.check_output([args.flutter_bin, '--version', '--machine'], text=True, cwd=ROOT))
    if version.get('frameworkVersion') != '3.41.6' or version.get('dartSdkVersion') != '3.11.4':
        raise ValueError('Build Flutter/Dart differs from verified pinned toolchain')
    if args.action == 'check':
        print('POS_PUBLIC_CONFIG_CHECK=PASS (names, project, public-key role, Firebase app/sender, VAPID; values not emitted)')
        return
    build = ROOT / 'build/web'
    manifest = {'schemaVersion': 1, 'sourceSha': sha, 'publicConfigStatus': 'PASS',
                'flutterVersion': version['frameworkVersion'], 'dartVersion': version['dartSdkVersion'],
                'lockfileSha256': hashlib.sha256((ROOT / 'pubspec.lock').read_bytes()).hexdigest(),
                'mainDartJsSha256': hashlib.sha256((build / 'main.dart.js').read_bytes()).hexdigest(),
                'generatedAt': dt.datetime.now(dt.timezone.utc).isoformat()}
    (build / 'pos-release.json').write_text(json.dumps(manifest, sort_keys=True) + '\n')
    print('POS_EXACT_SOURCE_WEB_BUILD=' + sha)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit('POS_WEB_BUILD_BLOCKED: ' + str(error))
