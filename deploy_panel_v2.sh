#!/bin/bash
set -e

echo "==> Actualizando panel.js (v2)..."
cat > /root/aura-luz/src/panel.js << 'EOF'
const express = require('express');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const router = express.Router();

const DB_PATH = path.join(__dirname, '..', 'data', 'store.json');

function getPassword() { return process.env.PANEL_PASSWORD || ''; }
function makeToken(p) { return crypto.createHmac('sha256', p + 'aura-luz-panel-v1').update('token').digest('hex'); }
function isAuthenticated(req) {
  if (!req.cookies) return false;
  const token = req.cookies['panel_token'];
  if (!token) return false;
  try {
    const expected = makeToken(getPassword());
    if (token.length !== expected.length) return false;
    return crypto.timingSafeEqual(Buffer.from(token), Buffer.from(expected));
  } catch(e) { return false; }
}
function loadDB() {
  if (!fs.existsSync(DB_PATH)) return { sessions: {}, appointments: {} };
  return JSON.parse(fs.readFileSync(DB_PATH, 'utf-8'));
}
function escHtml(str) {
  return String(str || '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;');
}
function formatDT(iso) {
  if (!iso) return '';
  try { return new Date(iso).toLocaleString('es-CO', { timeZone:'America/Bogota', day:'numeric', month:'short', hour:'numeric', minute:'2-digit', hour12:true }); }
  catch(e) { return iso; }
}
function getLocalDate(iso) {
  if (!iso) return '';
  try { return new Date(iso).toLocaleDateString('en-CA', { timeZone:'America/Bogota' }); }
  catch(e) { return ''; }
}

const CSS_BASE = `
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#f0f2f5;color:#1a1a2e}
`;

// ---- Login ----
router.get('/login', (req, res) => {
  const err = req.query.error ? '<p class="err">Contraseña incorrecta.</p>' : '';
  res.send(`<!DOCTYPE html><html lang="es"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Seguimiento Chats DRG Soul</title><style>${CSS_BASE}
body{display:flex;align-items:center;justify-content:center;min-height:100vh}
.card{background:#fff;border-radius:14px;padding:2.2rem;width:100%;max-width:360px;box-shadow:0 2px 16px rgba(0,0,0,0.10)}
h1{font-size:1.4rem;color:#1a1a2e;margin-bottom:0.2rem}.sub{color:#888;font-size:0.9rem;margin-bottom:1.8rem}
input{width:100%;padding:0.8rem 1rem;border:1.5px solid #e0e0e0;border-radius:8px;font-size:1rem;margin-bottom:1rem;outline:none;transition:border 0.2s}
input:focus{border-color:#7c5cbf}button{width:100%;padding:0.8rem;background:#7c5cbf;color:#fff;border:none;border-radius:8px;font-size:1rem;cursor:pointer;font-weight:600}
button:hover{background:#6a4daa}.err{color:#c0392b;font-size:0.88rem;margin-bottom:1rem;background:#fdecea;padding:0.6rem 0.8rem;border-radius:6px}
</style></head><body><div class="card">
<h1>💛 DRG Soul</h1><p class="sub">Seguimiento de chats</p>${err}
<form method="POST" action="/panel/login">
<input type="password" name="password" placeholder="Contraseña" autofocus required autocomplete="current-password">
<button type="submit">Entrar</button></form></div></body></html>`);
});

router.post('/login', express.urlencoded({ extended: false }), (req, res) => {
  const { password } = req.body;
  try {
    const expected = makeToken(getPassword());
    const attempt = makeToken(password || '');
    if (expected.length === attempt.length && crypto.timingSafeEqual(Buffer.from(attempt), Buffer.from(expected))) {
      res.cookie('panel_token', expected, { httpOnly:true, maxAge:7*24*60*60*1000, sameSite:'strict' });
      return res.redirect('/panel');
    }
  } catch(e) {}
  res.redirect('/panel/login?error=1');
});

router.get('/logout', (req, res) => { res.clearCookie('panel_token'); res.redirect('/panel/login'); });

router.use((req, res, next) => {
  if (!isAuthenticated(req)) return res.redirect('/panel/login');
  next();
});

