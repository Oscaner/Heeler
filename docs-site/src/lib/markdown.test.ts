// Unit tests for the guide pipeline helpers. Run with `pnpm test` (Node's
// built-in runner; Node strips the TypeScript types).

import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import type { Element, Root as HastRoot } from 'hast';
import type { Root as MdastRoot } from 'mdast';
import {
  dropLeadIn,
  extractTitle,
  parseAlertMarker,
  rehypeFumadocsElements,
  rehypeGithubAlerts,
  resolveGuideHref,
  rewriteHtmlLinks,
  htmlNodes,
  summarize,
} from './markdown.ts';

const repo = 'https://github.com/ZingerLittleBee/Heeler';
const source = 'docs/guides/tailscale.md';
const directories = new Set(['docs/adr', 'Sources/Heeler']);
const resolve = (href: string) => resolveGuideHref(href, source, (path) => directories.has(path));

describe('resolveGuideHref', () => {
  it('routes published guides to flat site URLs and keeps the fragment', () => {
    assert.equal(resolve('overlay-networks.md#prepare-the-host'), '/overlay-networks#prepare-the-host');
    assert.equal(resolve('tailscale-userspace.md'), '/tailscale-userspace');
    assert.equal(resolve('./zerotier.md'), '/zerotier');
  });

  it('sends unpublished files to GitHub on main, keeping line anchors', () => {
    assert.equal(
      resolve('native-windows-testing.md#4-test-device-key-authentication'),
      `${repo}/blob/main/docs/guides/native-windows-testing.md#4-test-device-key-authentication`,
    );
    assert.equal(resolve('../agents/overlay-network-guides.md'), `${repo}/blob/main/docs/agents/overlay-network-guides.md`);
    assert.equal(resolve('../../README.md#adding-a-machine'), `${repo}/blob/main/README.md#adding-a-machine`);
    assert.equal(resolve('../../Sources/Heeler/App.swift#L12'), `${repo}/blob/main/Sources/Heeler/App.swift#L12`);
    assert.equal(resolve('/CHANGELOG.md'), `${repo}/blob/main/CHANGELOG.md`);
  });

  it('uses /tree/ for directories', () => {
    assert.equal(resolve('../adr'), `${repo}/tree/main/docs/adr`);
    assert.equal(resolve('../research/'), `${repo}/tree/main/docs/research`);
    assert.equal(resolve('../../'), repo);
  });

  it('serves guide images from /images/', () => {
    assert.equal(resolve('images/overlay-networks/tailscale-form.png'), '/images/overlay-networks/tailscale-form.png');
  });

  it('keeps percent-escapes canonical instead of encoding them twice', () => {
    assert.equal(resolve('../../a%23b.md'), `${repo}/blob/main/a%23b.md`);
    assert.equal(resolve('../../a%2Fb.md'), `${repo}/blob/main/a%2Fb.md`);
    assert.equal(resolve('../../My%20File.md'), `${repo}/blob/main/My%20File.md`);
    assert.equal(resolve('../../my file.md'), `${repo}/blob/main/my%20file.md`);
    assert.equal(resolve('../../100%.md'), undefined);
  });

  it('drops a query on site routes and keeps it on GitHub', () => {
    assert.equal(resolve('zerotier.md?plain=1#x'), '/zerotier#x');
    assert.equal(resolve('releasing.md?plain=1#L3'), `${repo}/blob/main/docs/guides/releasing.md?plain=1#L3`);
  });

  it('leaves absolute URLs, mail links, anchors, and paths outside the repo alone', () => {
    for (const href of ['https://herdr.dev', 'mailto:someone@example.com', '#troubleshooting', '//cdn.example', '../../../x.md']) {
      assert.equal(resolve(href), undefined, href);
    }
  });
});

describe('rewriteHtmlLinks', () => {
  it('rewrites href and src in raw HTML', () => {
    const html = '<a href="images/a.png"><img src="images/a.png" width="300" alt="A"></a>';
    assert.equal(
      rewriteHtmlLinks(html, resolve),
      '<a href="/images/a.png"><img src="/images/a.png" width="300" alt="A"></a>',
    );
  });

  it('handles srcset and spaced attributes but not data-* look-alikes', () => {
    assert.equal(
      rewriteHtmlLinks('<img data-src="images/a.png" srcset="images/a.png 2x, images/b.png 3x"><a href = "zerotier.md">', resolve),
      '<img data-src="images/a.png" srcset="/images/a.png 2x, /images/b.png 3x"><a href="/zerotier">',
    );
  });
});

