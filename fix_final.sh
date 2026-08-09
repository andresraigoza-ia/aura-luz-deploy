#!/bin/bash
set -e

echo "=== Aura Luz: Fix final (origen, notificacion, sesion, reagendamiento) ==="

# ---- Backups ----
cp /root/aura-luz/src/aura/agent.js /root/aura-luz/src/aura/agent.js.bak3
cp /root/aura-luz/src/aura/tools.js /root/aura-luz/src/aura/tools.js.bak2
cp /root/aura-luz/src/aura/persona.js /root/aura-luz/src/aura/persona.js.bak2
cp /root/aura-luz/src/whatsapp/templates.js /root/aura-luz/src/whatsapp/templates.js.bak
cp /root/aura-luz/src/telegram/bot.js /root/aura-luz/src/telegram/bot.js.bak2
echo "✅ Backups creados"

# ================================================================
# 1. templates.js: agregar confirmacion_sesion
# ================================================================
cat >> /root/aura-luz/src/whatsapp/templates.js << 'ENDOFFILE'

/**
 * Confirmacion de nueva sesion agendada (usado en reagendamiento).
 * @param {string} to        Numero del paciente
 * @param {string} nombre    Nombre del paciente
 * @param {string} fechaHora Ej: "viernes 15 de agosto a las 2:00 p.m."
 * @param {string} linkTeams Link de la reunion de Teams
 */
async function sendConfirmacionSesion(to, nombre, fechaHora, linkTeams) {
  return sendTemplate(to, 'confirmacion_sesion', LANG, [
    bodyParams(nombre, fechaHora, linkTeams || 'Sin enlace disponible'),
  ]);
}

module.exports = {
  ...module.exports,
  sendConfirmacionSesion,
};
ENDOFFILE
echo "✅ templates.js actualizado con confirmacion_sesion"

# ================================================================
# 2. tools.js: agregar herramienta reschedule_appointment
# ================================================================
node << 'ENDOFNODE'
const fs = require('fs');
const filePath = '/root/aura-luz/src/aura/tools.js';
let code = fs.readFileSync(filePath, 'utf-8');

const newTool = `
  {
    name: 'reschedule_appointment',
    description:
      'Reagenda (mueve) una sesion existente a una nueva fecha y hora. SOLO Daniela puede usarlo. Flujo: 1) busca la sesion actual con find_appointments, 2) consulta disponibilidad con check_availability para el rango pedido, 3) muestra resumen con la sesion actual y la nueva propuesta y pregunta confirmacion, 4) solo con el si de Daniela llama a esta herramienta. Cancela la sesion anterior y crea una nueva, avisando al paciente por WhatsApp.',
    input_schema: {
      type: 'object',
      properties: {
        appointment_id: { type: 'string', description: 'ID de la sesion a cancelar (de find_appointments)' },
        new_start_iso: { type: 'string', description: 'Nueva fecha/hora de inicio (de check_availability)' },
        new_end_iso: { type: 'string', description: 'Nueva fecha/hora de fin (de check_availability)' },
      },
      required: ['appointment_id', 'new_start_iso', 'new_end_iso'],
    },
  },
`;

// Insertar antes del cierre del array TOOLS
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
console.log('tools.js OK');
ENDOFNODE
echo "✅ tools.js actualizado con reschedule_appointment"

# ================================================================
# 3. agent.js: implementar reschedule_appointment, origen automatico,
#    notificacion a Daniela al agendar, y cambio Cita -> Sesion
# ================================================================
node << 'ENDOFNODE'
const fs = require('fs');
const filePath = '/root/aura-luz/src/aura/agent.js';
let code = fs.readFileSync(filePath, 'utf-8');

// ---- 3a. Cambiar "Cita - DRGsoul" por "Sesion - DRGsoul" en los subjects ----
code = code.replace(/`Cita - DRGsoul # \$\{visitNum\} - \$\{input\.patient_name\}`/g,
  '`Sesion - DRGsoul # ${visitNum} - ${input.patient_name}`');
