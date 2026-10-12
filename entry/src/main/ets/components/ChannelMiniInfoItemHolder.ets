/*
 * S3 - port of org.schabi.newpipe.info_list.holder.ChannelMiniInfoItemHolder (list_channel_mini_item.xml).
 *
 * MINI_CHANNEL_HOLDER_TYPE: no itemChannelDescriptionView.
 * The row root (@+id/itemRoot) and its click/long-click belong to InfoItemHolder, the base class,
 * so this struct is the BODY that wrapper renders.
 */
import { ChannelInfoItem } from '../model/extractor/ChannelInfoItem';
import { choosePreferredImage, shouldLoadImages } from '../common/image/ImageLoader';
import { Localization } from '../common/i18n/Localization';
import { C_ON_SURFACE, C_SECONDARY } from './StreamInfoItemHolder';

/**
 * list_channel_mini_item.xml's own geometry. The image is the channel's AVATAR - a
 * ShapeableImageView with the CircularImageView shape appearance - not the video row's 100x60
 * rectangle, which is what this holder had.
 *
 * 42dp is written literally in that layout, so it is a constant here rather than a dimen; the
 * margins are literal there too. Everything else is a migrated dimen.
 */
const AVATAR_SIZE: number = 42;
/** shapeAppearance CircularImageView: half of 42vp. */
const AVATAR_RADIUS: number = 21;

@Component
export struct ChannelMiniInfoItemHolder {
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
    Row() {
      if (shouldLoadImages()) {
        // CoilHelper.loadAvatar's placeholder is @drawable/placeholder_person, and an empty
        // src draws nothing at all - an item with no avatar left a hole where every other row
        // has an image. It is the src for that case and the alt for the load in flight.
        Image(this.thumbnailUrl() === ''
          ? $r('app.media.placeholder_person') : this.thumbnailUrl())
          .alt($r('app.media.placeholder_person'))
          .id('itemThumbnailView')
          .width(AVATAR_SIZE)
          .height(AVATAR_SIZE)
          .borderRadius(AVATAR_RADIUS)
          .clip(true)
          .objectFit(ImageFit.Cover)
          // layout_marginStart="3dp" layout_marginRight="15dp".
          .margin({ left: 3, right: 15 })
      }
      Column() {
        Text(this.title())
          .id('itemTitleView')
          .fontSize($r('app.float.video_item_search_title_text_size'))
          .fontColor(C_ON_SURFACE)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
          // layout_marginTop="3dp" layout_marginBottom="2dp".
          .margin({ top: 3, bottom: 2 })
        if (this.additionalDetails().length > 0) {
          Text(this.additionalDetails())
            .id('itemAdditionalDetails')
            .fontSize($r('app.float.video_item_search_upload_date_text_size'))
            .fontColor(C_SECONDARY)
            .maxLines(1)
            .width('100%')
            .textAlign(TextAlign.Start)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding($r('app.float.video_item_search_padding'))
    // layout_centerVertical on the avatar: the row centres it.
    .alignItems(VerticalAlign.Center)
  }
}
