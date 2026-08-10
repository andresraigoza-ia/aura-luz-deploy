#!/bin/bash
set -e
cd /root/aura-luz

echo "==> Paso 1: Agregando comando /estado en bot.js..."
node << 'JSEOF'
const fs = require('fs');
const f = './src/telegram/bot.js';
let c = fs.readFileSync(f, 'utf-8');

// Agregar comando /estado antes del module.exports
const statusCmd = `
bot.onText(/\\/estado/, async (msg) => {
  const chatId = String(msg.chat.id);
  const danielaId = String(config.telegram.danielaChatId);
  if (chatId !== danielaId) return;

  var report = '🔍 <b>Estado del sistema Aura Luz</b>\\n\\n';
  var alertas = [];

  // 1. Servicio Aura Luz
  report += '✅ <b>Servicio:</b> Activo (respondiendo)\\n';

  // 2. Claude API
  try {
    const Anthropic = require('@anthropic-ai/sdk');
    const anthropic = new Anthropic({ apiKey: config.anthropic.apiKey });
    await anthropic.messages.create({
      model: 'claude-sonnet-4-5',
      max_tokens: 10,
      messages: [{ role: 'user', content: 'test' }],
    });
    report += '✅ <b>Claude API:</b> Funcionando\\n';
  } catch(e) {
    var errMsg = e.message || '';
    if (errMsg.includes('credit') || errMsg.includes('billing') || errMsg.includes('insufficient')) {
      report += '🚨 <b>Claude API:</b> SIN SALDO\\n';
      alertas.push('Recargar saldo en console.anthropic.com');
    } else if (errMsg.includes('401') || errMsg.includes('authentication')) {
      report += '🚨 <b>Claude API:</b> API key invalida\\n';
      alertas.push('Revisar API key de Anthropic');
    } else {
      report += '⚠️ <b>Claude API:</b> Error - ' + errMsg.slice(0, 80) + '\\n';
    }
  }

  // 3. Microsoft Graph (Teams/Outlook)
  try {
    const { getGraphToken } = require('./graph/auth');
    await getGraphToken();
    report += '✅ <b>Teams/Outlook:</b> Conectado\\n';
  } catch(e) {
    report += '🚨 <b>Teams/Outlook:</b> Desconectado - ' + (e.message || '').slice(0, 60) + '\\n';
    alertas.push('Revisar credenciales de Microsoft Graph');
  }

  // 4. WhatsApp
  if (config.whatsapp.token && config.whatsapp.phoneNumberId) {
    try {
      const axios = require('axios');
      var waResp = await axios.get(
        'https://graph.facebook.com/v20.0/' + config.whatsapp.phoneNumberId,
        { headers: { Authorization: 'Bearer ' + config.whatsapp.token } }
      );
      report += '✅ <b>WhatsApp:</b> Conectado (' + (waResp.data.verified_name || 'activo') + ')\\n';
    } catch(e) {
      var status = e.response ? e.response.status : '';
      if (status === 401 || status === 190) {
        report += '🚨 <b>WhatsApp:</b> Token expirado\\n';
        alertas.push('Token de WhatsApp necesita renovacion');
      } else {
        report += '⚠️ <b>WhatsApp:</b> Error ' + status + '\\n';
      }
    }
  } else {
    report += '⚠️ <b>WhatsApp:</b> No configurado\\n';
  }

  // 5. Disco
  try {
    const { execSync } = require('child_process');
    var diskLine = execSync("df -h / | tail -1").toString().trim();
    var parts = diskLine.split(/\\s+/);
    var usePct = parseInt(parts[4]);
    if (usePct > 90) {
      report += '🚨 <b>Disco:</b> ' + parts[4] + ' usado\\n';
      alertas.push('Disco casi lleno');
    } else {
      report += '✅ <b>Disco:</b> ' + parts[4] + ' usado (' + parts[3] + ' libre)\\n';
    }
  } catch(e) {}

  // 6. Memoria
  try {
    const { execSync } = require('child_process');
    var memLine = execSync("free -m | grep Mem").toString().trim();
    var memParts = memLine.split(/\\s+/);
    var totalMem = parseInt(memParts[1]);
    var usedMem = parseInt(memParts[2]);
    var memPct = Math.round(usedMem / totalMem * 100);
    report += '✅ <b>Memoria:</b> ' + memPct + '% (' + usedMem + 'MB / ' + totalMem + 'MB)\\n';
  } catch(e) {}

  // Resumen de alertas
  if (alertas.length > 0) {
    report += '\\n⚠️ <b>Acciones necesarias:</b>\\n';
    alertas.forEach(function(a) { report += '• ' + a + '\\n'; });
  } else {
    report += '\\n💚 Todo en orden.';
  }

  await bot.sendMessage(chatId, report, { parse_mode: 'HTML' });
});
`;

