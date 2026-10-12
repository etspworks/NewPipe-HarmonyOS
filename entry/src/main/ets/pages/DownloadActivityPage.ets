/**
 * S3 - DownloadActivity (screen_download_activity).
 *
 * A thin shell: it starts DownloadManagerService, sets toolbar_layout.toolbar as the action bar
 * with home-as-up and R.string.downloads_title, then replaces R.id.frame with a MissionsFragment.
 * onOptionsItemSelected handles ONLY android.R.id.home -> onBackPressed(); every other item of
 * R.menu.download_menu falls through to the fragment, which is why the four menu handlers below
 * are MissionsFragment.onOptionsItemSelected's, not this activity's.
 *
 * screen_missions declares hostedBy: screen_download_activity, so MissionsFragmentPage is MOUNTED
 * in the frame below - it is not forwarded with replaceUrl, which would take this page's identity
 * marker off screen and break its deep link.
 *
 * Menu visibility is the source's, not a guess: MissionAdapter.setClearButton() shows clear_list
 * iff the iterator has finished missions, and checkMasterButtonsVisibility() shows pause_downloads
 * / start_downloads from hasValidPendingMissions() = [something running, something paused]. With
 * an empty list all three are hidden, which is what both captured states show.
 *
 * S4 adds what kept that menu live in the source: MissionAdapter is a MissionEventListener, so
 * this page subscribes to DownloadManager.observeMissions() instead of only refreshing on show.
 * The service lifecycle (startService / bindService / clearDownloadNotifications) maps onto
 * BackgroundWork + Notifications - there is no DownloadManagerService in this port.
 */
import { router, promptAction } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { FocusOverlayView } from '../components/FocusOverlayView';
import { ServiceLocator } from '../common/di/ServiceLocator';
import { AppPreferences } from '../common/prefs/Preferences';
import { DownloadManager, MissionEvent, MissionEventKind } from '../common/download/DownloadManager';
import { Deleter } from '../common/download/Deleter';
import { CompositeDisposable } from '../common/rx/Rx';
import { Localization } from '../common/i18n/Localization';
import { FinishedMission } from '../model/app/FinishedMission';
import { MissionsFragmentPage } from './MissionsFragmentPage';
import { DIALOG_MASK_COLOR } from '../common/theme/ServiceTheme';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

const TAG: string = 'DownloadActivity';
/** MissionsFragment: mPrefs.getBoolean("linear", false) / putBoolean("linear", mLinear). */
const PREF_LINEAR: string = 'linear';
/** DeviceUtils.isTv(this) - UI_MODE_TYPE_TELEVISION / LEANBACK, i.e. deviceType 'tv' here. */
const TV_DEVICE_TYPE: string = 'tv';

@Entry
@Component
export struct DownloadActivityPage {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  /** actionBar.setTitle(R.string.downloads_title) - a static string, not fetched. */
  @State title: Resource = $r('app.string.downloads_title');
  /**
   * The window MissionsFragment spends between bindService() and onServiceConnected(): the
   * adapter does not exist yet, so onPrepareOptionsMenu skips setAdapterButtons() and the three
   * conditional menu items stay at their menu-XML android:visible="false". Nothing else is drawn
   * for it in the source - no spinner - so nothing else is drawn for it here.
   */
  @State isLoading: boolean = true;
  /**
   * The download screen has NO error panel: MissionsFragment reports a failure with a Toast
   * (requestDownloadSaveAsResult -> R.string.general_error) or an AlertDialog
   * (NoFileManagerSafeGuard). So this is the Toast's message, kept as state only so a repeated
   * failure is not re-announced; it renders no panel.
   */
  @State errorInfo: string = '';
  /** MissionsFragment.mLinear - owned here because this screen owns the switch_mode item. */
  @State missionsLinear: boolean = false;
  /** setClearButton(): clearButton.setVisible(mIterator.hasFinishedMissions()). */
  @State hasFinishedMissions: boolean = false;
  /** checkMasterButtonsVisibility(): state[0] - at least one pending mission is running. */
  @State hasRunningMissions: boolean = false;
  /** checkMasterButtonsVisibility(): state[1] - at least one pending mission is paused. */
  @State hasPausedMissions: boolean = false;
  /** DeviceUtils.isTv(this) - the source installs FocusOverlayView only on TV builds. */
  @State isTv: boolean = false;

