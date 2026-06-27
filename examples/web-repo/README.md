# Example Web Repository

这个目录是一个示例网页仓库。实际使用时，可以把这个目录复制到单独 Git 仓库中，然后在服务器框架的 `config/site.config.json` 里配置：

```json
"git": {
  "web": {
    "url": "https://github.com/you/your-web-repo.git",
    "localPath": "webapps/current",
    "branch": "main",
    "entry": "server-entry.js"
  }
}
```

服务器框架启动时会调用 `server-entry.js`，并按照它返回的 manifest 托管 `public/` 里的页面和静态资源。
