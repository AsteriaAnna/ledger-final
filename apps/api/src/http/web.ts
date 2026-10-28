import express, { type Express } from 'express';
import { statSync } from 'node:fs';
import { join, resolve, basename } from 'node:path';

// Optional same-origin delivery of this release's compiled Web code only.
// There is no general file-serving root, upload directory or SPA catch-all.
export function registerWeb(app: Express, directory?: string): void {
  if (!directory) return;
  const root = resolve(directory);
  const index = join(root, 'index.html');
  if (!statSync(index).isFile() || !statSync(join(root, 'assets')).isDirectory()) {
    throw new Error('WEB_DIST_PATH must contain a built index.html and assets directory');
  }
  app.use('/assets', express.static(join(root, 'assets'), {
    dotfiles: 'ignore', index: false, redirect: false,
    setHeaders(res, path) {
      const fingerprinted = /-[A-Za-z0-9_-]{8,}\.(js|css)$/.test(basename(path));
      res.setHeader('Cache-Control', fingerprinted ? 'public, max-age=31536000, immutable' : 'no-cache');
      res.setHeader('X-Content-Type-Options', 'nosniff');
    },
  }));
  const html = (_req: express.Request, res: express.Response) => {
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Referrer-Policy', 'same-origin');
    res.sendFile(index);
  };
  // Existing navigation uses URL hashes, so refreshes still request '/'.
  app.get('/', html);
  app.get('/index.html', html);
}
