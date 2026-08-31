#!/usr/bin/env python3
"""Paper Reader - local server.

Serves the PDF reading UI and bridges two endpoints to the local claude CLI:
  POST /api/translate  - translate a selected passage into Korean
  POST /api/chat       - ask a question about the paper

The data/ layout matches the earlier PowerShell version, so a data/ folder
copied over from that install keeps working as is.

Requires: Python 3.9+, the `claude` CLI, and `pdftotext` (brew install poppler)
for PDF import.
"""

import argparse
import json
import mimetypes
import os
import re
import shutil
import subprocess
import sys
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlsplit

ROOT = Path(__file__).resolve().parent


# --- locate external tools -------------------------------------------------
# A .command double-clicked from Finder can start with a bare PATH, so the
# usual install locations are probed directly when `which` comes up empty.
def find_tool(name, extra_paths):
    hit = shutil.which(name)
    if hit:
        return hit
    for p in extra_paths:
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None


CLAUDE = find_tool('claude', [
    os.path.expanduser('~/.local/bin/claude'),
    os.path.expanduser('~/.claude/local/claude'),
    '/opt/homebrew/bin/claude',
    '/usr/local/bin/claude',
])

PDFTOTEXT = find_tool('pdftotext', [
    '/opt/homebrew/bin/pdftotext',
    '/usr/local/bin/pdftotext',
])

if not CLAUDE:
    print('ERROR: claude CLI not found.', file=sys.stderr)
    print('Install Claude Code and log in, then run `which claude` to confirm.', file=sys.stderr)
    sys.exit(1)


# --- assets and data layout ------------------------------------------------
PROMPTS_PATH = ROOT / 'prompts.json'
if not PROMPTS_PATH.exists():
    print('ERROR: missing required file: %s' % PROMPTS_PATH, file=sys.stderr)
    sys.exit(1)
PROMPTS = json.loads(PROMPTS_PATH.read_text('utf-8'))

DATA_DIR = ROOT / 'data'
PAPERS_DIR = DATA_DIR / 'papers'
SESSIONS_DIR = DATA_DIR / 'sessions'
ACTIVE_FILE = DATA_DIR / 'active.json'
LOG_PATH = ROOT / 'server.log'
for d in (DATA_DIR, PAPERS_DIR, SESSIONS_DIR):
    d.mkdir(parents=True, exist_ok=True)

ID_RE = re.compile(r'^[A-Za-z0-9_-]{1,64}$')
ALLOWED_MODELS = ('sonnet', 'opus', 'haiku', 'fable')
ALLOWED_EFFORTS = ('low', 'medium', 'high', 'xhigh', 'max')

# shared state: one lock per structure, mirroring the synchronized hashtables
SESS_LOCK = threading.RLock()
ACTIVE_LOCK = threading.RLock()
CACHE_LOCK = threading.RLock()
SESSIONS = {}                                   # key -> {meta, turns}
CACHE = {}                                      # source text -> translation
ACTIVE = {'id': '', 'title': '', 'pdf': '', 'text': ''}


def write_log(message):
    try:
        with open(LOG_PATH, 'a', encoding='utf-8') as f:
            f.write('[%s] %s\n' % (datetime.now().strftime('%H:%M:%S'), message))
    except OSError:
        pass


def now_iso():
    return datetime.now().astimezone().isoformat()


# --- paper library ---------------------------------------------------------
def read_meta_title(paper_dir, fallback):
    meta = paper_dir / 'meta.json'
    if meta.exists():
        try:
            m = json.loads(meta.read_text('utf-8'))
            if m.get('title'):
                return str(m['title'])
        except (OSError, ValueError):
            pass
    return fallback


def get_paper_entry(paper_id):
    d = PAPERS_DIR / paper_id
    pdf, txt = d / 'paper.pdf', d / 'paper.txt'
    if not (pdf.exists() and txt.exists()):
        return None
    return {'id': paper_id, 'title': read_meta_title(d, paper_id),
            'pdf': str(pdf), 'txt': str(txt)}