code = code.replace(/let subject = `Cita - DRGsoul # \$\{visitNum\} - \$\{input\.patient_name\}`;/g,
  'let subject = `Sesion - DRGsoul # ${visitNum} - ${input.patient_name}`;');
code = code.replace(/`Cita - DRGsoul # \$\{nuevoNum\} - \$\{r\.name\}`/g,
  '`Sesion - DRGsoul # ${nuevoNum} - ${r.name}`');

// ---- 3b. Notificacion a Daniela al crear una sesion ----
const OLD_CREATE_RETURN = `    return { appointment_id: appt.id, join_url: joinUrl, visit_number: visitNum };
  }

  if (name === 'send_payment_instructions')`;

const NEW_CREATE_RETURN = `    // Notificar a Daniela por Telegram cuando se agenda una sesion nueva
    try {
      const { bot } = require('../telegram/bot');
      const chatId = require('../config').telegram.danielaChatId;
      const startLabel = new Date(input.start_iso).toLocaleString('es-CO', {
        weekday: 'long', day: 'numeric', month: 'long',
        hour: 'numeric', minute: '2-digit', hour12: true,
        timeZone: require('../config').timezone,
      });
      await bot.sendMessage(chatId,
        \`✅ <b>Nueva sesion agendada</b>\\n\\n<b>Paciente:</b> \${input.patient_name}\\n<b>Sesion #:</b> \${visitNum}\\n<b>Fecha:</b> \${startLabel}\\n<b>Link:</b> \${joinUrl || 'No disponible'}\`,
        { parse_mode: 'HTML' }
      );
    } catch (e) {
      console.error('No se pudo notificar a Daniela de la nueva sesion:', e.message);
    }

    return { appointment_id: appt.id, join_url: joinUrl, visit_number: visitNum };
  }

  if (name === 'send_payment_instructions')`;

if (!code.includes(OLD_CREATE_RETURN)) {
  console.error('ERROR: no se encontro el bloque de return create_appointment');
  process.exit(1);
}
code = code.replace(OLD_CREATE_RETURN, NEW_CREATE_RETURN);

// ---- 3c. Origen automatico: detectar en la conversacion ----
// Inyectar deteccion de origen despues de guardar la sesion en handlePatientMessage
const OLD_SAVE_SESSION = `  store.saveSession(phone, {
    ...session,
    phone,
    history: messages,
    lastAt: new Date().toISOString(),
  });
  return finalText;
}

async function handleAdminMessage`;

const NEW_SAVE_SESSION = `  // Detectar origen del cliente en la conversacion (Instagram, referido, etc.)
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
    history: messages,
    lastAt: new Date().toISOString(),
  });
  return finalText;
}

async function handleAdminMessage`;

if (!code.includes(OLD_SAVE_SESSION)) {
  console.error('ERROR: no se encontro el bloque saveSession en handlePatientMessage');
  process.exit(1);
}
code = code.replace(OLD_SAVE_SESSION, NEW_SAVE_SESSION);

// ---- 3d. Implementar reschedule_appointment ----
const OLD_UNKNOWN = `  return { error: \`Herramienta desconocida: \${name}\` };
}`;

