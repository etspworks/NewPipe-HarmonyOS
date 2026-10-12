/*
 * S3 — port of org.schabi.newpipe.local.holder.PlaylistItemHolder: the four views every playlist
 * row shares (list_playlist_bookmark_item.xml). Abstract in the source; here it is the shared row
 * BODY the concrete holders render.
 *
 * Source binding: itemTitleView = orderingName, itemStreamCountView =
 * Localization.localizeStreamCountMini(streamCount), itemUploaderView = uploader (INVISIBLE, not
 * gone, for a local playlist), itemThumbnailView = CoilHelper.loadPlaylistThumbnail(thumbnailUrl).
 */
import { Localization } from '../common/i18n/Localization';
import { choosePreferredImage, dbUrlToImageList, shouldLoadImages }
  from '../common/image/ImageLoader';

/* S5 — style only. Values come from list_playlist_bookmark_item.xml + the migrated
 * float/color resources, cross-checked against the S0043 capture (1080x2340 @3x):
 * itemThumbnailView [36,276][306,426] = 90x50vp at a 12vp inset, itemStreamCountView is the
 * 45vp black strip at its right edge, itemTitleView starts 6vp after the thumbnail. */

/** list_playlist_bookmark_item: itemThumbnailView is a fixed 90x50dp, scaleType centerCrop. */
const THUMBNAIL_WIDTH: number = 90;
const THUMBNAIL_HEIGHT: number = 50;
/** itemStreamCountView layout_width=45dp, alignTop/alignBottom of the thumbnail. */
const BADGE_WIDTH: number = 45;
/** ic_playlist_play as drawableTop; ArkUI has no compound drawable, so it is a sibling glyph. */
const BADGE_GLYPH_SIZE: number = 16;
/** ?android:textColorPrimary (87% black) over the #EEEEEE window background. */
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');
/** ?android:textColorSecondary (54% black) — the uploader line. */
const COLOR_SECONDARY_TEXT: Resource = $r('app.color.on_surface_variant');

@Component
export struct PlaylistItemHolder {
  thumbnailUrl: string | null = null;
  title: string | null = null;
  streamCount: number | null = null;
  uploader: string | null = null;
  /** LocalPlaylistItemHolder sets itemUploaderView to INVISIBLE; the remote one fills it. */
  showUploader: boolean = true;

  /**
   * CoilHelper.loadPlaylistThumbnail(itemThumbnailView, thumbnailUrl): the single URL the
   * database stores expands back into an image list and ImageStrategy picks the variant for the
   * user's image_quality preference. PreferredImageQuality.NONE loads nothing at all, which is
   * what leaves the placeholder showing.
   */
  private thumbnailSrc(): string {
    if (!shouldLoadImages()) {
      return '';
    }
    const chosen: string | null = choosePreferredImage(dbUrlToImageList(this.thumbnailUrl));
    return chosen === null ? '' : chosen;
  }

  build() {
    Row() {
      Stack({ alignContent: Alignment.End }) {
        // S6 — the two non-captured states of this bound site. `.alt` covers LOADING; an
        // EMPTY src (no stored thumbnail, or image_quality = NONE) is what CoilHelper renders
        // the same placeholder for, and an empty string alone would draw nothing at all.
        Image(this.thumbnailSrc() === '' ? $r('app.media.placeholder_thumbnail_playlist')
          : this.thumbnailSrc())
          .alt($r('app.media.placeholder_thumbnail_playlist'))
          .id('itemThumbnailView')
          .width(THUMBNAIL_WIDTH)
          .height(THUMBNAIL_HEIGHT)
          .objectFit(ImageFit.Cover)
          .backgroundColor($r('app.color.placeholder_background'))

        Column() {
          Image($r('app.media.ic_playlist_play'))
            .width(BADGE_GLYPH_SIZE)
            .height(BADGE_GLYPH_SIZE)
            .fillColor($r('app.color.duration_text_color'))
          Text(Localization.localizeStreamCountMini(
            this.streamCount === null ? 0 : this.streamCount))
            .id('itemStreamCountView')
            .fontSize($r('app.float.video_item_search_duration_text_size'))
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.duration_text_color'))
            .textAlign(TextAlign.Center)
            .maxLines(1)
        }
        .width(BADGE_WIDTH)
        .height(THUMBNAIL_HEIGHT)
        .justifyContent(FlexAlign.Center)
        .padding({ top: 4, bottom: 6 })
        .backgroundColor($r('app.color.playlist_stream_count_background_color'))
      }
      .width(THUMBNAIL_WIDTH)
      .height(THUMBNAIL_HEIGHT)

      Column() {
        Text(this.title === null ? '' : this.title)
          .id('itemTitleView')
          .width('100%')
          .fontSize($r('app.float.video_item_search_title_text_size'))
          .fontColor(COLOR_ON_SURFACE)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.uploader === null ? '' : this.uploader)
          .id('itemUploaderView')
          .visibility(this.showUploader ? Visibility.Visible : Visibility.Hidden)
          .width('100%')
          .fontSize($r('app.float.video_item_search_uploader_text_size'))
          .fontColor(COLOR_SECONDARY_TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: $r('app.float.video_item_search_image_right_margin') })
    }
    .layoutWeight(1)
    .alignItems(VerticalAlign.Top)
  }
}
