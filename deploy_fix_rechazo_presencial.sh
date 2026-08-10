#!/bin/bash
set -e
cd /root/aura-luz

echo "==> Actualizando persona.js y bot.js..."
node << 'JSEOF'
const fs = require('fs');

// 1. persona.js - comportamiento post-rechazo presencial
let p = fs.readFileSync('./src/aura/persona.js', 'utf-8');

p = p.replace(
  "Si la solicitud presencial fue rechazada (veras un mensaje tuyo diciendo que no hay disponibilidad presencial y ofreciendo virtual), y el paciente acepta virtual, agenda directamente con create_appointment usando los mismos datos que ya tienes. NO vuelvas a escalar ni a pedir confirmacion a Daniela. Si el paciente dice que no quiere virtual, respetalo con calidez e invitalo a reconsiderarlo cuando lo desee.",
  "Si la solicitud presencial fue rechazada (veras un mensaje tuyo diciendo que la doctora solo atiende virtualmente):\n- Si el paciente acepta virtual: agenda directamente con create_appointment usando los mismos datos que ya tienes. NO vuelvas a escalar ni a pedir confirmacion a Daniela.\n- Si el paciente insiste en presencial: dile con calidez que por el momento la Dra. Daniela esta atendiendo unicamente de forma virtual y que la experiencia por Teams es igual de cercana y efectiva. Insiste UNA vez mas con amabilidad.\n- Si el paciente sigue sin aceptar virtual: respeta su decision con calidez, agradecele el interes, deseale bienestar y cierra la conversacion amablemente. NUNCA le digas el motivo real del rechazo, NUNCA vuelvas a escalar a Daniela sobre el mismo paciente, y NUNCA ofrezcas presencial de nuevo para ese paciente en esa conversacion."
);

fs.writeFileSync('./src/aura/persona.js', p);
console.log('[OK] persona.js');

// 2. bot.js - ajustar mensaje de rechazo (no decir "para esa fecha" sino "por el momento")
let b = fs.readFileSync('./src/telegram/bot.js', 'utf-8');

b = b.replace(
  "var rechazoMsg = 'Hola ' + pending.patientName.split(' ')[0] + ' 🌷 Te cuento que por el momento la Dra. Daniela no tiene disponibilidad presencial para esa fecha. Tu sesion puede ser igual de cercana y efectiva por Teams. ¿Te gustaria que la agendemos asi? 💛';",
  "var rechazoMsg = 'Hola ' + pending.patientName.split(' ')[0] + ' 🌷 Te cuento que por el momento la Dra. Daniela esta atendiendo unicamente de forma virtual por Teams. La experiencia es igual de cercana y efectiva. ¿Te gustaria que agendemos tu sesion asi? 💛';"
);

fs.writeFileSync('./src/telegram/bot.js', b);
console.log('[OK] bot.js');
JSEOF

echo "==> Reiniciando..."
systemctl restart aura-luz
sleep 2
journalctl -u aura-luz -n 3 --no-pager
