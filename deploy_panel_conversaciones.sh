#!/bin/bash
set -e

echo "==> Paso 1: Instalando cookie-parser..."
cd /root/aura-luz && npm install cookie-parser --save --silent

echo "==> Paso 2: Respaldo de store.json..."
cp /root/aura-luz/data/store.json "/root/aura-luz/data/store.json.bak.$(date +%Y%m%d%H%M%S)"
echo "    Respaldo creado."

echo "==> Paso 3: Limpiando sesiones de mas de 24h..."
cat > /tmp/clean_sessions.js << 'JSEOF'
const fs = require('fs');
const DB_PATH = '/root/aura-luz/data/store.json';
try {
  const db = JSON.parse(fs.readFileSync(DB_PATH, 'utf-8'));
  const now = Date.now();
  const DAY = 24 * 60 * 60 * 1000;
  let cleaned = 0;
  let kept = 0;
  for (const key of Object.keys(db.sessions || {})) {
    if (key === 'admin:daniela') continue;
    const s = db.sessions[key];
    const lastAt = s.lastAt ? new Date(s.lastAt).getTime() : 0;
    if (!lastAt || now - lastAt > DAY) {
      delete db.sessions[key];
      cleaned++;
    } else {
      kept++;
    }
  }
  fs.writeFileSync(DB_PATH, JSON.stringify(db, null, 2));
  console.log('Sesiones eliminadas: ' + cleaned + ' | Conservadas (activas hoy): ' + kept);
} catch(e) {
  console.error('Error limpiando sesiones:', e.message);
  process.exit(1);
}
JSEOF
node /tmp/clean_sessions.js

echo "==> Paso 4: Creando panel de conversaciones (src/panel.js)..."
cat > /root/aura-luz/src/panel.js << 'EOF'
const express = require('express');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const router = express.Router();

const DB_PATH = path.join(__dirname, '..', 'data', 'store.json');

function getPassword() {
  return process.env.PANEL_PASSWORD || '';
}

function makeToken(password) {
  return crypto.createHmac('sha256', password + 'aura-luz-panel-v1').update('token').digest('hex');
}

function isAuthenticated(req) {
  if (!req.cookies) return false;
  const token = req.cookies['panel_token'];
  if (!token) return false;
  try {
    const expected = makeToken(getPassword());
    if (token.length !== expected.length) return false;
    return crypto.timingSafeEqual(Buffer.from(token), Buffer.from(expected));
  } catch(e) {
    return false;
  }
}

function loadDB() {
  if (!fs.existsSync(DB_PATH)) return { sessions: {}, appointments: {} };
  return JSON.parse(fs.readFileSync(DB_PATH, 'utf-8'));
}

