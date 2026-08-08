#!/bin/bash
set -e

echo "=== Fix: disponibilidad de calendario Aura Luz ==="

# ---- 1. Backup de seguridad ----
cp /root/aura-luz/src/aura/tools.js /root/aura-luz/src/aura/tools.js.bak
cp /root/aura-luz/src/scheduling/rules.js /root/aura-luz/src/scheduling/rules.js.bak
cp /root/aura-luz/src/aura/agent.js /root/aura-luz/src/aura/agent.js.bak
echo "✅ Backups creados"

# ---- 2. tools.js: nuevos parámetros en check_availability ----
cat > /root/aura-luz/src/aura/tools.js << 'ENDOFFILE'
const TOOLS = [
  {
    name: 'check_availability',
    description:
      'Consulta las franjas de horario disponibles en la agenda. Usala SIEMPRE antes de ofrecer un horario. Si el paciente pide horarios desde una fecha especifica (ej: desde el miercoles), pasa esa fecha en from_date. Si pide solo mananas o solo tardes, usa time_preference. Si el paciente quiere mas opciones de las que se mostraron, llama de nuevo con max_slots mayor o con from_date ajustado.',
    input_schema: {
      type: 'object',
      properties: {
        days_ahead: {
          type: 'number',
          description: 'Cuantos dias hacia adelante buscar (default 60). Aumenta si el paciente quiere fechas lejanas.'
        },
        from_date: {
          type: 'string',
          description: 'Fecha minima desde la que buscar, formato YYYY-MM-DD (hora Bogota). Usala cuando el paciente pida horarios desde el miercoles, a partir del 15, etc. Si no se especifica, busca desde ahora.'
        },
        time_preference: {
          type: 'string',
          enum: ['manana', 'tarde', 'cualquiera'],
          description: 'Filtro de franja horaria. manana = 8am-12pm, tarde = 12pm-6pm, cualquiera = sin filtro (default).'
        },
        max_slots: {
          type: 'number',
          description: 'Cuantas opciones devolver (default 3 para primera consulta, usa 6 si el paciente pide mas opciones).'
        },
      },
    },
  },
  {
    name: 'create_appointment',
    description:
      'Crea la cita real (reunion de Teams + evento en Outlook). SOLO se puede llamar cuando ya tienes NOMBRE, CORREO y CELULAR del paciente. El correo y el celular son OBLIGATORIOS: sin cualquiera de los dos NO debes llamar esta herramienta, primero pidelos.',
    input_schema: {
      type: 'object',
      properties: {
        patient_name: { type: 'string', description: 'Nombre completo del paciente' },
        patient_email: { type: 'string', description: 'OBLIGATORIO. Correo del paciente, para enviarle la invitacion con el link de Teams.' },
        patient_phone: { type: 'string', description: 'OBLIGATORIO. Celular del paciente (con indicativo), para la confirmacion por WhatsApp.' },
        reason: { type: 'string', description: 'Motivo de la cita, breve' },
        subject_note: { type: 'string', description: 'ASUNTO de la cita. OBLIGATORIO solo cuando quien agenda es Daniela (modo admin). Para pacientes por WhatsApp NO se usa, se deja vacio.' },
        start_iso: { type: 'string', description: 'Fecha/hora de inicio en ISO 8601, de una franja devuelta por check_availability' },
        end_iso: { type: 'string' },
      },
      required: ['patient_name', 'patient_email', 'patient_phone', 'reason', 'start_iso', 'end_iso'],
    },
  },
  {
    name: 'send_payment_instructions',
    description:
      'Devuelve el texto con los datos de pago/anticipo configurados para que se los envies al paciente y asi reservar la cita.',
    input_schema: { type: 'object', properties: {} },
  },
  {
    name: 'find_appointments',
    description:
      'Busca las citas activas de un paciente por su nombre, correo o celular. Usala cuando haya que ubicar una cita para cancelarla.',
    input_schema: {
      type: 'object',
      properties: {
        name: { type: 'string' },
        email: { type: 'string' },
        phone: { type: 'string' },
      },
    },
  },
  {
    name: 'cancel_appointment',
    description:
      'Cancela (elimina de verdad) una cita especifica por su appointment_id, obtenido de find_appointments. IMPORTANTE: solo Daniela (modo administradora) puede ordenar cancelaciones. Si un paciente por WhatsApp pide cancelar, NO uses esta herramienta: usa notify_daniela_cancellation.',
    input_schema: {
      type: 'object',
      properties: {
        appointment_id: { type: 'string' },
      },
      required: ['appointment_id'],
    },
  },
  {
    name: 'notify_daniela_cancellation',
    description:
      'Cuando un PACIENTE por WhatsApp pide cancelar su cita, usa esto para avisarle a Daniela por Telegram (ella gestiona). NO cancela la cita directamente.',
    input_schema: {
      type: 'object',
      properties: {
        patient_info: { type: 'string', description: 'Nombre/celular del paciente y que pidio' },
      },
      required: ['patient_info'],
    },
  },
  {
    name: 'get_next_visit_number',
    description:
      'Devuelve el numero de cita que le correspondera al paciente (consultando el calendario real de Teams). Usalo ANTES de mostrar el numero en el resumen de confirmacion, para no equivocarte. Requiere identificar al paciente por celular o correo.',
    input_schema: {
      type: 'object',
      properties: {
        patient_phone: { type: 'string' },
        patient_email: { type: 'string' },
        patient_name: { type: 'string' },
      },
    },
  },
];

