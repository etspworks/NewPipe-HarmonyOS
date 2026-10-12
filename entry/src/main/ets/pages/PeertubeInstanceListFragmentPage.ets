/**
 * S3 - PeertubeInstanceListFragment (screen_peertube_instance_list): the real view tree, unstyled.
 *
 * fragment_instance_list.xml: instanceHelpTV over the `instances` RecyclerView, a
 * loading_progress_bar shown while an added instance is fetched, and the addInstanceButton FAB.
 * The row is item_instance.xml and lives in components/InstanceListAdapter.ets (comp_instance_list
 * _adapter): instanceIcon / instanceName / instanceUrl / selectInstanceRB / handle. Plain Fragment,
 * NOT a preference screen, reached from ContentSettingsFragment. hostedBy screen_settings_activity,
 * which PUSHES this page - SettingsActivityPage carries that push. No navOut.
 *
 * This is the PeerTube SERVICE-INSTANCE SELECTOR: the chosen instance is the base URL every
 * PeerTube extractor call is built on, so it is part of the multi-service surface.
 *
 * Structure this pass added on top of the S2 shell:
 *  - the toolbar (onResume pushes @string/peertube_instance_url_title into it) with the Up
 *    affordance and the ONE options-menu item, menu_chooser_fragment.xml's
 *    menu_item_restore_default (showAsAction=always, so it is an icon in the bar, not a sheet);
 *  - the extracted row adapter, replacing the shell's single representative row;
 *  - the two AlertDialogs the fragment builds by hand: showAddItemDialog(dialog_edit_text.xml,
 *    title peertube_instance_add_title, icon ic_placeholder_peertube, Cancel/OK) and
 *    restoreDefaults()'s confirmation (restore_defaults / restore_defaults_confirmation).
 *
 * The three interaction modes live in the adapter, and their VETOES live here, exactly as the
 * source splits them: swiping the SELECTED row is refused, the list is never left empty, and drag
 * needs getItemCount() > 1.
 *
 * S4 wiring, all of it through svc_peertube_instances (common/extractor/PeertubeInstances.ts,
 * the port of PeertubeHelper plus the fragment's non-UI half):
 *  - onViewCreated: submitList(PeertubeHelper.getInstanceList(context)); onCreate:
 *    selectedInstance = PeertubeHelper.getCurrentInstance(), which is PeerTube.getInstance() on
 *    the ported ServiceRegistry - the PeerTube service IS instance-relative, so the selected row
 *    and the extractor base url are one fact (feat_multi_service_extractor);
 *  - addInstance(url): cleanUrl() rejects a non-https url (peertube_instance_add_https_only) or a
 *    duplicate (peertube_instance_add_exists) with a toast, then validateInstance() fetches
 *    /api/v1/config behind loading_progress_bar and a failure toasts peertube_instance_add_fail;
 *  - selectInstance(instance): PeertubeHelper.selectInstance + Constants.KEY_MAIN_PAGE_CHANGE,
 *    flushed so it survives a relaunch;
 *  - restoreDefaults(): the saved list is cleared, DEFAULT_INSTANCE re-selected, list re-submitted;
 *  - saveChanges(): the source runs it in onPause, so its ArkUI home is onPageHide /
 *    aboutToDisappear. The swaps a drag emits are coalesced through the app's shared
 *    DebounceSaver (feat_drag_reorder) - DEVIATION: it writes the same JSON slightly earlier than
 *    onPause, so a reorder also survives a kill that never reaches onPause.
 * No visual styling here; S5 owns the card, its radius/elevation and every metric.
 */
import { promptAction, router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  InstanceListAdapter,
  InstanceListDataSource,
  moveInstance
} from '../components/InstanceListAdapter';
import { Localization } from '../common/i18n/Localization';
import { PeertubeInstance } from '../model/extractor/PeertubeInstance';
import {
  CleanUrlError,
  CleanUrlResult,
  PeertubeInstances
} from '../common/extractor/PeertubeInstances';
import { PeerTube } from '../common/extractor/ServiceRegistry';
import { AppPreferences } from '../common/prefs/Preferences';
import { DebounceSaver } from '../common/util/DebounceSaver';
import { DIALOG_MASK_COLOR } from '../common/theme/ServiceTheme';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