function escHtml(str) {
  return String(str || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function formatDT(isoStr) {
  if (!isoStr) return '';
  try {
    return new Date(isoStr).toLocaleString('es-CO', {
      timeZone: 'America/Bogota',
      day: 'numeric', month: 'short',
      hour: 'numeric', minute: '2-digit', hour12: true
    });
  } catch(e) { return isoStr; }
}

// ---- Login ----
router.get('/login', (req, res) => {
  const err = req.query.error ? '<p class="err">Contrasena incorrecta, intenta de nuevo.</p>' : '';
  res.send(`<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Aura Luz — Acceso</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#f0f2f5;display:flex;align-items:center;justify-content:center;min-height:100vh}
.card{background:#fff;border-radius:14px;padding:2.2rem;width:100%;max-width:360px;box-shadow:0 2px 16px rgba(0,0,0,0.10)}
h1{font-size:1.5rem;color:#1a1a2e;margin-bottom:0.2rem}
.sub{color:#888;font-size:0.9rem;margin-bottom:1.8rem}
input{width:100%;padding:0.8rem 1rem;border:1.5px solid #e0e0e0;border-radius:8px;font-size:1rem;margin-bottom:1rem;outline:none;transition:border 0.2s}
input:focus{border-color:#7c5cbf}
button{width:100%;padding:0.8rem;background:#7c5cbf;color:#fff;border:none;border-radius:8px;font-size:1rem;cursor:pointer;font-weight:600}
button:hover{background:#6a4daa}
.err{color:#c0392b;font-size:0.88rem;margin-bottom:1rem;background:#fdecea;padding:0.6rem 0.8rem;border-radius:6px}
</style>
</head>
<body>
<div class="card">
  <h1>💛 Aura Luz</h1>
  <p class="sub">Panel de conversaciones</p>
  ${err}
  <form method="POST" action="/panel/login">
    <input type="password" name="password" placeholder="Contrasena" autofocus required autocomplete="current-password">
    <button type="submit">Entrar</button>
  </form>
</div>
</body></html>`);
});

router.post('/login', express.urlencoded({ extended: false }), (req, res) => {
  const { password } = req.body;
  try {
    const expected = makeToken(getPassword());
    const attempt = makeToken(password || '');
    if (expected.length === attempt.length && crypto.timingSafeEqual(Buffer.from(attempt), Buffer.from(expected))) {
      res.cookie('panel_token', expected, { httpOnly: true, maxAge: 7 * 24 * 60 * 60 * 1000, sameSite: 'strict' });
      return res.redirect('/panel');
    }
  } catch(e) {}
  res.redirect('/panel/login?error=1');
});

router.get('/logout', (req, res) => {
  res.clearCookie('panel_token');
  res.redirect('/panel/login');
});

// ---- Auth middleware para todo lo que sigue ----
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
  const today = new Date().toLocaleDateString('en-CA', { timeZone: 'America/Bogota' });
  const yesterday = new Date(Date.now() - 86400000).toLocaleDateString('en-CA', { timeZone: 'America/Bogota' });

  const convs = Object.values(sessions)
    .filter(s => s.phone && s.phone !== 'admin:daniela')
    .map(s => {
      const phoneClean = String(s.phone).replace(/\D/g, '');
      const appt = Object.values(appointments).find(a => {
        const ap = a.phone ? String(a.phone).replace(/\D/g, '') : '';
        return ap && phoneClean && ap === phoneClean;
      });
      const name = (appt && appt.name) || s.profileName || s.phone;
      const dh = s.displayHistory || [];
      const lastMsg = dh.length > 0 ? dh[dh.length - 1] : null;
      const lastAt = s.lastAt || (lastMsg && lastMsg.timestamp) || '';
      const preview = lastMsg ? lastMsg.text.slice(0, 90).replace(/\n/g, ' ') : '(sin mensajes registrados aun)';
      const hasDisplay = dh.length > 0;
      return { phone: s.phone, name, lastAt, preview, count: dh.length, hasDisplay };
    })
    .sort((a, b) => new Date(b.lastAt) - new Date(a.lastAt));

  let filtered = convs;
  if (search) {
    const q = search.toLowerCase();
    filtered = filtered.filter(c => c.name.toLowerCase().includes(q) || String(c.phone).includes(q));
  }
  if (dateFilter) {
    filtered = filtered.filter(c => {
      if (!c.lastAt) return false;
      const d = new Date(c.lastAt).toLocaleDateString('en-CA', { timeZone: 'America/Bogota' });
      return d === dateFilter;
    });
  }

  const rows = filtered.map(c => {
    const encodedPhone = encodeURIComponent(c.phone);
    const dt = formatDT(c.lastAt);
    const dim = !c.hasDisplay ? ' style="opacity:0.5"' : '';
    return `<tr onclick="location.href='/panel/chat/${encodedPhone}'" style="cursor:pointer"${dim}>
      <td><strong>${escHtml(c.name)}</strong><br><span class="mono">${escHtml(String(c.phone))}</span></td>
      <td class="preview">${escHtml(c.preview)}</td>
      <td class="dt">${escHtml(dt)}</td>
      <td class="center">${c.count}</td>
    </tr>`;
  }).join('');

  res.send(`<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Aura Luz — Conversaciones</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#f0f2f5;color:#1a1a2e}
.topbar{background:#7c5cbf;color:#fff;padding:1rem 1.5rem;display:flex;justify-content:space-between;align-items:center}
.topbar h1{font-size:1.15rem;font-weight:700}
.topbar a{color:#fff;font-size:0.85rem;opacity:0.82;text-decoration:none}
.topbar a:hover{opacity:1}
.controls{background:#fff;border-bottom:1px solid #eee;padding:0.9rem 1.5rem;display:flex;gap:0.6rem;flex-wrap:wrap;align-items:center}
.controls input[type=search]{flex:1;min-width:160px;padding:0.55rem 0.85rem;border:1.5px solid #e0e0e0;border-radius:7px;font-size:0.9rem;outline:none}
.controls input[type=date]{padding:0.55rem 0.75rem;border:1.5px solid #e0e0e0;border-radius:7px;font-size:0.9rem;outline:none}
.controls input:focus{border-color:#7c5cbf}
.btn{padding:0.55rem 1rem;border:1.5px solid #e0e0e0;border-radius:7px;background:#fff;cursor:pointer;font-size:0.85rem;text-decoration:none;color:#444;white-space:nowrap}
.btn:hover{background:#f5f0ff;border-color:#7c5cbf;color:#7c5cbf}
.btn.active{background:#7c5cbf;color:#fff;border-color:#7c5cbf}
.btn-go{background:#7c5cbf;color:#fff;border-color:#7c5cbf}
.btn-go:hover{background:#6a4daa}
.container{padding:1.5rem}
.stat{color:#888;font-size:0.85rem;margin-bottom:0.85rem}
table{width:100%;border-collapse:collapse;background:#fff;border-radius:10px;overflow:hidden;box-shadow:0 1px 5px rgba(0,0,0,0.07)}
th{background:#f8f6ff;padding:0.7rem 1rem;text-align:left;font-size:0.75rem;color:#888;text-transform:uppercase;letter-spacing:0.06em;border-bottom:1px solid #eee}
td{padding:0.82rem 1rem;border-top:1px solid #f2f2f2;vertical-align:top;font-size:0.9rem}
tr:hover td{background:#faf8ff}
.preview{color:#666;max-width:320px;font-size:0.87rem}
.dt{white-space:nowrap;color:#999;font-size:0.8rem}
.center{text-align:center;color:#999;font-size:0.85rem}
.mono{font-size:0.76rem;color:#aaa;font-family:monospace}
.empty{text-align:center;padding:3rem 1rem;color:#aaa}
</style>
</head>
<body>
<div class="topbar">
  <h1>💛 Aura Luz — Conversaciones</h1>
  <a href="/panel/logout">Salir</a>
</div>
<form class="controls" method="GET" action="/panel">
  <input type="search" name="q" placeholder="Buscar nombre o numero..." value="${escHtml(search)}">
  <input type="date" name="date" value="${escHtml(dateFilter)}">
  <button type="submit" class="btn btn-go">Buscar</button>
  <a href="/panel?date=${today}" class="btn${dateFilter === today ? ' active' : ''}">Hoy</a>
  <a href="/panel?date=${yesterday}" class="btn${dateFilter === yesterday ? ' active' : ''}">Ayer</a>
  <a href="/panel" class="btn${!dateFilter && !search ? ' active' : ''}">Todas</a>
</form>
<div class="container">
  <p class="stat">${filtered.length} conversacion${filtered.length !== 1 ? 'es' : ''}</p>
  ${filtered.length === 0
    ? '<div class="empty">No hay conversaciones que coincidan.</div>'
    : `<table>
        <thead><tr><th>Paciente</th><th>Ultimo mensaje</th><th>Fecha</th><th>Msgs</th></tr></thead>
        <tbody>${rows}</tbody>
       </table>`}
</div>
</body></html>`);
});