module.exports = { TOOLS };
ENDOFFILE

echo "✅ tools.js actualizado"

# ---- 3. rules.js: fromDate, time_preference y daysAhead=60 ----
cat > /root/aura-luz/src/scheduling/rules.js << 'ENDOFFILE'
const config = require('../config');
const { getBusyTimes } = require('../graph/calendar');
const colombiaHolidays = require('colombia-holidays');

function toLocalDateTime(date) {
  const y = date.getFullYear();
  const mo = String(date.getMonth() + 1).padStart(2, '0');
  const d = String(date.getDate()).padStart(2, '0');
  const h = String(date.getHours()).padStart(2, '0');
  const mi = String(date.getMinutes()).padStart(2, '0');
  return `${y}-${mo}-${d}T${h}:${mi}:00`;
}

const DEFAULT_SLOTS = ['08:00', '09:00', '10:00', '11:00', '14:00', '15:00'];

function getFixedSlots() {
  return (config.rules.fixedSlots && config.rules.fixedSlots.length)
    ? config.rules.fixedSlots
    : DEFAULT_SLOTS;
}

const holidayCache = {};
function getHolidaySet(year) {
  if (!holidayCache[year]) {
    const list = colombiaHolidays.getColombiaHolidaysByYear(year) || [];
    holidayCache[year] = new Set(list.map((h) => h.holiday));
  }
  return holidayCache[year];
}

function ymd(date) {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, '0');
  const d = String(date.getDate()).padStart(2, '0');
  return `${y}-${m}-${d}`;
}

function isHoliday(date) {
  return getHolidaySet(date.getFullYear()).has(ymd(date));
}

function isWeekend(date) {
  const day = date.getDay();
  return day === 0 || day === 6;
}

function isPatientWorkingDay(date) {
  return !isWeekend(date) && !isHoliday(date);
}

/**
 * Genera franjas disponibles.
 * @param fromDate       Date o string YYYY-MM-DD desde donde empezar (default: ahora).
 * @param daysAhead      Dias a mirar (default: 60).
 * @param maxSlots       Maximo de franjas a devolver (default: 3).
 * @param restricted     true = L-V no festivos (pacientes). false = cualquier dia (Daniela).
 * @param timePreference 'manana' | 'tarde' | 'cualquiera'.
 */
async function suggestNextSlots({
  fromDate = new Date(),
  daysAhead = 60,
  maxSlots = 3,
  restricted = true,
  timePreference = 'cualquiera',
} = {}) {
  const duration = config.rules.appointmentDurationMinutes || 60;
  const allSlots = getFixedSlots();

  // Filtrar por preferencia horaria
  const slotsTimes = allSlots.filter((t) => {
    const h = parseInt(t.split(':')[0], 10);
    if (timePreference === 'manana') return h < 12;
    if (timePreference === 'tarde') return h >= 12;
    return true;
  });

  // Convertir fromDate string YYYY-MM-DD a Date en hora Bogota (medianoche local)
  let startFrom;
  if (typeof fromDate === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(fromDate)) {
    const [y, mo, d] = fromDate.split('-').map(Number);
    // 00:00 Bogota (UTC-5) = 05:00 UTC
    startFrom = new Date(Date.UTC(y, mo - 1, d, 5, 0, 0));
  } else {
    startFrom = new Date(fromDate);
  }

  const rangeEnd = new Date(startFrom);
  rangeEnd.setDate(rangeEnd.getDate() + daysAhead);

  const busyRaw = await getBusyTimes(startFrom.toISOString(), rangeEnd.toISOString());
  const slots = [];
  const now = new Date();

  for (let d = new Date(startFrom); d < rangeEnd && slots.length < maxSlots; d.setDate(d.getDate() + 1)) {
    if (restricted && !isPatientWorkingDay(d)) continue;

    for (const t of slotsTimes) {
      if (slots.length >= maxSlots) break;
      const [h, m] = t.split(':').map(Number);
      const slotStart = new Date(d);
      slotStart.setHours(h, m, 0, 0);
      const slotEnd = new Date(slotStart.getTime() + duration * 60000);

      if (slotStart <= now) continue;

      const overlaps = busyRaw.some((b) => {
        const bStart = new Date(b.start);
        const bEnd = new Date(b.end);
        return slotStart < bEnd && slotEnd > bStart;
      });

      if (!overlaps) {
        slots.push({ startISO: toLocalDateTime(slotStart), endISO: toLocalDateTime(slotEnd) });
      }
    }
  }

  return slots;
}