def get_paper_list():
    items = []
    with ACTIVE_LOCK:
        active_id = ACTIVE['id']
    for d in sorted(PAPERS_DIR.iterdir() if PAPERS_DIR.exists() else []):
        if not d.is_dir():
            continue
        if (d / 'paper.pdf').exists() and (d / 'paper.txt').exists():
            items.append({'id': d.name, 'title': read_meta_title(d, d.name),
                          'active': d.name == active_id})
    return items


def set_active_paper(paper_id):
    if not ID_RE.match(paper_id or ''):
        return False
    entry = get_paper_entry(paper_id)
    if not entry:
        return False
    text = Path(entry['txt']).read_text('utf-8', errors='replace')
    with ACTIVE_LOCK:
        ACTIVE.update({'id': entry['id'], 'title': entry['title'],
                       'pdf': entry['pdf'], 'text': text})
    try:
        ACTIVE_FILE.write_text(json.dumps({'paperId': paper_id}), 'utf-8')
    except OSError:
        pass
    return True


def delete_paper(paper_id):
    """Remove a paper's folder. Sessions that point at it are left alone - the
    transcript is worth keeping even once the PDF is gone. Deleting the paper
    that is currently open falls back to whatever else is in the library."""
    if not ID_RE.match(paper_id or ''):
        return False
    d = PAPERS_DIR / paper_id
    if not (d / 'paper.pdf').exists():
        return False
    shutil.rmtree(d, ignore_errors=True)
    with TRANS_LOCK:
        TRANS_JOBS.pop(paper_id, None)

    with ACTIVE_LOCK:
        was_active = ACTIVE['id'] == paper_id
        if was_active:
            ACTIVE.update({'id': '', 'title': '', 'pdf': '', 'text': ''})
    if was_active:
        ACTIVE_FILE.unlink(missing_ok=True)
        for p in get_paper_list():
            if set_active_paper(p['id']):
                break
    return True


def import_paper(data, original_name):
    """Save the upload, extract page-marked text, make it the active paper."""
    if not PDFTOTEXT:
        return {'ok': False, 'error': 'pdftotext not found (brew install poppler)'}
    if not data or len(data) < 1024:
        return {'ok': False, 'error': 'file too small or empty'}
    if len(data) > 200 * 1024 * 1024:
        return {'ok': False, 'error': 'file larger than 200MB'}
    if data[:5] != b'%PDF-':
        return {'ok': False, 'error': 'not a PDF file'}

    base = 'p' + datetime.now().strftime('%Y%m%d%H%M%S')
    paper_id, n_try = base, 1
    while (PAPERS_DIR / paper_id).exists():
        n_try += 1
        paper_id = '%s_%d' % (base, n_try)

    d = PAPERS_DIR / paper_id
    d.mkdir(parents=True)
    pdf = d / 'paper.pdf'
    pdf.write_bytes(data)

    raw_txt = d / 'raw.txt'
    try:
        proc = subprocess.run([PDFTOTEXT, '-enc', 'UTF-8', str(pdf), str(raw_txt)],
                              capture_output=True, timeout=120)
    except subprocess.TimeoutExpired:
        shutil.rmtree(d, ignore_errors=True)
        return {'ok': False, 'error': 'pdftotext timed out'}
    if proc.returncode != 0 or not raw_txt.exists():
        err = proc.stderr.decode('utf-8', 'replace').strip()
        shutil.rmtree(d, ignore_errors=True)
        return {'ok': False, 'error': 'text extraction failed: ' + err}

    # pdftotext separates pages with a form feed; turn those into [p.N] markers
    pages = raw_txt.read_text('utf-8', errors='replace').split('\f')
    out, n = [], 0
    for i, page in enumerate(pages):
        body = page.strip()
        if not body and i == len(pages) - 1:
            continue
        n += 1
        out.append('===== [p.%d] =====\n%s\n\n' % (n, body))
    (d / 'paper.txt').write_text(''.join(out), 'utf-8')
    raw_txt.unlink(missing_ok=True)

    title = paper_id
    if original_name:
        stem = Path(original_name).stem
        if stem:
            title = stem
    (d / 'meta.json').write_text(
        json.dumps({'id': paper_id, 'title': title}, ensure_ascii=False), 'utf-8')

    set_active_paper(paper_id)
    start_trans_job(paper_id)          # pre-translate every page in the background
    return {'ok': True, 'id': paper_id, 'title': title, 'pages': n}


