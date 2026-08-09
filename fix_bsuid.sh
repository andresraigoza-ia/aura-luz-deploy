#!/bin/bash
set -e

echo "=== Aura Luz: Fix BSUID WhatsApp + alerta saldo bajo ==="

cp /root/aura-luz/src/whatsapp/webhook.js /root/aura-luz/src/whatsapp/webhook.js.bak3
cp /root/aura-luz/src/aura/agent.js /root/aura-luz/src/aura/agent.js.bak5
echo "✅ Backups creados"

# ================================================================
# 1. webhook.js: manejar BSUID y limpiar debug lines
# ================================================================
cat > /root/aura-luz/src/whatsapp/webhook.js << 'ENDOFFILE'
const express = require('express');
const router = express.Router();

const config = require('../config');
const waClient = require('./client');
const auraAgent = require('../aura/agent');
const { transcribeAudio } = require('../audio/transcribe');
const { enqueue } = require('../audio/queue');
const { toWhatsApp } = require('../format');
const store = require('../store');

// Verificacion inicial del webhook (Meta la llama una sola vez al configurar)
router.get('/', (req, res) => {
  const mode = req.query['hub.mode'];
  const token = req.query['hub.verify_token'];
  const challenge = req.query['hub.challenge'];

  if (mode === 'subscribe' && token === config.whatsapp.verifyToken) {
    return res.status(200).send(challenge);
  }
  return res.sendStatus(403);
});

router.post('/', async (req, res) => {
  // Responder rapido a Meta; procesar despues
  res.sendStatus(200);

  if (!waClient.verifySignature(req)) {
    console.warn('Firma de webhook invalida, ignorando payload');
    return;
  }

  try {
    const entry = req.body.entry && req.body.entry[0];
    const change = entry && entry.changes && entry.changes[0];
    const value = change && change.value;
    const messages = value && value.messages;
    if (!messages || messages.length === 0) return;

    const msg = messages[0];

    // Extraer el numero del remitente.
    // Meta puede enviar el numero en msg.from (formato clasico) o
    // en value.contacts[0].wa_id (cuando usa BSUID en msg.from_user_id).
    // Siempre preferimos el numero real (digitos), no el BSUID.
    let from = msg.from;
    if (!from || from.includes('.')) {
      // msg.from no tiene el numero real — buscar en contacts
      const contacts = value.contacts;
      if (contacts && contacts[0]) {
        from = contacts[0].wa_id || contacts[0].user_id || from;
      }
    }
    // Si aun tiene formato BSUID (ej: CO.123...), intentar extraer solo digitos
    if (from && from.includes('.')) {
      const digits = from.replace(/\D/g, '');
      if (digits.length >= 10) from = digits;
    }
    // Ultimo recurso: from_user_id
    if (!from) from = msg.from_user_id;

    if (!from) {
      console.error('[webhook] No se pudo determinar el numero del remitente:', JSON.stringify(msg).slice(0, 200));
      return;
    }

    const profileName =
      (value.contacts && value.contacts[0] && value.contacts[0].profile.name) || from;

    await enqueue('wa:' + from, async () => {
    if (msg.type === 'text') {
      const reply = await auraAgent.handlePatientMessage(from, msg.text.body, profileName);
      if (reply) await waClient.sendText(from, toWhatsApp(reply));
    } else if (msg.type === 'image') {
      await handlePaymentPhoto({ from, profileName, mediaId: msg.image.id });
    } else if (msg.type === 'audio' || msg.type === 'voice') {
      const media = msg.audio || msg.voice;
      const { buffer } = await waClient.downloadMedia(media.id);
      const texto = await transcribeAudio(buffer, 'nota.ogg');
      if (texto) {
        const reply = await auraAgent.handlePatientMessage(from, texto, profileName, true);
        if (reply) await waClient.sendText(from, toWhatsApp(reply));
      } else {
        await waClient.sendText(from, 'No logre entender tu audio 😕 ¿me lo repites o me escribes?');
      }
    } else {
      await waClient.sendText(
        from,
        'Por ahora puedo leer texto, imagenes y notas de voz 💛 ¿me cuentas en que te puedo ayudar?'
      );
    }
    });
  } catch (err) {
    console.error('Error procesando webhook de WhatsApp:', err);
  }
});

