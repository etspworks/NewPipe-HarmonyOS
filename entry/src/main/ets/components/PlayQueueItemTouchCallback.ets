/*
 * S3 - port of org.schabi.newpipe.player.playqueue.PlayQueueItemTouchCallback, the
 * ItemTouchHelper.SimpleCallback(UP|DOWN, LEFT|RIGHT) the play-queue lists attach.
 *
 * It is a BEHAVIOUR object in the source, not a view, so there is no XML to mirror. ArkUI has no
 * ItemTouchHelper: the two gestures it installs (a vertical drag that reorders, a horizontal
 * swipe that removes) belong to the row itself. This struct is therefore the row WRAPPER that
 * carries them, and the concrete holder renders as its body - the same shape InfoItemHolder uses
 * for click / long-click.
 *
 * onMove(source, target) and onSwiped(index) keep the source's own signatures, so the owning
 * screen wires them to PlayQueue.move() / PlayQueue.remove() unchanged.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';

/** SimpleCallback's minimum drag distance before a row is considered picked up, in vp. */
const DRAG_SLOP: number = 12;
/** getSwipeEscapeVelocity(): how far a horizontal swipe must travel to dismiss the row. */
const SWIPE_THRESHOLD: number = 96;

@Component
export struct PlayQueueItemTouchCallback {
  /** The row's own position, which is what onMove/onSwiped are expressed in. */
  @Prop index: number = 0;
  /** onMove(source, target): PlayQueue.move(sourceIndex, targetIndex). */
  onMove: (fromIndex: number, toIndex: number) => void =
    (fromIndex: number, toIndex: number): void => {
      hilog.debug(0x0000, 'NewPipe', 'PlayQueueItemTouchCallback: move %{public}d->%{public}d unbound',
        fromIndex, toIndex);
    };
  /** onSwiped(index): PlayQueue.remove(index). */
  onSwiped: (index: number) => void = (index: number): void => {
    hilog.debug(0x0000, 'NewPipe', 'PlayQueueItemTouchCallback: swipe %{public}d unbound', index);
  };
  /** Row height in vp, so a vertical drag maps to a number of rows the way a drag does. */
  @Prop rowHeight: number = 64;

  @BuilderParam body: () => void = this.emptyBody;

  @Builder
  emptyBody() {
    Row()
  }

  build() {
    Column() {
      this.body()
    }
    .width('100%')
    .gesture(
      PanGesture({ distance: DRAG_SLOP })
        .onActionEnd((event: GestureEvent) => {
          if (Math.abs(event.offsetX) >= SWIPE_THRESHOLD
            && Math.abs(event.offsetX) > Math.abs(event.offsetY)) {
            this.onSwiped(this.index);
            return;
          }
          const rows: number = Math.round(event.offsetY / this.rowHeight);
          if (rows !== 0) {
            this.onMove(this.index, this.index + rows);
          }
        })
    )
  }
}
