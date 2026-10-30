import base64
import copy
from contextlib import redirect_stdout
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
import urllib.error
from unittest.mock import MagicMock, patch

import bridge
import vercel_release as release

spec = importlib.util.spec_from_file_location('web_build', Path(__file__).parents[1] / 'write_pos_web_build_manifest.py')
web_build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(web_build)


class VercelReleaseTests(unittest.TestCase):
    sha = 'a' * 40

    def test_complete_release_inspects_hostnames_and_verifies_actual_live_build(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory / 'pubspec.lock').write_bytes(b'fixture-lock')
            manifest = {'phase': 'web-only', 'sourceSha': self.sha}
            deployment = {'id': 'dpl_fixture', 'readyState': 'READY', 'target': 'production',
                          'projectId': release.PROJECT, 'gitSource': {'sha': self.sha},
                          'meta': {'githubCommitSha': self.sha}, 'url': 'fixture.vercel.app'}
            build = {'schemaVersion': 1, 'sourceSha': self.sha, 'publicConfigStatus': 'PASS',
                     'flutterVersion': '3.41.6', 'dartVersion': '3.11.4',
                     'lockfileSha256': hashlib.sha256(b'fixture-lock').hexdigest(),
                     'mainDartJsSha256': hashlib.sha256(b'compiled-fixture').hexdigest()}
            responses = [io.BytesIO(json.dumps(build).encode()), io.BytesIO(b'compiled-fixture')]
            for response in responses: response.status = 200
            output = io.StringIO()
            with patch.object(release, 'ROOT', directory), \
                 patch.object(release, 'session', return_value=(directory, manifest)), \
                 patch.object(release, 'request', side_effect=[deployment, {'id': 'dpl_fixture'}, deployment, deployment]) as remote, \
                 patch.object(release.urllib.request, 'urlopen', side_effect=responses), \
                 redirect_stdout(output):
                release.deploy(directory)
            calls = remote.call_args_list
            self.assertEqual([c.args[1] for c in calls],
                             ['vercel-inspect', 'vercel-deploy', 'vercel-inspect', 'vercel-inspect'])
            self.assertEqual(calls[0].args[2]['idOrUrl'], release.HOST)
            self.assertEqual(calls[2].args[2]['idOrUrl'], 'dpl_fixture')
            self.assertEqual(calls[3].args[2]['idOrUrl'], release.HOST)
            receipt = json.loads((directory / 'vercel-receipt.json').read_text())
            self.assertEqual(receipt['productionBuild'], build)
            self.assertTrue(receipt['productionAliasVerified'])
            self.assertEqual(json.loads(output.getvalue()), receipt)

    def test_deployment_never_changes_project_settings_env_or_source_revision(self):
        args = release.deployment_arguments(self.sha)
        body = args['requestBody']
        self.assertEqual(body['gitSource']['sha'], self.sha)
        self.assertEqual(body['gitSource']['ref'], self.sha)
        self.assertFalse(body['withLatestCommit'])
        self.assertNotIn('env', body)
        self.assertNotIn('projectSettings', body)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            (path / 'vercel-prepared.json').write_text(json.dumps({'sourceSha': self.sha, 'arguments': args}))
            manifest = {'phase': 'web-only', 'sourceSha': self.sha}
            release.authorize_mutation(path, manifest, args)
            for field in ['project', 'target']:
                bad = copy.deepcopy(args); bad['requestBody'][field] = 'foreign'
                with self.assertRaises(bridge.CloudError):
                    release.authorize_mutation(path, manifest, bad)
            for phase in ['db-only', 'coordinated', 'diagnostic', 'fixture']:
                with self.assertRaises(bridge.CloudError):
                    release.authorize_mutation(path, {**manifest, 'phase': phase}, args)
            (path / 'vercel-created.json').write_text('{}')
            with self.assertRaises(bridge.CloudError):
                release.authorize_mutation(path, manifest, args)

    def test_metadata_requires_provider_git_identity_ready_and_matching_alias(self):
        value = {'id': 'dpl_fixture', 'readyState': 'READY', 'target': 'production',
                 'projectId': release.PROJECT, 'gitSource': {'sha': self.sha},
                 'meta': {'githubCommitSha': self.sha}}
        release.verify_deployment(value, self.sha, 'dpl_fixture')
        for change in [{'readyState': 'BUILDING'}, {'target': 'preview'},
                       {'projectId': 'foreign'}, {'gitSource': {'sha': 'b' * 40}},
                       {'meta': {'githubCommitSha': 'b' * 40}}, {'id': 'dpl_other'}]:
            with self.subTest(change=change), self.assertRaises(bridge.CloudError):
                release.verify_deployment({**value, **change}, self.sha, 'dpl_fixture')
        # Both optional mapped fields may be absent. Complete releases still
        # require actual build identity and compiled bytes, not metadata alone.
        value.pop('gitSource')
        release.verify_deployment(value, self.sha)
        release.verify_deployment({**value, 'source': 'git'}, self.sha)
        release.verify_deployment({**value, 'source': 'api'}, self.sha)
        release.verify_deployment({**value, 'source': 'cli'}, self.sha)

    def test_configuration_and_toolchain_are_required_actual_build_evidence(self):
        value = {'schemaVersion': 1, 'sourceSha': self.sha, 'publicConfigStatus': 'PASS',
                 'flutterVersion': '3.41.6', 'dartVersion': '3.11.4', 'lockfileSha256': 'fixture'}
        release.verify_build(value, self.sha, 'fixture')
        for key in value:
            bad = dict(value); bad[key] = 'wrong'
            with self.subTest(key=key), self.assertRaises(bridge.CloudError):
                release.verify_build(bad, self.sha, 'fixture')

    def test_missing_optional_fields_never_substitute_for_actual_build_and_compiled_bytes(self):
        for failure in [None, 'source', 'bytes']:
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as tmp:
                directory = Path(tmp); (directory / 'pubspec.lock').write_bytes(b'lock')
                manifest = {'phase': 'web-only', 'sourceSha': self.sha}
                deployment = {'id': 'dpl_fixture', 'readyState': 'READY', 'target': 'production',
                              'projectId': release.PROJECT, 'meta': {'githubCommitSha': self.sha},
                              'url': 'fixture.vercel.app'}
                build = {'schemaVersion': 1, 'sourceSha': 'b' * 40 if failure == 'source' else self.sha,
                         'publicConfigStatus': 'PASS', 'flutterVersion': '3.41.6', 'dartVersion': '3.11.4',
                         'lockfileSha256': hashlib.sha256(b'lock').hexdigest(),
                         'mainDartJsSha256': hashlib.sha256(b'compiled').hexdigest()}
                replies = [io.BytesIO(json.dumps(build).encode()),
                           io.BytesIO(b'tampered' if failure == 'bytes' else b'compiled')]
                for reply in replies: reply.status = 200
                with patch.object(release, 'ROOT', directory), \
                     patch.object(release, 'session', return_value=(directory, manifest)), \
                     patch.object(release, 'request', side_effect=[deployment, deployment, deployment, deployment]) as remote, \
                     patch.object(release.urllib.request, 'urlopen', side_effect=replies), redirect_stdout(io.StringIO()):
                    if failure:
                        with self.assertRaises(bridge.CloudError): release.deploy(directory)
                        self.assertFalse((directory / 'vercel-receipt.json').exists())
                    else:
                        release.deploy(directory)
                        receipt = json.loads((directory / 'vercel-receipt.json').read_text())
                        self.assertEqual(receipt['providerGitShaStatus'], 'NOT_RETURNED')
                        self.assertFalse(receipt['providerInitiatorReturned'])
                self.assertEqual(sum(c.args[1] == 'vercel-deploy' for c in remote.call_args_list), 1)

    def test_vercel_api_denials_are_not_normalized_as_success(self):
        with self.assertRaises(bridge.CloudError):
            bridge.normalize_result({'structuredContent': {'error': {'status': 403}}}, 'vercel-deploy')

    def test_public_build_configuration_rejects_missing_fields_wrong_store_and_private_keys(self):
        payload = base64.urlsafe_b64encode(json.dumps({'role': 'anon', 'ref': bridge.PROJECT}).encode()).decode().rstrip('=')
        env = {'SUPABASE_URL': 'https://' + bridge.PROJECT + '.supabase.co',
               'SUPABASE_ANON_KEY': 'header.' + payload + '.signature',
               'FIREBASE_API_KEY': 'public-fixture', 'FIREBASE_APP_ID': '1:123:web:fixture',
               'FIREBASE_MESSAGING_SENDER_ID': '123', 'FIREBASE_PROJECT_ID': 'fixture-project',
               'FIREBASE_WEB_VAPID_KEY': base64.urlsafe_b64encode(bytes([4]) + bytes(64)).decode().rstrip('=')}
        web_build.check_public_config(env)
        for key in web_build.PUBLIC_NAMES:
            with self.subTest(key=key), self.assertRaises(ValueError):
                web_build.check_public_config({**env, key: ''})
        for change in [{'SUPABASE_URL': 'https://other.supabase.co'},
                       {'SUPABASE_ANON_KEY': 'sb_secret_fixture'},
                       {'FIREBASE_MESSAGING_SENDER_ID': '999'}, {'FIREBASE_WEB_VAPID_KEY': 'not-a-point'}]:
            with self.assertRaises(ValueError): web_build.check_public_config({**env, **change})

    def test_actual_public_client_probe_rejects_disabled_keys_without_emitting_them(self):
        env = {'SUPABASE_URL': 'https://' + bridge.PROJECT + '.supabase.co',
               'SUPABASE_ANON_KEY': 'public-fixture'}
        response = MagicMock()
        response.__enter__.return_value = response
        response.status = 200
        response.read.return_value = b'{"external": {}}'
        with patch.object(web_build.urllib.request, 'urlopen', return_value=response) as fetch:
            web_build.verify_public_client(env)
            request = fetch.call_args.args[0]
            self.assertEqual(request.full_url, env['SUPABASE_URL'] + '/auth/v1/settings')
            self.assertEqual(request.get_header('Apikey'), 'public-fixture')
        denied = urllib.error.HTTPError('https://fixture', 401, 'disabled', {}, None)
        with patch.object(web_build.urllib.request, 'urlopen', side_effect=denied):
            with self.assertRaisesRegex(ValueError, '^Production public client authentication probe failed$'):
                web_build.verify_public_client(env)


if __name__ == '__main__': unittest.main()
