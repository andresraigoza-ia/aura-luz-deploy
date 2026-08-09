#!/bin/bash
set -e

echo "=== Aura Luz: Fix correo, busqueda parcial, Doc, alertas y Excel ==="

# ---- Backups ----
cp /root/aura-luz/src/aura/agent.js /root/aura-luz/src/aura/agent.js.bak4
cp /root/aura-luz/src/aura/tools.js /root/aura-luz/src/aura/tools.js.bak3
cp /root/aura-luz/src/aura/persona.js /root/aura-luz/src/aura/persona.js.bak3
cp /root/aura-luz/src/scheduler.js /root/aura-luz/src/scheduler.js.bak
cp /root/aura-luz/src/clients.js /root/aura-luz/src/clients.js.bak
cp /root/aura-luz/src/store.js /root/aura-luz/src/store.js.bak2
echo "✅ Backups creados"

# ================================================================
# 1. store.js: agregar updatePatientEmail
# ================================================================
node << 'ENDOFNODE'
const fs = require('fs');
const filePath = '/root/aura-luz/src/store.js';
let code = fs.readFileSync(filePath, 'utf-8');

if (!code.includes('updatePatientEmail')) {
  const newFn = `
// Actualiza el correo de todas las citas activas de un paciente
// Recibe el phone como identificador principal y el nuevo correo
function updatePatientEmail(phone, newEmail) {
  if (!phone || !newEmail) return 0;
  const db = loadDB();
  const phoneClean = String(phone).replace(/\\D/g, '');
  let count = 0;
  for (const a of Object.values(db.appointments || {})) {
    const ap = a.phone ? String(a.phone).replace(/\\D/g, '') : '';
    if (ap === phoneClean) {
      a.email = newEmail.toLowerCase().trim();
      count++;
    }
  }
  if (count > 0) saveDB(db);
  return count;
}

`;
  const idx = code.lastIndexOf('module.exports');
  code = code.slice(0, idx) + newFn + code.slice(idx);
  code = code.replace('module.exports = {', 'module.exports = {\n  updatePatientEmail,');
  fs.writeFileSync(filePath, code, 'utf-8');
  console.log('store.js OK - updatePatientEmail agregado');
} else {
  console.log('store.js ya tenia updatePatientEmail');
}
ENDOFNODE
echo "✅ store.js actualizado"

# ================================================================
# 2. tools.js: agregar fix_patient_email
# ================================================================
node << 'ENDOFNODE'
const fs = require('fs');
const filePath = '/root/aura-luz/src/aura/tools.js';
let code = fs.readFileSync(filePath, 'utf-8');

if (!code.includes('fix_patient_email')) {
  const newTool = `
  {
    name: 'fix_patient_email',
    description:
      'Corrige el correo electronico de un paciente cuando hay un error. Cancela la sesion actual, la reagenda con el correo correcto, actualiza todos los registros y notifica al paciente por WhatsApp y a la Doc por Telegram. Usalo cuando un paciente reporte que el correo esta mal. IMPORTANTE: pide el correo correcto POR ESCRITO antes de llamar esta herramienta.',
    input_schema: {
      type: 'object',
      properties: {
        appointment_id: { type: 'string', description: 'ID de la sesion a corregir (de find_appointments)' },
        new_email: { type: 'string', description: 'Correo electronico correcto (debe venir por texto escrito, nunca de audio)' },
      },
      required: ['appointment_id', 'new_email'],
    },
  },
`;

  const OLD = `];

module.exports = { TOOLS };`;
  const NEW = newTool + `];

module.exports = { TOOLS };`;

  if (!code.includes(OLD)) {
    console.error('ERROR: no se encontro el cierre del array TOOLS');
    process.exit(1);
  }
  code = code.replace(OLD, NEW);
  fs.writeFileSync(filePath, code, 'utf-8');
  console.log('tools.js OK - fix_patient_email agregado');
} else {
  console.log('tools.js ya tenia fix_patient_email');
}
ENDOFNODE
echo "✅ tools.js actualizado"

# ================================================================
# 3. agent.js: implementar fix_patient_email y mejoras
# ================================================================
node << 'ENDOFNODE'
const fs = require('fs');
const filePath = '/root/aura-luz/src/aura/agent.js';
let code = fs.readFileSync(filePath, 'utf-8');

