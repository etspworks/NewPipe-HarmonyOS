/*
 * S3 — port of org.schabi.newpipe.local.holder.RemotePlaylistItemHolder: a bookmarked REMOTE
 * playlist row WITHOUT a drag handle. Chosen by LocalItemListAdapter when `useItemHandle` is
 * false; BookmarkFragment sets it true, so on that screen this branch is not taken.
 */
import { PlaylistLocalItem } from '../model/db/view/PlaylistLocalItem';

@Component
export struct RemotePlaylistItemHolder {
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
