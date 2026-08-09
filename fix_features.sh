#!/bin/bash
set -e

echo "=== Aura Luz: Features nuevos (recordatorios, plantillas, clientes) ==="

# ---- Backups ----
cp /root/aura-luz/src/store.js /root/aura-luz/src/store.js.bak
cp /root/aura-luz/src/index.js /root/aura-luz/src/index.js.bak
cp /root/aura-luz/src/aura/agent.js /root/aura-luz/src/aura/agent.js.bak2
echo "✅ Backups creados"

# ---- Instalar xlsx para exportar Excel ----
cd /root/aura-luz && npm install xlsx --save --silent
echo "✅ Dependencia xlsx instalada"

# ================================================================
# 1. src/whatsapp/templates.js — funciones para las 4 plantillas
# ================================================================
cat > /root/aura-luz/src/whatsapp/templates.js << 'ENDOFFILE'
/**
 * templates.js
 * Funciones para enviar cada plantilla aprobada por Meta.
 * Todas usan languageCode 'es_CO' (Spanish COL).
 *
 * Plantillas disponibles:
 *   cancelacion_cita          — {{1}} nombre, {{2}} fecha/hora
 *   recordatorio_pago_pendiente — {{1}} nombre, {{2}} fecha/hora, {{3}} link Teams
 *   recordatorio_pago_confirmado — {{1}} nombre, {{2}} fecha/hora, {{3}} link Teams
 *   alerta_cancelacion_cliente  — {{1}} nombre, {{2}} fecha/hora
 */

const { sendTemplate } = require('./client');

const LANG = 'es_CO';

function bodyParam(text) {
  return { type: 'body', parameters: [{ type: 'text', value: text }] };
}

function bodyParams(...texts) {
  return {
    type: 'body',
    parameters: texts.map((t) => ({ type: 'text', value: String(t) })),
  };
}

/**
 * Aviso de cancelacion de cita (iniciado por Daniela/sistema).
 * @param {string} to       Numero del paciente (solo digitos, con indicativo)
 * @param {string} nombre   Nombre del paciente
 * @param {string} fechaHora Ej: "lunes 11 de agosto a las 10:00 a.m."
 */
async function sendCancelacionCita(to, nombre, fechaHora) {
  return sendTemplate(to, 'cancelacion_cita', LANG, [
    bodyParams(nombre, fechaHora),
  ]);
}

/**
 * Recordatorio cuando el pago NO esta confirmado.
 */
async function sendRecordatorioPagoPendiente(to, nombre, fechaHora, linkTeams) {
  return sendTemplate(to, 'recordatorio_pago_pendiente', LANG, [
    bodyParams(nombre, fechaHora, linkTeams || 'Sin enlace disponible'),
  ]);
}

/**
 * Recordatorio cuando el pago YA esta confirmado.
 */
async function sendRecordatorioPagoConfirmado(to, nombre, fechaHora, linkTeams) {
  return sendTemplate(to, 'recordatorio_pago_confirmado', LANG, [
    bodyParams(nombre, fechaHora, linkTeams || 'Sin enlace disponible'),
  ]);
}

/**
 * Alerta cuando el paciente cancela/declina desde su propio calendario.
 */
async function sendAlertaCancelacionCliente(to, nombre, fechaHora) {
  return sendTemplate(to, 'alerta_cancelacion_cliente', LANG, [
    bodyParams(nombre, fechaHora),
  ]);
}

module.exports = {
  sendCancelacionCita,
  sendRecordatorioPagoPendiente,
  sendRecordatorioPagoConfirmado,
  sendAlertaCancelacionCliente,
};
ENDOFFILE
echo "✅ templates.js creado"

# ================================================================
# 2. src/clients.js — registro de clientes exportable
# ================================================================
cat > /root/aura-luz/src/clients.js << 'ENDOFFILE'
/**
 * clients.js
 * Registro de clientes de Aura Luz.
 * Guarda: nombre, telefono, correo, numero de citas, valor facturado, origen.
 * Exportable a Excel para que Daniela lo consulte cuando quiera.
 */

const fs = require('fs');
const path = require('path');
const XLSX = require('xlsx');

const DB_PATH = path.join(__dirname, '..', 'data', 'store.json');

function loadDB() {
  if (!fs.existsSync(DB_PATH)) return { sessions: {}, appointments: {} };
  return JSON.parse(fs.readFileSync(DB_PATH, 'utf-8'));
}

/**
 * Construye la tabla de clientes a partir de las citas activas en store.json.
 * Agrupa por numero de telefono (fuente de verdad).
 */
