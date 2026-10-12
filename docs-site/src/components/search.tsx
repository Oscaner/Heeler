import { useStaticSearch } from 'fumadocs-core/search/client';
import {
  SearchDialog,
  SearchDialogClose,
  SearchDialogContent,
  SearchDialogHeader,
  SearchDialogIcon,
  SearchDialogInput,
  SearchDialogList,
  SearchDialogOverlay,
  type SharedProps,
} from 'fumadocs-ui/components/dialog/search';

/** Path of the prebuilt search index (src/pages/api/search.json.ts). */
export const searchIndexPath = '/api/search.json';

// Static search: the browser downloads the index once and queries it locally,
// so the site needs no server.
export default function StaticSearchDialog(props: SharedProps) {
  const search = useStaticSearch({ from: searchIndexPath });

  return (
    <SearchDialog {...search} {...props}>
      <SearchDialogOverlay />
      <SearchDialogContent>
        <SearchDialogHeader>
          <SearchDialogIcon />
          <SearchDialogInput />
          <SearchDialogClose />
        </SearchDialogHeader>
        <SearchDialogList />
      </SearchDialogContent>
    </SearchDialog>
  );
}
