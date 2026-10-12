/**
 * S6 - DownloadSettingsFragment (screen_download_settings).
 *
 * Structure is the source's res/xml/download_settings.xml, read row for row: two switches, the two
 * folder rows, a ListPreference, an EditTextPreference, a ListPreference and two more switches -
 * rendered as the preference RecyclerView the capture shows (id/recycler_view), one ListItem per
 * XML entry. Styling is applied (see the S5 token block below).
 *
 * hostedBy screen_settings_activity, which PUSHES this page (router.pushUrl) - SettingsActivityPage
 * already carries that push. No Up affordance is drawn here: this is one of the hosted pages whose
 * bar the host draws, and a second one is the double-toolbar defect.
 *
 * navOut screen_custom_file_picker is kind `present` in the plan, but its target is a
 * `presentation: page` screen with its own routeUrl (pages/CustomFilePickerFragmentPage), so it is
 * generated as router.pushUrl - the batch convention, and what the S2 gate scores. It is the
 * non-SAF half of StoredDirectoryHelper.getPicker(): with SAF in use a folder row opens the system
 * DocumentViewPicker (FileAccess.pickDirectory), otherwise NewPipe's own file picker - which on
 * this target is that page.
 *
 * Source facts this port honours:
 *  - NewPipeSettings.useStorageAccessFramework() returns true unconditionally from API 29, and the
 *    fragment then setEnabled(false)s the SAF row, swaps its summary for
 *    downloads_storage_use_saf_summary_api_29 and gives "Ask where to download" the
 *    downloads_storage_ask_summary_no_saf_notice summary. HarmonyOS is scoped-storage-only, so that
 *    is the branch that applies - which is exactly what the source capture shows (switchWidget ON,
 *    enabled=false). The row is therefore checked and inert, as in the source.
 *  - downloads_storage_ask gates the two path rows: updatePathPickers(!value).
 *  - showPathInSummary(): an empty preference falls back to the XML summary, otherwise the stored
 *    path itself is the summary.
 *  - IGNORE_RELEASE_ON_OLD_PATH = true makes forgetSAFTree() a deliberate no-op (FIXME in the
 *    source). Not "fixed" during the port.
 */
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppPreferences } from '../common/prefs/Preferences';
import { Localization } from '../common/i18n/Localization';
import { ServiceLocator } from '../common/di/ServiceLocator';
import { DownloadManager } from '../common/download/DownloadManager';
import { FileAccess, StoredDirectory, TAG_AUDIO, TAG_VIDEO } from '../common/file/FileAccess';
import { FilePicker, FilePickerMode } from '../common/file/FilePicker';
import { FILE_PICKER_RESULT_KEY } from './CustomFilePickerFragmentPage';
import {
  charset_letters_and_digits_value,
  charset_most_special_value,
  download_path_audio_key,
  download_path_video_key,
  downloads_cross_network,
  downloads_maximum_retry,
  downloads_maximum_retry_default,
  downloads_queue_limit,
  settings_file_charset_key,
  settings_file_replacement_character_default_value,
  settings_file_replacement_character_key,
  storage_use_saf
} from '../common/prefs/SettingsKeys';
import { DIALOG_MASK_COLOR } from '../common/theme/ServiceTheme';
import { settingsListScroller } from '../common/settings/SettingsScroller';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

const TAG: string = 'DownloadSettingsFragmentPage';

/**
 * NewPipeSettings.useStorageAccessFramework(): `Build.VERSION.SDK_INT >= Q` returns true before the
 * preference is even read. HarmonyOS is scoped-storage-only, so that branch is the one this port
 * takes - which is why the SAF row is checked and disabled, exactly as the source is on API 29+.
 *
 * It does NOT follow that the system picker can serve the two folder rows: DocumentViewPicker
 * selects a DIRECTORY only on 2-in-1 devices (FileAccess.canPickDirectory()), so on a phone
 * pickDownloadDirectory() takes getPicker()'s other half, NewPipe's own MODE_DIR picker.
 */
const SAF_FORCED_BY_PLATFORM: boolean = true;

