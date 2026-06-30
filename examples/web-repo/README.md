# Example Web Repository

This directory shows the advanced `server-entry` web repository shape.

```json
"git": {
  "web": {
    "mode": "server-entry",
    "url": "https://github.com/you/your-web-repo.git",
    "localPath": "webapps/current",
    "branch": "main",
    "entry": "server-entry.js"
  }
}
```

The framework loads `server-entry.js`, calls the exported function, and serves
the returned manifest.

For a web repository that only has `index.html`, use the static mode instead:

```json
"git": {
  "web": {
    "mode": "static-spa",
    "url": "https://github.com/you/your-static-web-repo.git",
    "localPath": "webapps/current",
    "branch": "main",
    "staticEntry": "index.html",
    "staticRoot": "."
  }
}
```

`mode: "auto"` first tries `server-entry.js`; if it is missing, it falls back
to `staticEntry`.
