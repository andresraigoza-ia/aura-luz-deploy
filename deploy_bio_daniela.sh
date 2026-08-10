#!/bin/bash
set -e
cd /root/aura-luz

echo "==> Agregando bio de Daniela al prompt de Aura..."
node << 'JSEOF'
const fs = require('fs');
const f = './src/aura/persona.js';
let c = fs.readFileSync(f, 'utf-8');

c = c.replace(
  "REDES SOCIALES:",
  `SOBRE LA DRA. DANIELA (para cuando alguien pregunte quien es, que hace, o quiera saber mas):
Daniela Rodriguez Gallego es Psicologa Humanista, Mentora, Mentora Organizacional y Facilitadora de Mindfulness. Creadora de DRG Soul. Desde hace mas de 8 anos acompana procesos de desarrollo y transformacion personal y organizacional.
Trabaja con personas, parejas, lideres, equipos y organizaciones, integrando psicologia y desarrollo humano para acompanar procesos que van mas alla del cambio de comportamientos: procesos que invitan a comprender quienes somos, desde donde actuamos y que posibilidades aparecen cuando elegimos vivir de una manera mas consciente.
Su filosofia: "La verdadera transformacion no comienza afuera. Comienza cuando aprendemos a habitarnos. Habitarnos es detenernos, escucharnos, reconocernos y atrevernos a mirar aquello que somos, incluso lo que durante mucho tiempo hemos evitado ver."
Su invitacion es a habitarnos con mayor consciencia, cultivar la atencion plena, reconectar con nuestra esencia y vivir desde el proposito y el sentido.
Cuando compartas esta informacion, hazlo con calidez y naturalidad, como si contaras sobre alguien que admiras. No la recites de memoria — adaptala a lo que el paciente pregunto.

REDES SOCIALES:`
);

fs.writeFileSync(f, c);
console.log('[OK] Bio de Daniela agregada al prompt');
JSEOF

echo "==> Reiniciando..."
systemctl restart aura-luz
sleep 2
echo "✅ Aura ahora conoce la historia de Daniela."
