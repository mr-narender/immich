"""Read-only DSM WSGI catalog adapter. No listener, installation or activation.

Mount `application` behind an independently approved HTTPS host. The public raw
catalog is input, not a DSM endpoint; DSM compatibility still needs runtime tests.
"""
import json
import re
import urllib.parse
import urllib.request

CATALOG_URL = 'https://raw.githubusercontent.com/mr-narender/immich/main/packages.json'
REPOSITORY = 'https://github.com/mr-narender/immich'
MAX_CATALOG = 256 * 1024
MIN_BUILD = 64561  # Current standalone INFO: DSM 7.2-64561; installer INFO remains authoritative.
ARCHES = {
    'x86_64': frozenset('x86_64 bromolow cedarview avoton grantley broadwell broadwellnk broadwellnkv2 broadwellds apollolake denverton purley coffeelake skylaked geminilake v1000 r1000 epyc7002'.split()),
    'arm64': frozenset('arm64 aarch64 rtd1296 rtd1619b armada37xx ac7613 ac7565'.split()),
}
VERSION = re.compile(r'(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})-([1-9][0-9]{0,8})\Z')


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise ValueError('catalog redirects are not allowed')


def load_catalog():
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    with opener.open(urllib.request.Request(CATALOG_URL, headers={'User-Agent':'immich-dsm-feed'}), timeout=10) as r:
        body = r.read(MAX_CATALOG + 1)
    if len(body) > MAX_CATALOG:
        raise ValueError('catalog too large')
    return json.loads(body)


class RequestError(Exception):
    def __init__(self, status):
        self.status = status


def parameters(environ):
    method = environ.get('REQUEST_METHOD', '')
    if method not in ('GET', 'POST'):
        raise RequestError('405 Method Not Allowed')
    query = environ.get('QUERY_STRING', '')
    if len(query) > 4096:
        raise RequestError('414 URI Too Long')
    if method == 'POST':
        if environ.get('CONTENT_TYPE', '').split(';')[0].strip().lower() != 'application/x-www-form-urlencoded':
            raise RequestError('415 Unsupported Media Type')
        length = environ.get('CONTENT_LENGTH', '')
        if not length:
            raise RequestError('411 Length Required')
        if not re.fullmatch('[0-9]{1,9}', length):
            raise RequestError('400 Bad Request')
        length = int(length)
        if length > 8192:
            raise RequestError('413 Content Too Large')
        body = environ['wsgi.input'].read(length)
        if len(body) != length:
            raise RequestError('400 Bad Request')
        try:
            query = '&'.join(part for part in (query, body.decode('utf-8')) if part)
        except UnicodeError:
            raise RequestError('400 Bad Request') from None
    try:
        fields = urllib.parse.parse_qs(query, keep_blank_values=True, strict_parsing=True,
                                     max_num_fields=32, encoding='utf-8', errors='strict')
    except (ValueError, UnicodeError):
        raise RequestError('400 Bad Request') from None
    if any(len(values) != 1 for values in fields.values()):
        raise RequestError('400 Bad Request')
    arch = fields.get('arch', [''])[0]
    build = fields.get('build', [''])[0]
    language = fields.get('language', ['enu'])[0]
    if (not any(arch in names for names in ARCHES.values()) or
            not re.fullmatch('[0-9]{5,8}', build) or not re.fullmatch('[a-z]{2,3}', language)):
        raise RequestError('400 Bad Request')
    if int(build) < MIN_BUILD:
        raise RequestError('422 Unprocessable Content')
    return arch


def select_package(catalog, device_arch):
    if not isinstance(catalog, dict) or set(catalog) != {'packages'}:
        raise ValueError('invalid catalog')
    packages = catalog['packages']
    if not isinstance(packages, list) or not 1 <= len(packages) <= 16:
        raise ValueError('invalid package list')
    native = next(key for key, aliases in ARCHES.items() if device_arch in aliases)
    selected = []
    versions = set()
    for item in packages:
        if not isinstance(item, dict):
            raise ValueError('invalid package metadata')
        for field in ('id','package','version','arch','link','dname','desc','maintainer','distributor','distributor_url'):
            value = item.get(field)
            if not isinstance(value, str) or not value or len(value) > 8192:
                raise ValueError('missing or oversized package metadata')
        if item['id'] != 'immich' or item['package'] != 'immich' or item['distributor'] != 'mr-narender' or item['distributor_url'] != REPOSITORY:
            raise ValueError('wrong package identity')
        if type(item.get('update_protocol')) is not int or item['update_protocol'] != 1:
            raise ValueError('unsupported update preservation protocol')
        if not VERSION.fullmatch(item['version']):
            raise ValueError('invalid stable package version')
        versions.add(item['version'])
        for key in ('qinst','qstart','qupgrade'):
            if item.get(key) is not True:
                raise ValueError('missing native package capabilities')
        names = item['arch'].split()
        families = [key for key, aliases in ARCHES.items() if names and set(names) <= aliases]
        if len(families) != 1 or len(set(names)) != len(names):
            raise ValueError('invalid architecture metadata')
        family = families[0]
        app = item['version'].split('-')[0]
        expected = REPOSITORY + '/releases/download/v' + app + '/immich-' + family + '-' + item['version'] + '.spk'
        if item['link'] != expected:
            raise ValueError('unapproved artifact URL')
        if family == native and (device_arch in names or device_arch in ('x86_64','arm64','aarch64')):
            selected.append(item)
    if len(selected) != 1 or len(versions) != 1:
        raise ValueError('missing or ambiguous package')
    return {'packages':selected}


def application(environ, start_response):
    try:
        arch = parameters(environ)
        body = json.dumps(select_package(load_catalog(), arch), separators=(',', ':')).encode()
        if len(body) > MAX_CATALOG:
            raise ValueError('response too large')
        status = '200 OK'
    except RequestError as error:
        status = error.status
        body = b'{"packages":[],"error":"unsupported-request"}'
    except Exception:
        status = '503 Service Unavailable'
        body = b'{"packages":[],"error":"catalog-unavailable"}'
    headers = [('Content-Type','application/json; charset=utf-8'), ('Content-Length',str(len(body))),
               ('Cache-Control','no-store'), ('X-Content-Type-Options','nosniff')]
    if status.startswith('405'):
        headers.append(('Allow','GET, POST'))
    start_response(status, headers)
    return [body]
