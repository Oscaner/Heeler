import type { APIRoute } from 'astro';
import { createFromSource } from 'fumadocs-core/search/server';
import { getStructuredData, source } from '@/lib/source.ts';

// Prebuilt search index, emitted as dist/api/search.json and loaded by the
// search dialog in the browser (useStaticSearch).
const server = createFromSource(source, {
  buildIndex(page) {
    return {
      id: page.url,
      title: page.data.title,
      description: page.data.description,
      structuredData: getStructuredData(page.data.entry),
      url: page.url,
    };
  },
});

export const GET: APIRoute = () => server.staticGET();
