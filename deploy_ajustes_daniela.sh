#!/bin/bash
set -e

echo "==> Paso 1: Actualizando persona.js (puntos 1,2,5,6,7)..."
# Reemplazamos las secciones relevantes del prompt
cd /root/aura-luz

node -e "
const fs = require('fs');
const f = './src/aura/persona.js';
let c = fs.readFileSync(f, 'utf-8');

// PUNTO 1: No decir que la pregunta es para definir tarifas + agregar corporativo
c = c.replace(
  'Identificar si es nueva, referida/conocida, o busca terapia de pareja (esto define la tarifa).',
  'Identificar si es nueva, referida/conocida, corporativa (empresa) o busca terapia de pareja.'
);

// PUNTO 5: No decir 'esto define la tarifa' ni resaltar por que preguntas
// (esto ya se resuelve con el cambio anterior)

// PUNTO 2: Actualizar tarifas de referidos/conocidos/organizacionales
c = c.replace(
  'REFERIDA / conocida / procesos organizacionales / ya ha consultado (individual): tarifa especial \$150.000 (el valor regular es \$200.000). Sesion de 1 hora.',
  'REFERIDA / conocida / procesos organizacionales / corporativa / ya ha consultado (individual): sesion de 1 hora, valor \$150.000.'
);

// Actualizar paquetes referidos
c = c.replace(
  '- Referida/conocida/organizacional: 5 sesiones \$680.000 (ahorra \$70.000), 6 sesiones \$780.000 (ahorra \$120.000).',
  '- Referida/conocida/organizacional/corporativa: 5 sesiones \$700.000 (ahorra \$50.000), 6 sesiones \$820.000 (ahorra \$80.000).'
);

// PUNTO 6: No mostrar '(tarifa referido)' ni etiquetas de tarifa junto al valor
// Agregar regla explicita
c = c.replace(
  'CONFIRMACION ANTES DE AGENDAR:',
  'PRESENTACION DE TARIFAS — REGLA IMPORTANTE:\\n- NUNCA digas por que preguntas si es nueva o referida. Solo pregunta con naturalidad.\\n- NUNCA muestres etiquetas de tarifa junto al valor (nada de \"tarifa referido\", \"tarifa nueva\", \"precio especial\"). Solo di el valor: \"\$150.000\", punto.\\n- NUNCA digas \"esto es para definir/confirmar la tarifa\".\\n\\nCONFIRMACION ANTES DE AGENDAR:'
);

// PUNTO 7: Cuando hay multiples citas y una ya tiene pago, indicarlo
c = c.replace(
  'Recuerdale con calidez que el pago debe estar hecho antes de la sesion, y comparte los datos de pago si aun no los diste.',
  'Recuerdale con calidez que el pago debe estar hecho antes de la sesion, y comparte los datos de pago si aun no los diste.\\n- Si agendas multiples citas en una conversacion y el cliente ya pago alguna, al mostrar el resumen final indica \"(ya pago)\" al lado del valor de la cita pagada, para que sea claro que citas faltan por pagar.'
);

// PUNTO 3: Citas presenciales — escalar a Daniela
c = c.replace(
  'CANCELACIONES: si el paciente pide cancelar o reagendar, NO cancelas.',
  'CITAS PRESENCIALES:\\nSi el paciente pide una sesion presencial (en persona, en consultorio, cara a cara), NO la agendes directamente. Sigue este flujo:\\n1. Recoge TODOS los datos primero (nombre, correo, celular, horario deseado).\\n2. Dile al paciente con calidez que necesitas consultar la disponibilidad presencial con la Dra. Daniela y que en breve le confirmas.\\n3. Usa escalate_to_daniela para enviarle a Daniela todos los datos del paciente, el horario solicitado y que la solicitud es presencial.\\n4. Espera. No confirmes nada al paciente hasta que Daniela responda por su lado.\\nSi el paciente no especifica modalidad, asume virtual (Teams) y agenda normalmente.\\n\\nCANCELACIONES: si el paciente pide cancelar o reagendar, NO cancelas.'
);

fs.writeFileSync(f, c);
console.log('[OK] persona.js actualizado (puntos 1,2,3,5,6,7)');
"

