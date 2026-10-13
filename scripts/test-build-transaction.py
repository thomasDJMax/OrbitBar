#!/usr/bin/env python3
"""Exercise real release transaction logic with fake build/sign tools.

Everything runs in a temporary project. No application is executed, no real
dist artifact is touched, and mocked processes only emulate build failures.
"""
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

PROJECT = Path(__file__).resolve().parent.parent

MOCK_TOOL = r'''#!/usr/bin/env python3
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
name = Path(sys.argv[0]).name
args = sys.argv[1:]
if name == 'swift':
    if args and args[0] == 'build':
        if '--show-bin-path' in args:
            print(os.environ['MOCK_BIN'])
        elif os.environ.get('MOCK_BLOCK'):
            Path(os.environ['MOCK_READY']).touch()
            deadline = time.monotonic() + 10
            while not Path(os.environ['MOCK_RELEASE']).exists():
                if time.monotonic() > deadline: sys.exit(88)
                time.sleep(0.01)
elif name == 'iconutil':
    Path(args[args.index('--output') + 1]).write_bytes(b'fake-icon')
elif name == 'codesign':
    if os.environ.get('MOCK_FAIL_SIGN'): sys.exit(67)
elif name == 'ps':
    if os.environ.get('MOCK_FAIL_PS'): sys.exit(68)
    if os.environ.get('MOCK_EXECUTABLE'): print(os.environ['MOCK_EXECUTABLE'])
elif name == 'mv':
    source, destination = map(Path, args)
    publishing = source.parent.name == '.OrbitBar.release' and destination.parent.name == 'dist'
    recovering_app = source.name == 'previous.app' and destination.name == 'OrbitBar.app'
    if recovering_app and os.environ.get('MOCK_KILL_BEFORE_RECOVERY_MOVE'):
        os.kill(os.getppid(), signal.SIGKILL)
        sys.exit(0)
    if publishing and source.name == 'OrbitBar-macos.zip' and os.environ.get('MOCK_FAIL_ZIP_SWAP'):
        sys.exit(69)
    result = subprocess.run(['/bin/mv', *args])
    if result.returncode: sys.exit(result.returncode)
    if publishing and source.name == 'OrbitBar.app' and os.environ.get('MOCK_KILL_AFTER_APP'):
        os.kill(os.getppid(), signal.SIGKILL)
    if recovering_app and os.environ.get('MOCK_KILL_DURING_RECOVERY'):
        os.kill(os.getppid(), signal.SIGKILL)
elif name == 'rm':
    target = Path(args[-1])
    marker = target.parent / '.OrbitBar.release-committed'
    if target.name == '.OrbitBar.release' and marker.exists() and os.environ.get('MOCK_KILL_DURING_COMMITTED_CLEANUP'):
        old_app = target / 'previous.app'
        if old_app.exists():
            import shutil
            shutil.rmtree(old_app)
        os.kill(os.getppid(), signal.SIGKILL)
        sys.exit(0)
    sys.exit(subprocess.run(['/bin/rm', *args]).returncode)
'''


class BuildTransactionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='OrbitBar-release-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / 'scripts').mkdir()
        (self.root / 'Resources').mkdir()
        self.dist = self.root / 'dist'
        self.dist.mkdir()
        self.app = self.dist / 'OrbitBar.app'
        self.binary = self.app / 'Contents/MacOS/OrbitBar'
        self.binary.parent.mkdir(parents=True)
        self.binary.write_bytes(b'old-binary')
        (self.app / 'stale-resource').write_bytes(b'old-resource')
        self.zip = self.dist / 'OrbitBar-macos.zip'
        self.zip.write_bytes(b'old-archive')
        self.script = self.root / 'scripts/build-app.sh'
        shutil.copyfile(PROJECT / 'scripts/build-app.sh', self.script)
        shutil.copyfile(PROJECT / 'Resources/Info.plist', self.root / 'Resources/Info.plist')
        mock_bin = self.root / 'built'
        mock_bin.mkdir()
        (mock_bin / 'OrbitBar').write_bytes(b'new-binary')
        shim_dir = self.root / 'tools'
        shim_dir.mkdir()
        for command in ('swift', 'iconutil', 'codesign', 'ps', 'mv', 'rm'):
            tool = shim_dir / command
            tool.write_text(MOCK_TOOL)
            tool.chmod(0o755)
        self.environment = dict(os.environ, PATH=str(shim_dir) + os.pathsep + os.environ['PATH'],
                                MOCK_BIN=str(mock_bin))

    def build(self, **extra):
        return subprocess.run(['/bin/bash', str(self.script)],
                              env=dict(self.environment, **extra), text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)

    def assertOldRelease(self):
        self.assertEqual(self.binary.read_bytes(), b'old-binary')
        self.assertEqual(self.zip.read_bytes(), b'old-archive')
        self.assertTrue((self.app / 'stale-resource').exists())
        self.assertFalse((self.dist / '.OrbitBar.release').exists())

    def testSuccessReplacesBundleAndZipWithoutStaleResources(self):
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.binary.read_bytes(), b'new-binary')
        self.assertFalse((self.app / 'stale-resource').exists())
        archive = subprocess.check_output(['/usr/bin/unzip', '-Z1', str(self.zip)], text=True)
        self.assertIn('OrbitBar.app/Contents/MacOS/OrbitBar', archive)
        self.assertNotIn('__MACOSX', archive)
        self.assertNotIn('/._', archive)

    def testSigningFailurePreservesPreviousRelease(self):
        self.assertNotEqual(self.build(MOCK_FAIL_SIGN='1').returncode, 0)
        self.assertOldRelease()

    def testSecondSwapFailureRollsBackBothArtifacts(self):
        self.assertNotEqual(self.build(MOCK_FAIL_ZIP_SWAP='1').returncode, 0)
        self.assertOldRelease()

    def testSigkillRecoveryRestoresBothArtifactsOnNextInvocation(self):
        result = self.build(MOCK_KILL_AFTER_APP='1')
        self.assertEqual(result.returncode, -signal.SIGKILL, result.stderr)
        self.assertTrue((self.dist / '.OrbitBar.release/previous.app').exists())
        # Fail before new publication so we can inspect the recovered version.
        self.assertNotEqual(self.build(MOCK_FAIL_SIGN='1').returncode, 0)
        self.assertOldRelease()

    def testFirstInstallSigkillRecoveryRemovesPartialArtifacts(self):
        shutil.rmtree(self.app)
        self.zip.unlink()
        self.assertEqual(self.build(MOCK_KILL_AFTER_APP='1').returncode, -signal.SIGKILL)
        self.assertNotEqual(self.build(MOCK_FAIL_SIGN='1').returncode, 0)
        self.assertFalse(self.app.exists())
        self.assertFalse(self.zip.exists())
        self.assertFalse((self.dist / '.OrbitBar.release').exists())

    def testSigkillAfterRecoveringAppCanResumeAndRecoverZip(self):
        self.assertEqual(self.build(MOCK_KILL_AFTER_APP='1').returncode, -signal.SIGKILL)
        self.assertEqual(self.build(MOCK_KILL_DURING_RECOVERY='1').returncode, -signal.SIGKILL)
        self.assertEqual(self.binary.read_bytes(), b'old-binary')
        self.assertFalse((self.dist / '.OrbitBar.release/previous.app').exists())
        self.assertTrue((self.dist / '.OrbitBar.release/previous.zip').exists())
        self.assertNotEqual(self.build(MOCK_FAIL_SIGN='1').returncode, 0)
        self.assertOldRelease()

    def testSigkillAfterRemovingPartialAppCanRetryBackupMove(self):
        self.assertEqual(self.build(MOCK_KILL_AFTER_APP='1').returncode, -signal.SIGKILL)
        self.assertEqual(self.build(MOCK_KILL_BEFORE_RECOVERY_MOVE='1').returncode, -signal.SIGKILL)
        self.assertFalse(self.app.exists())
        self.assertTrue((self.dist / '.OrbitBar.release/previous.app').exists())
        self.assertNotEqual(self.build(MOCK_FAIL_SIGN='1').returncode, 0)
        self.assertOldRelease()

    def testSigkillDuringCommittedCleanupPreservesTheNewPair(self):
        result = self.build(MOCK_KILL_DURING_COMMITTED_CLEANUP='1')
        self.assertEqual(result.returncode, -signal.SIGKILL, result.stderr)
        new_zip = self.zip.read_bytes()
        self.assertEqual(self.binary.read_bytes(), b'new-binary')
        self.assertFalse((self.dist / '.OrbitBar.release/previous.app').exists())
        self.assertTrue((self.dist / '.OrbitBar.release/previous.zip').exists())
        self.assertTrue((self.dist / '.OrbitBar.release-committed').exists())
        self.assertNotEqual(self.build(MOCK_FAIL_SIGN='1').returncode, 0)
        self.assertEqual(self.binary.read_bytes(), b'new-binary')
        self.assertEqual(self.zip.read_bytes(), new_zip)
        self.assertFalse((self.dist / '.OrbitBar.release').exists())
        self.assertFalse((self.dist / '.OrbitBar.release-committed').exists())

    def testConcurrentBuildIsRefusedWhileOwnerHoldsLock(self):
        ready, release = self.root / 'ready', self.root / 'release'
        owner = subprocess.Popen(['/bin/bash', str(self.script)], stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True,
                                 env=dict(self.environment, MOCK_BLOCK='1', MOCK_READY=str(ready),
                                          MOCK_RELEASE=str(release)))
        try:
            deadline = time.monotonic() + 5
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(ready.exists())
            competitor = self.build()
            self.assertNotEqual(competitor.returncode, 0)
            self.assertIn('Another OrbitBar build', competitor.stderr)
            self.assertEqual(self.binary.read_bytes(), b'old-binary')
            release.touch()
            _, error = owner.communicate(timeout=10)
            self.assertEqual(owner.returncode, 0, error)
        finally:
            if owner.poll() is None:
                owner.kill()
                owner.communicate(timeout=5)

    def testRunningExecutableAliasIsDetectedByInode(self):
        alias = self.root / 'alias-executable'
        os.link(self.binary, alias)
        result = self.build(MOCK_EXECUTABLE=str(alias))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Quit the OrbitBar', result.stderr)
        self.assertOldRelease()

    def testUnreadableProcessListDoesNotAllowPublication(self):
        result = self.build(MOCK_FAIL_PS='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Unable to check running applications', result.stderr)
        self.assertOldRelease()


if __name__ == '__main__':
    unittest.main(verbosity=2)
