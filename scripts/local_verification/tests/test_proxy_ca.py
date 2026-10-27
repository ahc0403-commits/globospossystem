import base64
import hashlib
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('pos_release_gate', ROOT / 'scripts/pos_local_release_gate.py')
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


def pem(value):
    return '-----BEGIN CERTIFICATE-----\n' + base64.b64encode(value).decode() + '\n-----END CERTIFICATE-----\n'


class ProxyCATest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.ca = self.base / 'proxy.pem'
        self.bundle = self.base / 'host.pem'
        self.ca.write_text(pem(b'platform-ca'))
        self.bundle.write_text(pem(b'public-root') + pem(b'platform-ca'))

    def tearDown(self):
        self.temp.cleanup()

    def test_no_proxy_leaves_existing_execution_unchanged(self):
        self.assertIsNone(gate.proxy_trust(None, self.bundle))

    def test_only_existing_host_trust_is_accepted(self):
        info = gate.proxy_trust(self.ca, self.bundle)
        self.assertEqual(info['proxyCaSha256'], hashlib.sha256(b'platform-ca').hexdigest())
        self.assertEqual(info['hostBundleSha256'], hashlib.sha256(self.bundle.read_bytes()).hexdigest())
        self.assertEqual(info['bundle'], str(self.bundle.resolve()))
        self.assertEqual(info['certificate'], str(self.ca.resolve()))

    def test_untrusted_or_missing_ca_fails_closed(self):
        self.bundle.write_text(pem(b'other-ca'))
        with self.assertRaises(gate.InvalidEvidence):
            gate.proxy_trust(self.ca, self.bundle)
        self.ca.unlink()
        with self.assertRaises(gate.InvalidEvidence):
            gate.proxy_trust(self.ca, self.bundle)

    def test_private_key_and_multiple_certificates_are_rejected(self):
        private_key_marker = '-----BEGIN ' + 'PRIVATE KEY-----\nx\n-----END PRIVATE KEY-----\n'
        self.ca.write_text(pem(b'platform-ca') + private_key_marker)
        with self.assertRaises(gate.InvalidEvidence):
            gate.proxy_trust(self.ca, self.bundle)
        self.ca.write_text(pem(b'platform-ca') + pem(b'public-root'))
        with self.assertRaises(gate.InvalidEvidence):
            gate.proxy_trust(self.ca, self.bundle)

    def test_host_bundle_with_private_key_is_rejected(self):
        private_key_marker = '-----BEGIN ' + 'PRIVATE KEY-----\nx\n-----END PRIVATE KEY-----\n'
        self.bundle.write_text(pem(b'platform-ca') + private_key_marker)
        with self.assertRaises(gate.InvalidEvidence):
            gate.proxy_trust(self.ca, self.bundle)


if __name__ == '__main__':
    unittest.main()
