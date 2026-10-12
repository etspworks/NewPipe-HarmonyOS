/**
 * LicensePage (screen_license_page). Captured state S0003.
 *
 * The LICENCES half of the shared Compose About screen
 * (shared/.../screen/about/LicensePage.kt). presentation: page with its own routeUrl, so it is a
 * routed @Entry page that screen_about_screen pushes; the file is LicensePage.ets, NOT
 * LicensePagePage.ets - the plan's targetPage carries no doubled suffix.
 *
 * navOut is empty. Nothing is pushed from here.
 *
 * Structure read verbatim off LicensePage.kt / LibraryListItem.kt / LicenseDialog.kt:
 *  - a LazyColumn whose FIRST item is a static header block: app_license_title + app_license
 *    (license_app_header), the read_full_license TextButton (license_read_full), then
 *    title_licenses (license_third_party_header);
 *  - then `items(libraries, key = { it.id })` -> LibraryListItem, one shared row slug
 *    license_library_itemroot (Rule 12's list-row exception, and the plan's own idSlug). The
 *    row is `enabled = library.licenses.isNotEmpty()` and its description is
 *    license(developer, spdx) or not_available.
 *  - LicenseDialog is an OVERLAY hosted by THIS page (an AlertDialog reading the parent's
 *    licenseToShow), never a route. It is gated on
 *    `shouldShowLicenseDialog && licenseToShow.spdxID.isNotBlank()` - built as an ArkUI `if`
 *    below so the S4 conditional-variant check reads the real bound field.
 *
 * DATA: `libraries` is AboutViewModel's - it parses the bundled aboutlibraries.json rawfile off
 * the UI thread and publishes the list (AboutViewModel.kt:31-45). That parse is ported here in
 * aboutToAppear through the existing AboutLibraries.parse(); a literal library array would be a
 * provenance defect. The BOM carries 222 entries, so the list is a LazyForEach over an
 * IDataSource (Rule 7), keyed by library.id exactly as the source's `key = { it.id }`.
 * A failed parse legitimately leaves the list empty (the plan's fourth conditional variant), so
 * an empty list is not a defect on this screen.
 *
 * The dialog body reads composeResources files/LICENSES/<spdxID>.txt. The assets pass carried
 * those 8 files over as rawfile/licenses/<spdxID>.txt, and readLicenseBody() below reads the one
 * the selected licence names - never a transcribed literal. A licence whose file is missing
 * leaves the body EMPTY, which is what Res.readBytes' failure produces in the source too.
 */

import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AboutLibraries } from '../model/app/AboutLibraries';
import { Library } from '../model/app/Library';
import { License } from '../model/app/License';
import { ShareUtils } from '../common/share/ShareUtils';
import { ServiceLocator } from '../common/di/ServiceLocator';
import { libraryDescription, LibraryListItem } from '../components/LibraryListItem';
import { LicenseDialog } from '../components/LicenseDialog';
import { DIALOG_MASK_COLOR } from '../common/theme/ServiceTheme';

/** AboutViewModel.PATH_BOM. */
const PATH_BOM: string = 'aboutlibraries.json';
/** composeResources `files/LICENSES/<spdxID>.txt`, carried into rawfile by the assets pass. */
const PATH_LICENSES: string = 'licenses/';
/** Dimens.kt. */
const SPACE_XXSMALL: number = 2;
const SPACE_XSMALL: number = 4;
const SPACE_MEDIUM: number = 10;
/** ButtonDefaults.MinHeight / TextButtonContentPadding - the M3 TextButton box. */
const BUTTON_HEIGHT: number = 40;
const BUTTON_PADDING: number = 12;
/** theme/Color.kt - the shared module's own Material3 scheme; this screen has no capture. */
const COLOR_ON_SURFACE: string = '#231918';

/** `items(items = libraries, key = { library -> library.id })` over the parsed BOM. */
class LibraryDataSource implements IDataSource {
  private items: Library[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): Library {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos: number = this.listeners.indexOf(listener);
    if (pos >= 0) {
      this.listeners.splice(pos, 1);
    }
  }

  /** `_libraries.value = aboutLibraries.libraries` - the one publish the source makes. */
  submitList(items: Library[]): void {
    this.items = items;
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataReloaded();
    });
  }
}

