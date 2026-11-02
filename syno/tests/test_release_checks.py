"""Offline producer publication gates; GitHub reads are controlled API fixtures."""
import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import textwrap
import unittest
from unittest import mock
import urllib.error
import urllib.parse
import urllib.request
import urllib.response
from email.message import Message

REPO = Path(__file__).resolve().parents[2]
SHA = 'a' * 40


def response(data):
    return io.BytesIO(json.dumps(data).encode())


class DetectionTests(unittest.TestCase):
    def detect(self, upstream='', revision='', existing=(), latest='3.3.5'):
        workflow = (REPO / '.github/workflows/auto-release.yml').read_text()
        step = workflow.split('      - name: Detect latest Immich release\n', 1)[1]
        code = textwrap.dedent(step.split("          python3 - << 'PYEOF'\n", 1)[1].split('          PYEOF', 1)[0])
        def get(req, *args, **kwargs):
            url = req.full_url
            if '/mr-narender/immich/releases?per_page=100&page=' in url:
                return response([])
            if url == 'https://api.github.com/repos/immich-app/immich/releases/latest':
                return response({'tag_name': 'v' + latest, 'draft': False, 'prerelease': False})
            if url == 'https://api.github.com/repos/immich-app/immich/releases/tags/v' + upstream:
                return response({'tag_name': 'v' + upstream, 'draft': False, 'prerelease': False})
            if any(url.endswith('/' + tag) for tag in existing):
                return response({'id': 42})
            raise urllib.error.HTTPError(url, 404, 'missing', {}, io.BytesIO())
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / 'output'
            env = dict(GITHUB_OUTPUT=str(output), UPSTREAM_VERSION=upstream, SPK_REVISION=revision,
                       GITHUB_TOKEN='offline-fixture', FORCE_REBUILD='true')
            with mock.patch.dict(os.environ, env), mock.patch.object(urllib.request.OpenerDirector, 'open', side_effect=get), mock.patch('sys.path', [str(REPO / 'syno')] + sys.path), contextlib.redirect_stdout(io.StringIO()):
                exec(compile(code, 'workflow-detect', 'exec'), {})
            return dict(line.split('=', 1) for line in output.read_text().splitlines())

    def test_manual_revision_two_uses_full_version(self):
        result = self.detect('3.3.5', '2', existing=('v3.3.5',), latest='3.3.6')
        self.assertEqual(result['spk_version'], '3.3.5-2')
        self.assertEqual(result['should_release'], 'true')

    def test_future_upstream_uses_first_revision_full_tag_contract(self):
        result = self.detect(latest='3.3.6')
        self.assertEqual(result['version'], '3.3.6')
        self.assertEqual(result['spk_version'], '3.3.6-1')
        self.assertEqual(result['should_release'], 'true')

    def test_existing_full_tag_or_legacy_revision_one_never_rebuilt(self):
        for upstream, revision, tags in [('', '', ('v3.3.5',)),
                                         ('3.3.5', '2', ('v3.3.5-2',)),
                                         ('', '', ('v3.3.5-1',))]:
            with self.subTest(tags=tags):
                self.assertEqual(self.detect(upstream, revision, tags)['should_release'], 'false')

    def test_malformed_manual_tuple_fails_closed(self):
        for upstream, revision in [('3.3.5', ''), ('', '2'), ('3.3.5/other', '2'),
                                   ('3.3.5', '0'), ('3.3.5', '02'), ('3.3.5', '2\n3')]:
            with self.subTest(upstream=upstream, revision=revision):
                with self.assertRaises(ValueError):
                    self.detect(upstream, revision)