// ---- Conversacion individual ----
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

  const bubbles = dh.length === 0
    ? '<div class="empty-chat">Las conversaciones futuras apareceran aqui con marca de tiempo.<br>Los mensajes anteriores al panel no estan registrados.</div>'
    : dh.map(m => {
        const isPatient = m.role === 'user';
        const dt = formatDT(m.timestamp);
        const label = isPatient ? escHtml(name) : 'Aura Luz';
        const audioTag = m.fromAudio ? '<span class="audio-tag">🎤 audio</span> ' : '';
        return `<div class="bwrap ${isPatient ? 'patient' : 'aura'}">
          <div class="bubble">
            <div class="meta">${label}${dt ? ' &middot; ' + dt : ''}</div>
            ${audioTag}<div class="text">${escHtml(m.text).replace(/\n/g, '<br>')}</div>
          </div>
        </div>`;
      }).join('');

  res.send(`<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${escHtml(name)} — Aura Luz</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#ece5f0;color:#1a1a2e;display:flex;flex-direction:column;height:100vh}
.topbar{background:#7c5cbf;color:#fff;padding:0.9rem 1.2rem;display:flex;align-items:center;gap:1rem;flex-shrink:0}
.topbar a{color:#fff;text-decoration:none;font-size:1.3rem;line-height:1}
.topbar .info{flex:1}
.topbar h1{font-size:1.05rem;font-weight:700}
.topbar .phone{font-size:0.78rem;opacity:0.75;font-family:monospace}
.chat{flex:1;overflow-y:auto;padding:1.2rem 1rem;display:flex;flex-direction:column;gap:0.6rem}
.bwrap{display:flex}
.bwrap.patient{justify-content:flex-start}
.bwrap.aura{justify-content:flex-end}
.bubble{max-width:75%;padding:0.6rem 0.9rem;border-radius:12px;font-size:0.9rem;line-height:1.5;word-break:break-word}
.patient .bubble{background:#fff;border-bottom-left-radius:3px;box-shadow:0 1px 2px rgba(0,0,0,0.07)}
.aura .bubble{background:#d9c8f0;border-bottom-right-radius:3px}
.meta{font-size:0.7rem;color:#999;margin-bottom:0.25rem}
.aura .meta{text-align:right}
.text{white-space:pre-wrap}
.audio-tag{font-size:0.72rem;background:#ede0ff;color:#6a4daa;padding:0.1rem 0.4rem;border-radius:4px;margin-right:0.3rem}
.empty-chat{text-align:center;color:#aaa;font-size:0.9rem;margin:3rem auto;max-width:280px;line-height:1.6}
</style>
</head>
<body>
<div class="topbar">
  <a href="/panel">&#8592;</a>
  <div class="info">
    <h1>${escHtml(name)}</h1>
    <div class="phone">${escHtml(String(phone))}</div>
  </div>
</div>
<div class="chat" id="chat">
  ${bubbles}
</div>
<script>
  const c = document.getElementById('chat');
  if(c) c.scrollTop = c.scrollHeight;
</script>
</body></html>`);
});

module.exports = router;
EOF

echo "==> Paso 5: Actualizando agent.js (con displayHistory)..."
cat > /root/aura-luz/src/aura/agent.js << 'EOF'
const Anthropic = require('@anthropic-ai/sdk');
const { v4: uuid } = require('uuid');
const config = require('../config');
const store = require('../store');
const { TOOLS } = require('./tools');
const { patientSystemPrompt, adminSystemPrompt } = require('./persona');
const { suggestNextSlots } = require('../scheduling/rules');
const { createTeamsAppointment, cancelAppointment, updateAppointmentSubject, eventExists } = require('../graph/calendar');

const anthropic = new Anthropic({ apiKey: config.anthropic.apiKey });
const MODEL = 'claude-sonnet-4-5';

