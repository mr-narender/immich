"""Offline native DSM upgrade contracts; fake only the PostgreSQL process boundary."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

SOURCE = Path(__file__).resolve().parents[1] / 'src'
spec = importlib.util.spec_from_file_location('update_protocol', SOURCE / 'update_protocol.py')
p = importlib.util.module_from_spec(spec); spec.loader.exec_module(p)


class PreservationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.package = self.base / 'package'
        self.temp = self.base / 'upgrade'; self.temp.mkdir(mode=0o700)
        self.bodies = {
            'config': b"UPLOAD_LOCATION='/volume2/my photos'\nDB_USERNAME=custom\nDB_DATABASE_NAME=photos\nDB_PORT=5555\nDB_PASSWORD='do not log'\n",
            'ports': b'DB_PORT_PERSISTED=5555\nREDIS_PORT_PERSISTED=6388\n',
            'ml': b'export ML_ENABLED=true\nexport IMMICH_MACHINE_LEARNING_URL=http://127.0.0.1:3003\n'}
        for key, rel in p.FILES.items():
            dest = self.package / rel; dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(self.bodies[key])
        (self.package / 'target/.update-required').write_text('1\n')
        data = self.package / 'var/pgdata'
        (data / 'global').mkdir(parents=True)
        (data / 'PG_VERSION').write_text('14\n')
        (data / 'global/pg_control').write_bytes(b'control fixture')
        (data / 'base/1').mkdir(parents=True)
        (data / 'base/1/123').write_bytes(b'database fixture\x00')
        tool = self.package / 'target/postgres/bin/pg_controldata'
        tool.parent.mkdir(parents=True); tool.write_text('fixture'); tool.chmod(0o700)
        def process(args, **kw):
            self.assertEqual(args[0], str(tool))
            self.assertEqual(kw['env']['LC_ALL'], 'C')
            output = b'pg_controldata (PostgreSQL) 14.19\n' if args[-1] == '--version' else b'Database cluster state:               shut down\n'
            return subprocess.CompletedProcess(args, 0, output, b'')
        patch = mock.patch('subprocess.run', side_effect=process)
        patch.start(); self.addCleanup(patch.stop)

    def save(self):
        p.preserve('save', self.package, self.temp, upgrading=True)

    def restore(self):
        p.preserve('restore', self.package, self.temp, upgrading=True)

    def attempts(self):
        return list((self.package / 'var/update-backups').glob('attempt-*'))

    def test_config_ports_and_ml_survive_replacement_before_start(self):
        self.save()
        for rel in p.FILES.values():
            (self.package / rel).unlink()
        (self.package / 'target/conf/immich.conf').write_text('DEFAULT=wrong\n')
        self.restore()
        for key, rel in p.FILES.items():
            self.assertEqual((self.package / rel).read_bytes(), self.bodies[key])
        self.assertFalse((self.package / 'target/.update-required').exists())
        hook = (SOURCE / 'scripts/postinst').read_text()
        self.assertLess(hook.index('update_protocol.py'), hook.index('mkdir -p'))
        self.assertNotIn('. "${CONF_FILE}"', hook)
        start = (SOURCE / 'scripts/start-stop-status').read_text()
        self.assertLess(start.index('.update-required'), start.index('. "${INSTALL_ROOT}/conf/immich.conf"'))

    def test_real_dsm_var_and_target_symlinks_restore(self):
        for name in ('var', 'target'):
            actual = self.base / ('persistent-' + name)
            (self.package / name).rename(actual)
            (self.package / name).symlink_to(actual, target_is_directory=True)
        self.save()
        for rel in p.FILES.values():
            (self.package / rel).unlink()
        self.restore()
        for key, rel in p.FILES.items():
            self.assertEqual((self.package / rel).read_bytes(), self.bodies[key])

    def test_restore_rejects_arbitrary_destination_leaf_symlink(self):
        self.save()
        outside = self.base / 'outside'; outside.write_bytes(b'unchanged')
        dest = self.package / p.FILES['ports']; dest.unlink(); dest.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, 'unsafe preservation destination'):
            self.restore()
        self.assertEqual(outside.read_bytes(), b'unchanged')
        self.assertTrue(dest.is_symlink())
        self.assertTrue((self.package / 'target/.update-required').exists())

    def test_backup_directory_parents_synced_before_ready(self):
        events = []
        real_fsync, real_save = p.os.fsync, p.save_json
        def sync(fd):
            info = os.fstat(fd)
            for name in ('var', 'var/update-backups'):
                path = self.package / name
                if path.exists() and info.st_ino == path.stat().st_ino:
                    events.append(name)
            real_fsync(fd)
        def save(path, value):
            if value.get('status') == 'ready':
                self.assertIn('var', events, 'persistent var parent must be synced')
                self.assertIn('var/update-backups', events, 'attempt parent must be synced')
                self.assertLess(events.index('var'), events.index('var/update-backups'))
            real_save(path, value)
        with mock.patch.object(p.os, 'fsync', side_effect=sync), mock.patch.object(p, 'save_json', side_effect=save):
            self.save()

    def assert_parent_sync_failure(self, name):
        real_fsync = p.os.fsync
        def sync(fd):
            path = self.package / name
            if path.exists() and os.fstat(fd).st_ino == path.stat().st_ino:
                raise OSError('fixture parent sync failure')
            real_fsync(fd)
        with mock.patch.object(p.os, 'fsync', side_effect=sync):
            with self.assertRaisesRegex(OSError, 'fixture parent sync failure'):
                self.save()
        self.assertFalse((self.temp / 'immich-preserve-v1/manifest.json').exists())
        for attempt in self.attempts():
            status = attempt / 'status.json'
            self.assertFalse(status.exists() and json.loads(status.read_text())['status'] == 'ready')

    def test_var_parent_sync_failure_prevents_readiness(self):
        self.assert_parent_sync_failure('var')

    def test_backup_root_sync_failure_prevents_readiness(self):
        self.assert_parent_sync_failure('var/update-backups')

    def test_clean_physical_backup_is_durable_complete_and_byte_verified(self):
        self.save()
        self.assertEqual(len(self.attempts()), 1, 'preupgrade must retain a durable physical backup')
        backup = self.attempts()[0]
        status = json.loads((backup / 'status.json').read_text())
        self.assertEqual(status['status'], 'ready')
        for rel in ['PG_VERSION','global/pg_control','base/1/123']:
            self.assertEqual((backup / 'pgdata' / rel).read_bytes(), (self.package / 'var/pgdata' / rel).read_bytes())
        for key in p.FILES:
            self.assertEqual((backup / key).read_bytes(), self.bodies[key])
        self.assertNotIn('do not log', (backup / 'manifest.json').read_text())
        self.restore()
        self.assertEqual(json.loads((backup / 'status.json').read_text())['status'], 'config-restored')
        self.assertTrue((backup / 'pgdata/base/1/123').exists())

    def test_absent_optional_files_remain_absent(self):
        (self.package / p.FILES['ml']).unlink()
        self.save()
        (self.package / p.FILES['ml']).write_text('NEW=wrong')
        self.restore()
        self.assertFalse((self.package / p.FILES['ml']).exists())

    def assert_save_refused(self, error, reason):
        with self.assertRaisesRegex(error, reason):
            self.save()
        self.assertTrue((self.package / 'target/conf/immich.conf').exists())
        self.assertTrue((self.package / 'target/.update-required').exists())
        self.assertEqual(json.loads((self.attempts()[0] / 'status.json').read_text())['status'], 'failed')
        self.assertFalse((self.temp / 'immich-preserve-v1/manifest.json').exists())

    def test_running_database_refused(self):
        (self.package / 'var/pgdata/postmaster.pid').write_text('123')
        self.assert_save_refused(ValueError, 'database may still be running')

    def test_wrong_database_major_refused(self):
        (self.package / 'var/pgdata/PG_VERSION').write_text('15')
        self.assert_save_refused(ValueError, 'database major must be PostgreSQL 14')

    def test_missing_control_tool_refused(self):
        (self.package / 'target/postgres/bin/pg_controldata').unlink()
        self.assert_save_refused(FileNotFoundError, 'pg_controldata')

    def test_controldata_error_refused(self):
        with mock.patch('subprocess.run', return_value=subprocess.CompletedProcess([], 1, b'', b'')):
            self.assert_save_refused(ValueError, 'bundled pg_controldata failed')

    def test_unclean_database_refused_after_tool_version_check(self):
        commands = []
        def process(args, **kwargs):
            commands.append(args[-1])
            output = (b'pg_controldata (PostgreSQL) 14.19\n' if args[-1] == '--version'
                      else b'Database cluster state: in production\n')
            return subprocess.CompletedProcess(args, 0, output, b'')
        with mock.patch('subprocess.run', side_effect=process):
            self.assert_save_refused(ValueError, 'database is not cleanly shut down')
        self.assertEqual(commands, ['--version', str((self.package / 'var').resolve() / 'pgdata')])

    def test_wrong_control_tool_major_refused(self):
        with mock.patch('subprocess.run', return_value=subprocess.CompletedProcess([], 0, b'pg_controldata (PostgreSQL) 15.1\n', b'')):
            self.assert_save_refused(ValueError, 'only bundled PostgreSQL 14 is supported')

    def test_disk_shortage_blocks_upgrade(self):
        with mock.patch('shutil.disk_usage', return_value=mock.Mock(free=0)):
            self.assert_save_refused(ValueError, 'insufficient disk space for cold database backup')

    def test_copy_failure_is_retained_and_blocks_retry(self):
        with mock.patch.object(p, 'copy_database', side_effect=OSError('fixture copy failure')):
            self.assert_save_refused(OSError, 'fixture copy failure')
        self.assertEqual(json.loads((self.attempts()[0] / 'status.json').read_text())['status'], 'failed')
        other = self.base / 'another-upgrade'; other.mkdir(mode=0o700)
        with self.assertRaises(ValueError):
            p.preserve('save', self.package, other, upgrading=True)
        self.assertEqual(len(self.attempts()), 1)

    def test_source_change_after_copy_blocks_upgrade(self):
        original = p.copy_database
        def change(*args):
            original(*args)
            (self.package / 'var/pgdata/base/1/123').write_text('changed after copy')
        with mock.patch.object(p, 'copy_database', side_effect=change):
            self.assert_save_refused(ValueError, 'database changed after backup')

    def test_corrupt_snapshot_blocks_restore_and_marker_removal(self):
        self.save()
        self.assertTrue(self.attempts(), 'backup required')
        (self.attempts()[0] / 'pgdata/base/1/123').write_text('tampered')
        with self.assertRaises(ValueError):
            self.restore()
        self.assertTrue((self.package / 'target/.update-required').exists())

    def test_missing_temp_missing_snapshot_and_symlink_refused(self):
        for temp in [None, self.temp]:
            with self.assertRaises((ValueError, OSError)):
                p.preserve('restore', self.package, temp, upgrading=True)
        (self.base / 'linked').symlink_to(self.temp)
        with self.assertRaises(ValueError):
            p.preserve('save', self.package, self.base / 'linked', upgrading=True)
        conf = self.package / p.FILES['config']; conf.unlink(); conf.symlink_to('/dev/null')
        with self.assertRaises(OSError):
            self.save()

    def test_symlinked_pgdata_and_tablespaces_refused(self):
        data = self.package / 'var/pgdata'
        (data / 'pg_tblspc').mkdir(); (data / 'pg_tblspc/123').symlink_to(self.base)
        with self.assertRaises(ValueError):
            self.save()

    def test_outstanding_failed_or_pending_backup_blocks_another_attempt(self):
        backup_root = self.package / 'var/update-backups'; backup_root.mkdir(mode=0o700)
        (backup_root / 'attempt-interrupted').mkdir(mode=0o700)
        with self.assertRaises(ValueError):
            self.save()

    def test_concurrent_backup_and_lock_symlink_are_refused(self):
        self.assertTrue(hasattr(p, 'locked'), 'backup needs an exclusive no-symlink lock')
        root = p.storage(self.package)
        with p.locked(root):
            with self.assertRaises(ValueError):
                self.save()
        (root / 'lock').unlink(); (root / 'lock').symlink_to(self.base / 'outside')
        with self.assertRaises((OSError, ValueError)):
            self.save()

    def test_first_install_unblocks_without_upgrade_snapshot(self):
        p.preserve('restore', self.package, upgrading=False)
        self.assertFalse((self.package / 'target/.update-required').exists())
        self.assertFalse((self.package / 'var/update-backups').exists())


if __name__ == '__main__':
    unittest.main()
