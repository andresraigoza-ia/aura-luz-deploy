#!/bin/bash
set -e
echo "==> Reescribiendo calendar.js completo..."
cat > /root/aura-luz/src/graph/calendar.js << 'EOF'
const axios = require('axios');
const { getGraphToken } = require('./auth');
const config = require('../config');

const GRAPH_BASE = 'https://graph.microsoft.com/v1.0';

async function graphClient() {
  const token = await getGraphToken();
  return axios.create({
    baseURL: GRAPH_BASE,
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
  });
}

async function createTeamsAppointment({ subject, startISO, endISO, attendeeEmail, attendeeName, bodyText, presencial }) {
  const client = await graphClient();
  const organizer = config.graph.organizerEmail;

  var fechaLegible = '';
  try {
    fechaLegible = new Date(startISO).toLocaleString('es-CO', {
      weekday: 'long', day: 'numeric', month: 'long', year: 'numeric',
      hour: 'numeric', minute: '2-digit', hour12: true, timeZone: config.timezone,
    });
  } catch(e) { fechaLegible = startISO; }

  var nombre = attendeeName ? attendeeName.split(' ')[0] : '';

  var modalidadRow = presencial
    ? '<tr><td style="padding: 4px 12px 4px 0; color: #888;">📍 Modalidad:</td><td style="padding: 4px 0;"><strong>Presencial</strong></td></tr>'
    : '<tr><td style="padding: 4px 12px 4px 0; color: #888;">📍 Modalidad:</td><td style="padding: 4px 0;">Virtual por Microsoft Teams</td></tr>';

  var enlaceTexto = presencial
    ? 'Tu sesión es presencial. El enlace de Teams queda disponible por si en algún momento necesitan conectarse virtualmente.'
    : 'El enlace para unirte a la sesión está incluido en esta invitación de calendario.';

  var attendees = attendeeEmail
    ? [{ emailAddress: { address: attendeeEmail, name: attendeeName || attendeeEmail }, type: 'required' }]
    : [];

  var htmlBody = '<div style="font-family: -apple-system, BlinkMacSystemFont, \'Segoe UI\', sans-serif; color: #333; max-width: 520px;">'
    + '<p>Hola ' + nombre + ' 🌷</p>'
    + '<p>Tu sesión con la <strong>Dra. Daniela Rodríguez</strong> quedó confirmada.</p>'
    + '<table style="margin: 16px 0; border-collapse: collapse;">'
    + '<tr><td style="padding: 4px 12px 4px 0; color: #888;">📅 Fecha:</td><td style="padding: 4px 0;"><strong>' + fechaLegible + '</strong></td></tr>'
    + '<tr><td style="padding: 4px 12px 4px 0; color: #888;">⏱ Duración:</td><td style="padding: 4px 0;">1 hora</td></tr>'
    + modalidadRow
    + '</table>'
    + '<p>' + enlaceTexto + '</p>'
    + '<p style="margin-top: 20px; color: #888; font-size: 0.85em;">DRGsoul — Dra. Daniela Rodríguez Gallego<br>Acompañamiento en bienestar y Mindfulness</p>'
    + '</div>';

  var { data } = await client.post('/users/' + organizer + '/events', {
    subject: subject,
    body: { contentType: 'HTML', content: htmlBody },
    start: { dateTime: startISO, timeZone: config.timezone },
    end: { dateTime: endISO, timeZone: config.timezone },
    attendees: attendees,
    isOnlineMeeting: true,
    onlineMeetingProvider: 'teamsForBusiness',
    responseRequested: true,
    allowNewTimeProposals: false,
    importance: 'normal',
    reminderMinutesBeforeStart: 30,
  });

  return {
    eventId: data.id,
    joinUrl: data.onlineMeeting ? data.onlineMeeting.joinUrl : null,
  };
}

async function getBusyTimes(startISO, endISO) {
  var client = await graphClient();
  var organizer = config.graph.organizerEmail;

  var { data } = await client.post('/users/' + organizer + '/calendar/getSchedule', {
    schedules: [organizer],
    startTime: { dateTime: startISO, timeZone: config.timezone },
    endTime: { dateTime: endISO, timeZone: config.timezone },
    availabilityViewInterval: 15,
  });

  var schedule = data.value && data.value[0];
  if (!schedule) return [];
  return (schedule.scheduleItems || []).map(function(item) {
    return {
      start: item.start.dateTime.endsWith('Z') ? item.start.dateTime : item.start.dateTime + 'Z',
      end: item.end.dateTime.endsWith('Z') ? item.end.dateTime : item.end.dateTime + 'Z',
    };
  });
}

async function cancelAppointment(eventId) {
  var client = await graphClient();
  var organizer = config.graph.organizerEmail;
  await client.delete('/users/' + organizer + '/events/' + eventId);
  return { cancelled: true };
}

async function updateAppointmentSubject(eventId, newSubject) {
  var client = await graphClient();
  var organizer = config.graph.organizerEmail;
  await client.patch('/users/' + organizer + '/events/' + eventId, { subject: newSubject });
  return { updated: true };
}

async function eventExists(eventId) {
  if (!eventId) return false;
  try {
    var client = await graphClient();
    var organizer = config.graph.organizerEmail;
    var { data } = await client.get('/users/' + organizer + '/events/' + eventId);
    return data && !data.isCancelled;
  } catch (err) {
    if (err.response && err.response.status === 404) return false;
    console.error('Error verificando evento en Outlook:', err.response ? err.response.status : err.message);
    return false;
  }
}

module.exports = { createTeamsAppointment, getBusyTimes, cancelAppointment, updateAppointmentSubject, eventExists };
EOF

echo "==> Reiniciando..."
systemctl restart aura-luz
sleep 2
journalctl -u aura-luz -n 5 --no-pager