module.exports = { suggestNextSlots, isPatientWorkingDay, isHoliday, isWeekend, toLocalDateTime };
ENDOFFILE

echo "✅ rules.js actualizado"

# ---- 4. agent.js: actualizar bloque check_availability con los nuevos parametros ----
node << 'ENDOFNODE'
const fs = require('fs');
const filePath = '/root/aura-luz/src/aura/agent.js';
let code = fs.readFileSync(filePath, 'utf-8');

const OLD = `  if (name === 'check_availability') {
    // restricted = true para pacientes (L-V, no festivos); false para Daniela (libre).
    const restricted = ctx.restricted !== false;
    const slots = await suggestNextSlots({ daysAhead: input.days_ahead || 14, maxSlots: 6, restricted });
    // Guardamos las franjas válidas en la sesión/contexto para validar al agendar.
    ctx._validSlots = slots;
    // Devolvemos las franjas con etiqueta legible en español para que el modelo
    // elija una EXACTA (nunca invente fechas).
    const labeled = slots.map((s, i) => {
      const d = new Date(s.startISO);
      const label = d.toLocaleString('es-CO', {
        weekday: 'long', day: 'numeric', month: 'long', year: 'numeric',
        hour: 'numeric', minute: '2-digit', hour12: true, timeZone: config.timezone,
      });
      return { opcion: i + 1, etiqueta: label, start_iso: s.startISO, end_iso: s.endISO };
    });
    return { franjas_disponibles: labeled, instruccion: 'Para agendar, usa EXACTAMENTE el start_iso y end_iso de una de estas franjas. NUNCA inventes ni calcules una fecha por tu cuenta.' };
  }`;

const NEW = `  if (name === 'check_availability') {
    const restricted = ctx.restricted !== false;
    const daysAhead = input.days_ahead || 60;
    const maxSlots = input.max_slots || 3;
    const timePreference = input.time_preference || 'cualquiera';
    const fromDate = input.from_date ? input.from_date : new Date();
    const slots = await suggestNextSlots({ fromDate, daysAhead, maxSlots, restricted, timePreference });
    ctx._validSlots = slots;
    const labeled = slots.map((s, i) => {
      const d = new Date(s.startISO);
      const label = d.toLocaleString('es-CO', {
        weekday: 'long', day: 'numeric', month: 'long', year: 'numeric',
        hour: 'numeric', minute: '2-digit', hour12: true, timeZone: config.timezone,
      });
      return { opcion: i + 1, etiqueta: label, start_iso: s.startISO, end_iso: s.endISO };
    });
    const instruccion = slots.length === 0
      ? 'No hay franjas disponibles con esos criterios en los proximos ' + daysAhead + ' dias. Intenta cambiar from_date o time_preference.'
      : 'Para agendar, usa EXACTAMENTE el start_iso y end_iso de una de estas franjas. NUNCA inventes ni calcules una fecha por tu cuenta.';
    return { franjas_disponibles: labeled, instruccion };
  }`;

if (!code.includes(OLD)) {
  console.error('ERROR: no se encontro el bloque a reemplazar en agent.js. Verifica manualmente.');
  process.exit(1);
}

code = code.replace(OLD, NEW);
fs.writeFileSync(filePath, code, 'utf-8');
console.log('agent.js OK');
ENDOFNODE

echo "✅ agent.js actualizado"

# ---- 5. Reiniciar servicio ----
echo "=== Reiniciando Aura Luz ==="
systemctl restart aura-luz
sleep 3
systemctl is-active aura-luz && echo "✅ Servicio activo y corriendo" || echo "❌ Error al reiniciar — revisa journalctl -u aura-luz -f"
journalctl -u aura-luz -n 8 --no-pager

echo ""
echo "=== Fix aplicado exitosamente ==="
echo "Cambios:"
echo "  - check_availability ahora acepta from_date, time_preference y max_slots"
echo "  - daysAhead por defecto: 60 dias (antes 14)"
echo "  - maxSlots por defecto: 3 (el modelo puede pedir mas)"
echo "  - El modelo puede filtrar por manana/tarde y buscar desde cualquier fecha"
