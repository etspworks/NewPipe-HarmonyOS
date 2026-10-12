/**
 * ?attr/listChoiceIndicatorSingle - the radio that marks the current entry in a single-choice
 * dialog.
 *
 * The reference draws a HOLLOW ring with a concentric dot: an accent ring and an accent dot when
 * selected, a grey ring and nothing inside when not. ArkUI's stock `Radio` draws a filled disc
 * with a white tick however it is styled - `radioStyle` reaches the fill and the border colour,
 * not the shape - and that is the "button design (radio button) is not the same" eleven SETTINGS
 * cards report against four different dialogs.
 *
 * So the indicator is drawn rather than delegated. The same shape already shipped inline in
 * ContentSettingsFragmentPage's app-language dialog; this is that shape, once, for the dialogs
 * that were still using the stock control.
 */
const COLOR_PRIMARY: Resource = $r('app.color.primary');
const COLOR_SECONDARY_TEXT: Resource = $r('app.color.on_surface_variant');

/** The reference's ring measures ~18vp across; 20 inside the 24vp footprint the rows reserve. */
const RING_SIZE: number = 20;
const RING_STROKE: number = 2;
const DOT_SIZE: number = 10;

@Component
export struct ChoiceIndicator {
  @Prop checked: boolean = false;
  /**
   * The footprint the row reserves. The dialogs this replaces all used a 24vp Radio with a 20vp
   * gap to the label, and that spacing is not what the cards complain about - only the glyph is.
   * The ring is centred in the caller's box, so the row metrics do not move.
   */
  @Prop box: number = 24;

  build() {
    Stack() {
      Stack() {
        if (this.checked) {
          Column()
            .width(DOT_SIZE)
            .height(DOT_SIZE)
            .borderRadius(DOT_SIZE / 2)
            .backgroundColor(COLOR_PRIMARY)
        }
      }
      .width(RING_SIZE)
      .height(RING_SIZE)
      .borderRadius(RING_SIZE / 2)
      .borderWidth(RING_STROKE)
      .borderColor(this.checked ? COLOR_PRIMARY : COLOR_SECONDARY_TEXT)
    }
    .width(this.box)
    .height(this.box)
  }
}