// ---- Lista de conversaciones ----
router.get('/', (req, res) => {
  const db = loadDB();
  const sessions = db.sessions || {};
  const appointments = db.appointments || {};
  const search = req.query.q || '';
  const dateFilter = req.query.date || '';
  const today = getLocalDate(new Date().toISOString());
  const yesterday = getLocalDate(new Date(Date.now() - 86400000).toISOString());

  const convs = Object.values(sessions)
    .filter(s => s.phone && s.phone !== 'admin:daniela' && s.displayHistory && s.displayHistory.length > 0)
    .map(s => {
      const phoneClean = String(s.phone).replace(/\D/g, '');
      const appt = Object.values(appointments).find(a => {
        const ap = a.phone ? String(a.phone).replace(/\D/g, '') : '';
        return ap && phoneClean && ap === phoneClean;
      });
      const name = (appt && appt.name) || s.profileName || s.phone;
      const dh = s.displayHistory || [];
      const lastMsg = dh[dh.length - 1];
      const lastAt = s.lastAt || (lastMsg && lastMsg.timestamp) || '';
      const preview = lastMsg ? lastMsg.text.replace(/\n/g,' ').slice(0,90) : '';
      const lastRole = lastMsg ? lastMsg.role : '';
      return { phone: s.phone, name, lastAt, preview, count: dh.length, lastRole };
    })
    .sort((a, b) => new Date(b.lastAt) - new Date(a.lastAt));

  let filtered = convs;
  if (search) {
    const q = search.toLowerCase();
    filtered = filtered.filter(c => c.name.toLowerCase().includes(q) || String(c.phone).includes(q));
  }
  if (dateFilter) {
    filtered = filtered.filter(c => getLocalDate(c.lastAt) === dateFilter);
  }

  const rows = filtered.map(c => {
    const encodedPhone = encodeURIComponent(c.phone);
    const dt = formatDT(c.lastAt);
    const previewClass = c.lastRole === 'assistant' ? 'preview aura-preview' : 'preview';
    const prefix = c.lastRole === 'assistant' ? '<span class="aura-badge">Aura</span> ' : '';
    return `<tr onclick="location.href='/panel/chat/${encodedPhone}'" style="cursor:pointer">
      <td><strong>${escHtml(c.name)}</strong><br><span class="mono">${escHtml(String(c.phone))}</span></td>
      <td class="${previewClass}">${prefix}${escHtml(c.preview)}</td>
      <td class="dt">${escHtml(dt)}</td>
      <td class="center">${c.count}</td>
    </tr>`;
  }).join('');

  res.send(`<!DOCTYPE html><html lang="es"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Seguimiento Chats DRG Soul</title><style>${CSS_BASE}
.topbar{background:#7c5cbf;color:#fff;padding:1rem 1.5rem;display:flex;justify-content:space-between;align-items:center;gap:1rem}
.topbar h1{font-size:1.1rem;font-weight:700;white-space:nowrap}
.topbar-right{display:flex;gap:0.6rem;align-items:center;flex-shrink:0}
.btn-top{background:rgba(255,255,255,0.18);color:#fff;border:1.5px solid rgba(255,255,255,0.35);padding:0.4rem 0.85rem;border-radius:6px;cursor:pointer;font-size:0.85rem;font-weight:500;text-decoration:none;white-space:nowrap}
.btn-top:hover{background:rgba(255,255,255,0.28)}
.controls{background:#fff;border-bottom:1px solid #eee;padding:0.85rem 1.5rem;display:flex;gap:0.6rem;flex-wrap:wrap;align-items:center}
.controls input[type=search]{flex:1;min-width:160px;padding:0.55rem 0.85rem;border:1.5px solid #e0e0e0;border-radius:7px;font-size:0.9rem;outline:none}
.controls input[type=date]{padding:0.55rem 0.75rem;border:1.5px solid #e0e0e0;border-radius:7px;font-size:0.9rem;outline:none}
.controls input:focus{border-color:#7c5cbf}
.btn-f{padding:0.55rem 1rem;border:1.5px solid #e0e0e0;border-radius:7px;background:#fff;cursor:pointer;font-size:0.85rem;text-decoration:none;color:#444;white-space:nowrap}
.btn-f:hover{background:#f5f0ff;border-color:#7c5cbf;color:#7c5cbf}
.btn-f.active{background:#7c5cbf;color:#fff;border-color:#7c5cbf}
.container{padding:1.5rem}
.stat{color:#888;font-size:0.85rem;margin-bottom:0.85rem}
table{width:100%;border-collapse:collapse;background:#fff;border-radius:10px;overflow:hidden;box-shadow:0 1px 5px rgba(0,0,0,0.07)}
th{background:#f8f6ff;padding:0.7rem 1rem;text-align:left;font-size:0.75rem;color:#888;text-transform:uppercase;letter-spacing:0.06em;border-bottom:1px solid #eee}
td{padding:0.82rem 1rem;border-top:1px solid #f2f2f2;vertical-align:middle;font-size:0.9rem}
tr:hover td{background:#faf8ff}
.preview{color:#666;max-width:340px;font-size:0.87rem;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:320px}
.aura-preview{color:#7c5cbf}
.aura-badge{font-size:0.72rem;background:#ede0ff;color:#6a4daa;padding:0.1rem 0.4rem;border-radius:4px;margin-right:0.3rem;font-weight:600}
.dt{white-space:nowrap;color:#999;font-size:0.8rem}
.center{text-align:center;color:#999;font-size:0.85rem;width:50px}
.mono{font-size:0.76rem;color:#bbb;font-family:monospace}
.empty{text-align:center;padding:3rem 1rem;color:#aaa}
</style></head><body>
<div class="topbar">
  <h1>💛 Seguimiento Chats DRG Soul</h1>
  <div class="topbar-right">
    <button onclick="location.reload()" class="btn-top">&#8635; Actualizar</button>
    <a href="/panel/logout" class="btn-top">Salir</a>
  </div>
</div>
<form class="controls" method="GET" action="/panel">
  <input type="search" name="q" placeholder="Buscar nombre o numero..." value="${escHtml(search)}">
  <input type="date" name="date" value="${escHtml(dateFilter)}">
  <button type="submit" class="btn-f" style="background:#7c5cbf;color:#fff;border-color:#7c5cbf">Buscar</button>
  <a href="/panel?date=${today}" class="btn-f${dateFilter===today?' active':''}">Hoy</a>
  <a href="/panel?date=${yesterday}" class="btn-f${dateFilter===yesterday?' active':''}">Ayer</a>
  <a href="/panel" class="btn-f${!dateFilter&&!search?' active':''}">Todas</a>
</form>
<div class="container">
  <p class="stat">${filtered.length} conversación${filtered.length!==1?'es':''}</p>
  ${filtered.length===0
    ? '<div class="empty">No hay conversaciones que coincidan.</div>'
    : `<table><thead><tr><th>Paciente</th><th>Último mensaje</th><th>Fecha</th><th style="text-align:center">Msgs</th></tr></thead><tbody>${rows}</tbody></table>`}
</div>
</body></html>`);
});

