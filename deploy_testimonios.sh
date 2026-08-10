#!/bin/bash
set -e
cd /root/drgsoul-web

echo "==> Agregando testimonios..."
node << 'JSEOF'
const fs = require('fs');
const f = './index.html';
let c = fs.readFileSync(f, 'utf-8');

// Reemplazar la seccion de voces completa con los 5 testimonios
c = c.replace(
  `    <div class="voices-grid">
      <div class="vquote reveal">
        <span class="mark" aria-hidden="true">&ldquo;</span>
        <p>A trav&eacute;s de las sesiones aprend&iacute; el valor de tres palabras que hoy gu&iacute;an mi vida:
          <em>conciencia, l&iacute;mites y visi&oacute;n</em>. La conciencia me ha permitido observar mis emociones
          sin juicio, entender sus ra&iacute;ces y actuar con mayor claridad. Los l&iacute;mites me ense&ntilde;aron
          a cuidar de m&iacute; sin perder la empat&iacute;a, y la visi&oacute;n me ayud&oacute;
          a proyectar mi futuro con prop&oacute;sito. Entend&iacute; que puedo liderar desde
          la autenticidad, la sensibilidad y la presencia.</p>
        <div class="who-q">Isabela Quintero</div>
      </div>
      <div class="vquote reveal">
        <span class="mark" aria-hidden="true">&ldquo;</span>
        <p>Not&eacute; cambios reales en la forma de manejar las situaciones adversas. Una frase me marc&oacute;
          profundamente: <em>actuar desde el amor y no desde el miedo</em>. Es algo muy profundo, que resalta mi
          autenticidad desde el lugar m&aacute;s genuino. Cuando actuamos desde el amor abrimos otra
          perspectiva y otra manera de resolver cualquier situaci&oacute;n.</p>
        <div class="who-q">Lyan Camargo</div>
      </div>
    </div>`,
  `    <div class="voices-grid">
      <div class="vquote reveal">
        <span class="mark" aria-hidden="true">&ldquo;</span>
        <p>A trav&eacute;s de las sesiones aprend&iacute; el valor de tres palabras que hoy gu&iacute;an mi vida:
          <em>conciencia, l&iacute;mites y visi&oacute;n</em>. La conciencia me ha permitido observar mis emociones
          sin juicio, entender sus ra&iacute;ces y actuar con mayor claridad. Los l&iacute;mites me ense&ntilde;aron
          a cuidar de m&iacute; sin perder la empat&iacute;a, y la visi&oacute;n me ayud&oacute;
          a proyectar mi futuro con prop&oacute;sito. Entend&iacute; que puedo liderar desde
          la autenticidad, la sensibilidad y la presencia.</p>
        <div class="who-q">Isabela Quintero</div>
      </div>
      <div class="vquote reveal">
        <span class="mark" aria-hidden="true">&ldquo;</span>
        <p>Not&eacute; cambios reales en la forma de manejar las situaciones adversas. Una frase me marc&oacute;
          profundamente: <em>actuar desde el amor y no desde el miedo</em>. Es algo muy profundo, que resalta mi
          autenticidad desde el lugar m&aacute;s genuino. Cuando actuamos desde el amor abrimos otra
          perspectiva y otra manera de resolver cualquier situaci&oacute;n.</p>
        <div class="who-q">Lyan Camargo</div>
      </div>
      <div class="vquote reveal">
        <span class="mark" aria-hidden="true">&ldquo;</span>
        <p>Llegu&eacute; sinti&eacute;ndome bloqueada, con miedo y extra&ntilde;ando profundamente la persona que era.
          Me sent&iacute;a como alguien que todav&iacute;a estaba debajo de los escombros, pero con vida.
          El acompa&ntilde;amiento de Daniela me permiti&oacute; empezar a <em>mirar lo que estaba viviendo de otra manera</em>
          y reconocer que, aunque muchas cosas hab&iacute;an cambiado, todav&iacute;a hab&iacute;a una parte de m&iacute;
          que pod&iacute;a reconstruirse.</p>
        <div class="who-q">Alison Mayorga</div>
      </div>
      <div class="vquote reveal">
        <span class="mark" aria-hidden="true">&ldquo;</span>
        <p>Mi proceso con Daniela fue un camino de <em>volver la mirada hacia m&iacute;</em>.
          Llegu&eacute; pensando que necesitaba encontrar respuestas sobre mi hija y termin&eacute;
          encontr&aacute;ndome conmigo misma. Pude reconocer mis miedos, mi necesidad de controlar
          y la forma en que estaba cargando responsabilidades que no me correspond&iacute;an.
          Me llevo herramientas, pero sobre todo una nueva manera de comprenderme y de relacionarme con mi hija.</p>
        <div class="who-q">Maritza Sarmiento</div>
      </div>
      <div class="vquote reveal">
        <span class="mark" aria-hidden="true">&ldquo;</span>
        <p>Agradezco profundamente este espacio porque me permiti&oacute; reconocer aspectos de m&iacute; que
          necesitaban ser escuchados, integrar aprendizajes y <em>volver a conectar con mi propia esencia</em>.
          Daniela no solo me acompa&ntilde;&oacute; desde su conocimiento profesional, sino desde una presencia
          humana, sensible y profundamente consciente. A veces, quienes acompa&ntilde;amos tambi&eacute;n necesitamos
          un espacio donde podamos simplemente ser, sentirnos sostenidos y seguir creciendo.</p>
        <div class="who-q">Paula Echeverri</div>
      </div>
    </div>`
);

fs.writeFileSync(f, c);
console.log('[OK] 5 testimonios en la pagina');
JSEOF

echo "✅ Testimonios actualizados. Recarga www.drgsoul.com"
