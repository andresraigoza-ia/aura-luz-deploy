#!/bin/bash
set -e
echo "==> Reescribiendo bot.js completo..."
cat > /root/aura-luz/src/telegram/bot.js << 'EOF'
const TelegramBot = require('node-telegram-bot-api');
const config = require('../config');
const store = require('../store');
const waClient = require('../whatsapp/client');
const auraAgent = require('../aura/agent');
const { processExcelBuffer } = require('../scheduling/bulkImport');
const { transcribeAudio } = require('../audio/transcribe');
const { enqueue } = require('../audio/queue');
const { toTelegramHTML } = require('../format');
const axios = require('axios');

const bot = new TelegramBot(config.telegram.token, { polling: true });

function isDaniela(chatId) {
  return String(chatId) === String(config.telegram.danielaChatId);
}

async function notifyPaymentForValidation({ photoBuffer, patientName, phone, appointmentId }) {
  await bot.sendPhoto(config.telegram.danielaChatId, photoBuffer, {
    caption: `💳 Comprobante de *${patientName}* (${phone})\n\n¿Confirmas que el pago sí llegó a tu cuenta?`,
    parse_mode: 'Markdown',
    reply_markup: {
      inline_keyboard: [
        [
          { text: '✅ Sí, validar', callback_data: `pay_ok:${appointmentId}:${phone}` },
          { text: '❌ No, rechazar', callback_data: `pay_no:${appointmentId}:${phone}` },
        ],
      ],
    },
  });
}

