"""Tiny real assembly fixture: no compilation, network, services or installation."""
import copy
import io
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import textwrap
import tarfile
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
SOURCE = REPO / 'syno/src'


class AssemblyTests(unittest.TestCase):
    def test_real_assembler_ships_native_backup_hooks_and_package_permissions(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            def archive(name, member):
                p = root / name
                with tarfile.open(p, 'w:gz') as t:
                    item = tarfile.TarInfo(member); body = b'offline fixture\n'; item.size = len(body)
                    t.addfile(item, io.BytesIO(body))
                return str(p)
            geodata = root / 'geo'; geodata.mkdir()
            out = root / 'candidate.spk'
            env = dict(os.environ, REPO=str(REPO), VERSION='3.3.6-2', ARCH='arm64',
                       OUT_SPK=str(out), TMPDIR=str(root),
                       SERVER_TAR=archive('server.tgz','dist/main.js'), WEB_TAR=archive('web.tgz','web/index.html'),
                       POSTGRES_TAR=archive('pg.tgz','bin/pg_controldata'), REDIS_TAR=archive('redis.tgz','bin/redis-server'),
                       NODE_TAR=archive('node.tgz','node/bin/node'), GEODATA_DIR=str(geodata), FFMPEG_TAR='', HEIF_DIR='')
            r = subprocess.run(['bash', str(REPO / 'syno/assemble-standalone.sh')], env=env,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
            self.assertEqual(r.returncode, 0, r.stderr.decode()[:2000])
            with tarfile.open(out) as outer, tarfile.open(fileobj=outer.extractfile('package.tgz'), mode='r:gz') as inner:
                info = outer.extractfile('INFO').read().decode()
                self.assertIn('version="3.3.6-2"', info); self.assertIn('arch="arm64"', info)
                for name in ('preupgrade','postupgrade','postinst','start-stop-status'):
                    member = outer.getmember('scripts/' + name)
                    self.assertTrue(member.mode & 0o111, name + ' must be executable')
                    self.assertEqual(outer.extractfile(member).read(), (SOURCE / 'scripts' / name).read_bytes())
                self.assertEqual(outer.extractfile('scripts/update_protocol.py').read(), (SOURCE / 'update_protocol.py').read_bytes())
                self.assertEqual(inner.extractfile('./share/update_protocol.py').read(), (SOURCE / 'update_protocol.py').read_bytes())
                self.assertEqual(inner.extractfile('./.update-required').read(), b'1\n')
                self.assertFalse(any('nas-update' in name or 'update-hooks' in name for name in inner.getnames()))
                privilege = json.loads(outer.extractfile('conf/privilege').read())
                self.assertEqual(privilege['defaults']['run-as'], 'package')
                self.assertNotIn('ctrl-script', privilege)
            verifier_path = REPO / 'syno/verify_update_artifact.py'
            self.assertTrue(verifier_path.exists(), 'catalog capability requires an archive verifier')
            spec = importlib.util.spec_from_file_location('verify_update_artifact', verifier_path)
            verifier = importlib.util.module_from_spec(spec); spec.loader.exec_module(verifier)
            self.assertEqual(verifier.verified_protocol(out, 'arm64', '3.3.6-2'), 1)
            x86 = root / 'immich-x86_64-3.3.6-2.spk'
            x86_env = dict(env, ARCH='x86_64', OUT_SPK=str(x86))
            built = subprocess.run(['bash', str(REPO / 'syno/assemble-standalone.sh')], env=x86_env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
            self.assertEqual(built.returncode, 0, built.stderr.decode()[:2000])
            # Execute the actual CI metadata generator offline in an isolated cwd.
            workflow = (REPO / '.github/workflows/auto-release.yml').read_text()
            step = workflow.split('      - name: Update packages.json\n', 1)[1]
            code = textwrap.dedent(step.split("          python3 - << 'PYEOF'\n", 1)[1].split('          PYEOF', 1)[0])
            (root / 'syno').symlink_to(REPO / 'syno', target_is_directory=True)
            ci_env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1', VERSION='3.3.6', SPK_VERSION='3.3.6-2',
                          X86_SPK=str(x86), ARM64_SPK=str(out), X86_SPK_NAME=x86.name,
                          ARM64_SPK_NAME='immich-arm64-3.3.6-2.spk')
            generated = subprocess.run([sys.executable, '-B', '-c', code], cwd=root, env=ci_env,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
            self.assertEqual(generated.returncode, 0, generated.stderr.decode()[:2000])
            catalog = (root / 'packages.json').read_bytes()
            self.assertEqual([item['update_protocol'] for item in json.loads(catalog)['packages']], [1, 1])
            with self.assertRaises(ValueError):
                verifier.verified_protocol(out, 'x86_64', '3.3.6-2')
            with self.assertRaises(ValueError):
                verifier.verified_protocol(out, 'arm64', '3.3.6-3')

            def contents(archive):
                with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
                    return [(m, tar.extractfile(m).read() if m.isfile() else None) for m in tar]
            def repack(entries, changed, replacement):
                body = io.BytesIO()
                with tarfile.open(fileobj=body, mode='w:gz') as tar:
                    for member, data in entries:
                        if member.name == changed:
                            if replacement is None:
                                continue
                            member = copy.copy(member)
                            data = replacement; member.size = len(data)
                        tar.addfile(member, io.BytesIO(data) if data is not None else None)
                return body.getvalue()
            outer_entries = contents(out.read_bytes())
            payload = next(data for member, data in outer_entries if member.name == 'package.tgz')
            inner_entries = contents(payload)
            for name in ('scripts/preupgrade', 'scripts/postupgrade', 'scripts/postinst',
                         'scripts/start-stop-status', 'scripts/update_protocol.py',
                         './share/update_protocol.py', './.update-required'):
                for replacement in (None, b'tampered\n'):
                    with self.subTest(member=name, missing=replacement is None):
                        if name.startswith('./'):
                            changed = repack(inner_entries, name, replacement)
                            body = repack(outer_entries, 'package.tgz', changed)
                        else:
                            body = repack(outer_entries, name, replacement)
                        bad = root / 'bad.spk'; bad.write_bytes(body)
                        with self.assertRaises(ValueError):
                            verifier.verified_protocol(bad, 'arm64', '3.3.6-2')
            ci_env['ARM64_SPK'] = str(bad)
            refused = subprocess.run([sys.executable, '-B', '-c', code], cwd=root, env=ci_env,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
            self.assertNotEqual(refused.returncode, 0, 'CI must refuse capability for a tampered artifact')
            self.assertEqual((root / 'packages.json').read_bytes(), catalog, 'failed verification must not rewrite catalog')


if __name__ == '__main__':
    unittest.main()
