/**
 * S4 - BackupRestoreSettingsFragment (screen_backup_restore_settings). Structure read verbatim off
 * codegraph (BackupRestoreSettingsFragment.onCreatePreferences) and
 * res/xml/backup_restore_settings.xml; the wiring below is the rest of that same class
 * (requestImportPathResult / requestExportPathResult / importDatabase / exportDatabase /
 * cleanImport / finishImport / getImportExportDataUri / saveLastImportExportDataUri) plus
 * SubscriptionsImportExportHelper for the two subscription rows.
 *
 * Five rows, in XML order, each a plain androidx `Preference` with a title AND a summary - there is
 * no switch, no list dialog and no icon on this screen (`app:iconSpaceReserved="false"` on every
 * row). No navOut: none of the five pushes a page. hostedBy screen_settings_activity, which PUSHES
 * this page (router.pushUrl) and draws the toolbar - this page draws neither, exactly as the
 * sibling preference screens do.
 *
 * The rows are BasePreferenceFragment's preference RecyclerView, so they are a real List with one
 * ListItem per row (same shape as AppearanceSettingsFragmentPage), not a plain Column.
 *
 * The data layer is IMPORTED, never re-implemented: svc_settings_backup (BackupRestore: the zip
 * pack/unpack, the JSON preferences, the legacy-serialized refusal), svc_file_access (FileAccess /
 * StoredFile: the SAF substitution) and svc_preferences (AppPreferences). Only the two backup
 * pickers are built here rather than through FileAccess.pickFileToOpen/pickFileToSave, because the
 * source starts them at getImportExportDataUri() and those two wrappers take no start location -
 * see pickBackupToOpen().
 *
 * The four conditionalVariants of the plan entry:
 *   1. !ZipHelper.isValidZipFile(file) -> no_valid_zip_file toast, abort before any DB write.
 *      Probed with backupHasJsonPrefs(), which unpacks the archive: a file that is not a zip
 *      cannot be unpacked, which is the same answer isValidZipFile gives.
 *   2. exportHasJsonPrefs || exportHasSerializedPrefs -> the second AlertDialog(import_settings).
 *      The ported backup format is JSON-only (BackupRestore's own header), so the serialized-only
 *      case surfaces as LegacySerializedBackupError AFTER the database has been restored, and it
 *      is reported with import_settings_vulnerable_format - the message the source shows for
 *      exactly that backup.
 *   3. disabled_media_tunneling_automatically_key == 1 && disable_media_tunneling_key -> both are
 *      reset and setMediaTunneling is re-run for THIS device (cleanImport()).
 *   4. !extractDb(file) -> could_not_import_all_files toast, and the import CONTINUES.
 *
 * feat_process_restart: NavigationHelper.restartApp(activity) restarts the OS PROCESS so the
 * replaced database file is re-opened. ArkTS DOES expose that - ApplicationContext.restartApp(want),
 * @since 12, @stagemodelonly, no permission - so restartApp() below calls it and this feature is
 * PORTED, not substituted. The router reset is only the fallback for the errors the OS documents on
 * that call (16000053 not on top / 16000064 restarted under 3 s ago / 16000050 internal).
 */

import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { promptAction, router } from '@kit.ArkUI';

import { AppDatabase } from '../common/db/AppDatabase';
import { SubscriptionManager } from '../common/db/SubscriptionManager';
import { ServiceLocator } from '../common/di/ServiceLocator';
import { Localization } from '../common/i18n/Localization';
import { FileAccess, StoredFile } from '../common/file/FileAccess';
import { AppPreferences, PrefValue } from '../common/prefs/Preferences';
import {
  disable_media_tunneling_key,
  disabled_media_tunneling_automatically_key,
  import_export_data_path,
  media_tunneling_device_blacklist_version
} from '../common/prefs/SettingsKeys';
import {
  BackupRestore,
  FILE_NAME_JSON_PREFS,
  LegacySerializedBackupError
} from '../common/settings/BackupRestore';
import { enqueueSubscriptionImport } from '../common/subscription/SubscriptionImportWork';
import { SubscriptionImportInput } from './ImportConfirmationDialogPage';
import { PREVIOUS_EXPORT_SERVICE_ID } from './SubscriptionFragmentPage';
import { DATABASE_NAME } from '../model/app/AppDatabase';
import { SubscriptionItem } from '../model/app/SubscriptionData';
import { SubscriptionEntity } from '../model/db/entity/SubscriptionEntity';
import { DIALOG_MASK_COLOR } from '../common/theme/ServiceTheme';
import { settingsListScroller } from '../common/settings/SettingsScroller';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

