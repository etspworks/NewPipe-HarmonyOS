/*
 * S3 - port of SelectPlaylistFragment.SelectPlaylistAdapter (list_playlist_mini_item.xml).
 *
 * This list is HETEROGENEOUS: onBindViewHolder has TWO type branches
 *   selectedItem instanceof PlaylistMetadataEntry  -> a LOCAL playlist
 *   selectedItem instanceof PlaylistRemoteEntity   -> a bookmarked REMOTE playlist
 * and clickedItem(position) dispatches on the same distinction to onLocalPlaylistSelected(uid,
 * name) or onRemotePlaylistSelected(serviceId, url, name). An item matching NEITHER type binds
 * NOTHING - it stays blank and unclickable - so this port keeps all three cases rather than
 * flattening them into one row with one tap route.
 *
 * The row reuses the app-wide list_playlist_mini_item.xml, whose root id is `itemRoot`
 * (camelCase - it does NOT follow the lowercase itemroot spelling the other three pickers use),
 * and whose itemStreamCountView / itemUploaderView this screen never binds.
 */

import { LocalItemType } from '../model/enums/LocalItemLocalItemType';
import { shouldLoadImages } from '../common/image/ImageLoader';

/** list_playlist_mini_item.xml: a 90x50 thumbnail, fitStart. */
const THUMB_WIDTH: number = 90;
const THUMB_HEIGHT: number = 50;
/** list_playlist_mini_item.xml: itemStreamCountView is 45dp wide and aligned to the thumbnail's
 *  top/end/bottom, @dimen/video_item_search_padding is the row padding and
 *  @dimen/video_item_search_image_right_margin the gap before the title. */
const COUNT_WIDTH: number = 45;
const ROW_PADDING: number = 12;
const THUMB_RIGHT_MARGIN: number = 6;
/** @dimen/video_item_search_title_text_size on itemTitleView (?textAppearanceLarge overridden). */
const ITEM_TITLE_TEXT_SIZE: number = 14;
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');

/**
 * One PlaylistLocalItem row. `localItemType` is the discriminator both the bind and the click
 * branch on, so it is carried on the row rather than being re-derived.
 */
export class SelectPlaylistRow {
  /** `key = { it }` needs a stable identity across the merged local+remote list. */
  key: string;
  localItemType: LocalItemType;
  /** entry.getOrderingName() in BOTH branches. */
  orderingName: string;
  /** CoilHelper.loadPlaylistThumbnail(holder.thumbnailView, entry.getThumbnailUrl()). */
  thumbnailUrl: string;
  /** PlaylistMetadataEntry.getUid() - the local branch's callback argument. */
  uid: number;
  /** PlaylistRemoteEntity.getServiceId()/getUrl() - the remote branch's callback arguments. */
  serviceId: number;
  url: string;

  constructor(key: string, localItemType: LocalItemType, orderingName: string,
              thumbnailUrl: string, uid: number, serviceId: number, url: string) {
    this.key = key;
    this.localItemType = localItemType;
    this.orderingName = orderingName;
    this.thumbnailUrl = thumbnailUrl;
    this.uid = uid;
    this.serviceId = serviceId;
    this.url = url;
  }
}

/** getItemCount() / the fragment's `playlists`, as the LazyForEach source. */
export class SelectPlaylistDataSource implements IDataSource {
  private items: SelectPlaylistRow[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): SelectPlaylistRow {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos: number = this.listeners.indexOf(listener);
    if (pos >= 0) {
      this.listeners.splice(pos, 1);
    }
  }

  /** displayPlaylists(newPlaylists): the page re-submits the whole merged list. */
  submitList(items: SelectPlaylistRow[]): void {
    this.items = items;
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataReloaded();
    });
  }
}

@Component
export struct SelectPlaylistAdapter {
  dataSource: SelectPlaylistDataSource = new SelectPlaylistDataSource();
  /** clickedItem(position) -> onLocalPlaylistSelected(uid, orderingName), then dismiss(). */
  onLocalItemClicked: (item: SelectPlaylistRow) => void = (item: SelectPlaylistRow): void => {
    console.info('SelectPlaylistAdapter: onLocalItemClicked not bound (' + item.key + ')');
  };
  /** clickedItem(position) -> onRemotePlaylistSelected(serviceId, url, name), then dismiss(). */
  onRemoteItemClicked: (item: SelectPlaylistRow) => void = (item: SelectPlaylistRow): void => {
    console.info('SelectPlaylistAdapter: onRemoteItemClicked not bound (' + item.key + ')');
  };

  /** The shared body of both bind branches: thumbnail + orderingName. */
  @Builder
  rowBody(item: SelectPlaylistRow) {
    Row() {
      // itemStreamCountView sits ON the thumbnail (alignTop/alignEnd/alignBottom of it): the
      // adapter never binds it, so it renders as its own layout styling only - the
      // @color/playlist_stream_count_background_color slab with the ic_playlist_play
      // drawableTop centred in it, exactly the black block S0225 shows over the right 45dp
      // of the 90x50 thumbnail.
      Stack({ alignContent: Alignment.End }) {
        if (shouldLoadImages()) {
          Image(item.thumbnailUrl.length === 0
            ? $r('app.media.placeholder_thumbnail_playlist')
            : item.thumbnailUrl)
            .id('itemThumbnailView')
            .alt($r('app.media.placeholder_thumbnail_playlist'))
            .width(THUMB_WIDTH)
            .height(THUMB_HEIGHT)
            .objectFit(ImageFit.Contain)
        } else {
          Image($r('app.media.placeholder_thumbnail_playlist'))
            .id('itemThumbnailView')
            .width(THUMB_WIDTH)
            .height(THUMB_HEIGHT)
            .objectFit(ImageFit.Contain)
        }

        Column() {
          Image($r('app.media.ic_playlist_play'))
            .width(24)
            .height(24)
            .objectFit(ImageFit.Contain)
            .fillColor($r('app.color.duration_text_color'))
        }
        .width(COUNT_WIDTH)
        .height(THUMB_HEIGHT)
        .padding({ top: 4, bottom: 6 })
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.playlist_stream_count_background_color'))
      }
      .width(THUMB_WIDTH)
      .height(THUMB_HEIGHT)
      .margin({ right: THUMB_RIGHT_MARGIN })

      Text(item.orderingName)
        .id('itemTitleView')
        .fontSize(ITEM_TITLE_TEXT_SIZE)
        .fontColor(COLOR_ON_SURFACE)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  build() {
    List() {
      LazyForEach(this.dataSource, (item: SelectPlaylistRow) => {
        ListItem() {
          // The type dispatch the source performs twice - once when binding, once when clicking.
          if (item.localItemType === LocalItemType.PLAYLIST_LOCAL_ITEM) {
            Column() {
              this.rowBody(item)
            }
            .id('itemRoot')
            .width('100%')
            .padding(ROW_PADDING)
            .onClick((): void => {
              this.onLocalItemClicked(item);
            })
          } else if (item.localItemType === LocalItemType.PLAYLIST_REMOTE_ITEM) {
            Column() {
              this.rowBody(item)
            }
            .id('itemRoot')
            .width('100%')
            .padding(ROW_PADDING)
            .onClick((): void => {
              this.onRemoteItemClicked(item);
            })
          } else {
            // Neither type: onBindViewHolder binds NOTHING, so the row stays blank and
            // unclickable. It still occupies a position, because getItemCount() counts it.
            Column() {
            }
            .id('itemRoot')
            .width('100%')
            .padding(ROW_PADDING)
          }
        }
      }, (item: SelectPlaylistRow) => item.key)
    }
    .width('100%')
    .height('100%')
  }
}