# --- page translations: data/papers/<id>/trans.json ------------------------
# Whole-paper translation runs as a background job (started at import, or from
# the UI). Each page is one claude call; results land in trans.json page by
# page, so an interrupted job resumes where it left off.
TRANS_LOCK = threading.RLock()
TRANS_JOBS = {}                                 # paper_id -> status dict


def trans_path(paper_id):
    return PAPERS_DIR / paper_id / 'trans.json'


def load_trans(paper_id):
    f = trans_path(paper_id)
    if f.exists():
        try:
            return json.loads(f.read_text('utf-8'))
        except (OSError, ValueError):
            pass
    return {'v': 1, 'pages': {}}


def page_blocks(paper_id):
    """Page number -> raw text, parsed back out of paper.txt's page markers."""
    txt = PAPERS_DIR / paper_id / 'paper.txt'
    if not txt.exists():
        return {}
    marker = re.compile(r'^===== \[p\.(\d+)\] =====$')
    blocks, cur, buf = {}, None, []
    for line in txt.read_text('utf-8', errors='replace').splitlines():
        m = marker.match(line)
        if m:
            if cur is not None:
                blocks[cur] = '\n'.join(buf).strip()
            cur, buf = int(m.group(1)), []
        elif cur is not None:
            buf.append(line)
    if cur is not None:
        blocks[cur] = '\n'.join(buf).strip()
    return blocks


# Dots that do NOT end a sentence in academic prose: abbreviations, initials
# ("W. Dong"), and decimals. They get masked before splitting, restored after.
_ABBREV_RE = re.compile(
    r'\b(?:e\.g|i\.e|et[ ]al|etc|cf|vs|viz|resp|ca|approx|Fig|Figs|Eq|Eqs'
    r'|Ref|Refs|Sec|Secs|Tab|Tabs|Vol|No|pp|Dr|Mr|Ms|Prof|St)\.')
_INITIAL_RE = re.compile(r'\b([A-Z])\.')
_DECIMAL_RE = re.compile(r'(\d)\.(?=\d)')
_SENT_SPLIT = re.compile(r'(?<=[.!?])\s+(?=[A-Z0-9"\'(\[])')


def split_sentences(paragraph):
    t = ' '.join(paragraph.split())
    masked = _ABBREV_RE.sub(lambda m: m.group(0).replace('.', '\x00'), t)
    masked = _INITIAL_RE.sub(lambda m: m.group(1) + '\x00', masked)
    masked = _DECIMAL_RE.sub(lambda m: m.group(1) + '\x00', masked)
    return [p.replace('\x00', '.') for p in _SENT_SPLIT.split(masked) if p.strip()]


