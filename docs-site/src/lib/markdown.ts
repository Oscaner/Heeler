// Markdown pipeline for the guides in docs/guides/.
//
// The guides are written for GitHub: no frontmatter, a leading `# Title`, links
// between `.md` files, and GitHub alert blockquotes. These plugins adapt them
// at build time so the files themselves stay untouched. The string helpers are
// pure and covered by `pnpm test`; the plugins only walk trees and apply them.

import { posix, relative, sep } from 'node:path';
import type { Element, ElementContent, Root as HastRoot, RootContent } from 'hast';
import type { Html, Nodes as MdastNodes, Root as MdastRoot } from 'mdast';
import { githubRepo, guideImagesDir, guidesDir, publishedGuides } from './guides.ts';

/** The parts of a vfile these plugins touch (Astro stores frontmatter under `data.astro`). */
interface MarkdownFile {
  path?: string;
  data: { astro?: { frontmatter?: Record<string, unknown> } };
}

export interface GuidePluginOptions {
  /** Absolute path of the repository root. */
  repoRoot: string;
  /** Whether a repo-relative path is a directory (GitHub uses /tree/ for those). */
  isDirectory: (repoPath: string) => boolean;
}

// ---------------------------------------------------------------------------
// Links

const schemePattern = /^[a-z][a-z0-9+.-]*:/i;
const guidePattern = new RegExp(`^${guidesDir}/([^/]+)\\.md$`);

/**
 * Percent-encodes each path segment canonically: `my file` becomes `my%20file`
 * and an existing `%23` stays `%23`. `undefined` for a malformed escape.
 */
function encodePath(path: string): string | undefined {
  try {
    return path
      .split('/')
      .map((segment) => encodeURIComponent(decodeURIComponent(segment)))
      .join('/');
  } catch {
    return undefined;
  }
}

/** Inverse of `encodePath` for an already canonical path (cannot throw). */
function decodePath(path: string): string {
  return path.split('/').map(decodeURIComponent).join('/');
}

/**
 * Resolves a link written in a guide to its URL on the docs site.
 *
 * `sourcePath` is the guide's repo-relative path. Returns `undefined` when the
 * link must stay as written: absolute URLs, `mailto:`, in-page `#anchors`, and
 * paths that climb out of the repository. A `?query` survives only on GitHub
 * URLs (where `?plain=1` means something); site routes drop it.
 */
export function resolveGuideHref(
  href: string,
  sourcePath: string,
  isDirectory: GuidePluginOptions['isDirectory'],
): string | undefined {
  if (href === '' || href.startsWith('#') || href.startsWith('//') || schemePattern.test(href)) {
    return undefined;
  }

  const hashIndex = href.indexOf('#');
  const beforeHash = hashIndex === -1 ? href : href.slice(0, hashIndex);
  const fragment = hashIndex === -1 ? '' : href.slice(hashIndex);
  const queryIndex = beforeHash.indexOf('?');
  const pathPart = queryIndex === -1 ? beforeHash : beforeHash.slice(0, queryIndex);
  const query = queryIndex === -1 ? '' : beforeHash.slice(queryIndex);

  // Resolve on encoded segments so an escaped `/` (`%2F`) stays inside its segment.
  const encoded = encodePath(pathPart);
  const sourceDir = encodePath(posix.dirname(sourcePath));
  if (encoded === undefined || sourceDir === undefined) return undefined;

  // GitHub resolves a leading `/` against the repository root.
  const joined = encoded.startsWith('/') ? encoded.slice(1) : posix.join(sourceDir, encoded);
  const target = posix.normalize(joined).replace(/\/+$/, '');
  if (target === '..' || target.startsWith('../')) return undefined;
  const plainTarget = decodePath(target);

  const guide = guidePattern.exec(plainTarget)?.[1];
  if (guide !== undefined && publishedGuides.includes(guide)) {
    return `/${guide}${fragment}`;
  }

  if (plainTarget.startsWith(`${guideImagesDir}/`)) {
    return `/images/${target.slice(guideImagesDir.length + 1)}`;
  }

  if (target === '.' || target === '') return `${githubRepo}${fragment}`;
  const kind = pathPart.endsWith('/') || isDirectory(plainTarget) ? 'tree' : 'blob';
  return `${githubRepo}/${kind}/main/${target}${query}${fragment}`;
}