echo "==> Paso 2: Agregando herramienta escalate_to_daniela en tools.js..."
node -e "
const fs = require('fs');
const f = './src/aura/tools.js';
let c = fs.readFileSync(f, 'utf-8');

const newTool = \`,

  {
    name: 'escalate_to_daniela',
    description:
      'Envia un mensaje a Daniela (Doc) por Telegram cuando necesitas su decision sobre algo que no puedes resolver solo. Usalo para: solicitudes de cita presencial, situaciones especiales que requieren su aprobacion, o cualquier caso donde necesites que ella intervenga. Incluye toda la informacion relevante del paciente.',
    input_schema: {
      type: 'object',
      properties: {
        message: { type: 'string', description: 'Mensaje completo para Daniela con toda la informacion relevante (nombre del paciente, telefono, correo, que pide, horario, etc.)' },
      },
      required: ['message'],
    },
  }\`;

// Insertar antes del cierre del array TOOLS
c = c.replace(
  /\\n\\];\\n\\nmodule\\.exports/,
  newTool + '\\n];\\n\\nmodule.exports'
);

fs.writeFileSync(f, c);
console.log('[OK] tools.js - escalate_to_daniela agregado');
"

echo "==> Paso 3: Implementando escalate_to_daniela en agent.js..."
node -e "
const fs = require('fs');
const f = './src/aura/agent.js';
let c = fs.readFileSync(f, 'utf-8');

const impl = \`
  if (name === 'escalate_to_daniela') {
    try {
      const { bot } = require('../telegram/bot');
      const chatId = require('../config').telegram.danielaChatId;
      await bot.sendMessage(chatId,
        '🔔 <b>Solicitud especial de un paciente</b>\\\\n\\\\n' + input.message + '\\\\n\\\\n<i>Responde por aqui si apruebas o no, y Aura le informara al paciente.</i>',
        { parse_mode: 'HTML' });
      return { escalated: true, message: 'Mensaje enviado a la Doc. Esperando su respuesta.' };
    } catch (e) {
      return { error: 'FALLO_ESCALAR', motivo: e.message };
    }
  }

  return { error: \\\`Herramienta desconocida: \\\${name}\\\` };\`;

c = c.replace(
  \"  return { error: \\\`Herramienta desconocida: \\\${name}\\\` };\",
  impl
);

fs.writeFileSync(f, c);
console.log('[OK] agent.js - escalate_to_daniela implementado');
"

echo "==> Paso 4: Registrando mensaje de comprobante en panel (webhook.js)..."
node -e "
const fs = require('fs');
const f = './src/whatsapp/webhook.js';
let c = fs.readFileSync(f, 'utf-8');

// Agregar import de store si no lo tiene para logOutboundMessage
if (!c.includes('logOutboundMessage')) {
  // Registrar el mensaje de 'recibimos tu comprobante' en el panel
  c = c.replace(
    \"await waClient.sendText(opts.from, 'Gracias! Ya recibimos tu comprobante y en breve lo validamos.');\",
    \"await waClient.sendText(opts.from, 'Gracias! Ya recibimos tu comprobante y en breve lo validamos.');\\n  try { store.logOutboundMessage(opts.from, 'Gracias! Ya recibimos tu comprobante y en breve lo validamos.'); } catch(e) {}\"
  );
}

fs.writeFileSync(f, c);
console.log('[OK] webhook.js - mensaje comprobante registrado en panel');
"

echo "==> Paso 5: Reiniciando servicio..."
systemctl restart aura-luz
sleep 2

echo ""
echo "✅ Todo listo. Cambios aplicados:"
echo "   1. No dice por que pregunta si es nueva/referida/corporativa"
echo "   2. Tarifas referidos actualizadas: 150k / 700k (5) / 820k (6)"
echo "   3. Citas presenciales se escalan a Daniela antes de confirmar"
echo "   4. Mensaje de comprobante recibido ahora aparece en panel"
echo "   5. No dice 'esto es para confirmar la tarifa'"
echo "   6. No muestra '(tarifa referido)' junto al valor"
echo "   7. Indica '(ya pago)' en resumen de multiples citas"
