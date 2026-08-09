#!/bin/bash
set -e

echo "=== Aura Luz: Ajuste presentacion de tarifas ==="

cp /root/aura-luz/src/aura/persona.js /root/aura-luz/src/aura/persona.js.bak4
echo "✅ Backup creado"

node << 'ENDOFNODE'
const fs = require('fs');
const filePath = '/root/aura-luz/src/aura/persona.js';
let code = fs.readFileSync(filePath, 'utf-8');

const OLD = `VALOR DEL SERVICIO Y TARIFAS (apropia estos textos con TU estilo, conversando; no los sueltes de golpe ni los copies literal):
Las sesiones son online o presenciales segun disponibilidad. Segun el caso:

PERSONA NUEVA (individual): sesion de 1 hora, valor $200.000.
Paquetes: 5 sesiones por $900.000 (ahorra $100.000), 6 sesiones por $1.000.000 (ahorra $200.000).
Es un espacio de presencia, escucha profunda y herramientas de Mindfulness para reconectar con su calma y su centro.

REFERIDA / conocida / procesos organizacionales / ya ha consultado (individual): tarifa especial $150.000 (regular $200.000).
Paquetes: 5 sesiones $680.000 (ahorra $70.000), 6 sesiones $780.000 (ahorra $120.000). Sesion de 1 hora.

PAREJAS: valor $350.000, duracion aprox. 1 hora y 50 minutos.
Espacio de acompanamiento profesional donde ambos expresan lo que sienten, comprenden lo que ocurre en la relacion y aprenden a comunicarse desde el respeto, la consciencia y el amor.`;

const NEW = `VALOR DEL SERVICIO Y TARIFAS:
Las sesiones son online o presenciales segun disponibilidad. Presenta los costos de forma calida y conversacional, segun el tipo de cliente. IMPORTANTE: al presentar tarifas por primera vez, menciona SOLO el valor por sesion. NO menciones paquetes ni precios de paquetes a menos que el cliente lo pregunte explicitamente (frases como "hay algun plan", "que pasa si quiero mas sesiones", "tienen descuento", "paquetes", etc.). Los precios de paquetes al inicio pueden abrumar — el primer paso es que el cliente decida venir una vez.

PERSONA NUEVA (individual): sesion de 1 hora, valor $200.000.
Es un espacio de presencia, escucha profunda y herramientas de Mindfulness para reconectar con su calma y su centro.

REFERIDA / conocida / procesos organizacionales / ya ha consultado (individual): tarifa especial $150.000 (el valor regular es $200.000). Sesion de 1 hora.

PAREJAS: valor $350.000, duracion aprox. 1 hora y 50 minutos.
Espacio de acompanamiento profesional donde ambos expresan lo que sienten, comprenden lo que ocurre en la relacion y aprenden a comunicarse desde el respeto, la consciencia y el amor.

PAQUETES (solo si el cliente pregunta o despues de que ya agendo su primera sesion):
- Persona nueva: 5 sesiones $900.000 (ahorra $100.000), 6 sesiones $1.000.000 (ahorra $200.000).
- Referida/conocida/organizacional: 5 sesiones $680.000 (ahorra $70.000), 6 sesiones $780.000 (ahorra $120.000).
Presentalos como una opcion de continuidad para quienes ya decidieron iniciar su proceso, no como una oferta de entrada.`;

if (!code.includes(OLD)) {
  console.error('ERROR: no se encontro el bloque de tarifas en persona.js');
  process.exit(1);
}

code = code.replace(OLD, NEW);
fs.writeFileSync(filePath, code, 'utf-8');
console.log('persona.js OK');
ENDOFNODE

echo "✅ persona.js actualizado"

echo "=== Reiniciando Aura Luz ==="
systemctl restart aura-luz
sleep 3
systemctl is-active aura-luz && echo "✅ Servicio activo" || echo "❌ Error al reiniciar"
journalctl -u aura-luz -n 6 --no-pager

echo ""
echo "=== Cambio aplicado ==="
echo "  - Primera presentacion: solo valor por sesion"
echo "  - Paquetes: solo si el cliente pregunta o despues de agendar"
