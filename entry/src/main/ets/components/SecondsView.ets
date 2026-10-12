/*
 * S3 - port of org.schabi.newpipe.views.player.SecondsView
 * (player_fast_seek_overlay.xml @+id/seconds_view, layout player_fast_seek_seconds_view.xml).
 *
 * Three chevrons plus the "N seconds" quantity string. setForwarding() rotates the triangle
 * container 180deg for a rewind; startAnimation() runs the three icons' alphas in sequence. The
 * alpha CURVE is style (S5); the structure is the rotated container and the seconds label.
 */

@Component
export struct SecondsView {
  /** seconds: the accumulated fast-seek amount the quantity string formats. */
  @Prop seconds: number = 0;
  /** setForwarding(isForward): triangleContainer.rotation = isForward ? 0 : 180. */
  @Prop forward: boolean = true;
  /** icon1 / icon2 / icon3 alphas, driven by the owner's animator. */
  @Prop iconAlpha: number[] = [1, 1, 1];

  private alphaAt(index: number): number {
    return index < this.iconAlpha.length ? this.iconAlpha[index] : 1;
  }

  build() {
    Column() {
      Row() {
        Image($r('app.media.ic_play_seek_triangle'))
          .id('icon1')
          .width(20)
          .height(20)
          .fillColor($r('app.color.on_primary'))
          .opacity(this.alphaAt(0))
        Image($r('app.media.ic_play_seek_triangle'))
          .id('icon2')
          .width(20)
          .height(20)
          .fillColor($r('app.color.on_primary'))
          .opacity(this.alphaAt(1))
        Image($r('app.media.ic_play_seek_triangle'))
          .id('icon3')
          .width(20)
          .height(20)
          .fillColor($r('app.color.on_primary'))
          .opacity(this.alphaAt(2))
      }
      .id('triangle_container')
      .rotate({ angle: this.forward ? 0 : 180 })

      /** tvSeconds: getQuantityString(R.plurals.seconds, seconds, seconds). */
      // @style/Player.SecondsView: white on the darkened surface. Without a colour this drew
      // in the default near-black over near-black video and could not be read at all.
      Text((this.forward ? '+' : '-') + this.seconds + 's')
        .id('tv_seconds')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.on_primary'))
        .margin({ top: 4 })
    }
    .id('seconds_view')
    .hitTestBehavior(HitTestMode.Transparent)
  }
}
