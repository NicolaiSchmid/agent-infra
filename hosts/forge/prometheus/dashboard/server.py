"""Tailnet-only quota dashboard. Standard library only; no credential forwarding to browsers."""
import concurrent.futures
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import sqlite3
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE = os.getenv('PROXY_URL', 'http://127.0.0.1:8317')
DATA = Path(os.getenv('DATA_DIR', '/data'))
INTERVAL = max(60, int(os.getenv('POLL_SECONDS', '300')))
LOCK = threading.Lock()
STATUS = {'collecting': False, 'last_attempt': None, 'error': None}


def connect():
    db = sqlite3.connect(DATA / 'quota.db', timeout=30)
    db.row_factory = sqlite3.Row
    return db


def init():
    DATA.mkdir(parents=True, exist_ok=True)
    with connect() as db:
        db.execute('PRAGMA journal_mode=WAL')
        db.execute('CREATE TABLE IF NOT EXISTS accounts (id TEXT PRIMARY KEY, payload TEXT NOT NULL)')
        db.execute('CREATE TABLE IF NOT EXISTS samples (ts INTEGER, account TEXT, provider TEXT, window TEXT, remaining REAL, reset REAL, PRIMARY KEY(ts,account,window))')
        db.execute('CREATE INDEX IF NOT EXISTS sample_time ON samples(ts)')