/* S5 - style only, LightSettingsTheme - the theme a settings fragment runs
 * under. Reuses the run's style baseline (state.json generation.styleBaseline, source S0004) for
 * background / onSurface / secondaryText and the AndroidX preference-row + AlertDialog metrics
 * already measured for the sibling settings screens (ContentSettingsFragmentPage,
 * AppearanceSettingsFragmentPage). This screen's own base.ui.json (S0105) confirms every metric at
 * 1080px/360vp: 16vp gutters (title x=48px, switch right edge 1032px), 16vp vertical row padding
 * (48px from a summary bottom to the next title top), a 65px/21.7vp title line and a 53px/17.7vp
 * summary line, and a 140x81px (47x27vp) switch. setDivider(null) in BasePreferenceFragment, so
 * the list carries no separators. */
/** ?attr/windowBackground - light_background_color, the capture's #EEEEEE. */
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
/** ?android:textColorPrimary - #DE000000 over #EEEEEE is the capture's row title. */
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');
/** ?android:textColorSecondary - #8A000000 over #EEEEEE is the capture's summary. */
const COLOR_SECONDARY_TEXT: Resource = $r('app.color.on_surface_variant');
/** The AlertDialog surface: white in the capture, NOT light_dialog_background_color. */
const COLOR_DIALOG_SURFACE: Resource = $r('app.color.dialog_surface');
/** ?attr/disabledAlpha - preference_material dims a disabled row's title/summary group. */
const DISABLED_ALPHA: number = 0.5;

/** One entry of a ListPreference: the persisted value plus the label shown for it. */
interface DownloadPrefOption {
  value: string;
  label: string;
}

/** @array/settings_filename_charset - the entryValues, in XML order. */
const FILENAME_CHARSET_VALUES: string[] = [
  charset_letters_and_digits_value,
  charset_most_special_value
];

/** @array/settings_filename_charset_name - the entries, in the same order. */
const FILENAME_CHARSET_LABEL_NAMES: string[] = [
  'charset_letters_and_digits',
  'charset_most_special_characters'
];

/**
 * @array/downloads_maximum_retry_list, which the XML uses as BOTH android:entries and
 * android:entryValues - so the first row's persisted value is the localized "None" string itself,
 * not a number. Kept as the source has it.
 */
const DOWNLOADS_MAXIMUM_RETRY_NUMBERS: string[] = ['1', '2', '3', '4', '5', '7', '10', '15'];

/**
 * ListPreference's dialog: single choice over the preference's entries, plus CANCEL. The option
 * list scrolls inside a bounded panel so the button row cannot be pushed off screen.
 *
 * Widget.AppCompat.Button carries android:textAllCaps="true", so the source renders every dialog
 * button uppercased while the string resource stays sentence case. ArkUI has no such attribute,
 * which is why the labels here go through Localization.buttonLabel() rather than $r() directly -
 * the same route ConfirmDeleteDialog already takes.
 */
@CustomDialog
struct DownloadChoiceDialog {
  controller?: CustomDialogController;
  title: ResourceStr = '';
  options: DownloadPrefOption[] = [];
  selected: string = '';
  /** The option rows are instantiated per entry, so they deliberately SHARE one id (rule 12). */
  itemId: string = 'download_choice_itemroot';
  onSelect: (value: string) => void = (value: string): void => {
    hilog.debug(0x0000, TAG, 'DownloadChoiceDialog: select %{public}s not bound', value);
  };