const TAG: string = 'BackupRestoreSettingsFragment';

/* S5 - style only, LightTheme (the theme base.ui.json renders in). Reuses the run's style baseline
 * (state.json generation.styleBaseline, source S0004) for background / onSurface / secondaryText, and
 * the AndroidX preference-row metrics the sibling preference screens already carry
 * (AppearanceSettingsFragmentPage) - this screen's own base.ui.json confirms every one of them at
 * 1080px/360vp: 16vp gutters (title x=48px, row right edge 1032px) and 16vp vertical row padding
 * (row 2 = [507..725]: 48px above the title, 48px below the summary). S6 took the two line heights
 * off the same capture: the title TextView is 65px tall (16sp -> 21.7vp, rendered at 22) and a
 * two-line summary is 106px (14sp -> 17.7vp per line, rendered at 18), which puts row 1 at 90vp
 * against the captured 89vp. setDivider(null) in
 * BasePreferenceFragment, so the list carries no separators, and every row here has
 * app:iconSpaceReserved="false", so no icon column is reserved either. The toolbar in the capture is
 * drawn by the HOST (SettingsActivityPage), not by this page. */
/** ?attr/windowBackground - light_background_color, the capture's #EEEEEE. */
const COLOR_SURFACE: Resource = $r('app.color.background');
/** ?attr/colorPrimary - the indeterminate progress tint. */
const COLOR_PRIMARY: Resource = $r('app.color.primary');
/** ?android:textColorPrimary - #DE000000 over #EEEEEE is the capture's row title. */
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');
/** ?android:textColorSecondary - #8A000000 over #EEEEEE is the capture's summary. */
const COLOR_SECONDARY_TEXT: Resource = $r('app.color.on_surface_variant');

/**
 * ?attr/colorAccent - the AlertDialog button colour. Settings runs under LightSettingsTheme, whose
 * only override IS colorAccent = @color/light_settings_accent_color (#E53935), which is why the
 * sibling settings captures render CANCEL red rather than the LightTheme black.
 */
const COLOR_ACCENT: Resource = $r('app.color.settings_accent');
/** The AlertDialog surface: white in the captures, NOT light_dialog_background_color. */
const COLOR_DIALOG_SURFACE: Resource = $r('app.color.dialog_surface');
/** Theme.AppCompat.Dialog's window background is a square 9-patch: no corner rounding. */
const DIALOG_CORNER_RADIUS: number = 0;
const DIALOG_WIDTH: number = 294;

/** BackupRestoreSettingsFragment.ZIP_MIME_TYPE, verbatim. */
const ZIP_MIME_TYPE: string = 'application/zip';
/** SubscriptionFragment.JSON_MIME_TYPE, verbatim. */
const JSON_MIME_TYPE: string = 'application/json';
/** DeviceUtils.MEDIA_TUNNELING_DEVICE_BLACKLIST_VERSION, verbatim. */
const MEDIA_TUNNELING_DEVICE_BLACKLIST_VERSION: number = 994;
/** NavigationHelper.restartApp() re-enters MainActivity; here that is the router root. */
const ROOT_PAGE: string = 'pages/MainActivityPage';

function pad2(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}

/** SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US) - the backup file name. */
function exportDateFormat(now: Date): string {
  return `${now.getFullYear()}${pad2(now.getMonth() + 1)}${pad2(now.getDate())}`
    + `_${pad2(now.getHours())}${pad2(now.getMinutes())}${pad2(now.getSeconds())}`;
}

/** SimpleDateFormat("yyyyMMddHHmm", Locale.ENGLISH) - the subscriptions export name. */
function subscriptionsDateFormat(now: Date): string {
  return `${now.getFullYear()}${pad2(now.getMonth() + 1)}${pad2(now.getDate())}`
    + `${pad2(now.getHours())}${pad2(now.getMinutes())}`;
}

/**
 * The confirmation dialog every row on this screen raises.
 *
 * It used to be ArkUI's stock `AlertDialog.show()`, whose chrome is not the AppCompat one the
 * source has: it centres the message and lays its own buttons out rather than putting them at the
 * bottom right. There is no parameter for either - `AlertDialogParam` carries no text alignment and
 * no button placement - so the dialog is drawn here, in the same `@CustomDialog` shape
 * `components/ConfirmDeleteDialog` already uses: title and message left aligned at the 24vp gutter,
 * CANCEL (button2, which only dismisses) and OK (button1) side by side at the bottom right, and the
 * labels uppercased through Localization.buttonLabel() because Widget.AppCompat.Button carries
 * android:textAllCaps.
 *
 * `title` and `message` are already-resolved strings rather than ResourceStr, so an empty one means
 * "this dialog has none" - the source has dialogs with only a message, and one with both.
 */
