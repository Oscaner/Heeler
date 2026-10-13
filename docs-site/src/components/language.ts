import type { I18nProviderProps } from '@fumadocs/base-ui/contexts/i18n';
import { useEffect, useState } from 'react';

/**
 * The languages offered by the language switch at the bottom of the sidebar.
 * Every page is in English so far: picking another language is remembered for
 * when translations exist, but changes neither the content nor the URL (nor
 * <html lang>, which describes the content).
 */
const locales = [
  { locale: 'en', name: 'English' },
  { locale: 'zh', name: '简体中文' },
];
const storageKey = 'language';

/** Props for Fumadocs' I18nProvider (RootProvider's `i18n`) with the remembered language. */
export function useLanguage(): Omit<I18nProviderProps, 'children'> {
  const [locale, setLocale] = useState('en');
  // Read after hydration, so that the server and the first client render agree.
  useEffect(() => {
    const stored = storedLocale();
    if (stored !== undefined) setLocale(stored);
  }, []);
  return {
    locale,
    locales,
    onLocaleChange(value) {
      setLocale(value);
      try {
        localStorage.setItem(storageKey, value);
      } catch {
        // Without storage (blocked site data), the choice lasts until the next full load.
      }
    },
  };
}

function storedLocale(): string | undefined {
  try {
    const value = localStorage.getItem(storageKey);
    return locales.find((item) => item.locale === value)?.locale;
  } catch {
    return undefined;
  }
}
