import hashlib
from pathlib import Path
import sqlite3
import tempfile
import unittest
import prepare_tab_library as p

class LibraryNamingTests(unittest.TestCase):
    def test_source_titles_and_safe_unicode(self):
        self.assertEqual(p.names('gametabs', "Gametabs | Zelda: Ocarina of Time, Zelda&#x27;s Lullaby", '', '/tabs/zelda/lullaby'), ('Zelda - Ocarina of Time', "Zelda's Lullaby"))
        self.assertEqual(p.names('gprotab', '', "<title>GProTab.net | Guitar Pro tab for 'Don't stop' song by AC/DC</title>", '/en/tabs/acdc/dont-stop'), ('AC - DC', "Don't stop"))
        self.assertLessEqual(len(p.clean('音'*200).encode()), 180)
        self.assertNotIn('/', p.clean('../bad/name'))

    def test_versions_resume_and_preserve_content(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder); raw=root/'gametabs';raw.mkdir()
            db=sqlite3.connect(raw/'catalog.sqlite')
            db.execute('CREATE TABLE items(url,path,sha256,title,source_page)')
            for i in range(2):
                data=f'original tab {i}'.encode();(raw/f'{i}.txt').write_bytes(data)
                db.execute('INSERT INTO items VALUES (?,?,?,?,?)',(f'url{i}',f'{i}.txt',hashlib.sha256(data).hexdigest(),'Gametabs | Game, Song',f'https://gametabs.net/tabs/game/song-{i}'))
            db.commit();db.close()
            self.assertEqual(p.prepare(root)['added'],2)
            output=root/'import-ready/gametabs/Game'
            self.assertEqual({f.name for f in output.iterdir()}, {'Game - Song.txt','Game - Song (Version 2).txt'})
            enriched = (output/'Game - Song.txt').read_bytes()
            self.assertTrue(enriched.startswith(b'[TabBuddy Metadata v1]'))
            self.assertTrue(enriched.endswith(b'original tab 0'))
            self.assertIn(b'Source: GameTabs', enriched)
            self.assertEqual((raw/'0.txt').read_bytes(), b'original tab 0')
            self.assertEqual(p.prepare(root)['added'],0)
            self.assertTrue((raw/'0.txt').exists())
            edited = output/'Game - Song.txt'
            edited.write_bytes(b'User-edited score')
            manifest = sqlite3.connect(root/'import-ready/.manifest.sqlite')
            manifest.execute('UPDATE files SET metadata_version=0')
            manifest.commit();manifest.close()
            result = p.prepare(root)
            self.assertEqual(len(result['errors']), 1)
            self.assertIn('preserving user changes', result['errors'][0]['error'])
            self.assertEqual(edited.read_bytes(), b'User-edited score')
