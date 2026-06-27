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

function chooseWebRoot(webGitConfig) {
  const configuredRoot = webGitConfig.localPathResolved || resolveProjectPath(webGitConfig.localPath);
  const entry = webGitConfig.entry || 'server-entry.js';

  if (fs.existsSync(path.join(configuredRoot, entry))) {
    return {
      webRoot: configuredRoot,
      source: 'configured'
    };
  }

  if (webGitConfig.fallbackToBundledExample) {
    const bundledRoot = webGitConfig.bundledExamplePathResolved || resolveProjectPath(webGitConfig.bundledExamplePath);
    if (fs.existsSync(path.join(bundledRoot, entry))) {
      return {
        webRoot: bundledRoot,
        source: 'bundled-example'
      };
    }
  }

  throw new Error(`Web entry not found. Expected ${path.join(configuredRoot, entry)}`);
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

function validateManifest(manifest, webRoot, entryPath, source) {
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
    source,
    webRoot,
    entryPath,
    rootPath,
    pages,
    pageMap,
    staticMounts,
    fallbackPage: safeManifest.fallbackPage || '',
    securityHeaders: safeManifest.securityHeaders && typeof safeManifest.securityHeaders === 'object'
      ? safeManifest.securityHeaders
      : {},
    handleRequest: typeof safeManifest.handleRequest === 'function' ? safeManifest.handleRequest : null
  };
}

async function loadWebApp(config) {
  const webGitConfig = config.git && config.git.web ? config.git.web : {};
  const { webRoot, source } = chooseWebRoot(webGitConfig);
  const entryPath = resolveInside(webRoot, webGitConfig.entry || 'server-entry.js', 'web entry');
  const entryModule = await loadEntryModule(entryPath);
  const createWebApp = getEntryFactory(entryModule);
  const manifest = await Promise.resolve(createWebApp({
    frameworkRoot: projectRoot,
    webRoot,
    config
  }));

  return validateManifest(manifest, webRoot, entryPath, source);
}

module.exports = {
  loadWebApp,
  isPathInside
};
