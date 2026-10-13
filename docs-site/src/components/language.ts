import type { I18nProviderProps } from '@fumadocs/base-ui/contexts/i18n';
import { navigate } from 'astro:transitions/client';
import { defaultLocale, isLocale, localeFromPath, localePath } from '@/lib/guides.ts';

/** Languages offered by the language switch at the bottom of the sidebar. */
const locales = [
  { locale: 'en', name: 'English' },
  { locale: 'zh', name: '简体中文' },
];

/**
 * Props for Fumadocs' I18nProvider (RootProvider's `i18n`). The URL is the
 * single source of truth; switching navigates to the matching page in the
 * other language without keeping any `#fragment`, since heading anchors differ.
 */
export function useLanguage(pathname: string): Omit<I18nProviderProps, 'children'> {
  const locale = localeFromPath(pathname);
  return {
    locale,
    locales,
    defaultLanguage: defaultLocale,
    hideLocale: 'default-locale',
    onLocaleChange(value) {
      if (!isLocale(value) || value === locale) return;
      void navigate(localePath(pathname, value));
    },
  };
}
