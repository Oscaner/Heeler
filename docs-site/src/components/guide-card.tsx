import { Card } from '@fumadocs/base-ui/components/card';
import { icons } from 'lucide-react';
import type { ReactNode } from 'react';
import { pageLink } from '@/lib/source.ts';

/**
 * A card on the home page that links to a guide. Its title and icon are the
 * guide's sidebar label and icon from src/guides.json, so the two stay alike.
 */
export function GuideCard({ slug, children }: { slug: string; children: ReactNode }) {
  const { title, icon, url } = pageLink(slug);
  const Icon = icons[icon];
  return (
    <Card href={url} title={title} icon={<Icon />}>
      {children}
    </Card>
  );
}
