/*
 * S3 - port of org.schabi.newpipe.info_list.holder.ChannelGridInfoItemHolder (list_channel_grid_item.xml).
 *
 * GRID_CHANNEL_HOLDER_TYPE: the same fields laid out as a grid cell.
 * The row root (@+id/itemRoot) and its click/long-click belong to InfoItemHolder, the base class,
 * so this struct is the BODY that wrapper renders.
 */
import { ChannelInfoItem } from '../model/extractor/ChannelInfoItem';
import { choosePreferredImage, shouldLoadImages } from '../common/image/ImageLoader';
import { Localization } from '../common/i18n/Localization';
import { C_ON_SURFACE, C_SECONDARY } from './StreamInfoItemHolder';

/**
 * list_channel_grid_item.xml's own geometry: a COLUMN, everything centred horizontally, with a
 * circular channel avatar on top. This holder had the video row's 100x60 rectangle instead.
 */
const AVATAR_SIZE: Resource = $r('app.float.channel_item_grid_thumbnail_image_size');
/** shapeAppearance CircularImageView: half of channel_item_grid_thumbnail_image_size (92vp). */
const AVATAR_RADIUS: number = 46;

@Component
export struct ChannelGridInfoItemHolder {
  item: ChannelInfoItem | null = null;

  /** CoilHelper.loadThumbnail(itemThumbnailView, item.getThumbnails()). */
  private thumbnailUrl(): string {
    const url: string | null =
      this.item === null ? null : choosePreferredImage(this.item.getThumbnails());
    return url === null ? '' : url;
  }

  private title(): string {
    return this.item === null ? '' : this.item.getName();
  }

  private description(): string {
    return this.item === null ? '' : this.item.description;
  }

  /** Localization.shortSubscriberCount + streamCount - S4 formats and localizes them. */
  private additionalDetails(): string {
    if (this.item === null) {
      return '';
    }
    // ChannelMiniInfoItemHolder.java:99-113 getDetailLine().
    const subs: string = this.item.subscriberCount < 0
      ? '' : Localization.shortSubscriberCount(this.item.subscriberCount);
    const streams: string = this.item.streamCount < 0
      ? '' : Localization.localizeStreamCount(this.item.streamCount);
    if (subs.length === 0) {
      return streams;
    }
    return streams.length === 0 ? subs : Localization.concatenateStrings([subs, streams]);
  }

  build() {
    Column() {
      if (shouldLoadImages()) {
        // CoilHelper.loadAvatar's placeholder is @drawable/placeholder_person, and an empty
        // src draws nothing at all - an item with no avatar left a hole where every other row
        // has an image. It is the src for that case and the alt for the load in flight.
        Image(this.thumbnailUrl() === ''
          ? $r('app.media.placeholder_person') : this.thumbnailUrl())
          .alt($r('app.media.placeholder_person'))
          .id('itemThumbnailView')
          .width(AVATAR_SIZE)
          .height($r('app.float.channel_item_grid_thumbnail_image_size'))
          .borderRadius(AVATAR_RADIUS)
          .clip(true)
          .objectFit(ImageFit.Cover)
          .margin(2)
      }
      Text(this.title())
        .id('itemTitleView')
        .fontSize($r('app.float.video_item_search_title_text_size'))
        .fontColor(C_ON_SURFACE)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
      // The layout puts itemAdditionalDetails BELOW the title and the description below that.
      // updateFromItem() sets each GONE when the item carries nothing for it.
      if (this.additionalDetails().length > 0) {
        Text(this.additionalDetails())
          .id('itemAdditionalDetails')
          .fontSize($r('app.float.video_item_search_upload_date_text_size'))
          .fontColor(C_SECONDARY)
          .maxLines(1)
          .textAlign(TextAlign.Center)
      }
      if (this.description().length > 0) {
        Text(this.description())
          .id('itemChannelDescriptionView')
          .fontSize($r('app.float.video_item_search_upload_date_text_size'))
          .fontColor(C_SECONDARY)
          // android:gravity="center" and no lines cap.
          .textAlign(TextAlign.Center)
      }
    }
    .width('100%')
    .constraintSize({ minWidth: $r('app.float.channel_item_grid_min_width') })
    .padding($r('app.float.channel_item_grid_padding'))
    // layout_centerHorizontal on every child.
    .alignItems(HorizontalAlign.Center)
  }
}