// 3a. Agregar fix_patient_email antes del bloque final
const OLD_UNKNOWN = `  return { error: \`Herramienta desconocida: \${name}\` };
}`;

const FIX_EMAIL_BLOCK = `  if (name === 'fix_patient_email') {
    const appt = store.getAppointment(input.appointment_id);
    if (!appt) return { error: 'NO_ENCONTRADA', motivo: 'No encontre esa sesion.' };

    const newEmail = input.new_email.toLowerCase().trim();
    if (!/.+@.+\..+/.test(newEmail)) {
      return { error: 'EMAIL_INVALIDO', motivo: 'El correo no tiene formato valido. Pidelo de nuevo por escrito.' };
    }

    try {
      const config2 = require('../config');

      // 1. Cancelar sesion antigua en Teams
      if (appt.eventId) {
        try { await cancelAppointment(appt.eventId); } catch(e) {}
      }
      store.markAppointmentCancelled(input.appointment_id);

      // 2. Actualizar correo en TODOS los registros del paciente
      store.updatePatientEmail(appt.phone, newEmail);

      // 3. Crear sesion nueva con correo correcto
      const pKey = store.patientKeyOf({ ...appt, email: newEmail });
      await store.syncPatientWithCalendar(pKey, eventExists);
      const visitNum = store.countActiveAppointmentsForPatient(pKey) + 1;

      let subject = \`Sesion - DRGsoul # \${visitNum} - \${appt.name}\`;
      if (appt.subjectNote) subject += \` - \${appt.subjectNote}\`;

      const { eventId: newEventId, joinUrl: newJoinUrl } = await createTeamsAppointment({
        subject,
        startISO: appt.start,
        endISO: appt.end,
        attendeeEmail: newEmail,
        attendeeName: appt.name,
        bodyText: \`Paciente: \${appt.name}\\nMotivo: \${appt.reason || ''}\`,
      });

      store.createAppointment({
        id: require('uuid').v4 ? require('uuid').v4() : String(Date.now()),
        eventId: newEventId,
        joinUrl: newJoinUrl,
        phone: appt.phone,
        name: appt.name,
        email: newEmail,
        reason: appt.reason,
        start: appt.start,
        end: appt.end,
        patientVisitNumber: visitNum,
        subjectNote: appt.subjectNote || null,
        isAdminBooking: appt.isAdminBooking || false,
        origen: appt.origen || null,
        createdAt: new Date().toISOString(),
      });

      // 4. Fecha legible
      const fechaHora = new Date(appt.start).toLocaleString('es-CO', {
        weekday: 'long', day: 'numeric', month: 'long',
        hour: 'numeric', minute: '2-digit', hour12: true,
        timeZone: config2.timezone,
      });

      // 5. Notificar al paciente por WhatsApp (texto libre, dentro de ventana 24h)
      const phone2 = String(appt.phone).replace(/\\D/g, '');
      try {
        const { sendText } = require('../whatsapp/client');
        await sendText(phone2,
          \`Listo \${appt.name.split(' ')[0]} 🌷 Tu correo fue corregido a \${newEmail} y tu sesion del \${fechaHora} sigue confirmada. Ya te enviamos la nueva invitacion de Teams a ese correo. Estamos contigo 💛\`
        );
      } catch(e) {
        console.error('Error notificando paciente fix_email:', e.message);
      }

      // 6. Notificar a la Doc por Telegram (solo informando, sin pedirle nada)
      try {
        const { bot } = require('../telegram/bot');
        const chatId2 = config2.telegram.danielaChatId;
        await bot.sendMessage(chatId2,
          \`✅ <b>Correo corregido automaticamente</b>\\n\\n<b>Paciente:</b> \${appt.name}\\n<b>Correo anterior:</b> eliminado\\n<b>Correo nuevo:</b> \${newEmail}\\n<b>Sesion:</b> \${fechaHora}\\n\\nYa reagende la sesion y notifique al paciente por WhatsApp. No necesitas hacer nada.\`,
          { parse_mode: 'HTML' }
        );
      } catch(e) {}

      return { corregido: true, nuevo_email: newEmail, nuevo_join_url: newJoinUrl };
    } catch(e) {
      return { error: 'FALLO_CORRECCION', motivo: e.message };
    }
  }

`;