async function generateClientProfile(transcriptLines) {
  if (!transcriptLines || transcriptLines.length === 0) return null;
  const texto = transcriptLines.join('\n');
  try {
    const resp = await anthropic.messages.create({
      model: MODEL,
      max_tokens: 300,
      system: 'Eres un asistente que resume, en español y en un párrafo breve (máximo 4-5 líneas), cómo fue el primer contacto de un paciente nuevo con Aura Luz (asistente de agendamiento de una psicóloga). A continuación se te muestra la conversación completa, con las líneas marcadas "Paciente:" y "Aura Luz:". Usa los mensajes de "Aura Luz:" UNICAMENTE como contexto para entender a qué estaba respondiendo el paciente (por ejemplo, para saber qué pregunta contestaba con un "sí" o "la tarde"). Tu resumen debe describir EXCLUSIVAMENTE la conducta y las palabras del PACIENTE; nunca comentes, evalúes ni menciones cómo respondió Aura Luz. Describe: tono de comunicación del paciente (formal/informal, cálido/cortante/directo/insistente), el motivo de consulta si lo mencionó, cómo llegó a conocer a la Dra. Daniela (Instagram, referido, etc.), y cualquier detalle práctico útil para la sesión (pidió urgencia, dudó antes de confirmar, preguntó mucho por precios, etc.). NUNCA uses diagnósticos, etiquetas psicológicas ni juicios de carácter (evita palabras como "ansioso", "irrespetuoso", "grosero", "depresivo"); describe la conducta observada en vez del rasgo, por ejemplo "no saludó y fue directo" en vez de "es cortante". Si no hay información suficiente del paciente, responde solo: "Sin información suficiente para un perfil."',
      messages: [{ role: 'user', content: 'Conversación de agendamiento:\n\n' + texto }],
    });
    const textBlocks = resp.content.filter((b) => b.type === 'text').map((b) => b.text);
    const result = textBlocks.join(' ').trim();
    if (!result || result.toLowerCase().includes('sin información suficiente')) return null;
    return result;
  } catch (e) {
    console.error('No se pudo generar perfil de cliente nuevo:', e.message);
    return null;
  }
}