function buildClientTable() {
  const db = loadDB();
  const appts = Object.values(db.appointments || {});
  const map = {};

  for (const a of appts) {
    const phone = a.phone ? String(a.phone).replace(/\D/g, '') : null;
    if (!phone) continue;

    if (!map[phone]) {
      map[phone] = {
        nombre: a.name || '',
        telefono: phone,
        correo: a.email || '',
        citas_activas: 0,
        citas_canceladas: 0,
        valor_facturado: 0,
        origen: a.origen || 'No especificado',
        primera_cita: a.createdAt || '',
        ultima_cita: a.createdAt || '',
      };
    }

    const rec = map[phone];

    // Actualizar nombre y correo si hay datos mas recientes
    if (a.name && !rec.nombre) rec.nombre = a.name;
    if (a.email && !rec.correo) rec.correo = a.email;
    if (a.origen && rec.origen === 'No especificado') rec.origen = a.origen;

    // Fechas
    if (a.createdAt < rec.primera_cita || !rec.primera_cita) rec.primera_cita = a.createdAt;
    if (a.createdAt > rec.ultima_cita) rec.ultima_cita = a.createdAt;

    if (a.status === 'cancelada') {
      rec.citas_canceladas += 1;
    } else {
      rec.citas_activas += 1;
      // Intentar sumar valor segun tipo (si esta guardado)
      if (a.valorCita) rec.valor_facturado += Number(a.valorCita) || 0;
    }
  }

  return Object.values(map).sort((a, b) => a.nombre.localeCompare(b.nombre));
}

/**
 * Exporta la tabla de clientes a un archivo Excel en /tmp/clientes_aura.xlsx
 * y devuelve el path del archivo.
 */
function exportToExcel() {
  const rows = buildClientTable();
  const data = [
    ['Nombre', 'Telefono', 'Correo', 'Citas activas', 'Citas canceladas', 'Valor facturado (COP)', 'Origen', 'Primera cita', 'Ultima cita'],
    ...rows.map((r) => [
      r.nombre,
      r.telefono,
      r.correo,
      r.citas_activas,
      r.citas_canceladas,
      r.valor_facturado,
      r.origen,
      r.primera_cita ? new Date(r.primera_cita).toLocaleDateString('es-CO') : '',
      r.ultima_cita ? new Date(r.ultima_cita).toLocaleDateString('es-CO') : '',
    ]),
  ];

  const wb = XLSX.utils.book_new();
  const ws = XLSX.utils.aoa_to_sheet(data);

  // Anchos de columna
  ws['!cols'] = [
    { wch: 28 }, { wch: 16 }, { wch: 30 }, { wch: 14 },
    { wch: 17 }, { wch: 22 }, { wch: 20 }, { wch: 16 }, { wch: 16 },
  ];

  XLSX.utils.book_append_sheet(wb, ws, 'Clientes');
  const filePath = '/tmp/clientes_aura.xlsx';
  XLSX.writeFile(wb, filePath);
  return filePath;
}

/**
 * Guarda o actualiza el origen de un cliente en su cita mas reciente.
 * Se llama desde agent.js cuando se detecta el origen en la conversacion.
 */
function saveClientOrigin(phone, origen) {
  if (!phone || !origen) return;
  const db = loadDB();
  const phoneClean = String(phone).replace(/\D/g, '');
  let updated = false;
  for (const a of Object.values(db.appointments || {})) {
    const ap = a.phone ? String(a.phone).replace(/\D/g, '') : '';
    if (ap === phoneClean && !a.origen) {
      a.origen = origen;
      updated = true;
    }
  }
  if (updated) fs.writeFileSync(DB_PATH, JSON.stringify(db, null, 2));
}

/**
 * Resumen de texto para Telegram (sin Excel).
 */
function buildSummaryText() {
  const rows = buildClientTable();
  if (rows.length === 0) return 'No hay clientes registrados aun.';

  const total = rows.length;
  const totalCitas = rows.reduce((s, r) => s + r.citas_activas, 0);
  const totalFacturado = rows.reduce((s, r) => s + r.valor_facturado, 0);

  let txt = `*Resumen de clientes Aura Luz*\n`;
  txt += `Total clientes: ${total}\n`;
  txt += `Total citas activas: ${totalCitas}\n`;
  if (totalFacturado > 0) txt += `Total facturado: $${totalFacturado.toLocaleString('es-CO')}\n`;
  txt += `\n*Detalle:*\n`;
  for (const r of rows.slice(0, 20)) {
    txt += `• ${r.nombre} — ${r.citas_activas} cita(s)`;
    if (r.origen && r.origen !== 'No especificado') txt += ` — ${r.origen}`;
    txt += '\n';
  }
  if (rows.length > 20) txt += `... y ${rows.length - 20} mas.`;
  return txt;
}

