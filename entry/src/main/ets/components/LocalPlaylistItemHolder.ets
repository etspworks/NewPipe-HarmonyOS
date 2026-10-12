/*
 * S3 — port of org.schabi.newpipe.local.holder.LocalPlaylistItemHolder: a LOCAL playlist row
 * WITHOUT a drag handle (list_playlist_mini_item). LocalItemListAdapter picks this holder over
 * LocalBookmarkPlaylistItemHolder whenever `useItemHandle` is false, which is every local list
 * except BookmarkFragment.
 *
 * Its only addition over PlaylistItemHolder is binding the PlaylistMetadataEntry values, which
 * the caller passes in through `body`.
 */
import { PlaylistLocalItem } from '../model/db/view/PlaylistLocalItem';

@Component
export struct LocalPlaylistItemHolder {
  item: PlaylistLocalItem | null = null;
  @BuilderParam body: (item: PlaylistLocalItem) => void = this.defaultBody;

  @Builder
  defaultBody(item: PlaylistLocalItem) {
    Text(item.orderingName === null ? '' : item.orderingName)
  }

  build() {
    Row() {
      if (this.item !== null) {
        this.body(this.item)
      }
    }
    .width('100%')
  }
}
