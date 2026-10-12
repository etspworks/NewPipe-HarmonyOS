/*
 * S3 - port of org.schabi.newpipe.info_list.holder.ChannelInfoItemHolder (list_channel_item.xml).
 *
 * CHANNEL_HOLDER_TYPE: the mini variant plus itemChannelDescriptionView.
 * The row root (@+id/itemRoot) and its click/long-click belong to InfoItemHolder, the base class,
 * so this struct is the BODY that wrapper renders.
 */
import { ChannelInfoItem } from '../model/extractor/ChannelInfoItem';
import { choosePreferredImage, shouldLoadImages } from '../common/image/ImageLoader';
import { Localization } from '../common/i18n/Localization';
import { C_ON_SURFACE, C_SECONDARY } from './StreamInfoItemHolder';

/**
 * list_channel_item.xml's own geometry. A channel row is NOT a video row: its image is the
 * channel's AVATAR - a ShapeableImageView with the CircularImageView shape appearance, sized
 * video_item_search_avatar_image_width/height (70vp square) and inset 27vp/33vp - where a video
 * row carries a 100x60 rectangular thumbnail. The port had the video geometry here, which is
 * what "the channel logos were not displayed in the correct format" describes.
 *
 * Every value below is the migrated dimen, not a number chosen here.
 *
 * The geometry landed in b990b7c; what was still missing is everything else
 * list_channel_item.xml says about this row (TC-KIOSK-271). Its three Text nodes had no
 * fontSize and no fontColor at all, so a conference title drew at the platform default in full
 * black; itemChannelDescriptionView and itemAdditionalDetails were emitted even when the item
 * carries neither - which every media.ccc.de conference does - padding each row with two empty
 * lines; and the avatar had no placeholder, so an item with no logo drew nothing.
 * channel_item_detail_title_text_size is the title dimen that layout names, migrated with the
 * rest and until now unused.
 */
const AVATAR_SIZE: Resource = $r('app.float.video_item_search_avatar_image_width');
/** The circular crop: half of 70vp. ShapeableImageView does this with a shapeAppearance. */
const AVATAR_RADIUS: number = 35;

@Component
export struct ChannelInfoItemHolder {
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
        // src draws nothing at all - a media.ccc.de conference with no logo left a hole where
        // every other row has an image. It is the src for that case and the alt for the load.
        Image(this.thumbnailUrl() === ''
          ? $r('app.media.placeholder_person') : this.thumbnailUrl())
          .alt($r('app.media.placeholder_person'))
          .id('itemThumbnailView')
          .width(AVATAR_SIZE)
          .height($r('app.float.video_item_search_avatar_image_height'))
          // shapeAppearance CircularImageView: the avatar IS clipped to a circle, and the
          // artwork is FITTED inside it rather than cropped to fill it. Measured on the
          // reference at media.ccc.de > Conferences: the left edge of the drawn pixels of
          // "19C3: Out Of Order" runs 0.276, 0.195, 0.095, 0.038, 0.0, 0.043, 0.1, 0.2, 0.276
          // of the box width down the tile, against an ideal circle's 0.282, 0.2, 0.1, 0.042,
          // 0, 0.042, 0.1, 0.2, 0.282 - and "All Systems Go!", whose artwork has four coloured
          // corner triangles, shows plain background in all four corners there. Cover was the
          // real defect TC-NAV-464 reports: it cropped a wordmark to fill the box before the
          // circle even got to it. Contain + the circle is the reference.
          .borderRadius(AVATAR_RADIUS)
          .clip(true)
          .objectFit(ImageFit.Contain)
          .margin({
            left: $r('app.float.video_item_search_avatar_left_margin'),
            right: $r('app.float.video_item_search_avatar_right_margin')
          })
      }
      Column() {
        Text(this.title())
          .id('itemTitleView')
          .fontSize($r('app.float.channel_item_detail_title_text_size'))
          .fontColor(C_ON_SURFACE)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
          .margin({ bottom: $r('app.float.video_item_search_image_right_margin') })
        // updateFromItem() sets itemChannelDescriptionView GONE for an item with no
        // description, and getDetailLine() returns '' when neither count is available. A
        // media.ccc.de conference carries neither, so both nodes are absent rather than two
        // empty lines carrying their margins.
        if (this.description().length > 0) {
          Text(this.description())
            .id('itemChannelDescriptionView')
            .fontSize($r('app.float.video_item_search_upload_date_text_size'))
            .fontColor(C_SECONDARY)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)
            .margin({ bottom: $r('app.float.channel_item_description_to_details_margin') })
        }
        if (this.additionalDetails().length > 0) {
          Text(this.additionalDetails())
            .id('itemAdditionalDetails')
            .fontSize($r('app.float.video_item_search_upload_date_text_size'))
            .fontColor(C_SECONDARY)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding($r('app.float.video_item_search_padding'))
    // The avatar is constrained to both parent edges in the source, i.e. centred on the row.
    .alignItems(VerticalAlign.Center)
  }
}