module.exports = { buildClientTable, exportToExcel, saveClientOrigin, buildSummaryText };
ENDOFFILE
echo "✅ clients.js creado"

# ================================================================
# 3. src/scheduler.js — recordatorios y vigilancia del calendario
# ================================================================
cat > /root/aura-luz/src/scheduler.js << 'ENDOFFILE'
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
 *    Detecta citas declinadas/canceladas por el paciente y avisa.
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

// Convierte una fecha a string legible en hora Bogota
function formatFechaBogota(isoStr) {
  return new Date(isoStr).toLocaleString('es-CO', {
    weekday: 'long', day: 'numeric', month: 'long',
    hour: 'numeric', minute: '2-digit', hour12: true,
    timeZone: config.timezone,
  });
}

// Hora actual en Bogota
function nowBogota() {
  return new Date(new Date().toLocaleString('en-US', { timeZone: config.timezone }));
}

// Ejecuta una funcion a una hora especifica (HH:MM) en hora Bogota, cada dia
function scheduleDaily(hhmm, fn, label) {
  const [targetH, targetM] = hhmm.split(':').map(Number);

  function tick() {
    const now = nowBogota();
    const h = now.getHours();
    const m = now.getMinutes();
    if (h === targetH && m === targetM) {
      console.log(`[scheduler] Ejecutando tarea: ${label}`);
      fn().catch((e) => console.error(`[scheduler] Error en ${label}:`, e.message));
    }
  }

  // Revisar cada minuto
  setInterval(tick, 60 * 1000);
  console.log(`[scheduler] Tarea programada: ${label} a las ${hhmm} Bogota`);
}

