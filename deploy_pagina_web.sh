#!/bin/bash
set -e

echo "==> Paso 1: Creando directorio de la página web..."
mkdir -p /root/drgsoul-web

echo "==> Paso 2: Copiando página web..."
cp /root/drgsoul-mockup.html /root/drgsoul-web/index.html 2>/dev/null || echo "    (se creará desde el script)"

echo "==> Paso 3: Creando servidor web estático..."
cat > /root/drgsoul-web/server.js << 'EOF'
const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = 8080;
const DIR = __dirname;

const mimeTypes = {
  '.html': 'text/html',
  '.css': 'text/css',
  '.js': 'application/javascript',
  '.json': 'application/json',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
};

http.createServer((req, res) => {
  var url = req.url === '/' ? '/index.html' : req.url;
  var filePath = path.join(DIR, url);
  var ext = path.extname(filePath);

  // Seguridad: no salir del directorio
  if (!filePath.startsWith(DIR)) {
    res.writeHead(403);
    return res.end('Forbidden');
  }

  fs.readFile(filePath, (err, data) => {
    if (err) {
      // Si no existe, servir index.html (SPA fallback)
      fs.readFile(path.join(DIR, 'index.html'), (err2, data2) => {
        if (err2) {
          res.writeHead(404);
          return res.end('Not Found');
        }
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        res.end(data2);
      });
      return;
    }
    var contentType = mimeTypes[ext] || 'application/octet-stream';
    if (ext === '.html') contentType += '; charset=utf-8';
    res.writeHead(200, { 'Content-Type': contentType });
    res.end(data);
  });
}).listen(PORT, () => {
  console.log('DRGsoul web en puerto ' + PORT);
});
EOF

echo "==> Paso 4: Creando servicio systemd..."
cat > /etc/systemd/system/drgsoul-web.service << 'EOF'
[Unit]
Description=DRGsoul Web - Pagina web de Daniela Rodriguez
After=network.target

[Service]
Type=simple
WorkingDirectory=/root/drgsoul-web
ExecStart=/usr/bin/node /root/drgsoul-web/server.js
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "==> Paso 5: Habilitando y arrancando servicio..."
systemctl daemon-reload
systemctl enable drgsoul-web
systemctl start drgsoul-web
sleep 2

echo "==> Paso 6: Verificando..."
curl -s http://localhost:8080 | head -5

echo ""
echo "✅ Página web lista en https://www.drgsoul.com"