@CustomDialog
struct BackupConfirmDialog {
  controller?: CustomDialogController;
  title: string = '';
  message: string = '';
  /** setPositiveButton only, i.e. the notice that is acknowledged rather than answered. */
  confirmOnly: boolean = false;
  onConfirm: () => void = (): void => {
    hilog.debug(0x0000, TAG, 'BackupConfirmDialog: confirm not bound');
  };
  onCancel: () => void = (): void => {
    hilog.debug(0x0000, TAG, 'BackupConfirmDialog: cancel not bound');
  };

  build() {
    Column() {
      if (this.title.length > 0) {
        Text(this.title)
          .width('100%')
          .fontSize(20)
          .fontColor(COLOR_ON_SURFACE)
          .textAlign(TextAlign.Start)
          .padding({ left: 24, right: 24, top: 18, bottom: 8 })
      }

      if (this.message.length > 0) {
        Text(this.message)
          .width('100%')
          .fontSize(16)
          .lineHeight(22)
          .fontColor(COLOR_SECONDARY_TEXT)
          .textAlign(TextAlign.Start)
          .padding({ left: 24, right: 24, top: this.title.length > 0 ? 0 : 18, bottom: 8 })
      }

      Row() {
        if (!this.confirmOnly) {
          Button(Localization.buttonLabel('cancel'))
            .id('button2')
            .height(42)
            .backgroundColor(Color.Transparent)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_ACCENT)
            .onClick(() => {
              this.controller?.close();
              this.onCancel();
            })
        }

        Button(Localization.buttonLabel('ok'))
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
      .justifyContent(FlexAlign.End)
      .padding({ right: 12, bottom: 8 })
    }
    .width(DIALOG_WIDTH)
    .backgroundColor(COLOR_DIALOG_SURFACE)
    .borderRadius(DIALOG_CORNER_RADIUS)
    .alignItems(HorizontalAlign.Start)
  }
}

@Entry
@Component
export struct BackupRestoreSettingsFragmentPage {
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
  /**
   * getImportExportDataUri(): defaultPreferences.getString(import_export_data_path, null) - where
   * both pickers open, and what saveLastImportExportDataUri() writes back on success. Never a
   * literal path.
   */
  @State pickerStartLocation: string = '';
  /** "NewPipeData-" + exportDateFormat.format(new Date()) + ".zip", re-formatted on every click. */
  @State exportFileName: string = '';
  /** cleanImport(): prefs.getInt(disabled_media_tunneling_automatically_key, -1). */
  @State disabledMediaTunnelingAutomaticallyKey: number = -1;
  /** An import/export is running: the source blocks behind its dialogs, this guards re-entry. */
  @State isLoading: boolean = false;
  /** showErrorSnackbar(e, request) - the message, kept instead of dropped (no Snackbar in ArkUI). */
  @State errorInfo: string = '';

  /** exportHasJsonPrefs(file) for the backup currently being imported (the second dialog's test). */
  private pendingHasJsonPrefs: boolean = false;

  /** The armed state of the shared confirmation dialog - see showConfirm(). */
  @State confirmTitle: string = '';
  @State confirmMessage: string = '';
  @State confirmOnly: boolean = false;
  private confirmAction: () => void = (): void => {};
  private cancelAction: () => void = (): void => {};

