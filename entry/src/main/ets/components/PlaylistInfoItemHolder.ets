/*
 * S3 - port of org.schabi.newpipe.info_list.holder.PlaylistInfoItemHolder (list_playlist_item.xml).
 *
 * PLAYLIST_HOLDER_TYPE: the same fields at list size.
 * The row root (@+id/itemRoot) and its click/long-click belong to InfoItemHolder, the base class,
 * so this struct is the BODY that wrapper renders.
 *
 * S5: this holder was left at the S3 stub - a literal 100x60 thumbnail with no objectFit, no
 * padding, no gutter, and an itemStreamCountView that was a bare number with no size, no colour
 * and no background, so Bandcamp's square cover art stretched every row to a different width and
 * the count floated naked over the middle of the artwork (TC-KIOSK-061).
 *
 * list_playlist_item.xml sizes itemThumbnailView with the video_item_search_thumbnail_image_*
 * pair and lays itemStreamCountView over its END edge as a
 * playlist_item_thumbnail_stream_count_width band on playlist_stream_count_background_color -
 * both of those resources were migrated and until now unused. PlaylistItemHolder.ets already
 * renders that band for the bookmark row, so the arrangement here is its, not one chosen here.
 */
import { PlaylistInfoItem } from '../model/extractor/PlaylistInfoItem';
import { choosePreferredImage, shouldLoadImages } from '../common/image/ImageLoader';
import { Localization } from '../common/i18n/Localization';
import { C_ON_SURFACE, C_SECONDARY } from './StreamInfoItemHolder';

/** The playlist glyph in the count band, sized to sit above the number when there is one. */
const PLAYLIST_GLYPH_SIZE: number = 18;

@Component
export struct PlaylistInfoItemHolder {
  item: PlaylistInfoItem | null = null;

  /** CoilHelper.loadThumbnail(itemThumbnailView, item.getThumbnails()). */
  private thumbnailUrl(): string {
    const url: string | null =
      this.item === null ? null : choosePreferredImage(this.item.getThumbnails());
    return url === null ? '' : url;
  }

  private title(): string {
    return this.item === null ? '' : this.item.getName();
  }

  private uploader(): string {
    return this.item === null ? '' : this.item.uploaderName;
  }

  /** Localization.localizeStreamCount(item.getStreamCount()). */
  private streamCount(): string {
    return this.item === null ? '' : Localization.localizeStreamCountMini(this.item.streamCount);
  }

  build() {
    Row() {
      if (shouldLoadImages()) {
        // list_playlist_item.xml: itemStreamCountView is aligned to the thumbnail's top, bottom
        // and end - a band down its right half, not a chip and not a bare number.
        Stack({ alignContent: Alignment.End }) {
          // An empty src draws nothing, and CoilHelper renders the placeholder both while the
          // load is in flight and when the item carries no thumbnail at all.
          Image(this.thumbnailUrl() === ''
            ? $r('app.media.placeholder_thumbnail_playlist') : this.thumbnailUrl())
            .alt($r('app.media.placeholder_thumbnail_playlist'))
            .id('itemThumbnailView')
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
          // localizeStreamCountMini() returns '' for ITEM_COUNT_UNKNOWN; the band is GONE then,
          // rather than a black slab with nothing written on it.
          // TC-SEARCH-236: the band is what says "this row is a PLAYLIST" - without it a playlist
          // is a bare thumbnail, indistinguishable from a video. It used to be drawn only when a
          // stream count was known, so YouTube Music playlists, which report none, lost the band
          // entirely: "YouTube Music playlists do not appear in playlist format."
          //
          // The reference keeps the band either way and draws its playlist glyph in it, with the
          // number added only when there is one. So the band is unconditional now, and its
          // CONTENTS are what varies.
          Column() {
            Image($r('app.media.ic_playlist_play'))
              .width(PLAYLIST_GLYPH_SIZE)
              .height(PLAYLIST_GLYPH_SIZE)
              .fillColor($r('app.color.duration_text_color'))
            if (this.streamCount().length > 0) {
              Text(this.streamCount())
                .id('itemStreamCountView')
                .fontSize($r('app.float.video_item_search_duration_text_size'))
                .fontColor($r('app.color.duration_text_color'))
                .maxLines(1)
                .textAlign(TextAlign.Center)
            }
          }
          .id('itemStreamCountOverlay')
          .width($r('app.float.playlist_item_thumbnail_stream_count_width'))
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor($r('app.color.playlist_stream_count_background_color'))
        }
        .width($r('app.float.video_item_search_thumbnail_image_width'))
        .height($r('app.float.video_item_search_thumbnail_image_height'))
        .margin({ right: $r('app.float.video_item_search_image_right_margin') })
      }
      Column() {
        Text(this.title())
          .id('itemTitleView')
          .fontSize($r('app.float.video_item_search_title_text_size'))
          .fontColor(C_ON_SURFACE)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
        Text(this.uploader())
          .id('itemUploaderView')
          .fontSize($r('app.float.video_item_search_uploader_text_size'))
          .fontColor(C_SECONDARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding($r('app.float.video_item_search_padding'))
    // The thumbnail is constrained to the row's top, so a two-line title never shifts it.
    .alignItems(VerticalAlign.Top)
  }
}
