const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');

const PORT = 3032;
const DEFAULT_TARGET_PORT = 3030;
const MAIN_LOG_PATH = '/home/user/.config/Antigravity/logs/main.log';

const INJECT_SCRIPT = `
<script>
// Mock native Electron bridges for standalone browser mode
window.nativeStorage = {
  getItems: async () => {
    const items = {};
    for (let i = 0; i < localStorage.length; i++) {
      const key = localStorage.key(i);
      try {
        items[key] = JSON.parse(localStorage.getItem(key));
      } catch {
        items[key] = localStorage.getItem(key);
      }
    }
    return items;
  },
  updateItems: async (changes) => {
    for (const [key, value] of Object.entries(changes)) {
      if (value === null || value === undefined) {
        localStorage.removeItem(key);
      } else {
        localStorage.setItem(key, typeof value === 'object' ? JSON.stringify(value) : value);
      }
    }
  },
  onChanged: (callback) => {
    const handler = (e) => {
      if (e.storageArea === localStorage) {
        let newValue;
        try {
          newValue = JSON.parse(e.newValue);
        } catch {
          newValue = e.newValue;
        }
        callback({ [e.key]: { newValue } });
      }
    };
    window.addEventListener('storage', handler);
    return () => window.removeEventListener('storage', handler);
  }
};

window.electronUpdater = {
  onStateChanged: () => () => {},
  applyUpdate: async () => {},
  quitAndInstall: async () => {},
  checkForUpdates: async () => {},
  getState: async () => ({})
};

window.dialog = {
  showOpenDialog: async () => ({})
};

window.nativeNotifications = {
  send: async () => {},
  openSystemPreferences: async () => {},
  onClicked: () => () => {}
};

window.logs = {
  getElectronLogs: async () => []
};

window.extensions = {
  sendAuthorities: async () => {}
};

window.deepLink = {
  onDeepLink: () => () => {},
  getStoredDeepLink: async () => ''
};

window.agent = {
  updateActiveAgentCount: async () => {}
};

window.electronNative = {
  getZoomLevel: () => 1,
  setTitleBarOverlay: async () => {},
  minimize: async () => {},
  maximize: async () => {},
  unmaximize: async () => {},
  isMaximized: async () => false,
  close: async () => {},
  toggleDevTools: async () => {},
  zoomIn: () => {},
  zoomOut: () => {},
  resetZoom: () => {},
  openExternal: async (url) => window.open(url, '_blank')
};

window.ide = {
  isInstalled: async () => true
};
console.log('Antigravity standalone browser mocks successfully injected!');
</script>
`;

function getActiveElectronPort() {
  try {
    if (!fs.existsSync(MAIN_LOG_PATH)) {
      return null;
    }
    const logContent = fs.readFileSync(MAIN_LOG_PATH, 'utf8');
    const matches = [...logContent.matchAll(/Reloading all windows with URL: https:\/\/127\.0\.0\.1:(\d+)\//g)];
    if (matches.length > 0) {
      const lastMatch = matches[matches.length - 1];
      return {
        port: parseInt(lastMatch[1], 10),
        protocol: 'https'
      };
    }
  } catch (err) {
    console.error('Error reading Electron main log:', err);
  }
  return null;
}

const server = http.createServer((req, res) => {
  let target = getActiveElectronPort();
  if (!target) {
    target = {
      port: DEFAULT_TARGET_PORT,
      protocol: 'http'
    };
  }

  console.log(`[Proxy] Request ${req.method} ${req.url} -> Routing to ${target.protocol}://127.0.0.1:${target.port}`);

  const options = {
    hostname: '127.0.0.1',
    port: target.port,
    path: req.url,
    method: req.method,
    headers: { ...req.headers },
    rejectUnauthorized: false
  };
  delete options.headers['host'];
  delete options.headers['accept-encoding'];

  const requestModule = target.protocol === 'https' ? https : http;

  const proxyReq = requestModule.request(options, (proxyRes) => {
    const contentType = proxyRes.headers['content-type'] || '';
    console.log(`[Proxy] Response status: ${proxyRes.statusCode}, Content-Type: ${contentType}`);
    
    if (contentType.includes('text/html')) {
      let body = '';
      proxyRes.on('data', (chunk) => { 
        body += chunk; 
      });
      proxyRes.on('end', () => {
        console.log(`[Proxy] HTML body loaded. Original length: ${Buffer.byteLength(body)}`);
        if (body.includes('<head>')) {
          body = body.replace('<head>', '<head>' + INJECT_SCRIPT);
        } else if (body.includes('<body>')) {
          body = body.replace('<body>', '<body>' + INJECT_SCRIPT);
        }
        
        const newHeaders = { ...proxyRes.headers };
        delete newHeaders['content-length'];
        delete newHeaders['transfer-encoding'];
        newHeaders['content-length'] = Buffer.byteLength(body);
        
        console.log(`[Proxy] Sending modified HTML, new length: ${newHeaders['content-length']}`);
        res.writeHead(proxyRes.statusCode, newHeaders);
        res.end(body);
      });
    } else {
      res.writeHead(proxyRes.statusCode, proxyRes.headers);
      proxyRes.pipe(res);
    }
  });

  proxyReq.on('error', (err) => {
    console.error(`[Proxy] Error connecting to target:`, err);
    res.writeHead(500, { 'Content-Type': 'text/plain' });
    res.end(`Proxy error connecting to target (${target.protocol}://127.0.0.1:${target.port}): ` + err.message);
  });

  req.pipe(proxyReq);
});

server.listen(PORT, () => {
  console.log(`Node.js auto-detecting injection proxy listening on port ${PORT}`);
});
