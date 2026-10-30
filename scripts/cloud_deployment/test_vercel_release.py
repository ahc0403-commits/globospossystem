import base64
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import bridge
import vercel_release as release

spec = importlib.util.spec_from_file_location('web_build', Path(__file__).parents[1] / 'write_pos_web_build_manifest.py')
web_build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(web_build)


class VercelReleaseTests(unittest.TestCase):
    sha = 'a' * 40

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
        # Some mapped read tools omit gitSource. The actual provider source
        # must still be Git; build attestation independently checks actual SHA.
        value.pop('gitSource')
        with self.assertRaises(bridge.CloudError): release.verify_deployment(value, self.sha)
        release.verify_deployment({**value, 'source': 'git'}, self.sha)

    def test_configuration_and_toolchain_are_required_actual_build_evidence(self):
        value = {'schemaVersion': 1, 'sourceSha': self.sha, 'publicConfigStatus': 'PASS',
                 'flutterVersion': '3.41.6', 'dartVersion': '3.11.4', 'lockfileSha256': 'fixture'}
        release.verify_build(value, self.sha, 'fixture')
        for key in value:
            bad = dict(value); bad[key] = 'wrong'
            with self.subTest(key=key), self.assertRaises(bridge.CloudError):
                release.verify_build(bad, self.sha, 'fixture')

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


if __name__ == '__main__': unittest.main()
