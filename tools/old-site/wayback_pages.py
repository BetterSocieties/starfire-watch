"""Fetch the latest raw Wayback capture of each address in a list. argv: list file, output dir.
Pages only, one request every 6 seconds; the Archive caps callers at about 15 a minute."""
import sys, os, re, json, time, urllib.parse, urllib.request

LIST, OUT = sys.argv[1], sys.argv[2]
os.makedirs(f'{OUT}/pages', exist_ok=True)


def fetch(url):
    for attempt in range(4):
        time.sleep(6)
        try:
            r = urllib.request.urlopen(urllib.request.Request(
                f'https://web.archive.org/web/2026id_/{url}', headers={'User-Agent': 'Mozilla/5.0'}), timeout=60)
            ts = re.search(r'/web/(\d{14})', r.geturl())
            return r.read(), ts.group(1) if ts else ''
        except urllib.error.HTTPError as e:
            if e.code in (429, 503):
                time.sleep(120)
                continue
            return None, str(e.code)
        except Exception as e:
            err = str(e)[:40]
    return None, 'gave up after retries'


urls = [l.strip() for l in open(LIST) if l.strip()]
try:  # one probe first: while the Archive refuses this address, stop instead of spending hours
    urllib.request.urlopen(urllib.request.Request(f'https://web.archive.org/web/2026id_/https://{urls[0]}',
                                                  headers={'User-Agent': 'Mozilla/5.0'}), timeout=60)
except urllib.error.HTTPError as e:
    if e.code in (429, 503):
        print('Archive still refusing:', e.code)
        sys.exit(0)
index = {}
for line in urls:
    u = line.strip()
    if not u:
        continue
    path = urllib.parse.urlparse('https://' + u).path.strip('/') or 'index'
    fn = path.replace('/', '__')[:180] + '.html'
    body, ts = fetch('https://' + u)
    if body:
        open(f'{OUT}/pages/{fn}', 'wb').write(body)
    index[u] = {'file': fn if body else None, 'capture': ts}
    print(len(index), ts, fn, flush=True)
    json.dump(index, open(f'{OUT}/index.json', 'w'), indent=1)  # kept current so a timeout keeps the index
json.dump(index, open(f'{OUT}/index.json', 'w'), indent=1)
print('pages', sum(1 for v in index.values() if v['file']), 'of', len(index))