async function executeTool(name, input, ctx) {
  if (name === 'check_availability') {
    const restricted = ctx.restricted !== false;
    const daysAhead = input.days_ahead || 60;
    const maxSlots = input.max_slots || 3;
    const timePreference = input.time_preference || 'cualquiera';
    const fromDate = input.from_date ? input.from_date : new Date();
    const slots = await suggestNextSlots({ fromDate, daysAhead, maxSlots, restricted, timePreference });
    ctx._validSlots = slots;
    const labeled = slots.map((s, i) => {
      const d = new Date(s.startISO);
      const label = d.toLocaleString('es-CO', {
        weekday: 'long', day: 'numeric', month: 'long', year: 'numeric',
        hour: 'numeric', minute: '2-digit', hour12: true, timeZone: config.timezone,
      });
      return { opcion: i + 1, etiqueta: label, start_iso: s.startISO, end_iso: s.endISO };
    });
    const instruccion = slots.length === 0
      ? 'No hay franjas disponibles con esos criterios en los proximos ' + daysAhead + ' dias. Intenta cambiar from_date o time_preference.'
      : 'Para agendar, usa EXACTAMENTE el start_iso y end_iso de una de estas franjas. NUNCA inventes ni calcules una fecha por tu cuenta.';
    return { franjas_disponibles: labeled, instruccion };
  }

  if (name === 'create_appointment') {
    const emailOk = input.patient_email && /.+@.+\..+/.test(input.patient_email);
    const phoneOk = input.patient_phone && String(input.patient_phone).replace(/\D/g, '').length >= 7;
    if (!emailOk || !phoneOk) {
      const faltan = [];
      if (!emailOk) faltan.push('correo electrónico válido');
      if (!phoneOk) faltan.push('número de celular');
      return { error: 'NO_AGENDADO', motivo: 'Faltan datos obligatorios: ' + faltan.join(' y ') + '. Pídeselos antes de agendar.' };
    }
    const startDate = new Date(input.start_iso);
    if (isNaN(startDate.getTime())) {
      return { error: 'FECHA_INVALIDA', motivo: 'La fecha no es válida. Llama a check_availability y usa EXACTAMENTE una de las franjas que te devuelve.' };
    }
    const ahora = new Date();
    if (startDate < ahora) {
      return { error: 'FECHA_EN_PASADO', motivo: 'Esa fecha ya pasó (' + startDate.toLocaleString('es-CO', { timeZone: config.timezone }) + '). NUNCA inventes fechas. Llama a check_availability primero y usa una franja real de las que te devuelve.' };
    }
    const unAnoAdelante = new Date(ahora.getTime() + 366 * 24 * 60 * 60 * 1000);
    if (startDate > unAnoAdelante) {
      return { error: 'FECHA_MUY_LEJANA', motivo: 'Esa fecha está demasiado lejos, seguramente calculaste mal. Llama a check_availability y usa una franja real.' };
    }
    const pKeyCheck = store.patientKeyFromRaw({ phone: input.patient_phone, email: input.patient_email, name: input.patient_name });
    await store.syncPatientWithCalendar(pKeyCheck, eventExists);
    const yaExiste = store.findAppointments({ phone: input.patient_phone, email: input.patient_email })
      .find((a) => a.start === input.start_iso);
    if (yaExiste) {
      return { error: 'YA_EXISTE', motivo: 'Ya hay una cita activa para ese paciente a esa hora (id ' + yaExiste.id + '). No la dupliques.', appointment_id: yaExiste.id, join_url: yaExiste.joinUrl };
    }
    const pKey = store.patientKeyFromRaw({ phone: input.patient_phone, email: input.patient_email, name: input.patient_name });
    const visitNum = store.countActiveAppointmentsForPatient(pKey) + 1;

    // Perfil cliente nuevo: conversacion completa (ambos lados) solo para describir conducta del paciente
    let clientProfile = null;
    if (visitNum === 1 && ctx.history) {
      const transcriptLines = [];
      for (const m of ctx.history) {
        if (m.role === 'user' && typeof m.content === 'string') {
          transcriptLines.push('Paciente: ' + m.content);
        } else if (m.role === 'assistant' && Array.isArray(m.content)) {
          const texto = m.content.filter((b) => b.type === 'text').map((b) => b.text).join(' ').trim();
          if (texto) transcriptLines.push('Aura Luz: ' + texto);
        }
      }
      clientProfile = await generateClientProfile(transcriptLines);
    }

    const esAdmin = ctx.restricted === false;
    if (esAdmin && (!input.subject_note || !input.subject_note.trim())) {
      return { error: 'FALTA_ASUNTO', motivo: 'Falta el ASUNTO de la cita. Pídeselo a Daniela antes de agendar.' };
    }
    let subject = `Sesion - DRGsoul # ${visitNum} - ${input.patient_name}`;
    if (esAdmin && input.subject_note && input.subject_note.trim()) {
      subject += ` - ${input.subject_note.trim()}`;
    }
    const { eventId, joinUrl } = await createTeamsAppointment({
      subject,
      startISO: input.start_iso,
      endISO: input.end_iso,
      attendeeEmail: input.patient_email,
      attendeeName: input.patient_name,
      bodyText: `Paciente: ${input.patient_name}\nMotivo: ${input.reason}`,
    });
    const appt = store.createAppointment({
      id: uuid(),
      eventId,
      joinUrl,
      phone: input.patient_phone || ctx.phone,
      name: input.patient_name,
      email: input.patient_email || null,
      reason: input.reason,
      start: input.start_iso,
      end: input.end_iso,
      patientVisitNumber: visitNum,
      subjectNote: input.subject_note || null,
      isAdminBooking: esAdmin,
      clientProfile: clientProfile,
      createdAt: new Date().toISOString(),
    });
    try {
      const { bot } = require('../telegram/bot');
      const chatId = require('../config').telegram.danielaChatId;
      const startLabel = new Date(input.start_iso).toLocaleString('es-CO', {
        weekday: 'long', day: 'numeric', month: 'long',
        hour: 'numeric', minute: '2-digit', hour12: true,
        timeZone: require('../config').timezone,
      });
      let msg = `✅ <b>Nueva sesion agendada</b>\n\n<b>Paciente:</b> ${input.patient_name}\n<b>Sesion #:</b> ${visitNum}\n<b>Fecha:</b> ${startLabel}\n<b>Link:</b> ${joinUrl || 'No disponible'}`;
      if (clientProfile) {
        msg += `\n\n<b>Primer contacto (cliente nuevo):</b>\n${clientProfile}`;
      }
      await bot.sendMessage(chatId, msg, { parse_mode: 'HTML' });
    } catch (e) {
      console.error('No se pudo notificar a Daniela de la nueva sesion:', e.message);
    }
    return { appointment_id: appt.id, join_url: joinUrl, visit_number: visitNum };
  }

  if (name === 'send_payment_instructions') {
    return {
      payment_instructions: config.rules.paymentInstructions,
      deposit_note: config.rules.depositNote,
    };
  }

  if (name === 'find_appointments') {
    const keySync = store.patientKeyFromRaw({ phone: input.phone, email: input.email, name: input.name });
    await store.syncPatientWithCalendar(keySync, eventExists);
    const found = store.findAppointments({ name: input.name, email: input.email, phone: input.phone });
    return {
      appointments: found.map((a) => ({
        appointment_id: a.id, name: a.name, email: a.email,
        phone: a.phone, start: a.start, subject: `Cita - DRGsoul`,
      })),
    };
  }

  if (name === 'cancel_appointment') {
    if (ctx.restricted !== false) {
      return { error: 'SIN_PERMISO', motivo: 'Solo Daniela puede cancelar citas. Un paciente debe pedirlo y Daniela lo gestiona.' };
    }
    const appt = store.getAppointment(input.appointment_id);
    if (!appt) return { error: 'NO_ENCONTRADA', motivo: 'No encontré esa cita.' };
    try {
      if (appt.eventId) await cancelAppointment(appt.eventId);
      store.markAppointmentCancelled(input.appointment_id);
      const pKey2 = store.patientKeyOf(appt);
      const restantes = store.listActiveAppointmentsForPatient(pKey2);
      for (let idx = 0; idx < restantes.length; idx += 1) {
        const nuevoNum = idx + 1;
        const r = restantes[idx];
        if (r.patientVisitNumber !== nuevoNum) {
          store.setAppointmentNumber(r.id, nuevoNum);
          if (r.eventId) {
            let subj = `Sesion - DRGsoul # ${nuevoNum} - ${r.name}`;
            if (r.isAdminBooking && r.subjectNote) subj += ` - ${r.subjectNote}`;
            try { await updateAppointmentSubject(r.eventId, subj); }
            catch (e) { console.error('No se pudo renumerar cita', r.id, e.message); }
          }
        }
      }
      if (appt.phone) {
        try {
          const waClient = require('../whatsapp/client');
          if (require('../config').whatsapp.token) {
            await waClient.sendText(String(appt.phone).replace(/\D/g,''),
              'Hola 💛 Te informamos que tu cita fue cancelada. Si deseas reagendar, escríbenos con gusto.');
          }
        } catch (e) { console.error('No se pudo avisar al paciente de la cancelación:', e.message); }
      }
      return { cancelled: true, patient: appt.name };
    } catch (e) {
      return { error: 'FALLO_CANCELAR', motivo: e.message };
    }
  }

  if (name === 'notify_daniela_cancellation') {
    try {
      const { bot } = require('../telegram/bot');
      const chatId = require('../config').telegram.danielaChatId;
      await bot.sendMessage(chatId,
        `🔔 Un paciente pide CANCELAR su cita:\n\n${input.patient_info}\n\nGestiónalo tú y, si confirmas, dime "cancela la cita de [nombre]".`);
      return { notified: true };
    } catch (e) {
      return { error: 'FALLO_NOTIFICAR', motivo: e.message };
    }
  }

  if (name === 'get_next_visit_number') {
    const pk = store.patientKeyFromRaw({ phone: input.patient_phone, email: input.patient_email, name: input.patient_name });
    await store.syncPatientWithCalendar(pk, eventExists);
    const num = store.countActiveAppointmentsForPatient(pk) + 1;
    return { next_visit_number: num };
  }

  if (name === 'reschedule_appointment') {
    if (ctx.restricted !== false) {
      return { error: 'SIN_PERMISO', motivo: 'Solo Daniela puede reagendar sesiones.' };
    }
    const appt = store.getAppointment(input.appointment_id);
    if (!appt) return { error: 'NO_ENCONTRADA', motivo: 'No encontre esa sesion.' };
    try {
      if (appt.eventId) await cancelAppointment(appt.eventId);
      store.markAppointmentCancelled(input.appointment_id);
      const pKey = store.patientKeyOf(appt);
      await store.syncPatientWithCalendar(pKey, eventExists);
      const visitNum = store.countActiveAppointmentsForPatient(pKey) + 1;
      let subject = `Sesion - DRGsoul # ${visitNum} - ${appt.name}`;
      if (appt.subjectNote) subject += ` - ${appt.subjectNote}`;
      const { eventId: newEventId, joinUrl: newJoinUrl } = await createTeamsAppointment({
        subject, startISO: input.new_start_iso, endISO: input.new_end_iso,
        attendeeEmail: appt.email, attendeeName: appt.name,
        bodyText: `Paciente: ${appt.name}\nMotivo: ${appt.reason || ''}`,
      });
      const newAppt = store.createAppointment({
        id: require('uuid').v4 ? require('uuid').v4() : String(Date.now()),
        eventId: newEventId, joinUrl: newJoinUrl, phone: appt.phone,
        name: appt.name, email: appt.email, reason: appt.reason,
        start: input.new_start_iso, end: input.new_end_iso,
        patientVisitNumber: visitNum, subjectNote: appt.subjectNote || null,
        isAdminBooking: true, origen: appt.origen || null,
        createdAt: new Date().toISOString(),
      });
      const templates = require('../whatsapp/templates');
      const config2 = require('../config');
      const phone2 = String(appt.phone).replace(/\D/g, '');
      const fechaHora = new Date(input.new_start_iso).toLocaleString('es-CO', {
        weekday: 'long', day: 'numeric', month: 'long',
        hour: 'numeric', minute: '2-digit', hour12: true, timeZone: config2.timezone,
      });
      try {
        await templates.sendConfirmacionSesion(phone2, appt.name, fechaHora, newJoinUrl);
      } catch(e) {
        const { sendText } = require('../whatsapp/client');
        await sendText(phone2, `Hola ${appt.name} 🌷 Te escribe Aura Luz. Tu sesion fue reagendada para el ${fechaHora} ✨ Aqui esta tu nuevo enlace: ${newJoinUrl || 'Te lo enviamos pronto'} 💛`);
      }
      try {
        const { bot } = require('../telegram/bot');
        await bot.sendMessage(config2.telegram.danielaChatId,
          `✅ <b>Sesion reagendada</b>\n\n<b>Paciente:</b> ${appt.name}\n<b>Nueva sesion #:</b> ${visitNum}\n<b>Nueva fecha:</b> ${fechaHora}\n<b>Paciente notificado por WhatsApp</b> ✔️`,
          { parse_mode: 'HTML' });
      } catch(e) {}
      return { reagendado: true, nuevo_appointment_id: newAppt.id, nuevo_join_url: newJoinUrl, visit_number: visitNum };
    } catch(e) {
      return { error: 'FALLO_REAGENDAR', motivo: e.message };
    }
  }

  if (name === 'fix_patient_email') {
    const appt = store.getAppointment(input.appointment_id);
    if (!appt) return { error: 'NO_ENCONTRADA', motivo: 'No encontre esa sesion.' };
    const newEmail = input.new_email.toLowerCase().trim();
    if (!/.+@.+..+/.test(newEmail)) {
      return { error: 'EMAIL_INVALIDO', motivo: 'El correo no tiene formato valido. Pidelo de nuevo por escrito.' };
    }
    try {
      const config2 = require('../config');
      if (appt.eventId) { try { await cancelAppointment(appt.eventId); } catch(e) {} }
      store.markAppointmentCancelled(input.appointment_id);
      store.updatePatientEmail(appt.phone, newEmail);
      const pKey = store.patientKeyOf({ ...appt, email: newEmail });
      await store.syncPatientWithCalendar(pKey, eventExists);
      const visitNum = store.countActiveAppointmentsForPatient(pKey) + 1;
      let subject = `Sesion - DRGsoul # ${visitNum} - ${appt.name}`;
      if (appt.subjectNote) subject += ` - ${appt.subjectNote}`;
      const { eventId: newEventId, joinUrl: newJoinUrl } = await createTeamsAppointment({
        subject, startISO: appt.start, endISO: appt.end,
        attendeeEmail: newEmail, attendeeName: appt.name,
        bodyText: `Paciente: ${appt.name}\nMotivo: ${appt.reason || ''}`,
      });
      store.createAppointment({
        id: require('uuid').v4 ? require('uuid').v4() : String(Date.now()),
        eventId: newEventId, joinUrl: newJoinUrl, phone: appt.phone,
        name: appt.name, email: newEmail, reason: appt.reason,
        start: appt.start, end: appt.end, patientVisitNumber: visitNum,
        subjectNote: appt.subjectNote || null, isAdminBooking: appt.isAdminBooking || false,
        origen: appt.origen || null, createdAt: new Date().toISOString(),
      });
      const fechaHora = new Date(appt.start).toLocaleString('es-CO', {
        weekday: 'long', day: 'numeric', month: 'long',
        hour: 'numeric', minute: '2-digit', hour12: true, timeZone: config2.timezone,
      });
      const phone2 = String(appt.phone).replace(/\D/g, '');
      try {
        const { sendText } = require('../whatsapp/client');
        await sendText(phone2, `Listo ${appt.name.split(' ')[0]} 🌷 Tu correo fue corregido a ${newEmail} y tu sesion del ${fechaHora} sigue confirmada. Ya te enviamos la nueva invitacion de Teams a ese correo. Estamos contigo 💛`);
      } catch(e) { console.error('Error notificando paciente fix_email:', e.message); }
      try {
        const { bot } = require('../telegram/bot');
        await bot.sendMessage(config2.telegram.danielaChatId,
          `✅ <b>Correo corregido automaticamente</b>\n\n<b>Paciente:</b> ${appt.name}\n<b>Correo anterior:</b> eliminado\n<b>Correo nuevo:</b> ${newEmail}\n<b>Sesion:</b> ${fechaHora}\n\nYa reagende la sesion y notifique al paciente por WhatsApp. No necesitas hacer nada.`,
          { parse_mode: 'HTML' });
      } catch(e) {}
      return { corregido: true, nuevo_email: newEmail, nuevo_join_url: newJoinUrl };
    } catch(e) {
      return { error: 'FALLO_CORRECCION', motivo: e.message };
    }
  }

  return { error: `Herramienta desconocida: ${name}` };
}