/**
 * Rewrites `href`, `src`, and `srcset` attributes in a raw HTML fragment (the
 * guides embed `<a><img></a>`). `data-src` and similar attributes are left alone.
 */
export function rewriteHtmlLinks(html: string, rewrite: (href: string) => string | undefined): string {
  return html.replace(
    /(?<![\w-])(href|src|srcset)\s*=\s*(["'])(.*?)\2/gi,
    (match, attribute: string, quote: string, value: string) => {
      const next = attribute.toLowerCase() === 'srcset' ? rewriteSrcset(value, rewrite) : rewrite(value);
      return next === undefined ? match : `${attribute}=${quote}${next}${quote}`;
    },
  );
}

/** Rewrites the URL of each `url descriptor` candidate in a `srcset` value. */
function rewriteSrcset(value: string, rewrite: (href: string) => string | undefined): string {
  return value
    .split(',')
    .map((candidate) => {
      const [url = '', ...descriptors] = candidate.trim().split(/\s+/);
      return [rewrite(url) ?? url, ...descriptors].join(' ');
    })
    .join(', ');
}

/** Repo-relative POSIX path of a guide, or `undefined` for files outside docs/guides/. */
function guideSourcePath(file: MarkdownFile, repoRoot: string): string | undefined {
  if (typeof file.path !== 'string') return undefined;
  const repoPath = relative(repoRoot, file.path).split(sep).join('/');
  return repoPath.startsWith(`${guidesDir}/`) ? repoPath : undefined;
}

function walk(node: MdastNodes, visit: (node: MdastNodes) => void): void {
  visit(node);
  if ('children' in node) {
    for (const child of node.children) walk(child, visit);
  }
}

/** Remark plugin: points guide links at site routes, served images, or GitHub. */
export function remarkGuideLinks({ repoRoot, isDirectory }: GuidePluginOptions) {
  return (tree: MdastRoot, file: MarkdownFile) => {
    const sourcePath = guideSourcePath(file, repoRoot);
    if (sourcePath === undefined) return;
    const rewrite = (href: string) => resolveGuideHref(href, sourcePath, isDirectory);

    walk(tree, (node) => {
      if (node.type === 'link' || node.type === 'definition' || node.type === 'image') {
        node.url = rewrite(node.url) ?? node.url;
      } else if (node.type === 'html') {
        node.value = rewriteHtmlLinks(node.value, rewrite);
      }
    });
  };
}

// ---------------------------------------------------------------------------
// Title and description

/** Plain text of a node: link and emphasis syntax drops away, code keeps its text. */
export function plainText(node: MdastNodes): string {
  if (node.type === 'text' || node.type === 'inlineCode') return node.value;
  if (node.type === 'break') return ' ';
  if ('children' in node) return node.children.map(plainText).join('');
  return '';
}

/** Collapses whitespace and trims to `max` characters on a word boundary. */
export function summarize(text: string, max = 160): string {
  const flat = text.replace(/\s+/g, ' ').trim();
  if (flat.length <= max) return flat;
  const cut = flat.slice(0, max - 1);
  const lastSpace = cut.lastIndexOf(' ');
  return `${(lastSpace > 0 ? cut.slice(0, lastSpace) : cut).replace(/[\s,.;:]+$/, '')}…`;
}

/**
 * Drops a trailing lead-in sentence such as "The result is:", which only makes
 * sense next to the block it introduces. Text with no earlier sentence is kept.
 */
export function dropLeadIn(text: string): string {
  const flat = text.replace(/\s+/g, ' ').trim();
  if (!flat.endsWith(':')) return flat;
  const end = Math.max(flat.lastIndexOf('. '), flat.lastIndexOf('! '), flat.lastIndexOf('? '));
  return end === -1 ? flat : flat.slice(0, end + 1);
}

/**
 * Takes the guide's leading `# Title` out of the tree and returns it with the
 * first prose paragraph after it. The page layout renders both.
 */
export function extractTitle(tree: MdastRoot): { title?: string; description?: string } {
  const index = tree.children.findIndex((node) => node.type === 'heading' && node.depth === 1);
  if (index === -1) return {};

  const [heading] = tree.children.splice(index, 1);
  const title = heading === undefined ? undefined : plainText(heading).trim();
  // Skip paragraphs with no text of their own, such as a lone screenshot.
  const prose = tree.children
    .slice(index)
    .filter((node) => node.type === 'paragraph')
    .map((node) => plainText(node).trim())
    .find((text) => text !== '');
  const description = prose === undefined ? undefined : summarize(dropLeadIn(prose));
  return { title, description };
}

/** Raw HTML nodes at any depth (the guides' embedded `<a><img></a>` screenshots, `<details>`). */
export function htmlNodes(node: MdastNodes): Html[] {
  if (node.type === 'html') return [node];
  return 'children' in node ? node.children.flatMap(htmlNodes) : [];
}

/**
 * Remark plugin: moves a guide's H1 and lead paragraph into frontmatter, where
 * Astro exposes them as `entry.rendered.metadata.frontmatter`. Runs after
 * heading ids are assigned, so the remaining ids match GitHub's.
 */
export function remarkGuideTitle({ repoRoot }: Pick<GuidePluginOptions, 'repoRoot'>) {
  return (tree: MdastRoot, file: MarkdownFile) => {
    if (guideSourcePath(file, repoRoot) === undefined) return;
    const { title, description } = extractTitle(tree);
    file.data.astro ??= {};
    const frontmatter = (file.data.astro.frontmatter ??= {});
    if (title) frontmatter.title ??= title;
    if (description) frontmatter.description ??= description;
  };
}

// ---------------------------------------------------------------------------
// GitHub alerts

type AlertKind = 'NOTE' | 'TIP' | 'IMPORTANT' | 'WARNING' | 'CAUTION';

/** Fumadocs callout type, label, and Lucide icon paths (24x24) for each alert. */
const alerts: Record<AlertKind, { type: string; label: string; icon: string[] }> = {
  NOTE: { type: 'info', label: 'Note', icon: ['circle:12,12,10', 'M12 16v-4', 'M12 8h.01'] },
  TIP: {
    type: 'idea',
    label: 'Tip',
    icon: [
      'M15 14c.2-1 .7-1.7 1.5-2.5 1-.9 1.5-2.2 1.5-3.5A6 6 0 0 0 6 8c0 1 .2 2.2 1.5 3.5.7.7 1.3 1.5 1.5 2.5',
      'M9 18h6',
      'M10 22h4',
    ],
  },
  IMPORTANT: {
    type: 'info',
    label: 'Important',
    icon: [
      'M22 17a2 2 0 0 1-2 2H6.828a2 2 0 0 0-1.414.586l-2.202 2.202A.71.71 0 0 1 2 21.286V5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2z',
      'M12 15h.01',
      'M12 7v4',
    ],
  },
  WARNING: {
    type: 'warning',
    label: 'Warning',
    icon: [
      'm21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3',
      'M12 9v4',
      'M12 17h.01',
    ],
  },
  CAUTION: {
    type: 'error',
    label: 'Caution',
    icon: [
      'M15.312 2a2 2 0 0 1 1.414.586l4.688 4.688A2 2 0 0 1 22 8.688v6.624a2 2 0 0 1-.586 1.414l-4.688 4.688a2 2 0 0 1-1.414.586H8.688a2 2 0 0 1-1.414-.586l-4.688-4.688A2 2 0 0 1 2 15.312V8.688a2 2 0 0 1 .586-1.414l4.688-4.688A2 2 0 0 1 8.688 2z',
      'M12 16h.01',
      'M12 8v4',
    ],
  },
};

const alertPattern = /^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\][^\S\n]*(?:\n|$)/i;

/** Returns the alert kind and the text after the marker, if `text` opens a GitHub alert. */
export function parseAlertMarker(text: string): { kind: AlertKind; rest: string } | undefined {
  const match = alertPattern.exec(text);
  const kind = match?.[1]?.toUpperCase();
  if (match === null || kind === undefined || !(kind in alerts)) return undefined;
  return { kind: kind as AlertKind, rest: text.slice(match[0].length) };
}

function element(tagName: string, properties: Element['properties'], children: ElementContent[] = []): Element {
  return { type: 'element', tagName, properties, children };
}

function alertIcon(kind: AlertKind): Element {
  const { type, icon } = alerts[kind];
  // Same treatment as fumadocs-ui's <Callout> icons: filled with the callout
  // colour, stroked in the card colour (the lightbulb strokes in colour).
  const stroke = type === 'idea' ? 'text-(--callout-color)' : 'text-fd-card';
  const shapes = icon.map((shape) => {
    if (shape.startsWith('circle:')) {
      const [cx, cy, r] = shape.slice('circle:'.length).split(',');
      return element('circle', { cx, cy, r });
    }
    return element('path', { d: shape });
  });
  return lucideIcon(shapes, ['size-5', '-me-0.5', 'shrink-0', 'fill-(--callout-color)', stroke]);
}

/**
 * Rehype plugin: renders `> [!NOTE]`-style blockquotes with the markup and
 * classes of fumadocs-ui's <Callout>, since plain Markdown cannot use the
 * React component.
 */
export function rehypeGithubAlerts() {
  return (tree: HastRoot) => {
    const visit = (parent: HastRoot | Element) => {
      parent.children = parent.children.map((child) => {
        if (child.type !== 'element') return child;
        const callout = child.tagName === 'blockquote' ? toCallout(child) : undefined;
        if (callout) return callout;
        visit(child);
        return child;
      });
    };
    visit(tree);
  };
}

function toCallout(blockquote: Element): Element | undefined {
  const paragraph = blockquote.children.find((child): child is Element => child.type === 'element');
  const first = paragraph?.tagName === 'p' ? paragraph.children[0] : undefined;
  if (paragraph === undefined || first?.type !== 'text') return undefined;
  const marker = parseAlertMarker(first.value);
  if (marker === undefined) return undefined;

  first.value = marker.rest;
  const body = blockquote.children.filter((child) => {
    if (child !== paragraph) return true;
    return paragraph.children.some((node) => node.type !== 'text' || node.value.trim() !== '');
  });

  const { type, label } = alerts[marker.kind];
  return element(
    'div',
    {
      className: 'flex gap-2 my-4 rounded-xl border bg-fd-card p-3 ps-1 text-sm text-fd-card-foreground'.split(' '),
      style: `--callout-color: var(--color-fd-${type}, var(--color-fd-muted))`,
      role: 'note',
      ariaLabel: label,
    },
    [
      element('div', { role: 'none', className: ['w-0.5', 'bg-(--callout-color)/50', 'rounded-sm'] }),
      alertIcon(marker.kind),
      element('div', { className: ['flex', 'flex-col', 'gap-2', 'min-w-0', 'flex-1'] }, [
        element('p', { className: ['font-medium', 'my-0!'] }, [{ type: 'text', value: label }]),
        element('div', { className: ['text-fd-muted-foreground', 'prose-no-margin', 'empty:hidden'] }, body),
      ]),
    ],
  );
}

// ---------------------------------------------------------------------------
// Fumadocs components for plain Markdown

/**
 * Rehype plugin: gives code blocks, tables, and headings the markup of
 * fumadocs-ui's MDX components (<CodeBlock>, its table wrapper, <Heading>),
 * since plain Markdown cannot use React components. MDX files are skipped;
 * there `defaultMdxComponents` does this itself.
 */
export function rehypeFumadocsElements() {
  return (tree: HastRoot, file: Pick<MarkdownFile, 'path'>) => {
    if (file.path?.endsWith('.mdx')) return;
    const visit = (parent: { children: RootContent[] }) => {
      parent.children = parent.children.map((child) => {
        if (child.type === 'element') {
          if (child.tagName === 'pre' && classList(child).includes('shiki')) return toCodeFrame(child);
          if (child.tagName === 'table') {
            return element('div', { className: ['relative', 'overflow-auto', 'prose-no-margin', 'my-6'] }, [child]);
          }
          if (/^h[2-6]$/.test(child.tagName) && typeof child.properties.id === 'string') {
            return toAnchoredHeading(child, child.properties.id);
          }
        }
        // rehypeCode leaves each highlighted block inside a nested root node,
        // which the hast types do not model; descend into anything with children.
        if ('children' in child) visit(child);
        return child;
      });
    };
    visit(tree);
  };
}

/** Like <Heading>: clears the sticky header on fragment jumps and links to itself. */
function toAnchoredHeading(heading: Element, id: string): Element {
  return {
    ...heading,
    properties: { ...heading.properties, className: ['flex', 'scroll-m-28', 'flex-row', 'items-center', 'gap-1'] },
    children: [element('a', { href: `#${id}`, dataCard: '' }, heading.children)],
  };
}

/** A Lucide icon (24x24 viewBox, stroked) built from its shape elements. */
function lucideIcon(shapes: Element[], className: string[]): Element {
  return element(
    'svg',
    {
      xmlns: 'http://www.w3.org/2000/svg',
      viewBox: '0 0 24 24',
      fill: 'none',
      stroke: 'currentColor',
      strokeWidth: '2',
      strokeLinecap: 'round',
      strokeLinejoin: 'round',
      ariaHidden: 'true',
      className,
    },
    shapes,
  );
}

/** Class names of an element; Shiki sets `class` as a string rather than hast's `className`. */
function classList(node: Element): string[] {
  const value = node.properties.className ?? node.properties.class;
  if (Array.isArray(value)) return value.map(String);
  return typeof value === 'string' ? value.split(/\s+/).filter(Boolean) : [];
}

function toCodeFrame(pre: Element): Element {
  // rehypeCode attaches a language icon for <CodeBlock>; it is not an HTML attribute.
  const { icon: _icon, class: _class, className: _className, ...properties } = pre.properties;
  const preClasses = classList(pre);
  return element(
    'figure',
    {
      dir: 'ltr',
      className: 'my-4 bg-fd-card rounded-xl shiki relative border not-prose overflow-hidden text-sm'.split(' '),
      dataCodeFrame: '',
    },
    [
      // Static icon button like <CodeBlock>'s, so it survives island hydration;
      // the page script copies on click and sets data-checked. global.css hides
      // it until hover on pointer devices and gives it its own row on touch.
      element(
        'button',
        {
          type: 'button',
          dataCopyCode: '',
          className:
            'group absolute top-3 right-2 z-2 inline-flex items-center justify-center rounded-md p-1 backdrop-blur-lg text-fd-muted-foreground transition-colors hover:text-fd-accent-foreground data-checked:text-fd-accent-foreground'.split(
              ' ',
            ),
        },
        [
          lucideIcon(
            [
              element('rect', { width: '8', height: '4', x: '8', y: '2', rx: '1', ry: '1' }),
              element('path', { d: 'M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2' }),
            ],
            ['size-4', 'group-data-checked:hidden'],
          ),
          lucideIcon([element('path', { d: 'M20 6 9 17l-5-5' })], ['size-4', 'hidden', 'group-data-checked:inline']),
          element('span', { className: ['sr-only'] }, [{ type: 'text', value: 'Copy code' }]),
        ],
      ),
      element(
        'div',
        {
          className: 'text-[0.8125rem] py-3.5 overflow-auto max-h-[600px] fd-scroll-container'.split(' '),
        },
        [
          element(
            'pre',
            {
              ...properties,
              className: [...preClasses, 'min-w-full', 'w-max', '*:flex', '*:flex-col'],
              // Same as <CodeBlock>: keeps the end of each line clear of the
              // button. Set on the <pre> because its .shiki class resets it.
              style: [properties.style, '--padding-right: calc(var(--spacing) * 8)']
                .filter((value) => typeof value === 'string' && value !== '')
                .join('; '),
            },
            pre.children,
          ),
        ],
      ),
    ],
  );
}
