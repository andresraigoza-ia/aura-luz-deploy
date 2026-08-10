#!/bin/bash
set -e
cd /root/aura-luz

echo "==> Paso 1: Agregando funciones de solicitudes pendientes a store.js..."
node << 'JSEOF'
const fs = require('fs');
const f = './src/store.js';
let c = fs.readFileSync(f, 'utf-8');

const funcs = `
// ---- Solicitudes pendientes (presencial, etc.) ----
function savePendingRequest(id, data) {
  const db = loadDB();
  if (!db.pendingRequests) db.pendingRequests = {};
  db.pendingRequests[id] = { ...data, createdAt: new Date().toISOString() };
  saveDB(db);
}

function getPendingRequest(id) {
  const db = loadDB();
  return (db.pendingRequests || {})[id] || null;
}

function deletePendingRequest(id) {
  const db = loadDB();
  if (db.pendingRequests && db.pendingRequests[id]) {
    delete db.pendingRequests[id];
    saveDB(db);
  }
}

`;

c = c.replace(
  'module.exports = {\n  logOutboundMessage,',
  funcs + 'module.exports = {\n  savePendingRequest,\n  getPendingRequest,\n  deletePendingRequest,\n  logOutboundMessage,'
);

fs.writeFileSync(f, c);
console.log('[OK] store.js');
JSEOF

echo "==> Paso 2: Actualizando escalate_to_daniela en agent.js..."
node << 'JSEOF'
const fs = require('fs');
const f = './src/aura/agent.js';
let c = fs.readFileSync(f, 'utf-8');

const newImpl = `  if (name === 'escalate_to_daniela') {
    try {
      const { bot } = require('../telegram/bot');
      const chatId = require('../config').telegram.danielaChatId;
      const reqId = require('uuid').v4().slice(0, 8);

      // Guardar solicitud pendiente con todos los datos para poder agendar despues
      store.savePendingRequest(reqId, {
        type: 'presencial',
        message: input.message,
        patientName: input.patient_name || '',
        patientEmail: input.patient_email || '',
        patientPhone: input.patient_phone || ctx.phone || '',
        startISO: input.start_iso || '',
        endISO: input.end_iso || '',
        reason: input.reason || '',
        sessionValue: input.session_value || 0,
      });

      await bot.sendMessage(chatId,
        '🌷 <b>SOLICITUD DE CITA PRESENCIAL</b>\\n\\n' + input.message,
        {
          parse_mode: 'HTML',
          reply_markup: {
            inline_keyboard: [
              [
                { text: '✅ Aprobar presencial', callback_data: 'pres_ok:' + reqId },
                { text: '❌ Solo virtual', callback_data: 'pres_no:' + reqId },
              ],
            ],
          },
        }
      );
      return { escalated: true, message: 'Solicitud enviada a la Doc con botones. Esperando su decision.' };
    } catch (e) {
      return { error: 'FALLO_ESCALAR', motivo: e.message };
    }
  }

  return { error: \\\`Herramienta desconocida: \\\${name}\\\` };`;