async function runAgent({ systemPrompt, history, ctx }) {
  let messages = [...history];
  let finalText = '';
  for (let turn = 0; turn < 6; turn += 1) {
    let response;
    try {
      response = await anthropic.messages.create({
        model: MODEL, max_tokens: 1000,
        system: systemPrompt, tools: TOOLS, messages,
      });
    } catch (apiErr) {
      const errMsg = apiErr.message || (apiErr.error && apiErr.error.message) || String(apiErr);
      if (errMsg.includes('credit balance') || errMsg.includes('billing') || errMsg.includes('insufficient')) {
        console.error('[ALERTA] Saldo de Claude agotado:', errMsg);
        try {
          const { bot } = require('../telegram/bot');
          const chatId = require('../config').telegram.danielaChatId;
          await bot.sendMessage(chatId,
            '🚨 *ALERTA IMPORTANTE*\n\nEl saldo de la API de Claude se agoto. Aura Luz no puede responder a los pacientes hasta que se recargue.\n\nPor favor avisa a Jorge para que recargue en console.anthropic.com',
            { parse_mode: 'Markdown' });
        } catch(e) { console.error('No se pudo alertar a Daniela sobre saldo:', e.message); }
      }
      throw apiErr;
    }
    const toolUses = response.content.filter((b) => b.type === 'tool_use');
    const textBlocks = response.content.filter((b) => b.type === 'text').map((b) => b.text);
    finalText = textBlocks.join('\n').trim();
    if (response.stop_reason !== 'tool_use' || toolUses.length === 0) {
      messages.push({ role: 'assistant', content: response.content });
      break;
    }
    messages.push({ role: 'assistant', content: response.content });
    const toolResults = [];
    for (const toolUse of toolUses) {
      const result = await executeTool(toolUse.name, toolUse.input, ctx);
      toolResults.push({ type: 'tool_result', tool_use_id: toolUse.id, content: JSON.stringify(result) });
    }
    messages.push({ role: 'user', content: toolResults });
  }
  return { finalText, messages };
}

