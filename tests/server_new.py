#!/usr/bin/env python3
"""Enhanced HTTP server — backup status, drive check, log viewer, trigger."""
import json, os, re, sqlite3, subprocess
from datetime import datetime, timedelta
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

DB_PATH         = os.environ.get("STATUS_DB_PATH", "/app/web-server/backup_status.db")
PORT            = int(os.environ.get("WEB_PORT", "22587"))
FACILITY        = os.environ.get("FACILITY_CODE", os.environ.get("HOSTNAME", "unknown"))
BORG_MODE       = os.environ.get("BORG_MODE", "central")
RETENTION       = 60   # days
SENTINEL        = os.path.join(os.environ.get("WEB_SERVER_DIR", "/app/web-server"), "trigger_backup")
LOG_DIR         = os.environ.get("LOG_DIR", "/app/logs")
STALE_HOURS     = 4    # backup_running staleness threshold
STALE_SENTINEL_MINS = 10  # sentinel auto-cleanup threshold


def _open_db():
    conn = sqlite3.connect(DB_PATH)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS backup_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            task TEXT NOT NULL, status TEXT NOT NULL,
            start_time TEXT, end_time TEXT,
            duration_seconds INTEGER,
            recorded_at TEXT DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now'))
        )
    """)
    conn.commit()
    return conn


def _purge_old():
    if not os.path.exists(DB_PATH):
        return
    try:
        cutoff = (datetime.utcnow() - timedelta(days=RETENTION)).strftime("%Y-%m-%d %H:%M:%S")
        conn = _open_db()
        conn.execute("DELETE FROM backup_events WHERE recorded_at < ?", (cutoff,))
        conn.commit()
        conn.close()
    except Exception:
        pass


def _get_events():
    if not os.path.exists(DB_PATH):
        return []
    try:
        conn = _open_db()
        rows = conn.execute(
            "SELECT task, status, start_time, end_time, duration_seconds "
            "FROM backup_events ORDER BY id DESC LIMIT 200"
        ).fetchall()
        conn.close()
        return rows
    except Exception:
        return []


def _check_drive_status():
    """Returns (drive_mounted, repo_ok) for local mode; (None, None) for central."""
    if BORG_MODE != "local":
        return None, None
    drive = os.path.ismount("/mnt/external")
    if not drive:
        return False, None
    try:
        r = subprocess.run(
            ["borg", "info", "/mnt/external/repo"],
            capture_output=True, timeout=10, env=os.environ,
        )
        return True, r.returncode == 0
    except Exception:
        return True, False


def _get_status():
    """Build the /api/status JSON dict. Always live — no caching."""
    drive_mounted, repo_ok = _check_drive_status()

    # Stale sentinel cleanup
    backup_pending = False
    if os.path.exists(SENTINEL):
        age_mins = (datetime.utcnow() - datetime.utcfromtimestamp(
            os.path.getmtime(SENTINEL))).total_seconds() / 60
        if age_mins > STALE_SENTINEL_MINS:
            try:
                os.remove(SENTINEL)
            except OSError:
                pass
        else:
            backup_pending = True

    # backup_running: any unfinished row within last STALE_HOURS hours
    backup_running = False
    if os.path.exists(DB_PATH):
        try:
            cutoff = (datetime.utcnow() - timedelta(hours=STALE_HOURS)).strftime("%Y-%m-%d %H:%M:%S")
            conn = _open_db()
            row = conn.execute(
                "SELECT id FROM backup_events "
                "WHERE status='starting' AND end_time IS NULL AND start_time > ? LIMIT 1",
                (cutoff,),
            ).fetchone()
            conn.close()
            backup_running = row is not None
        except Exception:
            pass

    return {
        "facility": FACILITY,
        "borg_mode": BORG_MODE,
        "drive_mounted": drive_mounted,
        "repo_ok": repo_ok,
        "backup_running": backup_running,
        "backup_pending": backup_pending,
    }


def _serve_log(date_str):
    """Returns (http_status, content_type, body) for a log file request."""
    if not re.fullmatch(r"\d{8}", date_str):
        return 400, "text/plain", "Invalid date parameter — must be YYYYMMDD\n"
    log_path = os.path.join(LOG_DIR, f"{date_str}-{FACILITY}-backup.log")
    if not os.path.exists(log_path):
        return 404, "text/plain", f"Log not found: {date_str}-{FACILITY}-backup.log\n"
    with open(log_path, "r", encoding="utf-8", errors="replace") as f:
        return 200, "text/plain; charset=utf-8", f.read()


def _handle_trigger():
    """Returns (http_status, body). Writes sentinel or 409 if already exists."""
    if os.path.exists(SENTINEL):
        return 409, "Backup already pending\n"
    try:
        os.makedirs(os.path.dirname(SENTINEL), exist_ok=True)
        with open(SENTINEL, "w") as f:
            f.write(datetime.utcnow().isoformat())
        return 200, "OK\n"
    except OSError as e:
        return 500, f"Error: {e}\n"


def _fmt_dur(secs):
    if secs is None:
        return "&mdash;"
    secs = int(secs)
    return f"{secs // 60}m {secs % 60}s" if secs >= 60 else f"{secs}s"


_STATUS_COLOR = {"completed": "#4CAF50", "failed": "#e74c3c", "starting": "#5dade2"}
_STATUS_ICON  = {"completed": "&#10003;", "failed": "&#10007;", "starting": "&#8635;"}


def _render(status, events):
    borg_mode       = status["borg_mode"]
    drive_mounted   = status["drive_mounted"]
    repo_ok         = status["repo_ok"]
    backup_running  = status["backup_running"]
    backup_pending  = status["backup_pending"]

    now_utc = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S UTC")

    # ── Drive/repo badges (local mode only) ──
    if borg_mode == "local":
        if drive_mounted:
            drive_badge = "<span class='badge ok' id='badge-drive'>&#128190; Drive: <span class='i' data-pt='Pronto' data-en='Ready'>Pronto</span></span>"
        else:
            drive_badge = "<span class='badge err' id='badge-drive'>&#128190; Drive: <span class='i' data-pt='Ausente' data-en='Missing'>Ausente</span></span>"
        if repo_ok:
            repo_badge = "<span class='badge ok' id='badge-repo'>&#128274; Repo: OK</span>"
        elif drive_mounted:
            repo_badge = "<span class='badge warn' id='badge-repo'>&#128274; Repo: <span class='i' data-pt='Erro' data-en='Error'>Erro</span></span>"
        else:
            repo_badge = "<span class='badge warn' id='badge-repo'>&#128274; Repo: &mdash;</span>"
        drive_section = f"{drive_badge} {repo_badge} <div class='divider'></div>"
    else:
        drive_section = ""  # central mode — no drive badges

    # ── Running badge ──
    if backup_running or backup_pending:
        running_badge = "<span class='badge info' id='badge-running'>&#8635; <span class='i' data-pt='Backup em curso&hellip;' data-en='Backup running&hellip;'>Backup em curso&hellip;</span></span>"
    else:
        running_badge = "<span class='badge info' id='badge-running'>&#9679; <span class='i' data-pt='Sem backup em curso' data-en='No backup running'>Sem backup em curso</span></span>"

    # ── Backup Now button enabled state ──
    can_backup = (not backup_running) and (not backup_pending)
    if borg_mode == "local":
        can_backup = can_backup and bool(drive_mounted) and bool(repo_ok)
    btn_backup_disabled = "" if can_backup else "disabled"

    # ── Table rows ──
    rows_html = ""
    for task, st, start_time, end_time, dur_secs in events:
        color = _STATUS_COLOR.get(st, "#888")
        icon  = _STATUS_ICON.get(st, "?")
        date_key = (start_time or "")[:10].replace("-", "")  # "2026-03-24" → "20260324"
        log_btn = (
            f"<button class='btn-row-log' onclick=\"showLog('{date_key}')\">"
            f"&#128196; <span class='i' data-pt='Ver Log' data-en='View Log'>Ver Log</span></button>"
        ) if date_key else "&mdash;"
        rows_html += (
            f"<tr>"
            f"<td>{task}</td>"
            f"<td style='color:{color};font-weight:bold'>{icon} {st}</td>"
            f"<td>{start_time or '&mdash;'}</td>"
            f"<td>{end_time or '&mdash;'}</td>"
            f"<td>{_fmt_dur(dur_secs)}</td>"
            f"<td>{log_btn}</td>"
            f"</tr>\n"
        )
    if not rows_html:
        rows_html = "<tr><td colspan='6' style='text-align:center;color:#555'><span class='i' data-pt='Sem eventos registados.' data-en='No events recorded yet.'>Sem eventos registados.</span></td></tr>"

    return f"""<!DOCTYPE html>
