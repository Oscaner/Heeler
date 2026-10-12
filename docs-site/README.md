# Heeler docs site

The user guides at <https://docs.heeler.bybee.dev>. [Fumadocs](https://fumadocs.dev)
on Astro (fumadocs-ui as a React island, Tailwind CSS 4), built to static
files and deployed as an assets-only Cloudflare Worker, the same way as
`landing/`.

It is self-contained: nothing outside this directory imports from it, and it
imports nothing from `landing/` (the fonts and logo are copies).
`.github/workflows/docs-site.yml` runs for `docs-site/**` and `docs/guides/**`;
`ci.yml` and `ci-node.yml` include neither path.

## Commands

```bash
npm install          # once (Node 22.18 or newer)
npm run dev          # local dev server with hot reload
npm test             # unit tests for the Markdown pipeline (node:test)
npm run check        # astro check (typechecks .astro and .ts files)
npm run build        # static build into dist/
npm run check:links  # after build: internal links, #anchors, published page set
npm run preview      # serve dist/ locally
npm run deploy       # wrangler deploy (needs Cloudflare credentials)
```

Astro caches rendered guides in `node_modules/.astro/` and re-renders only
when a guide or `astro.config.mjs` changes. After editing the plugins in
`src/lib/markdown.ts`, run `rm -rf node_modules/.astro` before building. CI
always starts from a clean checkout.

The `Docs` React island persists across client-side navigation, including the
404 page. Astro refreshes its page props; `layout.astro` refreshes its static
article slot before the swap, since persisted island slots are not updated by
Astro. Keep persistence on the island, not on `<body>` or a wrapper.
Only the page content is keyed by pathname, so page-specific TOC observers and
state reset without remounting the sidebar, search, or theme provider.

After changing navigation, serve the production build and check home → guide →
another guide → Back, search-result navigation, and 404 → home. The sidebar DOM
node must stay the same while the title, article, table of contents, active
sidebar link, and "Edit on GitHub" destination update. Also check code copying,
theme retention, and the mobile navigation drawer.

## Layout

| Path | What it holds |
| --- | --- |
| `src/guides.json` | Which guides are published, their sidebar groups and order, and sidebar label overrides. |
| `src/content.config.ts` | Content collections: `guides` (read from `../docs/guides`) and `pages` (`content/`). |
| `src/lib/markdown.ts` | Remark/rehype plugins that adapt the GitHub-flavoured guides (see below). Tests in `markdown.test.ts`. |
| `src/lib/source.ts` | Fumadocs page source and page tree built from both collections. |
| `src/components/docs.tsx` | The Fumadocs shell: nav, sidebar, search, theme switch, page header, "Edit on GitHub". |
| `src/components/layout.astro` | `<head>` metadata and the global stylesheet. |
| `src/pages/[...slug].astro` | Every page, at `/<slug>`. `404.astro` is the not-found page. |
| `src/pages/api/search.json.ts` | Static search index, emitted as `dist/api/search.json`. |
| `src/pages/images/[...path].ts` | Copies `docs/guides/images/**` to `/images/**`. |
| `src/styles/global.css` | Tailwind and Fumadocs CSS, Geist fonts, and the brand palette. |
| `content/index.mdx` | The home page (site-owned). |
| `scripts/check-links.mjs` | Post-build link and route checker (Node built-ins only). |

## Content source

The guides stay in `docs/guides/` as the single source of truth and must keep
rendering on GitHub, so they are not edited for the site: no frontmatter, no
site-specific syntax. The build adapts them instead (`src/lib/markdown.ts`):

- **Title and description.** The leading `# Title` becomes the page title and
  is removed from the body; the first paragraph after it becomes the meta
  description (plain text, about 160 characters).
- **Links.** Relative links are resolved against the guide's path in the
  repository. A published guide becomes `/<slug>` (keeping `#fragment`);
  `docs/guides/images/**` becomes `/images/**`; anything else in the repository
  becomes a GitHub link on `main` (`/blob/` for files, `/tree/` for
  directories, keeping `#L12`-style anchors). This also covers the raw HTML
  `<a><img></a>` screenshots.
- **Heading anchors.** Ids use GitHub's slugger and are assigned before the H1
  is removed, so `guide.md#some-heading` links work the same on both. Smart
  punctuation is off for the same reason.
- **GitHub alerts.** `> [!NOTE]`, `TIP`, `IMPORTANT`, `WARNING`, and `CAUTION`
  render with the markup of Fumadocs' `<Callout>`.
- **Code blocks.** Highlighted by Fumadocs' `rehypeCode` and wrapped in the
  `<CodeBlock>` frame with a copy button. Languages Shiki does not ship (such as
  `sshconfig`) render as plain text.

The `guides` collection's glob loader uses `base: '../docs/guides'`, which
Astro resolves against the project root, so it reads outside `docs-site/`
without extra setup. The dev server also gets `vite.server.fs.allow` for the
repository root.

### Published guides

`overlay-networks`, `tailscale`, `tailscale-userspace`, `zerotier`, `easytier`,
`vps-jump-host-setup`, `vps-jump-host`, `host-routes`, and `windows-setup`.
Maintainer documents in `docs/guides/` (`releasing.md`,
`native-windows-testing.md`), ADRs, and everything else under `docs/` stay
GitHub-only; links to them point at GitHub.

### Adding a guide

1. Write `docs/guides/<slug>.md` for GitHub as usual, starting with `# Title`
   and a paragraph.
2. Add `<slug>` to a section in `src/guides.json`, plus a short sentence-case
   sidebar label under `sidebarTitles` if the H1 is long or title case.
3. Add a card for it to `content/index.mdx`.
4. Run `npm run build && npm run check:links`. The checker fails if a page is
   missing, an unlisted page is emitted, or a link or anchor does not resolve.

## Design

The palette maps the landing page's Substrate tokens
(`landing/src/styles/substrate/tokens/colors.css`) onto Fumadocs' `--color-fd-*`
variables: dark mode uses them directly, light mode is the same neutral ramp
inverted, and hue is reserved for callouts. The theme follows the system
setting, with a light/dark switch in the sidebar.

The Geist and Geist Mono variable fonts in `src/styles/fonts/` and
`public/logo.png` / `public/favicon.png` are copies of the files in `landing/`.
The fonts come from the `geist` npm package (SIL Open Font License 1.1,
`LICENSE.txt` alongside them).

## Deployment

`wrangler.toml` describes an assets-only Worker (`heeler-docs`) bound to the
`docs.heeler.bybee.dev` custom domain. Pages are emitted as `dist/<slug>.html`
(`build.format: 'file'`), which Workers serves at `/<slug>`, and
`dist/404.html` answers unmatched paths.

A push to `main` that touches `docs-site/**` or `docs/guides/**` deploys
automatically, using the same `CLOUDFLARE_API_TOKEN` and
`CLOUDFLARE_ACCOUNT_ID` repository secrets as the landing page.

For a manual deploy, `wrangler login` once, then `npm run build && npm run
deploy`.
