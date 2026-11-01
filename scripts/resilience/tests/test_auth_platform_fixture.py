import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import test_schema_snapshot as schema_tests

spec=importlib.util.spec_from_file_location('auth_platform_fixture',Path(__file__).parents[1]/'auth_platform_fixture.py')
fixture=importlib.util.module_from_spec(spec);spec.loader.exec_module(fixture)


class AuthPlatformPreflightGuards(unittest.TestCase):
    def setUp(self):
        self.input=schema_tests.SchemaSnapshotTests();self.input.setUp();self.addCleanup(self.input.doCleanups)
        self.area=self.input.area
        self.input.write('pos-inventory-guards.json',{'schemaInventory':sorted(schema_tests.m.SCOPES['pos']),
          **{k:0 for k in ['unsupportedRelations','unsupportedTypes','nonViewRules',
            'customAggregates','customCollations','schemaPublications','otherLanguages','ordinaryInheritance']}})
        self.input.write('pos-bootstrap.json',{'extensions':[]})
        source=self.area/'pos-current-application-schema.sql'
        source.write_text('CREATE SCHEMA public;\nCREATE TABLE public.synthetic(id integer);\n');source.chmod(0o600)

    def test_relative_output_is_rejected_before_docker(self):
        with patch.object(fixture.subprocess,'run') as child:
            with self.assertRaisesRegex(ValueError,'outside every Git'):
                fixture.run('pos',self.area,Path('relative-auth-output'))
            child.assert_not_called()

    def test_output_inside_a_git_worktree_cannot_receive_credentials(self):
        repo=self.area/'repository';repo.mkdir();(repo/'.git').mkdir()
        output=repo/'auth-output'
        with patch.object(fixture.subprocess,'run') as child:
            with self.assertRaisesRegex(ValueError,'outside every Git'):
                fixture.run('pos',self.area,output)
            child.assert_not_called()
        self.assertFalse(output.exists())

    def test_existing_evidence_is_never_overwritten(self):
        output=self.area/'existing';output.mkdir(mode=0o700)
        marker=output/'receipt.json';marker.write_text('original evidence')
        with patch.object(fixture.subprocess,'run') as child:
            with self.assertRaises(FileExistsError):fixture.run('pos',self.area,output)
            child.assert_not_called()
        self.assertEqual(marker.read_text(),'original evidence')

    def test_symlink_output_cannot_redirect_fixture_secrets(self):
        destination=self.area/'destination';destination.mkdir(mode=0o700)
        output=self.area/'linked';output.symlink_to(destination,target_is_directory=True)
        with patch.object(fixture.subprocess,'run') as child:
            with self.assertRaisesRegex(ValueError,'outside every Git'):
                fixture.run('pos',self.area,output)
            child.assert_not_called()
        self.assertEqual(list(destination.iterdir()),[])

    def test_project_mismatch_is_rejected_without_starting_a_service(self):
        self.input.write('office-manifest.json',self.input.manifest)
        output=self.area/'new-output'
        with patch.object(fixture.subprocess,'run') as child:
            with self.assertRaisesRegex(ValueError,'project/scope'):
                fixture.run('office',self.area,output)
            child.assert_not_called()
        self.assertFalse(output.exists())


if __name__=='__main__':unittest.main()
