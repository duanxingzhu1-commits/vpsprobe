#!/usr/bin/env python3
"""VPSProbe MVP hub. Python 3.9+, standard library only."""
import hashlib
import hmac
import json
import os
import secrets
import sqlite3
import threading
import time
import urllib.request
from datetime import datetime, timezone
from http import HTTPStatus
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parent
DB_PATH = Path(os.environ.get("VPSPROBE_DB", str(ROOT / "vpsprobe.db")))
HOST = os.environ.get("VPSPROBE_HOST", "127.0.0.1")
PORT = int(os.environ.get("VPSPROBE_PORT", "8765"))
ADMIN_PASSWORD = os.environ.get("VPSPROBE_ADMIN_PASSWORD", "")
COOKIE_KEY = os.environ.get("VPSPROBE_COOKIE_KEY", "")
TG_TOKEN = os.environ.get("VPSPROBE_TG_TOKEN", "")
TG_CHAT = os.environ.get("VPSPROBE_TG_CHAT_ID", "")
WECOM_URL = os.environ.get("VPSPROBE_WECOM_WEBHOOK", "")
PUBLIC_HTTPS = os.environ.get("VPSPROBE_PUBLIC_HTTPS", "") == "1"
DB_LOCK = threading.RLock()


def conn():
    db = sqlite3.connect(str(DB_PATH), timeout=15)
    db.row_factory = sqlite3.Row
    return db