<html lang="pt">
<head>
  <meta charset="utf-8">
  <title>Backup &mdash; {FACILITY}</title>
  <style>
    *{{box-sizing:border-box;margin:0;padding:0}}
    body{{font-family:monospace;background:#0f0f1a;color:#e0e0e0;padding:24px}}
    h1{{color:#4CAF50;font-size:1.2rem;margin-bottom:2px}}
    .sub{{color:#666;font-size:.82em;margin-bottom:14px}}
    .bar{{background:#161626;border:1px solid #2a2a44;border-radius:6px;padding:10px 14px;margin-bottom:16px}}
    .bar-row{{display:flex;align-items:center;gap:10px;flex-wrap:wrap}}
    .bar-row+.bar-row{{margin-top:8px;padding-top:8px;border-top:1px solid #1e1e30}}
    .spacer{{flex:1}}
    .badge{{display:inline-flex;align-items:center;gap:5px;padding:4px 11px;border-radius:4px;font-size:.78em;font-weight:bold;white-space:nowrap}}
    .badge.ok{{background:#1a3d28;color:#4CAF50;border:1px solid #2d6a40}}
    .badge.warn{{background:#3d2a1a;color:#e67e22;border:1px solid #6a4020}}
    .badge.info{{background:#1a2a3d;color:#5dade2;border:1px solid #1f4068}}
    .badge.err{{background:#3d1a1a;color:#e74c3c;border:1px solid #6a2020}}
    .divider{{width:1px;height:24px;background:#2a2a44;flex-shrink:0}}
    .btn{{padding:5px 14px;border-radius:4px;font-size:.8em;font-family:monospace;cursor:pointer;border:none;font-weight:bold;white-space:nowrap}}
    .btn-backup{{background:#922b21;color:#fff}}
    .btn-backup:hover{{background:#c0392b}}
    .btn-backup:disabled{{background:#3a2020;color:#555;cursor:not-allowed}}
    .btn-recheck{{background:#1e1e3a;color:#7ecfff;border:1px solid #2a3a5a}}
    .btn-recheck:hover{{background:#252545}}
    .btn-lang{{background:#1e1e3a;color:#7ecfff;border:1px solid #2a3a5a;min-width:44px;text-align:center}}
    .btn-lang:hover{{background:#252545}}
    .refresh-wrap{{font-size:.78em;color:#666;display:flex;align-items:center;gap:6px;white-space:nowrap}}
    .refresh-wrap select{{background:#1a1a2e;color:#aaa;border:1px solid #333;padding:3px 6px;font-size:.9em;font-family:monospace;border-radius:3px}}
    .meta-info{{font-size:.75em;color:#555;display:flex;align-items:center;gap:16px;flex-wrap:wrap}}
    .meta-info strong{{color:#666}}
    table{{width:100%;border-collapse:collapse;font-size:.85em}}
    th{{background:#1e1e3a;padding:8px 14px;text-align:left;border-bottom:2px solid #2a2a4a;color:#888;font-weight:normal}}
    td{{padding:8px 14px;border-bottom:1px solid #1e1e2e;vertical-align:middle}}
    tr:hover td{{background:#16162a}}
    .btn-row-log{{background:none;border:1px solid #2a2a44;color:#666;font-family:monospace;font-size:.75em;padding:2px 8px;border-radius:3px;cursor:pointer}}
    .btn-row-log:hover{{border-color:#5dade2;color:#5dade2}}
    .log-panel{{background:#0a0a18;border:1px solid #2a2a4a;border-radius:6px;padding:14px;font-size:.82em;line-height:1.8;max-height:360px;overflow-y:auto}}
    .log-hdr{{color:#5dade2;margin-bottom:10px;padding-bottom:6px;border-bottom:1px solid #1e1e3a;display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:6px}}
    .log-back{{color:#888;cursor:pointer;font-size:.9em}}
    .log-back:hover{{color:#ccc}}
    .ll-ok{{color:#4CAF50}}.ll-warn{{color:#e67e22}}.ll-info{{color:#666}}
    .spin{{display:inline-block;animation:spin 1s linear infinite}}
    @keyframes spin{{to{{transform:rotate(360deg)}}}}
  </style>
</head>
<body>
  <h1>&#128202; <span class="i" data-pt="Estado do Backup" data-en="Backup Status">Estado do Backup</span></h1>
  <p class="sub"><span class="i" data-pt="Unidade Sanit&#225;ria" data-en="Health Facility">Unidade Sanit&#225;ria</span>: <strong>{FACILITY}</strong></p>

  <div class="bar">
    <div class="bar-row">
      {drive_section}
      {running_badge}
      <div class="divider"></div>
      <button class="btn btn-backup" id="btn-backup" {btn_backup_disabled} onclick="triggerBackup()">
        &#9654; <span class="i" data-pt="Backup Agora" data-en="Backup Now">Backup Agora</span>
      </button>
      <button class="btn btn-recheck" id="btn-recheck" onclick="doRecheck()">
        &#8635; <span class="i" data-pt="Re-verificar" data-en="Re-check">Re-verificar</span>
      </button>
      <div class="spacer"></div>
      <button class="btn btn-lang" id="btn-lang" onclick="toggleLang()">PT</button>
      <div class="divider"></div>
      <div class="refresh-wrap">
        <span class="i" data-pt="Auto-refresh" data-en="Auto-refresh">Auto-refresh</span>:
        <select id="refresh-sel" onchange="setRefresh(this.value)">
          <option value="0" class="i" data-pt="Nunca" data-en="Never">Nunca</option>
          <option value="5">5s</option>
          <option value="10">10s</option>
          <option value="15">15s</option>
          <option value="30" selected>30s</option>
          <option value="60">60s</option>
        </select>
      </div>
    </div>
    <div class="bar-row">
      <div class="spacer"></div>
      <div class="meta-info">
        <span><span class="i" data-pt="&#218;ltima verifica&#231;&#227;o" data-en="Last checked">&#218;ltima verifica&#231;&#227;o</span>: <strong id="last-checked">{now_utc}</strong></span>
        <span><span class="i" data-pt="Hist&#243;rico" data-en="History">Hist&#243;rico</span>: <strong>{RETENTION} <span class="i" data-pt="dias" data-en="days">dias</span></strong></span>
      </div>
    </div>
  </div>

  <div id="tbl">
    <table>
      <thead><tr>
        <th class="i" data-pt="Task" data-en="Task">Task</th>
        <th class="i" data-pt="Status" data-en="Status">Status</th>
        <th class="i" data-pt="In&#237;cio (UTC)" data-en="Start (UTC)">In&#237;cio (UTC)</th>
        <th class="i" data-pt="Fim (UTC)" data-en="End (UTC)">Fim (UTC)</th>
        <th class="i" data-pt="Dura&#231;&#227;o" data-en="Duration">Dura&#231;&#227;o</th>
        <th class="i" data-pt="Log" data-en="Log">Log</th>
      </tr></thead>
      <tbody>{rows_html}</tbody>
    </table>
  </div>

  <div id="log-sec" style="display:none">
    <div class="log-panel">
      <div class="log-hdr">
        <span id="log-title"></span>
        <span class="log-back" onclick="showTable()">&#8592; <span class="i" data-pt="Voltar &#224; tabela" data-en="Back to table">Voltar &#224; tabela</span></span>
      </div>
      <div id="log-body"></div>
    </div>
  </div>

  <script>
  var LANG='pt', refreshTimer=null;
  var FACILITY='{FACILITY}';

  // ── i18n ──
  function applyLang(){{
    document.querySelectorAll('.i[data-'+LANG+']').forEach(function(el){{
      el.textContent=el.getAttribute('data-'+LANG);
    }});
    document.querySelectorAll('select option.i[data-'+LANG+']').forEach(function(opt){{
      opt.textContent=opt.getAttribute('data-'+LANG);
    }});
    document.getElementById('btn-lang').textContent=LANG.toUpperCase();
    document.documentElement.lang=LANG;
  }}
  function toggleLang(){{
    LANG=LANG==='pt'?'en':'pt';
    try{{localStorage.setItem('hf_backup_lang',LANG);}}catch(e){{}}
    applyLang();
  }}

  // ── Auto-refresh ──
  function setRefresh(val){{
    clearTimeout(refreshTimer);
    var secs=parseInt(val,10);
    if(secs>0){{
      refreshTimer=setTimeout(function(){{
        if(document.getElementById('log-sec').style.display==='none') location.reload();
        else setRefresh(val); // defer while log open
      }},secs*1000);
    }}
    try{{localStorage.setItem('hf_backup_refresh_interval',val);}}catch(e){{}}
  }}

  // ── Log panel ──
  function showLog(dateKey){{
    document.getElementById('tbl').style.display='none';
    document.getElementById('log-sec').style.display='';
    clearTimeout(refreshTimer);
    var title=dateKey+'-'+FACILITY+'-backup.log';
    document.getElementById('log-title').textContent='\U0001F4C4 '+title;
    document.getElementById('log-body').innerHTML='<span style="color:#666">A carregar\u2026</span>';
    fetch('/api/log?date='+dateKey)
      .then(function(r){{return r.text();}} )
      .then(function(txt){{
        var html=txt.split('\\n').map(function(line){{
          if(!line) return '';
          var cls='ll-info';
          if(/state=(completed|starting)/.test(line)||/\u2713/.test(line)) cls='ll-ok';
          if(/state=failed|ERROR|WARN/.test(line)) cls='ll-warn';
          return '<div class="'+cls+'">'+line.replace(/&/g,'&amp;').replace(/</g,'&lt;')+'</div>';
        }}).join('');
        document.getElementById('log-body').innerHTML=html||'<span style="color:#666">(empty)</span>';
      }})
      .catch(function(){{
        document.getElementById('log-body').innerHTML='<span style="color:#e74c3c">Erro ao carregar log.</span>';
      }});
  }}
  function showTable(){{
    document.getElementById('log-sec').style.display='none';
    document.getElementById('tbl').style.display='';
    var sel=document.getElementById('refresh-sel');
    setRefresh(sel?sel.value:'30');
  }}

  // ── Re-check ──
  function doRecheck(){{
    var btn=document.getElementById('btn-recheck');
    btn.innerHTML='<span class="spin">&#8635;</span> '+(LANG==='pt'?'A verificar\u2026':'Checking\u2026');
    btn.disabled=true;
    fetch('/api/status')
      .then(function(r){{return r.json();}} )
      .then(function(s){{
        document.getElementById('last-checked').textContent=new Date().toISOString().replace('T',' ').slice(0,19)+' UTC';
        // Reload to reflect updated badge states from server-rendered HTML
        location.reload();
      }})
      .catch(function(){{btn.disabled=false;btn.innerHTML='&#8635; '+(LANG==='pt'?'Re-verificar':'Re-check');}});
  }}

  // ── Backup Now ──
  function triggerBackup(){{
    var msg=LANG==='pt'
      ?'Iniciar um backup imediato agora?\n\nEsta opera\u00e7\u00e3o pode demorar v\u00e1rios minutos.'
      :'Start an immediate backup now?\n\nThis may take several minutes.';
    if(!confirm(msg)) return;
    var btn=document.getElementById('btn-backup');
    btn.disabled=true;
    btn.innerHTML='&#9654; '+(LANG==='pt'?'A iniciar\u2026':'Starting\u2026');
    fetch('/api/trigger-backup',{{method:'POST'}})
      .then(function(r){{
        if(r.status===409){{btn.innerHTML='&#9654; '+(LANG==='pt'?'Backup Agora':'Backup Now');btn.disabled=true;return;}}
        if(!r.ok) throw new Error(r.status);
        // Force 5s refresh so running status appears quickly
        clearTimeout(refreshTimer);
        refreshTimer=setTimeout(function(){{location.reload();}},5000);
      }})
      .catch(function(){{btn.disabled=false;btn.innerHTML='&#9654; '+(LANG==='pt'?'Backup Agora':'Backup Now');}});
  }}

  // ── Init ──
  (function(){{
    try{{
      var savedLang=localStorage.getItem('hf_backup_lang');
      if(savedLang==='en') LANG='en';
      var savedRefresh=localStorage.getItem('hf_backup_refresh_interval');
      var sel=document.getElementById('refresh-sel');
      if(savedRefresh&&sel){{
        sel.value=savedRefresh;
        setRefresh(savedRefresh);
      }} else {{
        setRefresh('30');
      }}
    }}catch(e){{setRefresh('30');}}
    applyLang();
  }})();
  </script>
</body>
</html>"""


# ── HTTP handler ───────────────────────────────────────────────────────────────

class _Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # suppress per-request noise

    def _send(self, status, content_type, body):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if path == "/api/status":
            _purge_old()
            data = _get_status()
            self._send(200, "application/json", json.dumps(data))
        elif path == "/api/log":
            qs = parse_qs(parsed.query)
            date_param = qs.get("date", [None])[0]
            if not date_param:
                self._send(400, "text/plain", "Missing date parameter\n")
                return
            st, ct, body = _serve_log(date_param)
            self._send(st, ct, body)
        elif path == "/" or path == "":
            _purge_old()
            status = _get_status()
            events = _get_events()
            html = _render(status, events)
            self._send(200, "text/html; charset=utf-8", html)
        else:
            self._send(404, "text/plain", "Not found\n")

    def do_POST(self):
        if self.path == "/api/trigger-backup":
            st, body = _handle_trigger()
            self._send(st, "text/plain", body)
        else:
            self._send(404, "text/plain", "Not found\n")


if __name__ == "__main__":
    print(f"[web-server] facility={FACILITY}  port={PORT}", flush=True)
    HTTPServer(("0.0.0.0", PORT), _Handler).serve_forever()
