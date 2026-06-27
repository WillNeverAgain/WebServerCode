const fs = require('fs');
const http = require('http');
const path = require('path');
const { lookupMimeType } = require('./mime');
const { getConfig, getProjectRoot, getConfigPath } = require('./config');
const { loadWebApp, isPathInside } = require('./webapp');

const projectRoot = getProjectRoot();
const pidPath = path.join(projectRoot, 'logs', 'server.pid');
let webAppRuntime = null;

function ensureLogsDirectory() {
  fs.mkdirSync(path.dirname(pidPath), { recursive: true });
}

function writePidFile() {
  ensureLogsDirectory();
  fs.writeFileSync(pidPath, String(process.pid));
}

function removePidFile() {
  try {
    if (fs.existsSync(pidPath) && fs.readFileSync(pidPath, 'utf8').trim() === String(process.pid)) {
      fs.unlinkSync(pidPath);
    }
  } catch {
    // Ignore shutdown cleanup errors.
  }
}

function hostWithoutPort(hostHeader) {
  if (!hostHeader) return '';
  const trimmed = hostHeader.trim();
  if (trimmed.startsWith('[')) {
    const end = trimmed.indexOf(']');
    return end >= 0 ? trimmed.slice(1, end).toLowerCase() : trimmed.toLowerCase();
  }
  return trimmed.split(':')[0].toLowerCase();
}

function isAllowedHost(requestHost, config) {
  if (!config.server.enforceHost) return true;

  const host = hostWithoutPort(requestHost);
  const allowed = new Set([
    config.site.domain.toLowerCase(),
    ...config.server.allowedHosts.map((item) => String(item).toLowerCase())
  ]);

  return allowed.has(host);
}

function normalizeRequestPath(url, hostHeader) {
  const parsed = new URL(url, `http://${hostHeader || 'localhost'}`);
  let pathname = decodeURIComponent(parsed.pathname);
  if (pathname.length > 1 && pathname.endsWith('/')) {
    pathname = pathname.slice(0, -1);
  }
  return pathname || '/';
}

function sendJson(res, statusCode, body) {
  const payload = JSON.stringify(body, null, 2);
  res.writeHead(statusCode, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(payload)
  });
  res.end(payload);
}

function sendError(res, statusCode, message) {
  const body = `<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>${statusCode}</title><body><h1>${statusCode}</h1><p>${message}</p></body></html>`;
  res.writeHead(statusCode, {
    'Content-Type': 'text/html; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store'
  });
  res.end(body);
}

function applySecurityHeaders(headers, config, webApp) {
  for (const [key, value] of Object.entries(config.securityHeaders)) {
    if (value) headers[key] = String(value);
  }

  if (webApp) {
    for (const [key, value] of Object.entries(webApp.securityHeaders)) {
      if (value) headers[key] = String(value);
    }
  }
}

function serveFile(req, res, filePath, basePath, cacheControl, config, webApp) {
  const resolvedFile = path.resolve(filePath);
  const resolvedBase = path.resolve(basePath);

  if (!isPathInside(resolvedBase, resolvedFile)) {
    sendError(res, 403, 'Forbidden');
    return;
  }

  fs.stat(resolvedFile, (statError, stat) => {
    if (statError || !stat.isFile()) {
      sendError(res, 404, 'Not found');
      return;
    }

    const headers = {
      'Content-Type': lookupMimeType(path.extname(resolvedFile)),
      'Content-Length': stat.size,
      'Cache-Control': cacheControl || 'no-store',
      'Last-Modified': stat.mtime.toUTCString()
    };
    applySecurityHeaders(headers, config, webApp);

    res.writeHead(200, headers);
    if (req.method === 'HEAD') {
      res.end();
      return;
    }

    fs.createReadStream(resolvedFile).pipe(res);
  });
}

function matchStaticMount(requestPath, webApp) {
  return webApp.staticMounts.find((mount) => requestPath.startsWith(mount.route));
}

