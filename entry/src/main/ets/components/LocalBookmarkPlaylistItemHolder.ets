/*
 * S3 — port of org.schabi.newpipe.local.holder.LocalBookmarkPlaylistItemHolder: the LOCAL
 * playlist row of BookmarkFragment. Tapping it opens LocalPlaylistFragment.
 *
 * Its ONLY addition over LocalPlaylistItemHolder is `R.id.itemHandle`
 * (list_playlist_bookmark_item.xml): NOT clickable in the source — it starts the drag instead
 * (OnClickGesture.drag -> itemTouchHelper.startDrag), which here is a PanGesture.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PlaylistLocalItem } from '../model/db/view/PlaylistLocalItem';

function unwiredDragStart(item: PlaylistLocalItem): void {
  hilog.debug(0x0000, 'NewPipe', 'itemHandle: drag start not bound for uid %{public}d', item.uid);
}

function unwiredDragUpdate(offsetY: number): void {
  hilog.debug(0x0000, 'NewPipe', 'itemHandle: drag offset %{public}d not bound', offsetY);
}

function unwiredDragEnd(): void {
  hilog.debug(0x0000, 'NewPipe', 'itemHandle: drag end not bound');
}

/** The owning page measures the row so the drag knows how far one position is. */
function unmeasuredRow(height: number): void {
  hilog.debug(0x0000, 'NewPipe', 'itemHandle: row height %{public}d not observed', height);
}

/** S5 — ic_drag_handle at its natural 24dp; capture S0043: itemHandle box is 30vp = 6 + 24. */
const HANDLE_ICON_SIZE: number = 24;
/** ?android:textColorSecondary (54% black), the tint every NewPipe list icon carries. */
const COLOR_ICON_TINT: Resource = $r('app.color.on_surface_variant');
/**
 * ItemTouchHelper's own pickup slop, in vp - the same constant PlayQueueItemTouchCallback uses
 * for the identical "drag a row out of a scrolling list" gesture.
 */
const DRAG_SLOP: number = 12;

@Component
export struct LocalBookmarkPlaylistItemHolder {
  item: PlaylistLocalItem | null = null;
  onRowDragStart: (item: PlaylistLocalItem) => void = unwiredDragStart;
  /** The pan's cumulative vertical travel since it was picked up, in vp. */
  onRowDragUpdate: (offsetY: number) => void = unwiredDragUpdate;
  onRowDragEnd: () => void = unwiredDragEnd;
  /**
   * The raw finger-down / finger-up on the handle, BEFORE any gesture is judged. The owning
   * page uses it to switch the List's own scrolling off for exactly as long as the handle is
   * held: on device the List's scroll recognizer beat this PanGesture every time (the pan
   * only starts after its slop, by which point the List has already claimed the move), so
   * the list scrolled and the row stayed put - the tester's "scrollbar becomes active".
   */
  onHandleTouch: (held: boolean) => void = (held: boolean): void => {
    hilog.debug(0x0000, 'NewPipe', 'itemHandle: touch %{public}s not bound', `${held}`);
  };
  onRowHeight: (height: number) => void = unmeasuredRow;
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
      // itemHandle: android:clickable is absent here - drag-only, never a click target.
      Image($r('app.media.ic_drag_handle'))
        .id('itemHandle')
        // S5: itemHandle is scaleType=center over a 55dp box with paddingLeft
        // video_item_search_image_right_margin — the capture measures 24vp of glyph behind a
        // 6vp gap, tinted like every other list icon (?android:textColorSecondary).
        .width(HANDLE_ICON_SIZE)
        .height(HANDLE_ICON_SIZE)
        .fillColor(COLOR_ICON_TINT)
        .margin({ left: $r('app.float.video_item_search_image_right_margin') })
        // S6 — the handle's own contentDescription (R.string.detail_drag_description), which
        // is what the capture names this icon-only control by.
        .accessibilityText($r('app.string.detail_drag_description'))
        // An Image is draggable by default, and that SYSTEM drag-and-drop (a floating copy of
        // the glyph) was starting on the handle and cancelling the pan (hilog AceDrag
        // 'Drag gesture has been canceled'). Same trap PlayQueueItemHolder documents.
        .draggable(false)
        .onTouch((event: TouchEvent) => {
          if (event.type === TouchType.Down) {
            this.onHandleTouch(true);
          } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
            this.onHandleTouch(false);
          }
        })
        // OnClickGesture.drag -> itemTouchHelper.startDrag(), carried until the finger lifts;
        // isLongPressDragEnabled() is false in the source, so the pickup is the drag itself.
        //
        // This was an .onTouch listener, which is PASSIVE: it observes the touch stream without
        // ever entering the gesture arena, so the enclosing full-height List claimed the vertical
        // pan and the screen scrolled instead of the row moving. A PanGesture COMPETES, and
        // ArkUI resolves the innermost recognizer first, so the handle takes the pan off the
        // List - the same shape PlayQueueItemTouchCallback uses for the identical reorder drag.
        //
        // Exclusive with the TapGesture below: in the source the handle is not clickable, so a
        // tap on it must be CONSUMED rather than fall through to itemRoot's onClick -> navigate.
        // Pan comes first because it is the one that needs the slop to win.
        .gesture(GestureGroup(GestureMode.Exclusive,
          PanGesture({ direction: PanDirection.Vertical, distance: DRAG_SLOP })
            .onActionStart(() => {
              if (this.item !== null) {
                this.onRowDragStart(this.item);
              }
            })
            .onActionUpdate((event: GestureEvent) => {
              this.onRowDragUpdate(event.offsetY);
            })
            .onActionEnd(() => {
              this.onRowDragEnd();
            })
            .onActionCancel(() => {
              this.onRowDragEnd();
            }),
          TapGesture().onAction(() => {
            hilog.debug(0x0000, 'NewPipe', 'itemHandle: tap consumed - drag-only control');
          })
        ))
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .onAreaChange((oldValue: Area, newValue: Area) => {
      const measured: number = typeof newValue.height === 'number' ? newValue.height as number : 0;
      if (measured > 0) {
        this.onRowHeight(measured);
      }
    })
  }
}