def init_db():
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    with conn() as db:
        db.executescript("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS servers (
          id INTEGER PRIMARY KEY, name TEXT NOT NULL, agent_token_hash TEXT UNIQUE NOT NULL,
          created_at INTEGER NOT NULL, last_seen INTEGER, offline_alerted INTEGER DEFAULT 0, region TEXT DEFAULT '',
          provider TEXT DEFAULT '', expires_at TEXT DEFAULT '', quota_gb REAL,
          billing_day INTEGER DEFAULT 1, rx_base INTEGER, tx_base INTEGER,
          rx_last INTEGER, tx_last INTEGER, cycle_key TEXT DEFAULT '',
          used_bytes INTEGER DEFAULT 0, last_alert TEXT DEFAULT '',
          cpu REAL, memory REAL, disk REAL, rx_rate REAL, tx_rate REAL,
          latency_ms REAL, probe_ok INTEGER, os_info TEXT DEFAULT ''
        );
        CREATE TABLE IF NOT EXISTS enrollments (
          code_hash TEXT PRIMARY KEY, expires_at INTEGER NOT NULL, used INTEGER DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS samples (
          id INTEGER PRIMARY KEY, server_id INTEGER NOT NULL, ts INTEGER NOT NULL,
          cpu REAL, memory REAL, disk REAL, rx_rate REAL, tx_rate REAL,
          used_bytes INTEGER, latency_ms REAL, probe_ok INTEGER
        );
        CREATE TABLE IF NOT EXISTS events (
          id INTEGER PRIMARY KEY, server_id INTEGER, ts INTEGER NOT NULL,
          level TEXT NOT NULL, kind TEXT NOT NULL, message TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS samples_server_ts ON samples(server_id,ts);
        CREATE INDEX IF NOT EXISTS events_ts ON events(ts);
        """)


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def cycle_key(ts, billing_day):
    dt = datetime.fromtimestamp(ts, timezone.utc)
    year, month = dt.year, dt.month
    if dt.day < billing_day:
        month -= 1
        if month == 0:
            year, month = year - 1, 12
    return f"{year:04d}-{month:02d}-{billing_day:02d}"


def send_notice(message):
    targets = []
    if TG_TOKEN and TG_CHAT:
        targets.append((f"https://api.telegram.org/bot{TG_TOKEN}/sendMessage", {"chat_id": TG_CHAT, "text": message}))
    if WECOM_URL:
        targets.append((WECOM_URL, {"msgtype": "text", "text": {"content": message}}))
    for url, body in targets:
        try:
            req = urllib.request.Request(url, json.dumps(body).encode(), {"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=8) as response:
                response.read()
        except Exception as exc:
            print(f"notification failed: {type(exc).__name__}", flush=True)


def event(db, server_id, level, kind, message):
    db.execute("INSERT INTO events(server_id,ts,level,kind,message) VALUES(?,?,?,?,?)",
               (server_id, int(time.time()), level, kind, message))
    threading.Thread(target=send_notice, args=(f"VPSProbe · {message}",), daemon=True).start()


def parse_number(value, lower, upper):
    if value is None:
        return None
    value = float(value)
    if not lower <= value <= upper:
        raise ValueError("metric out of range")
    return value


def ingest(server, data):
    now = int(time.time())
    sid = server["id"]
    cpu = parse_number(data.get("cpu"), 0, 100)
    memory = parse_number(data.get("memory"), 0, 100)
    disk = parse_number(data.get("disk"), 0, 100)
    rx = int(data.get("rx_bytes", 0))
    tx = int(data.get("tx_bytes", 0))
    if rx < 0 or tx < 0:
        raise ValueError("negative counter")
    rx_rate = parse_number(data.get("rx_rate"), 0, 1e12)
    tx_rate = parse_number(data.get("tx_rate"), 0, 1e12)
    latency = parse_number(data.get("latency_ms"), 0, 1e6)
    probe_ok = 1 if data.get("probe_ok") else 0
    key = cycle_key(now, server["billing_day"] or 1)
    used = server["used_bytes"] or 0
    if key != server["cycle_key"]:
        used = 0
        rx_last, tx_last = rx, tx
        last_alert = ""
    else:
        rx_last, tx_last = server["rx_last"], server["tx_last"]
        if rx_last is not None and tx_last is not None:
            if rx >= rx_last and tx >= tx_last:
                used += rx - rx_last + tx - tx_last
            else:
                with conn() as db:
                    event(db, sid, "info", "counter_reset", f"{server['name']} 网卡计数器重置，已重新建立流量基准")
        last_alert = server["last_alert"] or ""
    with DB_LOCK, conn() as db:
        old_online = server["last_seen"] is not None and now - server["last_seen"] <= 90
        db.execute("""UPDATE servers SET last_seen=?,offline_alerted=0,cpu=?,memory=?,disk=?,rx_rate=?,tx_rate=?,
          rx_last=?,tx_last=?,cycle_key=?,used_bytes=?,latency_ms=?,probe_ok=?,os_info=?,last_alert=? WHERE id=?""",
          (now,cpu,memory,disk,rx_rate,tx_rate,rx,tx,key,used,latency,probe_ok,str(data.get("os_info", ""))[:120],last_alert,sid))
        db.execute("""INSERT INTO samples(server_id,ts,cpu,memory,disk,rx_rate,tx_rate,used_bytes,latency_ms,probe_ok)
          VALUES(?,?,?,?,?,?,?,?,?,?)""", (sid,now,cpu,memory,disk,rx_rate,tx_rate,used,latency,probe_ok))
        if not old_online:
            event(db, sid, "ok", "online", f"{server['name']} 已连接")
        if server["probe_ok"] == 1 and not probe_ok:
            event(db, sid, "warning", "network", f"{server['name']} 网络探测失败")
        elif server["probe_ok"] == 0 and probe_ok:
            event(db, sid, "ok", "network", f"{server['name']} 网络探测恢复")
        quota = server["quota_gb"]
        if quota and quota > 0:
            percent = used / (quota * 1024**3) * 100
            reached = "100" if percent >= 100 else "95" if percent >= 95 else "80" if percent >= 80 else ""
            if reached and reached != last_alert:
                event(db, sid, "warning", "traffic", f"{server['name']} 本期流量已使用 {percent:.1f}%（阈值 {reached}%）")
                db.execute("UPDATE servers SET last_alert=? WHERE id=?", (reached,sid))


def background_checks():
    while True:
        try:
            now = int(time.time())
            today = datetime.now(timezone.utc).date()
            with DB_LOCK, conn() as db:
                for row in db.execute("SELECT * FROM servers").fetchall():
                    if row["last_seen"] and now - row["last_seen"] > 90 and not row["offline_alerted"]:
                        event(db, row["id"], "warning", "offline", f"{row['name']} 已离线")
                        db.execute("UPDATE servers SET offline_alerted=1 WHERE id=?", (row["id"],))
                    if row["expires_at"]:
                        try:
                            days = (datetime.strptime(row["expires_at"], "%Y-%m-%d").date() - today).days
                        except ValueError:
                            continue
                        if days in (30, 7, 1, 0):
                            marker = f"expiry:{row['expires_at']}:{days}"
                            exists = db.execute("SELECT 1 FROM events WHERE server_id=? AND kind=? AND message LIKE ?",
                                                (row["id"], "expiry", f"%[{marker}]%")).fetchone()
                            if not exists:
                                event(db, row["id"], "warning", "expiry", f"{row['name']} 将在 {days} 天后到期 [{marker}]")
                db.execute("DELETE FROM samples WHERE ts < ?", (now - 30*86400,))
        except Exception as exc:
            print(f"background check failed: {type(exc).__name__}: {exc}", flush=True)
        time.sleep(30)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print("%s %s" % (self.address_string(), fmt % args), flush=True)

    def json(self, status, data):
        body = json.dumps(data, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def read_json(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length > 65536:
            raise ValueError("payload too large")
        return json.loads(self.rfile.read(length or 0))

    def authed(self):
        cookie = SimpleCookie()
        try:
            cookie.load(self.headers.get("Cookie", ""))
            value = cookie["vpsprobe"].value
            stamp, signature = value.split(".", 1)
            expected = hmac.new(COOKIE_KEY.encode(), stamp.encode(), hashlib.sha256).hexdigest()
            return int(stamp) > time.time() and hmac.compare_digest(signature, expected)
        except (KeyError, ValueError, TypeError):
            return False

    def agent(self):
        token = self.headers.get("Authorization", "").removeprefix("Bearer ")
        if not token:
            return None
        with conn() as db:
            return db.execute("SELECT * FROM servers WHERE agent_token_hash=?", (digest(token),)).fetchone()

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/health":
            return self.json(200, {"ok": True})
        if path == "/" or path == "/index.html":
            body = (ROOT / "index.html").read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            return self.wfile.write(body)
        if not self.authed():
            return self.json(401, {"error": "login required"})
        with conn() as db:
            if path == "/api/servers":
                rows = [dict(row) for row in db.execute("SELECT * FROM servers ORDER BY id DESC")]
                for row in rows:
                    row.pop("agent_token_hash")
                return self.json(200, {"servers": rows, "now": int(time.time())})
            if path == "/api/events":
                rows = [dict(row) for row in db.execute("SELECT * FROM events ORDER BY id DESC LIMIT 60")]
                return self.json(200, {"events": rows})
            if path.startswith("/api/history/"):
                try:
                    sid = int(path.rsplit("/", 1)[1])
                except ValueError:
                    return self.json(400, {"error": "invalid id"})
                rows = [dict(row) for row in db.execute("SELECT * FROM samples WHERE server_id=? ORDER BY ts DESC LIMIT 120", (sid,))]
                return self.json(200, {"samples": rows[::-1]})
        return self.json(404, {"error": "not found"})

    def do_POST(self):
        path = urlparse(self.path).path
        try:
            origin = self.headers.get("Origin")
            if origin and urlparse(origin).netloc != self.headers.get("Host"):
                return self.json(403, {"error": "invalid origin"})
            data = self.read_json()
            if path == "/api/login":
                if not hmac.compare_digest(str(data.get("password", "")), ADMIN_PASSWORD):
                    return self.json(401, {"error": "密码错误"})
                stamp = str(int(time.time()) + 86400)
                signature = hmac.new(COOKIE_KEY.encode(), stamp.encode(), hashlib.sha256).hexdigest()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                secure = "; Secure" if PUBLIC_HTTPS else ""
                self.send_header("Set-Cookie", f"vpsprobe={stamp}.{signature}; HttpOnly; SameSite=Strict; Path=/; Max-Age=86400{secure}")
                self.end_headers()
                return self.wfile.write(b'{"ok":true}')
            if path == "/api/agent/register":
                code = str(data.get("code", ""))
                name = str(data.get("name", "")).strip()[:80]
                if not code or not name:
                    return self.json(400, {"error": "code and name required"})
                with DB_LOCK, conn() as db:
                    entry = db.execute("SELECT * FROM enrollments WHERE code_hash=?", (digest(code),)).fetchone()
                    if not entry or entry["used"] or entry["expires_at"] < time.time():
                        return self.json(403, {"error": "invalid or expired enrollment code"})
                    token = secrets.token_urlsafe(40)
                    cur = db.execute("INSERT INTO servers(name,agent_token_hash,created_at) VALUES(?,?,?)", (name,digest(token),int(time.time())))
                    db.execute("UPDATE enrollments SET used=1 WHERE code_hash=?", (digest(code),))
                    event(db, cur.lastrowid, "info", "register", f"{name} 已注册")
                return self.json(200, {"token": token})
            if path == "/api/agent/report":
                server = self.agent()
                if not server:
                    return self.json(403, {"error": "invalid agent token"})
                ingest(server, data)
                return self.json(200, {"ok": True})
            if not self.authed():
                return self.json(401, {"error": "login required"})
            if path == "/api/enroll":
                code = secrets.token_urlsafe(18)
                with conn() as db:
                    db.execute("INSERT INTO enrollments(code_hash,expires_at) VALUES(?,?)", (digest(code),int(time.time())+600))
                return self.json(200, {"code": code, "expires_in": 600})
            if path == "/api/server/update":
                sid = int(data["id"])
                expires = str(data.get("expires_at", ""))
                if expires:
                    datetime.strptime(expires, "%Y-%m-%d")
                quota = data.get("quota_gb")
                quota = float(quota) if quota not in (None, "") else None
                if quota is not None and quota < 0:
                    raise ValueError("invalid quota")
                day = int(data.get("billing_day") or 1)
                if not 1 <= day <= 28:
                    raise ValueError("billing day must be 1-28")
                with conn() as db:
                    db.execute("UPDATE servers SET name=?,region=?,provider=?,expires_at=?,quota_gb=?,billing_day=? WHERE id=?",
                               (str(data.get("name", ""))[:80],str(data.get("region", ""))[:80],str(data.get("provider", ""))[:80],expires,quota,day,sid))
                return self.json(200, {"ok": True})
            if path == "/api/logout":
                self.send_response(200)
                self.send_header("Set-Cookie", "vpsprobe=; Max-Age=0; Path=/")
                self.end_headers()
                return self.wfile.write(b'{"ok":true}')
            return self.json(404, {"error": "not found"})
        except (ValueError, KeyError, TypeError, json.JSONDecodeError) as exc:
            return self.json(400, {"error": str(exc)})


if __name__ == "__main__":
    if len(ADMIN_PASSWORD) < 12 or len(COOKIE_KEY) < 24:
        raise SystemExit("Set VPSPROBE_ADMIN_PASSWORD (12+ chars) and VPSPROBE_COOKIE_KEY (24+ chars)")
    init_db()
    threading.Thread(target=background_checks, daemon=True).start()
    print(f"VPSProbe listening on http://{HOST}:{PORT}", flush=True)
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
