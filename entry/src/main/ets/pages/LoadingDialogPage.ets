/**
 * S2 shell - LoadingDialog (screen_loading_dialog). presentation: modal. SOURCE-ONLY.
 *
 * NOT a routed page: an OVERLAY whose hostScreen is screen_persistent, mounted by
 * PersistentFragmentPage with .bindContentCover() and reading that host's state. It is
 * deliberately absent from main_pages.json and must never be pushed. RouterActivityPage holds
 * its own slot for the same dialog on its own menu path; this export fits that call site too -
 * only `show` is required, `toolbarTitle` defaults.
 *
 * Read verbatim off LoadingDialog.java + download_loading_dialog.xml:
 *  - a reusable busy modal with a caller-supplied @StringRes title; the only call site is
 *    PersistentFragment.openDownloadDialog, which passes R.string.loading_metadata_title and
 *    dismisses it when the stream info arrives or the request fails;
 *  - initToolbar(): toolbar.setTitle(getString(title)) and
 *    toolbar.setNavigationOnClickListener(v -> dismiss()) - the Close control below;
 *  - R.id.loader is an indeterminate ProgressBar -> LoadingProgress();
 *  - onCreate calls setCancelable(false), so Back and outside taps do NOT dismiss it: the
 *    toolbar navigation button and the owning code's dismiss() are the only exits. That is why
 *    the host mounts it as a content cover rather than a dismissable sheet.
 *
 * The RelativeLayout has no layout_below on the ProgressBar, so in the source the spinner is
 * positioned by fixed 150dp/100dp margins measured from the dialog's own top edge.
 *
 * initToolbar() sets NO navigation icon (unlike DownloadDialog, which sets ic_arrow_back), only
 * setNavigationOnClickListener(v -> dismiss()); the toolbar's own theme supplies the affordance.
 * The navigation slot is rendered here with the same asset every other toolbar in this app uses,
 * carrying the plan's `Close` slug so the replay can reach it.
 */

/* toolbar_layout.xml: a 24dp glyph centred in the 56dp ?attr/actionBarSize target. */
const ICON_SIZE: number = 24;
const TOOLBAR_HEIGHT: number = 56;
/* download_loading_dialog.xml positions the spinner by fixed margins, not by layout_below. */
const LOADER_MARGIN_TOP: number = 150;
const LOADER_MARGIN_BOTTOM: number = 100;

@Component
export struct LoadingDialogPage {
  /** Two-way with the host's visibility flag: the toolbar navigation icon calls dismiss(). */
  @Link isShown: boolean;
  /** The @StringRes constructor argument, resolved by the caller. Never a literal in S4. */
  @Prop toolbarTitle: string = '';

  build() {
    Column() {
      // toolbar_layout
      Row() {
        Image($r('app.media.ic_arrow_back'))
          .id('Close')
          .width(TOOLBAR_HEIGHT)
          .height(TOOLBAR_HEIGHT)
          .padding((TOOLBAR_HEIGHT - ICON_SIZE) / 2)
          .objectFit(ImageFit.Contain)
          .fillColor($r('app.color.on_primary'))
          .accessibilityText('Close')
          .onClick(() => {
            // setNavigationOnClickListener(v -> dismiss()).
            this.isShown = false;
          })
        // Widget.AppCompat.Toolbar.Title: 20sp medium, 16dp past the navigation button.
        Text(this.toolbarTitle)
          .id('Title')
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_primary'))
          .margin({ left: 16, right: 16 })
      }
      .width('100%')
      .height(TOOLBAR_HEIGHT)
      .alignItems(VerticalAlign.Center)
      // android:background="?attr/colorPrimary" on the Toolbar.
      .backgroundColor($r('app.color.primary'))

      // The RelativeLayout has no layout_below on the ProgressBar, so its 150dp top margin is
      // measured from the DIALOG's top, not from under the toolbar — the spinner overlaps the
      // toolbar band by design. Subtracting the toolbar height puts it at the same absolute y.
      LoadingProgress()
        .id('loader')
        .width(48)
        .height(48)
        .color($r('app.color.primary'))
        .margin({ top: LOADER_MARGIN_TOP - TOOLBAR_HEIGHT, bottom: LOADER_MARGIN_BOTTOM })
    }
    .id('LoadingDialogPage')
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    // The dialog window's own background: @color/light_dialog_background_color.
    .backgroundColor($r('app.color.dialog_background'))
  }
}