def translate_page_call(paper_title, paras):
    """One claude call for one page. paras is a list of sentence lists (one
    list per paragraph); returns (segs, error) where each seg carries the
    paragraph pair plus per-sentence pairs for fine-grained highlighting."""
    lines, count = [], 0
    for i, sents in enumerate(paras):
        for k, s in enumerate(sents):
            lines.append('⟦%d.%d⟧ %s' % (i + 1, k + 1, s))
            count += 1
    prompt = (PROMPTS['translate_page']
              .replace('{{PAPER_TITLE}}', paper_title or '(제목 미상)')
              .replace('{{COUNT}}', str(count))
              .replace('{{SEGMENTS}}', '\n'.join(lines)))
    # same quality-over-latency choice as the drag-translate popup
    res = invoke_claude(prompt, 240, 'opus', 'medium')
    if not res['ok']:
        return None, res['error']

    parts = re.split(r'⟦(\d+)\.(\d+)⟧', res['text'])
    out = {}
    for j in range(1, len(parts) - 2, 3):
        out[(int(parts[j]), int(parts[j + 1]))] = parts[j + 2].strip()

    segs = []
    for i, sents in enumerate(paras):
        pairs = []
        for k, s in enumerate(sents):
            ko = out.get((i + 1, k + 1))
            if ko is None:
                return None, 'model returned %d/%d sentences' % (len(out), count)
            pairs.append({'src': s, 'ko': ko})
        segs.append({'src': ' '.join(sents),
                     'ko': ' '.join(p['ko'] for p in pairs),
                     'sents': pairs})
    return segs, None


def get_trans_status(paper_id):
    with TRANS_LOCK:
        job = TRANS_JOBS.get(paper_id)
        if job:
            return dict(job)
    total = len(page_blocks(paper_id))
    done = len(load_trans(paper_id)['pages'])
    status = 'done' if total and done >= total else 'idle'
    return {'status': status, 'done': done, 'total': total, 'error': ''}


def run_trans_job(paper_id):
    entry = get_paper_entry(paper_id)
    blocks = page_blocks(paper_id)
    if not entry or not blocks:
        with TRANS_LOCK:
            TRANS_JOBS[paper_id] = {'status': 'error', 'done': 0, 'total': 0,
                                    'error': 'paper not found'}
        return

    data = load_trans(paper_id)
    todo = [n for n in sorted(blocks) if str(n) not in data['pages']]
    with TRANS_LOCK:
        TRANS_JOBS[paper_id] = {'status': 'running', 'done': len(data['pages']),
                                'total': len(blocks), 'error': ''}
    write_log('translation job start: %s, %d/%d pages to go'
              % (paper_id, len(todo), len(blocks)))

    def work(n):
        paras = [split_sentences(p) for p in re.split(r'\n\s*\n', blocks[n]) if p.strip()]
        paras = [p for p in paras if p]
        if not paras:
            return n, [], None
        segs, err = translate_page_call(entry['title'], paras)
        return n, segs, err

    errors, successes = [], 0
    with ThreadPoolExecutor(max_workers=3) as pool:
        futures = {pool.submit(work, n): n for n in todo}
        for fut in as_completed(futures):
            try:
                n, segs, err = fut.result()
            except Exception as e:
                n, segs, err = futures[fut], None, str(e)
            if segs is None:
                errors.append('p.%d: %s' % (n, err))
                write_log('translation failed %s p.%d: %s' % (paper_id, n, err))
                # every early call failing the same way (usually auth) - stop
                # burning through the rest of the paper
                if successes == 0 and len(errors) >= 3:
                    for f in futures:
                        f.cancel()
                    break
                continue
            successes += 1
            with TRANS_LOCK:
                if not (PAPERS_DIR / paper_id).exists():   # deleted mid-job
                    TRANS_JOBS.pop(paper_id, None)
                    return
                data = load_trans(paper_id)
                data['pages'][str(n)] = segs
                trans_path(paper_id).write_text(
                    json.dumps(data, ensure_ascii=False), 'utf-8')
                TRANS_JOBS[paper_id]['done'] = len(data['pages'])

    with TRANS_LOCK:
        job = TRANS_JOBS[paper_id]
        job['status'] = 'error' if errors else 'done'
        job['error'] = errors[0] if errors else ''
    write_log('translation job end: %s, +%d pages, %d errors'
              % (paper_id, successes, len(errors)))


def start_trans_job(paper_id):
    with TRANS_LOCK:
        job = TRANS_JOBS.get(paper_id)
        if job and job['status'] == 'running':
            return dict(job)
        TRANS_JOBS[paper_id] = {'status': 'running', 'done': 0, 'total': 0, 'error': ''}
    threading.Thread(target=run_trans_job, args=(paper_id,), daemon=True).start()
    return {'status': 'running', 'done': 0, 'total': 0, 'error': ''}


