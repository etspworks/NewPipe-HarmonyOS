/**
 * S6 - HistorySettingsFragment (screen_history_settings).
 *
 * Structure is the source's res/xml/history_settings.xml, read row for row: four switches, then the
 * "Clear data" PreferenceCategory (a header, not a control) holding five clickable rows - rendered
 * as the preference RecyclerView the capture shows, one ListItem per XML entry. Styling is applied
 * (see the S5 token block below).
 *
 * hostedBy screen_settings_activity, which PUSHES this page - SettingsActivityPage carries that
 * push, and draws the bar, so no Up affordance is drawn here (double-toolbar defect).
 *
 * DESTRUCTIVE ROWS - exclude every clear-* row and cache_wipe_key from any automated evidence
 * sweep. Four of the five wipe the database; three go through a confirm dialog, but cache_wipe_key
 * fires IMMEDIATELY with no confirmation, exactly as onPreferenceTreeClick does.
 *
 * android:dependency has no ArkUI equivalent, so both dependencies are explicit conditions here:
 *  - enable_playback_resume and enable_playback_state_lists are enabled only while
 *    enable_watch_history is on (android:dependency=@string/enable_watch_history_key);
 *  - clear_cookie starts disabled when recaptcha_cookies_key is empty, and disables itself again
 *    after a clear.
 *
 * The three openDelete*Dialog helpers are STATIC in the source and StatisticsPlaylistFragment calls
 * openDeleteWatchHistoryDialog too, so they belong in a shared service on the target. That file is
 * outside this screen's allowlist, so the dialogs live here for now and the shared extraction is
 * reported instead.
 */
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { promptAction, router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppPreferences } from '../common/prefs/Preferences';
import { HistoryRecordManager } from '../common/db/HistoryRecordManager';
import { InfoCache } from '../common/extractor/InfoCache';
import { DownloaderImpl, RECAPTCHA_COOKIES_KEY } from '../common/net/Downloader';
import { ConfirmDeleteDialog } from '../components/ConfirmDeleteDialog';
import {
  enable_playback_resume_key,
  enable_playback_state_lists_key,
  enable_search_history_key,
  enable_watch_history_key,
  recaptcha_cookies_key
} from '../common/prefs/SettingsKeys';
import { DIALOG_MASK_COLOR } from '../common/theme/ServiceTheme';
import { settingsListScroller } from '../common/settings/SettingsScroller';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

const TAG: string = 'HistorySettingsFragmentPage';

/** Toast.LENGTH_SHORT. */
const TOAST_SHORT_MS: number = 2000;

/* S5 - style only, LightSettingsTheme - the theme a settings fragment runs
 * under. Reuses the run's style baseline (state.json generation.styleBaseline, source S0004) for
 * background / onSurface / secondaryText and the AndroidX preference-row + AlertDialog metrics
 * already measured for the sibling settings screens (ContentSettingsFragmentPage,
 * AppearanceSettingsFragmentPage). This screen has NO usable capture - all six of its source
 * states are the ACRA ErrorActivity, stranded there by an unrelated PlayQueueActivity crash - so
 * nothing here is read off a screenshot. Its rows are the same AndroidX preference rows as its
 * siblings', so the sibling settings screens' measured metrics ARE the faithful values: 16vp
 * gutters, 16vp vertical row padding, a 21.7vp title line and a 17.7vp summary line, a 47x27vp
 * switch, and settings_category_header_layout for the 'Clear data' header. setDivider(null) in
 * BasePreferenceFragment, so the list carries no separators. */
/** ?attr/windowBackground - light_background_color (#EEEEEE) in base, dark_background_color in dark. */
const COLOR_SURFACE: Resource = $r('app.color.background');
/** ?attr/colorPrimary - the switch's checked track and the dialog's selected mark. */
const COLOR_PRIMARY: Resource = $r('app.color.primary');
/** ?attr/actionColor - the toolbar's Up glyph and its title. */
const COLOR_ON_PRIMARY: Resource = $r('app.color.on_primary');
/**
 * ?attr/colorAccent - the AlertDialog's button colour. Settings runs under LightSettingsTheme,
 * whose only override IS colorAccent = @color/light_settings_accent_color (#E53935), which is why
 * the sibling settings captures render CANCEL red rather than the LightTheme black.
 */