const TAG: string = 'PeertubeInstanceListFragmentPage';

/** Toast.LENGTH_SHORT. */
const TOAST_SHORT_MS: number = 2000;

/**
 * How long the list may sit modified before it is written. The source writes only in onPause;
 * this coalesces a drag's per-row swaps into one write and still writes on leave.
 */
const SAVE_DEBOUNCE_MS: number = 1000;

/* S5 - style only, LightSettingsTheme (the theme every captured state of this screen renders in).
 * Reuses the run's style baseline (state.json generation.styleBaseline, source S0004): primary /
 * onPrimary / background / secondaryText and the 56vp toolbar with its 72vp title inset and 20fp
 * Medium bar title. The body metrics are fragment_instance_list.xml's own (the help text's 15dp
 * margin, the FAB's 16dp end/bottom), cross-checked against this screen's base.ui.json; the
 * colours are sampled from base.png. Neither dialog has a capture on this screen, so both take the
 * AlertDialog metrics of the one dialog this app DOES capture
 * (fragment_ExoPlayerSettingsFragment): a 294vp white card, 4vp radius, a 24vp gutter and black
 * borderless buttons. */
/** ?attr/colorPrimary - the toolbar, the FAB and the checked radio all sample (229,57,53). */
const COLOR_PRIMARY: Resource = $r('app.color.primary');
/** ?attr/actionColor - the Up glyph, the bar title, the action icon and the FAB's plus. */
const COLOR_ON_PRIMARY: Resource = $r('app.color.on_primary');
/** ?attr/windowBackground - light_background_color, the capture's #EEEEEE. */
const COLOR_SURFACE: Resource = $r('app.color.background');
/** ?android:textColorPrimary - #DE000000 is the capture's (33,33,33) over a white card. */
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');
/** ?android:textColorSecondary - the help text samples (109,109,109) over #EEEEEE. */
const COLOR_SECONDARY_TEXT: Resource = $r('app.color.on_surface_variant');
/** The AlertDialog surface: white, per the one dialog this app's captures record. */
const COLOR_DIALOG_SURFACE: Resource = $r('app.color.dialog_surface');
/** That same capture samples the dialog buttons at (0,0,0) - light_youtube_accent_color. */
const COLOR_ACCENT: Resource = $r('app.color.accent');
/**
 * ?android:attr/textColorLink, which this theme leaves at the platform default the capture samples
 * black on the linkified URL - the same ink InstanceListAdapter paints instanceUrl with.
 */
const COLOR_LINK: Resource = $r('app.color.accent');

/**
 * showAddItemDialog(context): DialogEditTextBinding inside an AlertDialog titled
 * peertube_instance_add_title with the ic_placeholder_peertube icon, Cancel and OK. OK reads
 * dialogEditText's text and hands it to addInstance(url).
 */
@CustomDialog
struct AddInstanceDialog {
  controller?: CustomDialogController;
  onSubmit: (url: string) => void = (url: string): void => {
    hilog.debug(0x0000, TAG, 'AddInstanceDialog: onSubmit(%{public}s) not bound', url);
  };
  /** The dialog's own field state; the page never sees a half-typed url. */
  @State enteredUrl: string = '';