async function handlePatientMessage(phone, userText, profileName, fromAudio = false) {
  // Guardar texto limpio para displayHistory antes de agregar el prefijo de audio
  const cleanUserText = userText;

  if (fromAudio) userText = '[NOTA: este mensaje vino de un audio transcrito. NO aceptes correos de aquí; si hay un correo, pídelo por escrito.] ' + userText;

  const session = store.getSession(phone);
  let history = session.history || [];
  let displayHistory = session.displayHistory || [];

  const DAY = 24 * 60 * 60 * 1000;
  const lastAt = session.lastAt ? new Date(session.lastAt).getTime() : 0;
  if (lastAt && Date.now() - lastAt > DAY) {
    history = [];
    displayHistory = []; // también resetear al arrancar hilo nuevo
  }

  // Registrar mensaje del paciente con timestamp
  displayHistory.push({
    role: 'user',
    text: cleanUserText,
    timestamp: new Date().toISOString(),
    fromAudio: fromAudio || false,
  });

  history.push({ role: 'user', content: userText });

  const { finalText, messages } = await runAgent({
    systemPrompt: patientSystemPrompt(),
    history,
    ctx: { phone, profileName, restricted: true, history },
  });

  // Registrar respuesta de Aura con timestamp
  if (finalText) {
    displayHistory.push({
      role: 'assistant',
      text: finalText,
      timestamp: new Date().toISOString(),
    });
  }

  // Detectar origen del cliente
  const origenMatch = finalText && (() => {
    const hist = messages.map(m => typeof m.content === 'string' ? m.content : '').join(' ').toLowerCase();
    if (hist.includes('instagram')) return 'Instagram';
    if (hist.includes('facebook')) return 'Facebook';
    if (hist.includes('referid') || hist.includes('me recomend') || hist.includes('me lo recomend')) return 'Referido';
    if (hist.includes('organizacional') || hist.includes('empresa') || hist.includes('corporativ')) return 'Organizacional';
    if (hist.includes('google') || hist.includes('busque') || hist.includes('busqué')) return 'Google/Busqueda';
    if (hist.includes('tiktok')) return 'TikTok';
    if (hist.includes('youtube')) return 'YouTube';
    return null;
  })();
  if (origenMatch) {
    try { require('../store').saveClientOrigin(phone, origenMatch); } catch(e) {}
  }

  store.saveSession(phone, {
    ...session,
    phone,
    profileName: profileName || session.profileName,
    history: messages,
    displayHistory,
    lastAt: new Date().toISOString(),
  });
  return finalText;
}

