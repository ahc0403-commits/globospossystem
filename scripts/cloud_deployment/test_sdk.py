import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import sdk


class SDKTests(unittest.TestCase):
    def setUp(self):
        self.area = tempfile.TemporaryDirectory()
        self.addCleanup(self.area.cleanup)
        self.directory = Path(self.area.name)
        self.manifest = {'sourceSha': 'a' * 40, 'runId': 'b' * 32, 'phase': 'web-only'}
        self.data = {**self.manifest, 'container': 'fixture', 'id': 'container-id', 'image': 'image-id'}
        (self.directory / 'sdk.json').write_text(json.dumps(self.data))
        self.identity = {'Id': 'container-id', 'Image': 'image-id', 'Config': {
            'Labels': {'pos.local.verification': self.manifest['runId']}}}
        self.session = patch.object(sdk, 'session', return_value=(self.directory, self.manifest))
        self.session.start(); self.addCleanup(self.session.stop)

    def test_compiler_receives_public_configuration_without_host_credentials(self):
        with patch.object(sdk, 'checked', return_value=json.dumps([self.identity])), \
             patch.object(sdk.subprocess, 'run') as run, \
             patch.dict(os.environ, {'SUPABASE_URL': 'https://example.invalid',
                                      'SUPABASE_ACCESS_TOKEN': 'fixture-private',
                                      'FIXED_SMOKE_PASSWORD': 'fixture-password'}, clear=True):
            run.return_value.returncode = 0
            self.assertEqual(sdk.tool(self.directory, 'flutter', ['build', 'web']), 0)
            args = run.call_args.args[0]
            self.assertIn('SUPABASE_URL', args)
            self.assertNotIn('SUPABASE_ACCESS_TOKEN', args)
            self.assertNotIn('FIXED_SMOKE_PASSWORD', args)
            self.assertNotIn('fixture-private', ' '.join(args))

    def test_container_identity_image_and_ownership_are_required_before_execution(self):
        for key in ('Id', 'Image', 'Config'):
            wrong = {**self.identity, key: {} if key == 'Config' else 'another'}
            with self.subTest(key=key), \
                 patch.object(sdk, 'checked', return_value=json.dumps([wrong])), \
                 patch.object(sdk.subprocess, 'run') as run, \
                 self.assertRaises(sdk.CloudError):
                sdk.tool(self.directory, 'dart', ['analyze'])
            run.assert_not_called()

    def test_checks_keep_db_only_scope_and_do_not_reenter_mcp_transport(self):
        self.manifest['phase'] = 'db-only'
        with patch.object(sdk, 'checked', return_value=json.dumps([self.identity])), \
             patch.object(sdk.subprocess, 'run') as run:
            sdk.tool(self.directory, 'checks', [])
            command = run.call_args.args[0]
            self.assertIn('DB_ONLY=1', command[-1])
            self.assertNotIn('POS_SUPABASE_BACKEND=mcp', ' '.join(command))

    def test_initialization_requires_exact_main_evidence_before_docker(self):
        with patch.object(sdk.gate, 'verify', side_effect=sdk.gate.InvalidEvidence('bad receipt')) as verify, \
             patch.object(sdk, 'checked') as execute, self.assertRaises(sdk.gate.InvalidEvidence):
            sdk.initialize(self.directory, '/untrusted/receipt')
        verify.assert_called_once_with(Path('/untrusted/receipt'), sdk.ROOT, kind='exact-main')
        execute.assert_not_called()


    def initialization_command(self, fixture_environment, trust=None):
        receipt = {'environment': {'image': {'Id': 'verified-sdk-image'}, **fixture_environment}}
        with patch.object(sdk.gate, 'verify', return_value=receipt) as verify, \
             patch.object(sdk.gate, 'proxy_environment', return_value=[]), \
             patch.object(sdk.gate, 'proxy_host_arguments', return_value=[]), \
             patch.object(sdk.gate, 'proxy_trust', return_value=trust), \
             patch.object(sdk, 'checked', return_value='owned-sdk-container') as execute, \
             patch.object(sdk, 'write_new'), patch.object(sdk.subprocess, 'run') as ready:
            ready.return_value.returncode = 0
            sdk.initialize(self.directory, self.directory / 'exact-main-evidence')
            verify.assert_called_once_with(self.directory / 'exact-main-evidence',
                                           sdk.ROOT, kind='exact-main')
            execute.assert_called_once()
            return execute.call_args.args[0]

    def test_post_gate_sdk_uses_all_verified_fixture_mappings_in_both_phases(self):
        refs = ['public.ecr.aws/supabase/postgres:17.6.1.104',
                'postgres:15', 'postgres:17.6', 'postgres:17-alpine']
        projections = [{'requestedRef': ref, 'derivedImageId': 'verified-image-' + str(i)}
                       for i, ref in enumerate(refs)]
        environment = {'fixtureProjection': projections[0],
                       'additionalFixtureProjections': projections[1:]}
        for phase in ['db-only', 'web-only']:
            with self.subTest(phase=phase), patch.dict(os.environ, {
                    'POS_FIXTURE_IMAGE_MAP': '{"postgres:15":"unreviewed-host-image"}'}):
                self.manifest['phase'] = phase
                command = self.initialization_command(environment)
                values = [command[i + 1] for i, arg in enumerate(command[:-1]) if arg == '--env']
                mappings = [x for x in values if x.startswith('POS_FIXTURE_IMAGE_MAP=')]
                self.assertEqual(len(mappings), 1)
                self.assertEqual(json.loads(mappings[0].split('=', 1)[1]),
                                 {p['requestedRef']: p['derivedImageId'] for p in projections})
                self.assertNotIn('unreviewed-host-image', ' '.join(command))

    def test_sdk_does_not_forward_unverified_host_fixture_overrides(self):
        with patch.dict(os.environ, {
                'POS_FIXTURE_IMAGE_MAP': '{"postgres:15":"unreviewed-host-image"}',
                'POS_POSTGRES_FIXTURE_IMAGE': 'unreviewed-legacy-image'}):
            command = self.initialization_command({})
        self.assertFalse(any(x.startswith(('POS_FIXTURE_IMAGE_MAP=',
                                           'POS_POSTGRES_FIXTURE_IMAGE=')) for x in command))

    def test_sdk_preserves_canonical_proxy_bundle_for_dart_node_and_deno(self):
        command = self.initialization_command({}, {'bundle': '/host/ca.pem', 'certificate': '/host/proxy.crt'})
        for variable in ('SSL_CERT_FILE', 'CURL_CA_BUNDLE', 'GIT_SSL_CAINFO',
                         'REQUESTS_CA_BUNDLE', 'NODE_EXTRA_CA_CERTS'):
            self.assertIn(variable + '=/run/pos-host-ca.pem', command)
        self.assertIn('DENO_TLS_CA_STORE=system', command)
        self.assertIn('type=bind,src=/host/ca.pem,dst=/run/pos-host-ca.pem,readonly', command)
        self.assertNotIn('DANGER_ACCEPT_INVALID_CERTS', ' '.join(command))


if __name__ == '__main__':
    unittest.main()