const NEW_RESCHEDULE = `  if (name === 'reschedule_appointment') {
    if (ctx.restricted !== false) {
      return { error: 'SIN_PERMISO', motivo: 'Solo Daniela puede reagendar sesiones.' };
    }
    const appt = store.getAppointment(input.appointment_id);
    if (!appt) return { error: 'NO_ENCONTRADA', motivo: 'No encontre esa sesion.' };

    try {
      // 1. Cancelar la sesion anterior en Teams
      if (appt.eventId) await cancelAppointment(appt.eventId);
      store.markAppointmentCancelled(input.appointment_id);

      // 2. Crear la nueva sesion
      const pKey = store.patientKeyOf(appt);
      await store.syncPatientWithCalendar(pKey, eventExists);
      const visitNum = store.countActiveAppointmentsForPatient(pKey) + 1;

      let subject = \`Sesion - DRGsoul # \${visitNum} - \${appt.name}\`;
      if (appt.subjectNote) subject += \` - \${appt.subjectNote}\`;

      const { eventId: newEventId, joinUrl: newJoinUrl } = await createTeamsAppointment({
        subject,
        startISO: input.new_start_iso,
        endISO: input.new_end_iso,
        attendeeEmail: appt.email,
        attendeeName: appt.name,
        bodyText: \`Paciente: \${appt.name}\\nMotivo: \${appt.reason || ''}\`,
      });

      const newAppt = store.createAppointment({
        id: require('uuid').v4 ? require('uuid').v4() : String(Date.now()),
        eventId: newEventId,
        joinUrl: newJoinUrl,
        phone: appt.phone,
        name: appt.name,
        email: appt.email,
        reason: appt.reason,
        start: input.new_start_iso,
        end: input.new_end_iso,
        patientVisitNumber: visitNum,
        subjectNote: appt.subjectNote || null,
        isAdminBooking: true,
        origen: appt.origen || null,
        createdAt: new Date().toISOString(),
      });

      // 3. Avisar al paciente por WhatsApp
      const templates = require('../whatsapp/templates');
      const config2 = require('../config');
      const phone2 = String(appt.phone).replace(/\\D/g, '');
      const fechaHora = new Date(input.new_start_iso).toLocaleString('es-CO', {
        weekday: 'long', day: 'numeric', month: 'long',
        hour: 'numeric', minute: '2-digit', hour12: true,
        timeZone: config2.timezone,
      });

      try {
        await templates.sendConfirmacionSesion(phone2, appt.name, fechaHora, newJoinUrl);
      } catch(e) {
        // Si la plantilla aun no esta aprobada, enviar texto libre
        const { sendText } = require('../whatsapp/client');
        await sendText(phone2,
          \`Hola \${appt.name} 🌷 Te escribe Aura Luz. Tu sesion fue reagendada para el \${fechaHora} ✨ Aqui esta tu nuevo enlace: \${newJoinUrl || 'Te lo enviamos pronto'} 💛\`
        );
      }

      // 4. Notificar a Daniela
      try {
        const { bot } = require('../telegram/bot');
        const chatId2 = config2.telegram.danielaChatId;
        await bot.sendMessage(chatId2,
          \`✅ <b>Sesion reagendada</b>\\n\\n<b>Paciente:</b> \${appt.name}\\n<b>Nueva sesion #:</b> \${visitNum}\\n<b>Nueva fecha:</b> \${fechaHora}\\n<b>Paciente notificado por WhatsApp</b> ✔️\`,
          { parse_mode: 'HTML' }
        );
      } catch(e) {}

      return { reagendado: true, nuevo_appointment_id: newAppt.id, nuevo_join_url: newJoinUrl, visit_number: visitNum };
    } catch(e) {
      return { error: 'FALLO_REAGENDAR', motivo: e.message };
    }
  }

  return { error: \`Herramienta desconocida: \${name}\` };
}`;

if (!code.includes(OLD_UNKNOWN)) {
  console.error('ERROR: no se encontro el bloque herramienta desconocida');
  process.exit(1);
}
code = code.replace(OLD_UNKNOWN, NEW_RESCHEDULE);

fs.writeFileSync(filePath, code, 'utf-8');
console.log('agent.js OK');
ENDOFNODE
echo "✅ agent.js actualizado"

# ================================================================
# 4. persona.js: agregar instrucciones de reagendamiento para Daniela
#    y cambiar "cita" por "sesion" en el prompt del admin
# ================================================================
node << 'ENDOFNODE'
const fs = require('fs');
const filePath = '/root/aura-luz/src/aura/persona.js';
let code = fs.readFileSync(filePath, 'utf-8');