  build() {
    Column() {
      Text(this.title)
        .width('100%')
        .fontSize(20)
        .fontColor(COLOR_ON_SURFACE)
        .padding({ left: 24, right: 24, top: 18, bottom: 8 })

      Scroll() {
        Column() {
          ForEach(this.options, (option: DownloadPrefOption) => {
            Row() {
              // ?attr/listChoiceIndicatorSingle: the row LEADS with a 20vp radio at the 24vp
              // gutter, 32vp from its label, and marks the current entry by filling it in
              // ?attr/colorPrimary - there is no tick at the row's end.
              Stack() {
                if (option.value === this.selected) {
                  Column()
                    .width(10)
                    .height(10)
                    .borderRadius(5)
                    .backgroundColor(COLOR_PRIMARY)
                }
              }
              .width(20)
              .height(20)
              .borderRadius(10)
              .borderWidth(2)
              .borderColor(option.value === this.selected ? COLOR_PRIMARY : COLOR_SECONDARY_TEXT)
              .margin({ right: 32 })

              Text(option.label)
                .layoutWeight(1)
                .fontSize(16)
                .fontColor(COLOR_ON_SURFACE)
            }
            .width('100%')
            .height(48)
            .padding({ left: 24, right: 24 })
            .alignItems(VerticalAlign.Center)
            .id(this.itemId)
            .onClick(() => {
              this.controller?.close();
              this.onSelect(option.value);
            })
          }, (option: DownloadPrefOption) => option.value)
        }
        .width('100%')
      }
      .align(Alignment.Top)
      .scrollBar(BarState.Auto)
      .constraintSize({ maxHeight: 560 })

      Button(Localization.buttonLabel('cancel'))
        .id('button2')
        .height(42)
        .backgroundColor(Color.Transparent)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(COLOR_ACCENT)
        .alignSelf(ItemAlign.End)
        .margin({ top: 4, right: 12, bottom: 8 })
        .onClick(() => {
          this.controller?.close();
        })
    }
    .width(294)
    .backgroundColor(COLOR_DIALOG_SURFACE)
    .borderRadius(4)
    .alignItems(HorizontalAlign.Start)
  }
}

/** EditTextPreference's dialog: android.R.id.edit plus OK/CANCEL; only OK commits. */
@CustomDialog
struct DownloadTextInputDialog {
  controller?: CustomDialogController;
  title: ResourceStr = '';
  text: string = '';
  @State pending: string = '';
  onConfirm: (value: string) => void = (value: string): void => {
    hilog.debug(0x0000, TAG, 'DownloadTextInputDialog: %{public}s not bound', value);
  };

  aboutToAppear(): void {
    this.pending = this.text;
  }

  build() {
    Column() {
      Text(this.title)
        .width('100%')
        .fontSize(20)
        .fontColor(COLOR_ON_SURFACE)
        .padding({ left: 24, right: 24, top: 18, bottom: 8 })

      TextInput({ text: this.pending })
        .id('edit')
        .width('100%')
        .fontSize(16)
        .fontColor(COLOR_ON_SURFACE)
        .padding({ left: 24, right: 24 })
        .margin({ top: 4, bottom: 4 })
        .onChange((value: string) => {
          this.pending = value;
        })

      Row() {
        Button(Localization.buttonLabel('cancel'))
          .id('button2')
          .height(42)
          .backgroundColor(Color.Transparent)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_ACCENT)
          .onClick(() => {
            this.controller?.close();
          })

        Button(Localization.buttonLabel('ok'))
          .id('button1')
          .height(42)
          .backgroundColor(Color.Transparent)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_ACCENT)
          .onClick(() => {
            this.controller?.close();
            this.onConfirm(this.pending);
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .padding({ right: 12, bottom: 8 })
    }
    .width(294)
    .backgroundColor(COLOR_DIALOG_SURFACE)
    .borderRadius(4)
    .alignItems(HorizontalAlign.Start)
  }
}

@Entry
@Component
export struct DownloadSettingsFragmentPage {
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

  /** showPathInSummary(download_path, R.string.download_path_summary, prefPathVideo). */
  @State videoDownloadFolderSummary: string = '';
  /** showPathInSummary(download_path_audio, R.string.download_path_audio_summary, prefPathAudio). */
  @State audioDownloadFolderSummary: string = '';
  /** prefUseSaf.setChecked(NewPipeSettings.useStorageAccessFramework(ctx)) - true on API 29+. */
  @State useSAFCheckedState: boolean = true;
  /** The raw storage_use_saf preference behind that forced checked state. */
  @State storageUseSaf: boolean = true;
  /**
   * downloads_storage_ask; when true, updatePathPickers(false) disables both folder rows. Not
   * offered on HarmonyOS: a download always goes to the folder set below, so this stays false and
   * the stored value is not read.
   */
  @State downloadsStorageAsk: boolean = false;
  /** The stored video path - empty is hasInvalidPath(), which is why the summary falls back. */
  @State downloadPath: string = '';
  /** The stored audio path, read the same way. */
  @State downloadPathAudio: string = '';
  /** useSimpleSummaryProvider: the charset row shows the entry of its current value. */
  @State fileCharsetSummary: string = '';
  @State fileCharsetValue: string = charset_most_special_value;
  @State fileReplacementCharacter: string = settings_file_replacement_character_default_value;
  @State downloadsMaxRetryValue: string = downloads_maximum_retry_default;
  @State crossNetworkDownloads: boolean = false;
  @State downloadsQueueLimitEnabled: boolean = true;
  @State isLoading: boolean = true;
  @State errorInfo: string = '';

