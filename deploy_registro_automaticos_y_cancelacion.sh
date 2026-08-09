#!/bin/bash
set -e

echo "==> Paso 1: Agregando helper logOutboundMessage a store.js..."
node -e "
const fs = require('fs');
const f = '/root/aura-luz/src/store.js';
let c = fs.readFileSync(f, 'utf-8');

// Agregar funcion antes del module.exports
const helper = \`
// Registra un mensaje saliente (de Aura o automatico) en el displayHistory del paciente.
// Sirve para que el panel de chats muestre mensajes que no pasaron por handlePatientMessage
// (recordatorios, alertas de cancelacion, validacion de pago, etc.)
function logOutboundMessage(phone, text) {
  if (!phone || !text) return;
  const db = loadDB();
  const phoneClean = String(phone).replace(/\\\\D/g, '');
  // Buscar la sesion por numero (normalizado)
  let sessionKey = null;
  for (const key of Object.keys(db.sessions || {})) {
    const keyClean = String(key).replace(/\\\\D/g, '');
    if (keyClean && phoneClean && keyClean === phoneClean) {
      sessionKey = key;
      break;
    }
  }
  if (!sessionKey) {
    // Crear sesion minima si no existe
    sessionKey = phoneClean;
    db.sessions[sessionKey] = { phone: phoneClean, history: [], displayHistory: [], createdAt: new Date().toISOString() };
  }
  if (!db.sessions[sessionKey].displayHistory) {
    db.sessions[sessionKey].displayHistory = [];
  }
  db.sessions[sessionKey].displayHistory.push({
    role: 'assistant',
    text: text,
    timestamp: new Date().toISOString(),
    automatic: true,
  });
  db.sessions[sessionKey].lastAt = new Date().toISOString();
  saveDB(db);
}

\`;

c = c.replace(
  'module.exports = {',
  helper + 'module.exports = {\\n  logOutboundMessage,'
);

fs.writeFileSync(f, c);
console.log('[OK] store.js - logOutboundMessage agregado');
"

echo "==> Paso 2: Actualizando scheduler.js (texto neutral + registro en panel)..."
cat > /root/aura-luz/src/scheduler.js << 'EOF'
/**
 * scheduler.js
 * Tareas programadas de Aura Luz:
 *
 * 1. Recordatorio 3:30 PM (Bogota): pacientes que escribieron hoy
 *    pero no agendaron todavia.
 *
 * 2. Recordatorios de cita:
 *    - 24 horas antes: envia plantilla segun estado de pago
 *    - 7:00 AM del dia de la cita: mismo criterio
 *
 * 3. Vigilancia del calendario Teams (cada 30 min):
 *    Detecta citas canceladas y avisa con mensaje neutral.
 */

const fs = require('fs');
const path = require('path');
const config = require('./config');

const DB_PATH = path.join(__dirname, '..', 'data', 'store.json');

function loadDB() {
  if (!fs.existsSync(DB_PATH)) return { sessions: {}, appointments: {} };
  return JSON.parse(fs.readFileSync(DB_PATH, 'utf-8'));
}

function saveDB(db) {
  fs.writeFileSync(DB_PATH, JSON.stringify(db, null, 2));
}

function formatFechaBogota(isoStr) {
  return new Date(isoStr).toLocaleString('es-CO', {
    weekday: 'long', day: 'numeric', month: 'long',
    hour: 'numeric', minute: '2-digit', hour12: true,
    timeZone: config.timezone,
  });
}

function nowBogota() {
  return new Date(new Date().toLocaleString('en-US', { timeZone: config.timezone }));
}

function scheduleDaily(hhmm, fn, label) {
  const [targetH, targetM] = hhmm.split(':').map(Number);
  function tick() {
    const now = nowBogota();
    if (now.getHours() === targetH && now.getMinutes() === targetM) {
      console.log(`[scheduler] Ejecutando tarea: ${label}`);
      fn().catch((e) => console.error(`[scheduler] Error en ${label}:`, e.message));
    }
  }
  setInterval(tick, 60 * 1000);
  console.log(`[scheduler] Tarea programada: ${label} a las ${hhmm} Bogota`);
}

function scheduleInterval(minutes, fn, label) {
  setInterval(() => {
    fn().catch((e) => console.error(`[scheduler] Error en ${label}:`, e.message));
  }, minutes * 60 * 1000);
  console.log(`[scheduler] Tarea periodica: ${label} cada ${minutes} min`);
}

// ----------------------------------------------------------------
// TAREA 1: Recordatorio 3:30 PM para conversaciones sin cita
// ----------------------------------------------------------------
async function recordatorioConversacionesIncompletas() {
  const waClient = require('./whatsapp/client');
  const { toWhatsApp } = require('./format');
  const store = require('./store');
  const db = loadDB();
  const now = nowBogota();
  const todayStr = now.toISOString().slice(0, 10);

  for (const [phone, session] of Object.entries(db.sessions || {})) {
    if (!session.lastAt) continue;
    if (phone === 'admin:daniela') continue;

    const lastAt = new Date(session.lastAt);
    const lastDateStr = new Date(lastAt.toLocaleString('en-US', { timeZone: config.timezone }))
      .toISOString().slice(0, 10);

    if (lastDateStr !== todayStr) continue;

    const appts = Object.values(db.appointments || {}).filter(
      (a) => a.status !== 'cancelada' &&
             a.phone && String(a.phone).replace(/\D/g, '') === String(phone).replace(/\D/g, '') &&
             new Date(a.start) > now
    );
    if (appts.length > 0) continue;

    if (session.recordatorio330Enviado === todayStr) continue;

    try {
      const mensaje = 'Hola 🌷 Habla Aura Luz, asistente de la Dra. Daniela. Queria saber si puedo ayudarte a reservar tu espacio hoy. Estoy aqui cuando quieras continuar 💛';
      const phoneClean = String(phone).replace(/\D/g, '');
      await waClient.sendText(phoneClean, toWhatsApp(mensaje));
      store.logOutboundMessage(phoneClean, mensaje);

      db.sessions[phone].recordatorio330Enviado = todayStr;
      saveDB(db);
      console.log(`[scheduler] Recordatorio 3:30pm enviado a ${phone}`);
    } catch (e) {
      console.error(`[scheduler] No se pudo enviar recordatorio a ${phone}:`, e.message);
    }
  }
}

// ----------------------------------------------------------------
// TAREA 2: Recordatorios de cita (24h antes y 7am del dia)
// ----------------------------------------------------------------
async function recordatoriosCitas() {
  const templates = require('./whatsapp/templates');
  const store = require('./store');
  const db = loadDB();
  const now = nowBogota();

  for (const [id, appt] of Object.entries(db.appointments || {})) {
    if (appt.status === 'cancelada') continue;
    if (!appt.phone || !appt.start) continue;

    const citaDate = new Date(appt.start);
    const diffMs = citaDate - now;
    const diffHours = diffMs / (1000 * 60 * 60);
    const nowH = now.getHours();
    const nowM = now.getMinutes();

    const fechaHora = formatFechaBogota(appt.start);
    const nombre = appt.name || 'paciente';
    const link = appt.joinUrl || '';
    const phone = String(appt.phone).replace(/\D/g, '');
    const pagado = appt.paymentStatus === 'validado';

    // Recordatorio 24h antes
    if (diffHours >= 23.5 && diffHours < 24.5 && !appt.recordatorio24hEnviado) {
      try {
        if (pagado) {
          await templates.sendRecordatorioPagoConfirmado(phone, nombre, fechaHora, link);
          store.logOutboundMessage(phone, `[Recordatorio 24h - pago confirmado] Sesion: ${fechaHora}`);
        } else {
          await templates.sendRecordatorioPagoPendiente(phone, nombre, fechaHora, link);
          store.logOutboundMessage(phone, `[Recordatorio 24h - pago pendiente] Sesion: ${fechaHora}`);
        }
        db.appointments[id].recordatorio24hEnviado = true;
        saveDB(db);
        console.log(`[scheduler] Recordatorio 24h enviado a ${nombre} (${phone})`);
      } catch (e) {
        console.error(`[scheduler] Error recordatorio 24h a ${phone}:`, e.message);
      }
    }

    // Recordatorio 7am del dia de la cita
    const citaBogota = new Date(citaDate.toLocaleString('en-US', { timeZone: config.timezone }));
    const esHoyLaCita = citaBogota.toISOString().slice(0, 10) ===
                        now.toISOString().slice(0, 10);

    if (esHoyLaCita && nowH === 7 && nowM < 5 && !appt.recordatorio7amEnviado) {
      try {
        if (pagado) {
          await templates.sendRecordatorioPagoConfirmado(phone, nombre, fechaHora, link);
          store.logOutboundMessage(phone, `[Recordatorio dia de sesion - pago confirmado] Sesion: ${fechaHora}`);
        } else {
          await templates.sendRecordatorioPagoPendiente(phone, nombre, fechaHora, link);
          store.logOutboundMessage(phone, `[Recordatorio dia de sesion - pago pendiente] Sesion: ${fechaHora}`);
        }
        db.appointments[id].recordatorio7amEnviado = true;
        saveDB(db);
        console.log(`[scheduler] Recordatorio 7am enviado a ${nombre} (${phone})`);
      } catch (e) {
        console.error(`[scheduler] Error recordatorio 7am a ${phone}:`, e.message);
      }
    }
  }
}

// ----------------------------------------------------------------
// TAREA 3: Vigilancia del calendario Teams (cada 30 min)
// Texto NEUTRAL: no asume quien cancelo (puede ser Daniela o el paciente)
// ----------------------------------------------------------------
async function vigilanciaCalendario() {
  const { getGraphToken } = require('./graph/auth');
  const axios = require('axios');
  const templates = require('./whatsapp/templates');
  const { bot } = require('./telegram/bot');
  const store = require('./store');
  const db = loadDB();
  const organizer = config.graph.organizerEmail;
  const chatId = config.telegram.danielaChatId;

  try {
    const token = await getGraphToken();
    const client = axios.create({
      baseURL: 'https://graph.microsoft.com/v1.0',
      headers: { Authorization: `Bearer ${token}` },
    });

    for (const [id, appt] of Object.entries(db.appointments || {})) {
      if (appt.status === 'cancelada') continue;
      if (!appt.eventId || !appt.phone) continue;
      if (new Date(appt.start) < new Date()) continue;

      try {
        const { data } = await client.get(`/users/${organizer}/events/${appt.eventId}`);

        // Paciente DECLINO la invitacion desde su calendario
        const asistentes = data.attendees || [];
        const paciente = asistentes.find(
          (a) => a.emailAddress && a.emailAddress.address &&
                 appt.email && a.emailAddress.address.toLowerCase() === appt.email.toLowerCase()
        );

        if (paciente && paciente.status && paciente.status.response === 'declined') {
          if (appt.alertaCancelacionEnviada) continue;

          const fechaHora = formatFechaBogota(appt.start);
          const nombre = appt.name || 'el paciente';
          const phone = String(appt.phone).replace(/\D/g, '');

          // Para declined SI sabemos que fue el paciente
          const msgPaciente = `Hola ${nombre} 🌷 Te escribe Aura Luz, asistente de la Dra. Daniela. Notamos que tu sesion del ${fechaHora} fue cancelada desde tu calendario. Si fue intencional cuentanos con confianza, y si fue por error escribenos y lo resolvemos enseguida 💛`;

          try {
            await templates.sendAlertaCancelacionCliente(phone, nombre, fechaHora);
          } catch (e) {
            try {
              const { sendText } = require('./whatsapp/client');
              await sendText(phone, msgPaciente);
            } catch (err2) {
              console.error('[scheduler] Error fallback alerta WA:', err2.message);
            }
          }
          store.logOutboundMessage(phone, msgPaciente);

          try {
            await bot.sendMessage(chatId,
              `⚠️ *Cancelacion detectada*\n\n*${nombre}* declino su cita del *${fechaHora}* desde su calendario.\n\nYa le envie un mensaje por WhatsApp para confirmar si fue intencional.`,
              { parse_mode: 'Markdown' });
          } catch (e) {}

          db.appointments[id].alertaCancelacionEnviada = true;
          saveDB(db);
        }
      } catch (e) {
        // 404 = evento eliminado desde Teams (puede ser Daniela o el paciente)
        if (e.response && e.response.status === 404) {
          if (!appt.alertaCancelacionEnviada) {
            const fechaHora = formatFechaBogota(appt.start);
            const nombre = appt.name || 'el paciente';
            const phone = String(appt.phone).replace(/\D/g, '');

            // Mensaje NEUTRAL: no asume quien cancelo
            const msgNeutral = `Hola ${nombre} 🌷 Te escribe Aura Luz, asistente de la Dra. Daniela. Te informamos que tu sesion del ${fechaHora} ha sido cancelada. Si deseas reagendar en otro momento, con gusto te ayudo. Solo escribeme por aqui 💛`;

            try {
              const { sendText } = require('./whatsapp/client');
              await sendText(phone, msgNeutral);
            } catch (err2) {
              console.error('[scheduler] Error alerta WA 404:', err2.message);
            }
            store.logOutboundMessage(phone, msgNeutral);

            try {
              await bot.sendMessage(chatId,
                `⚠️ *Sesion eliminada*\n\n*${nombre}* — la sesion del *${fechaHora}* fue eliminada del calendario.\n\nYa le envie un mensaje al paciente informandole.`,
                { parse_mode: 'Markdown' });
            } catch (err) {}

            db.appointments[id].alertaCancelacionEnviada = true;
            db.appointments[id].status = 'cancelada';
            db.appointments[id].autoSynced = true;
            saveDB(db);
          }
        }
      }
    }
  } catch (e) {
    console.error('[scheduler] Error en vigilanciaCalendario:', e.message);
  }
}

function startScheduler() {
  scheduleDaily('15:30', recordatorioConversacionesIncompletas, 'Recordatorio 3:30pm');
  scheduleDaily('07:00', recordatoriosCitas, 'Recordatorio 7am citas');
  scheduleInterval(1, recordatoriosCitas, 'Recordatorio 24h citas');
  scheduleInterval(30, vigilanciaCalendario, 'Vigilancia calendario Teams');

  setTimeout(() => {
    vigilanciaCalendario().catch((e) =>
      console.error('[scheduler] Error inicial vigilancia:', e.message)
    );
  }, 10000);
}

module.exports = { startScheduler };
EOF

echo "==> Paso 3: Actualizando bot.js (registro de pagos en panel)..."
node -e "
const fs = require('fs');
const f = '/root/aura-luz/src/telegram/bot.js';
let c = fs.readFileSync(f, 'utf-8');

// Agregar require de store al inicio si no existe logOutboundMessage usage
// El store ya esta importado. Solo agregar las llamadas a logOutboundMessage.

// Despues de enviar mensaje de pago validado
c = c.replace(
  \"await bot.answerCallbackQuery(query.id, { text: 'Pago validado y paciente notificado ✅' });\",
  \"store.logOutboundMessage(phone, '¡Tu pago fue validado! 🎉 Tu sesion quedo confirmada. Nos vemos pronto 💛');\\n    await bot.answerCallbackQuery(query.id, { text: 'Pago validado y paciente notificado ✅' });\"
);

// Despues de enviar mensaje de pago rechazado
c = c.replace(
  \"await bot.answerCallbackQuery(query.id, { text: 'Paciente notificado del rechazo' });\",
  \"store.logOutboundMessage(phone, 'Hola 💛 Revisamos el comprobante y no logramos verificar el pago. ¿Nos ayudas enviándolo de nuevo o con otro comprobante?');\\n    await bot.answerCallbackQuery(query.id, { text: 'Paciente notificado del rechazo' });\"
);

fs.writeFileSync(f, c);
console.log('[OK] bot.js - registro de pagos en panel');
"

echo "==> Paso 4: Reiniciando servicio..."
systemctl restart aura-luz
sleep 2

echo ""
echo "✅ Todo listo. Cambios aplicados:"
echo "   - Mensajes automaticos ahora aparecen en el panel de chats"
echo "   - Cancelacion desde Teams: mensaje neutral (no asume quien cancelo)"
echo "   - Cancelacion desde calendario del paciente: mensaje especifico"
echo "   - Validacion/rechazo de pago: aparece en el panel"
