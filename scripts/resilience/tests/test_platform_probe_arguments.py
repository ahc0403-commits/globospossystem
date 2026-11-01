import contextlib
import importlib.util
import io
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

import test_owned_platform

spec=importlib.util.spec_from_file_location('platform_probe_arguments',Path(__file__).parents[1]/'run_platform_probe.py')
probe=importlib.util.module_from_spec(spec)
with patch.dict(sys.modules,{'owned_platform':test_owned_platform.platform}):spec.loader.exec_module(probe)


class ProbeArgumentGuards(unittest.TestCase):
    def reject(self,flags):
        base=['probe','--snapshot-dir','/missing-source','--office-root','/missing-office','--output','/missing-output']
        with patch.object(sys,'argv',base+flags),patch.object(probe,'OwnedPlatform') as owned,contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as error:probe.main()
            self.assertEqual(error.exception.code,2);owned.assert_not_called()

    def test_cross_project_flow_cannot_be_narrowed_to_one_project(self):
        self.reject(['--projects','pos','--exercise-legal-connection'])

    def test_pos_storage_probe_cannot_be_reported_as_office_storage(self):
        self.reject(['--projects','office','--exercise-storage','--storage-reference','/missing-reference'])

    def test_missing_storage_reference_fails_before_restoring_any_database(self):
        self.reject(['--projects','pos','--exercise-storage'])

    def test_workforce_cannot_skip_cross_project_dependency_or_private_storage_reference(self):
        self.reject(['--projects','pos','--exercise-workforce'])
        self.reject(['--exercise-workforce','--deno','/missing-deno','--deno-cache','/missing-cache'])


    def test_realtime_missing_reference_or_dart_fails_before_any_database(self):
        self.reject(['--exercise-realtime'])
        self.reject(['--exercise-realtime-websocket','--realtime-reference-dir','/missing-reference'])


if __name__=='__main__':unittest.main()
