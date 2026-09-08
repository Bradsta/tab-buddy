"""Offline acquisition checks; run: python3 -m unittest discover -s Tools -p 'test_collect_tabs.py'."""
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import collect_tabs as c


class CollectorTests(unittest.TestCase):
    def test_robots_groups_wildcards_and_specific_allow(self):
        rules, delay = c.robots_rules('''User-agent: GPTBot
Disallow: /
User-agent: *
Disallow: /api/
Disallow: /tabs?*
Disallow: /*.php$
Allow: /api/public
Crawl-delay: 5
''')
        self.assertEqual(delay, 5)
        for path in ['/tabs/game/song', '/api/public']:
            self.assertTrue(c.permitted('https://gametabs.net' + path, rules))
        for path in ['/tabs?q=a', '/api/private', '/old.php']:
            self.assertFalse(c.permitted('https://gametabs.net' + path, rules))

    def test_preserves_tab_whitespace_and_entities(self):
        page = c.Page()
        page.feed('<pre>ignore</pre><pre id="tab-text-view-text"><span>  E|--0--|\n</span>  B|--1--|<br>A &amp; B</pre>footer')
        self.assertEqual(''.join(page.text), '  E|--0--|\n  B|--1--|\nA & B')

    def test_rejects_html_as_guitar_pro(self):
        with self.assertRaises(ValueError):
            c.binary_extension(b'<html>Sign in</html>')
        self.assertEqual(c.binary_extension(b'\x18FICHIER GUITAR PRO v4.06'), '.gp4')
        self.assertEqual(c.binary_extension(b'BCFZ123'), '.gpx')
        archive = io.BytesIO()
        with zipfile.ZipFile(archive, 'w') as z:
            z.writestr('Content/score.gpif', '<GPIF/>')
        self.assertEqual(c.binary_extension(archive.getvalue()), '.gp')

    def test_catalog_is_distinct_from_song_and_queue_resumes(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(c, 'ROOT', Path(folder)):
            collector = c.Collector('gametabs')
            song = 'https://gametabs.net/tabs/example/exercise'
            with patch.object(collector, 'fetch', return_value=b'<a href="/tabs/example/exercise">Exercise</a>'):
                collector.process('https://gametabs.net/tabs/example', 'page')
            self.assertEqual(collector.status()['files'], 0)
            collector.db.commit()
            collector.db.close()
            resumed = c.Collector('gametabs')
            self.assertEqual(resumed.db.execute('SELECT url FROM queue').fetchone()[0], song)
            with patch.object(resumed, 'fetch', return_value=b'<pre id="tab-text-view-text">E|--0--|\nB|--1--|</pre>Log in to download files'):
                resumed.process(song, 'page')
            item = resumed.db.execute('SELECT path,attachments_require_login FROM items').fetchone()
            self.assertEqual((resumed.root / item[0]).read_text(), 'E|--0--|\nB|--1--|')
            self.assertEqual(item[1], 1)
            resumed.db.close()


if __name__ == '__main__':
    unittest.main()
