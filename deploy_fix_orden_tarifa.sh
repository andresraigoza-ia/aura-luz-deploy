#!/bin/bash
set -e
cd /root/aura-luz

echo "==> Actualizando persona.js - descripcion antes del precio..."
node << 'JSEOF'
const fs = require('fs');
const f = './src/aura/persona.js';
let c = fs.readFileSync(f, 'utf-8');

c = c.replace(
  "PERSONA NUEVA (individual): sesion de 1 hora, valor $200.000.\nEs un espacio de presencia, escucha profunda y herramientas de Mindfulness para reconectar con su calma y su centro.",
  "PERSONA NUEVA (individual): Es un espacio de presencia, escucha profunda y herramientas de Mindfulness para reconectar con su calma y su centro. Sesion de 1 hora, valor *$200.000*."
);

c = c.replace(
  "REFERIDA / conocida / procesos organizacionales / corporativa / ya ha consultado (individual): sesion de 1 hora, valor $150.000.",
  "REFERIDA / conocida / procesos organizacionales / corporativa / ya ha consultado (individual): Es un espacio de presencia, escucha profunda y herramientas de Mindfulness para reconectar con su calma y su centro. Sesion de 1 hora, valor *$150.000*."
);

c = c.replace(
  "PAREJAS: valor $350.000, duracion aprox. 1 hora y 50 minutos.\nEspacio de acompanamiento profesional donde ambos expresan lo que sienten, comprenden lo que ocurre en la relacion y aprenden a comunicarse desde el respeto, la consciencia y el amor.",
  "PAREJAS: Espacio de acompanamiento profesional donde ambos expresan lo que sienten, comprenden lo que ocurre en la relacion y aprenden a comunicarse desde el respeto, la consciencia y el amor. Duracion aprox. 1 hora y 50 minutos, valor *$350.000*."
);

fs.writeFileSync(f, c);
console.log('[OK] persona.js - descripcion primero, precio despues en negrilla');
JSEOF

echo "==> Reiniciando..."
systemctl restart aura-luz
sleep 2
journalctl -u aura-luz -n 3 --no-pager
