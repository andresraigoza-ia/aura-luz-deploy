#!/bin/bash
set -e
cd /root/drgsoul-web

echo "==> Paso 1: Creando favicon del colibri..."
cat > favicon.svg << 'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
<rect width="100" height="100" rx="22" fill="#fbfcfb"/>
<g transform="translate(50,50)">
<path d="M-3 15 Q-10 28 -14 39 Q-15 44 -11.5 42.5 Q-7.5 41.5 -5 35 Q-1 26 0 17.5Z" fill="#6b9e98"/>
<path d="M-1.5 16 Q-7 29 -9.5 37 Q-10 41 -7 39.5 Q-3.5 37.5 -1.5 32 Q1 25 1.5 17Z" fill="#8ecac0"/>
<ellipse cx="0" cy="7" rx="5.5" ry="10" fill="#7cb5ae" transform="rotate(-8)"/>
<ellipse cx="1" cy="4" rx="3.5" ry="5" fill="#a8d8ce"/>
<path d="M-4 5 Q-20 -10 -27 -17 Q-31 -21 -29 -22 Q-25 -23 -17 -18 Q-10 -12 -2 2Z" fill="#9b7cc4"/>
<path d="M-3 4 Q-17 -8 -23 -14 Q-26 -17 -24 -18 Q-21 -18 -14 -14 Q-8 -9 -1.5 1.5Z" fill="#b494d8"/>
<path d="M4 4 Q19 -12 26 -20 Q30 -24 28 -25 Q25 -25 18 -19 Q10 -13 2 1Z" fill="#9b7cc4"/>
<path d="M3.5 3.5 Q16 -10 22 -16 Q25 -19 23 -20 Q21 -20 14 -15 Q8 -10 2 1Z" fill="#b494d8"/>
<circle cx="1.5" cy="-4.5" r="3.5" fill="#7cb5ae"/>
<circle cx="2.5" cy="-5.2" r="0.9" fill="#2a2a3a"/>
<circle cx="2.8" cy="-5.5" r="0.3" fill="#fff"/>
<path d="M4 -5.8 Q10 -8 15 -8.5 L15 -7.9 Q10 -6.9 4 -4.9Z" fill="#555"/>
<path d="M0 -8 Q1 -11 2.5 -10 Q4 -9 3 -7.5Z" fill="#c9a8e8"/>
</g>
</svg>
EOF

echo "==> Paso 2: Creando bloque de carrusel..."
cat > /tmp/carousel_block.html << 'EOF'

<style>
/* Carrusel de voces */
.voices-carousel{position:relative;margin-top:48px}
.vc-viewport{overflow:hidden;padding:6px 2px}
.vc-track{display:flex;gap:22px;transition:transform .9s cubic-bezier(.33,0,.2,1)}
.vc-slide{flex:0 0 calc((100% - 44px)/3);min-width:0}
@media(max-width:960px){.vc-slide{flex:0 0 calc((100% - 22px)/2)}}
@media(max-width:640px){.vc-slide{flex:0 0 100%}}
.vc-btn{position:absolute;top:50%;transform:translateY(-50%);z-index:5;
  width:44px;height:44px;border-radius:50%;border:1px solid var(--line);
  background:rgba(255,255,255,.92);color:var(--teal);font-size:19px;cursor:pointer;
  display:flex;align-items:center;justify-content:center;box-shadow:0 6px 18px rgba(59,70,80,.14);transition:.2s}
