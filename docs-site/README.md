# Heeler docs site

The user guides at <https://docs.heeler.bybee.dev>. [Fumadocs](https://fumadocs.dev)
on Astro (the Base UI flavour, `@fumadocs/base-ui`, with its Spacious layout, as
a React island; Tailwind CSS 4), built to static files and deployed as an
assets-only Cloudflare Worker, the same way as `landing/`.

It is self-contained: nothing outside this directory imports from it, and it
imports nothing from `landing/` (the fonts and logo are copies).
`.github/workflows/docs-site.yml` runs for `docs-site/**`, `docs/guides/**`, and the root `Makefile`;
`ci.yml` and `ci-node.yml` include neither path.

## Commands

Use Node 22.18 or newer and pnpm 11.11.0 (pinned in `package.json`). From the repository root:

```bash
make docs-install     # install locked dependencies when needed
cd docs-site
pnpm run dev          # start the dev server
# Optional: pnpm run dev --host 0.0.0.0 --port 4322
```

Open the local URL printed by Astro (normally <http://localhost:4321>). `make docs-install` installs dependencies without starting the server. Install pnpm using [its installation guide](https://pnpm.io/installation) if it is not on your PATH.

For individual commands, run these in `docs-site/`:

```bash
pnpm install --frozen-lockfile # install the committed dependency versions
pnpm run dev                  # local dev server with hot reload
pnpm test                     # unit tests for the Markdown pipeline (node:test)
pnpm run check                # astro check (typechecks .astro and .ts files)
pnpm run build                # static build into dist/
pnpm run check:links          # after build: internal links, #anchors, published page set
pnpm run preview              # serve dist/ locally
pnpm run deploy               # wrangler deploy (needs Cloudflare credentials)
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

On wide screens the Spacious layout scrolls the article inside its panel, not
the window, so neither the browser nor Astro restores that position.
`src/components/panel-scroll.ts` remembers it for each history entry and
restores it on Back and Forward (also between `#fragment` entries of one page);
a new page or `#fragment` scrolls the panel instead. It also scrolls the panel
for the scroll keys (Page Up and Page Down, Space, the arrow keys, Home, and
End) while nothing has focus, which the browser would send to the window.

After changing navigation, serve the production build and check home → guide →
another guide → Back, search-result navigation, and 404 → home. The sidebar DOM
node must stay the same while the title, article, table of contents, active
sidebar link, and "Edit on GitHub" destination update. On a wide window, also
check Back after a table-of-contents click (also after then clicking the same
page in the sidebar) and Page Down right after a page loads. Also check code
copying, theme retention, and the mobile navigation drawer (it takes focus when
it opens and keeps it until it closes).

## Layout

| Path | What it holds |
| --- | --- |
| `src/guides.json` | Which guides are published, their sidebar groups and order, sidebar label overrides, and each page's Lucide icon. |
| `src/content.config.ts` | Content collections: `guides` (read from `../docs/guides`) and `pages` (`content/`). |
| `src/lib/markdown.ts` | Remark/rehype plugins that adapt the GitHub-flavoured guides (see below). Tests in `markdown.test.ts`. |
| `src/lib/source.ts` | Fumadocs page source and page tree built from both collections. |
| `src/components/docs.tsx` | The Fumadocs shell: nav, sidebar, search, theme switch, page header, "Edit on GitHub". |
| `src/components/panel-scroll.ts` | Saves and restores the article's scroll position (see above). |
| `src/components/guide-card.tsx` | `<GuideCard>` for `content/index.mdx`: a card with a guide's sidebar label and icon. |
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
2. Add `<slug>` to a section in `src/guides.json` with a
   [Lucide](https://lucide.dev/icons) icon under `icons`, plus a short
   sentence-case sidebar label under `sidebarTitles` if the H1 is long or title
   case. Labels should fit on one sidebar line.
3. Add `<GuideCard slug="<slug>">One sentence.</GuideCard>` to its section in
   `content/index.mdx`. The card takes its title and icon from `src/guides.json`.
4. Run `pnpm run build && pnpm run check:links`. The checker fails if a page is
   missing, an unlisted page is emitted, or a link or anchor does not resolve.

## Design

The layout follows <https://fumadocs.dev/docs>: the Spacious layout, a block
table of contents, and Lucide icons in the sidebar. The palette in
`src/styles/global.css` sets Fumadocs' `--color-fd-*` variables: the dark
neutrals come from the landing page's Substrate tokens
(`landing/src/styles/substrate/tokens/colors.css`), and the light ones are
plain greys in the same roles. The one brand hue is teal, set by
`--color-fd-primary` in `:root` (light) and `.dark`; it marks the active
sidebar and table-of-contents items, link underlines, focus rings, and
selection. Teal is about as light as the muted grey of the other items, so the
active ones also get a cue that needs no colour (medium weight in the sidebar,
a bar beside the table of contents); keep it when changing the palette.
Callouts keep the Substrate status hues. Check text contrast (4.5:1) on the
panel and on the sidebar's active tint when changing it. The theme follows the
system setting; readers can switch it in the header's options menu (in the
sidebar drawer on phones).

The Geist and Geist Mono variable fonts in `src/styles/fonts/` and
`public/logo.png` / `public/favicon.png` are copies of the files in `landing/`.
The fonts come from the `geist` npm package (SIL Open Font License 1.1,
`LICENSE.txt` alongside them).

## Deployment

`wrangler.toml` describes an assets-only Worker (`heeler-docs`) bound to the
`docs.heeler.bybee.dev` custom domain. Pages are emitted as `dist/<slug>.html`
(`build.format: 'file'`), which Workers serves at `/<slug>`, and
`dist/404.html` answers unmatched paths.

A push to `main` that touches `docs-site/**`, `docs/guides/**`, the root `Makefile`, or the docs site workflow deploys automatically, using the same `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` repository secrets as the landing page.

For a manual deploy, `pnpm exec wrangler login` once, then `pnpm run build && pnpm run deploy`.