# --- sessions: in-memory, mirrored to data/sessions/<key>.json -------------
def session_path(key):
    return SESSIONS_DIR / (key + '.json')


def get_session(key):
    with SESS_LOCK:
        if key not in SESSIONS:
            entry = {'meta': None, 'turns': []}
            f = session_path(key)
            if f.exists():
                try:
                    j = json.loads(f.read_text('utf-8'))
                    entry['meta'] = {
                        'title': str(j.get('title', '')),
                        'created': str(j.get('created', '')),
                        'updated': str(j.get('updated', '')),
                        'paperId': str(j.get('paperId', '')),
                        'paperTitle': str(j.get('paperTitle', '')),
                    }
                    entry['turns'] = [{'role': str(t.get('role', '')),
                                       'text': str(t.get('text', ''))}
                                      for t in (j.get('turns') or [])]
                except (OSError, ValueError):
                    pass
            SESSIONS[key] = entry
        return SESSIONS[key]


def add_turn(key, role, text):
    with SESS_LOCK:
        entry = get_session(key)
        if not entry['meta']:
            title = re.sub(r'\s+', ' ', text).strip()
            if len(title) > 44:
                title = title[:44] + '...'
            with ACTIVE_LOCK:
                paper_id, paper_title = ACTIVE['id'], ACTIVE['title']
            entry['meta'] = {'title': title, 'created': now_iso(), 'updated': now_iso(),
                             'paperId': paper_id, 'paperTitle': paper_title}
        entry['meta']['updated'] = now_iso()
        entry['turns'].append({'role': role, 'text': text})

        doc = {'key': key, 'turns': entry['turns'], **entry['meta']}
        try:
            session_path(key).write_text(json.dumps(doc, ensure_ascii=False), 'utf-8')
        except OSError:
            pass


def get_session_list():
    items = []
    for f in SESSIONS_DIR.glob('*.json'):
        try:
            j = json.loads(f.read_text('utf-8'))
            items.append({'key': str(j.get('key', '')), 'title': str(j.get('title', '')),
                          'updated': str(j.get('updated', '')),
                          'paperId': str(j.get('paperId', '')),
                          'paperTitle': str(j.get('paperTitle', '')),
                          'turns': len(j.get('turns') or [])})
        except (OSError, ValueError):
            pass
    return sorted(items, key=lambda i: i['updated'], reverse=True)


# --- claude CLI ------------------------------------------------------------
def invoke_claude(prompt, timeout_sec=300, model='sonnet', effort='medium'):
    """One-shot claude call. The prompt goes in through stdin as UTF-8, which
    keeps Korean text off the command line entirely."""
    if model not in ALLOWED_MODELS:
        model = 'sonnet'
    if effort not in ALLOWED_EFFORTS:
        effort = 'medium'

    cmd = [CLAUDE, '-p', '--model', model, '--effort', effort,
           '--tools', '', '--no-session-persistence', '--output-format', 'json']
    try:
        proc = subprocess.run(cmd, input=prompt.encode('utf-8'), capture_output=True,
                              cwd=str(ROOT), timeout=timeout_sec)
    except subprocess.TimeoutExpired:
        return {'ok': False, 'error': 'claude timed out after %ds' % timeout_sec}

    raw = proc.stdout.decode('utf-8', 'replace')
    err = proc.stderr.decode('utf-8', 'replace')

    # --output-format json prints one JSON object; slice it out in case
    # anything else leaks onto stdout.
    i, j = raw.find('{'), raw.rfind('}')
    if i < 0 or j <= i:
        write_log('claude produced no JSON. exit=%s err=%s raw=%s' % (proc.returncode, err, raw))
        return {'ok': False, 'error': err.strip() or 'claude returned no output'}
    try:
        data = json.loads(raw[i:j + 1])
    except ValueError:
        write_log('unparsable claude output: %s' % raw)
        return {'ok': False, 'error': 'could not parse claude output'}

    if data.get('is_error') or data.get('subtype') != 'success':
        detail = data.get('result') or data.get('subtype') or 'unknown error'
        write_log('claude reported an error: %s' % detail)
        return {'ok': False, 'error': str(detail)}

    return {'ok': True, 'text': str(data.get('result', '')), 'cost': data.get('total_cost_usd')}


