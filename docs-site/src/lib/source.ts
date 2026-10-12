import { type CollectionEntry, getCollection, render } from 'astro:content';
import { structure, type StructuredData } from 'fumadocs-core/mdx-plugins';
import { replaceSource } from 'fumadocs-core/mdx-plugins/stringifier';
import { loader, type StaticSource } from 'fumadocs-core/source';
import { githubRepo, guideSections, guidesDir, sidebarTitles } from './guides.ts';
import type { Root as MdastRoot } from 'mdast';
import { extractTitle, htmlNodes } from './markdown.ts';

type Entry = CollectionEntry<'guides'> | CollectionEntry<'pages'>;

interface DocsPageData {
  title: string;
  description: string;
  /** Source file on GitHub, for the "Edit on GitHub" link. */
  sourceUrl: string;
  entry: Entry;
}

/** Fumadocs page source: the site's own pages plus the published guides, in one flat tree. */
export const source = loader({
  source: await createSource(),
  baseUrl: '/',
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
 * Search records for a page. A guide's H1 is dropped as it is on the page, and
 * so is raw HTML (the screenshots), which results would otherwise render.
 * Records are sliced from the source text, so HTML is blanked through
 * Fumadocs' source replacements rather than removed from the tree.
 */
export function getStructuredData(entry: Entry): StructuredData {
  const searchTransform = () => (tree: MdastRoot, file: Parameters<typeof replaceSource>[0]) => {
    extractTitle(tree);
    for (const node of htmlNodes(tree)) replaceSource(file, node, '', 'search');
  };
  return structure(entry.body ?? '', [searchTransform]);
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
      data: { title, description, sourceUrl: `${githubRepo}/blob/main/${guidesDir}/${path}`, entry },
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

function basename(filePath: string | undefined): string {
  const name = filePath?.split('/').at(-1);
  if (name === undefined || name === '') throw new Error(`Content entry has no file path: ${filePath}`);
  return name;
}
