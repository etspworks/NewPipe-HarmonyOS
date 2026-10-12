/**
 * S3 - port of org.schabi.newpipe.views.CustomCollapsingToolbarLayout, the AppBarLayout child that
 * wraps fragment_channel's channel_metadata block.
 *
 * The source subclass exists for exactly one reason: CollapsingToolbarLayout consumes the window
 * insets, so its `fitsSystemWindows="true"` children never see them; overrideListener() passes them
 * through again. The ArkUI equivalent of "this container's children get the system inset" is
 * expandSafeArea on the container, which is what this does.
 *
 * Everything else the source class inherits (parallax, scroll flags) is layout, so it is a slot
 * here: the host passes the metadata block as the content builder.
 */

import { servicePrimaryColor } from '../common/theme/ServiceTheme';

/** Taller than any header this container will ever hold: the cap is inert at this value. */
const UNBOUNDED_HEIGHT: number = 10000;

@Component
export struct CustomCollapsingToolbarLayout {
  /** ?attr/colorPrimary follows the service the drawer selected; see servicePrimaryColor(). */
  @StorageProp('mainSelectedServiceId') activeServiceId: number = 0;

  /** app:layout_scrollFlags="scroll|exitUntilCollapsed" - how much never scrolls away, in vp. */
  @Prop collapsedHeight: number = 0;
  /**
   * How far the content below has scrolled, in vp. `scroll|exitUntilCollapsed` spends that on the
   * header first: it shrinks from its natural height down to collapsedHeight and no further.
   */
  @Prop collapsed: number = 0;
  /**
   * The natural height, so the host can clamp `collapsed` against it. The host owns the clamp
   * because it owns the scroll offset; this container only knows how tall it wants to be.
   */
  onMeasured: (height: number) => void = (): void => {
  };
  /** The last height measured while fully expanded. */
  @State private naturalHeight: number = 0;
  /** The channel_metadata block. */
  @BuilderParam content: () => void = this.emptyContent;

  @Builder
  emptyContent() {
    Column() {
    }
  }

  build() {
    Column() {
      this.content()
    }
    .id('app_bar_layout')
    .width('100%')
    // AppBarLayout's default background is ?attr/colorPrimary - the red band the banner,
    // avatar, title and subscribe button all sit on in the S0047 capture.
    .backgroundColor(servicePrimaryColor(this.activeServiceId))
    .constraintSize({
      minHeight: this.collapsedHeight,
      // A cap rather than a height, and NO cap at all while fully expanded: that is what keeps the
      // container content-sized, so it can still be measured and can still grow when the banner
      // image or the subtitle line arrives.
      maxHeight: this.collapsed === 0
        ? UNBOUNDED_HEIGHT
        : Math.max(this.collapsedHeight, this.naturalHeight - this.collapsed)
    })
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      // A measurement is only the NATURAL height while nothing is collapsed; once the cap above is
      // binding, what comes back is the cap itself. Reading it on every expanded frame rather than
      // once is what lets a late-loading banner correct the value.
      const measured: number = Number(newArea.height);
      if (this.collapsed === 0 && measured > 0 && measured !== this.naturalHeight) {
        this.naturalHeight = measured;
        this.onMeasured(measured);
      }
    })
    // overrideListener(): let the inset reach the children instead of being eaten here.
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
    .clip(true)
  }
}