.vc-btn:hover{background:var(--teal);color:#fff;border-color:var(--teal)}
.vc-prev{left:-12px}.vc-next{right:-12px}
@media(max-width:640px){.vc-prev{left:4px}.vc-next{right:4px}}
/* Booking movil impecable */
@media(max-width:768px){
  .book{margin:0 14px 64px;padding:60px 18px}
  .book small{line-height:2}
}
.book-mail{display:inline-flex;align-items:center;gap:8px;margin-top:22px;
  font-weight:600;font-size:15px;color:var(--teal);text-decoration:none;
  border-bottom:1px solid rgba(31,138,128,.35);padding-bottom:2px;transition:.2s}
.book-mail:hover{border-color:var(--teal)}
</style>
<script>
(function(){
  var grid=document.querySelector('.voices-grid');
  if(!grid)return;
  var cards=Array.prototype.slice.call(grid.querySelectorAll('.vquote'));
  if(cards.length<2)return;
  for(var i=cards.length-1;i>0;i--){var j=Math.floor(Math.random()*(i+1));var t=cards[i];cards[i]=cards[j];cards[j]=t;}
  grid.innerHTML='';
  grid.classList.remove('voices-grid');
  grid.classList.add('voices-carousel');
  var vp=document.createElement('div');vp.className='vc-viewport';
  var track=document.createElement('div');track.className='vc-track';
  cards.forEach(function(c){c.classList.remove('reveal');c.classList.add('vc-slide');track.appendChild(c);});
  vp.appendChild(track);grid.appendChild(vp);
  var prev=document.createElement('button');prev.className='vc-btn vc-prev';prev.setAttribute('aria-label','Testimonio anterior');prev.innerHTML='&#8592;';
  var next=document.createElement('button');next.className='vc-btn vc-next';next.setAttribute('aria-label','Testimonio siguiente');next.innerHTML='&#8594;';
  grid.appendChild(prev);grid.appendChild(next);
  var idx=0;
  function perView(){var w=window.innerWidth;return w<=640?1:(w<=960?2:3);}
  function maxIdx(){return Math.max(0,cards.length-perView());}
  function go(n){
    var m=maxIdx();
    idx=n>m?0:(n<0?m:n);
    var gap=22;
    var first=track.children[0];
    if(!first)return;
    var slideW=first.getBoundingClientRect().width+gap;
    track.style.transform='translateX('+(-idx*slideW)+'px)';
  }
  var timer=null;
  function start(){if(!timer){timer=setInterval(function(){go(idx+1);},12000);}}
  function stop(){if(timer){clearInterval(timer);timer=null;}}
  function restart(){stop();start();}
  prev.addEventListener('click',function(){go(idx-1);restart();});
  next.addEventListener('click',function(){go(idx+1);restart();});
  grid.addEventListener('mouseenter',stop);
  grid.addEventListener('mouseleave',start);
  grid.addEventListener('touchstart',stop,{passive:true});
  grid.addEventListener('touchend',restart,{passive:true});
  window.addEventListener('resize',function(){go(idx);});
  go(0);start();
})();
</script>
EOF

echo "==> Paso 3: Aplicando cambios al index.html..."
node << 'JSEOF'
const fs = require('fs');
const f = './index.html';
let c = fs.readFileSync(f, 'utf-8');

// 1. Favicon + Open Graph (para tarjeta al compartir por WhatsApp)
if (!c.includes('favicon.svg')) {
  c = c.replace(
    '</title>',
    `</title>
<link rel="icon" type="image/svg+xml" href="/favicon.svg">
<meta property="og:title" content="DRG Soul · Daniela Rodríguez — Psicóloga Humanista">
<meta property="og:description" content="Un espacio para habitarnos. Psicología humanista, mindfulness y acompañamiento consciente en Cali, Colombia.">
<meta property="og:image" content="https://www.drgsoul.com/daniela.jpg">
<meta property="og:url" content="https://www.drgsoul.com">
<meta property="og:type" content="website">`
  );
  console.log('[OK] Favicon + Open Graph');
} else {
  console.log('[SKIP] Favicon ya existe');
}

// 2. Booking: correo estrategico + fix movil del telefono
if (c.includes('<small>Lun a Vie · Cali, Colombia · +57 302 710 9880</small>')) {
  c = c.replace(
    '<small>Lun a Vie · Cali, Colombia · +57 302 710 9880</small>',
    `<br><a class="book-mail" href="mailto:danielarodriguez@drgsoul.com">&#9993; danielarodriguez@drgsoul.com</a>
    <small>Lun a Vie · Cali, Colombia<br><span style="white-space:nowrap">+57 302 710 9880</span></small>`
  );
  console.log('[OK] Correo en booking + fix movil');
} else {
  console.log('[MISS] small del booking - revisar manualmente');
}

// 3. Agregar bloque de carrusel al final
if (!c.includes('voices-carousel')) {
  const block = fs.readFileSync('/tmp/carousel_block.html', 'utf-8');
  c = c + block;
  console.log('[OK] Carrusel agregado');
} else {
  console.log('[SKIP] Carrusel ya existe');
}

fs.writeFileSync(f, c);
console.log('Listo.');
JSEOF

echo ""
echo "✅ Cambios aplicados. Recarga www.drgsoul.com con Ctrl+Shift+R"
