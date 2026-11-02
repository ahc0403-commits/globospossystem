"""Guard the reproduced VFS SDK duplication and missing bootstrap dependency."""
from pathlib import Path
import unittest


class ToolsImageLayout(unittest.TestCase):
    def test_filesystem_workdir_creation_precedes_the_single_sdk_layer(self):
        text=(Path(__file__).parents[1]/'Dockerfile').read_text()
        self.assertEqual(text.count('\nRUN '),1)
        self.assertEqual(text.count('\nWORKDIR '),1)
        self.assertLess(text.index('\nWORKDIR /work'),text.index('\nRUN '))
        self.assertIn('chown -R ubuntu:ubuntu /opt/flutter /home/ubuntu /work',text)
        self.assertTrue(text.rstrip().endswith('USER ubuntu'))

    def test_sdk_dependency_config_is_bootstrapped_before_isolated_checks(self):
        text=(Path(__file__).parents[1]/'Dockerfile').read_text()
        self.assertIn('pub get --directory /opt/flutter/packages/flutter_tools',text)
        self.assertIn('--root-certs-file="$SSL_CERT_FILE"',text)
        self.assertIn('libsqlite3-dev',text)


if __name__=='__main__':unittest.main()