class PublicationTests(unittest.TestCase):
    def setUp(self):
        path = REPO / 'syno/release_checks.py'
        self.assertTrue(path.exists(), 'publication read-back gate is missing')
        spec = importlib.util.spec_from_file_location('release_checks', path)
        self.checks = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.checks)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.paths = []
        assets = []
        for index, arch in enumerate(('x86_64', 'arm64'), 1):
            path = Path(self.tmp.name) / ('immich-' + arch + '-3.3.5-2.spk')
            path.write_bytes(b'offline fixture ' + arch.encode())
            self.paths.append(path)
            assets.append(dict(id=index, name=path.name, size=path.stat().st_size, state='uploaded',
                               digest='sha256:' + hashlib.sha256(path.read_bytes()).hexdigest(),
                               browser_download_url='https://github.com/mr-narender/immich/releases/download/v3.3.5-2/' + path.name))
        self.release = dict(id=42, tag_name='v3.3.5-2', immutable=True, draft=False, prerelease=False,
                            published_at='2026-10-30T00:00:00Z', assets=assets)

    def verify(self, release=None, ref=None):
        release = self.release if release is None else release
        ref = {'object': {'type': 'commit', 'sha': SHA}} if ref is None else ref
        def get(path, **kwargs):
            if path == '/releases/tags/v3.3.5-2':
                return release
            if path == '/git/ref/tags/v3.3.5-2':
                return ref
            self.fail('unexpected API path: ' + path)
        with mock.patch.object(self.checks, 'github_json', side_effect=get):
            self.checks.verify_published('3.3.5-2', SHA, '42', self.paths)

    def test_published_immutable_assets_match_real_local_hashes(self):
        self.verify()

    def test_mutable_draft_prerelease_wrong_tag_or_commit_refused(self):
        for field, value in [('immutable', False), ('immutable', 1), ('draft', True),
                             ('prerelease', True), ('id', 43), ('published_at', ''),
                             ('tag_name', 'v3.3.5')]:
            with self.subTest(field=field):
                release = copy.deepcopy(self.release); release[field] = value
                with self.assertRaises(ValueError):
                    self.verify(release=release)
        with self.assertRaises(ValueError):
            self.verify(ref={'object': {'type': 'commit', 'sha': 'b' * 40}})

    def test_missing_extra_duplicate_or_unverified_asset_refused(self):
        for assets in [self.release['assets'][:1], self.release['assets'] * 2,
                       [self.release['assets'][0]] * 2]:
            with self.subTest(assets=len(assets)):
                release = copy.deepcopy(self.release); release['assets'] = assets
                with self.assertRaises(ValueError):
                    self.verify(release=release)
        for field, value in [('id', 0), ('id', True), ('size', 1), ('state', 'new'),
                             ('digest', None), ('digest', 'sha256:' + '0' * 64),
                             ('browser_download_url', 'https://github.com/other/repo/file')]:
            with self.subTest(field=field):
                release = copy.deepcopy(self.release); release['assets'][0][field] = value
                with self.assertRaises(ValueError):
                    self.verify(release=release)
        self.paths[0].write_bytes(b'changed after upload')
        with self.assertRaises(ValueError):
            self.verify()

    def test_existing_release_or_tag_refused_before_publication(self):
        for present in ('/releases/tags/v3.3.5-2', '/git/ref/tags/v3.3.5-2'):
            with self.subTest(present=present), mock.patch.object(self.checks, 'github_json',
                    side_effect=lambda path, **kw: {'id': 42} if path == present else None):
                with self.assertRaises(ValueError):
                    self.checks.assert_unused('v3.3.5-2')

    def unused_with_inventory(self, pages):
        urls = []
        def get(req, *args, **kwargs):
            self.assertEqual(req.get_header('Authorization'), 'Bearer offline-fixture')
            url = req.full_url
            urls.append(url)
            if '/releases/tags/' in url or '/git/ref/tags/' in url:
                raise urllib.error.HTTPError(url, 404, 'missing', {}, io.BytesIO())
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(url).query)
            self.assertEqual(query['per_page'], ['100'])
            page = int(query['page'][0])
            self.assertLessEqual(page, len(pages), 'unexpected extra inventory request')
            value = pages[page - 1]
            if isinstance(value, Exception):
                raise value
            return value if isinstance(value, io.BytesIO) else response(value)
        with mock.patch.dict(os.environ, GITHUB_TOKEN='offline-fixture'), mock.patch.object(urllib.request.OpenerDirector, 'open', side_effect=get):
            self.checks.assert_unused('v3.3.5-2')
        return urls

    def test_draft_without_ref_or_published_release_is_not_unused(self):
        with self.assertRaisesRegex(ValueError, 'already exists'):
            self.unused_with_inventory([[{'tag_name': 'v3.3.5-2', 'draft': True}]])

    def test_matching_release_on_later_inventory_page_is_not_unused(self):
        first = [{'tag_name': 'v0.0.1', 'draft': False}] * 100
        with self.assertRaisesRegex(ValueError, 'already exists'):
            self.unused_with_inventory([first, [{'tag_name': 'v3.3.5-2', 'draft': True}]])

    def test_full_inventory_page_cap_refuses_incomplete_absence_claim(self):
        page = [{'tag_name': 'v0.0.1'}] * 100
        with self.assertRaisesRegex(ValueError, 'incomplete'):
            self.unused_with_inventory([page] * 10)

    def test_complete_empty_or_short_inventory_accepts_unused_target(self):
        for pages in ([[]], [[{'tag_name': 'v0.0.1'}] * 100, []],
                      [[{'tag_name': 'v0.0.1', 'draft': True}]]):
            with self.subTest(pages=len(pages)):
                urls = self.unused_with_inventory(pages)
                self.assertEqual(len(urls), 2 + len(pages))
                self.assertEqual(urls[-1], 'https://api.github.com/repos/mr-narender/immich/releases?per_page=100&page=' + str(len(pages)))

    def test_malformed_or_oversized_inventory_fails_closed(self):
        malformed = [{}, None, 'not a list', [None], [{}], [{'tag_name': None}],
                     [{'tag_name': ''}], [{'tag_name': 42}],
                     [{'tag_name': 'v0.0.1'}] * 101,
                     io.BytesIO(b'{broken'), io.BytesIO(b' ' * (1024 * 1024 + 1))]
        for value in malformed:
            with self.subTest(value=type(value).__name__):
                with self.assertRaises(ValueError):
                    self.unused_with_inventory([value])

    def test_inventory_http_errors_never_mean_unused(self):
        for status in (401, 403, 404, 429, 500):
            error = urllib.error.HTTPError('https://api.github.com', status, 'denied', {}, io.BytesIO())
            self.addCleanup(error.close)
            with self.subTest(status=status), self.assertRaises(urllib.error.HTTPError):
                self.unused_with_inventory([error])

    def test_missing_or_empty_token_refused_before_any_request(self):
        for env in ({}, {'GITHUB_TOKEN': ''}):
            with self.subTest(env=env), mock.patch.dict(os.environ, env, clear=True), mock.patch.object(urllib.request.OpenerDirector, 'open', return_value=response({})) as opened:
                with self.assertRaises((KeyError, ValueError)):
                    self.checks.github_json('/releases?per_page=100&page=1')
                opened.assert_not_called()

    def test_authenticated_redirects_never_make_a_second_request(self):
        for status in (301, 302, 303, 307, 308):
            for target in ('https://untrusted.invalid/token', 'http://api.github.com/token'):
                with self.subTest(status=status, target=target):
                    requests = []
                    def transport(req):
                        requests.append((req.full_url, req.get_header('Authorization')))
                        headers = Message()
                        headers['Location'] = target
                        result = urllib.response.addinfourl(io.BytesIO(b'{}'), headers,
                                                           req.full_url, status if len(requests) == 1 else 200)
                        result.msg = 'offline fixture'
                        return result
                    with mock.patch.dict(os.environ, {'GITHUB_TOKEN': 'offline-fixture'}, clear=True), mock.patch.object(urllib.request, '_opener', None), mock.patch.object(urllib.request.HTTPSHandler, 'https_open', side_effect=transport), mock.patch.object(urllib.request.HTTPHandler, 'http_open', side_effect=transport):
                        with self.assertRaises((ValueError, urllib.error.HTTPError)):
                            self.checks.github_json('/releases/tags/v3.3.5-2')
                    self.assertEqual(requests, [('https://api.github.com/repos/mr-narender/immich/releases/tags/v3.3.5-2', 'Bearer offline-fixture')])

    def test_api_denial_is_not_treated_as_unused(self):
        error = urllib.error.HTTPError('https://api.github.com', 403, 'denied', {}, io.BytesIO())
        self.addCleanup(error.close)
        with mock.patch.dict(os.environ, GITHUB_TOKEN='offline-fixture'), mock.patch.object(urllib.request.OpenerDirector, 'open', side_effect=error):
            with self.assertRaises(urllib.error.HTTPError):
                self.checks.github_json('/releases/tags/v3.3.5-2', missing_ok=True)


if __name__ == '__main__':
    unittest.main()