bot.on('callback_query', async (query) => {
  if (!isDaniela(query.message.chat.id)) return;

  const data = query.data;
  const parts = data.split(':');
  const action = parts[0];

  // ---- Validacion de pago ----
  if (action === 'pay_ok' || action === 'pay_no') {
    const appointmentId = parts[1];
    const phone = parts[2];

    if (action === 'pay_ok') {
      if (appointmentId && appointmentId !== 'null') store.updatePaymentStatus(appointmentId, 'validado');
      await waClient.sendText(phone, '¡Tu pago fue validado! 🎉 Tu sesion quedo confirmada. Nos vemos pronto 💛');
      store.logOutboundMessage(phone, '¡Tu pago fue validado! 🎉 Tu sesion quedo confirmada. Nos vemos pronto 💛');
      await bot.answerCallbackQuery(query.id, { text: 'Pago validado y paciente notificado ✅' });
    } else {
      if (appointmentId && appointmentId !== 'null') store.updatePaymentStatus(appointmentId, 'rechazado');
      await waClient.sendText(phone, 'Hola 💛 Revisamos el comprobante y no logramos verificar el pago. ¿Nos ayudas enviándolo de nuevo o con otro comprobante?');
      store.logOutboundMessage(phone, 'Hola 💛 Revisamos el comprobante y no logramos verificar el pago. ¿Nos ayudas enviándolo de nuevo o con otro comprobante?');
      await bot.answerCallbackQuery(query.id, { text: 'Paciente notificado del rechazo' });
    }

    await bot.editMessageReplyMarkup(
      { inline_keyboard: [] },
      { chat_id: query.message.chat.id, message_id: query.message.message_id }
    );
    return;
  }

  // ---- Aprobacion/rechazo de cita presencial ----
  if (action === 'pres_ok' || action === 'pres_no') {
    const reqId = parts[1];
    const pending = store.getPendingRequest(reqId);
    if (!pending) {
      await bot.answerCallbackQuery(query.id, { text: 'Solicitud no encontrada o ya procesada' });
      return;
    }

    if (action === 'pres_ok') {
      try {
        const { createTeamsAppointment } = require('../graph/calendar');
        const pKey = store.patientKeyFromRaw({ phone: pending.patientPhone, email: pending.patientEmail, name: pending.patientName });
        const visitNum = store.countActiveAppointmentsForPatient(pKey) + 1;
        const subject = 'Sesion - DRGsoul # ' + visitNum + ' - ' + pending.patientName;

        const { eventId, joinUrl } = await createTeamsAppointment({
          subject,
          startISO: pending.startISO,
          endISO: pending.endISO,
          attendeeEmail: pending.patientEmail,
          attendeeName: pending.patientName,
          bodyText: 'Paciente: ' + pending.patientName + '\nMotivo: ' + (pending.reason || ''),
          presencial: true,
        });

        store.createAppointment({
          id: require('uuid').v4(),
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

        var phone2 = String(pending.patientPhone).replace(/\D/g, '');
        var fechaHora = new Date(pending.startISO).toLocaleString('es-CO', {
          weekday: 'long', day: 'numeric', month: 'long',
          hour: 'numeric', minute: '2-digit', hour12: true,
          timeZone: config.timezone,
        });
        var valor = (pending.sessionValue || 0).toLocaleString('es-CO');

        var confirmMsg = '¡Listo, ' + pending.patientName.split(' ')[0] + '! Tu sesion presencial esta agendada 🌷\n\n' +
          '*Numero de sesion:* #' + visitNum + '\n' +
          '*Fecha y hora:* ' + fechaHora + '\n' +
          '*Modalidad:* Presencial\n' +
          '*Valor:* $' + valor + '\n\n' +
          'Aqui esta el link de Teams por si en algun momento lo necesitan como respaldo:\n' + (joinUrl || '') + '\n\n' +
          'Recuerda que el pago debe estar hecho antes de la sesion. Puedes hacerlo a:\n' +
          '🏦 Bancolombia (ahorros): 91200736520\n' +
          '📲 Nequi: 316 447 6243\n' +
          '⚡ Bre-B (llave celular): 316 447 6243\n' +
          'A nombre de Daniela Rodriguez Gallego.\n\n' +
          'Cuando hagas el pago, me compartes el comprobante 💛';

        await waClient.sendText(phone2, confirmMsg);
        store.logOutboundMessage(phone2, confirmMsg);

        await bot.answerCallbackQuery(query.id, { text: 'Presencial aprobada y paciente notificado ✅' });
        await bot.sendMessage(query.message.chat.id,
          '✅ <b>Cita presencial creada</b>\n\n<b>Paciente:</b> ' + pending.patientName + '\n<b>Sesion #:</b> ' + visitNum + '\n<b>Fecha:</b> ' + fechaHora + '\n<b>Paciente notificado por WhatsApp</b> ✔️',
          { parse_mode: 'HTML' });
      } catch(e) {
        console.error('[bot] Error creando cita presencial:', e.message);
        await bot.answerCallbackQuery(query.id, { text: 'Error: ' + e.message });
      }
    } else {
      var phone3 = String(pending.patientPhone).replace(/\D/g, '');
      var rechazoMsg = 'Hola ' + pending.patientName.split(' ')[0] + ' 🌷 Te cuento que por el momento la Dra. Daniela no tiene disponibilidad presencial para esa fecha. Tu sesion puede ser igual de cercana y efectiva por Teams. ¿Te gustaria que la agendemos asi? 💛';
      await waClient.sendText(phone3, rechazoMsg);
      store.logOutboundMessage(phone3, rechazoMsg);
      await bot.answerCallbackQuery(query.id, { text: 'Paciente informado — solo virtual' });
    }

    store.deletePendingRequest(reqId);
    await bot.editMessageReplyMarkup(
      { inline_keyboard: [] },
      { chat_id: query.message.chat.id, message_id: query.message.message_id }
    );
    return;
  }
});

bot.on('document', async (msg) => {
  if (!isDaniela(msg.chat.id)) return;

  const fileName = msg.document.file_name || '';
  if (!/\.xlsx?$/i.test(fileName)) {
    return bot.sendMessage(msg.chat.id, 'Ese archivo no parece un Excel (.xlsx/.xls) 🤔');
  }

  await bot.sendMessage(msg.chat.id, `Recibido "${fileName}" 📄 Agendando citas, dame un momento...`);

  try {
    const fileLink = await bot.getFileLink(msg.document.file_id);
    const { data } = await axios.get(fileLink, { responseType: 'arraybuffer' });
    const result = await processExcelBuffer(Buffer.from(data));
    const okCount = result.ok.length;
    const errCount = result.errors.length;
    let summary = `Listo ✅ ${okCount} citas creadas y confirmadas por WhatsApp.`;
    if (errCount > 0) {
      summary += `\n⚠️ ${errCount} filas con problemas:\n`;
      summary += result.errors.map((e) => `- ${e.row}: ${e.reason}`).join('\n');
    }
    await bot.sendMessage(msg.chat.id, summary);
  } catch (err) {
    console.error('Error procesando Excel:', err);
    await bot.sendMessage(msg.chat.id, 'Tuve un problema procesando ese Excel 😕 ¿revisamos las columnas?');
  }
});

async function downloadTelegramFile(fileId) {
  const link = await bot.getFileLink(fileId);
  const { data } = await axios.get(link, { responseType: 'arraybuffer' });
  return Buffer.from(data);
}

bot.on('message', async (msg) => {
  if (!isDaniela(msg.chat.id)) return;
  if (msg.document || msg.photo) return;

  await enqueue('tg:' + msg.chat.id, async () => {
    let texto = null;
    let vinoDeAudio = false;

    if (msg.voice || msg.audio) {
      vinoDeAudio = true;
      const fileId = (msg.voice || msg.audio).file_id;
      try {
        const buffer = await downloadTelegramFile(fileId);
        texto = await transcribeAudio(buffer, 'nota.ogg');
      } catch (e) {
        console.error('Error con audio de Telegram:', e.message);
      }
      if (!texto) {
        await bot.sendMessage(msg.chat.id, 'No logré entender el audio 😕 ¿me lo repites o lo escribes?');
        return;
      }
    } else if (msg.text && !msg.text.startsWith('/')) {
      texto = msg.text;
    } else {
      return;
    }

    const reply = await auraAgent.handleAdminMessage(texto, vinoDeAudio);
    if (reply) await bot.sendMessage(msg.chat.id, toTelegramHTML(reply), { parse_mode: 'HTML' });
  });
});

bot.onText(/\/start/, (msg) => {
  bot.sendMessage(msg.chat.id, `Hola Daniela, soy Aura Luz 💛 Tu chat_id es: ${msg.chat.id}\n(Guárdalo en TELEGRAM_DANIELA_CHAT_ID)`);
});

bot.onText(/\/clientes/, async (msg) => {
  const chatId = String(msg.chat.id);
  const danielaId = String(config.telegram.danielaChatId);
  if (chatId !== danielaId) return;

  try {
    const { exportToExcel, buildSummaryText } = require('../clients');
    const resumen = await buildSummaryText();
    await bot.sendMessage(chatId, resumen, { parse_mode: 'Markdown' });
    const filePath = await exportToExcel();
    await bot.sendDocument(chatId, filePath, {}, { filename: 'clientes_aura.xlsx', contentType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' });
  } catch (e) {
    console.error('[bot] Error /clientes:', e.message);
    await bot.sendMessage(chatId, 'Hubo un error generando el reporte de clientes. Intenta de nuevo.');
  }
});

module.exports = { bot, notifyPaymentForValidation };
EOF

echo "==> Reiniciando..."
systemctl restart aura-luz
sleep 2
journalctl -u aura-luz -n 5 --no-pager
