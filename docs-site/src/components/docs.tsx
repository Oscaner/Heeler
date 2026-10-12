import type { AstroProviderProps } from 'fumadocs-core/framework/astro';
import type { Root } from 'fumadocs-core/page-tree';
import type { TOCItemType } from 'fumadocs-core/toc';
import { DocsLayout } from 'fumadocs-ui/layouts/docs';
import { DocsBody, DocsDescription, DocsPage, DocsTitle, EditOnGitHub } from 'fumadocs-ui/layouts/docs/page';
import { RootProvider } from 'fumadocs-ui/provider/astro';
import type { ReactNode } from 'react';
import { navigate } from 'astro:transitions/client';
import { githubRepo } from '@/lib/guides.ts';
import StaticSearchDialog from './search';

export interface DocsProps {
  tree: Root;
  pathname: string;
  params: AstroProviderProps['params'];
  /** Omitted on the 404 page, which has no article chrome. */
  page?: {
    title: string;
    /** Shown under the title; guides leave it out because it repeats their first paragraph. */
    description?: string;
    toc: TOCItemType[];
    sourceUrl: string;
  };
  children: ReactNode;
}

/** The Fumadocs shell (sidebar, nav, search, theme) around one page's rendered HTML. */
export function Docs({ tree, pathname, params, page, children }: DocsProps) {
  return (
    <RootProvider
      pathname={pathname}
      params={params}
      navigate={navigate}
      search={{ SearchDialog: StaticSearchDialog }}
    >
      <DocsLayout
        tree={tree}
        nav={{
          title: (
            <>
              <img src="/logo.png" alt="" width={24} height={24} className="rounded-md" />
              Heeler Docs
            </>
          ),
        }}
        links={[{ text: 'Heeler website', url: 'https://heeler.bybee.dev', external: true }]}
        githubUrl={githubRepo}
      >
        {page ? (
          <DocsPage key={pathname} toc={page.toc}>
            <DocsTitle>{page.title}</DocsTitle>
            <DocsDescription>{page.description}</DocsDescription>
            <DocsBody>{children}</DocsBody>
            <EditOnGitHub href={page.sourceUrl} />
          </DocsPage>
        ) : (
          children
        )}
      </DocsLayout>
    </RootProvider>
  );
}
