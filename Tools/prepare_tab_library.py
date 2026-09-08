#!/usr/bin/env python3
"""Create a resumable, readable local import collection without changing raw crawl files."""
import argparse
import gzip
import hashlib
import html
import json
from pathlib import Path
import re
import shutil
import subprocess
import os
import sqlite3
import time
import unicodedata
from urllib.parse import unquote, urlsplit
import fcntl

PROJECT = Path(__file__).resolve().parents[1]
ROOT = PROJECT / '.local-tab-corpus'
METADATA_VERSION = 2


def metadata_tool():
    binary = PROJECT / '.local-tab-corpus' / 'embed-metadata'
    sources = [PROJECT / 'TabBuddy/EmbeddedScoreMetadata.swift', PROJECT / 'Tools/embed_score_metadata.swift']
    binary.parent.mkdir(parents=True, exist_ok=True)
    if not binary.exists() or any(p.stat().st_mtime > binary.stat().st_mtime for p in sources):
        subprocess.run(['xcrun', 'swiftc', '-module-cache-path', '/tmp/tabbuddy-swift-cache', '-D', 'METADATA_STANDALONE', *map(str, sources), '-o', str(binary)], check=True)
    return subprocess.Popen([str(binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)



def clean(value, limit=180):
    value = unicodedata.normalize('NFC', html.unescape(value))
    value = re.sub(r'[<>:"/\\|?*\x00-\x1f]', ' - ', value)
    value = re.sub(r'\s+', ' ', value).strip(' .-') or 'Untitled'
    while len(value.encode('utf-8')) > limit:
        value = value[:-1]
    return value.rstrip(' .-')


def names(source, title, page, url):
    titles = re.findall(r'<title[^>]*>(.*?)</title>', page, re.S | re.I)
    title = html.unescape(titles[0] if titles else title).strip()
    parts = [unquote(p) for p in urlsplit(url).path.split('/') if p]
    if source == 'gprotab':
        match = re.search(r"Guitar Pro tab for '(.*)' song by (.*)", title, re.S)
        if match:
            return clean(match[2]), clean(match[1])
    else:
        title = re.sub(r'^Gametabs\s*\|\s*', '', title, flags=re.I)
        headings = re.findall(r'<h1[^>]*>(.*?)</h1>', page, re.S | re.I)
        song = html.unescape(re.sub('<[^>]+>', '', headings[0])).strip() if headings else ''
        if song and title.endswith(', ' + song):
            return clean(title[:-len(song)-2]), clean(song)
        if ', ' in title:
            group, song = title.split(', ', 1)
            return clean(group), clean(song)
    return clean(parts[-2].replace('-', ' ').title()), clean(parts[-1].replace('-', ' ').title())


def prepare(root=ROOT):
    output = root / 'import-ready'
    output.mkdir(parents=True, exist_ok=True)
    with (output / '.organizer.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        db = sqlite3.connect(output / '.manifest.sqlite')
        db.execute('CREATE TABLE IF NOT EXISTS files (source TEXT, url TEXT, path TEXT, path_key TEXT UNIQUE, sha256 TEXT, PRIMARY KEY(source,url))')
        columns = {row[1] for row in db.execute("PRAGMA table_info(files)")}
        for name, declaration in [("output_sha256", "TEXT"), ("metadata_version", "INTEGER DEFAULT 0")]:
            if name not in columns:
                db.execute(f"ALTER TABLE files ADD COLUMN {name} {declaration}")
        db.commit()
        helper = None
        added = 0
        errors = []
        for source in ['gametabs', 'gprotab']:
            catalog = root / source / 'catalog.sqlite'
            if not catalog.exists():
                continue
            source_db = sqlite3.connect(f'file:{catalog}?mode=ro', uri=True)
            rows = source_db.execute('SELECT url,path,sha256,title,source_page FROM items').fetchall()
            source_db.close()
            for url, raw_path, digest, title, page_url in rows:
                previous = db.execute('SELECT path,sha256,output_sha256,metadata_version FROM files WHERE source=? AND url=?', (source,url)).fetchone()
                if previous and previous[1] == digest and previous[3] == METADATA_VERSION and (output / previous[0]).exists():
                    continue
                try:
                    raw = root / source / raw_path
                    if hashlib.sha256(raw.read_bytes()).hexdigest() != digest:
                        raise ValueError('Raw content does not match catalog checksum')
                    page_path = root / source / 'pages' / (hashlib.sha256(page_url.encode()).hexdigest() + '.html.gz')
                    page = gzip.decompress(page_path.read_bytes()).decode('utf-8', errors='replace') if page_path.exists() else ''
                    group, song = names(source, title, page, page_url)
                    stem = clean(group + ' - ' + song, 215)
                    relative = Path(source) / group / (stem + raw.suffix.lower())
                    version = 1
                    while not previous:
                        key = unicodedata.normalize('NFD', str(relative)).casefold()
                        if not db.execute('SELECT 1 FROM files WHERE path_key=?', (key,)).fetchone() and not (output / relative).exists():
                            break
                        version += 1
                        relative = Path(source) / group / (stem + f' (Version {version})' + raw.suffix.lower())
                    if previous:
                        relative = Path(previous[0])
                    target = output / relative
                    if target.exists() and previous:
                        expected = previous[2] or previous[1]
                        if hashlib.sha256(target.read_bytes()).hexdigest() != expected:
                            raise ValueError('Prepared file was edited; preserving user changes')
                    target.parent.mkdir(parents=True, exist_ok=True)
                    temp = target.with_suffix(target.suffix + '.partial')
                    if raw.suffix.lower() in ['.txt', '.gp3', '.gp4', '.gp5']:
                        if helper is None:
                            helper = metadata_tool()
                        metadata = {'title': song, 'sourceName': 'GameTabs' if source == 'gametabs' else 'GProTab', 'sourceURL': page_url, 'sourceID': urlsplit(page_url).path}
                        metadata['collection' if source == 'gametabs' else 'artist'] = group
                        helper.stdin.write(json.dumps({'input': str(raw.resolve()), 'output': str(temp.resolve()), 'metadata': metadata}) + '\n')
                        helper.stdin.flush()
                        response = json.loads(helper.stdout.readline())
                        if not response.get('ok'):
                            raise ValueError(response.get('error', 'Metadata helper failed'))
                    else:
                        shutil.copyfile(raw, temp)
                    output_digest = hashlib.sha256(temp.read_bytes()).hexdigest()
                    temp.replace(target)
                    db.execute('INSERT OR REPLACE INTO files (source,url,path,path_key,sha256,output_sha256,metadata_version) VALUES (?,?,?,?,?,?,?)',
                               (source,url,str(relative),unicodedata.normalize('NFD', str(relative)).casefold(),digest,output_digest,METADATA_VERSION))
                    db.commit()
                    added += 1
                except Exception as exc:
                    errors.append({'source':source,'url':url,'error':str(exc)})
        if helper is not None:
            helper.stdin.close()
            helper.wait(timeout=10)
            helper.stdout.close()
        totals = dict(db.execute('SELECT source,count(*) FROM files GROUP BY source'))
        manifest = [{'source':s,'source_url':u,'path':p,'raw_sha256':h,'sha256':o,'metadata_version':v} for s,u,p,h,o,v in db.execute('SELECT source,url,path,sha256,output_sha256,metadata_version FROM files ORDER BY path')]
        temp = output / '.manifest.json.partial'
        temp.write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
        temp.replace(output / 'manifest.json')
        db.close()
        result = {'added':added,'totals':totals,'errors':errors}
        (output / 'status.json').write_text(json.dumps(result,indent=2))
        return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--watch', action='store_true')
    args = parser.parse_args()
    while True:
        print(json.dumps(prepare()), flush=True)
        if not args.watch:
            break
        time.sleep(60)