# --- HTTP ------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    server_version = 'PaperReader'

    def log_message(self, fmt, *args):
        pass                                    # errors go to server.log instead

    def send_bytes(self, body, ctype, status=200, headers=None):
        try:
            self.send_response(status)
            self.send_header('Content-Type', ctype)
            self.send_header('Content-Length', str(len(body)))
            for k, v in (headers or {}).items():
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def send_json(self, obj, status=200):
        body = json.dumps(obj, ensure_ascii=False).encode('utf-8')
        self.send_bytes(body, 'application/json; charset=utf-8', status)

    def read_body(self):
        length = int(self.headers.get('Content-Length') or 0)
        return self.rfile.read(length) if length else b''

    def read_json(self):
        try:
            return json.loads(self.read_body().decode('utf-8'))
        except ValueError:
            return {}

    def do_GET(self):
        path, query = self.split_target()
        try:
            self.handle_get(path, query)
        except Exception as e:                  # never let one request kill the thread
            write_log('handler error: %s' % e)
            self.send_json({'ok': False, 'error': str(e)}, 500)

    def do_POST(self):
        path, _ = self.split_target()
        try:
            self.handle_post(path)
        except Exception as e:
            write_log('handler error: %s' % e)
            self.send_json({'ok': False, 'error': str(e)}, 500)

    def split_target(self):
        parts = urlsplit(self.path)
        return parts.path, parse_qs(parts.query)

    # ---- GET ----------------------------------------------------------
    def handle_get(self, path, query):
        if path == '/api/health':
            return self.send_json({'ok': True, 'claude': CLAUDE})

        if path == '/api/state':
            with ACTIVE_LOCK:
                paper = ({'id': ACTIVE['id'], 'title': ACTIVE['title']}
                         if ACTIVE['id'] else None)
            return self.send_json({'ok': True, 'paper': paper, 'canImport': bool(PDFTOTEXT)})

        if path == '/api/papers':
            return self.send_json({'ok': True, 'papers': get_paper_list()})

        if path == '/api/sessions':
            return self.send_json({'ok': True, 'sessions': get_session_list()})

        if path == '/api/translation/status':
            pid = (query.get('id') or [''])[0]
            if not ID_RE.match(pid):
                return self.send_json({'ok': False, 'error': 'bad paper id'}, 400)
            st = get_trans_status(pid)
            return self.send_json({'ok': True, **st})

        if path == '/api/translation/page':
            pid = (query.get('id') or [''])[0]
            try:
                page = int((query.get('page') or ['0'])[0])
            except ValueError:
                page = 0
            if not ID_RE.match(pid) or page < 1:
                return self.send_json({'ok': False, 'error': 'bad request'}, 400)
            segs = load_trans(pid)['pages'].get(str(page))
            return self.send_json({'ok': True, 'exists': segs is not None,
                                   'segs': segs or []})

        if path == '/api/session':
            key = (query.get('key') or [''])[0]
            if not ID_RE.match(key):
                return self.send_json({'ok': False, 'error': 'bad session key'}, 400)
            entry = get_session(key)
            meta = entry['meta']
            return self.send_json({
                'ok': True, 'exists': bool(meta),
                'paperId': meta['paperId'] if meta else '',
                'title': meta['title'] if meta else '',
                'turns': list(entry['turns']),
            })

        self.serve_static(path)

    # ---- POST ---------------------------------------------------------
    def handle_post(self, path):
        if path == '/api/paper/activate':
            body = self.read_json()
            if set_active_paper(str(body.get('id', ''))):
                return self.send_json({'ok': True})
            return self.send_json({'ok': False, 'error': 'unknown paper id'}, 400)

        if path == '/api/translation/start':
            pid = str(self.read_json().get('id', ''))
            if not ID_RE.match(pid) or not get_paper_entry(pid):
                return self.send_json({'ok': False, 'error': 'unknown paper id'}, 400)
            st = start_trans_job(pid)
            return self.send_json({'ok': True, **st})

        if path == '/api/paper/delete':
            body = self.read_json()
            if delete_paper(str(body.get('id', ''))):
                return self.send_json({'ok': True})
            return self.send_json({'ok': False, 'error': 'unknown paper id'}, 400)

        if path == '/api/paper/import':
            data = self.read_body()
            name = unquote(self.headers.get('X-File-Name') or '')
            res = import_paper(data, name)
            return self.send_json(res, 200 if res['ok'] else 500)

        if path == '/api/session/delete':
            key = str(self.read_json().get('key', ''))
            if not ID_RE.match(key):
                return self.send_json({'ok': False, 'error': 'bad session key'}, 400)
            with SESS_LOCK:
                SESSIONS.pop(key, None)
            session_path(key).unlink(missing_ok=True)
            return self.send_json({'ok': True})

        if path == '/api/chat/reset':
            key = str(self.read_json().get('sessionKey', '')) or 'default'
            with SESS_LOCK:
                SESSIONS.pop(key, None)
            return self.send_json({'ok': True})

        if path == '/api/translate':
            return self.handle_translate()

        if path == '/api/chat':
            return self.handle_chat()

        self.send_json({'ok': False, 'error': 'not found'}, 404)

    def handle_translate(self):
        text = str(self.read_json().get('text', ''))
        if not text.strip():
            return self.send_json({'ok': False, 'error': 'empty selection'}, 400)
        text = text[:20000]

        cache_key = text.strip()
        with CACHE_LOCK:
            hit = CACHE.get(cache_key)
        if hit is not None:
            return self.send_json({'ok': True, 'text': hit, 'cached': True})

        with ACTIVE_LOCK:
            paper_title = ACTIVE['title'] or '(제목 미상)'
        prompt = (PROMPTS['translate']
                  .replace('{{PAPER_TITLE}}', paper_title)
                  .replace('{{TEXT}}', text))
        # translation quality matters more than latency here - pin opus
        res = invoke_claude(prompt, 240, 'opus', 'medium')
        if not res['ok']:
            return self.send_json({'ok': False, 'error': res['error']}, 500)
        with CACHE_LOCK:
            CACHE[cache_key] = res['text']
        return self.send_json({'ok': True, 'text': res['text'], 'cost': res['cost']})

    def handle_chat(self):
        body = self.read_json()
        key = str(body.get('sessionKey', '')) or 'default'
        msg = str(body.get('message', ''))
        model = str(body.get('model', '')) or 'sonnet'
        effort = str(body.get('effort', '')) or 'medium'

        if not msg.strip():
            return self.send_json({'ok': False, 'error': 'empty message'}, 400)
        if not ID_RE.match(key):
            return self.send_json({'ok': False, 'error': 'bad session key'}, 400)

        with ACTIVE_LOCK:
            paper_id, paper_text = ACTIVE['id'], ACTIVE['text']
        if not paper_id:
            return self.send_json(
                {'ok': False, 'error': '먼저 상단 [논문] 메뉴에서 PDF를 가져오세요.'}, 400)

        # deeper effort levels think a lot longer over a 17k-token paper
        timeout = {'xhigh': 600, 'max': 720, 'high': 450}.get(effort, 300)

        # The CLI's own --resume did not carry context in print mode, so the
        # conversation is rebuilt here on every turn instead.
        parts = [PROMPTS['chat_system'].replace('{{PAPER}}', paper_text), '\n']

        # full history persists on disk; only the tail rides the prompt
        hist = list(get_session(key)['turns'])[-32:]
        if hist:
            parts.append('\n' + PROMPTS['chat_turn_header'])
            for h in hist:
                who = 'ASSISTANT' if h['role'] == 'assistant' else 'USER'
                parts.append('<%s>\n%s\n</%s>\n' % (who, h['text'], who))
        parts.append(PROMPTS['chat_question_header'] + msg + '\n')

        res = invoke_claude(''.join(parts), timeout, model, effort)
        if not res['ok']:
            return self.send_json({'ok': False, 'error': res['error']}, 500)
        add_turn(key, 'user', msg)
        add_turn(key, 'assistant', res['text'])
        return self.send_json({'ok': True, 'text': res['text'], 'cost': res['cost']})

    # ---- static files -------------------------------------------------
    def serve_static(self, path):
        rel = path.lstrip('/') or 'index.html'

        if rel == 'paper.pdf':
            with ACTIVE_LOCK:
                target = Path(ACTIVE['pdf']) if ACTIVE['pdf'] else None
        else:
            base = ROOT if rel.startswith('vendor/') else ROOT / 'web'
            target = (base / rel).resolve()
            # keep traversal inside the directory it resolved against
            if not str(target).startswith(str(base.resolve()) + os.sep):
                return self.send_json({'ok': False, 'error': 'bad path'}, 400)

        if not target or not target.is_file():
            return self.send_bytes(b'404 not found', 'text/plain; charset=utf-8', 404)

        ctype = mimetypes.guess_type(target.name)[0] or 'application/octet-stream'
        if ctype.startswith('text/') or ctype in ('application/javascript', 'application/json'):
            ctype += '; charset=utf-8'
        if target.suffix == '.mjs':
            ctype = 'text/javascript; charset=utf-8'
        self.send_bytes(target.read_bytes(), ctype, headers={'Cache-Control': 'no-store'})