async function handleAdminMessage(daniela_text, fromAudio = false) {
  if (fromAudio) daniela_text = '[NOTA: este mensaje vino de un audio transcrito. NO aceptes correos de aquí; si hay un correo, pídelo por escrito.] ' + daniela_text;
  const KEY = 'admin:daniela';
  const session = store.getSession(KEY);
  let history = session.history || [];
  const SIX_HOURS = 6 * 60 * 60 * 1000;
  const lastAt = session.lastAt ? new Date(session.lastAt).getTime() : 0;
  if (lastAt && Date.now() - lastAt > SIX_HOURS) { history = []; }
  history.push({ role: 'user', content: daniela_text });
  const { finalText, messages } = await runAgent({
    systemPrompt: adminSystemPrompt(),
    history,
    ctx: { phone: null, restricted: false },
  });
  store.saveSession(KEY, { ...session, phone: KEY, history: messages, lastAt: new Date().toISOString() });
  return finalText;
}

module.exports = { handlePatientMessage, handleAdminMessage };
EOF

echo "==> Paso 6: Actualizando index.js (con cookie-parser y panel)..."
cat > /root/aura-luz/src/index.js << 'EOF'
const express = require('express');
const cookieParser = require('cookie-parser');
const config = require('./config');
require('./telegram/bot');
console.log('Telegram (Aura Luz) iniciado.');
const app = express();
app.use(cookieParser());
app.use(
  express.json({
    verify: (req, res, buf) => { req.rawBody = buf; },
  })
);
// Panel de conversaciones (solo lectura, protegido con contrasena)
const panelRouter = require('./panel');
app.use('/panel', panelRouter);
if (config.whatsapp.token && config.whatsapp.phoneNumberId) {
  const whatsappWebhook = require('./whatsapp/webhook');
  app.use('/webhook/whatsapp', whatsappWebhook);
  console.log('WhatsApp (webhook) activado.');
} else {
  console.log('WhatsApp aun no configurado (faltan datos de Meta). Se omite por ahora.');
}
app.get('/health', (req, res) => res.json({ status: 'Aura Luz despierta' }));
const { startScheduler } = require('./scheduler');
startScheduler();
app.listen(config.port, () => {
  console.log('Aura Luz escuchando en el puerto ' + config.port);
});
EOF

echo "==> Paso 7: Configurando contrasena del panel..."
if ! grep -q "^PANEL_PASSWORD=" /root/aura-luz/.env 2>/dev/null; then
  PANEL_PWD=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 20)
  echo "PANEL_PASSWORD=${PANEL_PWD}" >> /root/aura-luz/.env
  echo ""
  echo "============================================"
  echo "  CONTRASENA DEL PANEL: ${PANEL_PWD}"
  echo "============================================"
  echo "  Guardala y compartila con Daniela."
  echo "============================================"
  echo ""
else
  echo "==> PANEL_PASSWORD ya existe en .env, se mantiene la actual."
  echo "    Si quieres verla: grep PANEL_PASSWORD /root/aura-luz/.env"
fi

echo "==> Paso 8: Reiniciando servicio..."
systemctl restart aura-luz
sleep 2

# Intentar obtener URL del tunel Cloudflare
TUNNEL_URL=$(grep -r "hostname" /etc/cloudflared/*.yml /root/.cloudflared/*.yml 2>/dev/null | grep -v "^#" | awk -F': ' '{print $2}' | head -1 | tr -d ' ')
if [ -z "$TUNNEL_URL" ]; then
  TUNNEL_URL="TU-DOMINIO.trycloudflare.com"
fi

echo ""
echo "✅ Todo listo."
echo ""
echo "Panel disponible en: https://${TUNNEL_URL}/panel"
echo "Revisa logs con:     journalctl -u aura-luz -f"
