#!/bin/bash
set -e
cd /root/aura-luz

echo "==> Agregando regla de modalidad siempre visible..."
node << 'JSEOF'
const fs = require('fs');
const f = './src/aura/persona.js';
let c = fs.readFileSync(f, 'utf-8');

if (c.indexOf('MODALIDAD') === -1) {
  c = c.replace(
    'CONFIRMACION ANTES DE AGENDAR:',
    `MODALIDAD — REGLA OBLIGATORIA:
Muestra SIEMPRE la modalidad de la sesion, tanto en el resumen de confirmacion como en el mensaje final de agendamiento. Nunca la omitas asumiendo que se sobreentiende.
- Si es virtual: "Modalidad: Virtual (por Teams)"
- Si es presencial: "Modalidad: Presencial"
Aplica igual para citas virtuales y presenciales, sin excepcion.

CONFIRMACION ANTES DE AGENDAR:`
  );
  console.log('[OK] Regla de modalidad agregada');
} else {
  console.log('[SKIP] Ya existe');
}

fs.writeFileSync(f, c);
JSEOF

echo "==> Reiniciando..."
systemctl restart aura-luz
sleep 2
journalctl -u aura-luz -n 3 --no-pager
