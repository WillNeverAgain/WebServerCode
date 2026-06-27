# Windows Dual-Git HTML Server Framework

这是一个 Windows 端通用网页服务器框架。它把“服务器框架”和“网页内容”拆成两套 Git：

- **服务器框架仓库**：当前目录，负责 Node HTTP 服务、配置、Git 同步、Windows 计划任务、cloudflared tunnel。
- **网页仓库**：独立仓库，负责 HTML、静态资源和一个运行入口文件。框架启动时会调用这个入口，由入口告诉框架该如何托管页面。

Cloudflare 的命令行工具名是 `cloudflared`，不是 `cloudfared`。

## 核心结构

```text
config/
  site.config.json              # 服务器框架配置；包含网页仓库 Git 配置
  cloudflared.generated.yml     # 生成文件，不纳入 Git
examples/
  web-repo/                     # 示例网页仓库结构
src/
  server.js                     # HTTP 框架
  webapp.js                     # 加载网页仓库入口
scripts/
  update-from-git.ps1           # 每日更新框架仓库和网页仓库
  sync-web-repo.ps1             # 仅同步网页仓库
  start-server.ps1
  start-cloudflared.ps1
logs/
webapps/
  current/                      # 默认网页仓库 clone 位置；不纳入框架 Git
```

## 服务器框架配置

主配置在 `config/site.config.json`。

```json
{
  "server": {
    "host": "127.0.0.1",
    "port": 8787,
    "enforceHost": true,
    "allowedHosts": ["localhost", "127.0.0.1", "::1"]
  },
  "site": {
    "domain": "html.example.com"
  },
  "git": {
    "dailyTime": "03:20",
    "framework": {
      "enabled": true,
      "localPath": ".",
      "remote": "origin",
      "branch": "main"
    },
    "web": {
      "enabled": true,
      "url": "https://github.com/you/your-web-repo.git",
      "localPath": "webapps/current",
      "remote": "origin",
      "branch": "main",
      "entry": "server-entry.js",
      "cloneIfMissing": true,
      "pullOnStart": false,
      "fallbackToBundledExample": true,
      "bundledExamplePath": "examples/web-repo"
    },
    "afterUpdate": {
      "restartServer": true,
      "restartCloudflared": true
    }
  }
}
```

关键点：

- `git.framework` 是服务器框架仓库的 Git 配置。
- `git.web` 是网页仓库的 Git 配置，放在服务器框架的 config 内。
- `git.web.localPath` 是网页仓库 clone 到本机的位置，默认 `webapps/current`。
- `git.web.entry` 是网页仓库入口文件。框架启动时会加载并调用它。
- `git.web.fallbackToBundledExample` 为 `true` 时，如果网页仓库还没 clone，会使用 `examples/web-repo` 作为演示页面。

## 网页仓库规范

网页仓库至少需要一个入口文件，默认叫 `server-entry.js`：

```text
your-web-repo/
  server-entry.js
  public/
    index.html
    status.html
    assets/
      site.css
```

入口文件示例：

```js
module.exports = function createWebApp(context) {
  return {
    name: 'MyWebApp',
    root: 'public',
    fallbackPage: 'index.html',
    pages: [
      { route: '/', file: 'index.html', cacheControl: 'no-store' },
      { route: '/status', file: 'status.html', cacheControl: 'no-store' }
    ],
    staticMounts: [
      { route: '/assets/', dir: 'assets', cacheControl: 'public, max-age=300' }
    ]
  };
};
```

入口可以导出 CommonJS 函数、ESM default 函数，或 `{ createWebApp }`。

返回 manifest 字段：

- `name`：网页应用名，健康检查会显示。
- `root`：网页仓库内的站点根目录。
- `pages`：精确路由到 HTML 文件的映射。
- `staticMounts`：静态资源目录映射。
- `fallbackPage`：未命中路由时返回的页面，适合 SPA。
- `securityHeaders`：网页仓库额外响应头。
- `handleRequest`：可选动态处理函数，静态文件处理前调用。

## 本地启动

需要 Node.js 18 或更高版本。

```powershell
.\scripts\start-server.ps1
```

One-click startup:

```powershell
.\scripts\start-all.ps1
.\scripts\start-all.ps1 -WebSyncStallTimeoutSeconds 180 -WebSyncRetries 3
.\scripts\start-all.ps1 -NoCloudflared
.\scripts\start-all.ps1 -NoCloudflaredSetup
```

During startup, web repository sync prints live Git clone/fetch/pull progress. If no new output is seen for the configured stall timeout, the Git process is stopped and retried. Defaults: 120 seconds and 2 retries.

cloudflared tunnel startup is enabled by default through `cloudflared.autoStart: true` in `config/site.config.json`. Use `-NoCloudflared` for a one-time local-only startup, or set `cloudflared.autoStart` to `false` to disable it by config.

cloudflared installation and tunnel setup are also integrated by default through `cloudflared.autoSetup: true`. Startup validates the configured `tunnelName`, reconciles the real tunnel ID and credentials in `config/cloudflared.local.json`, generates `config/cloudflared.generated.yml`, and ensures the DNS route. Use `-NoCloudflaredSetup` to skip only setup while still allowing an already-configured tunnel to start.

后台运行：

```powershell
.\scripts\start-server.ps1 -Background
```

访问：

```text
http://127.0.0.1:8787/
http://127.0.0.1:8787/_health
```

如果 `git.web.url` 还没配置，框架会使用 `examples/web-repo` 作为演示网页。

## 同步 Git

只同步网页仓库：

```powershell
.\scripts\sync-web-repo.ps1
```

Show live progress and retry stalled sync:

```powershell
.\scripts\sync-web-repo.ps1 -ShowProgress -StallTimeoutSeconds 120 -MaxRetries 2
```

同步框架仓库和网页仓库：

```powershell
.\scripts\update-from-git.ps1
```

安装每日自动更新任务：

```powershell
.\scripts\install-scheduled-tasks.ps1
```

连同 cloudflared 登录后自动启动：

```powershell
.\scripts\install-scheduled-tasks.ps1 -IncludeCloudflared
```

## cloudflared tunnel

首次配置需要你的域名已经托管到 Cloudflare。

```powershell
.\scripts\install-cloudflared.ps1 -UseWinget
.\scripts\setup-cloudflared.ps1 -Login -CreateTunnel
```

把生成的 tunnel UUID 填进 `config/site.config.json`：

```json
// config/cloudflared.local.json
{
  "schemaVersion": 1,
  "tunnelId": "<Tunnel-UUID>",
  "credentialsFile": "%USERPROFILE%\\.cloudflared\\<Tunnel-UUID>.json"
}
```

Runtime tunnel state is stored in `config/cloudflared.local.json`, which is not tracked by Git. Keep stable settings such as `tunnelName`, `domain`, protocol, and paths in `config/site.config.json`; run `.\scripts\ensure-cloudflared.ps1` to validate tunnel name/id/credentials/DNS and update local state automatically.

然后创建 DNS 路由并启动：

```powershell
.\scripts\setup-cloudflared.ps1 -RouteDns
.\scripts\start-server.ps1 -Background
.\scripts\start-cloudflared.ps1 -Background
```

参考官方文档：

- https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/
- https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/create-local-tunnel/