const COLOR_ACCENT: Resource = $r('app.color.settings_accent');
/** ?android:textColorPrimary - #DE000000 over #EEEEEE is the capture's row title; white in dark. */
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');
/** ?android:textColorSecondary - #8A000000 over #EEEEEE is the capture's summary; 70% white in dark. */
const COLOR_SECONDARY_TEXT: Resource = $r('app.color.on_surface_variant');
/** The AlertDialog surface: white in the capture, NOT light_dialog_background_color. */
const COLOR_DIALOG_SURFACE: Resource = $r('app.color.dialog_surface');
/** ?attr/disabledAlpha - preference_material dims a disabled row's title/summary group. */
const DISABLED_ALPHA: number = 0.5;

@Entry
@Component
export struct HistorySettingsFragmentPage {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  /**
   * WHICH MOUNT: the settings main list reaches this page with router.pushUrl, so on that path it
   * IS the route and nothing above it draws a toolbar - the screen had no Up affordance at all
   * (T-1512, T-1547). A preference-search hit instead puts it in SettingsActivityPage's fragment
   * holder, under the activity's own bar, and that mount passes `hostDrawsToolbar: true` so a
   * second bar is never stacked on the first. It defaults to FALSE, so an unset value falls
   * through to DRAWING a bar it did not need rather than to leaving the screen with no way back.
   */
  @Prop hostDrawsToolbar: boolean = false;

  /** enable_watch_history: default true, and the dependency the two rows below hang off. */
  @State enableWatchHistory: boolean = true;
  /** enable_playback_resume and enable_playback_state_lists follow that dependency. */
  @State enablePlaybackResume: boolean = true;
  @State enablePlaybackStateLists: boolean = true;
  /** android:dependency=@string/enable_watch_history_key, re-implemented explicitly. */
  @State resumePlaybackPositionsInListsEnabledSta: boolean = true;
  @State enableSearchHistory: boolean = true;
  /** The stored ReCaptcha cookie - empty means the clear row is disabled. */
  @State recaptchaCookiesKey: string = '';
  /** clearCookiePref.setEnabled(!cookies.isEmpty()). */
  @State clearCookiesRowEnabledState: boolean = false;
  @State isLoading: boolean = true;
  @State errorInfo: string = '';

  /** The armed state of the shared confirm dialog: which row raised it, and its title. */
  @State confirmDialogTitle: ResourceStr = '';
  private pendingConfirmKey: string = '';

  private recordManager: HistoryRecordManager | null = null;