  build() {
    Column() {
      // The AlertDialog's icon + alertTitle band: 20sp beside the 24dp icon, at the 24vp gutter.
      Row() {
        Image($r('app.media.ic_placeholder_peertube'))
          .width(24)
          .height(24)
          .objectFit(ImageFit.Contain)
        Text($r('app.string.peertube_instance_add_title'))
          .layoutWeight(1)
          .fontSize(20)
          .fontColor(COLOR_ON_SURFACE)
          .margin({ left: 8 })
      }
      .width('100%')
      .padding({ left: 24, right: 24, top: 18, bottom: 8 })
      .alignItems(VerticalAlign.Center)

      // dialog_edit_text.xml: a single-line field typed TYPE_CLASS_TEXT|TYPE_TEXT_VARIATION_URI
      // whose hint is peertube_instance_add_help.
      TextInput({ placeholder: $r('app.string.peertube_instance_add_help'), text: this.enteredUrl })
        .id('dialogEditText')
        .type(InputType.URL)
        .maxLines(1)
        .width('100%')
        .fontSize(16)
        .fontColor(COLOR_ON_SURFACE)
        .caretColor(COLOR_PRIMARY)
        .padding({ left: 24, right: 24 })
        .backgroundColor(Color.Transparent)
        .onChange((value: string): void => {
          this.enteredUrl = value;
        })

      // buttonPanel: borderless accent-coloured buttons, flush with the card's bottom-right.
      Row() {
        Button($r('app.string.cancel'))
          .id('button2')
          .height(42)
          .backgroundColor(Color.Transparent)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_ACCENT)
          .onClick(() => {
            this.controller?.close();
          })
        Button($r('app.string.ok'))
          .id('button1')
          .height(42)
          .backgroundColor(Color.Transparent)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_ACCENT)
          .onClick(() => {
            this.controller?.close();
            this.onSubmit(this.enteredUrl);
          })
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      .justifyContent(FlexAlign.End)
    }
    // The AlertDialog card: 294vp wide, white, a 4vp radius - not the platform's rounded sheet.
    .width(294)
    .backgroundColor(COLOR_DIALOG_SURFACE)
    .borderRadius(4)
    .alignItems(HorizontalAlign.Start)
  }
}

/**
 * restoreDefaults(): an AlertDialog over restore_defaults / restore_defaults_confirmation whose
 * negative button is a plain dismiss and whose positive button clears the saved list, re-selects
 * PeertubeInstance.DEFAULT_INSTANCE and re-submits.
 */
@CustomDialog
struct RestoreDefaultsDialog {
  controller?: CustomDialogController;
  onConfirm: () => void = (): void => {
    hilog.debug(0x0000, TAG, 'RestoreDefaultsDialog: onConfirm not bound');
  };

  build() {
    Column() {
      // alertTitle: 20sp at the dialog's 24vp gutter, 18vp above and 8vp below.
      Text($r('app.string.restore_defaults'))
        .width('100%')
        .fontSize(20)
        .fontColor(COLOR_ON_SURFACE)
        .padding({ left: 24, right: 24, top: 18, bottom: 8 })
      // The message body: 16sp on ?android:textColorSecondary, same gutter.
      Text($r('app.string.restore_defaults_confirmation'))
        .width('100%')
        .fontSize(16)
        .lineHeight(22)
        .fontColor(COLOR_SECONDARY_TEXT)
        .padding({ left: 24, right: 24, bottom: 16 })

      // buttonPanel: borderless accent-coloured buttons, flush with the card's bottom-right.
      Row() {
        Button($r('app.string.cancel'))
          .id('button2')
          .height(42)
          .backgroundColor(Color.Transparent)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_ACCENT)
          .onClick(() => {
            this.controller?.close();
          })
        Button($r('app.string.ok'))
          .id('button1')
          .height(42)
          .backgroundColor(Color.Transparent)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_ACCENT)
          .onClick(() => {
            this.controller?.close();
            this.onConfirm();
          })
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      .justifyContent(FlexAlign.End)
    }
    // The AlertDialog card: 294vp wide, white, a 4vp radius - not the platform's rounded sheet.
    .width(294)
    .backgroundColor(COLOR_DIALOG_SURFACE)
    .borderRadius(4)
    .alignItems(HorizontalAlign.Start)
  }
}