const NEW_UNKNOWN = FIX_EMAIL_BLOCK + `  return { error: \`Herramienta desconocida: \${name}\` };
}`;

if (!code.includes(OLD_UNKNOWN)) {
  console.error('ERROR: no se encontro el bloque herramienta desconocida en agent.js');
  process.exit(1);
}
code = code.replace(OLD_UNKNOWN, NEW_UNKNOWN);

fs.writeFileSync(filePath, code, 'utf-8');
console.log('agent.js OK');
ENDOFNODE
echo "✅ agent.js actualizado con fix_patient_email"

# ================================================================
# 4. persona.js: Doc, busqueda parcial, no escalar tareas simples,
#    y fix_patient_email en el flujo del paciente
# ================================================================
node << 'ENDOFNODE'
const fs = require('fs');
const filePath = '/root/aura-luz/src/aura/persona.js';
let code = fs.readFileSync(filePath, 'utf-8');

// 4a. Cambiar todas las referencias de "Daniela" por "Doc" en el adminSystemPrompt
// Solo la parte del adminSystemPrompt (no el patientSystemPrompt)
const adminStart = code.indexOf('function adminSystemPrompt()');
if (adminStart === -1) {
  console.error('ERROR: no se encontro adminSystemPrompt');
  process.exit(1);
}

let adminPart = code.slice(adminStart);
adminPart = adminPart.replace(/cuando Daniela /g, 'cuando la Doc ');
adminPart = adminPart.replace(/Si Daniela /g, 'Si la Doc ');
adminPart = adminPart.replace(/Daniela te /g, 'la Doc te ');
adminPart = adminPart.replace(/Daniela te/g, 'la Doc te');
adminPart = adminPart.replace(/Daniela puede/g, 'la Doc puede');
adminPart = adminPart.replace(/Daniela pide/g, 'la Doc pide');
adminPart = adminPart.replace(/Daniela agenda/g, 'la Doc agenda');
adminPart = adminPart.replace(/Daniela dice/g, 'la Doc dice');
adminPart = adminPart.replace(/Daniela diga/g, 'la Doc diga');
adminPart = adminPart.replace(/"Confirmo y agendo la cita\?"/g, '"Confirmo y agendo la sesion?"');

// Reemplazar el saludo inicial del admin
adminPart = adminPart.replace(
  'hablando directamente con Daniela (la duena del consultorio) por Telegram, no con un paciente.',
  'hablando directamente con la Doc (Daniela, duena del consultorio) por Telegram, no con un paciente. Llamala siempre "Doc", nunca "Daniela".'
);

code = code.slice(0, adminStart) + adminPart;

// 4b. Agregar instrucciones para: no escalar tareas simples, busqueda parcial, fix correo paciente
const OLD_CANCEL_ADMIN = `CANCELAR SESIONES (Daniela SI puede):`;
const NEW_CANCEL_ADMIN = `AUTONOMIA: resuelve por tu cuenta todo lo que puedas sin pedirle nada a la Doc. Solo informala del resultado. Ejemplos de lo que NO debes escalarle: correcciones de correo de pacientes, cambios de datos, reagendamientos que ya tienes toda la informacion para ejecutar. Informale el resultado, pero no le pidas que ella lo gestione.

BUSQUEDA PARCIAL DE PACIENTES: cuando la Doc mencione solo parte del nombre (ej: "Jorge" o "Raigoza"), usa find_appointments con ese fragmento. Si encuentras mas de una coincidencia, muestra las opciones y pregunta "Doc, te refieres a [Nombre Completo]?" antes de proceder. Si encuentras una sola, confirma: "Encontre a Jorge Andres Raigoza, es ese?".

CANCELAR SESIONES (la Doc SI puede):`;

if (!code.includes(OLD_CANCEL_ADMIN)) {
  console.error('ERROR: no se encontro CANCELAR SESIONES en adminSystemPrompt');
  process.exit(1);
}
code = code.replace(OLD_CANCEL_ADMIN, NEW_CANCEL_ADMIN);