describe('extractTitle', () => {
  it('removes the H1 and returns it with the next paragraph as plain text', () => {
    const tree: MdastRoot = {
      type: 'root',
      children: [
        { type: 'heading', depth: 1, children: [{ type: 'text', value: 'Connect Heeler' }] },
        {
          type: 'paragraph',
          children: [
            { type: 'text', value: 'Use ' },
            { type: 'strong', children: [{ type: 'text', value: 'Settings' }] },
            { type: 'text', value: ' and\n' },
            { type: 'link', url: 'tailscale.md', children: [{ type: 'inlineCode', value: 'tailscale' }] },
            { type: 'text', value: '.' },
          ],
        },
        { type: 'heading', depth: 2, children: [{ type: 'text', value: 'Steps' }] },
      ],
    };
    assert.deepEqual(extractTitle(tree), { title: 'Connect Heeler', description: 'Use Settings and tailscale.' });
    assert.deepEqual(
      tree.children.map((node) => node.type),
      ['paragraph', 'heading'],
    );
  });

  it('skips paragraphs without prose and a trailing lead-in sentence', () => {
    const tree: MdastRoot = {
      type: 'root',
      children: [
        { type: 'heading', depth: 1, children: [{ type: 'text', value: 'T' }] },
        { type: 'paragraph', children: [{ type: 'image', url: 'x.png', alt: 'only image' }] },
        { type: 'paragraph', children: [{ type: 'text', value: 'Use a VPS. The result is:' }] },
      ],
    };
    assert.deepEqual(extractTitle(tree), { title: 'T', description: 'Use a VPS.' });
  });

  it('returns nothing without an H1', () => {
    assert.deepEqual(extractTitle({ type: 'root', children: [] }), {});
  });
});

describe('dropLeadIn', () => {
  it('drops a final sentence that ends in a colon', () => {
    assert.equal(dropLeadIn('Follow this guide.\nThe result is:'), 'Follow this guide.');
    assert.equal(dropLeadIn('Run this:'), 'Run this:');
    assert.equal(dropLeadIn('Plain text.'), 'Plain text.');
  });
});

describe('htmlNodes', () => {
  it('finds raw HTML at any depth', () => {
    const tree: MdastRoot = {
      type: 'root',
      children: [
        { type: 'html', value: '<details>' },
        { type: 'paragraph', children: [{ type: 'text', value: 'Keep' }, { type: 'html', value: '<br>' }] },
      ],
    };
    assert.deepEqual(
      htmlNodes(tree).map((node) => node.value),
      ['<details>', '<br>'],
    );
  });
});

describe('rehypeFumadocsElements', () => {
  it('wraps tables and anchors headings in Markdown files only', () => {
    const build = (): HastRoot => ({
      type: 'root',
      children: [
        { type: 'element', tagName: 'h2', properties: { id: 'steps' }, children: [{ type: 'text', value: 'Steps' }] },
        { type: 'element', tagName: 'table', properties: {}, children: [] },
      ],
    });

    const markdown = build();
    rehypeFumadocsElements()(markdown, { path: '/repo/docs/guides/tailscale.md' });
    const [heading, wrapper] = markdown.children;
    assert.ok(heading?.type === 'element' && wrapper?.type === 'element');
    assert.ok((heading.properties.className as string[]).includes('scroll-m-28'));
    assert.deepEqual(heading.children[0], {
      type: 'element',
      tagName: 'a',
      properties: { href: '#steps', dataCard: '' },
      children: [{ type: 'text', value: 'Steps' }],
    });
    assert.equal(wrapper.tagName, 'div');
    assert.equal((wrapper.children[0] as Element).tagName, 'table');

    const mdx = build();
    rehypeFumadocsElements()(mdx, { path: '/repo/docs-site/content/index.mdx' });
    assert.deepEqual(mdx, build());
  });
});

describe('summarize', () => {
  it('keeps short text and trims long text on a word boundary', () => {
    assert.equal(summarize('  short\n text '), 'short text');
    const long = 'word '.repeat(60);
    const result = summarize(long);
    assert.ok(result.length <= 160, `${result.length}`);
    assert.ok(result.endsWith('word…'));
  });
});

describe('GitHub alerts', () => {
  it('parses the alert marker', () => {
    assert.deepEqual(parseAlertMarker('[!IMPORTANT]\nAllow only tcp:22.'), { kind: 'IMPORTANT', rest: 'Allow only tcp:22.' });
    assert.deepEqual(parseAlertMarker('[!note]'), { kind: 'NOTE', rest: '' });
    assert.equal(parseAlertMarker('[!INFO]\nText'), undefined);
    assert.equal(parseAlertMarker('Plain quote'), undefined);
  });

  it('turns an alert blockquote into a callout and leaves other quotes alone', () => {
    const quote = (text: string): Element => ({
      type: 'element',
      tagName: 'blockquote',
      properties: {},
      children: [{ type: 'element', tagName: 'p', properties: {}, children: [{ type: 'text', value: text }] }],
    });
    const tree: HastRoot = { type: 'root', children: [quote('[!WARNING]\nBack up first.'), quote('Just a quote.')] };
    rehypeGithubAlerts()(tree);

    const [callout, plain] = tree.children;
    assert.ok(callout?.type === 'element' && plain?.type === 'element');
    assert.equal(callout.tagName, 'div');
    assert.equal(callout.properties.role, 'note');
    assert.match(String(callout.properties.style), /--color-fd-warning/);
    assert.match(JSON.stringify(callout), /"value":"Warning"/);
    assert.match(JSON.stringify(callout), /"value":"Back up first\."/);
    assert.doesNotMatch(JSON.stringify(callout), /\[!WARNING\]/);
    assert.equal(plain.tagName, 'blockquote');
  });
});
