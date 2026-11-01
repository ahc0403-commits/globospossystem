import hashlib
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

spec=importlib.util.spec_from_file_location('owned_platform',Path(__file__).parents[1]/'owned_platform.py')
platform=importlib.util.module_from_spec(spec);spec.loader.exec_module(platform)


class OwnedPlatformGuards(unittest.TestCase):
    def setUp(self):
        self.area=Path(tempfile.mkdtemp(prefix='owned-platform-contract-'))
        self.addCleanup(lambda:__import__('shutil').rmtree(self.area))

    def instance(self):
        value=platform.OwnedPlatform.__new__(platform.OwnedPlatform)
        value.output=self.area;value.started=time.monotonic();value.run_id='a'*32
        value.projects={};value.gateways={};value.threads=[];value.processes=[]
        value.env={};value.result={'status':'PASS'}
        value.runner=Mock();value.runner.cleanup_owned.return_value=True
        return value

    def test_relative_or_git_output_fails_before_any_process(self):
        repo=self.area/'repo';repo.mkdir();(repo/'.git').mkdir()
        for output in [Path('relative'),repo/'private-output']:
            with self.subTest(output=str(output)),patch.object(platform.subprocess,'run') as child:
                with self.assertRaisesRegex(ValueError,'outside every Git'):
                    platform.OwnedPlatform(self.area,self.area,output)
                child.assert_not_called()

    def test_symlink_output_cannot_redirect_secrets(self):
        link=self.area/'link';link.symlink_to(self.area,target_is_directory=True)
        with patch.object(platform.subprocess,'run') as child:
            with self.assertRaisesRegex(ValueError,'outside every Git'):
                platform.OwnedPlatform(self.area,self.area,link)
            child.assert_not_called()

    def test_one_owned_process_failure_cannot_skip_other_process_or_docker_cleanup(self):
        value=self.instance();bad=Mock();good=Mock()
        bad.poll.return_value=None;bad.terminate.side_effect=OSError('Synthetic process failure')
        good.poll.return_value=None
        value.processes=[bad,good]
        value.close()
        good.terminate.assert_called_once()
        value.runner.cleanup_owned.assert_called_once_with(value.run_id,value.env)
        self.assertFalse(value.result['cleanupVerified']);self.assertEqual(value.result['status'],'FAIL')

    def test_diagnostic_failure_still_cleans_docker_and_cannot_be_pass(self):
        value=self.instance();value.projects={'pos':{'auth':'owned-auth','rest':'owned-rest','db':'owned-db'}}
        value.command=Mock(side_effect=subprocess.TimeoutExpired('synthetic diagnostic',1))
        value.close()
        value.runner.cleanup_owned.assert_called_once()
        self.assertEqual(value.result['status'],'FAIL');self.assertFalse(value.result['cleanupVerified'])

    def test_changed_input_cannot_support_a_pass(self):
        value=self.instance();source=self.area/'tool.py';source.write_text('original')
        value.input_paths=[source];value.result['toolHashes']={source.name:hashlib.sha256(source.read_bytes()).hexdigest()}
        source.write_text('changed')
        with self.assertRaisesRegex(RuntimeError,'runtime-tool-inputs-unchanged'):value.validate_inputs()

    def test_lingering_gateway_thread_is_not_successful_cleanup(self):
        value=self.instance();thread=Mock();thread.is_alive.return_value=True
        value.threads=[thread]
        value.close()
        value.runner.cleanup_owned.assert_called_once()
        self.assertFalse(value.result['cleanupVerified'])
        self.assertIn('GatewayThreadNotStopped',value.result['cleanupFailures'])


if __name__=='__main__':unittest.main()
