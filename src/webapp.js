const fs = require('fs');
const path = require('path');
const { pathToFileURL } = require('url');
const { getProjectRoot, normalizeRoute, resolveProjectPath } = require('./config');

const projectRoot = getProjectRoot();

function isPathInside(parentPath, childPath) {
  const relative = path.relative(parentPath, childPath);
  return relative === '' || (!relative.startsWith('..') && !path.isAbsolute(relative));
}

function resolveInside(basePath, value, label) {
  const resolved = path.resolve(basePath, value || '.');
  if (!isPathInside(basePath, resolved)) {
    throw new Error(`${label} must stay inside ${basePath}`);
  }
  return resolved;
}

function normalizeWebMode(mode) {
  const normalized = String(mode || 'auto').trim().toLowerCase();
  if (['auto', 'server-entry', 'static-spa', 'static-site'].includes(normalized)) {
    return normalized;
  }

  if (['entry', 'server', 'module'].includes(normalized)) {
    return 'server-entry';
  }

  if (['static', 'index', 'html'].includes(normalized)) {
    return 'static-spa';
  }

  throw new Error(`Unsupported git.web.mode: ${mode}`);
}

function getServerEntry(webGitConfig) {
  return webGitConfig.entry || 'server-entry.js';
}

function getStaticEntry(webGitConfig) {
  return webGitConfig.staticEntry || webGitConfig.index || 'index.html';
}

function getStaticRoot(webGitConfig) {
  return webGitConfig.staticRoot || webGitConfig.root || '.';
}

function getStaticEntryPath(webRoot, webGitConfig) {
  const rootPath = resolveInside(webRoot, getStaticRoot(webGitConfig), 'static web root');
  return resolveInside(rootPath, getStaticEntry(webGitConfig), 'static web entry');
}

function selectWebRootCandidate(webRoot, source, webGitConfig, requestedMode) {
  const serverEntryPath = resolveInside(webRoot, getServerEntry(webGitConfig), 'web entry');
  const hasServerEntry = fs.existsSync(serverEntryPath);

  if (requestedMode === 'server-entry') {
    return hasServerEntry ? {
      mode: 'server-entry',
      webRoot,
      source,
      entryPath: serverEntryPath
    } : null;
  }

  if (requestedMode === 'static-spa' || requestedMode === 'static-site') {
    const staticEntryPath = getStaticEntryPath(webRoot, webGitConfig);
    const hasStaticEntry = fs.existsSync(staticEntryPath);
    return hasStaticEntry ? {
      mode: requestedMode,
      webRoot,
      source,
      entryPath: staticEntryPath
    } : null;
  }

  if (hasServerEntry) {
    return {
      mode: 'server-entry',
      webRoot,
      source,
      entryPath: serverEntryPath
    };
  }

  const staticEntryPath = getStaticEntryPath(webRoot, webGitConfig);
  const hasStaticEntry = fs.existsSync(staticEntryPath);

  if (hasStaticEntry) {
    return {
      mode: 'static-spa',
      webRoot,
      source,
      entryPath: staticEntryPath
    };
  }

  return null;
}

function chooseWebRoot(webGitConfig) {
  const configuredRoot = webGitConfig.localPathResolved || resolveProjectPath(webGitConfig.localPath);
  const requestedMode = normalizeWebMode(webGitConfig.mode);
  const configured = selectWebRootCandidate(configuredRoot, 'configured', webGitConfig, requestedMode);

  if (configured) {
    return configured;
  }

  if (webGitConfig.fallbackToBundledExample) {
    const bundledRoot = webGitConfig.bundledExamplePathResolved || resolveProjectPath(webGitConfig.bundledExamplePath);
    const bundled = selectWebRootCandidate(bundledRoot, 'bundled-example', webGitConfig, requestedMode);
    if (bundled) {
      return bundled;
    }
  }

  const serverEntry = path.join(configuredRoot, getServerEntry(webGitConfig));
  const staticEntry = getStaticEntryPath(configuredRoot, webGitConfig);
  throw new Error(`Web entry not found. Expected ${serverEntry} or ${staticEntry}`);
}

async function loadEntryModule(entryPath) {
  const extension = path.extname(entryPath).toLowerCase();

  if (extension === '.mjs') {
    return import(`${pathToFileURL(entryPath).href}?t=${Date.now()}`);
  }

  try {
    delete require.cache[require.resolve(entryPath)];
    return require(entryPath);
  } catch (error) {
    if (error && error.code === 'ERR_REQUIRE_ESM') {
      return import(`${pathToFileURL(entryPath).href}?t=${Date.now()}`);
    }
    throw error;
  }
}