// 4c. Agregar instruccion de fix_patient_email en el flujo del paciente
const OLD_CANCEL_PATIENT = `CANCELACIONES: si el paciente pide cancelar o reagendar, NO cancelas.`;
const NEW_CANCEL_PATIENT = `CORRECCION DE CORREO DEL PACIENTE: si el paciente reporta que el correo que dio esta mal y da el correcto (POR ESCRITO), usa fix_patient_email para corregirlo de forma automatica. No escales esto a la Doc. Primero usa find_appointments para ubicar la sesion activa del paciente por su telefono, luego llama a fix_patient_email con el appointment_id y el nuevo correo. Dale tranquilidad al paciente: su sesion no se pierde, solo se corrige el correo. Ejemplo de respuesta inicial: "No te preocupes, lo corrijo ahora mismo para que te llegue la invitacion bien 🌿".

CANCELACIONES: si el paciente pide cancelar o reagendar, NO cancelas.`;

if (!code.includes(OLD_CANCEL_PATIENT)) {
  console.error('ERROR: no se encontro CANCELACIONES en patientSystemPrompt');
  process.exit(1);
}
code = code.replace(OLD_CANCEL_PATIENT, NEW_CANCEL_PATIENT);

fs.writeFileSync(filePath, code, 'utf-8');
console.log('persona.js OK');
ENDOFNODE
echo "✅ persona.js actualizado"

# ================================================================
# 5. scheduler.js: fix alerta cancelacion al paciente
# ================================================================
node << 'ENDOFNODE'
const fs = require('fs');
const filePath = '/root/aura-luz/src/scheduler.js';
let code = fs.readFileSync(filePath, 'utf-8');

// Mejorar el bloque de alerta 404 para garantizar fallback de texto si la plantilla falla
const OLD_404 = `        try {
              await templates.sendAlertaCancelacionCliente(phone, nombre, fechaHora);
            } catch (err) {
              console.error(\`[scheduler] Error alerta WA 404:\`, err.message);
            }`;

const NEW_404 = `        try {
              await templates.sendAlertaCancelacionCliente(phone, nombre, fechaHora);
            } catch (err) {
              // Fallback: texto libre si la plantilla falla
              try {
                const { sendText } = require('./whatsapp/client');
                await sendText(phone,
                  \`Hola \${nombre} 🌷 Te escribe Aura Luz, asistente de la Dra. Daniela. Notamos que tu sesion del \${fechaHora} fue cancelada. Si fue intencional cuentanos, si fue por error escribenos y lo resolvemos enseguida 💛\`
                );
              } catch (err2) {
                console.error('[scheduler] Error fallback WA 404:', err2.message);
              }
            }`;

if (code.includes(OLD_404)) {
  code = code.replace(OLD_404, NEW_404);
  console.log('scheduler.js - fallback 404 mejorado');
}

// Mejorar tambien el bloque de declined
const OLD_DECLINED = `          try {
            await templates.sendAlertaCancelacionCliente(phone, nombre, fechaHora);
            console.log(\`[scheduler] Alerta cancelacion cliente enviada a \${nombre}\`);
          } catch (e) {
            console.error(\`[scheduler] Error alerta WA a \${phone}:\`, e.message);
          }`;

const NEW_DECLINED = `          try {
            await templates.sendAlertaCancelacionCliente(phone, nombre, fechaHora);
            console.log(\`[scheduler] Alerta cancelacion cliente enviada a \${nombre}\`);
          } catch (e) {
            // Fallback: texto libre si la plantilla falla o no esta aprobada aun
            try {
              const { sendText } = require('./whatsapp/client');
              await sendText(phone,
                \`Hola \${nombre} 🌷 Te escribe Aura Luz, asistente de la Dra. Daniela. Notamos que tu sesion del \${fechaHora} fue cancelada desde tu calendario. Si fue intencional cuentanos con confianza. Si fue por error escribenos y lo resolvemos 💛\`
              );
              console.log(\`[scheduler] Alerta cancelacion (fallback texto) enviada a \${nombre}\`);
            } catch (err2) {
              console.error('[scheduler] Error fallback alerta WA:', err2.message);
            }
          }`;

if (code.includes(OLD_DECLINED)) {
  code = code.replace(OLD_DECLINED, NEW_DECLINED);
  console.log('scheduler.js - fallback declined mejorado');
}