def api(path, payload=None):
    key = Path(os.getenv('MANAGEMENT_KEY_FILE', '/run/secrets/management_key')).read_text().strip()
    req = urllib.request.Request(BASE + '/v0/management/' + path,
        data=json.dumps(payload).encode() if payload is not None else None,
        headers={'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=25) as response:
        return json.load(response)


def instant(value):
    try:
        if isinstance(value, (int, float)):
            return float(value)
        return dt.datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()
    except (ValueError, TypeError, AttributeError):
        return None


def window(name, used, reset):
    try:
        used = float(used)
        if not math.isfinite(used):
            return None
        return {'name': name, 'remaining': max(0, min(100, 100 - used)), 'reset': instant(reset)}
    except (TypeError, ValueError):
        return None


def normalize(provider, body):
    result = []
    if provider == 'claude':
        for key, value in body.items():
            if isinstance(value, dict) and (key == 'five_hour' or key.startswith('seven_day')):
                item = window(key, value.get('utilization'), value.get('resets_at'))
                if item:
                    result.append(item)
    else:
        limits = body.get('rate_limit') or {}
        for key, fallback in [('primary_window', 'five_hour'), ('secondary_window', 'seven_day')]:
            value = limits.get(key)
            if not isinstance(value, dict):
                continue
            seconds = value.get('limit_window_seconds')
            name = 'five_hour' if seconds == 18000 else 'seven_day' if seconds == 604800 else (f'window_{seconds}s' if seconds else fallback)
            reset = value.get('reset_at')
            if reset is None and isinstance(value.get('reset_after_seconds'), (float, int)):
                reset = time.time() + value['reset_after_seconds']
            item = window(name, value.get('used_percent'), reset)
            if item:
                result.append(item)
    return result


def fetch_account(file):
    provider = file.get('type') or file.get('provider')
    idx = str(file.get('auth_index', ''))
    identity = hashlib.sha256((provider + ':' + (idx or file.get('name', ''))).encode()).hexdigest()[:20]
    account = {'id': identity, 'provider': provider, 'label': file.get('email') or file.get('label') or file.get('name') or provider,
               'disabled': bool(file.get('disabled')), 'windows': [], 'observed': None, 'error': None}
    if account['disabled']:
        return account
    if not idx:
        account['error'] = 'Missing account index'
        return account
    headers = {'Authorization': 'Bearer $TOKEN$', 'Content-Type': 'application/json'}
    if provider == 'claude':
        url = 'https://api.anthropic.com/api/oauth/usage'
        headers.update({'anthropic-beta': 'oauth-2025-04-20', 'User-Agent': 'claude-cli/2.1.280 (external, cli)'})
    else:
        url = 'https://chatgpt.com/backend-api/wham/usage'
        headers['User-Agent'] = 'codex-tui/0.149.1'
        # Account ID is non-secret metadata; never read/download credential files.
        metadata = file.get('id_token')
        account_id = file.get('account_id') or (metadata.get('chatgpt_account_id') if isinstance(metadata, dict) else None)
        if account_id:
            headers['Chatgpt-Account-Id'] = str(account_id)
    try:
        response = api('api-call', {'authIndex': idx, 'method': 'GET', 'url': url, 'header': headers})
        code = response.get('status_code', 0)
        if code != 200:
            raise ValueError('Provider returned HTTP ' + str(code))
        body = response.get('body')
        if isinstance(body, str):
            body = json.loads(body)
        account['windows'] = normalize(provider, body)
        if not account['windows']:
            raise ValueError('Provider returned no supported quota windows')
        account['observed'] = int(time.time())
        account['plan'] = body.get('plan_type') if provider == 'codex' else None
    except Exception as error:
        # Do not expose provider response bodies, tokens, or request headers.
        account['error'] = str(error) if isinstance(error, ValueError) else 'Quota fetch failed (' + type(error).__name__ + ')'
    return account


def collect():
    if not LOCK.acquire(blocking=False):
        return
    STATUS.update(collecting=True, last_attempt=int(time.time()), error=None)
    try:
        files = api('auth-files').get('files', [])
        files = [f for f in files if (f.get('type') or f.get('provider')) in ('claude', 'codex')]
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
            accounts = list(pool.map(fetch_account, files))
        now = int(time.time())
        with connect() as db:
            previous = {row['id']: json.loads(row['payload']) for row in db.execute('SELECT * FROM accounts')}
            db.execute('DELETE FROM accounts')
            for account in accounts:
                if account['error'] and account['id'] in previous:
                    old = previous[account['id']]
                    account.update(windows=old['windows'], observed=old['observed'], plan=old.get('plan'))
                db.execute('INSERT INTO accounts VALUES (?,?)', (account['id'], json.dumps(account)))
                if account['error'] or account['disabled']:
                    continue
                for item in account['windows']:
                    db.execute('INSERT OR REPLACE INTO samples VALUES (?,?,?,?,?,?)', (now, account['id'], account['provider'], item['name'], item['remaining'], item['reset']))
            db.execute('DELETE FROM samples WHERE ts < ?', (now - 90 * 86400,))
    except Exception as error:
        STATUS['error'] = 'Collection failed (' + type(error).__name__ + ')'
    finally:
        STATUS['collecting'] = False
        LOCK.release()


def state():
    with connect() as db:
        accounts = [json.loads(r['payload']) for r in db.execute('SELECT payload FROM accounts ORDER BY id')]
        # At most 14 days, bucketed per account in 15-minute bins to bound responses.
        history = [dict(r) for r in db.execute('SELECT CAST(ts / 900 AS INTEGER)*900 AS ts, account, provider, window, AVG(remaining) AS remaining, MAX(reset) AS reset FROM samples WHERE ts > ? GROUP BY CAST(ts / 900 AS INTEGER),account,provider,window ORDER BY ts', (time.time() - 14 * 86400,))]
    return {'accounts': accounts, 'history': history, 'status': dict(STATUS), 'now': int(time.time()), 'interval': INTERVAL}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def send(self, code, body, kind='application/json'):
        self.send_response(code)
        self.send_header('Content-Type', kind)
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split('?')[0]
        if path in ('/', '/dashboard', '/dashboard/'):
            return self.send(200, Path(__file__).with_name('index.html').read_bytes(), 'text/html; charset=utf-8')
        if path == '/dashboard/api/state':
            return self.send(200, json.dumps(state()).encode())
        if path == '/dashboard/health':
            return self.send(200, b'{"ok":true}')
        self.send(404, b'{}')

    def do_POST(self):
        # Require same-origin fetch metadata/custom header to prevent browser CSRF.
        if self.path != '/dashboard/api/refresh':
            return self.send(404, b'{}')
        if self.headers.get('X-Dashboard-Request') != '1' or self.headers.get('Sec-Fetch-Site', 'same-origin') not in ('same-origin', 'none'):
            return self.send(403, b'{}')
        if STATUS['last_attempt'] and time.time() - STATUS['last_attempt'] < 60:
            return self.send(429, b'{"error":"Please wait one minute between refreshes"}')
        threading.Thread(target=collect, daemon=True).start()
        self.send(202, b'{"ok":true}')


def loop():
    while True:
        collect()
        time.sleep(INTERVAL)


if __name__ == '__main__':
    init()
    threading.Thread(target=loop, daemon=True).start()
    ThreadingHTTPServer(('127.0.0.1', 8318), Handler).serve_forever()