c = c.replace(
  'module.exports = { bot, notifyPaymentForValidation };',
  statusCmd + '\nmodule.exports = { bot, notifyPaymentForValidation };'
);

fs.writeFileSync(f, c);
console.log('[OK] bot.js - comando /estado agregado');
JSEOF

echo "==> Paso 2: Agregando chequeo automatico al scheduler..."
node << 'JSEOF'
const fs = require('fs');
const f = './src/scheduler.js';
let c = fs.readFileSync(f, 'utf-8');

// Agregar funcion de health check
const healthCheck = `
// ----------------------------------------------------------------
// TAREA 4: Health check automatico (cada 5 min)
// Si algo critico falla, avisa a Daniela sin que nadie pregunte.
// ----------------------------------------------------------------
async function healthCheck() {
  var alertas = [];

  // 1. Claude API
  try {
    const Anthropic = require('@anthropic-ai/sdk');
    const anthropic = new Anthropic({ apiKey: config.anthropic.apiKey });
    await anthropic.messages.create({
      model: 'claude-sonnet-4-5',
      max_tokens: 10,
      messages: [{ role: 'user', content: 'ok' }],
    });
  } catch(e) {
    var errMsg = e.message || '';
    if (errMsg.includes('credit') || errMsg.includes('billing') || errMsg.includes('insufficient')) {
      alertas.push('🚨 El saldo de Claude se agoto. Aura no puede responder a los pacientes.');
    }
  }

  // 2. Microsoft Graph
  try {
    const { getGraphToken } = require('./graph/auth');
    await getGraphToken();
  } catch(e) {
    alertas.push('🚨 La conexion con Teams/Outlook fallo. Las citas no se pueden crear.');
  }

  // 3. Disco
  try {
    const { execSync } = require('child_process');
    var diskLine = execSync("df -h / | tail -1").toString().trim();
    var usePct = parseInt(diskLine.split(/\\s+/)[4]);
    if (usePct > 90) {
      alertas.push('🚨 El disco del servidor esta al ' + usePct + '%. Puede dejar de funcionar.');
    }
  } catch(e) {}

  // Solo alertar si hay problemas (no molestar si todo esta bien)
  // Y solo alertar una vez cada 30 min para no spamear
  if (alertas.length > 0) {
    var db2 = loadDB();
    var lastAlert = db2._lastHealthAlert ? new Date(db2._lastHealthAlert).getTime() : 0;
    if (Date.now() - lastAlert > 30 * 60 * 1000) {
      try {
        var { bot } = require('./telegram/bot');
        var chatId = config.telegram.danielaChatId;
        var msg = '⚠️ <b>ALERTA AUTOMATICA Aura Luz</b>\\n\\n' + alertas.join('\\n') + '\\n\\nPor favor avisa a Jorge.';
        await bot.sendMessage(chatId, msg, { parse_mode: 'HTML' });
        db2._lastHealthAlert = new Date().toISOString();
        saveDB(db2);
      } catch(e) {
        console.error('[scheduler] No se pudo enviar alerta:', e.message);
      }
    }
  }
}
`;

// Insertar antes de startScheduler
c = c.replace(
  'function startScheduler() {',
  healthCheck + '\nfunction startScheduler() {'
);

// Agregar al scheduler
c = c.replace(
  "  setTimeout(() => {",
  "  scheduleInterval(5, healthCheck, 'Health check automatico');\n\n  setTimeout(() => {"
);

fs.writeFileSync(f, c);
console.log('[OK] scheduler.js - health check cada 5 min');
JSEOF

echo "==> Paso 3: Reiniciando..."
systemctl restart aura-luz
sleep 2
journalctl -u aura-luz -n 8 --no-pager
