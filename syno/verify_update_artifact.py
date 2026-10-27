"""Trusted CI capability check against current source; never extracts or installs SPKs."""
from pathlib import Path
import re
import tarfile

SOURCE = Path(__file__).resolve().parent / 'src'


def verified_protocol(spk, arch, version):
    """Return protocol 1 only for an artifact containing the exact upgrade gate."""
    def read(archive, name, executable=False):
        members = [m for m in archive.getmembers() if m.name == name]
        if (len(members) != 1 or not members[0].isfile() or
                (executable and not members[0].mode & 0o111)):
            raise ValueError('missing or unsafe update artifact member: ' + name)
        with archive.extractfile(members[0]) as body:
            return body.read()

    def matches(archive, name, expected, executable=False):
        if read(archive, name, executable) != expected:
            raise ValueError('update artifact differs from source: ' + name)

    with tarfile.open(spk) as outer:
        info = read(outer, 'INFO').decode('utf-8')
        for key, value in (('package', 'immich'), ('arch', arch), ('version', version)):
            values = re.findall(r'^' + key + r'="?([^"\n]+)"?$', info, re.MULTILINE)
            if values != [value]:
                raise ValueError('artifact metadata mismatch: ' + key)
        for name in ('preupgrade', 'postupgrade', 'postinst', 'start-stop-status'):
            matches(outer, 'scripts/' + name, (SOURCE / 'scripts' / name).read_bytes(), True)
        helper = (SOURCE / 'update_protocol.py').read_bytes()
        matches(outer, 'scripts/update_protocol.py', helper)
        # Inspect the nested payload without extracting any archive-controlled paths.
        payloads = [m for m in outer.getmembers() if m.name == 'package.tgz']
        if len(payloads) != 1 or not payloads[0].isfile():
            raise ValueError('missing or unsafe package payload')
        with outer.extractfile(payloads[0]) as payload:
            with tarfile.open(fileobj=payload, mode='r:gz') as inner:
                matches(inner, './share/update_protocol.py', helper)
                matches(inner, './.update-required', b'1\n')
    return 1
