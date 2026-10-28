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


if __name__ == '__main__':
    unittest.main()
