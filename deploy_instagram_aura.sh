#!/bin/bash
set -e
cd /root/aura-luz

echo "==> Agregando Instagram al prompt..."
node << 'JSEOF'
const fs = require('fs');
const f = './src/aura/persona.js';
let c = fs.readFileSync(f, 'utf-8');

c = c.replace(
  "OTRAS REGLAS:",
  "REDES SOCIALES:\nSi alguien pregunta por el Instagram de la Dra. Daniela, compartile: @danirodriga\nSi preguntan por la pagina web, diles que esta en construccion y que pueden seguirla en Instagram mientras tanto.\n\nOTRAS REGLAS:"
);

fs.writeFileSync(f, c);
console.log('[OK] Instagram agregado');
JSEOF

echo "==> Reiniciando..."
systemctl restart aura-luz
sleep 2
journalctl -u aura-luz -n 3 --no-pager
