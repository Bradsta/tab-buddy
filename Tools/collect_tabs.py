#!/usr/bin/env python3
"""Resumable, anonymous local research collection; never publishes material.

Usage: python3 Tools/collect_tabs.py gametabs|gprotab [--limit N]
       python3 Tools/collect_tabs.py gametabs|gprotab --status
Each source has one process, a durable SQLite queue, and a robots-aware limiter.
"""
import argparse
import fcntl
import gzip
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import sqlite3
import subprocess
import time
from urllib.parse import urljoin, urlsplit, urlunsplit, unquote
import xml.etree.ElementTree as ET
import zipfile
import io

ROOT = Path(__file__).resolve().parents[1] / '.local-tab-corpus'
AGENT = 'TabBuddyLocalCollector/1.0 (private tab compatibility research)'


class Page(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.links, self.text, self.title = [], [], []
        self.in_pre = self.in_title = False
        self.all_text = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == 'a' and a.get('href'):
            self.links.append(a['href'])
        if tag == 'pre' and a.get('id') == 'tab-text-view-text':
            self.in_pre = True
        if tag == 'title':
            self.in_title = True
        if tag == 'br' and self.in_pre:
            self.text.append('\n')

    def handle_endtag(self, tag):
        if tag == 'pre':
            self.in_pre = False
        if tag == 'title':
            self.in_title = False

    def handle_data(self, data):
        self.all_text.append(data)
        if self.in_pre:
            self.text.append(data)
        if self.in_title:
            self.title.append(data)


def robots_rules(text):
    """Our named agent falls under *, including wildcard/end-anchor rules."""
    rules, delay, agents, directives = [], 0, [], False
    for line in text.splitlines():
        line = line.split('#', 1)[0].strip()
        if ':' not in line:
            continue
        key, value = [p.strip() for p in line.split(':', 1)]
        key = key.lower()
        if key == 'user-agent':
            if directives:
                agents, directives = [], False
            agents.append(value.lower())
        else:
            directives = True
            if '*' not in agents:
                continue
            if key in ('allow', 'disallow') and value:
                pattern = '^' + re.escape(value).replace(r'\*', '.*')
                if value.endswith('$'):
                    pattern = pattern[:-2] + '$'
                rules.append((len(value.replace('*', '')), key == 'allow', re.compile(pattern)))
            if key == 'crawl-delay':
                delay = max(delay, float(value))
    return rules, delay


def permitted(url, rules):
    u = urlsplit(url)
    path = u.path + ('?' + u.query if u.query else '')
    matches = [(n, allow) for n, allow, pattern in rules if pattern.search(path)]
    return max(matches, default=(0, True))[1]


def canonical(base, href):
    u = urlsplit(urljoin(base, href))
    return urlunsplit((u.scheme, u.netloc, u.path, u.query, ''))


def binary_extension(data):
    if data.startswith(b'%PDF-'):
        return '.pdf'
    if b'FICHIER GUITAR PRO' in data[:80]:
        version = re.search(rb'v([345])', data[:80])
        return '.gp' + version[1].decode() if version else '.gp'
    if data[:4] in (b'BCFZ', b'BCFS'):
        return '.gpx'
    if data.startswith(b'PK'):
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            return '.gp' if any(n.endswith('.gpif') for n in z.namelist()) else '.zip'
    raise ValueError('Response is not a recognized Guitar Pro/PDF/archive file')


class Collector:
    def __init__(self, source):
        self.source = source
        self.base = 'https://' + ('gametabs.net' if source == 'gametabs' else 'gprotab.net')
        self.root = ROOT / source
        self.root.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(self.root / 'catalog.sqlite')
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.execute('''CREATE TABLE IF NOT EXISTS queue (
            url TEXT PRIMARY KEY, kind TEXT, priority INTEGER, status TEXT DEFAULT 'pending',
            attempts INTEGER DEFAULT 0, error TEXT, updated REAL)''')
        self.db.execute('''CREATE TABLE IF NOT EXISTS items (
            url TEXT PRIMARY KEY, path TEXT, sha256 TEXT, bytes INTEGER, title TEXT,
            source_page TEXT, rights TEXT, attachments_require_login INTEGER, fetched REAL)''')
        self.rules, self.delay, self.last_request = [], 5 if source == 'gametabs' else 2, 0

    def enqueue(self, url, kind, priority):
        if urlsplit(url).netloc != urlsplit(self.base).netloc:
            return
        self.db.execute('INSERT OR IGNORE INTO queue(url,kind,priority) VALUES (?,?,?)', (url,kind,priority))

    def fetch(self, url, robots=False):
        if not robots and not permitted(url, self.rules):
            raise PermissionError('Excluded by robots.txt')
        time.sleep(max(0, self.delay - (time.monotonic() - self.last_request)))
        self.last_request = time.monotonic()
        # No cookies, login automation, hidden APIs, or automatic redirect following.
        tmp = self.root / '.response.part'
        result = subprocess.run(['curl','--silent','--show-error','--max-time','45',
            '--max-filesize','20971520','--user-agent',AGENT,
            '--output',str(tmp),'--write-out','%{http_code}',url], capture_output=True, text=True)
        if result.returncode:
            raise OSError(result.stderr.strip())
        status = int(result.stdout)
        if status in (403, 429):
            raise PermissionError(f'HTTP {status}; source paused, no bypass or immediate retry')
        if status != 200:
            raise OSError(f'HTTP {status}')
        data = tmp.read_bytes()
        tmp.unlink()
        return data

    def save_item(self, url, data, ext, title, source_page, login=False):
        key = hashlib.sha256(url.encode()).hexdigest()[:20]
        slug = re.sub(r'[^a-zA-Z0-9_-]+', '-', unquote(urlsplit(source_page).path.split('/')[-1]))[:90]
        path = Path('files') / (slug + '-' + key + ext)
        destination = self.root / path
        destination.parent.mkdir(exist_ok=True)
        temp = destination.with_suffix(destination.suffix + '.part')
        temp.write_bytes(data)
        temp.replace(destination)
        self.db.execute('INSERT OR REPLACE INTO items VALUES (?,?,?,?,?,?,?,?,?)',
            (url,str(path),hashlib.sha256(data).hexdigest(),len(data),title,source_page,
             'local-research-only; commercial redistribution not cleared',int(login),time.time()))

    def process(self, url, kind):
        data = self.fetch(url)
        if kind == 'sitemap':
            if data[:2] == b'\x1f\x8b':
                data = gzip.decompress(data)
            xml = ET.fromstring(data)
            index = xml.tag.endswith('sitemapindex')
            for node in xml.iter():
                if not node.tag.endswith('}loc') or not node.text:
                    continue
                link = node.text.strip()
                if index:
                    self.enqueue(link, 'sitemap', 0)
                elif '/tabs/' in link:
                    is_song = self.source == 'gametabs' and len(urlsplit(link).path.strip('/').split('/')) >= 3
                    self.enqueue(link, 'page', 10 if is_song else 20)
            return
        if kind == 'download':
            self.save_item(url,data,binary_extension(data),'',url.split('?')[0])
            return
        page = Page()
        page.feed(data.decode('utf-8',errors='replace'))
        title = ''.join(page.title).strip()
        if self.source == 'gametabs':
            tab = ''.join(page.text)
            is_song = len(urlsplit(url).path.strip('/').split('/')) >= 3
            for href in page.links:
                link = canonical(url, href)
                if urlsplit(link).path.startswith('/tabs/') and not urlsplit(link).query:
                    self.enqueue(link, 'page', 10 if len(urlsplit(link).path.strip('/').split('/')) >= 3 else 20)
            if is_song and not tab.strip():
                raise ValueError('No public tab text found')
            login = 'Log in to download files' in ''.join(page.all_text)
            if tab.strip():
                self.save_item(url,tab.encode(),'.txt',title,url,login)
        else:
            for href in page.links:
                link = canonical(url,href)
                u = urlsplit(link)
                if u.path.startswith('/en/tabs/'):
                    if u.query == 'download':
                        self.enqueue(link,'download',1)
                    elif not u.query or re.fullmatch(r'page=\d+',u.query):
                        self.enqueue(link,'page',10 if len(u.path.strip('/').split('/')) >= 4 else 20)
        # Preserve the source page for attribution and later metadata extraction.
        folder = self.root / 'pages'
        folder.mkdir(exist_ok=True)
        key = hashlib.sha256(url.encode()).hexdigest()
        (folder / (key + '.html.gz')).write_bytes(gzip.compress(data))

    def status(self):
        result = dict(self.db.execute('SELECT status,count(*) FROM queue GROUP BY status'))
        result['files'],result['bytes'] = self.db.execute('SELECT count(*),coalesce(sum(bytes),0) FROM items').fetchone()
        result['attachments_require_login'] = self.db.execute('SELECT count(*) FROM items WHERE attachments_require_login=1').fetchone()[0]
        result['source'] = self.source
        return result

    def run(self, limit):
        lock = (self.root / 'collector.lock').open('w')
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        raw = self.fetch(self.base + '/robots.txt', robots=True)
        (self.root / 'robots.txt').write_bytes(raw)
        self.rules, declared = robots_rules(raw.decode())
        self.delay = max(self.delay, declared)
        self.enqueue(self.base + '/sitemap.xml','sitemap',0)
        self.db.commit()
        completed = 0
        while not limit or completed < limit:
            row = self.db.execute("SELECT url,kind,attempts FROM queue WHERE status='pending' ORDER BY priority,rowid LIMIT 1").fetchone()
            if not row:
                break
            url,kind,attempts = row
            status,error,stop = 'done',None,False
            try:
                self.process(url,kind)
            except PermissionError as exc:
                error = str(exc)
                status = 'blocked'
                stop = 'HTTP' in error
            except Exception as exc:
                error = str(exc)
                status = 'failed' if attempts >= 2 or isinstance(exc, ValueError) else 'pending'
                if status == 'pending':
                    time.sleep(15 * (attempts + 1))
            self.db.execute('UPDATE queue SET status=?,attempts=attempts+1,error=?,updated=? WHERE url=?',
                            (status,error,time.time(),url))
            self.db.commit()
            completed += 1
            print(json.dumps(dict(self.status(),last_url=url,error=error)),flush=True)
            if stop:
                break
        print(json.dumps(dict(self.status(),run_finished=True)),flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source',choices=['gametabs','gprotab'])
    parser.add_argument('--limit',type=int,default=0,help='Requests to process this run; 0 processes the queue')
    parser.add_argument('--status',action='store_true')
    args = parser.parse_args()
    collector = Collector(args.source)
    if args.status:
        print(json.dumps(collector.status(),indent=2))
    else:
        collector.run(args.limit)
