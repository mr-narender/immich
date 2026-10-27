"""Actual offline WSGI GET/form-POST calls, with only public catalog loading replaced."""
import copy
import importlib.util
import io
import json
from pathlib import Path
import unittest
from unittest import mock
from wsgiref.util import setup_testing_defaults
from wsgiref.validate import validator

REPO = Path(__file__).resolve().parents[2]
PATH = REPO / 'syno/package_feed.py'
f = None
if PATH.exists():
    spec = importlib.util.spec_from_file_location('package_feed', PATH)
    f = importlib.util.module_from_spec(spec); spec.loader.exec_module(f)


class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(f, 'read-only DSM feed adapter is missing')
        self.catalog = json.loads((REPO / 'packages.json').read_text())
        for item in self.catalog['packages']:
            item['update_protocol'] = 1

    def request(self, method='GET', query='arch=geminilake&build=72806&language=enu', body=b'', content_type='application/x-www-form-urlencoded', length=None, catalog=None):
        env = {}; setup_testing_defaults(env)
        env.update(REQUEST_METHOD=method, QUERY_STRING=query, CONTENT_TYPE=content_type,
                   CONTENT_LENGTH=str(len(body)) if length is None else length)
        env['wsgi.input'] = io.BytesIO(body)
        response = {}
        def start(status, headers, exc_info=None):
            response['status'] = int(status.split()[0]); response['headers'] = dict(headers)
        with mock.patch.object(f, 'load_catalog', return_value=self.catalog if catalog is None else catalog) as loader:
            result = validator(f.application)(env, start)
            try:
                response['body'] = json.loads(b''.join(result))
            finally:
                result.close()
            response['loads'] = loader.call_count
        return response

    def test_existing_published_catalog_is_refused_without_protocol(self):
        current = json.loads((REPO / 'packages.json').read_text())
        self.assertEqual(self.request(catalog=current)['status'], 503)

    def test_wrong_boolean_or_missing_protocol_is_refused(self):
        for marker in (None, 0, 2, True, False, '1'):
            data = copy.deepcopy(self.catalog)
            if marker is None:
                del data['packages'][0]['update_protocol']
            else:
                data['packages'][0]['update_protocol'] = marker
            response = self.request(catalog=data)
            self.assertEqual(response['status'], 503, repr(marker))
            self.assertEqual(response['body']['packages'], [])

    def test_get_filters_exactly_one_x86_package(self):
        r = self.request()
        self.assertEqual(r['status'], 200); self.assertEqual(r['loads'], 1)
        self.assertEqual(len(r['body']['packages']), 1)
        self.assertIn('immich-x86_64-', r['body']['packages'][0]['link'])
        self.assertEqual(r['headers']['Content-Type'], 'application/json; charset=utf-8')

    def test_form_post_filters_exactly_one_arm_package(self):
        r = self.request(method='POST', query='', body=b'arch=rtd1296&build=72806&language=enu')
        self.assertEqual(r['status'], 200)
        self.assertEqual(len(r['body']['packages']), 1)
        self.assertIn('immich-arm64-', r['body']['packages'][0]['link'])

    def test_invalid_unsupported_or_duplicate_dsm_fields_fail_before_loading(self):
        for query in ['arch=unknown&build=72806', 'arch=geminilake&build=-1', 'arch=geminilake&build=72806&build=72807', 'arch=geminilake', 'arch=geminilake&build=72806&language=../../x']:
            r = self.request(query=query)
            self.assertEqual(r['status'], 400); self.assertEqual(r['loads'], 0)
            self.assertEqual(r['body']['packages'], [])
        r = self.request(query='arch=geminilake&build=64560')
        self.assertEqual(r['status'], 422); self.assertEqual(r['loads'], 0)

    def test_request_method_size_content_type_and_short_read_limits(self):
        for kw, expected in [({'method':'DELETE'},405), ({'query':'x'*5000},414),
                             ({'method':'POST','query':'','body':b'x'*9000},413),
                             ({'method':'POST','query':'','body':b'{}','content_type':'application/json'},415),
                             ({'method':'POST','query':'','length':''},411),
                             ({'method':'POST','query':'','body':b'arch=x','length':'200'},400)]:
            r = self.request(**kw)
            self.assertEqual(r['status'], expected); self.assertEqual(r['loads'], 0)

    def test_bad_identity_version_arch_link_and_missing_metadata_fail_closed(self):
        for field, value in [('package','other'), ('id','other'), ('version','3.3.6-beta'),
                             ('arch','x86_64 rtd1296'), ('link','http://github.com/a'),
                             ('link','https://github.com/mr-narender/immich/releases/download/v3.3.6/immich-x86_64-3.3.6-1.spk'),
                             ('link','https://github.com/mr-narender/immich/releases/download/v3.3.5/immich-arm64-3.3.5-1.spk'),
                             ('link','https://github.com/other/repo/releases/download/v3.3.5/immich-x86_64-3.3.5-1.spk'),
                             ('dname',None), ('maintainer',None)]:
            data = copy.deepcopy(self.catalog)
            if value is None:
                del data['packages'][0][field]
            else:
                data['packages'][0][field] = value
            r = self.request(catalog=data)
            self.assertEqual(r['status'], 503, field)
            self.assertEqual(r['body']['packages'], [])

    def test_ambiguous_package_and_missing_architecture_fail_closed(self):
        data = copy.deepcopy(self.catalog); data['packages'].append(copy.deepcopy(data['packages'][0]))
        self.assertEqual(self.request(catalog=data)['status'], 503)
        data = copy.deepcopy(self.catalog); data['packages'] = [data['packages'][1]]
        self.assertEqual(self.request(catalog=data)['status'], 503)

    def test_public_catalog_fetch_has_pinned_https_limits_and_no_redirects(self):
        body = json.dumps(self.catalog).encode()
        response = mock.MagicMock(); response.__enter__.return_value = response
        response.read.return_value = body
        opener = mock.Mock(); opener.open.return_value = response
        with mock.patch.object(f.urllib.request, 'build_opener', return_value=opener):
            self.assertEqual(f.load_catalog(), self.catalog)
        req = opener.open.call_args.args[0]
        self.assertEqual(req.full_url, 'https://raw.githubusercontent.com/mr-narender/immich/main/packages.json')
        self.assertEqual(opener.open.call_args.kwargs['timeout'], 10)
        response.read.assert_called_once_with(256*1024+1)
        with self.assertRaises(ValueError):
            f.NoRedirect().redirect_request(None, None, 302, '', {}, 'https://evil.example/catalog')

    def test_upstream_failure_is_bounded_and_never_echoes_exception(self):
        env = {}; setup_testing_defaults(env); env['QUERY_STRING'] = 'arch=geminilake&build=72806'
        response = {}
        def start(status, headers):
            response['status'] = int(status.split()[0])
        with mock.patch.object(f, 'load_catalog', side_effect=OSError('do not print this secret')):
            body = b''.join(f.application(env, start))
        self.assertEqual(response['status'], 503)
        self.assertLess(len(body), 300); self.assertNotIn(b'secret', body)


if __name__ == '__main__':
    unittest.main()
