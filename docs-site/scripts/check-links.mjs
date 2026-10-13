#!/usr/bin/env node
// Checks the static build in dist/ (run after `pnpm run build`):
//
// - every internal href/src resolves to an emitted file or page, and every
//   #fragment exists as an id on the target page;
// - the emitted pages are exactly the index plus the guides in src/guides.json,
//   so unpublished docs (releasing, native-windows-testing, ...) never ship;
// - each guide's Markdown (/<slug>.md, for the page actions) exists, and no
//   other Markdown ships;
// - the 404 page and the search index exist.
//
// Node built-ins only. Exits 1 and lists every failure with its source page.

import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const dist = join(root, 'dist');
const failures = [];

if (!existsSync(dist)) {
  console.error('dist/ is missing; run `pnpm run build` first.');
  process.exit(1);
}

/** @param {string} dir @returns {string[]} */
function walk(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    return entry.isDirectory() ? walk(path) : [path];
  });
}

/** @param {string} value */
function decodeEntities(value) {
  return value
    .replace(/&#x([0-9a-f]+);/gi, (_, hex) => String.fromCodePoint(Number.parseInt(hex, 16)))
    .replace(/&#(\d+);/g, (_, dec) => String.fromCodePoint(Number(dec)))
    .replaceAll('&quot;', '"')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&');
}

/**
 * Site route of an emitted HTML file: dist/tailscale.html -> /tailscale, dist/index.html -> /.
 * @param {string} file
 */
function routeOf(file) {
  const path = relative(dist, file).split(sep).join('/').replace(/\.html$/, '');
  return path === 'index' ? '/' : `/${path.replace(/\/index$/, '')}`;
}

const htmlFiles = walk(dist).filter((file) => file.endsWith('.html'));
/** @type {Map<string, { file: string, ids: Set<string>, html: string }>} */
const pages = new Map();
for (const file of htmlFiles) {
  const html = readFileSync(file, 'utf8');
  const ids = new Set([...html.matchAll(/\sid="([^"]*)"/g)].map((match) => decodeEntities(match[1])));
  pages.set(routeOf(file), { file, ids, html });
}

/**
 * Resolves an internal path to a page route, or `asset` for a non-HTML file.
 * `/tailscale.html` and `/guide/index.html` map to their pages (Workers
 * redirects them there), so their fragments are checked too.
 * @param {string} path decoded path
 * @returns {string | undefined}
 */
function resolve(path) {
  const trimmed = path.length > 1 ? path.replace(/\/$/, '') : path;
  const route = trimmed.replace(/(\/index)?\.html$/, '') || '/';
  if (pages.has(route)) return route;
  const file = join(dist, path);
  if (existsSync(file) && statSync(file).isFile()) return 'asset';
  return undefined;
}

/**
 * URLs referenced by a page: href and src values plus each srcset candidate.
 * @param {string} html
 */
function referencesOf(html) {
  return [...html.matchAll(/\s(href|src|srcset)="([^"]*)"/g)].flatMap((match) => {
    const value = decodeEntities(match[2] ?? '');
    if (match[1] !== 'srcset') return [value];
    return value.split(',').map((candidate) => candidate.trim().split(/\s+/)[0] ?? '');
  });
}

// 1. Internal links and fragments.
for (const [route, page] of pages) {
  for (const ref of referencesOf(page.html)) {
    if (ref === '' || /^[a-z][a-z0-9+.-]*:/i.test(ref) || ref.startsWith('//')) continue;
    if (!ref.startsWith('/') && !ref.startsWith('#')) {
      failures.push(`${route}: relative link "${ref}" (guides must link through the site or GitHub)`);
      continue;
    }

    const hashIndex = ref.indexOf('#');
    let path;
    let fragment;
    try {
      path = decodeURIComponent((hashIndex === -1 ? ref : ref.slice(0, hashIndex)).split('?')[0] ?? '');
      fragment = hashIndex === -1 ? '' : decodeURIComponent(ref.slice(hashIndex + 1));
    } catch {
      failures.push(`${route}: malformed URL "${ref}"`);
      continue;
    }
    const target = path === '' ? route : resolve(path);

    if (target === undefined) {
      failures.push(`${route}: "${ref}" does not resolve to an emitted page or file`);
    } else if (fragment !== '' && target !== 'asset' && !pages.get(target)?.ids.has(fragment)) {
      failures.push(`${route}: "${ref}" has no element with id "${fragment}" on ${target}`);
    }
  }
}

// 2. Published routes: exactly the index plus the configured guides.
const config = JSON.parse(readFileSync(join(root, 'src', 'guides.json'), 'utf8'));
/** @type {string[]} */
const guides = config.sections.flatMap((/** @type {{ guides: string[] }} */ section) => section.guides);
const expected = new Set(['/', '/404', ...guides.map((slug) => `/${slug}`)]);
for (const route of expected) {
  if (!pages.has(route)) failures.push(`missing page ${route}`);
}
for (const route of pages.keys()) {
  if (!expected.has(route)) failures.push(`unexpected page ${route} (not listed in src/guides.json)`);
}
for (const route of ['/releasing', '/native-windows-testing']) {
  if (resolve(route) !== undefined) failures.push(`${route} must not be published`);
}
if (!existsSync(join(dist, 'api', 'search.json'))) failures.push('missing search index /api/search.json');

// 3. Guide Markdown for "Copy Markdown" and "Open" (src/pages/[...slug].md.ts).
const markdownFiles = new Set(
  walk(dist)
    .filter((file) => file.endsWith('.md'))
    .map((file) => relative(dist, file).split(sep).join('/')),
);
for (const slug of guides) {
  if (!markdownFiles.has(`${slug}.md`)) failures.push(`missing Markdown /${slug}.md`);
}
for (const file of markdownFiles) {
  if (!guides.includes(file.replace(/\.md$/, ''))) failures.push(`unexpected Markdown /${file} (not a published guide)`);
}

if (failures.length > 0) {
  console.error(`check-links: ${failures.length} problem(s)\n`);
  for (const failure of failures) console.error(`  ${failure}`);
  process.exit(1);
}
console.log(`check-links: ${pages.size} pages and ${markdownFiles.size} guide Markdown files; all internal links and fragments resolve.`);
