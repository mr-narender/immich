#!/usr/bin/python3
"""DSM package-user upgrade gate: cold PG14 backup and pre-start config preservation.

No root operation, shell evaluation, scheduler, database restore or media backup.
"""
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import uuid

FILES = {'config': 'target/conf/immich.conf', 'ports': 'var/ports.env',
         'ml': 'var/ml-settings.env'}
PACKAGE = Path('/var/packages/immich')


def read_file(path, limit=1024 * 1024):
    fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as f:
        s = os.fstat(f.fileno())
        if not stat.S_ISREG(s.st_mode) or s.st_size > limit:
            raise ValueError('unsafe preservation file')
        return f.read()


def atomic(path, data):
    tmp = path.with_name(path.name + '.preserving')
    fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(data); f.flush(); os.fsync(f.fileno())
        os.replace(str(tmp), str(path))
        fd = os.open(str(path.parent), os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    finally:
        if tmp.exists():
            tmp.unlink()


def save_json(path, value):
    body = json.dumps(value, sort_keys=True).encode()
    if len(body) > 64 * 1024 * 1024:
        raise ValueError('backup manifest exceeds supported limit')
    atomic(path, body)


def directory(path, create=False, private=False):
    if create:
        try:
            path.mkdir(mode=0o700)
        except FileExistsError:
            pass
    s = path.lstat()
    if (not stat.S_ISDIR(s.st_mode) or s.st_uid != os.geteuid() or
            s.st_mode & (0o077 if private else 0o022)):
        raise ValueError('unsafe package backup directory')
    return path


def sync_directory(path):
    fd = os.open(str(path), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def storage(package):
    # DSM's var link is supported; never allow a second link at the backup/data leaf.
    var = directory((package / 'var').resolve(strict=True))
    root = directory(var / 'update-backups', create=True, private=True)
    sync_directory(var)  # Persist the backup-root entry, including after an interrupted creation.
    return root


def data_directory(package):
    return directory((package / 'var').resolve(strict=True) / 'pgdata')


def file_digest(path, dest=None):
    fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    digest = hashlib.sha256(); size = 0
    with os.fdopen(fd, 'rb') as f:
        s = os.fstat(f.fileno())
        if (not stat.S_ISREG(s.st_mode) or s.st_nlink != 1 or
                s.st_uid != os.geteuid() or s.st_mode & 0o022):
            raise ValueError('unsafe database file')
        while True:
            body = f.read(1024 * 1024)
            if not body:
                break
            digest.update(body); size += len(body)
            if dest is not None:
                dest.write(body)
        if size != s.st_size:
            raise ValueError('database changed during backup')
    return {'size':size, 'sha256':digest.hexdigest()}


def inventory(data):
    directory(data)
    result = {}
    def onerror(error):
        raise error
    for root, dirs, files in os.walk(str(data), followlinks=False, onerror=onerror):
        for name in dirs:
            path = directory(Path(root) / name)
            result[path.relative_to(data).as_posix()] = {'directory':True}
        for name in files:
            path = Path(root) / name
            result[path.relative_to(data).as_posix()] = file_digest(path)
        if len(result) > 500000:
            raise ValueError('database inventory exceeds supported limit')
    return result


def control_data(package, data):
    tool = package / 'target/postgres/bin/pg_controldata'
    s = tool.lstat()
    if not stat.S_ISREG(s.st_mode) or not s.st_mode & 0o111:
        raise ValueError('missing bundled pg_controldata')
    env = {'PATH':'/usr/bin:/bin', 'HOME':'/nonexistent', 'LC_ALL':'C',
           'LD_LIBRARY_PATH':str(package / 'target/postgres/lib')}
    def run(arg):
        r = subprocess.run([str(tool), arg], env=env, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, timeout=30)
        if r.returncode or len(r.stdout) > 65536:
            raise ValueError('bundled pg_controldata failed')
        return r.stdout.decode()
    if not re.fullmatch(r'pg_controldata \(PostgreSQL\) 14\.[0-9]+\s*', run('--version')):
        raise ValueError('only bundled PostgreSQL 14 is supported')
    states = re.findall(r'^Database cluster state:\s*(.*?)\s*$', run(str(data)), re.MULTILINE)
    if states != ['shut down']:
        raise ValueError('database is not cleanly shut down')


def require_clean(package, data):
    if read_file(data / 'PG_VERSION').strip() != b'14':
        raise ValueError('database major must be PostgreSQL 14')
    pid = data / 'postmaster.pid'
    if pid.exists() or pid.is_symlink():
        raise ValueError('database may still be running')
    control_data(package, data)


def copy_database(data, dest, expected):
    dest.mkdir(mode=0o700)
    for name, entry in expected.items():
        target = dest / name
        if entry.get('directory'):
            target.mkdir(mode=0o700)
        else:
            fd = os.open(str(target), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, 'wb') as out:
                actual = file_digest(data / name, out)
                out.flush(); os.fsync(out.fileno())
            if actual != entry:
                raise ValueError('database changed while copying')
    if inventory(dest) != expected or inventory(data) != expected:
        raise ValueError('database copy verification failed')
    for root, dirs, files in os.walk(str(dest), topdown=False):
        fd = os.open(root, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)


def manifest_files(package):
    bodies = {}
    for key, rel in FILES.items():
        path = package / rel
        bodies[key] = read_file(path) if path.exists() or key == 'config' else None
    return bodies


@contextlib.contextmanager
def locked(root):
    fd = os.open(str(root / 'lock'), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        s = os.fstat(fd)
        if not stat.S_ISREG(s.st_mode) or s.st_uid != os.geteuid() or s.st_mode & 0o077 or s.st_nlink != 1:
            raise ValueError('unsafe backup lock')
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            raise ValueError('another backup is running') from None
        yield
    finally:
        os.close(fd)


def backup(package, temp_folder):
    root = storage(package)
    with locked(root):
        backup_locked(package, temp_folder, root)


def backup_locked(package, temp_folder, root):
    for old in root.iterdir():
        if old.name == 'lock':
            continue
        directory(old, private=True)
        try:
            status = json.loads(read_file(old / 'status.json'))
        except (OSError, ValueError):
            raise ValueError('incomplete backup requires manual investigation') from None
        if status.get('status') != 'config-restored':
            raise ValueError('outstanding backup/upgrade requires manual investigation')
    attempt = root / ('attempt-' + uuid.uuid4().hex)
    attempt.mkdir(mode=0o700)
    sync_directory(root)  # Persist the attempt entry before publishing any ready status.
    status = {'status':'pending', 'attempt':attempt.name}
    save_json(attempt / 'status.json', status)
    try:
        data = data_directory(package)
        require_clean(package, data)
        bodies = manifest_files(package)
        expected = inventory(data)
        needed = sum(e.get('size', 0) for e in expected.values())
        if shutil.disk_usage(str(root)).free < needed + needed // 5 + 16*1024*1024:
            raise ValueError('insufficient disk space for cold database backup')
        manifest = {'postgres_major':14, 'files':{}, 'pgdata':expected}
        for key, body in bodies.items():
            manifest['files'][key] = hashlib.sha256(body).hexdigest() if body is not None else None
            if body is not None:
                atomic(attempt / key, body)
        copy_database(data, attempt / 'pgdata', expected)
        require_clean(package, data)
        control_data(package, attempt / 'pgdata')
        if inventory(data) != expected:
            raise ValueError('database changed after backup')
        if manifest_files(package) != bodies:
            raise ValueError('configuration changed during backup')
        save_json(attempt / 'manifest.json', manifest)
        status['status'] = 'ready'; save_json(attempt / 'status.json', status)
        save_json(temp_folder / 'manifest.json', {'attempt':attempt.name})
    except BaseException:
        status['status'] = 'failed'; save_json(attempt / 'status.json', status)
        raise


def restore(package, temp_folder):
    ref = json.loads(read_file(temp_folder / 'manifest.json'))
    if set(ref) != {'attempt'} or not re.fullmatch('attempt-[0-9a-f]{32}', ref['attempt']):
        raise ValueError('invalid preservation reference')
    attempt = directory(storage(package) / ref['attempt'], private=True)
    status = json.loads(read_file(attempt / 'status.json'))
    if status != {'status':'ready', 'attempt':attempt.name}:
        raise ValueError('backup is not ready for configuration restoration')
    try:
        manifest = json.loads(read_file(attempt / 'manifest.json', limit=64 * 1024 * 1024))
        if (set(manifest) != {'postgres_major','files','pgdata'} or manifest['postgres_major'] != 14 or
                set(manifest['files']) != set(FILES) or not manifest['files']['config']):
            raise ValueError('invalid backup manifest')
        data = data_directory(package)
        require_clean(package, data)  # Uses the NEW bundled tool; never start across a major change.
        if inventory(attempt / 'pgdata') != manifest['pgdata'] or inventory(data) != manifest['pgdata']:
            raise ValueError('database/snapshot changed before config restoration')
        saved = {}
        for key, digest in manifest['files'].items():
            if digest is not None:
                body = read_file(attempt / key)
                if hashlib.sha256(body).hexdigest() != digest:
                    raise ValueError('configuration backup checksum failed')
                saved[key] = body
        # Only DSM's top-level target/var links are supported. Validate their
        # resolved directories before appending fixed, non-symlink destinations.
        var = directory((package / 'var').resolve(strict=True))
        target = (package / 'target').resolve(strict=True)
        conf = directory(target / 'conf')
        destinations = {'config': conf / 'immich.conf',
                        'ports': var / 'ports.env', 'ml': var / 'ml-settings.env'}
        if any(dest.is_symlink() for dest in destinations.values()):
            raise ValueError('unsafe preservation destination')
        for key, dest in destinations.items():
            if key in saved:
                atomic(dest, saved[key])
            elif dest.exists():
                dest.unlink()
                sync_directory(dest.parent)
        status['status'] = 'config-restored'; save_json(attempt / 'status.json', status)
    except BaseException:
        status['status'] = 'failed'; save_json(attempt / 'status.json', status)
        raise


def preserve(action, package=PACKAGE, temp=None, upgrading=False):
    marker = package / 'target/.update-required'
    if not upgrading:
        if action == 'restore':
            marker.unlink(missing_ok=True)
        return
    if not temp or not Path(temp).is_absolute():
        raise ValueError('missing DSM upgrade directory')
    temp = Path(temp)
    s = temp.lstat()
    if not stat.S_ISDIR(s.st_mode) or s.st_uid not in (0, os.geteuid()) or s.st_mode & 0o022:
        raise ValueError('unsafe DSM upgrade directory')
    folder = temp / 'immich-preserve-v1'
    if action == 'save':
        folder.mkdir(mode=0o700)
        backup(package, folder)
    elif action == 'restore':
        directory(folder, private=True)
        restore(package, folder)
        marker.unlink(missing_ok=True)
    else:
        raise ValueError('invalid preservation action')


def main():
    try:
        status = os.environ.get('SYNOPKG_PKG_STATUS')
        if os.geteuid() == 0 or status not in ('INSTALL', 'UPGRADE'):
            raise ValueError('package-user DSM install/upgrade context required')
        preserve(sys.argv[1], temp=os.environ.get('SYNOPKG_TEMP_UPGRADE_FOLDER'),
                 upgrading=status == 'UPGRADE')
        return 0
    except Exception:
        print('Immich backup/config preservation failed; upgrade/start refused. '
              'Retain var/update-backups and investigate; no automatic DB restore.', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
