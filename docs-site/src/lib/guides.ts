import config from '../guides.json' with { type: 'json' };

/** Repository that hosts the guides; links outside the site point here. */
export const githubRepo = 'https://github.com/ZingerLittleBee/Heeler';

/** Repo-relative directory the published guides are read from. */
export const guidesDir = 'docs/guides';

/** Repo-relative directory whose files the site serves under `/images/`. */
export const guideImagesDir = 'docs/guides/images';

export interface GuideSection {
  title: string;
  guides: string[];
}

export const guideSections: readonly GuideSection[] = config.sections;

/** Basenames (without `.md`) of every published guide, in sidebar order. */
export const publishedGuides: readonly string[] = guideSections.flatMap((section) => section.guides);

/** Sidebar labels that differ from a guide's H1 title. */
export const sidebarTitles: Readonly<Record<string, string>> = config.sidebarTitles;

/** Lucide icon name for each page (the index and every guide), keyed by slug. */
export const pageIcons: Readonly<Record<string, string>> = config.icons;