  private confirmDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    customStyle: true,
    builder: ConfirmDeleteDialog({
      title: this.confirmDialogTitle,
      onConfirm: (): void => {
        this.onConfirmed();
      }
    })
  });

  async aboutToAppear(): Promise<void> {
    await this.loadPreferences();
  }

  /** onCreatePreferences: read each switch, then the cookie that gates the clear-cookies row. */
  private async loadPreferences(): Promise<void> {
    try {
      this.enableWatchHistory = await AppPreferences.getBoolean(enable_watch_history_key, true);
      this.enablePlaybackResume = await AppPreferences.getBoolean(enable_playback_resume_key, true);
      this.enablePlaybackStateLists =
        await AppPreferences.getBoolean(enable_playback_state_lists_key, true);
      this.resumePlaybackPositionsInListsEnabledSta = this.enableWatchHistory;
      this.enableSearchHistory = await AppPreferences.getBoolean(enable_search_history_key, true);
      this.recaptchaCookiesKey = await AppPreferences.getString(recaptcha_cookies_key, '');
      this.clearCookiesRowEnabledState = true;
      // if (defaultPreferences.getString(recaptcha_cookies_key, "").isEmpty())
      //     clearCookiePref.setEnabled(false);
      if (this.recaptchaCookiesKey.length === 0) {
        this.clearCookiesRowEnabledState = false;
      }
      this.errorInfo = '';
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.errorInfo = failure.message;
      hilog.error(0x0000, TAG, 'loadPreferences failed: %{public}s', failure.message);
    } finally {
      this.isLoading = false;
    }
  }

  /** new HistoryRecordManager(getActivity()) - built once, on the first destructive row. */
  private async ensureRecordManager(): Promise<HistoryRecordManager | null> {
    const existing: HistoryRecordManager | null = this.recordManager;
    if (existing !== null) {
      return existing;
    }
    try {
      const context: common.Context = getContext(this) as common.Context;
      const manager: HistoryRecordManager = await HistoryRecordManager.of(context);
      this.recordManager = manager;
      return manager;
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.errorInfo = failure.message;
      hilog.error(0x0000, TAG, 'HistoryRecordManager unavailable: %{public}s', failure.message);
      return null;
    }
  }

  /** Every write goes through the flushing static - the instance methods do not flush. */
  private async persistBoolean(key: string, value: boolean): Promise<void> {
    try {
      await AppPreferences.putBoolean(key, value);
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      hilog.error(0x0000, TAG, 'putBoolean %{public}s failed: %{public}s', key, failure.message);
    }
  }

  private toast(message: Resource): void {
    promptAction.showToast({ message: message, duration: TOAST_SHORT_MS });
  }

  /** Arm the shared confirm dialog for one clear-* row, then show it. */
  private openConfirmDialog(key: string, title: ResourceStr): void {
    this.pendingConfirmKey = key;
    this.confirmDialogTitle = title;
    this.confirmDialog.open();
  }

  /** The positive button of whichever clear-* dialog is open. */
  private onConfirmed(): void {
    const key: string = this.pendingConfirmKey;
    if (key === 'clear_play_history') {
      this.deleteWatchHistory();
    } else if (key === 'clear_playback_states') {
      this.deletePlaybackStates();
    } else if (key === 'clear_search_history') {
      this.deleteSearchHistory();
    }
  }

  /**
   * openDeleteWatchHistoryDialog's positive button: three subscriptions -
   * deleteCompleteStreamStateHistory(), deleteWholeStreamHistory(), removeOrphanedRecords().
   */
  private async deleteWatchHistory(): Promise<void> {
    const manager: HistoryRecordManager | null = await this.ensureRecordManager();
    if (manager === null) {
      return;
    }
    try {
      await manager.deleteCompleteStreamStateHistory();
      this.toast($r('app.string.watch_history_states_deleted'));
      await manager.deleteWholeStreamHistory();
      this.toast($r('app.string.watch_history_deleted'));
      // getRemoveOrphanedRecordsDisposable: succeeds silently, no toast.
      await manager.removeOrphanedRecords();
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.errorInfo = failure.message;
      hilog.error(0x0000, TAG, 'Delete from history failed: %{public}s', failure.message);
    }
  }

  /** openDeletePlaybackStatesDialog -> deleteCompleteStreamStateHistory(). */
  private async deletePlaybackStates(): Promise<void> {
    const manager: HistoryRecordManager | null = await this.ensureRecordManager();
    if (manager === null) {
      return;
    }
    try {
      await manager.deleteCompleteStreamStateHistory();
      this.toast($r('app.string.watch_history_states_deleted'));
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.errorInfo = failure.message;
      hilog.error(0x0000, TAG, 'Delete playback states failed: %{public}s', failure.message);
    }
  }

  /** openDeleteSearchHistoryDialog -> deleteCompleteSearchHistory(). */
  private async deleteSearchHistory(): Promise<void> {
    const manager: HistoryRecordManager | null = await this.ensureRecordManager();
    if (manager === null) {
      return;
    }
    try {
      await manager.deleteCompleteSearchHistory();
      this.toast($r('app.string.search_history_deleted'));
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.errorInfo = failure.message;
      hilog.error(0x0000, TAG, 'Delete search history failed: %{public}s', failure.message);
    }
  }

  /** onPreferenceTreeClick(cacheWipeKey): clearCache() + the notice, with NO confirmation. */
  private wipeMetadataCache(): void {
    InfoCache.getInstance().clearCache();
    this.toast($r('app.string.metadata_cache_wipe_complete_notice'));
  }

  /** clearCookiePref's click listener: blank the preference and the downloader's cookie. */
  private async clearCookies(): Promise<void> {
    try {
      await AppPreferences.putString(recaptcha_cookies_key, '');
      DownloaderImpl.getInstance().setCookie(RECAPTCHA_COOKIES_KEY, '');
      this.recaptchaCookiesKey = '';
      this.toast($r('app.string.recaptcha_cookies_cleared'));
      // clearCookiePref.setEnabled(false)
      this.clearCookiesRowEnabledState = false;
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.errorInfo = failure.message;
      hilog.error(0x0000, TAG, 'Clear cookies failed: %{public}s', failure.message);
    }
  }

  build() {
    Column() {
      // toolbar_layout.xml: the host activity's Up affordance and the PreferenceScreen title that
      // BasePreferenceFragment.onViewCreated pushes into it. android.R.id.home is the slug.
      if (!this.hostDrawsToolbar) {
        Row() {
          // The 24vp glyph centred in a 56vp (?attr/actionBarSize) target, as every other pushed
          // preference screen draws it. The SVG ships black, so the bar's tint is applied here.
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

          // Widget.AppCompat.Toolbar.Title: 20sp medium, 16vp past the navigation button.
          Text($r('app.string.settings_category_history_title'))
            .layoutWeight(1)
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_ON_PRIMARY)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ left: 16 })
        }
        .width('100%')
        .height(56)
        .alignItems(VerticalAlign.Center)
        .backgroundColor(COLOR_PRIMARY)
      }

      // The preference RecyclerView: one row per XML entry.
      List({ scroller: settingsListScroller }) {
        // -- SwitchPreferenceCompat: enable_watch_history ---------------------------------------
        // This key gates every stream_history and stream_state write, and the two rows below
        // declare android:dependency on it.
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.enable_watch_history_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.enable_watch_history_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(18)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            // The whole row is the one tappable control, so the switch takes no touch.
            Toggle({ type: ToggleType.Switch, isOn: this.enableWatchHistory })
              .hitTestBehavior(HitTestMode.None)
              .width(47)
              .height(27)
              .margin({ left: 16 })
              .selectedColor(COLOR_PRIMARY)
          }
          .id('enable_watch_history')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.enableWatchHistory = !this.enableWatchHistory;
            this.resumePlaybackPositionsInListsEnabledSta = this.enableWatchHistory;
            this.persistBoolean(enable_watch_history_key, this.enableWatchHistory);
          })
        }

        // -- SwitchPreferenceCompat: enable_playback_resume -------------------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.enable_playback_resume_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.enable_playback_resume_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(18)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.enablePlaybackResume })
              .hitTestBehavior(HitTestMode.None)
              .width(47)
              .height(27)
              .margin({ left: 16 })
              .selectedColor(COLOR_PRIMARY)
          }
          .id('enable_playback_resume')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .opacity(this.resumePlaybackPositionsInListsEnabledSta ? 1 : DISABLED_ALPHA)
          // android:dependency=@string/enable_watch_history_key
          .enabled(this.resumePlaybackPositionsInListsEnabledSta)
          .onClick(() => {
            this.enablePlaybackResume = !this.enablePlaybackResume;
            this.persistBoolean(enable_playback_resume_key, this.enablePlaybackResume);
          })
        }

        // -- SwitchPreferenceCompat: enable_playback_state_lists --------------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.enable_playback_state_lists_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.enable_playback_state_lists_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(18)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.enablePlaybackStateLists })
              .hitTestBehavior(HitTestMode.None)
              .width(47)
              .height(27)
              .margin({ left: 16 })
              .selectedColor(COLOR_PRIMARY)
          }
          .id('enable_playback_state_lists')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .opacity(this.resumePlaybackPositionsInListsEnabledSta ? 1 : DISABLED_ALPHA)
          // android:dependency=@string/enable_watch_history_key
          .enabled(this.resumePlaybackPositionsInListsEnabledSta)
          .onClick(() => {
            this.enablePlaybackStateLists = !this.enablePlaybackStateLists;
            this.persistBoolean(enable_playback_state_lists_key, this.enablePlaybackStateLists);
          })
        }

        // -- SwitchPreferenceCompat: enable_search_history --------------------------------------
        // Gates every search_history write.
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.enable_search_history_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.enable_search_history_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(18)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.enableSearchHistory })
              .hitTestBehavior(HitTestMode.None)
              .width(47)
              .height(27)
              .margin({ left: 16 })
              .selectedColor(COLOR_PRIMARY)
          }
          .id('enable_search_history')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.enableSearchHistory = !this.enableSearchHistory;
            this.persistBoolean(enable_search_history_key, this.enableSearchHistory);
          })
        }

        // -- PreferenceCategory: settings_category_clear_data_title - a header, not a control ----
        ListItem() {
          Column() {
            // settings_category_header_layout: a 14vp ?attr/contrast_background_color band, then
            // the 1vp ?attr/separator_color rule, then the title itself.
            Column()
              .width('100%')
              .height(14)
              .backgroundColor($r('app.color.contrast_background'))

            Divider()
              .strokeWidth(1)
              .color($r('app.color.separator'))

            // settings_category_header_title: 14sp bold ?android:textColorPrimary at the same
            // 16vp gutter, 16vp below the rule.
            Text($r('app.string.settings_category_clear_data_title'))
              .width('100%')
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor(COLOR_ON_SURFACE)
              .padding({ left: 16, right: 16, top: 16 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }

        // -- Preference: cache_wipe_key - fires IMMEDIATELY, no confirmation --------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.metadata_cache_wipe_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.metadata_cache_wipe_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(18)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('cache_wipe_key')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.wipeMetadataCache();
          })
        }

        // -- Preference: clear_play_history -> openDeleteWatchHistoryDialog ----------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.clear_views_history_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.clear_views_history_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(18)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('clear_play_history')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.openConfirmDialog('clear_play_history', $r('app.string.delete_view_history_alert'));
          })
        }

        // -- Preference: clear_playback_states -> openDeletePlaybackStatesDialog -----------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.clear_playback_states_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.clear_playback_states_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(18)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('clear_playback_states')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.openConfirmDialog('clear_playback_states',
              $r('app.string.delete_playback_states_alert'));
          })
        }

        // -- Preference: clear_search_history -> openDeleteSearchHistoryDialog -------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.clear_search_history_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.clear_search_history_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(18)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('clear_search_history')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.openConfirmDialog('clear_search_history',
              $r('app.string.delete_search_history_alert'));
          })
        }

        // -- Preference: clear_cookie - enabled only while a cookie is stored --------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.clear_cookie_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.clear_cookie_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(18)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('clear_cookie')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .opacity(this.clearCookiesRowEnabledState ? 1 : DISABLED_ALPHA)
          // if (defaultPreferences.getString(recaptcha_cookies_key, "").isEmpty()) setEnabled(false)
          .enabled(this.clearCookiesRowEnabledState)
          .onClick(() => {
            this.clearCookies();
          })
        }
      }
      .width('100%')
      .layoutWeight(1)

      // ErrorPanelHelper equivalent: only once the first read has finished and failed.
      if (!this.isLoading && this.errorInfo.length > 0) {
        Text(this.errorInfo)
          .width('100%')
          .fontSize(14)
          .lineHeight(18)
          .fontColor(COLOR_SECONDARY_TEXT)
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
      }
    }
    .id('HistorySettingsFragmentPage')
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(themedBackground(this.blackTheme))
  }
}