@Entry
@Component
export struct LicensePage {
  /**
   * viewModel.libraries.collectAsStateWithLifecycle() - the parsed BOM, never a literal array.
   * A failed parse legitimately leaves it EMPTY (the plan's fourth conditional variant), and the
   * page then renders only the app-licence header.
   */
  @Watch('onLibrariesChanged') @State libraries: Library[] = [];
  /**
   * `items(items = libraries, key = { it.id })` - the list the LazyColumn actually renders, i.e.
   * the source's `val libraries by viewModel.libraries.collectAsStateWithLifecycle()` read at the
   * composition site. It is fed into librarySource below, because a LazyForEach needs a plain
   * IDataSource and an @State-wrapped one is not that (Rule 7).
   */
  @State libraryList: Library[] = [];
  /** LibraryListItem's `when` block: license(developer, spdx) or not_available, one per row. */
  @State libraryRowDescription: string[] = [];
  /** rememberSaveable { mutableStateOf(false) }. */
  @State shouldShowLicenseDialog: boolean = false;
  /** rememberSerializable { mutableStateOf(License()) }. */
  @State licenseToShow: License = new License();
  /** licenseToShow.spdxID - the file the dialog body is read from, and the dialog's own gate. */
  @State spdxID: string = '';
  /** licenseToShow.website - null/blank disables the dialog's Website button. */
  @State website: string | null = null;
  /** library.licenses - empty means the row is disabled and shows not_available. */
  @State licenses: string[] = [];
  /** Res.readBytes(files/LICENSES/${spdxID}.txt).decodeToString().lines(). */
  @State licenceDialogBody: string[] = [];
  /** parseLibraries() runs off the UI thread, so the page renders before the BOM lands. */
  @State isLoading: boolean = true;
  /** "Failed to parse BOM" - reported, but NOT a defect: an empty list is a legal outcome. */
  @State errorInfo: string = '';

  /** getItemCount()/getItem(): what LazyForEach reads. */
  private librarySource: LibraryDataSource = new LibraryDataSource();