@Entry
@Component
export struct PeertubeInstanceListFragmentPage {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  /**
   * TRUE when this screen sits in SettingsActivityPage's settings_fragment_holder, which draws the
   * one toolbar for whatever it holds; FALSE when this page is the pushed route and nothing above
   * it carries a bar. The host passes it explicitly, the way ChannelFragmentPage takes
   * `hostedInMainShell`: a host-set AppStorage flag still reads true underneath a page the host
   * pushed, and MainSettingsFragmentPage pushes this very screen from inside that host. The
   * default is FALSE, so an unset value falls through to DRAWING the bar rather than to none.
   */
  @Prop hostDrawsToolbar: boolean = false;
  /** instanceListAdapter.getCurrentList() - the page owns the list, the adapter only renders it. */
  @State instancesList: PeertubeInstance[] = [];
  /** `selectedInstance` - PeertubeHelper.getCurrentInstance(), the swipe veto's yardstick. */
  @State peertubeSelectedInstance: PeertubeInstance = PeertubeInstance.DEFAULT_INSTANCE;
  /** Its url: what selectInstanceRB is checked against (preference peertube_selected_instance). */
  @State selectedRadio: string = '';
  /** The list saveChanges() last wrote to peertube_instance_list; '' until the first write. */
  @State persistedListOnLeave: string = '';
  /** binding.loadingProgressBar's VISIBLE window around the add-instance fetch. */
  @State isLoading: boolean = false;
  @State errorInfo: string = '';
  /**
   * getString(peertube_instance_url_help, getString(peertube_instance_list_url)), split around the
   * URL the format argument supplied: android:autoLink="web" linkifies exactly that substring, so
   * the label is one Text drawn in three Spans rather than three labels.
   */
  @State helpTextPrefix: string = '';
  @State helpLinkUrl: string = '';
  @State helpTextSuffix: string = '';

  private dataSource: InstanceListDataSource = new InstanceListDataSource();
  /** The shared reorder-persist util every reorderable screen in this app uses. */
  private saver: DebounceSaver | null = null;