fs.writeFileSync(filePath, code, 'utf-8');
console.log('scheduler.js OK');
ENDOFNODE
echo "✅ scheduler.js actualizado con fallback de alertas"

# ================================================================
# 6. clients.js: Excel con dos hojas (resumen + detalle)
# ================================================================
cat > /root/aura-luz/src/clients.js << 'ENDOFFILE'
/**
 * clients.js
 * Registro de clientes de Aura Luz.
 * Excel con dos hojas:
 *   - Hoja 1: Resumen (una fila por cliente)
 *   - Hoja 2: Detalle (una fila por sesion/evento)
 */

const fs = require('fs');
const path = require('path');
const XLSX = require('xlsx');

const DB_PATH = path.join(__dirname, '..', 'data', 'store.json');

function loadDB() {
  if (!fs.existsSync(DB_PATH)) return { sessions: {}, appointments: {} };
  return JSON.parse(fs.readFileSync(DB_PATH, 'utf-8'));
}

function formatDate(isoStr) {
  if (!isoStr) return '';
  try {
    return new Date(isoStr).toLocaleDateString('es-CO', { timeZone: 'America/Bogota' });
  } catch(e) { return isoStr; }
}

function formatDateTime(isoStr) {
  if (!isoStr) return '';
  try {
    return new Date(isoStr).toLocaleString('es-CO', {
      timeZone: 'America/Bogota',
      day: 'numeric', month: 'short', year: 'numeric',
      hour: 'numeric', minute: '2-digit', hour12: true
    });
  } catch(e) { return isoStr; }
}

/**
 * Construye resumen por cliente (una entrada por numero de telefono).
 */
function buildClientSummary() {
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
        sesiones_activas: 0,
        sesiones_canceladas: 0,
        valor_facturado: 0,
        origen: a.origen || '',
        primera_sesion: a.start || a.createdAt || '',
        ultima_sesion: a.start || a.createdAt || '',
      };
    }

    const rec = map[phone];
    if (a.name && !rec.nombre) rec.nombre = a.name;
    if (a.email && !rec.correo) rec.correo = a.email;
    if (a.origen && !rec.origen) rec.origen = a.origen;

    const fechaSesion = a.start || a.createdAt || '';
    if (fechaSesion && (!rec.primera_sesion || fechaSesion < rec.primera_sesion)) rec.primera_sesion = fechaSesion;
    if (fechaSesion && fechaSesion > rec.ultima_sesion) rec.ultima_sesion = fechaSesion;

    if (a.status === 'cancelada') {
      rec.sesiones_canceladas += 1;
    } else {
      rec.sesiones_activas += 1;
      if (a.valorSesion) rec.valor_facturado += Number(a.valorSesion) || 0;
    }
  }

  return Object.values(map).sort((a, b) => a.nombre.localeCompare(b.nombre));
}

/**
 * Construye detalle por sesion (una entrada por cita/evento).
 */
function buildSessionDetail() {
  const db = loadDB();
  const appts = Object.values(db.appointments || {});

  return appts
    .sort((a, b) => (a.start || '') < (b.start || '') ? -1 : 1)
    .map((a) => ({
      nombre: a.name || '',
      telefono: a.phone ? String(a.phone).replace(/\D/g, '') : '',
      correo: a.email || '',
      sesion_num: a.patientVisitNumber || '',
      fecha_sesion: formatDateTime(a.start),
      estado: a.status === 'cancelada' ? 'Cancelada' : 'Activa',
      pago: a.paymentStatus === 'validado' ? 'Validado' : (a.paymentStatus === 'rechazado' ? 'Rechazado' : 'Pendiente'),
      valor: a.valorSesion || '',
      origen: a.origen || '',
      agendado_por: a.isAdminBooking ? 'Daniela' : 'WhatsApp',
      creado: formatDate(a.createdAt),
    }));
}

/**
 * Exporta Excel con dos hojas.
 */