// Cambiar "cita" por "sesion" en menciones clave del prompt de pacientes
code = code.replace(/Numero de cita: #1/g, 'Numero de sesion: #1');
code = code.replace(/numero de cita en el resumen/g, 'numero de sesion en el resumen');
code = code.replace(/"Confirmo y agendo tu cita\?"/g, '"Confirmo y agendo tu sesion?"');
code = code.replace(/resumen claro con el numero de cita/g, 'resumen claro con el numero de sesion');

// Agregar instruccion de reagendamiento en el prompt admin
const OLD_CANCEL = `CANCELAR CITAS (Daniela SI puede):
- Si Daniela pide cancelar la cita de alguien, usa find_appointments para ubicarla, muestrale cual es, y al confirmar usa cancel_appointment con el appointment_id.
- Tras cancelar, el paciente sera avisado automaticamente por WhatsApp. Confirma a Daniela que quedo hecho.`;

const NEW_CANCEL = `CANCELAR SESIONES (Daniela SI puede):
- Si Daniela pide cancelar la sesion de alguien, usa find_appointments para ubicarla, muestrale cual es, y al confirmar usa cancel_appointment con el appointment_id.
- Tras cancelar, el paciente sera avisado automaticamente por WhatsApp. Confirma a Daniela que quedo hecho.

REAGENDAR SESIONES (mover una sesion a otra fecha):
- Cuando Daniela diga "mueve la sesion de X al viernes" o similar, sigue este flujo OBLIGATORIO:
  1. Usa find_appointments para encontrar la sesion actual del paciente.
  2. Usa check_availability con from_date y/o time_preference segun lo que pida Daniela, para encontrar franjas disponibles en el rango pedido.
  3. Muestra un resumen claro: "Voy a cancelar la sesion del [fecha actual] y crear una nueva el [fecha nueva] a las [hora]. Confirmo?"
  4. SOLO con el "si" de Daniela llama a reschedule_appointment pasando el appointment_id de la sesion actual y el new_start_iso/new_end_iso de la franja nueva.
  5. El sistema cancela la sesion vieja, crea la nueva y avisa al paciente por WhatsApp automaticamente.
- Si no hay disponibilidad en el rango pedido, avisale a Daniela y ofrecele otras opciones.`;

if (!code.includes(OLD_CANCEL)) {
  console.error('ERROR: no se encontro el bloque CANCELAR en adminSystemPrompt');
  process.exit(1);
}
code = code.replace(OLD_CANCEL, NEW_CANCEL);

fs.writeFileSync(filePath, code, 'utf-8');
console.log('persona.js OK');
ENDOFNODE
echo "✅ persona.js actualizado"

# ================================================================
# 5. Cambiar "Cita" por "Sesion" en mensajes del bot de Telegram
# ================================================================
node << 'ENDOFNODE'
const fs = require('fs');
const filePath = '/root/aura-luz/src/telegram/bot.js';
let code = fs.readFileSync(filePath, 'utf-8');

code = code.replace(/Tu cita quedó confirmada/g, 'Tu sesion quedo confirmada');
code = code.replace(/tu cita fue cancelada/g, 'tu sesion fue cancelada');
code = code.replace(/Cita - DRGsoul/g, 'Sesion - DRGsoul');

fs.writeFileSync(filePath, code, 'utf-8');
console.log('bot.js OK');
ENDOFNODE
echo "✅ bot.js actualizado (Cita -> Sesion)"

# ================================================================
# 6. Cambiar "cita" por "sesion" en whatsapp/webhook.js
# ================================================================
node << 'ENDOFNODE'
const fs = require('fs');
const filePath = '/root/aura-luz/src/whatsapp/webhook.js';
let code = fs.readFileSync(filePath, 'utf-8');

code = code.replace(/Tu cita quedó lista/g, 'Tu sesion quedo lista');
code = code.replace(/confirmar tu cita/g, 'confirmar tu sesion');

fs.writeFileSync(filePath, code, 'utf-8');
console.log('webhook.js OK');
ENDOFNODE
echo "✅ webhook.js actualizado"

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
echo "  - Plantilla confirmacion_sesion agregada a templates.js"
echo "  - Herramienta reschedule_appointment implementada en agent.js"
echo "  - Origen automatico del cliente detectado en conversacion"
echo "  - Notificacion a Daniela por Telegram al agendar una sesion"
echo "  - 'Cita' cambiado por 'Sesion' en mensajes, prompts y subjects de Teams"
echo "  - Instrucciones de reagendamiento agregadas al prompt de Daniela"