  /**
   * T-0188: the overlay used to be composed inside this page's own Stack, so its size was a
   * percentage of the pager cell rather than of the window. Every other dialog in this app opens
   * through a `customStyle: true` controller; this one now does too, and the card's 92% finally
   * means 92% of the screen. `licenseToShow`/`licenceDialogBody` are handed over by reference
   * because the dialog opens before the licence text has been read off disk.
   */
  private licenseDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    customStyle: true,
    // onDismissRequest = onDismiss: tapping the scrim or pressing back closes it the same way.
    cancel: (): void => {
      this.shouldShowLicenseDialog = false;
    },
    builder: LicenseDialog({
      license: $licenseToShow,
      licenseContent: $licenceDialogBody,
      onOpenWebsite: (website: string): void => {
        this.openUrl(website);
      },
      onDismiss: (): void => {
        this.shouldShowLicenseDialog = false;
        this.licenseDialog.close();
      }
    })
  });

  /** `_libraries.value = aboutLibraries.libraries` - the one publish the source makes. */
  onLibrariesChanged(): void {
    this.libraryList = this.libraries;
    this.librarySource.submitList(this.libraries);
    this.libraryRowDescription =
      this.libraries.map((library: Library): string => libraryDescription(library));
  }

  /** AboutViewModel.init -> viewModelScope.launch(Dispatchers.IO) { parseLibraries() }. */
  async aboutToAppear(): Promise<void> {
    this.isLoading = true;
    this.errorInfo = '';
    try {
      const context: common.Context = getContext(this) as common.Context;
      const bytes: Uint8Array = await context.resourceManager.getRawFileContent(PATH_BOM);
      const parsed: AboutLibraries =
        AboutLibraries.parse(util.TextDecoder.create('utf-8').decodeToString(bytes));
      this.libraries = parsed.libraries;
    } catch (err) {
      // Logger.e(messageString = "Failed to parse BOM", throwable = exception) - the source
      // swallows it and leaves the list EMPTY, so the page renders only the app-licence header.
      this.errorInfo = (err as Error).message;
      hilog.error(0x0000, 'LicensePage', 'Failed to parse BOM: %{public}s', (err as Error).message);
    }
    this.isLoading = false;
  }

  /**
   * LicenseDialog's LaunchedEffect(license):
   *   licenseContent = Res.readBytes("files/LICENSES/${license.spdxID}.txt")
   *       .decodeToString().lines()
   * The read lives on the PAGE (it owns licenseToShow) and the lines are handed down to the
   * overlay. A missing file leaves the body empty rather than crashing the dialog.
   */
  private async readLicenseBody(spdxID: string): Promise<void> {
    if (spdxID.length === 0) {
      this.licenceDialogBody = [];
      return;
    }
    try {
      const context: common.Context = getContext(this) as common.Context;
      const bytes: Uint8Array =
        await context.resourceManager.getRawFileContent(PATH_LICENSES + spdxID + '.txt');
      const text: string = util.TextDecoder.create('utf-8').decodeToString(bytes);
      // .lines() splits on CR, LF and CRLF; the bundled files are CRLF, so a bare '\n' split
      // would leave a trailing CR on every line.
      this.licenceDialogBody = text.split(/\r\n|\r|\n/);
    } catch (err) {
      this.licenceDialogBody = [];
      hilog.error(0x0000, 'LicensePage', 'reading licence %{public}s: %{public}s',
        spdxID, (err as Error).message);
    }
  }

  /** onOpenUrl(url) -> shareHandler.openUrlInBrowser(url). */
  private openUrl(url: string): void {
    const share: ShareUtils = ServiceLocator.get().share;
    share.openUrlInBrowser(url)
      .catch((err: Error): void => {
        hilog.error(0x0000, 'LicensePage', 'openUrlInBrowser failed: %{public}s', err.message);
      });
  }

  /** The two paths that set licenseToShow and open the dialog. */
  private showLicense(license: License): void {
    this.licenseToShow = license;
    this.spdxID = license.spdxID;
    this.website = license.website;
    this.licenceDialogBody = [];
    // ...&& licenseToShow.spdxID.isNotBlank() - the gate the composed `if` used to carry.
    if (license.spdxID === '') {
      return;
    }
    this.shouldShowLicenseDialog = true;
    this.licenseDialog.open();
    this.readLicenseBody(license.spdxID)
      .catch((err: Error): void => {
        hilog.error(0x0000, 'LicensePage', 'licence body: %{public}s', err.message);
      });
  }

  build() {
    Stack() {
      // LazyColumn(verticalArrangement = Arrangement.spacedBy(spaceXXSmall)).
      List({ space: SPACE_XXSMALL }) {
        // item { ... } - the app-licence header block, static chrome.
        ListItem() {
          Column({ space: SPACE_XSMALL }) {
            Column({ space: SPACE_XSMALL }) {
              Text($r('app.string.app_license_title'))
                .fontSize(22)
                .lineHeight(28)
                .fontColor(COLOR_ON_SURFACE)
                .width('100%')
              Text($r('app.string.app_license'))
                .fontSize(14)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
                .width('100%')
            }
            .id('license_app_header')
            .width('100%')
            .alignItems(HorizontalAlign.Start)

            // TextButton(fillMaxWidth().wrapContentWidth(Alignment.End)) - the app's own licence.
            Text($r('app.string.read_full_license'))
              .id('license_read_full')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.about_link_color'))
              .textAlign(TextAlign.Center)
              .height(BUTTON_HEIGHT)
              .padding({ left: BUTTON_PADDING, right: BUTTON_PADDING })
              .onClick((): void => {
                // licenseToShow = License(name = NewPipe, website = https://newpipe.net/,
                //                         spdxID = GPL-3.0-or-later)
                this.licenses = ['GPL-3.0-or-later'];
                this.showLicense(new License('NewPipe', this.licenses[0],
                  'https://newpipe.net/'));
              })

            Text($r('app.string.title_licenses'))
              .id('license_third_party_header')
              .fontSize(22)
              .lineHeight(28)
              .fontColor(COLOR_ON_SURFACE)
              .width('100%')
          }
          .width('100%')
          .padding(SPACE_MEDIUM)
          .alignItems(HorizontalAlign.End)
        }

        // items(items = libraries, key = { library -> library.id }).
        LazyForEach(this.librarySource, (library: Library) => {
          ListItem() {
            LibraryListItem({
              library: library,
              onSelected: (): void => {
                // licenseToShow = License(library.name, library.website, library.licenses.first())
                this.licenses = library.licenses;
                this.showLicense(new License(library.name,
                  this.licenses.length > 0 ? this.licenses[0] : '', library.website));
              }
            })
          }
        }, (library: Library) => library.id)
      }
      .width('100%')
      .height('100%')
    }
    .id('LicensePage')
    .width('100%')
    .height('100%')
  }
}