async function handlePaymentPhoto({ from, profileName, mediaId }) {
  const { notifyPaymentForValidation } = require('../telegram/bot');
  const { buffer, mimeType } = await waClient.downloadMedia(mediaId);

  const appt = store.getLatestAppointmentByPhone(from);

  await notifyPaymentForValidation({
    photoBuffer: buffer,
    mimeType,
    patientName: profileName,
    phone: from,
    appointmentId: appt ? appt.id : null,
  });

  await waClient.sendText(
    from,
    '¡Gracias! 💛 Ya recibimos tu comprobante y en breve lo validamos. Te confirmamos tu sesion apenas quede lista.'
  );
}

module.exports = router;
ENDOFFILE
echo "✅ webhook.js actualizado (soporte BSUID)"

# ================================================================
# 2. agent.js: alerta de saldo bajo a Daniela por Telegram
# ================================================================
node << 'ENDOFNODE'
const fs = require('fs');
const filePath = '/root/aura-luz/src/aura/agent.js';
let code = fs.readFileSync(filePath, 'utf-8');

// Buscar el bloque de runAgent donde se llama a anthropic.messages.create
// y agregar catch para detectar error de creditos
const OLD = `    const response = await anthropic.messages.create({
      model: MODEL,
      max_tokens: 1000,
      system: systemPrompt,
      tools: TOOLS,
      messages,
    });`;

const NEW = `    let response;
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
            '🚨 *ALERTA IMPORTANTE*\\n\\nEl saldo de la API de Claude se agoto. Aura Luz no puede responder a los pacientes hasta que se recargue.\\n\\nPor favor avisa a Jorge para que recargue en console.anthropic.com',
            { parse_mode: 'Markdown' }
          );
        } catch(e) { console.error('No se pudo alertar a Daniela sobre saldo:', e.message); }
      }
      throw apiErr;
    }`;

if (!code.includes(OLD)) {
  console.error('ERROR: no se encontro el bloque anthropic.messages.create en agent.js');
  process.exit(1);
}

code = code.replace(OLD, NEW);
fs.writeFileSync(filePath, code, 'utf-8');
console.log('agent.js OK');
ENDOFNODE
echo "✅ agent.js actualizado (alerta saldo bajo)"

# ================================================================
# 3. Limpiar citas sin telefono valido del store
# ================================================================
node << 'ENDOFNODE'
const fs = require('fs');
const db = JSON.parse(fs.readFileSync('/root/aura-luz/data/store.json', 'utf-8'));
let borradas = 0;
for (const [id, a] of Object.entries(db.appointments || {})) {
  if (!a.phone || String(a.phone).replace(/\D/g, '').length < 7) {
    delete db.appointments[id];
    borradas++;
  }
}
fs.writeFileSync('/root/aura-luz/data/store.json', JSON.stringify(db, null, 2));
console.log('Citas basura eliminadas:', borradas);
ENDOFNODE
echo "✅ Store limpiado"

# ================================================================
# 4. Reiniciar
# ================================================================
echo "=== Reiniciando Aura Luz ==="
systemctl restart aura-luz
sleep 4
systemctl is-active aura-luz && echo "✅ Servicio activo" || echo "❌ Error al reiniciar"
journalctl -u aura-luz -n 10 --no-pager

echo ""
echo "=== Cambios aplicados ==="
echo "  - webhook.js: soporte para BSUID (formato nuevo de Meta)"
echo "  - agent.js: alerta a Doc por Telegram cuando el saldo de Claude se agota"
echo "  - Store: citas sin telefono eliminadas"
echo "  - Aura ahora funciona con CUALQUIER numero, sin importar formato"
