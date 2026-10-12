/*
 * S3 — port of org.schabi.newpipe.local.holder.LocalPlaylistStreamItemHolder: a stream row inside
 * a local playlist (LocalItemType.PLAYLIST_STREAM_ITEM). BookmarkFragment's list is
 * List<PlaylistLocalItem>, so this branch of the adapter's dispatch is never taken there; it is
 * LocalPlaylistFragment's row.
 */

/**
 * list_stream_playlist_item.xml's own geometry. The thumbnail is a fixed 98x55 box written
 * literally in that layout - it is not one of the video_item_search_thumbnail_* dimens - and
 * itemHandle matches its height. Everything else below is a migrated dimen.
 *
 * These two sizes are why this file needed changing at all: without them the Image had no
 * constraint, took the whole row width, and squeezed the title/uploader Column to zero.
 */
const THUMB_W: number = 98;
const THUMB_H: number = 55;
/**
 * ItemTouchHelper's pickup slop, in vp - the constant LocalBookmarkPlaylistItemHolder and
 * PlayQueueItemTouchCallback use for the same "drag a row out of a scrolling list" gesture.
 */
const DRAG_SLOP: number = 12;

@Component
export struct LocalPlaylistStreamItemHolder {
  thumbnailUrl: string | null = null;
  title: string | null = null;
  uploader: string | null = null;
  duration: string | null = null;
  /** LocalPlaylistFragment sets useItemHandle too, so this row can carry the drag handle. */
  showItemHandle: boolean = false;
  /**
   * getOnTouchListener(item): ACTION_DOWN on itemHandle -> OnClickGesture.drag ->
   * itemTouchHelper.startDrag(). The pan's start, its cumulative vertical travel in vp, and its
   * end; the owning page does the swapping. Only wired where showItemHandle is.
   */
  onHandleDragStart: () => void = (): void => {};
  onHandleDragUpdate: (offsetY: number) => void = (offsetY: number): void => {};
  onHandleDragEnd: () => void = (): void => {};
  /**
   * The raw finger-down / finger-up on the handle: the owning list stops scrolling for exactly as
   * long as the handle is held, or its scroll recognizer wins the vertical move over the pan
   * (the cause LocalBookmarkPlaylistItemHolder documents).
   */
  onHandleTouch: (held: boolean) => void = (held: boolean): void => {};

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
        Text(this.duration === null ? '' : this.duration)
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
      .width(THUMB_W)
      .height(THUMB_H)
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
          .id('itemAdditionalDetails')
          .fontSize($r('app.float.video_item_search_uploader_text_size'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (this.showItemHandle) {
        Image($r('app.media.ic_drag_handle'))
          .id('itemHandle')
          .height(THUMB_H)
          .padding({ left: $r('app.float.video_item_search_image_right_margin') })
          .accessibilityText($r('app.string.detail_drag_description'))
          // An Image is draggable by default, and that system drag-and-drop would start on the
          // handle and cancel the pan.
          .draggable(false)
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Down) {
              this.onHandleTouch(true);
            } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
              this.onHandleTouch(false);
            }
          })
          // isLongPressDragEnabled() is false in the source: the pickup IS the drag. Exclusive
          // with a consuming tap, because the handle is not clickable there and a tap on it must
          // not fall through to itemRoot's onClick (play).
          .gesture(GestureGroup(GestureMode.Exclusive,
            PanGesture({ direction: PanDirection.Vertical, distance: DRAG_SLOP })
              .onActionStart(() => {
                this.onHandleDragStart();
              })
              .onActionUpdate((event: GestureEvent) => {
                this.onHandleDragUpdate(event.offsetY);
              })
              .onActionEnd(() => {
                this.onHandleDragEnd();
              })
              .onActionCancel(() => {
                this.onHandleDragEnd();
              }),
            TapGesture().onAction(() => {
              // drag-only control: the tap is consumed
            })
          ))
      }
    }
    .width('100%')
    // The row root already carries video_item_search_padding - this layout IS the content of
    // LocalItemHolder's itemRoot, and list_stream_item.xml has that padding once, on the
    // root. Repeating it here made every history and playlist row 24vp taller than the
    // reference's (measured: 384 px against 318 px scaled, on rows whose text blocks match).
    .alignItems(VerticalAlign.Center)
  }
}