// ---- Conversación individual ----
router.get('/chat/:phone', (req, res) => {
  const db = loadDB();
  const phone = decodeURIComponent(req.params.phone);
  const session = db.sessions[phone];
  if (!session) return res.redirect('/panel');

  const appointments = db.appointments || {};
  const phoneClean = String(phone).replace(/\D/g, '');
  const appt = Object.values(appointments).find(a => {
    const ap = a.phone ? String(a.phone).replace(/\D/g, '') : '';
    return ap && phoneClean && ap === phoneClean;
  });
  const name = (appt && appt.name) || session.profileName || phone;
  const dh = session.displayHistory || [];
  const totalMsgs = dh.length;
  const firstDate = totalMsgs > 0 ? formatDT(dh[0].timestamp) : '';

  const bubbles = totalMsgs === 0
    ? '<div class="empty-chat">Las conversaciones futuras aparecerán aquí.<br>Los mensajes anteriores a la instalación del panel no están registrados.</div>'
    : dh.map(m => {
        const isPatient = m.role === 'user';
        const dt = formatDT(m.timestamp);
        const label = isPatient ? escHtml(name) : 'Aura Luz';
        const audioTag = m.fromAudio ? '<span class="audio-tag">🎤 audio</span>' : '';
        const txt = m.text ? escHtml(m.text).replace(/\n/g,'<br>') : '<em style="color:#bbb">mensaje vacío</em>';
        return `<div class="bwrap ${isPatient?'patient':'aura'}">
          <div class="bubble">
            <div class="meta">${label}${dt?' &middot; '+dt:''}</div>
            ${audioTag?'<div class="audio-row">'+audioTag+'</div>':''}
            <div class="text">${txt}</div>
          </div>
        </div>`;
      }).join('');

  res.send(`<!DOCTYPE html><html lang="es"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${escHtml(name)} — DRG Soul</title><style>${CSS_BASE}
body{display:flex;flex-direction:column;height:100vh;overflow:hidden}
.topbar{background:#7c5cbf;color:#fff;padding:0.85rem 1.2rem;display:flex;align-items:center;gap:0.85rem;flex-shrink:0;box-shadow:0 2px 6px rgba(0,0,0,0.15)}
.back{color:#fff;text-decoration:none;font-size:1.4rem;line-height:1;flex-shrink:0;opacity:0.9}
.back:hover{opacity:1}
.info{flex:1;min-width:0}
.info h1{font-size:1.05rem;font-weight:700;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.info .sub{font-size:0.75rem;opacity:0.7;font-family:monospace;margin-top:0.1rem}
.btn-ref{background:rgba(255,255,255,0.18);color:#fff;border:1.5px solid rgba(255,255,255,0.35);padding:0.4rem 0.85rem;border-radius:6px;cursor:pointer;font-size:0.82rem;flex-shrink:0;white-space:nowrap}
.btn-ref:hover{background:rgba(255,255,255,0.28)}
.chat-info{background:#f5f0ff;border-bottom:1px solid #e4d9f7;padding:0.55rem 1.2rem;font-size:0.8rem;color:#7c5cbf;flex-shrink:0;display:flex;gap:1.5rem}
.chat-info span{display:flex;align-items:center;gap:0.3rem}
.chat{flex:1;overflow-y:auto;padding:1.2rem 1rem;display:flex;flex-direction:column;gap:0.65rem;background:#ede8f5}
.bwrap{display:flex}
.bwrap.patient{justify-content:flex-start}
.bwrap.aura{justify-content:flex-end}
.bubble{max-width:72%;padding:0.55rem 0.9rem;border-radius:12px;font-size:0.9rem;line-height:1.5;word-break:break-word;box-shadow:0 1px 3px rgba(0,0,0,0.08)}
.patient .bubble{background:#fff;border-bottom-left-radius:3px}
.aura .bubble{background:#d4bff7;border-bottom-right-radius:3px}
.meta{font-size:0.7rem;color:#999;margin-bottom:0.3rem}
.aura .meta{text-align:right;color:#8860c2}
.text{white-space:pre-wrap;line-height:1.5}
.audio-row{margin-bottom:0.3rem}
.audio-tag{font-size:0.72rem;background:#ede0ff;color:#6a4daa;padding:0.15rem 0.45rem;border-radius:4px;display:inline-block}
.empty-chat{text-align:center;color:#aaa;font-size:0.9rem;margin:auto;max-width:280px;line-height:1.7;padding:2rem}
</style></head><body>
<div class="topbar">
  <a href="/panel" class="back">&#8592;</a>
  <div class="info">
    <h1>${escHtml(name)}</h1>
    <div class="sub">${escHtml(String(phone))}</div>
  </div>
  <button onclick="location.reload()" class="btn-ref">&#8635; Actualizar</button>
</div>
<div class="chat-info">
  <span>💬 ${totalMsgs} mensajes</span>
  ${firstDate ? `<span>📅 Desde ${escHtml(firstDate)}</span>` : ''}
</div>
<div class="chat" id="chat">${bubbles}</div>
<script>const c=document.getElementById('chat');if(c)c.scrollTop=c.scrollHeight;</script>
</body></html>`);
});

module.exports = router;
EOF

echo "==> Reiniciando servicio..."
systemctl restart aura-luz
sleep 2
echo "✅ Panel v2 listo. Recarga la pagina."
