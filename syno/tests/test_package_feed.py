"""Static catalog identity/link checks, not proof of publication or DSM registration."""
import json
from pathlib import Path
import re
import unittest

REPO = Path(__file__).resolve().parents[2]


class FeedTests(unittest.TestCase):
    def test_catalog_identity_version_architecture_and_pinned_links(self):
        feed = json.loads((REPO / 'packages.json').read_text())['packages']
        self.assertEqual(len(feed), 2)
        seen = set()
        for item in feed:
            self.assertEqual(item['id'], 'immich'); self.assertEqual(item['package'], 'immich')
            self.assertRegex(item['version'], r'^\d+\.\d+\.\d+-[1-9]\d*$')
            arch = 'x86_64' if 'x86_64' in item['arch'].split() else 'arm64'
            self.assertNotIn(arch, seen); seen.add(arch)
            self.assertTrue(item['arch'].split())
            app = item['version'].split('-')[0]
            expected = 'https://github.com/mr-narender/immich/releases/download/v%s/immich-%s-%s.spk' % (app, arch, item['version'])
            self.assertEqual(item['link'], expected)
        self.assertEqual(seen, {'x86_64', 'arm64'})
        self.assertEqual(feed[0]['version'], feed[1]['version'])
        self.assertFalse(set(feed[0]['arch'].split()) & set(feed[1]['arch'].split()))

    def test_no_unsupported_automatic_feed_registration_promise(self):
        hook = (REPO / 'syno/src/scripts/postinst').read_text()
        wizard = (REPO / 'syno/src/wizard/install_uifile').read_text()
        self.assertNotIn('/usr/syno/etc/packages/feeds.conf', hook)
        self.assertNotIn('WIZARD_ADD_FEED', wizard)
        self.assertNotIn('add the update feed automatically', wizard)


if __name__ == '__main__':
    unittest.main()