c = c.replace(
  /  if \(name === 'escalate_to_daniela'\) \{[\s\S]*?return \{ error: `Herramienta desconocida: \$\{name\}` \};/,
  newImpl
);

fs.writeFileSync(f, c);
console.log('[OK] agent.js');
JSEOF

echo "==> Paso 3: Actualizando tools.js - agregar campos al escalate_to_daniela..."
node << 'JSEOF'
const fs = require('fs');
const f = './src/aura/tools.js';
let c = fs.readFileSync(f, 'utf-8');

c = c.replace(
  "message: { type: 'string', description: 'Mensaje completo para Daniela con toda la informacion relevante (nombre del paciente, telefono, correo, que pide, horario, etc.)' },\n      },\n      required: ['message'],",
  "message: { type: 'string', description: 'Mensaje resumen para Daniela con toda la informacion relevante.' },\n        patient_name: { type: 'string', description: 'Nombre completo del paciente' },\n        patient_email: { type: 'string', description: 'Correo del paciente' },\n        patient_phone: { type: 'string', description: 'Celular del paciente' },\n        start_iso: { type: 'string', description: 'Fecha/hora de inicio solicitada (de check_availability)' },\n        end_iso: { type: 'string', description: 'Fecha/hora de fin' },\n        reason: { type: 'string', description: 'Motivo de la cita' },\n        session_value: { type: 'number', description: 'Valor de la sesion en COP' },\n      },\n      required: ['message', 'patient_name', 'patient_email', 'patient_phone', 'start_iso', 'end_iso'],"
);

fs.writeFileSync(f, c);
console.log('[OK] tools.js');
JSEOF

echo "==> Paso 4: Agregando handler de botones presencial en bot.js..."
node << 'JSEOF'
const fs = require('fs');
const f = './src/telegram/bot.js';
let c = fs.readFileSync(f, 'utf-8');

// Agregar handler para pres_ok y pres_no dentro del callback_query existente
const presHandler = `
  // ---- Aprobacion/rechazo de cita presencial ----
  if (action === 'pres_ok' || action === 'pres_no') {
    const reqId = query.data.split(':')[1];
    const pending = store.getPendingRequest(reqId);
    if (!pending) {
      await bot.answerCallbackQuery(query.id, { text: 'Solicitud no encontrada o ya procesada' });
      return;
    }

    if (action === 'pres_ok') {
      try {
        const { createTeamsAppointment } = require('./graph/calendar');
        const { v4: uuid } = require('uuid');
        const config2 = require('./config');

        const pKey = store.patientKeyFromRaw({ phone: pending.patientPhone, email: pending.patientEmail, name: pending.patientName });
        const visitNum = store.countActiveAppointmentsForPatient(pKey) + 1;
        const subject = 'Sesion - DRGsoul # ' + visitNum + ' - ' + pending.patientName;

        const { eventId, joinUrl } = await createTeamsAppointment({
          subject,
          startISO: pending.startISO,
          endISO: pending.endISO,
          attendeeEmail: pending.patientEmail,
          attendeeName: pending.patientName,
          bodyText: 'Paciente: ' + pending.patientName + '\\nMotivo: ' + (pending.reason || ''),
          presencial: true,
        });

        store.createAppointment({
          id: uuid(),
          eventId,
          joinUrl,
          phone: pending.patientPhone,
          name: pending.patientName,
          email: pending.patientEmail,
          reason: pending.reason || '',
          start: pending.startISO,
          end: pending.endISO,
          patientVisitNumber: visitNum,
          isAdminBooking: false,
          presencial: true,
          valorSesion: pending.sessionValue || 0,
          createdAt: new Date().toISOString(),
        });

        // Notificar al paciente por WhatsApp
        const phone2 = String(pending.patientPhone).replace(/\\D/g, '');
        const fechaHora = new Date(pending.startISO).toLocaleString('es-CO', {
          weekday: 'long', day: 'numeric', month: 'long',
          hour: 'numeric', minute: '2-digit', hour12: true,
          timeZone: config2.timezone,
        });
        const waClient2 = require('./whatsapp/client');
        await waClient2.sendText(phone2,
          'Hola ' + pending.patientName.split(' ')[0] + ' 🌷 Tu sesion presencial quedo confirmada para el ' + fechaHora + ' ✨ Te llego la invitacion al correo con el enlace de Teams por si lo necesitas como respaldo. Nos vemos pronto 💛'
        );
        store.logOutboundMessage(phone2, 'Sesion presencial confirmada para el ' + fechaHora);

        await bot.answerCallbackQuery(query.id, { text: 'Presencial aprobada y paciente notificado ✅' });
        await bot.sendMessage(query.message.chat.id,
          '✅ <b>Cita presencial creada</b>\\n\\n<b>Paciente:</b> ' + pending.patientName + '\\n<b>Sesion #:</b> ' + visitNum + '\\n<b>Fecha:</b> ' + fechaHora + '\\n<b>Paciente notificado por WhatsApp</b> ✔️',
          { parse_mode: 'HTML' });
      } catch(e) {
        console.error('[bot] Error creando cita presencial:', e.message);
        await bot.answerCallbackQuery(query.id, { text: 'Error: ' + e.message });
      }
    } else {
      // Rechazar: solo virtual
      const phone2 = String(pending.patientPhone).replace(/\\D/g, '');
      const waClient2 = require('./whatsapp/client');
      await waClient2.sendText(phone2,
        'Hola ' + pending.patientName.split(' ')[0] + ' 🌷 Por el momento la Dra. Daniela solo tiene disponibilidad para sesion virtual (por Teams). Si deseas agendar tu sesion virtual, con gusto te ayudo 💛'
      );
      store.logOutboundMessage(phone2, 'Solicitud presencial no disponible, se ofrecio virtual.');
      await bot.answerCallbackQuery(query.id, { text: 'Paciente informado — solo virtual' });
    }

    store.deletePendingRequest(reqId);
    await bot.editMessageReplyMarkup(
      { inline_keyboard: [] },
      { chat_id: query.message.chat.id, message_id: query.message.message_id }
    );
    return;
  }`;

// Insertar despues del handler de pay_ok/pay_no
c = c.replace(
  "  await bot.editMessageReplyMarkup(\n    { inline_keyboard: [] },\n    { chat_id: query.message.chat.id, message_id: query.message.message_id }\n  );\n});",
  "  await bot.editMessageReplyMarkup(\n    { inline_keyboard: [] },\n    { chat_id: query.message.chat.id, message_id: query.message.message_id }\n  );\n  return;\n  }\n" + presHandler + "\n});"
);

// Fix: necesitamos que bot.js importe las funciones extra de store
if (!c.includes('countActiveAppointmentsForPatient')) {
  c = c.replace(
    "const store = require('../store');",
    "const store = require('../store');"
  );
}

fs.writeFileSync(f, c);
console.log('[OK] bot.js');
JSEOF

echo "==> Paso 5: Fix imports en bot.js (graph/calendar path)..."
node << 'JSEOF'
const fs = require('fs');
const f = './src/telegram/bot.js';
let c = fs.readFileSync(f, 'utf-8');

// Fix path for createTeamsAppointment - it's relative to telegram/ not src/
c = c.replace(
  "require('./graph/calendar')",
  "require('../graph/calendar')"
);

// Fix path for config
c = c.replace(
  "require('./config')",
  "require('../config')"
);

// Fix uuid import
c = c.replace(
  "const { v4: uuid } = require('uuid');",
  "const { v4: uuidv4 } = require('uuid');"
);
c = c.replace(
  "id: uuid(),",
  "id: require('uuid').v4(),"
);

fs.writeFileSync(f, c);
console.log('[OK] bot.js paths fixed');
JSEOF

echo "==> Paso 6: Reiniciando..."
systemctl restart aura-luz
sleep 2

echo "==> Verificando..."
node -e 'var t = require("/root/aura-luz/src/aura/tools").TOOLS; console.log("Tools:", t.length, "OK:", t.filter(function(x){return x!==undefined}).length);'

echo "✅ Listo. Botones de presencial activados."
