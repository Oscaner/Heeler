import { type CollectionEntry, getCollection, render } from 'astro:content';
import { structure, type StructuredData } from 'fumadocs-core/mdx-plugins';
import { replaceSource } from 'fumadocs-core/mdx-plugins/stringifier';
import { loader, type StaticSource } from 'fumadocs-core/source';
import { lucideIconsPlugin } from 'fumadocs-core/source/plugins/lucide-icons';
import { icons } from 'lucide-react';
import remarkMdx from 'remark-mdx';
import { githubRepo, guideSections, guidesDir, pageIcons, sidebarTitles } from './guides.ts';
import type { Root as MdastRoot } from 'mdast';
import { extractTitle, hiddenForSearch, htmlNodes } from './markdown.ts';

type Entry = CollectionEntry<'guides'> | CollectionEntry<'pages'>;

/** A Lucide icon's component name, such as `Compass`. */
export type IconName = keyof typeof icons;

interface DocsPageData {
  title: string;
  description: string;
  /** Lucide icon for the sidebar and for cards that link to the page (src/guides.json). */
  icon: IconName;
  /** Source file on GitHub, for the "Edit on GitHub" link. */
  sourceUrl: string;
  entry: Entry;
}

/** Fumadocs page source: the site's own pages plus the published guides, in one flat tree. */
export const source = loader({
  source: await createSource(),
  baseUrl: '/',
  plugins: [lucideIconsPlugin()],
  pageTree: {
    transformers: [
      {
        file(node, filePath) {
          const slug = filePath?.replace(/\.mdx?$/, '');
          const label = slug === undefined ? undefined : sidebarTitles[slug];
          return label === undefined ? node : { ...node, name: label };
        },
      },
    ],
  },
});

/**
 * The page tree for the `Docs` island. Its icons are React elements, which
 * cannot cross the island boundary, so they travel as rendered HTML and
 * `deserializePageTree` (in src/components/docs.tsx) turns them back into
 * elements in the browser.
 */
export const serializedPageTree = await source.serializePageTree(source.getPageTree());

/** A page's sidebar label, icon, and URL, for the cards that link to it from content/index.mdx. */
export function pageLink(slug: string): { title: string; icon: IconName; url: string } {
  const page = source.getPage(slug === 'index' ? [] : [slug]);
  if (page === undefined) throw new Error(`There is no page "${slug}" to link to`);
  return { title: sidebarTitles[slug] ?? page.data.title, icon: page.data.icon, url: page.url };
}

/** Sidebar section of a guide, for search result breadcrumbs; undefined for the index. */
export function sectionOf(slug: string): string | undefined {
  return guideSections.find((section) => section.guides.includes(slug))?.title;
}

/**
 * Search records for a page. A guide's H1 is dropped as it is on the page, and
 * so is raw HTML (the screenshots), which results would otherwise render, and
 * a guide's trailing review note and maintainer pointer (the page shows the
 * one as a footer line and drops the other). Records are sliced from the
 * source text, so these are blanked through Fumadocs' source replacements
 * rather than removed from the tree. MDX pages are parsed as MDX, so imports
 * stay out and card text gets in.
 */
export function getStructuredData(entry: Entry): StructuredData {
  const isMdx = entry.filePath?.endsWith('.mdx') ?? false;
  const searchTransform = () => (tree: MdastRoot, file: Parameters<typeof replaceSource>[0]) => {
    extractTitle(tree);
    const hidden = [...htmlNodes(tree), ...(isMdx ? [] : hiddenForSearch(tree))];
    for (const node of hidden) replaceSource(file, node, '', 'search');
  };
  return structure(entry.body ?? '', isMdx ? [remarkMdx, searchTransform] : [searchTransform]);
}

async function createSource() {
  const out: StaticSource<{ pageData: DocsPageData; metaData: { pages: string[] } }> = { files: [] };

  for (const entry of await getCollection('pages')) {
    const path = basename(entry.filePath);
    out.files.push({
      type: 'page',
      path,
      data: {
        ...entry.data,
        icon: iconFor(path),
        sourceUrl: `${githubRepo}/blob/main/docs-site/content/${path}`,
        entry,
      },
    });
  }

  for (const entry of await getCollection('guides')) {
    const path = basename(entry.filePath);
    // remarkGuideTitle moved the H1 and lead paragraph into the frontmatter.
    const frontmatter: Record<string, unknown> = (await render(entry)).remarkPluginFrontmatter;
    const { title, description } = frontmatter;
    if (typeof title !== 'string' || typeof description !== 'string') {
      throw new Error(`${guidesDir}/${path} needs a "# Title" heading followed by a paragraph`);
    }
    out.files.push({
      type: 'page',
      path,
      data: { title, description, icon: iconFor(path), sourceUrl: `${githubRepo}/blob/main/${guidesDir}/${path}`, entry },
    });
  }

  // Sidebar order and grouping: the index, then one separator per section.
  out.files.push({
    type: 'meta',
    path: 'meta.json',
    data: {
      pages: ['index', ...guideSections.flatMap((section) => [`---${section.title}---`, ...section.guides])],
    },
  });

  return out;
}

/** The sidebar icon of a page file, checked here because Fumadocs only warns about unknown names. */
function iconFor(path: string): IconName {
  const slug = path.replace(/\.mdx?$/, '');
  const icon = pageIcons[slug];
  if (icon === undefined) throw new Error(`src/guides.json has no icon for "${slug}"`);
  if (!isIconName(icon)) throw new Error(`src/guides.json: "${icon}" (for "${slug}") is not a Lucide icon name`);
  return icon;
}

function isIconName(name: string): name is IconName {
  return Object.hasOwn(icons, name);
}

function basename(filePath: string | undefined): string {
  const name = filePath?.split('/').at(-1);
  if (name === undefined || name === '') throw new Error(`Content entry has no file path: ${filePath}`);
  return name;
}