  /** MissionsFragment.showDeleteDownloadedFilesConfirmationPrompt(). */
  private deleteFilesDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    builder: DeleteDownloadedFilesDialog({
      onConfirm: (): void => {
        this.clearFinishedDownloads(true);
      }
    })
  });

  /** MissionsFragment.showClearDownloadHistoryPrompt(). */
  private clearHistoryDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    builder: ClearDownloadHistoryDialog({
      onClearHistory: (): void => {
        this.clearFinishedDownloads(false);
      },
      onDeleteFiles: (): void => {
        this.deleteFilesDialog.open();
      }
    })
  });

  /** MissionAdapter's own CompositeDisposable: what onDestroy() disposes (Rule 8). */
  private disposables: CompositeDisposable = new CompositeDisposable();

  aboutToAppear(): void {
    this.isTv = deviceInfo.deviceType === TV_DEVICE_TYPE;
    this.missionsLinear = ServiceLocator.get().preferences.getBooleanSync(PREF_LINEAR, false);
    this.connectDownloadService();
  }

  /**
   * DownloadActivity.onCreate's startService(DownloadManagerService) plus
   * MissionsFragment.onCreateView's bindService(BIND_AUTO_CREATE) / onServiceConnected:
   * take the background window, clear the download notifications, register for mission events,
   * then show the menu state. isLoading covers exactly that bind window.
   */
  private async connectDownloadService(): Promise<void> {
    this.isLoading = true;
    try {
      // onServiceConnected(): mBinder.clearDownloadNotifications() is MissionsFragmentPage's, as
      // it is MissionsFragment's. This cancelled id 1000 - the ONGOING row - while downloads ran.

      // onResume(): mBinder.addMissionEventListener(mAdapter). MissionAdapter.handleMessage
      // calls checkMasterButtonsVisibility() per event, which is why the menu is live and not
      // only refreshed on show.
      this.disposables.add(this.downloads().observeMissions().subscribeCallbacks(
        (event: MissionEvent): void => {
          this.onMissionEvent(event);
        },
        (err: Error): void => {
          this.reportError(err.message);
        }
      ));
      // A pending delete hides its rows, and with them possibly the whole Finished section.
      this.disposables.add(Deleter.get().observe().subscribeCallbacks((): void => {
        this.refreshMenuState();
      }));
      this.refreshMenuState();
    } catch (err) {
      this.reportError(err instanceof Error ? err.message : Localization.getString('general_error'));
    } finally {
      this.isLoading = false;
    }
  }

  /**
   * MissionsFragment.onResume(): mAdapter.checkMasterButtonsVisibility(), and
   * mBinder.enableNotifications(false) - no finished/failed rows while the list is in front.
   */
  onPageShow(): void {
    this.downloads().enableNotifications(false);
    this.refreshMenuState();
  }

  /** MissionsFragment.onPause(): mBinder.enableNotifications(true) - also when the app goes. */
  onPageHide(): void {
    this.downloads().enableNotifications(true);
  }

  /**
   * MissionsFragment.onDestroy(): removeMissionEventListener + mAdapter.onDestroy() (Rule 8).
   * The dataTransfer continuous task is the DownloadManager's own now (the source's foreground
   * service), so leaving this screen no longer stops a running download in the background.
   */
  aboutToDisappear(): void {
    this.disposables.dispose();
  }

  /** MissionAdapter.handleMessage(): every mission message re-checks the master buttons. */
  private onMissionEvent(event: MissionEvent): void {
    if (event.kind !== MissionEventKind.PROGRESS) {
      this.refreshMenuState();
    }
  }

  /** requestDownloadSaveAsResult()'s catch: a Toast, never a panel. */
  private reportError(message: string): void {
    const text: string = message.length === 0 ? Localization.getString('general_error') : message;
    hilog.error(0x0000, TAG, 'download screen: %{public}s', text);
    if (this.errorInfo === text) {
      return;
    }
    this.errorInfo = text;
    promptAction.showToast({ message: this.errorInfo, duration: 3000 });
  }

  private downloads(): DownloadManager {
    return ServiceLocator.get().downloadManager;
  }

  /** setClearButton() + checkMasterButtonsVisibility(), off the same manager the fragment reads. */
  private refreshMenuState(): void {
    const manager: DownloadManager = this.downloads();
    let running: boolean = false;
    let paused: boolean = false;
    for (const mission of manager.getPendingMissions()) {
      if (mission.isFinished() || mission.isCorrupt()) {
        continue;
      }
      if (mission.running) {
        running = true;
      } else {
        paused = true;
      }
    }
    this.hasRunningMissions = running;
    this.hasPausedMissions = paused;
    const deleter: Deleter = Deleter.get();
    this.hasFinishedMissions = manager.getFinishedMissions()
      .some((mission: FinishedMission): boolean => !deleter.isHidden(mission));
  }

  /**
   * onOptionsItemSelected(R.id.switch_mode): mLinear = !mLinear; updateList() persists it with
   * mPrefs.edit().putBoolean("linear", mLinear).apply() - and apply() COMMITS. The instance
   * putBoolean is putSync alone, which the next process start loses, so the write goes through
   * the static accessor, which flushes. Same store either way: init() sets AppPreferences.shared
   * to the instance ServiceLocator holds, so the read in aboutToAppear sees this write.
   */
  private toggleLayoutMode(): void {
    this.missionsLinear = !this.missionsLinear;
    AppPreferences.putBoolean(PREF_LINEAR, this.missionsLinear).catch((err: Error) => {
      hilog.error(0x0000, TAG, 'persisting %{public}s: %{public}s', PREF_LINEAR, err.message);
    });
  }

  /** onOptionsItemSelected(R.id.start_downloads). */
  private startAllMissions(): void {
    this.downloads().startAllMissions().then(() => {
      this.refreshMenuState();
    }).catch((err: Error) => {
      hilog.error(0x0000, TAG, 'startAllMissions: %{public}s', err.message);
    });
  }

  /** onOptionsItemSelected(R.id.pause_downloads) - pauseAllMissions(false) + refresh. */
  private pauseAllMissions(): void {
    this.downloads().pauseAllMissions();
    this.refreshMenuState();
  }

  /**
   * MissionAdapter.clearFinishedDownloads(delete): deleting the files is held five seconds behind
   * an Undo snackbar (the list shows it), forgetting the entries happens at once.
   */
  private clearFinishedDownloads(deleteFiles: boolean): void {
    const manager: DownloadManager = this.downloads();
    if (deleteFiles) {
      const finished: FinishedMission[] = manager.getFinishedMissions();
      Deleter.get().append(finished, true, Localization.deletedDownloadCount(finished.length));
    } else {
      manager.forgetFinishedDownloads();
    }
    this.refreshMenuState();
  }

  build() {
    Stack() {
      Column() {
      // toolbar_layout.xml, with setDisplayHomeAsUpEnabled(true) and R.menu.download_menu.
      Row() {
        // The Up affordance is an ImageButton in the source, not a label: toolbar_layout's
        // ToolbarTheme tints every icon with ?attr/actionColor = @color/white, and the 24dp
        // glyph sits centred in the 56dp (?attr/actionBarSize) touch target.
        Image($r('app.media.ic_arrow_back'))
          .id('home')
          .accessibilityText($r('app.string.navigate_back'))
          .width(56)
          .height(56)
          .padding(16)
          .objectFit(ImageFit.Contain)
          .fillColor($r('app.color.on_primary'))
          .onClick(() => {
            router.back();
          })
        // Widget.AppCompat.Toolbar.Title: 20sp medium, inset 16dp past the navigation button.
        Text(this.title)
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_primary'))
          .margin({ left: 16 })

        Blank()

        // switch_mode: showAsAction="always", so it is the one item always on the bar.
        // updateList() sets its title to grid when linear, list otherwise.
        // updateList(): mSwitch.setIcon(mLinear ? ic_apps : ic_list) - the icon carries the
        // state, so the binding moves onto the glyph. 48dp action item, flush to the bar's end.
        Image(this.missionsLinear ? $r('app.media.ic_apps') : $r('app.media.ic_list'))
          .id('switch_mode')
          .accessibilityText(this.missionsLinear ? $r('app.string.grid') : $r('app.string.list'))
          .width(48)
          .height(48)
          .padding(12)
          .objectFit(ImageFit.Contain)
          .fillColor($r('app.color.on_primary'))
          .onClick(() => {
            this.toggleLayoutMode();
          })

        // The other three are android:visible="false" in the menu XML and are revealed only by
        // the adapter, from the mission list's real state - so while the service is still binding
        // (no adapter yet, onPrepareOptionsMenu skips setAdapterButtons) all three stay hidden.
        //
        // start_downloads and pause_downloads are action items carrying a GLYPH, not a label:
        // the header shows the play-all icon while anything is paused and the pause-all icon
        // while anything is running, which is the state swap both cards describe. The port had
        // put their titles on the bar as text, which is what "the Start downloads button text is
        // shown instead of the icon" reports - and a bare Text has no action-item touch target
        // either, which is the other half of it.
        if (!this.isLoading && this.hasPausedMissions) {
          Image($r('app.media.ic_play_arrow'))
            .id('start_downloads')
            .accessibilityText($r('app.string.start_downloads'))
            .width(48)
            .height(48)
            .padding(12)
            .objectFit(ImageFit.Contain)
            .fillColor($r('app.color.on_primary'))
            .onClick(() => {
              this.startAllMissions();
            })
        }
        if (!this.isLoading && this.hasRunningMissions) {
          Image($r('app.media.ic_pause'))
            .id('pause_downloads')
            .accessibilityText($r('app.string.pause_downloads'))
            .width(48)
            .height(48)
            .padding(12)
            .objectFit(ImageFit.Contain)
            .fillColor($r('app.color.on_primary'))
            .onClick(() => {
              this.pauseAllMissions();
            })
        }
        // clear_list is an ACTION ITEM carrying the delete glyph, not an overflow row. The
        // reference build (0.29.1, device-checked) shows a trash can straight on the bar and has
        // no three-dot affordance here at all; this port had put the same action behind an
        // overflow, which is what the case means by "the three dots in the top right corner
        // should be removed, a trash can button should be added". The three dots stay where the
        // reference keeps them - on the ITEM, not on the toolbar.
        //
        // It is drawn only while something is FINISHED: setClearButton() is
        // clearButton.setVisible(mIterator.hasFinishedMissions()), so with nothing completed the
        // reference has no clear_list on the bar at all - device-checked on 0.29.1 in grid and in
        // list view with one paused mission and no finished section. Leaving it up with nothing to
        // clear is what this card reports.
        if (!this.isLoading && this.hasFinishedMissions) {
          Image($r('app.media.ic_delete'))
            .id('clear_list')
            .accessibilityText($r('app.string.clear_download_history'))
            .width(48)
            .height(48)
            .padding(12)
            .margin({ right: 8 })
            .objectFit(ImageFit.Contain)
            .fillColor($r('app.color.on_primary'))
            .onClick(() => {
              this.clearHistoryDialog.open();
            })
        }
      }
      .width('100%')
      // Toolbar: ?attr/actionBarSize tall, android:background="?attr/colorPrimary".
      .height(56)
      .alignItems(VerticalAlign.Center)
      .backgroundColor($r('app.color.primary'))

      // updateFragments(): replace(R.id.frame, new MissionsFragment(), MISSIONS_FRAGMENT_TAG).
      Column() {
        MissionsFragmentPage({ missionsLinear: this.missionsLinear })
      }
      .id('frame')
      .width('100%')
      .layoutWeight(1)
      .backgroundColor(themedBackground(this.blackTheme))
      }
      .width('100%')
      .height('100%')

      // DeviceUtils.isTv(this) -> FocusOverlayView.setupFocusObserver(this): the source adds the
      // focus overlay to the DECOR view, so it sits over the whole page, not inside the frame.
      FocusOverlayView({ isTv: this.isTv })
    }
    .id('DownloadActivityPage')
    .width('100%')
    .height('100%')
    .backgroundColor(themedBackground(this.blackTheme))
  }
}

