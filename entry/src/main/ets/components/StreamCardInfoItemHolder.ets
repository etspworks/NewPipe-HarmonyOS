/*
 * S3 - port of org.schabi.newpipe.info_list.holder.StreamCardInfoItemHolder (list_stream_card_item.xml).
 *
 * CARD_STREAM_HOLDER_TYPE: the same fields laid out as a card.
 * The row root (@+id/itemRoot) and its click/long-click belong to InfoItemHolder, the base class,
 * so this struct is the BODY that wrapper renders.
 *
 * S5: type scale, badge visibility and itemProgressView all come from StreamInfoItemHolder.ets,
 * which is what the source's inheritance says - see its header. The card stacks the same pieces
 * vertically, so the thumbnail's gutter is a BOTTOM margin, not a right one.
 */
import { common } from '@kit.AbilityKit';
import { StreamInfoItem } from '../model/extractor/StreamInfoItem';
import {
  C_ON_SURFACE,
  C_SECONDARY,
  getStreamDurationText,
  getStreamInfoDetailLine,
  isLiveDurationBadge,
  loadStreamProgressSeconds
} from './StreamInfoItemHolder';
import { choosePreferredImage, shouldLoadImages } from '../common/image/ImageLoader';

@Component
export struct StreamCardInfoItemHolder {
  item: StreamInfoItem | null = null;
  /** updateState()'s saved position in seconds; -1 until the query answers, and when none exists. */
  @State progressSeconds: number = -1;

  aboutToAppear(): void {
    loadStreamProgressSeconds(this.item, getContext(this) as common.Context)
      .then((seconds: number): void => {
        this.progressSeconds = seconds;
      });
  }

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

  /** StreamMiniInfoItemHolder.updateFromItem(): formatted duration, 'Live', or GONE. */
  private duration(): string {
    return getStreamDurationText(this.item);
  }

  /** A live badge is drawn on live_duration_background_color, not the black one. */
  private isLiveBadge(): boolean {
    return isLiveDurationBadge(this.item);
  }

  /** getStreamInfoDetailLine(item), inherited from StreamInfoItemHolder. */
  private additionalDetails(): string {
    return getStreamInfoDetailLine(this.item);
  }

  /** itemProgressView.setMax((int) item.getDuration()). */
  private durationTotal(): number {
    return this.item === null || this.item.getDuration() <= 0 ? 1 : this.item.getDuration();
  }

  build() {
    Column() {
      if (shouldLoadImages()) {
        // list_stream_item.xml: itemDurationView is layout_gravity="bottom|end" over
        // the thumbnail, with the duration paddings and a 2dp inset. StreamItem.ets
        // already places it that way; these holders centred it instead.
        Stack({ alignContent: Alignment.BottomEnd }) {
          // An empty src draws nothing; CoilHelper renders the placeholder for a missing
          // thumbnail, so it is the src there and the `alt` for the load in flight.
          Image(this.thumbnailUrl() === ''
            ? $r('app.media.placeholder_thumbnail_video') : this.thumbnailUrl())
            .alt($r('app.media.placeholder_thumbnail_video'))
            .id('itemThumbnailView')
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
          // setVisibility(GONE) when there is neither a duration nor a live badge.
          if (this.duration().length > 0) {
            Text(this.duration())
              .id('itemDurationView')
              .fontSize($r('app.float.video_item_search_duration_text_size'))
              .fontColor($r('app.color.duration_text_color'))
              .backgroundColor(this.isLiveBadge()
                ? $r('app.color.live_duration_background_color')
                : $r('app.color.duration_background_color'))
              .padding({
                left: $r('app.float.video_item_search_duration_horizontal_padding'),
                right: $r('app.float.video_item_search_duration_horizontal_padding'),
                top: $r('app.float.video_item_search_duration_vertical_padding'),
                bottom: $r('app.float.video_item_search_duration_vertical_padding')
              })
              .margin($r('app.float.video_item_search_duration_margin'))
          }
          if (this.progressSeconds > 0) {
            Progress({
              value: this.progressSeconds,
              total: this.durationTotal(),
              type: ProgressType.Linear
            })
              .id('itemProgressView')
              .width('100%')
              .height(4)
              .color($r('app.color.primary'))
          }
        }
        // list_stream_grid_item.xml, not list_stream_item.xml: the stacked layout has its own
        // thumbnail dimens and this holder was naming the row layout's.
        .width($r('app.float.video_item_grid_thumbnail_image_width'))
        .height($r('app.float.video_item_grid_thumbnail_image_height'))
        .margin({ bottom: $r('app.float.video_item_search_image_right_margin') })
      }
      Column() {
        Text(this.title())
          .id('itemVideoTitleView')
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
        Text(this.additionalDetails())
          .id('itemAdditionalDetails')
          .fontSize($r('app.float.video_item_search_upload_date_text_size'))
          .fontColor(C_SECONDARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.video_item_search_padding'))
  }
}