// Ejecuta una funcion cada N minutos
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
  const db = loadDB();
  const now = nowBogota();
  const todayStr = now.toISOString().slice(0, 10); // YYYY-MM-DD

  for (const [phone, session] of Object.entries(db.sessions || {})) {
    if (!session.lastAt) continue;
    if (phone === 'admin:daniela') continue;

    const lastAt = new Date(session.lastAt);
    const lastDateStr = new Date(lastAt.toLocaleString('en-US', { timeZone: config.timezone }))
      .toISOString().slice(0, 10);

    // Solo si la ultima interaccion fue hoy
    if (lastDateStr !== todayStr) continue;

    // Verificar si ya tiene una cita agendada hoy o en el futuro
    const appts = Object.values(db.appointments || {}).filter(
      (a) => a.status !== 'cancelada' &&
             a.phone && String(a.phone).replace(/\D/g, '') === String(phone).replace(/\D/g, '') &&
             new Date(a.start) > now
    );
    if (appts.length > 0) continue; // ya tiene cita, no molestar

    // Verificar que no hayamos enviado ya este recordatorio hoy
    if (session.recordatorio330Enviado === todayStr) continue;

    try {
      const mensaje = 'Hola 🌷 Habla Aura Luz, asistente de la Dra. Daniela. Queria saber si puedo ayudarte a reservar tu espacio hoy. Estoy aqui cuando quieras continuar 💛';
      await waClient.sendText(String(phone).replace(/\D/g, ''), toWhatsApp(mensaje));

      // Marcar que ya se envio hoy
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

    // Recordatorio 24h antes (entre 23.5h y 24.5h antes)
    if (diffHours >= 23.5 && diffHours < 24.5 && !appt.recordatorio24hEnviado) {
      try {
        if (pagado) {
          await templates.sendRecordatorioPagoConfirmado(phone, nombre, fechaHora, link);
        } else {
          await templates.sendRecordatorioPagoPendiente(phone, nombre, fechaHora, link);
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
        } else {
          await templates.sendRecordatorioPagoPendiente(phone, nombre, fechaHora, link);
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
// Detecta cuando un paciente declina su cita y avisa
// ----------------------------------------------------------------
async function vigilanciaCalendario() {
  const { getGraphToken } = require('./graph/auth');
  const axios = require('axios');
  const templates = require('./whatsapp/templates');
  const { bot } = require('./telegram/bot');
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

      // Solo vigilar citas futuras
      if (new Date(appt.start) < new Date()) continue;

      try {
        const { data } = await client.get(`/users/${organizer}/events/${appt.eventId}`);

        // Buscar si el asistente (paciente) declino
        const asistentes = data.attendees || [];
        const paciente = asistentes.find(
          (a) => a.emailAddress && a.emailAddress.address &&
                 appt.email && a.emailAddress.address.toLowerCase() === appt.email.toLowerCase()
        );

        if (paciente && paciente.status && paciente.status.response === 'declined') {
          // El paciente declino — verificar que no hayamos avisado ya
          if (appt.alertaCancelacionEnviada) continue;

          const fechaHora = formatFechaBogota(appt.start);
          const nombre = appt.name || 'el paciente';
          const phone = String(appt.phone).replace(/\D/g, '');

          // Avisar al paciente por WhatsApp
          try {
            await templates.sendAlertaCancelacionCliente(phone, nombre, fechaHora);
            console.log(`[scheduler] Alerta cancelacion cliente enviada a ${nombre}`);
          } catch (e) {
            console.error(`[scheduler] Error alerta WA a ${phone}:`, e.message);
          }

          // Avisar a Daniela por Telegram
          try {
            await bot.sendMessage(
              chatId,
              `⚠️ *Cancelacion detectada*\n\n*${nombre}* declino su cita del *${fechaHora}* desde su calendario.\n\nYa le envie un mensaje por WhatsApp para confirmar si fue intencional.`,
              { parse_mode: 'Markdown' }
            );
          } catch (e) {
            console.error(`[scheduler] Error notificacion Telegram:`, e.message);
          }

          // Marcar para no repetir
          db.appointments[id].alertaCancelacionEnviada = true;
          saveDB(db);
        }
      } catch (e) {
        // 404 = el evento ya no existe en Teams (fue borrado directamente)
        if (e.response && e.response.status === 404) {
          if (!appt.alertaCancelacionEnviada) {
            const fechaHora = formatFechaBogota(appt.start);
            const nombre = appt.name || 'el paciente';
            const phone = String(appt.phone).replace(/\D/g, '');

            try {
              await templates.sendAlertaCancelacionCliente(phone, nombre, fechaHora);
            } catch (err) {
              console.error(`[scheduler] Error alerta WA 404:`, err.message);
            }

            try {
              await bot.sendMessage(
                chatId,
                `⚠️ *Cita eliminada*\n\n*${nombre}* — la cita del *${fechaHora}* ya no existe en Teams (fue eliminada).`,
                { parse_mode: 'Markdown' }
              );
            } catch (err) {
              console.error(`[scheduler] Error Telegram 404:`, err.message);
            }

            db.appointments[id].alertaCancelacionEnviada = true;
            saveDB(db);
          }
        }
        // Otros errores: ignorar silenciosamente para no saturar logs
      }
    }
  } catch (e) {
    console.error('[scheduler] Error en vigilanciaCalendario:', e.message);
  }
}

// ----------------------------------------------------------------
// Arrancar todas las tareas
// ----------------------------------------------------------------
function startScheduler() {
  scheduleDaily('15:30', recordatorioConversacionesIncompletas, 'Recordatorio 3:30pm');
  scheduleDaily('07:00', recordatoriosCitas, 'Recordatorio 7am citas');
  scheduleInterval(1, recordatoriosCitas, 'Recordatorio 24h citas'); // cada minuto para no perder la ventana
  scheduleInterval(30, vigilanciaCalendario, 'Vigilancia calendario Teams');

  // Ejecutar vigilancia al arrancar (sin esperar 30 min)
  setTimeout(() => {
    vigilanciaCalendario().catch((e) =>
      console.error('[scheduler] Error inicial vigilancia:', e.message)
    );
  }, 10000);
}

module.exports = { startScheduler };
ENDOFFILE
echo "✅ scheduler.js creado"

# ================================================================
# 4. Modificar index.js para arrancar el scheduler
# ================================================================
node << 'ENDOFNODE'
const fs = require('fs');
const filePath = '/root/aura-luz/src/index.js';
let code = fs.readFileSync(filePath, 'utf-8');

const OLD = `app.get('/health', (req, res) => res.json({ status: 'Aura Luz despierta' }));`;
const NEW = `app.get('/health', (req, res) => res.json({ status: 'Aura Luz despierta' }));

// Scheduler: recordatorios, vigilancia calendario
const { startScheduler } = require('./scheduler');
startScheduler();`;

if (!code.includes(OLD)) {
  console.error('ERROR: no se encontro el bloque en index.js');
  process.exit(1);
}
code = code.replace(OLD, NEW);
fs.writeFileSync(filePath, code, 'utf-8');
console.log('index.js OK');
ENDOFNODE
echo "✅ index.js actualizado"

# ================================================================
# 5. Modificar telegram/bot.js para agregar comandos de clientes
# ================================================================
# Buscar donde esta el archivo del bot de Telegram
BOT_FILE="/root/aura-luz/src/telegram/bot.js"

if [ -f "$BOT_FILE" ]; then
  cp "$BOT_FILE" "${BOT_FILE}.bak"

  node << 'ENDOFNODE'
const fs = require('fs');
const filePath = '/root/aura-luz/src/telegram/bot.js';
let code = fs.readFileSync(filePath, 'utf-8');

// Agregar comando /clientes al final del archivo, antes del module.exports
const clientesCode = `

// ---- Comando /clientes: envia tabla de clientes a Daniela ----
bot.onText(/\\/clientes/, async (msg) => {
  const chatId = String(msg.chat.id);
  const danielaId = String(require('../config').telegram.danielaChatId);
  if (chatId !== danielaId) return;

  try {
    const { exportToExcel, buildSummaryText } = require('../clients');
    // Resumen de texto primero
    const resumen = buildSummaryText();
    await bot.sendMessage(chatId, resumen, { parse_mode: 'Markdown' });
    // Luego el Excel
    const filePath = exportToExcel();
    await bot.sendDocument(chatId, filePath, {}, { filename: 'clientes_aura.xlsx', contentType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' });
  } catch (e) {
    console.error('[bot] Error /clientes:', e.message);
    await bot.sendMessage(chatId, 'Hubo un error generando el reporte de clientes. Intenta de nuevo.');
  }
});
`;

// Insertar antes del module.exports final
if (code.includes('module.exports')) {
  const idx = code.lastIndexOf('module.exports');
  code = code.slice(0, idx) + clientesCode + '\n' + code.slice(idx);
  fs.writeFileSync(filePath, code, 'utf-8');
  console.log('bot.js OK');
} else {
  // Si no hay module.exports, agregar al final
  code += clientesCode;
  fs.writeFileSync(filePath, code, 'utf-8');
  console.log('bot.js OK (sin module.exports previo)');
}
ENDOFNODE
  echo "✅ bot.js actualizado con comando /clientes"
else
  echo "⚠️  No se encontro bot.js en $BOT_FILE — omitiendo comando /clientes"
fi

# ================================================================
# 6. Modificar store.js para guardar origen del cliente
# ================================================================
node << 'ENDOFNODE'
const fs = require('fs');
const filePath = '/root/aura-luz/src/store.js';
let code = fs.readFileSync(filePath, 'utf-8');

// Agregar funcion saveClientOrigin al store si no existe
if (!code.includes('saveClientOrigin')) {
  const newFn = `
// Guarda el origen del cliente (Instagram, referido, etc.) en sus citas
function saveClientOrigin(phone, origen) {
  if (!phone || !origen) return;
  const db = loadDB();
  const phoneClean = String(phone).replace(/\\D/g, '');
  let updated = false;
  for (const a of Object.values(db.appointments || {})) {
    const ap = a.phone ? String(a.phone).replace(/\\D/g, '') : '';
    if (ap === phoneClean && !a.origen) {
      a.origen = origen;
      updated = true;
    }
  }
  if (updated) saveDB(db);
}

`;
  // Insertar antes del module.exports
  const idx = code.lastIndexOf('module.exports');
  code = code.slice(0, idx) + newFn + code.slice(idx);

  // Agregar saveClientOrigin al exports
  code = code.replace(
    'module.exports = {',
    'module.exports = {\n  saveClientOrigin,'
  );

  fs.writeFileSync(filePath, code, 'utf-8');
  console.log('store.js OK');
} else {
  console.log('store.js ya tenia saveClientOrigin, sin cambios');
}
ENDOFNODE
echo "✅ store.js actualizado"

# ================================================================
# 7. Reiniciar servicio
# ================================================================
echo "=== Reiniciando Aura Luz ==="
systemctl restart aura-luz
sleep 4
systemctl is-active aura-luz && echo "✅ Servicio activo y corriendo" || echo "❌ Error al reiniciar"
journalctl -u aura-luz -n 12 --no-pager

echo ""
echo "=== Features aplicados ==="
echo "  - templates.js: funciones para las 4 plantillas WhatsApp"
echo "  - scheduler.js: recordatorio 3:30pm + recordatorios 24h/7am + vigilancia Teams"
echo "  - clients.js: registro de clientes exportable a Excel"
echo "  - index.js: arranca el scheduler al iniciar"
echo "  - bot.js: comando /clientes para Daniela en Telegram"
echo "  - store.js: campo origen del cliente"
echo ""
echo "  Daniela puede escribir /clientes en Telegram para obtener el reporte Excel."