  private addInstanceDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    customStyle: true,
    builder: AddInstanceDialog({
      onSubmit: (url: string): void => {
        this.addInstance(url);
      }
    })
  });

  private restoreDefaultsDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    customStyle: true,
    builder: RestoreDefaultsDialog({
      onConfirm: (): void => {
        this.restoreDefaults();
      }
    })
  });

  aboutToAppear(): void {
    const helpUrl: string = Localization.getString('peertube_instance_list_url');
    const help: string = Localization.getStringArgs('peertube_instance_url_help', [helpUrl]);
    // Locale-safe: the argument need not be at the end of every translation, and a translation
    // that dropped it leaves the whole string as the prefix, i.e. today's plain label.
    const linkAt: number = help.indexOf(helpUrl);
    this.helpTextPrefix = linkAt >= 0 ? help.substring(0, linkAt) : help;
    this.helpLinkUrl = linkAt >= 0 ? helpUrl : '';
    this.helpTextSuffix = linkAt >= 0 ? help.substring(linkAt + helpUrl.length) : '';
    this.saver = new DebounceSaver(SAVE_DEBOUNCE_MS, (): void => {
      this.saveChanges();
    });
    this.loadInstances();
  }

  /** onPause(): saveChanges(). */
  onPageHide(): void {
    this.saveChanges();
  }

  /** onDestroy(): disposables.clear() - and the last write, as onPause would have made it. */
  aboutToDisappear(): void {
    this.saveChanges();
    const saver: DebounceSaver | null = this.saver;
    if (saver !== null) {
      saver.dispose();
    }
    this.saver = null;
  }

  /**
   * onCreate + onViewCreated: `selectedInstance = PeertubeHelper.getCurrentInstance()` (which is
   * PeerTube.getInstance() on the ported registry) and
   * `submitList(PeertubeHelper.getInstanceList(context))`.
   */
  private loadInstances(): void {
    try {
      this.setSelectedInstance(PeerTube.getInstance());
      this.submitList(PeertubeInstances.getInstanceList());
      this.errorInfo = '';
    } catch (err) {
      const failure: Error = err as Error;
      this.errorInfo = failure.message;
      hilog.error(0x0000, TAG, 'getInstanceList: %{public}s', failure.message);
    }
  }

  /** instanceListAdapter.submitList(list): the page owns the list, the adapter renders it. */
  private submitList(list: PeertubeInstance[]): void {
    this.instancesList = list;
    this.dataSource.submitList(list);
    const saver: DebounceSaver | null = this.saver;
    if (saver !== null) {
      saver.setHasChangesToSave();
    }
  }

  /** One assignment for the one fact the source keeps in `selectedInstance`. */
  private setSelectedInstance(instance: PeertubeInstance): void {
    this.peertubeSelectedInstance = instance;
    this.selectedRadio = instance.getUrl();
  }

  /**
   * saveChanges(): JsonWriter over {name,url} of the current list into peertube_instance_list.
   * PeertubeInstances.saveInstanceList writes exactly that document; the flush is what makes it
   * survive a relaunch. The write is skipped when nothing changed since the last one.
   */
  private saveChanges(): void {
    const fingerprint: string = this.listFingerprint(this.instancesList);
    if (fingerprint === this.persistedListOnLeave) {
      return;
    }
    try {
      PeertubeInstances.saveInstanceList(this.instancesList);
      this.persistedListOnLeave = fingerprint;
    } catch (err) {
      const failure: Error = err as Error;
      this.errorInfo = failure.message;
      hilog.error(0x0000, TAG, 'saveInstanceList: %{public}s', failure.message);
      return;
    }
    const saver: DebounceSaver | null = this.saver;
    if (saver !== null) {
      saver.setNoChangesToSave();
    }
    this.flushPreferences();
  }

  /** The {name,url} pairs saveChanges() writes, in order - what "changed" means for that write. */
  private listFingerprint(list: PeertubeInstance[]): string {
    const parts: string[] = [];
    for (const instance of list) {
      parts.push(`${instance.getName()}\u0000${instance.getUrl()}`);
    }
    return parts.join('\u0001');
  }

  /**
   * `editor.apply()`. PeertubeInstances writes through the same single preference store this app
   * has; flushing it here is what turns those writes into something a relaunch can read.
   */
  private flushPreferences(): void {
    AppPreferences.instance().flush().catch((err: Error): void => {
      this.errorInfo = err.message;
      hilog.error(0x0000, TAG, 'preferences flush: %{public}s', err.message);
    });
  }

  /** Toast.makeText(getActivity(), resId, Toast.LENGTH_SHORT).show(). */
  private toast(message: Resource): void {
    promptAction.showToast({ message: message, duration: TOAST_SHORT_MS });
  }

  /**
   * ItemTouchHelper.onMove -> instanceListAdapter.swapItems(source, target): the reorder is
   * applied to a COPY, then submitList - nothing is persisted until onPause. One drag reports one
   * move, so the adjacent swaps the source made are folded into moveInstance's splice; a move that
   * goes nowhere hands the same list back and neither re-submits nor flags the saver.
   */
  private moveItem(fromIndex: number, toIndex: number): void {
    const list: PeertubeInstance[] = moveInstance(this.instancesList, fromIndex, toIndex);
    if (list !== this.instancesList) {
      this.submitList(list);
    }
  }

  build() {
    Column() {
      if (!this.hostDrawsToolbar) {
        // toolbar_layout.xml plus menu_chooser_fragment.xml: the Up affordance, the title
        // ThemeHelper.setTitleToAppCompatActivity pushes in onResume, and the ONE menu item -
        // showAsAction="always", so it is an icon button in the bar.
        Row() {
          // The 24vp glyph centred in a 56vp (?attr/actionBarSize) target - base.ui.json puts the
          // Up button at [0,72][168,240]. The SVG ships black, so the bar's tint is applied here.
          Image($r('app.media.ic_arrow_back'))
            .id('home')
            .accessibilityText($r('app.string.navigate_back'))
            .width(56)
            .height(56)
            .padding(16)
            .objectFit(ImageFit.Contain)
            .fillColor(COLOR_ON_PRIMARY)
            .onClick(() => {
              router.back();
            })

          // Widget.AppCompat.Toolbar.Title: 20sp medium, 16vp past the navigation button (the
          // capture puts the title at x=216 of 1080 - 72vp at density 3.0).
          Text($r('app.string.peertube_instance_url_title'))
            .layoutWeight(1)
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_ON_PRIMARY)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ left: 16 })

          // showAsAction="always": a 48vp action item flush to the bar's end - the capture measures
          // it at [936,84][1080,228], i.e. 48x48vp with no end margin.
          Image($r('app.media.ic_settings_backup_restore'))
            .id('menu_item_restore_default')
            .accessibilityText($r('app.string.restore_defaults'))
            .width(48)
            .height(48)
            .padding(12)
            .objectFit(ImageFit.Contain)
            .fillColor(COLOR_ON_PRIMARY)
            .onClick(() => {
              this.restoreDefaultsDialog.open();
            })
        }
        .width('100%')
        .height(56)
        .alignItems(VerticalAlign.Center)
        .backgroundColor(COLOR_PRIMARY)
      }

      // instanceHelpTV: setText(getString(peertube_instance_url_help, peertube_instance_list_url)),
      // android:autoLink="web" - a linkified label with no listener of its own. A default 14sp
      // TextView at the layout's 15dp margin; the capture samples it (109,109,109), i.e.
      // ?android:textColorSecondary over #EEEEEE.
      // The URL half is the linkified run: underlined in ?android:textColorLink. The source's
      // linkify also makes it TAPPABLE, which this port does NOT reproduce - the plan records
      // instanceHelpTV as displayOnly, so a tap target here would be an invented control.
      Text() {
        Span(this.helpTextPrefix)
        Span(this.helpLinkUrl)
          .fontColor(COLOR_LINK)
          .decoration({ type: TextDecorationType.Underline, color: COLOR_LINK })
        Span(this.helpTextSuffix)
      }
        .id('instanceHelpTV')
        .width('100%')
        .fontSize(14)
        .lineHeight(18)
        .fontColor(COLOR_SECONDARY_TEXT)
        // android:layout_margin="15dp", spent as padding so the full-width Text cannot overflow.
        .padding({ left: 15, right: 15 })
        .margin({ top: 15, bottom: 15 })

      // The `instances` RecyclerView with its LinearLayoutManager.
      Stack() {
        InstanceListAdapter({
          dataSource: this.dataSource,
          selectedUrl: this.selectedRadio,
          onSelectInstance: (index: number): void => {
            this.selectInstance(index);
          },
          onMoveItem: (fromIndex: number, toIndex: number): void => {
            this.moveItem(fromIndex, toIndex);
          },
          onSwipeRemove: (index: number): void => {
            this.removeInstance(index);
          }
        })

        // loading_progress_bar: android:visibility="gone" until addInstance() starts its fetch.
        if (this.isLoading) {
          LoadingProgress()
            .id('loading_progress_bar')
            .width(48)
            .height(48)
            .color(COLOR_PRIMARY)
        }

        // addInstanceButton: the FAB, aligned to the bottom end of the list area.
        // app:backgroundTint="?attr/colorPrimary", app:fabSize="auto" (56vp - the capture's
        // [864,2124][1032,2292]) at the layout's 16dp end/bottom margins, ic_add tinted white.
        Button({ type: ButtonType.Circle }) {
          Image($r('app.media.ic_add'))
            .width(24)
            .height(24)
            .objectFit(ImageFit.Contain)
            .fillColor(COLOR_ON_PRIMARY)
        }
        .id('addInstanceButton')
        .accessibilityText($r('app.string.peertube_instance_add_title'))
        .width(56)
        .height(56)
        .backgroundColor(COLOR_PRIMARY)
        .margin({ right: 16, bottom: 16 })
        .shadow({
          radius: 6,
          color: '#40000000',
          offsetX: 0,
          offsetY: 3
        })
        .onClick(() => {
          this.addInstanceDialog.open();
        })
      }
      .alignContent(Alignment.BottomEnd)
      .width('100%')
      .layoutWeight(1)
    }
    .id('PeertubeInstanceListFragmentPage')
    .width('100%')
    .height('100%')
    .backgroundColor(themedBackground(this.blackTheme))
  }

  /**
   * ItemTouchHelper.onSwiped, with the source's two vetoes: the SELECTED instance may not be
   * removed (the source restores the row with notifyItemChanged), and if the removal would empty
   * the list the selected instance is put back, so the list is never empty.
   */
  private removeInstance(index: number): void {
    if (index < 0 || index >= this.instancesList.length) {
      return;
    }
    if (this.instancesList[index].getUrl() === this.peertubeSelectedInstance.getUrl()) {
      // do not allow swiping the selected instance - re-render the row unchanged.
      this.dataSource.submitList(this.instancesList);
      return;
    }
    const list: PeertubeInstance[] = this.instancesList.slice();
    list.splice(index, 1);
    if (list.length === 0) {
      list.push(this.peertubeSelectedInstance);
    }
    this.submitList(list);
  }

  /**
   * selectInstance(instance): PeertubeHelper.selectInstance(instance, context) - it stores
   * peertube_selected_instance, raises Constants.KEY_MAIN_PAGE_CHANGE so the main page rebuilds
   * against the new base url, and points the PeerTube service at it.
   */
  private selectInstance(index: number): void {
    if (index < 0 || index >= this.instancesList.length) {
      return;
    }
    try {
      this.setSelectedInstance(PeertubeInstances.selectInstance(this.instancesList[index]));
      this.flushPreferences();
    } catch (err) {
      const failure: Error = err as Error;
      this.errorInfo = failure.message;
      hilog.error(0x0000, TAG, 'selectInstance: %{public}s', failure.message);
    }
    this.dataSource.submitList(this.instancesList);
  }

  /**
   * addInstance(url): cleanUrl() first - a non-https url or one already in the list is refused
   * with the source's own toast and nothing is fetched - then the instance's /api/v1/config is
   * fetched behind loadingProgressBar, and a failure toasts peertube_instance_add_fail.
   */
  private addInstance(url: string): void {
    const result: CleanUrlResult = PeertubeInstances.cleanUrl(url, this.instancesList);
    const cleanUrl: string | null = result.url;
    if (cleanUrl === null) {
      if (result.error === CleanUrlError.HTTPS_ONLY) {
        this.toast($r('app.string.peertube_instance_add_https_only'));
      } else if (result.error === CleanUrlError.ALREADY_EXISTS) {
        this.toast($r('app.string.peertube_instance_add_exists'));
      }
      return;
    }
    // binding.loadingProgressBar.setVisibility(View.VISIBLE)
    this.isLoading = true;
    PeertubeInstances.validateInstance(cleanUrl)
      .then((instance: PeertubeInstance): void => {
        this.isLoading = false;
        // add(instance): a COPY of the current list plus the new one, then submitList.
        const list: PeertubeInstance[] = this.instancesList.slice();
        list.push(instance);
        this.submitList(list);
      })
      .catch((err: Error): void => {
        this.isLoading = false;
        hilog.warn(0x0000, TAG, 'fetchInstanceMetaData(%{public}s): %{public}s', cleanUrl,
          err.message);
        this.toast($r('app.string.peertube_instance_add_fail'));
      });
  }

  /**
   * restoreDefaults()'s positive button: remove(savedInstanceListKey),
   * selectInstance(PeertubeInstance.DEFAULT_INSTANCE), submitList(getInstanceList(context)).
   */
  private restoreDefaults(): void {
    try {
      const restored: PeertubeInstance[] = PeertubeInstances.restoreDefaults();
      this.setSelectedInstance(PeertubeInstance.DEFAULT_INSTANCE);
      this.submitList(restored);
      this.flushPreferences();
    } catch (err) {
      const failure: Error = err as Error;
      this.errorInfo = failure.message;
      hilog.error(0x0000, TAG, 'restoreDefaults: %{public}s', failure.message);
    }
  }
}