function getEntryFactory(entryModule) {
  if (typeof entryModule === 'function') {
    return entryModule;
  }

  if (entryModule && typeof entryModule.createWebApp === 'function') {
    return entryModule.createWebApp;
  }

  if (entryModule && typeof entryModule.default === 'function') {
    return entryModule.default;
  }

  if (entryModule && entryModule.default && typeof entryModule.default.createWebApp === 'function') {
    return entryModule.default.createWebApp;
  }

  throw new Error('Web entry must export a function or createWebApp(context).');
}

function normalizeStaticMount(mount, rootPath) {
  if (!mount.route || !mount.dir) {
    throw new Error('Each static mount must include route and dir.');
  }

  let route = mount.route.startsWith('/') ? mount.route : `/${mount.route}`;
  if (!route.endsWith('/')) {
    route += '/';
  }

  return {
    ...mount,
    route,
    dirPath: resolveInside(rootPath, mount.dir, `staticMount ${route}`)
  };
}

function validateManifest(manifest, webRoot, entryPath, source, mode = 'server-entry') {
  const safeManifest = manifest && typeof manifest === 'object' ? manifest : {};
  const root = safeManifest.root || safeManifest.siteRoot || 'public';
  const rootPath = resolveInside(webRoot, root, 'web app root');

  let pages = Array.isArray(safeManifest.pages) ? safeManifest.pages : [];
  if (pages.length === 0 && fs.existsSync(path.join(rootPath, 'index.html'))) {
    pages = [{ route: '/', file: 'index.html', cacheControl: 'no-store' }];
  }

  const pageMap = new Map(pages.map((page) => {
    if (!page.route || !page.file) {
      throw new Error(`Invalid page mapping: ${JSON.stringify(page)}`);
    }

    resolveInside(rootPath, page.file, `page ${page.route}`);
    return [normalizeRoute(page.route), page];
  }));

  const staticMounts = (Array.isArray(safeManifest.staticMounts) ? safeManifest.staticMounts : [])
    .map((mount) => normalizeStaticMount(mount, rootPath))
    .sort((a, b) => b.route.length - a.route.length);

  if (safeManifest.fallbackPage) {
    resolveInside(rootPath, safeManifest.fallbackPage, 'fallbackPage');
  }

  return {
    name: safeManifest.name || path.basename(webRoot),
    mode,
    source,
    webRoot,
    entryPath,
    rootPath,
    pages,
    pageMap,
    staticMounts,
    fallbackPage: safeManifest.fallbackPage || '',
    staticSite: safeManifest.staticSite && typeof safeManifest.staticSite === 'object'
      ? safeManifest.staticSite
      : null,
    securityHeaders: safeManifest.securityHeaders && typeof safeManifest.securityHeaders === 'object'
      ? safeManifest.securityHeaders
      : {},
    handleRequest: typeof safeManifest.handleRequest === 'function' ? safeManifest.handleRequest : null
  };
}

function createStaticManifest(webGitConfig, webRoot, entryPath, mode, source) {
  const staticEntry = getStaticEntry(webGitConfig);
  const staticRoot = getStaticRoot(webGitConfig);
  const spaFallback = webGitConfig.spaFallback ?? (mode === 'static-spa');
  const htmlCacheControl = webGitConfig.htmlCacheControl || 'no-store';
  const staticCacheControl = webGitConfig.staticCacheControl || 'public, max-age=300';

  return validateManifest({
    name: webGitConfig.name || path.basename(webRoot),
    root: staticRoot,
    pages: [
      {
        route: '/',
        file: staticEntry,
        cacheControl: htmlCacheControl
      }
    ],
    fallbackPage: spaFallback ? staticEntry : '',
    staticSite: {
      enabled: true,
      htmlCacheControl,
      staticCacheControl,
      spaFallback
    }
  }, webRoot, entryPath, source, mode);
}

async function loadWebApp(config) {
  const webGitConfig = config.git && config.git.web ? config.git.web : {};
  const { webRoot, source, mode, entryPath } = chooseWebRoot(webGitConfig);

  if (mode === 'static-spa' || mode === 'static-site') {
    return createStaticManifest(webGitConfig, webRoot, entryPath, mode, source);
  }

  const entryModule = await loadEntryModule(entryPath);
  const createWebApp = getEntryFactory(entryModule);
  const manifest = await Promise.resolve(createWebApp({
    frameworkRoot: projectRoot,
    webRoot,
    config
  }));

  return validateManifest(manifest, webRoot, entryPath, source, mode);
}

module.exports = {
  loadWebApp,
  isPathInside
};
