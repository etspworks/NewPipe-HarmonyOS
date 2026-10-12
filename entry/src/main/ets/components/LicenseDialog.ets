/*
 * S3 - port of shared/.../screen/about/LicenseDialog.kt.
 *
 * An OVERLAY hosted by LicensePage (an AlertDialog reading its parent's `licenseToShow`), NOT a
 * route: LicensePageContent composes it inside its own body under
 *   if (shouldShowLicenseDialog && licenseToShow.spdxID.isNotBlank())
 * so the page owns the state and this struct only renders it.
 *
 *   AlertDialog(
 *     title          = { Text(license.name) },
 *     text           = { LazyColumn(testTag TEST_TAG_LICENSE_TEXT) { items(licenseContent) { Text(it) } } },
 *     onDismissRequest = onDismiss,
 *     dismissButton  = { TextButton(testTag license_dialog_website,
 *                                   onClick = { onOpenWebsite(license.website!!) },
 *                                   enabled = !license.website.isNullOrBlank()) { Text(website_title) } },
 *     confirmButton  = { TextButton(testTag license_dialog_done, onClick = onDismiss) { Text(done) } })
 *
 * The licence BODY is read from files/LICENSES/<spdxID>.txt and split into lines - one Text per
 * line - so it is data, never a transcribed literal. The page performs that read (S4) and hands
 * the lines down here.
 *
 * T-0188: it is opened through a `customStyle: true` CustomDialogController, like every other
 * dialog in this app, rather than being composed inside LicensePage's own body. Composed there it
 * could only be a percentage of the pager cell - the About screen spends 56vp on the toolbar and
 * 48vp on the tab strip before the cell starts - so a 92% card covered 73.7% of the window where
 * the reference's AlertDialog covers 91.2%. A dialog controller sizes against the window, which is
 * what an AlertDialog does on the reference, and brings its own scrim so this file no longer draws
 * one. The two bodies are @Link: the page opens the dialog first and fills the licence text from
 * disk afterwards, so the content has to keep flowing in after open.
 */

import { License } from '../model/app/License';

/** M3 AlertDialog metrics: 24dp padding, 28dp corner, 40dp text buttons. */
const DIALOG_PADDING: number = 24;
/**
 * T-1539, then T-0188: a Compose AlertDialog over a long licence grows to its window minus a
 * margin, and the list inside it is what scrolls. These are percentages of the DIALOG's box, which
 * under customStyle is the window - so they finally mean what they say.
 */
const DIALOG_WIDTH: string = '92%';
const DIALOG_HEIGHT: string = '92%';
const DIALOG_CORNER: number = 28;
const BUTTON_HEIGHT: number = 40;
const BUTTON_PADDING: number = 12;
/*
 * S5 - AlertDialogDefaults over the shared module's Material3 scheme: the container is
 * surfaceContainerHighLight, the title onSurfaceLight, the body onSurfaceVariantLight and both
 * TextButton labels primaryLight. No sid captures this dialog, so theme/Color.kt is the truth.
 */
const COLOR_DIALOG_CONTAINER: string = '#F6E4E2';
const COLOR_ON_SURFACE: string = '#231918';
const COLOR_ON_SURFACE_VARIANT: string = '#534342';

@CustomDialog
export struct LicenseDialog {
  controller?: CustomDialogController;
  /** rememberSerializable { mutableStateOf(License()) } in the page. */
  @Link license: License;
  /** Res.readBytes("files/LICENSES/${license.spdxID}.txt").decodeToString().lines(). */
  @Link licenseContent: string[];
  /** TextButton(onClick = { onOpenWebsite(license.website!!) }). */
  onOpenWebsite: (website: string) => void = (website: string): void => {
    console.info('LicenseDialog: onOpenWebsite not bound (' + website + ')');
  };
  /** onDismissRequest / confirmButton onClick. */
  onDismiss: () => void = (): void => {
    console.info('LicenseDialog: onDismiss not bound');
  };

  /** !license.website.isNullOrBlank() - the Website button's own enabled guard. */
  private hasWebsite(): boolean {
    const site: string | null = this.license.website;
    return site !== null && site.length > 0;
  }

  build() {
    // The scrim is the dialog controller's; tapping it raises `cancel`, which the page wires to
    // the same onDismiss.
    Column() {
      // title = { Text(license.name) }
      Text(this.license.name)
        .id('license_dialog_title')
        .fontSize(24)
        .lineHeight(32)
        .fontColor(COLOR_ON_SURFACE)
        .width('100%')

      // text = { LazyColumn { items(licenseContent) { line -> Text(line) } } }
      List() {
        ForEach(this.licenseContent, (line: string) => {
          ListItem() {
            Text(line)
              .fontSize(14)
              .lineHeight(20)
              .fontColor(COLOR_ON_SURFACE_VARIANT)
              .width('100%')
          }
        }, (line: string, index: number) => index.toString())
      }
      // The source's tag is TEST_TAG_LICENSE_TEXT; the plan's slug for it - and so the one the
      // gates read - is 'Licence dialog text'.
      .id('Licence dialog text')
      .width('100%')
      .layoutWeight(1)

      Row() {
        Text($r('app.string.website_title'))
          .id('license_dialog_website')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.about_link_color'))
          .textAlign(TextAlign.Center)
          .height(BUTTON_HEIGHT)
          .padding({ left: BUTTON_PADDING, right: BUTTON_PADDING })
          .enabled(this.hasWebsite())
          .onClick((): void => {
            const site: string | null = this.license.website;
            if (site !== null) {
              this.onOpenWebsite(site);
            }
          })

        Text($r('app.string.done'))
          .id('license_dialog_done')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.about_link_color'))
          .textAlign(TextAlign.Center)
          .height(BUTTON_HEIGHT)
          .padding({ left: BUTTON_PADDING, right: BUTTON_PADDING })
          .onClick((): void => {
            this.onDismiss();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
    }
    .width(DIALOG_WIDTH)
    .height(DIALOG_HEIGHT)
    .padding(DIALOG_PADDING)
    .borderRadius(DIALOG_CORNER)
    .backgroundColor(COLOR_DIALOG_CONTAINER)
    .alignItems(HorizontalAlign.Start)
  }
}
