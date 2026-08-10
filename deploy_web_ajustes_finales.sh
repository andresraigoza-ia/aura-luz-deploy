#!/bin/bash
set -e
cd /root/drgsoul-web

echo "==> Aplicando ajustes finales..."
node << 'JSEOF'
const fs = require('fs');
const f = './index.html';
let c = fs.readFileSync(f, 'utf-8');

// 1. Cambiar titulo de la tarjeta organizacional
c = c.replace(
  '<h3>Organizacional y equipos</h3>',
  '<h3>Organizacional, equipos y talleres grupales</h3>'
);

// 2. Rediseñar seccion Voces con foto de Daniela y agregar testimonio de Sara
c = c.replace(
  `<!-- ===================== VOCES ===================== -->
<section id="voces">
  <div class="wrap">
    <div class="section-head reveal">
      <p class="eyebrow">Voces</p>
      <h2>Quienes ya caminaron conmigo</h2>
    </div>`,
  `<!-- ===================== VOCES ===================== -->
<section id="voces" style="overflow:hidden">
  <div class="wash w-lav" style="width:400px;height:400px;background:var(--w-lav);top:-60px;right:-80px"></div>
  <div class="wash w-mint" style="width:360px;height:360px;background:var(--w-mint);bottom:-100px;left:-60px"></div>
  <div class="wrap">
    <div style="text-align:center;margin-bottom:48px" class="reveal">
      <p class="eyebrow">Voces</p>
      <h2 style="font-size:clamp(30px,4.4vw,46px);margin-top:14px">Quienes ya caminaron conmigo</h2>
      <div style="margin:32px auto 0;width:120px;height:120px;border-radius:50%;overflow:hidden;border:3px solid var(--teal);box-shadow:0 8px 28px rgba(31,138,128,.18)">
        <img src="/daniela2.jpg" alt="Daniela Rodríguez" style="width:100%;height:100%;object-fit:cover">
      </div>
      <p style="font-family:'Fraunces',serif;font-size:18px;color:var(--muted);margin-top:16px;font-weight:300;font-style:italic;max-width:480px;margin-left:auto;margin-right:auto">"Cada historia que acompaño me recuerda por qué elegí este camino."</p>
    </div>`
);

// 3. Agregar testimonio de Sara Mejía antes del cierre de voices-grid
c = c.replace(
  `        <div class="who-q">Paula Echeverri</div>
      </div>
    </div>`,
  `        <div class="who-q">Paula Echeverri</div>
      </div>
      <div class="vquote reveal">
        <span class="mark" aria-hidden="true">&ldquo;</span>
        <p>Mi proceso con Daniela fue un espacio para detenerme, mirarme y reconocer cosas de m&iacute; que,
          en medio de las responsabilidades y el d&iacute;a a d&iacute;a, hab&iacute;a dejado de escuchar.
          Su manera de acompa&ntilde;arme me permiti&oacute; <em>sentirme escuchada, comprenderme desde otro lugar</em>
          y descubrir nuevas posibilidades para relacionarme conmigo misma y con los dem&aacute;s.
          Me llevo gratitud por este proceso y, sobre todo, una mayor consciencia de qui&eacute;n soy
          y de c&oacute;mo quiero seguir creciendo.</p>
        <div class="who-q">Sara Mej&iacute;a</div>
      </div>
    </div>`
);

fs.writeFileSync(f, c);

// Verificar
console.log('Sara:', c.includes('Sara') ? 'SI' : 'NO');
console.log('daniela2:', c.includes('daniela2') ? 'SI' : 'NO');
console.log('talleres:', c.includes('talleres grupales') ? 'SI' : 'NO');
JSEOF

echo "✅ Ajustes aplicados. Recarga www.drgsoul.com"
