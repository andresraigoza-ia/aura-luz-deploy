#!/bin/bash
set -e
cd /root/aura-luz

echo "==> Paso 1: tools.js - agregar session_value..."
node << 'JSEOF'
const fs = require('fs');
const f = './src/aura/tools.js';
let c = fs.readFileSync(f, 'utf-8');
c = c.replace(
  "presencial: { type: 'boolean', description: 'true si la sesion es presencial (en consultorio). false o no incluir si es virtual (Teams). Default: false (virtual).' },",
  "presencial: { type: 'boolean', description: 'true si la sesion es presencial (en consultorio). false o no incluir si es virtual (Teams). Default: false (virtual).' },\n        session_value: { type: 'number', description: 'Valor en COP de esta sesion segun la tarifa que aplica. OBLIGATORIO. Ej: 200000 para persona nueva, 150000 para referida, 350000 para parejas.' },"
);
fs.writeFileSync(f, c);
console.log('[OK] tools.js');
JSEOF

echo "==> Paso 2: persona.js - instruir valor obligatorio..."
node << 'JSEOF'
const fs = require('fs');
const f = './src/aura/persona.js';
let c = fs.readFileSync(f, 'utf-8');
c = c.replace(
  'SOLO con el "si" llamas a create_appointment UNA vez.',
  'SOLO con el "si" llamas a create_appointment UNA vez.\n- Al llamar a create_appointment, incluye SIEMPRE session_value con el valor en pesos de la sesion segun la tarifa que aplica (200000, 150000 o 350000). Nunca lo dejes vacio.'
);
fs.writeFileSync(f, c);
console.log('[OK] persona.js');
JSEOF

echo "==> Paso 3: agent.js - guardar valorSesion..."
node << 'JSEOF'
const fs = require('fs');
const f = './src/aura/agent.js';
let c = fs.readFileSync(f, 'utf-8');
c = c.replace(
  "presencial: input.presencial || false,\n      createdAt:",
  "presencial: input.presencial || false,\n      valorSesion: input.session_value || 0,\n      createdAt:"
);
fs.writeFileSync(f, c);
console.log('[OK] agent.js');
JSEOF

echo "==> Paso 4: clients.js - dos columnas de valor..."
node << 'JSEOF'
const fs = require('fs');
const f = './src/clients.js';
let c = fs.readFileSync(f, 'utf-8');

c = c.replace(
  'valor_facturado: 0,',
  'valor_sesiones: 0,\n        valor_pagado: 0,'
);

c = c.replace(
  "if (a.valorSesion) rec.valor_facturado += Number(a.valorSesion) || 0;",
  "if (a.valorSesion) {\n        rec.valor_sesiones += Number(a.valorSesion) || 0;\n        if (a.paymentStatus === 'validado') rec.valor_pagado += Number(a.valorSesion) || 0;\n      }"
);

c = c.replace(
  "'Sesiones canceladas', 'Valor facturado (COP)', 'Origen',",
  "'Sesiones canceladas', 'Valor sesiones (COP)', 'Valor pagado (COP)', 'Origen',"
);

c = c.replace(
  'r.valor_facturado,',
  'r.valor_sesiones, r.valor_pagado,'
);

c = c.replace(
  "{ wch: 20 }, { wch: 22 }, { wch: 20 },",
  "{ wch: 20 }, { wch: 20 }, { wch: 20 }, { wch: 20 },"
);

c = c.replace(
  "const totalFacturado = rows.reduce((s, r) => s + r.valor_facturado, 0);",
  "const totalSesiones = rows.reduce((s, r) => s + r.valor_sesiones, 0);\n  const totalPagado = rows.reduce((s, r) => s + r.valor_pagado, 0);"
);

c = c.replace(
  /if \(totalFacturado > 0\) txt \+= .Total facturado.*\n/,
  "if (totalSesiones > 0) txt += `Valor total sesiones: $${totalSesiones.toLocaleString('es-CO')}\\n`;\n  if (totalPagado > 0) txt += `Total pagado: $${totalPagado.toLocaleString('es-CO')}\\n`;\n"
);

fs.writeFileSync(f, c);
console.log('[OK] clients.js');
JSEOF

echo "==> Paso 5: Reiniciando..."
systemctl restart aura-luz
sleep 2
echo "✅ Listo. Excel ahora tiene Valor sesiones + Valor pagado."
