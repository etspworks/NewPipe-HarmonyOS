/**
 * S3 — port of net.newpipe.app.composable.TopAppBar (shared/composable/TopAppBar.kt).
 *
 * The SHARED bar both Compose screens use: an optional title, an optional navigate-up icon
 * button, and a caller-supplied actions slot. Structure only, per the source:
 *   - `title: String? = null` with `{ if (title != null) Text(text = title) }` — the title slot
 *     is EMPTY, not blank, when no title is given, so the branch is a real condition here.
 *   - `onNavigateUp: (() -> Unit)? = null` — the whole IconButton is absent when nothing wires
 *     it, which is why `hasNavigateUp` gates the icon rather than the handler being a no-op.
 *   - `Modifier.testTag("topbar_navigate_up")` is the source's own slug, so it is the `.id()`.
 *
 * `colors: TopAppBarColors = currentServiceTopAppBarColors()` is deliberately NOT ported here:
 * it carries no structure, and S5 applies the bar's colours from the style baseline.
 *
 * S5 — the style baseline's toolbar tokens, which are the same Widget.AppCompat.Toolbar metrics
 * every other bar in this app uses: 56vp tall on `color.primary`, a 24vp white glyph centred in
 * a 56vp navigation target, and a 20fp Medium white title at the 72vp title inset. Style only —
 * no control added, removed, re-bound or re-kinded.
 */
import { servicePrimaryColor } from '../common/theme/ServiceTheme';

/** space.toolbarHeight / space.navButtonSize / space.toolbarTitleInset, from styleBaseline. */
const BAR_HEIGHT: number = 56;
const NAV_BUTTON_SIZE: number = 56;
const NAV_ICON_PADDING: number = 16;
const TITLE_INSET: number = 72;
const TITLE_SIZE: number = 20;
const BAR_END_PADDING: number = 4;

@Component
export struct TopAppBar {
  /** ?attr/colorPrimary follows the service the drawer selected; see servicePrimaryColor(). */
  @StorageProp('mainSelectedServiceId') activeServiceId: number = 0;

  /** title = { if (title != null) Text(text = title) }. */
  title: ResourceStr = '';
  /** Whether the source passed a title at all (`title != null`). */
  hasTitle: boolean = true;
  /** navigationIcon: Painter = painterResource(Res.drawable.ic_arrow_back). */
  navigationIcon: Resource = $r('app.media.ic_arrow_back');
  /** contentDescription = stringResource(Res.string.navigate_back). */
  navigationIconLabel: Resource = $r('app.string.navigate_back');
  /** Whether `onNavigateUp` was supplied — null hides the whole IconButton in the source. */
  hasNavigateUp: boolean = false;
  onNavigateUp: () => void = (): void => {
  };
  /** actions: @Composable (RowScope.() -> Unit) = {} — an empty trailing slot by default. */
  @BuilderParam actions: () => void = this.noActions;

  @Builder
  noActions() {
    Row()
  }

  build() {
    Row() {
      if (this.hasNavigateUp) {
        Image(this.navigationIcon)
          .id('topbar_navigate_up')
          .accessibilityText(this.navigationIconLabel)
          .width(NAV_BUTTON_SIZE)
          .height(NAV_BUTTON_SIZE)
          .padding(NAV_ICON_PADDING)
          .objectFit(ImageFit.Contain)
          .fillColor($r('app.color.on_primary'))
          .onClick((): void => {
            this.onNavigateUp();
          })
      }

      if (this.hasTitle) {
        Text(this.title)
          .id('topbar_title')
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontSize(TITLE_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_primary'))
          // The title sits at the toolbar inset whether or not the Up button occupies it.
          .margin({ left: this.hasNavigateUp ? TITLE_INSET - NAV_BUTTON_SIZE : TITLE_INSET })
      }

      this.actions()
    }
    .width('100%')
    .height(BAR_HEIGHT)
    .padding({ right: BAR_END_PADDING })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(servicePrimaryColor(this.activeServiceId))
  }
}