# --- startup ---------------------------------------------------------------
def load_active_paper():
    paper_id = ''
    if ACTIVE_FILE.exists():
        try:
            paper_id = str(json.loads(ACTIVE_FILE.read_text('utf-8')).get('paperId', ''))
        except (OSError, ValueError):
            pass
    if paper_id and set_active_paper(paper_id):
        return
    # a fresh clone ships no papers at all - start anyway and let the user
    # import one from the UI, rather than refusing to boot
    for p in get_paper_list():
        if set_active_paper(p['id']):
            return


def main():
    ap = argparse.ArgumentParser(description='Paper Reader local server')
    ap.add_argument('--port', type=int, default=8765)
    ap.add_argument('--no-browser', action='store_true')
    args = ap.parse_args()

    load_active_paper()

    httpd = None
    for port in range(args.port, args.port + 20):
        try:
            httpd = ThreadingHTTPServer(('127.0.0.1', port), Handler)
            break
        except OSError:
            continue
    if httpd is None:
        print('ERROR: could not bind a port in range %d..%d.'
              % (args.port, args.port + 19), file=sys.stderr)
        sys.exit(1)
    httpd.daemon_threads = True

    url = 'http://127.0.0.1:%d/' % httpd.server_address[1]
    print('')
    print('  Paper Reader')
    print('  ------------')
    print('  claude : %s' % CLAUDE)
    if ACTIVE['id']:
        print('  paper  : %s (%dk chars)' % (ACTIVE['title'], len(ACTIVE['text']) // 1000))
    else:
        print('  paper  : none yet - import a PDF from the [논문] menu in the UI')
    print('  import : %s' % ('pdftotext OK' if PDFTOTEXT
                             else 'pdftotext NOT FOUND - PDF import disabled'))
    print('  url    : %s' % url)
    print('')
    print('  Leave this window open while you read. Ctrl+C stops the server.')
    print('')

    if not args.no_browser:
        subprocess.Popen(['open', url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print('stopping...')
    finally:
        httpd.shutdown()
        httpd.server_close()


if __name__ == '__main__':
    main()
