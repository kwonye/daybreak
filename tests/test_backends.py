import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from daybreak.backends import Sparkle, Google, Brew, MAS, Docker, CommandAdapter, Registry
from daybreak.models import App
from daybreak.platform import CommandError, executable_is_stale

APP = App('com.example.App', 'App', '/Applications/App.app', '1', '1', (100,))
class Runner:
    def __init__(self, code=0, output=''):
        self.code, self.output, self.calls = code, output, []
    def run(self, argv, timeout=120):
        self.calls.append(argv)
        return subprocess.CompletedProcess(argv,self.code,self.output,'')
    def checked(self, argv, timeout=120):
        result = self.run(argv,timeout)
        if result.returncode: raise CommandError('failed')
        return result.stdout

class BackendTests(unittest.TestCase):
    def test_runner_timeout_is_uncertain(self):
        from daybreak.platform import Runner as ActualRunner, CommandTimeout
        with patch('daybreak.platform.subprocess.run', side_effect=subprocess.TimeoutExpired('/updater', 1)):
            with self.assertRaises(CommandTimeout): ActualRunner().run(['/updater'], 1)
    def test_empty_inventory_fails_closed(self):
        from daybreak.platform import Mac
        with self.assertRaises(CommandError): Mac('/bridge', Runner(output='[]')).records()
    def test_docker_waits_for_engine_readiness(self):
        runner=Runner()
        with patch.object(runner, 'run', side_effect=[subprocess.CompletedProcess([],1,'',''), subprocess.CompletedProcess([],0,'29.0','')]) as call, patch('daybreak.backends.time.sleep'):
            Docker(runner,'/docker').health(APP)
            self.assertEqual(call.call_count,2)
    def test_sparkle_exit_semantics(self):
        for code, state in [(0,'available'),(4,'current')]:
            runner=Runner(code)
            self.assertEqual(Sparkle(runner,'/sparkle').check(APP).state,state)
            self.assertNotIn('--check-immediately',runner.calls[0])
        for code in [1,2,3,5,6,8]:
            with self.assertRaises(CommandError): Sparkle(Runner(code),'/sparkle').check(APP)
    def test_sparkle_install_flags(self):
        runner=Runner(); Sparkle(runner,'/sparkle').apply(APP)
        self.assertIn('--check-immediately',runner.calls[0])
        self.assertNotIn('--probe',runner.calls[0])
    def test_brew_scoped(self):
        runner=Runner(output=json.dumps({'casks':[{'name':'app'}]}))
        backend=Brew(runner,'/brew','app')
        self.assertEqual(backend.check(APP).state,'available');backend.apply(APP)
        self.assertEqual(runner.calls[-1],['/brew','upgrade','--cask','app'])
    def test_invalid_cask(self):
        for name in ['--all','app; echo hi','owner/tap/app']:
            with self.assertRaises(ValueError): Brew(Runner(),'/brew',name)
    def test_mas_exact_id(self):
        runner=Runner(output='1234 Other (1 -> 2)\n123 App (1 -> 3)\n')
        self.assertEqual(MAS(runner,'/mas','123').check(APP).state,'available')
        self.assertEqual(MAS(runner,'/mas','12').check(APP).state,'current')
    def test_custom_adapter_no_shell(self):
        runner=Runner(output='{"state":"available", "target_version":"2"}')
        adapter=CommandAdapter(runner, {'check':['/bin/check','{app_path}'], 'apply':['/bin/update','{bundle_id}']})
        self.assertEqual(adapter.check(APP).target,'2')
        self.assertEqual(runner.calls[0],['/bin/check','/Applications/App.app'])
    def test_custom_adapter_requires_target(self):
        adapter=CommandAdapter(Runner(output='{"state":"available"}'),{'check':['/check'],'apply':['/apply']})
        with self.assertRaises(CommandError): adapter.check(APP)
    def test_registry_inventory_never_executes(self):
        runner=Runner()
        with patch('daybreak.backends.shutil.which',return_value='/opt/homebrew/bin/brew'):
            Registry(runner,{})
        self.assertEqual(runner.calls,[])
    def test_google_preflight_missing_updater(self):
        with tempfile.TemporaryDirectory() as root:
            helper=Path(root)/'GoogleUpdater.app/Contents/Helpers/GoogleSoftwareUpdate.bundle/Contents/Helpers/ksadmin'
            helper.parent.mkdir(parents=True);helper.touch()
            runner=Runner(output='com.google.Chrome /Applications/Google Chrome.app')
            with self.assertRaises(CommandError): Google(runner,str(helper)).check(APP)
            self.assertEqual(runner.calls,[])
    def test_google_scope_and_registration(self):
        app=App('com.google.Chrome','Chrome','/Applications/Google Chrome.app','1','1',(2,))
        with tempfile.TemporaryDirectory() as root:
            helper=Path(root)/'GoogleUpdater.app/Contents/Helpers/GoogleSoftwareUpdate.bundle/Contents/Helpers/ksadmin'
            helper.parent.mkdir(parents=True);helper.touch()
            updater=helper.parents[4]/'MacOS/GoogleUpdater';updater.parent.mkdir();updater.touch()
            runner=Runner(output='productID=com.google.chrome\nversion=1\nxc=<KSPathExistenceChecker:0 path=/Applications/Google Chrome.app>')
            backend=Google(runner,str(helper));self.assertEqual(backend.check(app).state,'available');backend.apply(app)
            self.assertIn('--productid',runner.calls[-1]);self.assertIn('--user-store',runner.calls[-1])
            self.assertNotIn('--update-apps',runner.calls[-1])
            runner.output='com.google.chrome /Applications/Other.app'
            with self.assertRaises(CommandError): backend.check(app)
    def test_stale_executable_inode(self):
        with tempfile.NamedTemporaryFile() as file:
            path=file.name;inode=Path(path).stat().st_ino
            self.assertFalse(executable_is_stale(f'ftxt\ni{inode}\nn{path}\n',path))
            self.assertTrue(executable_is_stale(f'ftxt\ni{inode+1}\nn{path}\n',path))
            self.assertFalse(executable_is_stale('ftxt\ni42\nn/other/path\n',path))

if __name__=='__main__': unittest.main()
