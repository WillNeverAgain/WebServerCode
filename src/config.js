const fs = require('fs');
const path = require('path');

const projectRoot = path.resolve(__dirname, '..');
const configPath = path.join(projectRoot, 'config', 'site.config.json');

let cachedConfig = null;
let cachedMtimeMs = 0;

function normalizeRoute(route) {
  if (!route || typeof route !== 'string') {
    throw new Error('Route values must be non-empty strings.');
  }

  let normalized = route.startsWith('/') ? route : `/${route}`;
  if (normalized.length > 1 && normalized.endsWith('/')) {
    normalized = normalized.slice(0, -1);
  }
  return normalized;
}

function ensureObject(value, fallback = {}) {
  return value && typeof value === 'object' && !Array.isArray(value) ? value : fallback;
}

function resolveProjectPath(value) {
  if (!value || typeof value !== 'string') {
    return projectRoot;
  }

  const expanded = value.replace(/^%USERPROFILE%/i, process.env.USERPROFILE || '');
  return path.isAbsolute(expanded) ? path.resolve(expanded) : path.resolve(projectRoot, expanded);
}

function validateConfig(config) {
  if (!config || typeof config !== 'object') {
    throw new Error('Config must be a JSON object.');
  }

  if (!config.server || !config.site) {
    throw new Error('Config must include server and site sections.');
  }

  if (!Number.isInteger(config.server.port) || config.server.port < 1 || config.server.port > 65535) {
    throw new Error('server.port must be an integer between 1 and 65535.');
  }

  if (!config.site.domain || typeof config.site.domain !== 'string') {
    throw new Error('site.domain must be configured.');
  }

  config.server.host = config.server.host || '127.0.0.1';
  config.server.allowedHosts = Array.isArray(config.server.allowedHosts) ? config.server.allowedHosts : [];
  config.securityHeaders = config.securityHeaders && typeof config.securityHeaders === 'object'
    ? config.securityHeaders
    : {};

  const legacyUpdate = ensureObject(config.update);
  config.git = ensureObject(config.git);

  config.git.framework = {
    enabled: true,
    localPath: '.',
    remote: legacyUpdate.remote || 'origin',
    branch: legacyUpdate.branch || 'main',
    ...ensureObject(config.git.framework)
  };

  config.git.web = {
    enabled: true,
    url: '',
    localPath: 'webapps/current',
    remote: 'origin',
    branch: 'main',
    entry: 'server-entry.js',
    cloneIfMissing: true,
    pullOnStart: false,
    fallbackToBundledExample: true,
    bundledExamplePath: 'examples/web-repo',
    ...ensureObject(config.git.web)
  };

  config.git.dailyTime = config.git.dailyTime || legacyUpdate.dailyTime || '03:20';
  config.git.afterUpdate = {
    restartServer: legacyUpdate.restartServerAfterUpdate ?? true,
    restartCloudflared: legacyUpdate.restartCloudflaredAfterUpdate ?? true,
    ...ensureObject(config.git.afterUpdate)
  };

  config.git.framework.localPathResolved = resolveProjectPath(config.git.framework.localPath);
  config.git.web.localPathResolved = resolveProjectPath(config.git.web.localPath);
  config.git.web.bundledExamplePathResolved = resolveProjectPath(config.git.web.bundledExamplePath);

  return config;
}

function loadConfig() {
  const stat = fs.statSync(configPath);
  if (cachedConfig && stat.mtimeMs === cachedMtimeMs) {
    return cachedConfig;
  }

  const parsed = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  cachedConfig = validateConfig(parsed);
  cachedMtimeMs = stat.mtimeMs;
  return cachedConfig;
}

function getProjectRoot() {
  return projectRoot;
}

function getConfigPath() {
  return configPath;
}

module.exports = {
  getConfig: loadConfig,
  getProjectRoot,
  getConfigPath,
  normalizeRoute,
  resolveProjectPath
};