async function requestHandler(req, res) {
  let config;
  try {
    config = getConfig();
  } catch (error) {
    sendJson(res, 500, {
      ok: false,
      error: `Failed to load config: ${error.message}`,
      configPath: getConfigPath()
    });
    return;
  }

  if (!['GET', 'HEAD'].includes(req.method)) {
    sendError(res, 405, 'Method not allowed');
    return;
  }

  if (!isAllowedHost(req.headers.host, config)) {
    sendError(res, 421, 'Host is not configured for this server.');
    return;
  }

  let requestPath;
  try {
    requestPath = normalizeRequestPath(req.url, req.headers.host);
  } catch {
    sendError(res, 400, 'Bad request path');
    return;
  }

  if (requestPath === '/_health') {
    sendJson(res, 200, {
      ok: true,
      pid: process.pid,
      domain: config.site.domain,
      webApp: webAppRuntime ? {
        name: webAppRuntime.name,
        source: webAppRuntime.source,
        webRoot: webAppRuntime.webRoot,
        entryPath: webAppRuntime.entryPath,
        rootPath: webAppRuntime.rootPath,
        routes: webAppRuntime.pages.map((page) => page.route)
      } : null,
      configPath: getConfigPath(),
      time: new Date().toISOString()
    });
    return;
  }

  if (!webAppRuntime) {
    sendError(res, 503, 'Web app is not loaded.');
    return;
  }

  if (webAppRuntime.handleRequest) {
    try {
      const parsedUrl = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
      const handled = await Promise.resolve(webAppRuntime.handleRequest({
        req,
        res,
        url: parsedUrl,
        requestPath,
        config,
        webApp: webAppRuntime
      }));

      if (handled || res.writableEnded) {
        return;
      }
    } catch (error) {
      sendJson(res, 500, {
        ok: false,
        error: `Web app handler failed: ${error.message}`
      });
      return;
    }
  }

  const page = webAppRuntime.pageMap.get(requestPath);
  if (page) {
    serveFile(req, res, path.join(webAppRuntime.rootPath, page.file), webAppRuntime.rootPath, page.cacheControl, config, webAppRuntime);
    return;
  }

  const mount = matchStaticMount(requestPath, webAppRuntime);
  if (mount) {
    const relative = requestPath.slice(mount.route.length);
    serveFile(req, res, path.join(mount.dirPath, relative), mount.dirPath, mount.cacheControl, config, webAppRuntime);
    return;
  }

  if (webAppRuntime.fallbackPage) {
    serveFile(req, res, path.join(webAppRuntime.rootPath, webAppRuntime.fallbackPage), webAppRuntime.rootPath, 'no-store', config, webAppRuntime);
    return;
  }

  sendError(res, 404, 'Not found');
}

async function startServer() {
  const config = getConfig();
  webAppRuntime = await loadWebApp(config);
  writePidFile();

  const server = http.createServer((req, res) => {
    requestHandler(req, res).catch((error) => {
      if (!res.writableEnded) {
        sendJson(res, 500, {
          ok: false,
          error: error.message
        });
      }
    });
  });
  server.listen(config.server.port, config.server.host, () => {
    const localUrl = `http://${config.server.host}:${config.server.port}`;
    console.log(`[${new Date().toISOString()}] ${config.server.name || 'LocalHtmlServer'} listening on ${localUrl}`);
    console.log(`[${new Date().toISOString()}] Configured domain: ${config.site.domain}`);
    console.log(`[${new Date().toISOString()}] Web app: ${webAppRuntime.name} (${webAppRuntime.source})`);
    console.log(`[${new Date().toISOString()}] Web entry: ${webAppRuntime.entryPath}`);
  });

  server.on('error', (error) => {
    console.error(`[${new Date().toISOString()}] Server failed: ${error.message}`);
    process.exitCode = 1;
  });

  for (const signal of ['SIGINT', 'SIGTERM']) {
    process.on(signal, () => {
      server.close(() => {
        removePidFile();
        process.exit(0);
      });
    });
  }
}

process.on('exit', removePidFile);
startServer().catch((error) => {
  console.error(`[${new Date().toISOString()}] Startup failed: ${error.message}`);
  removePidFile();
  process.exit(1);
});
