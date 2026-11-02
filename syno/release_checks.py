"""Read-only GitHub publication gates; never creates or replaces releases/assets."""
import hashlib
import json
import os
from pathlib import Path
import re
import urllib.error
import urllib.request

REPOSITORY = 'mr-narender/immich'


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise ValueError('authenticated GitHub redirects are not allowed')


def github_json(path, missing_ok=False):
    token = os.environ['GITHUB_TOKEN']
    if not token:
        raise ValueError('GITHUB_TOKEN is required')
    request = urllib.request.Request('https://api.github.com/repos/' + REPOSITORY + path,
                                     headers={'Accept': 'application/vnd.github+json',
                                              'User-Agent': 'immich-spk-release',
                                              'Authorization': 'Bearer ' + token,
                                              'X-GitHub-Api-Version': '2022-11-28'})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    try:
        with opener.open(request, timeout=30) as response:
            body = response.read(1024 * 1024 + 1)
    except urllib.error.HTTPError as error:
        if missing_ok and error.code == 404:
            error.close()
            return None
        raise
    if len(body) > 1024 * 1024:
        raise ValueError('oversized GitHub response')
    return json.loads(body)


def assert_unused(tag):
    for path in ('/releases/tags/', '/git/ref/tags/'):
        if github_json(path + tag, missing_ok=True) is not None:
            raise ValueError('release target already exists: ' + tag)
    # Published-by-tag reads omit drafts; use the caller's contents-write token inventory.
    for page in range(1, 11):
        releases = github_json('/releases?per_page=100&page=' + str(page))
        if (not isinstance(releases, list) or len(releases) > 100 or
                any(not isinstance(release, dict) or
                    not isinstance(release.get('tag_name'), str) or not release['tag_name']
                    for release in releases)):
            raise ValueError('malformed GitHub release inventory')
        if any(release['tag_name'] == tag for release in releases):
            raise ValueError('release target already exists: ' + tag)
        if len(releases) < 100:
            return
    raise ValueError('incomplete GitHub release inventory: pagination limit reached')


def verify_published(spk_version, source_sha, release_id, artifacts):
    """Require real immutable API evidence matching both locally verified artifacts."""
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+-[1-9][0-9]*', spk_version):
        raise ValueError('invalid package version')
    if not re.fullmatch(r'[0-9a-f]{40}', source_sha):
        raise ValueError('invalid producer commit')
    tag = 'v' + spk_version
    release = github_json('/releases/tags/' + tag)
    if (type(release.get('id')) is not int or release['id'] <= 0 or
            str(release['id']) != release_id or release.get('tag_name') != tag or
            release.get('immutable') is not True or release.get('draft') is not False or
            release.get('prerelease') is not False or not release.get('published_at')):
        raise ValueError('release is not the expected published immutable release')
    ref = github_json('/git/ref/tags/' + tag)
    obj = ref.get('object', {})
    if obj.get('type') != 'commit' or obj.get('sha') != source_sha:
        raise ValueError('release tag does not match reviewed producer commit')
    expected = {'immich-' + arch + '-' + spk_version + '.spk' for arch in ('x86_64', 'arm64')}
    paths = [Path(path) for path in artifacts]
    assets = release.get('assets', [])
    if (len(paths) != 2 or {path.name for path in paths} != expected or
            len(assets) != 2 or {asset.get('name') for asset in assets} != expected):
        raise ValueError('release must contain exactly both approved SPKs')
    ids = set()
    for path in paths:
        asset = next(asset for asset in assets if asset['name'] == path.name)
        digest = hashlib.sha256()
        with path.open('rb') as body:
            for block in iter(lambda: body.read(1024 * 1024), b''):
                digest.update(block)
        if (type(asset.get('id')) is not int or asset['id'] <= 0 or asset['id'] in ids or
                type(asset.get('size')) is not int or asset['size'] <= 0 or
                asset['size'] != path.stat().st_size or asset.get('state') != 'uploaded' or
                asset.get('digest') != 'sha256:' + digest.hexdigest() or
                asset.get('browser_download_url') != 'https://github.com/' + REPOSITORY +
                '/releases/download/' + tag + '/' + path.name):
            raise ValueError('published asset identity, size or SHA256 mismatch: ' + path.name)
        ids.add(asset['id'])
