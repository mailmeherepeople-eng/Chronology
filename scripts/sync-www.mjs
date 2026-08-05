// Rebuilds www/ from the shippable payload. There is no bundler: www/ is a
// straight copy of the seven paths below and nothing else. Run via `npm run sync`.
import { rmSync, mkdirSync, cpSync, statSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const www = join(root, 'www');

const PATHS = ['index.html', 'data', 'fonts', 'images', 'sounds', 'videos', 'js'];

rmSync(www, { recursive: true, force: true });
mkdirSync(www);

for (const p of PATHS) {
  const src = join(root, p);
  const dest = join(www, p);
  if (statSync(src).isDirectory()) cpSync(src, dest, { recursive: true });
  else cpSync(src, dest);
  console.log(`copied ${p}`);
}
console.log('www/ rebuilt');
