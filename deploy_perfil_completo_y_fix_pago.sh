#!/bin/bash
set -e

echo "==> Actualizando /root/aura-luz/src/aura/agent.js ..."
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
    // RED DE SEGURIDAD: nunca agendar sin correo Y celular.
    const emailOk = input.patient_email && /.+@.+\..+/.test(input.patient_email);
    const phoneOk = input.patient_phone && String(input.patient_phone).replace(/\D/g, '').length >= 7;
    if (!emailOk || !phoneOk) {
      const faltan = [];
      if (!emailOk) faltan.push('correo electrónico válido');
      if (!phoneOk) faltan.push('número de celular');
      return { error: 'NO_AGENDADO', motivo: 'Faltan datos obligatorios: ' + faltan.join(' y ') + '. Pídeselos antes de agendar.' };
    }

    // VALIDACIÓN DE FECHA (evita que el modelo invente fechas absurdas como años pasados).
    const startDate = new Date(input.start_iso);
    if (isNaN(startDate.getTime())) {
      return { error: 'FECHA_INVALIDA', motivo: 'La fecha no es válida. Llama a check_availability y usa EXACTAMENTE una de las franjas que te devuelve.' };
    }
    const ahora = new Date();
    if (startDate < ahora) {
      return { error: 'FECHA_EN_PASADO', motivo: 'Esa fecha ya pasó (' + startDate.toLocaleString('es-CO', { timeZone: config.timezone }) + '). NUNCA inventes fechas. Llama a check_availability primero y usa una franja real de las que te devuelve.' };
    }
    // No permitir agendar a más de 1 año de distancia (señal de error de cálculo del modelo)
    const unAnoAdelante = new Date(ahora.getTime() + 366 * 24 * 60 * 60 * 1000);
    if (startDate > unAnoAdelante) {
      return { error: 'FECHA_MUY_LEJANA', motivo: 'Esa fecha está demasiado lejos, seguramente calculaste mal. Llama a check_availability y usa una franja real.' };
    }

    // SINCRONIZAR CON OUTLOOK (fuente de verdad): limpiar del registro
    // las citas que ya no existen realmente en el calendario.
    const pKeyCheck = store.patientKeyFromRaw({ phone: input.patient_phone, email: input.patient_email, name: input.patient_name });
    await store.syncPatientWithCalendar(pKeyCheck, eventExists);

    // PROTECCIÓN ANTI-DUPLICADOS: si ya existe una cita activa idéntica
    // (mismo paciente + misma hora de inicio), no crear otra.
    const yaExiste = store.findAppointments({ phone: input.patient_phone, email: input.patient_email })
      .find((a) => a.start === input.start_iso);
    if (yaExiste) {
      return { error: 'YA_EXISTE', motivo: 'Ya hay una cita activa para ese paciente a esa hora (id ' + yaExiste.id + '). No la dupliques.', appointment_id: yaExiste.id, join_url: yaExiste.joinUrl };
    }

    // Número consecutivo de CITA de este paciente (solo activas, sin huecos).
    const pKey = store.patientKeyFromRaw({ phone: input.patient_phone, email: input.patient_email, name: input.patient_name });
    const visitNum = store.countActiveAppointmentsForPatient(pKey) + 1;

    // Perfil de cliente nuevo: solo si es su primera sesion y hay conversacion real por WhatsApp de la que sacar contexto.
    // Se construye la conversacion completa (paciente + Aura) para dar contexto, pero el resumen
    // solo debe describir la conducta del paciente, nunca la de Aura.
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

    // Asunto: si lo agenda Daniela (admin) es obligatorio incluir el "asunto".
    // Si es paciente por WhatsApp, va sin asunto.
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

    // Notificar a Daniela por Telegram cuando se agenda una sesion nueva
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
    // Sincronizar con Outlook antes de listar (no mostrar citas fantasma)
    const keySync = store.patientKeyFromRaw({ phone: input.phone, email: input.email, name: input.name });
    await store.syncPatientWithCalendar(keySync, eventExists);
    const found = store.findAppointments({
      name: input.name,
      email: input.email,
      phone: input.phone,
    });
    return {
      appointments: found.map((a) => ({
        appointment_id: a.id,
        name: a.name,
        email: a.email,
        phone: a.phone,
        start: a.start,
        subject: `Cita - DRGsoul`,
      })),
    };
  }

  if (name === 'cancel_appointment') {
    // Solo Daniela puede cancelar. Si no es admin, redirigir.
    if (ctx.restricted !== false) {
      return { error: 'SIN_PERMISO', motivo: 'Solo Daniela puede cancelar citas. Un paciente debe pedirlo y Daniela lo gestiona.' };
    }
    const appt = store.getAppointment(input.appointment_id);
    if (!appt) return { error: 'NO_ENCONTRADA', motivo: 'No encontré esa cita.' };
    try {
      if (appt.eventId) await cancelAppointment(appt.eventId);
      store.markAppointmentCancelled(input.appointment_id);

      // Renumerar las citas activas restantes de ese paciente (1,2,3... sin huecos)
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
      // Avisar al paciente por WhatsApp (si el canal está activo y hay celular)
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
      // 1. Cancelar la sesion anterior en Teams
      if (appt.eventId) await cancelAppointment(appt.eventId);
      store.markAppointmentCancelled(input.appointment_id);

      // 2. Crear la nueva sesion
      const pKey = store.patientKeyOf(appt);
      await store.syncPatientWithCalendar(pKey, eventExists);
      const visitNum = store.countActiveAppointmentsForPatient(pKey) + 1;

      let subject = `Sesion - DRGsoul # ${visitNum} - ${appt.name}`;
      if (appt.subjectNote) subject += ` - ${appt.subjectNote}`;

      const { eventId: newEventId, joinUrl: newJoinUrl } = await createTeamsAppointment({
        subject,
        startISO: input.new_start_iso,
        endISO: input.new_end_iso,
        attendeeEmail: appt.email,
        attendeeName: appt.name,
        bodyText: `Paciente: ${appt.name}\nMotivo: ${appt.reason || ''}`,
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
      const phone2 = String(appt.phone).replace(/\D/g, '');
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
          `Hola ${appt.name} 🌷 Te escribe Aura Luz. Tu sesion fue reagendada para el ${fechaHora} ✨ Aqui esta tu nuevo enlace: ${newJoinUrl || 'Te lo enviamos pronto'} 💛`
        );
      }

      // 4. Notificar a Daniela
      try {
        const { bot } = require('../telegram/bot');
        const chatId2 = config2.telegram.danielaChatId;
        await bot.sendMessage(chatId2,
          `✅ <b>Sesion reagendada</b>\n\n<b>Paciente:</b> ${appt.name}\n<b>Nueva sesion #:</b> ${visitNum}\n<b>Nueva fecha:</b> ${fechaHora}\n<b>Paciente notificado por WhatsApp</b> ✔️`,
          { parse_mode: 'HTML' }
        );
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

      let subject = `Sesion - DRGsoul # ${visitNum} - ${appt.name}`;
      if (appt.subjectNote) subject += ` - ${appt.subjectNote}`;

      const { eventId: newEventId, joinUrl: newJoinUrl } = await createTeamsAppointment({
        subject,
        startISO: appt.start,
        endISO: appt.end,
        attendeeEmail: newEmail,
        attendeeName: appt.name,
        bodyText: `Paciente: ${appt.name}\nMotivo: ${appt.reason || ''}`,
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
      const phone2 = String(appt.phone).replace(/\D/g, '');
      try {
        const { sendText } = require('../whatsapp/client');
        await sendText(phone2,
          `Listo ${appt.name.split(' ')[0]} 🌷 Tu correo fue corregido a ${newEmail} y tu sesion del ${fechaHora} sigue confirmada. Ya te enviamos la nueva invitacion de Teams a ese correo. Estamos contigo 💛`
        );
      } catch(e) {
        console.error('Error notificando paciente fix_email:', e.message);
      }

      // 6. Notificar a la Doc por Telegram (solo informando, sin pedirle nada)
      try {
        const { bot } = require('../telegram/bot');
        const chatId2 = config2.telegram.danielaChatId;
        await bot.sendMessage(chatId2,
          `✅ <b>Correo corregido automaticamente</b>\n\n<b>Paciente:</b> ${appt.name}\n<b>Correo anterior:</b> eliminado\n<b>Correo nuevo:</b> ${newEmail}\n<b>Sesion:</b> ${fechaHora}\n\nYa reagende la sesion y notifique al paciente por WhatsApp. No necesitas hacer nada.`,
          { parse_mode: 'HTML' }
        );
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
        model: MODEL,
        max_tokens: 1000,
        system: systemPrompt,
        tools: TOOLS,
        messages,
      });
    } catch (apiErr) {
      // Detectar saldo agotado y alertar a Daniela
      const errMsg = apiErr.message || (apiErr.error && apiErr.error.message) || String(apiErr);
      if (errMsg.includes('credit balance') || errMsg.includes('billing') || errMsg.includes('insufficient')) {
        console.error('[ALERTA] Saldo de Claude agotado:', errMsg);
        try {
          const { bot } = require('../telegram/bot');
          const chatId = require('../config').telegram.danielaChatId;
          await bot.sendMessage(chatId,
            '🚨 *ALERTA IMPORTANTE*\n\nEl saldo de la API de Claude se agoto. Aura Luz no puede responder a los pacientes hasta que se recargue.\n\nPor favor avisa a Jorge para que recargue en console.anthropic.com',
            { parse_mode: 'Markdown' }
          );
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
      toolResults.push({
        type: 'tool_result',
        tool_use_id: toolUse.id,
        content: JSON.stringify(result),
      });
    }
    messages.push({ role: 'user', content: toolResults });
  }

  return { finalText, messages };
}

async function handlePatientMessage(phone, userText, profileName, fromAudio = false) {
  if (fromAudio) userText = '[NOTA: este mensaje vino de un audio transcrito. NO aceptes correos de aquí; si hay un correo, pídelo por escrito.] ' + userText;
  const session = store.getSession(phone);
  let history = session.history || [];

  // "Frescura": si el paciente reaparece despues de mucho tiempo (24h),
  // arrancamos hilo nuevo para saludarlo de nuevo con calidez.
  const DAY = 24 * 60 * 60 * 1000;
  const lastAt = session.lastAt ? new Date(session.lastAt).getTime() : 0;
  if (lastAt && Date.now() - lastAt > DAY) {
    history = [];
  }

  history.push({ role: 'user', content: userText });

  const { finalText, messages } = await runAgent({
    systemPrompt: patientSystemPrompt(),
    history,
    ctx: { phone, profileName, restricted: true, history },
  });

  // Detectar origen del cliente en la conversacion (Instagram, referido, etc.)
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

async function handleAdminMessage(daniela_text, fromAudio = false) {
  if (fromAudio) daniela_text = '[NOTA: este mensaje vino de un audio transcrito. NO aceptes correos de aquí; si hay un correo, pídelo por escrito.] ' + daniela_text;
  // Daniela tambien tiene memoria persistente, con clave fija "admin:daniela".
  // Asi el hilo sobrevive reinicios del servicio.
  const KEY = 'admin:daniela';
  const session = store.getSession(KEY);
  let history = session.history || [];

  // "Frescura": si la ultima interaccion fue hace mas de 6 horas,
  // arrancamos hilo nuevo para no retomar algo viejo fuera de contexto.
  const SIX_HOURS = 6 * 60 * 60 * 1000;
  const lastAt = session.lastAt ? new Date(session.lastAt).getTime() : 0;
  if (lastAt && Date.now() - lastAt > SIX_HOURS) {
    history = [];
  }

  history.push({ role: 'user', content: daniela_text });

  const { finalText, messages } = await runAgent({
    systemPrompt: adminSystemPrompt(),
    history,
    ctx: { phone: null, restricted: false },
  });

  store.saveSession(KEY, {
    ...session,
    phone: KEY,
    history: messages,
    lastAt: new Date().toISOString(),
  });
  return finalText;
}

module.exports = { handlePatientMessage, handleAdminMessage };
EOF

echo "==> Actualizando /root/aura-luz/src/store.js ..."
cat > /root/aura-luz/src/store.js << 'EOF'
const fs = require('fs');
const path = require('path');

const DB_PATH = path.join(__dirname, '..', 'data', 'store.json');

function loadDB() {
  if (!fs.existsSync(DB_PATH)) {
    const initial = { sessions: {}, appointments: {} };
    fs.writeFileSync(DB_PATH, JSON.stringify(initial, null, 2));
    return initial;
  }
  return JSON.parse(fs.readFileSync(DB_PATH, 'utf-8'));
}

function saveDB(db) {
  fs.writeFileSync(DB_PATH, JSON.stringify(db, null, 2));
}

// ---- Sesiones de conversación (una por número de WhatsApp) ----
function getSession(phone) {
  const db = loadDB();
  return db.sessions[phone] || { phone, history: [], createdAt: new Date().toISOString() };
}

function saveSession(phone, session) {
  const db = loadDB();
  db.sessions[phone] = session;
  saveDB(db);
}

// ---- Citas ----
function createAppointment(appt) {
  const db = loadDB();
  db.appointments[appt.id] = { ...appt, paymentStatus: 'pendiente' };
  saveDB(db);
  return db.appointments[appt.id];
}

function getAppointment(id) {
  const db = loadDB();
  return db.appointments[id];
}

function getLatestAppointmentByPhone(phone) {
  const db = loadDB();
  const phoneClean = phone ? String(phone).replace(/\D/g, '') : '';
  const list = Object.values(db.appointments).filter((a) => {
    const ap = a.phone ? String(a.phone).replace(/\D/g, '') : '';
    return ap && phoneClean && ap === phoneClean;
  });
  return list.sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt))[0];
}

function updatePaymentStatus(id, status) {
  const db = loadDB();
  if (!db.appointments[id]) return null;
  db.appointments[id].paymentStatus = status; // 'validado' | 'rechazado'
  saveDB(db);
  return db.appointments[id];
}

// ---- Numeración de citas POR paciente (solo activas, sin huecos) ----
// Identificamos al paciente por su celular normalizado (o correo si no hay celular).
function patientKeyOf(appt) {
  const phone = appt.phone ? String(appt.phone).replace(/\D/g, '') : '';
  if (phone) return 'p:' + phone;
  if (appt.email) return 'e:' + appt.email.toLowerCase();
  return 'n:' + (appt.name || '').toLowerCase().trim();
}

function patientKeyFromRaw({ phone, email, name }) {
  const p = phone ? String(phone).replace(/\D/g, '') : '';
  if (p) return 'p:' + p;
  if (email) return 'e:' + email.toLowerCase();
  return 'n:' + (name || '').toLowerCase().trim();
}

// Cuenta cuántas citas ACTIVAS tiene ya un paciente (para asignar el siguiente número).
function countActiveAppointmentsForPatient(key) {
  const db = loadDB();
  return Object.values(db.appointments || {})
    .filter((a) => a.status !== 'cancelada' && patientKeyOf(a) === key)
    .length;
}

// Devuelve las citas activas de un paciente, ordenadas por fecha de creación
// (para renumerar 1,2,3... sin huecos).
function listActiveAppointmentsForPatient(key) {
  const db = loadDB();
  return Object.values(db.appointments || {})
    .filter((a) => a.status !== 'cancelada' && patientKeyOf(a) === key)
    .sort((a, b) => new Date(a.createdAt) - new Date(b.createdAt));
}

function setAppointmentNumber(id, num) {
  const db = loadDB();
  if (db.appointments[id]) {
    db.appointments[id].patientVisitNumber = num;
    saveDB(db);
  }
}

// ---- Buscar citas activas (para cancelar) ----
function findAppointments({ phone, email, name } = {}) {
  const db = loadDB();
  const all = Object.values(db.appointments || {});
  return all.filter((a) => {
    if (a.status === 'cancelada') return false;
    if (phone && a.phone && String(a.phone).replace(/\D/g,'').includes(String(phone).replace(/\D/g,''))) return true;
    if (email && a.email && a.email.toLowerCase() === String(email).toLowerCase()) return true;
    if (name && a.name && a.name.toLowerCase().includes(String(name).toLowerCase())) return true;
    return false;
  });
}

function markAppointmentCancelled(id) {
  const db = loadDB();
  if (db.appointments[id]) {
    db.appointments[id].status = 'cancelada';
    saveDB(db);
    return db.appointments[id];
  }
  return null;
}

// Sincroniza el registro con el calendario real de Outlook.
// Recibe una función async eventExists(eventId) y marca como canceladas
// las citas cuyo evento ya no existe en Outlook (fuente de verdad).
async function syncPatientWithCalendar(key, eventExistsFn) {
  const db = loadDB();
  const activas = Object.values(db.appointments || {})
    .filter((a) => a.status !== 'cancelada' && patientKeyOf(a) === key);
  let cambios = false;
  for (const a of activas) {
    const existe = await eventExistsFn(a.eventId);
    if (!existe) {
      db.appointments[a.id].status = 'cancelada';
      db.appointments[a.id].autoSynced = true; // marca que se limpió por sync
      cambios = true;
    }
  }
  if (cambios) saveDB(db);
  return cambios;
}


// Guarda el origen del cliente (Instagram, referido, etc.) en sus citas
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
  if (updated) saveDB(db);
}


// Actualiza el correo de todas las citas activas de un paciente
// Recibe el phone como identificador principal y el nuevo correo
function updatePatientEmail(phone, newEmail) {
  if (!phone || !newEmail) return 0;
  const db = loadDB();
  const phoneClean = String(phone).replace(/\D/g, '');
  let count = 0;
  for (const a of Object.values(db.appointments || {})) {
    const ap = a.phone ? String(a.phone).replace(/\D/g, '') : '';
    if (ap === phoneClean) {
      a.email = newEmail.toLowerCase().trim();
      count++;
    }
  }
  if (count > 0) saveDB(db);
  return count;
}

module.exports = {
  updatePatientEmail,
  saveClientOrigin,
  syncPatientWithCalendar,
  patientKeyOf,
  patientKeyFromRaw,
  countActiveAppointmentsForPatient,
  listActiveAppointmentsForPatient,
  setAppointmentNumber,
  findAppointments,
  markAppointmentCancelled,
  getSession,
  saveSession,
  createAppointment,
  getAppointment,
  getLatestAppointmentByPhone,
  updatePaymentStatus,
};
EOF

echo "==> Reiniciando aura-luz.service ..."
systemctl restart aura-luz

echo "==> Listo. Revisa logs con: journalctl -u aura-luz -f"