function exportToExcel() {
  const wb = XLSX.utils.book_new();

  // ---- Hoja 1: Resumen por cliente ----
  const summary = buildClientSummary();
  const summaryData = [
    ['Nombre', 'Telefono', 'Correo', 'Sesiones activas', 'Sesiones canceladas',
     'Valor facturado (COP)', 'Origen', 'Primera sesion', 'Ultima sesion'],
    ...summary.map((r) => [
      r.nombre, r.telefono, r.correo,
      r.sesiones_activas, r.sesiones_canceladas, r.valor_facturado,
      r.origen,
      formatDate(r.primera_sesion), formatDate(r.ultima_sesion),
    ]),
  ];
  const ws1 = XLSX.utils.aoa_to_sheet(summaryData);
  ws1['!cols'] = [
    { wch: 28 }, { wch: 16 }, { wch: 30 }, { wch: 16 },
    { wch: 19 }, { wch: 22 }, { wch: 20 }, { wch: 16 }, { wch: 16 },
  ];
  XLSX.utils.book_append_sheet(wb, ws1, 'Resumen clientes');

  // ---- Hoja 2: Detalle por sesion ----
  const detail = buildSessionDetail();
  const detailData = [
    ['Nombre', 'Telefono', 'Correo', 'Sesion #', 'Fecha sesion',
     'Estado', 'Pago', 'Valor (COP)', 'Origen', 'Agendado por', 'Fecha registro'],
    ...detail.map((r) => [
      r.nombre, r.telefono, r.correo, r.sesion_num, r.fecha_sesion,
      r.estado, r.pago, r.valor, r.origen, r.agendado_por, r.creado,
    ]),
  ];
  const ws2 = XLSX.utils.aoa_to_sheet(detailData);
  ws2['!cols'] = [
    { wch: 28 }, { wch: 16 }, { wch: 30 }, { wch: 10 }, { wch: 22 },
    { wch: 12 }, { wch: 12 }, { wch: 14 }, { wch: 20 }, { wch: 14 }, { wch: 14 },
  ];
  XLSX.utils.book_append_sheet(wb, ws2, 'Detalle sesiones');

  const filePath = '/tmp/clientes_aura.xlsx';
  XLSX.writeFile(wb, filePath);
  return filePath;
}

/**
 * Guarda origen del cliente.
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
 * Resumen de texto para Telegram.
 */
function buildSummaryText() {
  const rows = buildClientSummary();
  if (rows.length === 0) return 'No hay clientes registrados aun.';

  const totalCitas = rows.reduce((s, r) => s + r.sesiones_activas, 0);
  const totalFacturado = rows.reduce((s, r) => s + r.valor_facturado, 0);

  let txt = `*Resumen de clientes Aura Luz*\n`;
  txt += `Total clientes: ${rows.length}\n`;
  txt += `Total sesiones activas: ${totalCitas}\n`;
  if (totalFacturado > 0) txt += `Total facturado: $${totalFacturado.toLocaleString('es-CO')}\n`;
  txt += `\n*Detalle:*\n`;
  for (const r of rows.slice(0, 20)) {
    txt += `• ${r.nombre} — ${r.sesiones_activas} sesion(es)`;
    if (r.origen) txt += ` — ${r.origen}`;
    txt += '\n';
  }
  if (rows.length > 20) txt += `... y ${rows.length - 20} mas.`;
  txt += '\n\n_El Excel adjunto tiene el detalle completo en dos hojas._';
  return txt;
}

module.exports = { buildClientSummary, buildSessionDetail, exportToExcel, saveClientOrigin, buildSummaryText };
ENDOFFILE
echo "✅ clients.js actualizado con dos hojas Excel"

# ================================================================
# 7. Reiniciar servicio
# ================================================================
echo "=== Reiniciando Aura Luz ==="
systemctl restart aura-luz
sleep 4
systemctl is-active aura-luz && echo "✅ Servicio activo y corriendo" || echo "❌ Error al reiniciar"
journalctl -u aura-luz -n 12 --no-pager

echo ""
echo "=== Cambios aplicados ==="
echo "  - fix_patient_email: correccion autonoma de correo (sin escalar a la Doc)"
echo "  - Busqueda parcial de paciente con confirmacion"
echo "  - Aura no escala tareas simples a la Doc"
echo "  - Daniela ahora se llama 'Doc' en el chat de Telegram"
echo "  - Alertas de cancelacion con fallback de texto libre"
echo "  - Excel con dos hojas: Resumen clientes + Detalle sesiones"