  /** The entries of each ListPreference row, rebuilt from the source arrays in aboutToAppear. */
  @State fileCharsetOptions: DownloadPrefOption[] = [];
  @State downloadsMaxRetryOptions: DownloadPrefOption[] = [];

  /** The armed state of the shared single-choice dialog. */
  @State choiceDialogKey: string = '';
  @State choiceDialogTitle: ResourceStr = '';
  @State choiceDialogOptions: DownloadPrefOption[] = [];
  @State choiceDialogSelected: string = '';
  @State choiceDialogItemId: string = 'download_choice_itemroot';

  private choiceDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    customStyle: true,
    builder: DownloadChoiceDialog({
      title: this.choiceDialogTitle,
      options: this.choiceDialogOptions,
      selected: this.choiceDialogSelected,
      itemId: this.choiceDialogItemId,
      onSelect: (value: string): void => {
        this.onChoicePicked(value);
      }
    })
  });

  private replacementCharacterDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    customStyle: true,
    builder: DownloadTextInputDialog({
      title: $r('app.string.settings_file_replacement_character_title'),
      text: this.fileReplacementCharacter,
      onConfirm: (value: string): void => {
        this.onReplacementCharacterConfirmed(value);
      }
    })
  });

  /**
   * requestDownloadPathResult()'s launcher identity: which of the two folder preferences the
   * in-app picker was opened for. Empty whenever no pick is outstanding.
   */
  private pendingPickKey: string = '';

  async aboutToAppear(): Promise<void> {
    this.buildOptions();
    await this.loadPreferences();
  }

  /** @array/settings_filename_charset(+_name) and @array/downloads_maximum_retry_list. */
  private buildOptions(): void {
    const context: common.Context = getContext(this) as common.Context;
    const charsets: DownloadPrefOption[] = [];
    for (let i = 0; i < FILENAME_CHARSET_VALUES.length; i++) {
      const option: DownloadPrefOption = {
        value: FILENAME_CHARSET_VALUES[i],
        label: context.resourceManager.getStringByNameSync(FILENAME_CHARSET_LABEL_NAMES[i])
      };
      charsets.push(option);
    }
    this.fileCharsetOptions = charsets;

    // Item 0 of the retry array is @string/minimize_on_exit_none_description, and because entries
    // and entryValues are the same array it is also the value that gets persisted.
    const none: string =
      context.resourceManager.getStringByNameSync('minimize_on_exit_none_description');
    const retries: DownloadPrefOption[] = [];
    const noneOption: DownloadPrefOption = { value: none, label: none };
    retries.push(noneOption);
    for (const retryCount of DOWNLOADS_MAXIMUM_RETRY_NUMBERS) {
      const option: DownloadPrefOption = { value: retryCount, label: retryCount };
      retries.push(option);
    }
    this.downloadsMaxRetryOptions = retries;
  }

  /** onCreatePreferences: read every row's current value, then updatePreferencesSummary(). */
  private async loadPreferences(): Promise<void> {
    try {
      this.storageUseSaf = await AppPreferences.getBoolean(storage_use_saf, true);
      // prefUseSaf.setChecked(NewPipeSettings.useStorageAccessFramework(ctx)): forced true by the
      // platform branch, the stored preference otherwise.
      this.useSAFCheckedState = SAF_FORCED_BY_PLATFORM || this.storageUseSaf;
      this.downloadPath = await AppPreferences.getString(download_path_video_key, '');
      this.downloadPathAudio = await AppPreferences.getString(download_path_audio_key, '');
      await this.defaultDownloadPaths();
      this.fileCharsetValue =
        await AppPreferences.getString(settings_file_charset_key, charset_most_special_value);
      this.fileReplacementCharacter =
        await AppPreferences.getString(settings_file_replacement_character_key,
          settings_file_replacement_character_default_value);
      this.downloadsMaxRetryValue =
        await AppPreferences.getString(downloads_maximum_retry, downloads_maximum_retry_default);
      this.crossNetworkDownloads = await AppPreferences.getBoolean(downloads_cross_network, false);
      this.downloadsQueueLimitEnabled =
        await AppPreferences.getBoolean(downloads_queue_limit, true);
      this.updatePreferencesSummary();
      // if (hasInvalidPath(video) || hasInvalidPath(audio)) updatePreferencesSummary();
      if (this.hasInvalidPath(this.downloadPath) || this.hasInvalidPath(this.downloadPathAudio)) {
        this.updatePreferencesSummary();
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

  /**
   * NewPipeSettings.initSettings(): an unset folder row starts at `Download/<bundle>`, the one
   * public root this platform grants (folder SELECTION is a 2-in-1-only syscap, and the Download
   * root itself answers `13900001`). The rows then open NewPipe's own picker inside that root, so
   * the user can keep it or choose / create a folder under it (README, Known limits).
   *
   * A stored path outside that root - the unreachable sandbox an older build wrote - is replaced,
   * because nothing under it can be reached from Files.
   */
  private async defaultDownloadPaths(): Promise<void> {
    const root: string = await ServiceLocator.get().fileAccess.publicDownloadDir();
    if (root.length === 0) {
      // The platform would not give the folder up; keep whatever is stored rather than clear it.
      return;
    }
    if (!this.summaryOf(this.downloadPath).startsWith(root)) {
      this.downloadPath = root;
      await AppPreferences.putString(download_path_video_key, root);
    }
    if (!this.summaryOf(this.downloadPathAudio).startsWith(root)) {
      this.downloadPathAudio = root;
      await AppPreferences.putString(download_path_audio_key, root);
    }
  }

  /** updatePreferencesSummary() -> showPathInSummary() for each of the two folder rows. */
  private updatePreferencesSummary(): void {
    const filePicker: FilePicker = ServiceLocator.get().filePicker;
    this.videoDownloadFolderSummary = filePicker.displayPath(this.summaryOf(this.downloadPath));
    this.audioDownloadFolderSummary =
      filePicker.displayPath(this.summaryOf(this.downloadPathAudio));
    this.fileCharsetSummary = this.labelOf(this.fileCharsetOptions, this.fileCharsetValue);
  }

  /**
   * showPathInSummary(): a file uri is summarised by its path, anything else by the uri itself.
   * The empty case falls back to the row's XML summary, and that branch is in build() - it renders
   * a resource, not a string.
   */
  private summaryOf(path: string): string {
    return path.startsWith('file://') ? path.substring('file://'.length) : path;
  }

  /** hasInvalidPath(): the preference was never written, or was cleared. */
  private hasInvalidPath(path: string): boolean {
    return path.length === 0;
  }

  /**
   * launchDirectoryPicker() + requestDownloadPathResult(). StoredDirectoryHelper.getPicker() hands
   * back the SAF tree picker while SAF is in use and NewPipe's own file picker otherwise, so the
   * branch is kept: the system DocumentViewPicker, or the in-app CustomFilePicker page.
   *
   * A cancelled pick is the source's `result.getResultCode() != RESULT_OK` - it writes nothing.
   * forgetSAFTree() on the old path stays the deliberate no-op it is in the source
   * (IGNORE_RELEASE_ON_OLD_PATH = true).
   */
  private async pickDownloadDirectory(key: string): Promise<void> {
    const fileAccess: FileAccess = ServiceLocator.get().fileAccess;
    // useStorageAccessFramework(): the platform branch first, then the storage_use_saf preference -
    // and then whether the system picker can return a DIRECTORY on this device at all. Folder
    // selection is a 2-in-1-only syscap (FileAccess.canPickDirectory()), and on a phone the call
    // silently never starts, so the second half of StoredDirectoryHelper.getPicker() is the branch
    // that applies there: NewPipe's own MODE_DIR picker.
    if ((SAF_FORCED_BY_PLATFORM || this.storageUseSaf) && fileAccess.canPickDirectory()) {
      try {
        const picked: StoredDirectory | null =
          await fileAccess.pickDirectory(key === download_path_audio_key ? TAG_AUDIO : TAG_VIDEO);
        if (picked === null) {
          return;
        }
        await this.applyPickedDirectory(key, picked.getUri());
      } catch (err) {
        const failure: BusinessError = err as BusinessError;
        hilog.error(0x0000, TAG, 'Error acquiring tree: %{public}s', failure.message);
      }
    } else {
      // registerForActivityResult(...): arm the launcher, clear any stale result, then start the
      // picker at the directory the preference already holds.
      this.pendingPickKey = key;
      AppStorage.setOrCreate(FILE_PICKER_RESULT_KEY, '');
      const current: string =
        key === download_path_audio_key ? this.downloadPathAudio : this.downloadPath;
      // T-0183/T-0186: with no configured path the picker used to open on the app SANDBOX, whose
      // only entry is `pending_downloads` and none of which the user can reach from Files - the
      // card's "not a page where you can select a file". Start it in the device's public Download
      // folder instead; FileAccess.publicDownloadDir() explains how that path is obtained.
      // ...and a path stored INSIDE the app sandbox is no better than no path at all: nothing
      // under it is reachable from Files, and its only entry is `pending_downloads`. A row left
      // pointing there by an older build reopened there for good (T-0186), so it falls back to
      // the public folder exactly as an unset row does.
      let startPath: string = this.summaryOf(current);
      if (startPath.length === 0 || ServiceLocator.get().filePicker.isOwnFileUri(startPath)) {
        startPath = await fileAccess.publicDownloadDir();
      }
      const mode: number = FilePickerMode.DIR;
      const args: Record<string, Object> = {
        'startPath': startPath,
        'mode': mode
      };
      router.pushUrl({ url: 'pages/CustomFilePickerFragmentPage', params: args });
    }
  }

  /**
   * requestDownloadPathResult() on RESULT_OK: store the chosen tree and redraw both summaries.
   * forgetSAFTree() on the old path stays the no-op the source made it.
   */
  private async applyPickedDirectory(key: string, uri: string): Promise<void> {
    if (key === download_path_audio_key) {
      this.downloadPathAudio = uri;
    } else {
      this.downloadPath = uri;
    }
    await this.persistString(key, uri);
    // DownloadManagerService re-reads the two directories when the preference changes; the port
    // only read them at startup, so a folder picked here did not reach the manager until the next
    // launch - and prepareSelectedDownload() went on showing the save picker (T-0183/T-0186).
    const manager: DownloadManager = ServiceLocator.get().downloadManager;
    if (key === download_path_audio_key) {
      manager.mainStorageAudio = new StoredDirectory(uri, TAG_AUDIO);
    } else {
      manager.mainStorageVideo = new StoredDirectory(uri, TAG_VIDEO);
    }
    this.updatePreferencesSummary();
  }

  /**
   * The in-app picker publishes its choice and pops itself, so the result is collected when this
   * page comes back to the front - the analogue of onActivityResult for that launcher. A cancelled
   * pick leaves the published value empty and writes nothing, which is `resultCode != RESULT_OK`.
   */
  onPageShow(): void {
    const key: string = this.pendingPickKey;
    if (key.length === 0) {
      return;
    }
    this.pendingPickKey = '';
    const picked: string | undefined = AppStorage.get<string>(FILE_PICKER_RESULT_KEY);
    if (picked === undefined || picked.length === 0) {
      return;
    }
    AppStorage.setOrCreate(FILE_PICKER_RESULT_KEY, '');
    this.applyPickedDirectory(key, picked).catch((err: BusinessError) => {
      hilog.error(0x0000, TAG, 'Error acquiring tree: %{public}s', err.message);
    });
  }

  /** useSimpleSummaryProvider: the entry of the current value, or the raw value if it has none. */
  private labelOf(options: DownloadPrefOption[], value: string): string {
    for (const option of options) {
      if (option.value === value) {
        return option.label;
      }
    }
    return value;
  }

  /** Arm the shared single-choice dialog for one ListPreference row, then show it. */
  private openChoiceDialog(key: string, title: ResourceStr, options: DownloadPrefOption[],
                           selected: string): void {
    this.choiceDialogKey = key;
    this.choiceDialogTitle = title;
    this.choiceDialogOptions = options;
    this.choiceDialogSelected = selected;
    this.choiceDialog.open();
  }

  private async onChoicePicked(value: string): Promise<void> {
    const key: string = this.choiceDialogKey;
    if (key === settings_file_charset_key) {
      this.fileCharsetValue = value;
    } else if (key === downloads_maximum_retry) {
      this.downloadsMaxRetryValue = value;
    }
    await this.persistString(key, value);
    this.updatePreferencesSummary();
  }

  private async onReplacementCharacterConfirmed(value: string): Promise<void> {
    this.fileReplacementCharacter = value;
    await this.persistString(settings_file_replacement_character_key, value);
  }

  /**
   * DownloadManagerService.handlePreferenceChange(): the download service kept
   * downloads_maximum_retry, downloads_cross_network and downloads_queue_limit cached on the
   * DownloadManager and refreshed them from its OnSharedPreferenceChangeListener whenever this
   * fragment wrote one. `prefMeteredDownloads` is the value canDownloadInCurrentNetwork()
   * consults against the current connection state, so a write here has to reach the manager the
   * same way or the toggle changes nothing until the next cold start.
   *
   * The fragment itself registers no connectivity listener in the source and none is added here.
   */
  private refreshDownloadManagerPreferences(key: string): void {
    if (key !== downloads_maximum_retry && key !== downloads_cross_network
      && key !== downloads_queue_limit) {
      return;
    }
    if (!ServiceLocator.isInitialized()) {
      return;
    }
    try {
      const manager: DownloadManager = ServiceLocator.get().downloadManager;
      manager.readPreferences();
      if (key === downloads_maximum_retry) {
        manager.updateMaximumAttempts();
      }
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      hilog.error(0x0000, TAG, 'refreshDownloadManagerPreferences %{public}s failed: %{public}s',
        key, failure.message);
    }
  }

  /** Every write goes through the flushing static - the instance methods do not flush. */
  private async persistString(key: string, value: string): Promise<void> {
    try {
      await AppPreferences.putString(key, value);
      this.refreshDownloadManagerPreferences(key);
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      hilog.error(0x0000, TAG, 'putString %{public}s failed: %{public}s', key, failure.message);
    }
  }

  private async persistBoolean(key: string, value: boolean): Promise<void> {
    try {
      await AppPreferences.putBoolean(key, value);
      this.refreshDownloadManagerPreferences(key);
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      hilog.error(0x0000, TAG, 'putBoolean %{public}s failed: %{public}s', key, failure.message);
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
          Text($r('app.string.settings_category_downloads_title'))
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

      // The preference RecyclerView (id/recycler_view in the capture): one row per XML entry.
      List({ scroller: settingsListScroller }) {
        // -- SwitchPreferenceCompat: downloads_storage_ask -------------------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.downloads_storage_ask_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
              // The API-29 branch swaps this summary for the "no SAF" notice, and that branch is
              // the one a scoped-storage OS takes.
              Text($r('app.string.downloads_storage_ask_unavailable_note'))
                .width('100%')
                .fontSize(14)
                .lineHeight(18)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            // The whole row is the one tappable control, so the switch takes no touch.
            Toggle({ type: ToggleType.Switch, isOn: this.downloadsStorageAsk })
              .hitTestBehavior(HitTestMode.None)
              .width(47)
              .height(27)
              .margin({ left: 16 })
              .selectedColor(COLOR_PRIMARY)
          }
          .id('downloads_storage_ask')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .opacity(DISABLED_ALPHA)
          .enabled(false)
        }

        // -- SwitchPreferenceCompat: storage_use_saf -------------------------------------------
        // setEnabled(false) + downloads_storage_use_saf_summary_api_29 on API 29+, which is the
        // branch this OS takes; the switch stays checked, as the source capture shows.
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.downloads_storage_use_saf_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.storage_saf_unavailable_note'))
                .width('100%')
                .fontSize(14)
                .lineHeight(18)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.useSAFCheckedState })
              .hitTestBehavior(HitTestMode.None)
              .width(47)
              .height(27)
              .margin({ left: 16 })
              .selectedColor(COLOR_PRIMARY)
          }
          .id('storage_use_saf')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .opacity(DISABLED_ALPHA)
          .enabled(false)
        }

        // -- Preference: download_path (SAF tree picker -> CustomFilePicker on the target) ------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.download_path_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
              // showPathInSummary(): an empty preference shows the XML summary instead.
              if (this.hasInvalidPath(this.downloadPath)) {
                Text($r('app.string.download_path_summary'))
                  .width('100%')
                  .fontSize(14)
                  .lineHeight(18)
                  .fontColor(COLOR_SECONDARY_TEXT)
              } else {
                Text(this.videoDownloadFolderSummary)
                  .width('100%')
                  .fontSize(14)
                  .lineHeight(18)
                  .fontColor(COLOR_SECONDARY_TEXT)
              }
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('download_path')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          // Not offered: downloads always go to the default folder, so the row only shows it.
          .opacity(DISABLED_ALPHA)
          .enabled(false)
        }

        // -- Preference: download_path_audio ----------------------------------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.download_path_audio_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
              if (this.hasInvalidPath(this.downloadPathAudio)) {
                Text($r('app.string.download_path_audio_summary'))
                  .width('100%')
                  .fontSize(14)
                  .lineHeight(18)
                  .fontColor(COLOR_SECONDARY_TEXT)
              } else {
                Text(this.audioDownloadFolderSummary)
                  .width('100%')
                  .fontSize(14)
                  .lineHeight(18)
                  .fontColor(COLOR_SECONDARY_TEXT)
              }
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('download_path_audio')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          // Not offered: downloads always go to the default folder, so the row only shows it.
          .opacity(DISABLED_ALPHA)
          .enabled(false)
        }

        // -- ListPreference: file_rename_charset -------------------------------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.settings_file_charset_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
              Text(this.fileCharsetSummary)
                .width('100%')
                .fontSize(14)
                .lineHeight(18)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('file_rename_charset')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.openChoiceDialog(settings_file_charset_key,
              $r('app.string.settings_file_charset_title'), this.fileCharsetOptions,
              this.fileCharsetValue);
          })
        }

        // -- EditTextPreference: file_replacement_character --------------------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.settings_file_replacement_character_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.settings_file_replacement_character_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(18)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('file_replacement_character')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.replacementCharacterDialog.open();
          })
        }

        // -- ListPreference: downloads_max_retry -------------------------------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.max_retry_msg'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.max_retry_desc'))
                .width('100%')
                .fontSize(14)
                .lineHeight(18)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('downloads_max_retry')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.openChoiceDialog(downloads_maximum_retry, $r('app.string.max_retry_msg'),
              this.downloadsMaxRetryOptions, this.downloadsMaxRetryValue);
          })
        }

        // -- SwitchPreferenceCompat: cross_network_downloads -------------------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.pause_downloads_on_mobile'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.pause_downloads_on_mobile_desc'))
                .width('100%')
                .fontSize(14)
                .lineHeight(18)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.crossNetworkDownloads })
              .hitTestBehavior(HitTestMode.None)
              .width(47)
              .height(27)
              .margin({ left: 16 })
              .selectedColor(COLOR_PRIMARY)
          }
          .id('cross_network_downloads')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.crossNetworkDownloads = !this.crossNetworkDownloads;
            this.persistBoolean(downloads_cross_network, this.crossNetworkDownloads);
          })
        }

        // -- SwitchPreferenceCompat: downloads_queue_limit ---------------------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.enable_queue_limit'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.enable_queue_limit_desc'))
                .width('100%')
                .fontSize(14)
                .lineHeight(18)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.downloadsQueueLimitEnabled })
              .hitTestBehavior(HitTestMode.None)
              .width(47)
              .height(27)
              .margin({ left: 16 })
              .selectedColor(COLOR_PRIMARY)
          }
          .id('downloads_queue_limit')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.downloadsQueueLimitEnabled = !this.downloadsQueueLimitEnabled;
            this.persistBoolean(downloads_queue_limit, this.downloadsQueueLimitEnabled);
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
    .id('DownloadSettingsFragmentPage')
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(themedBackground(this.blackTheme))
  }
}
