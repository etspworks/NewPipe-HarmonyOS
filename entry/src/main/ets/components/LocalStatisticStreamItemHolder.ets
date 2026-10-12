/*
 * S3 — port of org.schabi.newpipe.local.holder.LocalStatisticStreamItemHolder: the history /
 * "most played" row (LocalItemType.STATISTIC_STREAM_ITEM), owned by StatisticsPlaylistFragment.
 * BookmarkFragment never emits this item type; the branch exists because LocalItemListAdapter's
 * dispatch covers it.
 *
 * Its layout is list_stream_item.xml, so the thumbnail is the video_item_search_thumbnail_image_*
 * pair rather than the literal 98x55 that list_stream_playlist_item.xml writes. Without those two
 * the Image has no constraint at all: it takes the whole row width and squeezes the title /
 * uploader / details Column to zero, which is why the rows rendered as bare thumbnails.
 */
@Component
export struct LocalStatisticStreamItemHolder {
  thumbnailUrl: string | null = null;
  title: string | null = null;
  uploader: string | null = null;
  duration: string | null = null;
  /** getDetailLine(): view count or the last-played date, per the sort mode. */
  additionalDetails: string | null = null;
  /**
   * itemProgressView: the source shows it when streamEntity.duration > 0 and progressMillis > 0
   * (max = duration in seconds, progress = progressMillis / 1000), GONE otherwise - the
   * "progress bar" TC-LIBRARY-461 asks for on a partly watched history row.
   */
  durationSeconds: number = 0;
  progressMillis: number = 0;

  build() {
    Row() {
      // itemDurationView is layout_gravity="bottom|end" over the thumbnail.
      Stack({ alignContent: Alignment.BottomEnd }) {
        Image(this.thumbnailUrl === null ? '' : this.thumbnailUrl)
          .alt($r('app.media.placeholder_thumbnail_video'))
          .id('itemThumbnailView')
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
        // setVisibility(GONE) when the duration is not positive, not an empty badge.
        if (this.duration !== null) {
          Text(this.duration)
            .id('itemDurationView')
            .fontSize($r('app.float.video_item_search_duration_text_size'))
            .fontColor($r('app.color.duration_text_color'))
            .backgroundColor($r('app.color.duration_background_color'))
            .padding({
              left: $r('app.float.video_item_search_duration_horizontal_padding'),
              right: $r('app.float.video_item_search_duration_horizontal_padding'),
              top: $r('app.float.video_item_search_duration_vertical_padding'),
              bottom: $r('app.float.video_item_search_duration_vertical_padding')
            })
            .margin($r('app.float.video_item_search_duration_margin'))
        }
        if (this.durationSeconds > 0 && this.progressMillis > 0) {
          Progress({
            value: this.progressMillis / 1000,
            total: this.durationSeconds,
            type: ProgressType.Linear
          })
            .id('itemProgressView')
            .width('100%')
            .height(4)
            .color($r('app.color.primary'))
        }
      }
      .width($r('app.float.video_item_search_thumbnail_image_width'))
      .height($r('app.float.video_item_search_thumbnail_image_height'))
      .margin({ right: $r('app.float.video_item_search_image_right_margin') })

      Column() {
        Text(this.title === null ? '' : this.title)
          .id('itemVideoTitleView')
          .fontSize($r('app.float.video_item_search_title_text_size'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
        Text(this.uploader === null ? '' : this.uploader)
          .id('itemUploaderView')
          .fontSize($r('app.float.video_item_search_uploader_text_size'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
        Text(this.additionalDetails === null ? '' : this.additionalDetails)
          .id('itemAdditionalDetails')
          .fontSize($r('app.float.video_item_search_upload_date_text_size'))
          // Two lines, not one: "41 views • 9/17/26, 15:18 • YouTube" does not fit the 195vp
          // text column of the folded Mate X7 and the ellipsis ate the service name, which
          // is a third of what this line is for (TC-LIBRARY-369/461).
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    // The row root already carries video_item_search_padding - this layout IS the content of
    // LocalItemHolder's itemRoot, and list_stream_item.xml has that padding once, on the
    // root. Repeating it here made every history and playlist row 24vp taller than the
    // reference's (measured: 384 px against 318 px scaled, on rows whose text blocks match).
    .alignItems(VerticalAlign.Center)
  }
}