/**
 * showClearDownloadHistoryPrompt(): title clear_download_history, message confirm_prompt, and the
 * source's deliberately swapped buttons - negative clears the history, positive goes on to the
 * delete-files confirmation, neutral cancels.
 */
@CustomDialog
struct ClearDownloadHistoryDialog {
  controller?: CustomDialogController;
  onClearHistory: () => void = (): void => {
    hilog.debug(0x0000, TAG, 'ClearDownloadHistoryDialog: clear not bound');
  };
  onDeleteFiles: () => void = (): void => {
    hilog.debug(0x0000, TAG, 'ClearDownloadHistoryDialog: delete not bound');
  };

  build() {
    Column() {
      Text($r('app.string.clear_download_history'))
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.on_surface'))
        .width('100%')
      Text($r('app.string.confirm_prompt'))
        .fontSize(16)
        .fontColor($r('app.color.on_surface_variant'))
        .width('100%')
        .margin({ top: 16 })

      // Three labels this long do not fit one row: the port laid them out horizontally and the
      // third - "Delete downloaded files", the destructive one - was clipped to "Delete downl...",
      // so a user could not read what they were about to tap. AlertDialog STACKS its buttons when
      // they will not fit, positive first, then negative, then neutral, each right-aligned and in
      // the theme's caps. Measured on the reference: DELETE DOWNLOADED FILES / CLEAR DOWNLOAD
      // HISTORY / CANCEL. The handlers keep the source's deliberately swapped roles - positive
      // deletes the files, negative clears the history, neutral cancels.
      Column() {
        Text(Localization.buttonLabel('delete_downloaded_files'))
          .id('delete_downloaded_files')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_surface'))
          .padding({ left: 8, right: 8, top: 10, bottom: 10 })
          .onClick(() => {
            this.controller?.close();
            this.onDeleteFiles();
          })
        Text(Localization.buttonLabel('clear_download_history'))
          .id('clear_history_confirm')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_surface'))
          .padding({ left: 8, right: 8, top: 10, bottom: 10 })
          .onClick(() => {
            this.controller?.close();
            this.onClearHistory();
          })
        Text(Localization.buttonLabel('cancel'))
          .id('clear_history_cancel')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_surface'))
          .padding({ left: 8, right: 8, top: 10, bottom: 10 })
          .onClick(() => {
            this.controller?.close();
          })
      }
      .width('100%')
      .alignItems(HorizontalAlign.End)
      .margin({ top: 8 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(24)
    .backgroundColor($r('app.color.dialog_background'))
  }
}

/** showDeleteDownloadedFilesConfirmationPrompt(): one more confirmation before touching disk. */
@CustomDialog
struct DeleteDownloadedFilesDialog {
  controller?: CustomDialogController;
  onConfirm: () => void = (): void => {
    hilog.debug(0x0000, TAG, 'DeleteDownloadedFilesDialog: confirm not bound');
  };

  build() {
    Column() {
      Text($r('app.string.delete_downloaded_files_confirm'))
        .fontSize(16)
        .fontColor($r('app.color.on_surface_variant'))
        .width('100%')

      Row() {
        Text($r('app.string.cancel'))
          .id('delete_files_cancel')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_surface'))
          .padding({ left: 8, right: 8, top: 10, bottom: 10 })
          .onClick(() => {
            this.controller?.close();
          })
        Text($r('app.string.ok'))
          .id('delete_files_confirm')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_surface'))
          .padding({ left: 8, right: 8, top: 10, bottom: 10 })
          .onClick(() => {
            this.controller?.close();
            this.onConfirm();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .margin({ top: 8 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(24)
    .backgroundColor($r('app.color.dialog_background'))
  }
}