  private confirmDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    customStyle: true,
    builder: BackupConfirmDialog({
      title: this.confirmTitle,
      message: this.confirmMessage,
      confirmOnly: this.confirmOnly,
      onConfirm: (): void => {
        this.confirmAction();
      },
      onCancel: (): void => {
        this.cancelAction();
      }
    })
  });

  /**
   * Arm and raise the screen's one confirmation dialog. `titleName` / `messageName` are string
   * resource NAMES; an empty one means the dialog has no such line, which is how the source's
   * message-only dialogs come across.
   */
  private showConfirm(titleName: string, messageName: string, onConfirm: () => void,
    onCancel: () => void = (): void => {
      hilog.debug(0x0000, TAG, 'confirmation dialog dismissed');
    },
    confirmOnly: boolean = false): void {
    this.confirmTitle = titleName.length > 0 ? Localization.getString(titleName) : '';
    this.confirmMessage = messageName.length > 0 ? Localization.getString(messageName) : '';
    this.confirmOnly = confirmOnly;
    this.confirmAction = onConfirm;
    this.cancelAction = onCancel;
    this.confirmDialog.open();
  }

  async aboutToAppear(): Promise<void> {
    this.exportFileName = `NewPipeData-${exportDateFormat(new Date())}.zip`;
    try {
      this.pickerStartLocation = await AppPreferences.getString(import_export_data_path, '');
      this.disabledMediaTunnelingAutomaticallyKey =
        await AppPreferences.getInt(disabled_media_tunneling_automatically_key, -1);
    } catch (err) {
      this.report(err as BusinessError, 'Reading the backup preferences');
    }
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Shared helpers
  ////////////////////////////////////////////////////////////////////////// */

  private context(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  /** showErrorSnackbar(e, request) -> ErrorUtil.showSnackbar(ErrorInfo(...)). */
  private report(err: BusinessError, request: string): void {
    this.errorInfo = `${request}: ${err.message}`;
    hilog.error(0x0000, TAG, '%{public}s', this.errorInfo);
    try {
      ServiceLocator.get().errorReporter.showUiErrorSnackbar(request, err);
    } catch (reportErr) {
      // the reporter is unavailable before ServiceLocator.init(); the message is already shown
      hilog.warn(0x0000, TAG, 'error reporter unavailable: %{public}s',
        (reportErr as BusinessError).message);
    }
  }

  /**
   * NoFileManagerSafeGuard.launchSafe(): the source's fallback for "no activity can handle the
   * picker intent". @ohos.file.picker is always present, so this only fires when the picker itself
   * refuses to open. A user CANCEL resolves with an empty uri list, so it does not come through here.
   */
  private noFileManager(err: BusinessError): void {
    hilog.warn(0x0000, TAG, 'document picker did not open: %{public}s', err.message);
    promptAction.showToast({
      message: $r('app.string.no_appropriate_file_manager_message'), duration: 3000
    });
  }

  /** saveLastImportExportDataUri(uri) - the FLUSHING static write; the instance one is not saved. */
  private async saveLastImportExportDataUri(uri: string): Promise<void> {
    this.pickerStartLocation = uri;
    await AppPreferences.putString(import_export_data_path, uri);
  }

  /**
   * StoredFileHelper.getPicker(context, ZIP_MIME_TYPE, getImportExportDataUri()). Built here rather
   * than through FileAccess.pickFileToOpen because only DocumentSelectOptions carries the start
   * location the bound preference supplies.
   */
  private async pickBackupToOpen(): Promise<StoredFile | null> {
    const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.fileSuffixFilters = ['.zip'];
    if (this.pickerStartLocation.length > 0) {
      options.defaultFilePathUri = this.pickerStartLocation;
    }
    const view: picker.DocumentViewPicker = new picker.DocumentViewPicker(this.context());
    const uris: string[] = await view.select(options);
    if (uris.length === 0) {
      return null;
    }
    return new StoredFile(uris[0], '', ZIP_MIME_TYPE);
  }

  /** StoredFileHelper.getNewPicker(context, exportFileName, ZIP_MIME_TYPE, getImportExportDataUri()). */
  private async pickBackupToSave(): Promise<StoredFile | null> {
    const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    options.newFileNames = [this.exportFileName];
    if (this.pickerStartLocation.length > 0) {
      options.defaultFilePathUri = this.pickerStartLocation;
    }
    const view: picker.DocumentViewPicker = new picker.DocumentViewPicker(this.context());
    const uris: string[] = await view.save(options);
    if (uris.length === 0) {
      return null;
    }
    return new StoredFile(uris[0], this.exportFileName, ZIP_MIME_TYPE);
  }

  /**
   * finishImport(uri): save the import path, then NavigationHelper.restartApp(activity) — a real
   * process restart, which is what re-opens the database file the import just replaced.
   */
  private async finishImport(importDataUri: string): Promise<void> {
    await this.saveLastImportExportDataUri(importDataUri);
    this.restartApp();
  }

  /**
   * NavigationHelper.restartApp(): restart the PROCESS and re-enter the launch ability.
   *
   * `ApplicationContext.restartApp(want)` (`@since 12`, `@stagemodelonly`) is the real thing —
   * the process comes back up, so the RdbStore handle opened before the import is dropped and the
   * restored database file is re-read. That is the whole point of the source's restart, and an
   * in-app route reset cannot do it: `AppDatabase` is a process-lifetime singleton.
   *
   * It throws where the OS refuses (16000053 the ability is not on top, 16000064 restarted less
   * than 3 s ago, 16000050 internal), so the router reset stays as the FALLBACK — the app is at
   * least back at its root instead of sitting on a settings page over a database it no longer
   * matches. The fallback is not the port; it is what happens when the restart is refused.
   */
  private restartApp(): void {
    const ctx: common.UIAbilityContext = this.context();
    try {
      ctx.getApplicationContext().restartApp({
        bundleName: ctx.abilityInfo.bundleName,
        abilityName: ctx.abilityInfo.name
      });
      return;
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      hilog.error(0x0000, TAG, 'restartApp refused (%{public}d): %{public}s — falling back to the '
        + 'router root', be.code, be.message);
    }
    router.clear();
    router.replaceUrl({ url: ROOT_PAGE })
      .catch((err: BusinessError) => {
        hilog.error(0x0000, TAG, 'restart to the root page failed: %{public}s', err.message);
      });
  }

  /**
   * extractDb(file) returns false when the archive carries no database entry; BackupRestore copies
   * the entry only when it is present and reports nothing back, so the database file itself is the
   * signal. Size + mtime: a copy of a byte-identical file within the same second reads as
   * "not extracted", which costs one extra toast and never a wrong import.
   */
  private databaseFingerprint(): string {
    try {
      const stat: fileIo.Stat =
        fileIo.statSync(`${this.context().databaseDir}/rdb/${DATABASE_NAME}`);
      return `${stat.size}:${stat.mtime}`;
    } catch (err) {
      return '';
    }
  }

  /* //////////////////////////////////////////////////////////////////////////
  // import_data
  ////////////////////////////////////////////////////////////////////////// */

  /**
   * The import row: launch the picker, then requestImportPathResult()'s
   * AlertDialog(override_current_data) before anything is written.
   */
  private async onImportDataClicked(): Promise<void> {
    if (this.isLoading) {
      return;
    }
    let file: StoredFile | null = null;
    try {
      file = await this.pickBackupToOpen();
    } catch (err) {
      this.noFileManager(err as BusinessError);
      return;
    }
    if (file === null) {
      return;
    }
    const picked: StoredFile = file;
    // setNegativeButton(cancel, (d, id) -> d.cancel()) is the default dismiss.
    this.showConfirm('', 'override_current_data', (): void => {
      this.importDatabase(picked);
    });
  }

  /** importDatabase(file, uri): the zip check, then the optional second settings dialog. */
  private async importDatabase(file: StoredFile): Promise<void> {
    const backup: BackupRestore = ServiceLocator.get().backupRestore;
    this.isLoading = true;
    try {
      this.pendingHasJsonPrefs = await backup.backupHasJsonPrefs(file);
    } catch (err) {
      // variant 1 - !ZipHelper.isValidZipFile(file): the archive cannot be opened at all, so the
      // import aborts here, before any database write.
      this.isLoading = false;
      hilog.warn(0x0000, TAG, 'not a valid zip: %{public}s', (err as BusinessError).message);
      promptAction.showToast({ message: $r('app.string.no_valid_zip_file'), duration: 2000 });
      return;
    }
    this.isLoading = false;

    if (!this.pendingHasJsonPrefs) {
      // no readable settings in the backup: the source extracts the database and finishes.
      this.runImport(file, false);
      return;
    }

    // variant 2 - the second AlertDialog(import_settings): import the settings too, or only the
    // database. Both buttons finish the import, exactly as the source's dismiss listener does.
    // setMessage(hasJsonPrefs ? null : getString(import_settings_vulnerable_format)) - the ported
    // backup format is JSON-only, so a readable backup carries no extra warning and this dialog is
    // a title plus its two buttons. CANCEL here is not a dismiss: it is "import the database only".
    this.showConfirm('import_settings', '', (): void => {
      this.runImport(file, true);
    }, (): void => {
      this.runImport(file, false);
    });
  }

  /**
   * The import itself. `importSettings` is the second dialog's answer: BackupRestore restores the
   * database and the settings in one call, so declining means the settings this device already has
   * are put back afterwards - the source's "database extracted, preferences left alone" outcome.
   */
  private async runImport(file: StoredFile, importSettings: boolean): Promise<void> {
    const prefs: AppPreferences = AppPreferences.instance();
    const backup: BackupRestore = ServiceLocator.get().backupRestore;
    const fingerprintBefore: string = this.databaseFingerprint();
    const kept: Map<string, PrefValue> | null =
      (!importSettings && this.pendingHasJsonPrefs) ? prefs.getAll() : null;

    this.isLoading = true;
    let legacySerialized: boolean = false;
    try {
      await backup.importDatabase(file);
    } catch (err) {
      if (err instanceof LegacySerializedBackupError) {
        // variant 2, the serialized-only backup: the database was restored, the settings were not.
        legacySerialized = true;
      } else if (!(err as Error).message.includes(FILE_NAME_JSON_PREFS)) {
        // showErrorSnackbar(e, "Importing database and settings")
        this.report(err as BusinessError, 'Importing database and settings');
        this.isLoading = false;
        return;
      }
    } finally {
      this.isLoading = false;
    }

    if (kept !== null) {
      try {
        prefs.clear();
        kept.forEach((value: PrefValue, key: string): void => {
          prefs.put(key, value);
        });
        await prefs.flush();
      } catch (err) {
        this.report(err as BusinessError, 'Restoring the settings of this device');
      }
    }

    // variant 4 - !manager.extractDb(file): reported, and the import CONTINUES.
    if (this.databaseFingerprint() === fingerprintBefore) {
      promptAction.showToast({
        message: $r('app.string.could_not_import_all_files'), duration: 3000
      });
    }

    if (legacySerialized) {
      this.showVulnerableFormatNotice(file);
      return;
    }
    if (importSettings) {
      await this.cleanImport();
    }
    await this.finishImport(file.getUri());
  }

  /**
   * The source's import_settings dialog for a backup whose settings exist only as the Java
   * ObjectOutputStream dump: it shows import_settings_vulnerable_format. This build cannot read
   * that file at all (BackupRestore's header), so the dialog reports it and the import finishes
   * with the database restored.
   */
  private showVulnerableFormatNotice(file: StoredFile): void {
    this.showConfirm('import_settings', 'import_settings_vulnerable_format', (): void => {
      this.finishImport(file.getUri());
    }, (): void => {
      hilog.debug(0x0000, TAG, 'vulnerable-format notice has no cancel');
    }, true);
  }

  /**
   * cleanImport(context, prefs) - variant 3, verbatim: settings that must not travel between
   * devices are reset after the import.
   */
  private async cleanImport(): Promise<void> {
    try {
      const automatic: number =
        await AppPreferences.getInt(disabled_media_tunneling_automatically_key, -1);
      const tunnelingDisabled: boolean =
        await AppPreferences.getBoolean(disable_media_tunneling_key, false);
      this.disabledMediaTunnelingAutomaticallyKey = automatic;
      if (automatic === 1 && tunnelingDisabled) {
        // The flushing static writes: an unflushed reset is lost on the restart that follows.
        await AppPreferences.putInt(disabled_media_tunneling_automatically_key, -1);
        await AppPreferences.putBoolean(disable_media_tunneling_key, false);
        this.disabledMediaTunnelingAutomaticallyKey = -1;
        // NewPipeSettings.setMediaTunneling(context) for THIS device. Its decision is
        // DeviceUtils.shouldSupportMediaTunneling(), an Android device-model blacklist that has no
        // HarmonyOS counterpart, so this device supports tunneling and only the blacklist version
        // is recorded - the else branch of setMediaTunneling.
        await AppPreferences.putInt(media_tunneling_device_blacklist_version,
          MEDIA_TUNNELING_DEVICE_BLACKLIST_VERSION);
      }
    } catch (err) {
      this.report(err as BusinessError, 'Cleaning the imported settings');
    }
  }

  /* //////////////////////////////////////////////////////////////////////////
  // export_data
  ////////////////////////////////////////////////////////////////////////// */

  /** The export row: the create-document picker, then exportDatabase(file, uri). */
  private async onExportDataClicked(): Promise<void> {
    if (this.isLoading) {
      return;
    }
    // the source formats the name at click time, not once per screen
    this.exportFileName = `NewPipeData-${exportDateFormat(new Date())}.zip`;
    let file: StoredFile | null = null;
    try {
      file = await this.pickBackupToSave();
    } catch (err) {
      this.noFileManager(err as BusinessError);
      return;
    }
    if (file === null) {
      return;
    }

    this.isLoading = true;
    try {
      // executor.submit(NewPipeDatabase::checkpoint).get() - the WAL is flushed into the database
      // file first, otherwise the copied file is missing everything written since the last commit.
      const database: AppDatabase = await AppDatabase.getInstance(this.context());
      await database.execute('PRAGMA wal_checkpoint(FULL)', []);

      await ServiceLocator.get().backupRestore.exportDatabase(file);
      // saveLastImportExportDataUri(uri): the export path is saved ONLY on success
      await this.saveLastImportExportDataUri(file.getUri());
      promptAction.showToast({ message: $r('app.string.export_complete_toast'), duration: 2000 });
    } catch (err) {
      this.report(err as BusinessError, 'Exporting database and settings');
    } finally {
      this.isLoading = false;
    }
  }

  /* //////////////////////////////////////////////////////////////////////////
  // reset_settings
  ////////////////////////////////////////////////////////////////////////// */

  /** AlertDialog(reset_all_settings); OK -> edit().clear().apply() then restartApp(). */
  private onResetSettingsClicked(): void {
    if (this.isLoading) {
      return;
    }
    // setNegativeButton(cancel, (dialogInterface, i) -> { }) dismisses and changes nothing, and
    // setCancelable(true) is CustomDialogController's default autoCancel.
    this.showConfirm('', 'reset_all_settings', (): void => {
      this.resetSettings();
    });
  }

  /** sharedPreferences.edit().clear().apply() then NavigationHelper.restartApp(activity). */
  private resetSettings(): void {
    const prefs: AppPreferences = AppPreferences.instance();
    prefs.clear();
    // clear() is an instance write and does not reach disk on its own: without this flush the old
    // values are still there after a relaunch.
    prefs.flush()
      .then((): void => {
        this.pickerStartLocation = '';
        this.disabledMediaTunnelingAutomaticallyKey = -1;
        this.restartApp();
      })
      .catch((err: BusinessError) => {
        this.report(err, 'Resetting all settings');
      });
  }

  /* //////////////////////////////////////////////////////////////////////////
  // export_subscriptions_key / import_subscriptions_key
  ////////////////////////////////////////////////////////////////////////// */

  /**
   * importExportHelper.onExportSelected(): a create-document picker named
   * newpipe_subscriptions_<yyyyMMddHHmm>.json, then SubscriptionExportWorker writes the local
   * subscriptions into it as a previous-export JSON.
   */
  private async onExportSubscriptionsClicked(): Promise<void> {
    if (this.isLoading) {
      return;
    }
    const exportName: string = `newpipe_subscriptions_${subscriptionsDateFormat(new Date())}.json`;
    let file: StoredFile | null = null;
    try {
      const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      options.newFileNames = [exportName];
      const view: picker.DocumentViewPicker = new picker.DocumentViewPicker(this.context());
      const uris: string[] = await view.save(options);
      file = uris.length === 0 ? null : new StoredFile(uris[0], exportName, JSON_MIME_TYPE);
    } catch (err) {
      this.noFileManager(err as BusinessError);
      return;
    }
    if (file === null) {
      return;
    }

    this.isLoading = true;
    try {
      const manager: SubscriptionManager = await SubscriptionManager.of(this.context());
      const subscriptions: SubscriptionEntity[] = await manager.subscriptions();
      const items: SubscriptionItem[] = [];
      subscriptions.forEach((entity: SubscriptionEntity): void => {
        items.push(new SubscriptionItem(entity.serviceId,
          entity.url === null ? '' : entity.url,
          entity.name === null ? '' : entity.name));
      });
      const json: string = SubscriptionManager.writePreviousExport(items, '', 0);
      const files: FileAccess = ServiceLocator.get().fileAccess;
      if (!files.writeText(file.getUri(), json)) {
        throw new Error(`Could not write ${exportName}`);
      }
      promptAction.showToast({ message: $r('app.string.export_complete_toast'), duration: 2000 });
    } catch (err) {
      this.report(err as BusinessError, 'Exporting subscriptions');
    } finally {
      this.isLoading = false;
    }
  }

  /**
   * importExportHelper.onImportPreviousSelected(): pick a previously exported JSON, confirm it
   * (ImportConfirmationDialog), then import it - SubscriptionImportInput.PreviousExportMode.
   */
  private async onImportSubscriptionsClicked(): Promise<void> {
    if (this.isLoading) {
      return;
    }
    let file: StoredFile | null = null;
    try {
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['.json'];
      const view: picker.DocumentViewPicker = new picker.DocumentViewPicker(this.context());
      const uris: string[] = await view.select(options);
      file = uris.length === 0 ? null : new StoredFile(uris[0], '', JSON_MIME_TYPE);
    } catch (err) {
      this.noFileManager(err as BusinessError);
      return;
    }
    if (file === null) {
      return;
    }

    const picked: StoredFile = file;
    // ImportConfirmationDialog.onCreateDialog(): setMessage(import_network_expensive_warning),
    // setCancelable(true), cancel / ok. No title - the dialog the source shows carries none.
    this.showConfirm('', 'import_network_expensive_warning', (): void => {
      // The import goes to the same worker every other entry point uses
      // (SubscriptionFragmentPage:570, SubscriptionsImportFragmentPage:286). It runs off the UI
      // path inside the dataTransfer task and reports a bad file with the transient
      // subscriptions_import_unsuccessful toast. This screen used to parse the file itself and
      // send the failure through report(), which is UserAction.UI_ERROR - the "App/UI crashed"
      // report TC-SETTINGS-033 sees, for an error the app had already handled.
      enqueueSubscriptionImport(this.context(),
        SubscriptionImportInput.previousExport(PREVIOUS_EXPORT_SERVICE_ID, picked.getUri()));
    });
  }

  build() {
    Column() {
      if (!this.hostDrawsToolbar) {
        // toolbar_layout.xml: the Up affordance and the PreferenceScreen title that
        // BasePreferenceFragment.onViewCreated pushes into the host toolbar. android.R.id.home is
        // the slug. This page is reached by MainSettingsFragmentPage's router.pushUrl(row.route)
        // (MainSettingsFragmentPage line 222) and by nothing else - SettingsActivityPage's
        // settingsFragmentHolder branch for it is unreachable (openSettingsFragment has no caller),
        // so no host draws a bar above this page and the Up affordance has to live here.
        Row() {
          // The Up affordance: a 24vp glyph centred in the ?attr/actionBarSize touch target,
          // tinted ?attr/actionColor = @color/white by ToolbarTheme.
          Image($r('app.media.ic_arrow_back'))
            .id('home')
            .accessibilityText($r('app.string.navigate_back'))
            .objectFit(ImageFit.Contain)
            .width(56)
            .height(56)
            .padding(16)
            .fillColor($r('app.color.on_primary'))
            .onClick(() => {
              router.back();
            })

          // Widget.AppCompat.Toolbar.Title: 20sp medium on ?attr/actionColor, inset 16vp past the
          // navigation button - the capture's 72vp title start.
          Text($r('app.string.settings_category_backup_restore_title'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.on_primary'))
            .margin({ left: 16 })
        }
        .width('100%')
        // Toolbar: ?attr/actionBarSize tall on ?attr/colorPrimary.
        .height(56)
        .alignItems(VerticalAlign.Center)
        .backgroundColor(COLOR_PRIMARY)
      }

      List({ scroller: settingsListScroller }) {
        // -- Preference: import_data ---------------------------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.import_data_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.import_data_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(18)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('import_data')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick((): void => {
            this.onImportDataClicked();
          })
        }

        // -- Preference: export_data ---------------------------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.export_data_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.export_data_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(18)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('export_data')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick((): void => {
            this.onExportDataClicked();
          })
        }

        // -- Preference: reset_settings ------------------------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.reset_settings_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.reset_settings_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(18)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('reset_settings')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick((): void => {
            this.onResetSettingsClicked();
          })
        }

        // -- Preference: export_subscriptions_key --------------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.export_subscriptions_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.export_subscriptions_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(18)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('export_subscriptions_key')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick((): void => {
            this.onExportSubscriptionsClicked();
          })
        }

        // -- Preference: import_subscriptions_key --------------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.import_subscriptions_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.import_subscriptions_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(18)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('import_subscriptions_key')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick((): void => {
            this.onImportSubscriptionsClicked();
          })
        }
      }
      .width('100%')
      .layoutWeight(1)

      // The zip work runs off the picker's callback, so the screen stays up while it does.
      if (this.isLoading) {
        LoadingProgress()
          .width(48)
          .height(48)
          .color(COLOR_PRIMARY)
          .margin({ top: 16, bottom: 16 })
      }

      // ErrorUtil.showSnackbar(ErrorInfo(...)) has no ArkUI analogue on a preference screen; the
      // message it carried is shown here rather than dropped.
      if (this.errorInfo.length > 0) {
        Text(this.errorInfo)
          .width('100%')
          .fontSize(14)
          .lineHeight(18)
          .fontColor(COLOR_SECONDARY_TEXT)
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
      }

      // cleanImport(): media tunneling was disabled AUTOMATICALLY on this device, so it is a
      // device-specific setting that an import resets rather than carrying across.
      if (this.disabledMediaTunnelingAutomaticallyKey === 1) {
        Text($r('app.string.disable_media_tunneling_summary'))
          .width('100%')
          .fontSize(14)
          .lineHeight(18)
          .fontColor(COLOR_SECONDARY_TEXT)
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
      }
    }
    .id('BackupRestoreSettingsFragmentPage')
    .width('100%')
    .height('100%')
    .backgroundColor(themedBackground(this.blackTheme))
  }
}
