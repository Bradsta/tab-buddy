# Local tab acquisition

`collect_tabs.py` collects publicly accessible tabs for local compatibility research. It is not an app feature, a redistribution license, or a publishing pipeline. ClassTab is deliberately excluded because the user already has its archive; no existing-library inventory or deduplication is performed.

## Sources and boundaries

- **GameTabs:** traverses its published sitemaps and preserves the public tab text, original page, source URL, and whether attachments require login. It does not enter `/api/` or download-preparation routes, automate login, or fetch protected attachments. Its published general crawler delay is five seconds.
- **GProTab.net:** traverses the sitemap and linked artist/song pages, then follows public `?download` links. It validates basic file signatures and preserves each source page. It waits at least two seconds between requests, or longer if robots.txt requests it. This is GProTab.net, not Arobas Music's Guitar Pro storefront.
- Each source's robots.txt is fetched at the beginning of a run. Disallowed URLs are recorded as blocked. HTTP 403/429 pauses that source; redirects are recorded as failures rather than followed into unreviewed locations. Transient failures receive bounded retries.
- GameTabs text extraction preserves whitespace and credits within its tab block. Unsupported layouts are failures, not empty "successful" downloads. File attachments listed behind login remain unavailable in this anonymous pass.

## Storage and operation

Everything downloaded lives in `.local-tab-corpus/<source>/`, which is ignored by git and sits outside Xcode's app and test fixture directories:

- `files/`: individual text/Guitar Pro files or source ZIPs.
- `pages/`: compressed original HTML for attribution and subsequent metadata extraction.
- `catalog.sqlite`: source URLs, local paths, SHA-256 hashes, byte counts, timestamps, rights status, and the durable download queue.
- `robots.txt`: source policy snapshot for the run.
- `collector.log` and `collector.pid`: output and process ID when launched in the background.

Run from the repository root:

```sh
python3 Tools/collect_tabs.py gametabs
python3 Tools/collect_tabs.py gprotab
```

Run sources as separate processes; each source holds an exclusive lock to prevent duplicate collectors. Re-running resumes pending entries. `--limit 10` processes ten queue entries for a pilot; sitemap and page requests count toward that limit. Failed/blocked records remain for review rather than being silently retried on every restart.

```sh
python3 Tools/collect_tabs.py gametabs --status
python3 Tools/collect_tabs.py gprotab --status
```

To stop a background collector, verify its PID against `collector.pid` and terminate that process. Restart with the commands above. Mac sleep, network loss, and logout can interrupt collection; pending work is retained. A completed queue means the reachable sitemap/link traversal finished, not proof that every historical tab or protected attachment was obtained.

## Rehosting research (not cleared or deployed)

GProTab's [rules/disclaimer](https://gprotab.net/en/pages/rules) limit files to private study, scholarship, or research. Neither that language nor free public access grants commercial redistribution rights. GameTabs has no verified commercial redistribution grant in this research. All collected entries therefore default to **local research only; commercial redistribution not cleared**.

Before any public library, obtain grants covering the underlying compositions and the contributed arrangements/transcriptions as applicable, plus catalog reuse. A site operator may not own all of those rights. Keep permission evidence, attribution requirements, license version, territory, and any expiry with each approved item. No permissions have been requested or obtained by this tool.

For genuinely reusable material, [Mutopia](https://www.mutopiaproject.org/legal.html) explicitly offers public-domain, CC BY, and CC BY-SA scores; examine each score's own license and jurisdiction before inclusion. Those are a separate potential catalog, not permission to republish GameTabs or GProTab downloads.

[Cloudflare Workers Static Assets](https://developers.cloudflare.com/workers/static-assets/) can serve a curated licensed collection. A growing catalog could instead use [R2 with a Worker binding](https://developers.cloudflare.com/r2/api/workers/workers-api-usage/). Hosting technology does not grant content rights. Keep any eventual public assets in a separately generated, explicitly approved export; never point deployment at this private corpus. Nothing has been uploaded or deployed.

## Readable import collection

`python3 Tools/prepare_tab_library.py` creates `.local-tab-corpus/import-ready/`:

- `gametabs/<Game>/<Game> - <Song>.txt`
- `gprotab/<Artist>/<Artist> - <Song>.<original format>`

Names come from saved source-page titles, preserving their spelling/capitalization. URL words are the fallback when a page title is unavailable. Unsupported filename characters are replaced, Unicode is preserved, and alternate arrangements receive `(Version 2)`, etc. These numbers distinguish local files; they do not imply source quality or revision order.

The organizer verifies raw crawl checksums, then embeds missing titles/collections and source references into separate TXT/GP3–5 import copies using the same Swift codec as the app. Existing credits are retained; text bodies and GP musical data remain byte-identical. Other formats are copied unchanged. It never edits the raw archive or crawl queues. User-modified import copies are preserved and reported as conflicts. `manifest.json` records raw/output checksums and enrichment version; `.manifest.sqlite` makes reruns incremental. Neither is required to import the embedded fields into TabBuddy. Xcode command-line tools compile the local helper automatically; failures leave existing files intact. Import the `gametabs` and/or `gprotab` folders into TabBuddy. Use `--watch` to incorporate new crawler downloads every minute; logs and a PID file stay under the ignored corpus. This is a local preparation process, not a published catalog.

Run naming tests with `python3 -m unittest discover -s Tools -p 'test_prepare_tab_library.py'`.

`check-embedded-metadata.cjs` compares original/enriched GP pairs (JSON input with `original` and `enriched` paths) through the bundled alphaTab runtime, checking track/bar counts and generated MIDI events. Downloaded test inputs remain ignored.
