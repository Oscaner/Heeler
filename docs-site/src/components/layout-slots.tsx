import { useSidebar } from '@fumadocs/base-ui/components/sidebar/base';
import { buttonVariants } from '@fumadocs/base-ui/components/ui/button';
import { LinkItem } from '@fumadocs/base-ui/layouts/shared';
import { type DocsLayoutProps, useSpaciousLayout } from '@fumadocs/base-ui/layouts/spacious';
import {
  Sidebar,
  SidebarDrawer,
  type SidebarProps,
  SidebarProvider,
} from '@fumadocs/base-ui/layouts/spacious/slots/sidebar';
import { useTheme } from '@fumadocs/base-ui/provider/base';
import { type LucideIcon, MonitorIcon, MoonIcon, SunIcon, SunMoonIcon } from 'lucide-react';
import { type ComponentProps, useEffect, useId, useState } from 'react';
import { createPortal, flushSync } from 'react-dom';

/**
 * Spacious slots that move the theme switch to the bottom of the sidebar and
 * of the phone drawer. Spacious keeps it in the page header's options menu (in
 * the drawer's top row on phones), which suits fumadocs.dev's long sidebar;
 * this site's sidebar is short and leaves room below. Pass to DocsLayout along
 * with `themeSwitch={{ enabled: false }}`, which removes the built-in switches.
 */
export const layoutSlots: DocsLayoutProps['slots'] = {
  sidebar: { provider: SidebarProvider, main: SidebarWithTheme, drawer: DrawerWithTheme },
  actions: HeaderActions,
};

// Neither sidebar has a footer slot, so the switch is portalled to the end of
// each one's flex column once it has mounted. Being inside the sidebar, it
// fades out and goes inert with it when collapsed and takes the sidebar's
// colour overrides.

function SidebarWithTheme(props: SidebarProps) {
  // Sidebar passes its props, ref included, to its <aside>, whose one child is the column.
  const [aside, setAside] = useState<HTMLElement | null>(null);
  const column = aside?.firstElementChild;
  return (
    <>
      <Sidebar {...props} ref={setAside} />
      {column && createPortal(<ThemeSwitch />, column)}
    </>
  );
}

function DrawerWithTheme() {
  const { mode } = useSidebar();
  const [drawer, setDrawer] = useState<HTMLElement | null>(null);
  // SidebarDrawer takes no props, so its <aside> (the column) is found by id.
  // It stays mounted while the drawer is closed, as long as the layout is in
  // drawer mode.
  useEffect(() => {
    setDrawer(mode === 'drawer' ? document.getElementById('nd-sidebar-mobile') : null);
  }, [mode]);
  return (
    <>
      <SidebarDrawer />
      {mode === 'drawer' && drawer && createPortal(<ThemeSwitch />, drawer)}
    </>
  );
}

/**
 * The page panel's header actions. Spacious shows icon links from lg up and
 * folds them into the options menu below that; without the theme switch the
 * menu would hold the GitHub link alone, so the links show at every width.
 */
function HeaderActions({ className, ...props }: ComponentProps<'div'>) {
  const { menuItems } = useSpaciousLayout();
  return (
    <div className={`flex items-center gap-0.5 rounded-lg bg-fd-background ${className ?? ''}`} {...props}>
      {menuItems.map(
        (item) =>
          item.type === 'icon' && (
            <LinkItem
              key={item.url}
              item={item}
              aria-label={item.label}
              className={buttonVariants({ variant: 'ghost', size: 'icon-sm', className: 'text-fd-muted-foreground' })}
            >
              {item.icon}
            </LinkItem>
          ),
      )}
    </div>
  );
}

const themes: [value: string, label: string, icon: LucideIcon, turn: string][] = [
  ['system', 'System', MonitorIcon, '0deg'],
  ['light', 'Light', SunIcon, '-90deg'],
  ['dark', 'Dark', MoonIcon, '40deg'],
];

/**
 * The theme row of Spacious' options menu (system, light, dark, with its
 * sliding thumb and icon turn), on native radios so that the current theme is
 * announced and the arrow keys move between the options.
 */
function ThemeSwitch() {
  const { theme, setTheme } = useTheme();
  const id = useId();
  const index = themes.findIndex(([value]) => value === theme);

  function pick(value: string, icon: Element | null, turn: string) {
    if (typeof document.startViewTransition === 'function') {
      document.startViewTransition(() => flushSync(() => setTheme(value)));
    } else {
      setTheme(value);
    }
    if (!matchMedia('(prefers-reduced-motion: reduce)').matches) {
      icon?.animate([{ rotate: turn, scale: 0.6 }, { rotate: '0deg', scale: 1 }], {
        duration: 520,
        easing: 'cubic-bezier(0.34, 1.56, 0.64, 1)',
      });
    }
  }

  return (
    // The rule keeps the row from reading as one more page link when the list
    // above runs down to it.
    <div className="mx-3 flex shrink-0 items-center gap-3 border-t py-3 ps-2.5 text-fd-muted-foreground">
      <SunMoonIcon className="size-4 shrink-0" />
      <span id={`${id}-label`} className="flex-1">
        Theme
      </span>
      <div
        role="radiogroup"
        aria-labelledby={`${id}-label`}
        className="relative flex rounded-full border bg-fd-secondary p-0.5"
      >
        {index !== -1 && (
          <span
            aria-hidden
            className="absolute start-0.5 top-0.5 size-7 rounded-full bg-fd-background shadow-sm ring-1 ring-fd-border transition-transform duration-300 ease-[cubic-bezier(0.22,1,0.36,1)] motion-reduce:transition-none"
            style={{ translate: `${index * 100}%` }}
          />
        )}
        {themes.map(([value, label, Icon, turn]) => (
          <label
            key={value}
            className={`relative flex size-7 cursor-pointer items-center justify-center rounded-full transition-colors duration-150 has-focus-visible:ring-2 has-focus-visible:ring-fd-ring ${
              value === theme
                ? 'text-fd-foreground'
                : 'hover:bg-fd-accent hover:text-fd-accent-foreground'
            }`}
          >
            <input
              type="radio"
              name={id}
              value={value}
              checked={value === theme}
              aria-label={label}
              className="sr-only"
              onChange={(event) => pick(value, event.currentTarget.nextElementSibling, turn)}
            />
            <Icon className="size-3.5" />
          </label>
        ))}
      </div>
    </div>
  );
}
