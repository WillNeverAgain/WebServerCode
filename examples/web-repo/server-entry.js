module.exports = function createWebApp(context) {
  return {
    name: 'ExampleWebApp',
    root: 'public',
    fallbackPage: 'index.html',
    pages: [
      {
        route: '/',
        file: 'index.html',
        cacheControl: 'no-store'
      },
      {
        route: '/status',
        file: 'status.html',
        cacheControl: 'no-store'
      }
    ],
    staticMounts: [
      {
        route: '/assets/',
        dir: 'assets',
        cacheControl: 'public, max-age=300'
      }
    ],
    securityHeaders: {
      'X-Web-App': 'ExampleWebApp'
    }
  };
};
