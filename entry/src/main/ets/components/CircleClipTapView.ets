/*
 * S3 - port of org.schabi.newpipe.views.player.CircleClipTapView
 * (player_fast_seek_overlay.xml @+id/circle_clip_tap_view).
 *
 * The Android view clips a half-screen arc and expands a circle out of the tap point while a
 * double-tap fast seek is running. ArkUI has no onDraw here, so the same two visual facts are
 * built from real nodes: the half of the surface the seek applies to (the clip), and a circle
 * centred on the tap whose radius the owner animates. Colours and timing are S5.
 *
 * hitTestBehavior is Transparent because this sits OVER the video surface: without it the
 * overlay would swallow the single tap that shows/hides the controls.
 */

@Component
export struct CircleClipTapView {
  /** updatePosition(x, y) - where the double tap landed, in vp inside this overlay. */
  @Prop tapX: number = 0;
  @Prop tapY: number = 0;
  /** DisplayPortion: false = left half (rewind), true = right half (forward). */
  @Prop forward: boolean = true;
  /** The circle only exists while a fast-seek gesture is running. */
  @Prop showing: boolean = false;
  /** The animated circle radius; the owner drives it, as ValueAnimator does in the source. */
  @Prop circleRadius: number = 0;

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.showing) {
        // @color/white_overlay_color: the arc the source paints under the finger. A Circle
        // with no fill is drawn in the default black over black video - invisible, which is
        // what "no ripple was displayed" was.
        Circle()
          .width(this.circleRadius * 2)
          .height(this.circleRadius * 2)
          .fill('#40FFFFFF')
          .position({ x: this.tapX - this.circleRadius, y: this.tapY - this.circleRadius })
      }
    }
    .id('circle_clip_tap_view')
    .width('50%')
    .height('100%')
    .clip(true)
    .hitTestBehavior(HitTestMode.Transparent)
  }
}
