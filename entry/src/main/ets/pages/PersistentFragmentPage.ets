/**
 * PersistentFragment (screen_persistent). Captured states S0012-S0015, S0190.
 *
 * RouterActivity.PersistentFragment (RouterActivity.java:691), read verbatim off codegraph.
 * HEADLESS: a retained (setRetainInstance(true)) Fragment with no onCreateView and no views. It
 * exists only to keep the CompositeDisposable and the `running` in-flight counter alive across
 * configuration changes while the extractor works. Its only user-visible output is
 *  - the pleaseWait() Toast (R.string.processing_may_take_a_moment), cancelled via ambWith when
 *    the wait is over, and
 *  - the dialogs it drives, all of which are OVERLAYS on this host, not routes:
 *      present -> screen_loading_dialog  (openDownloadDialog: new LoadingDialog(
 *                 R.string.loading_metadata_title).show(...), dismissed when the stream info
 *                 arrives OR the request fails)
 *      present -> screen_download_dialog (new DownloadDialog(ctx, result).show(fm, ...))
 *      the add-to-playlist chooser (openAddToPlaylistDialog, RouterActivity.java:854:
 *                 PlaylistDialog.createCorrespondingDialog(ctx, List.of(new StreamEntity(info)),
 *                 ...) -> PlaylistAppendDialog or PlaylistCreationDialog)
 *    Mounted below with an ArkUI overlay API; none is ever pushed.
 *
 * The page is HOSTED by screen_router_activity, which pushes this route. RouterActivityPage
 * carries its OWN loading/download slots for its own menu path and is not this call's file - its
 * loadingDialogSlot() can drop LoadingDialogPage in as-is, since the export takes only
 * `show` (required) plus an optional `toolbarTitle`.
 *
 * conditionalVariants - all three are lifecycle/threading behaviour with no view of their own,
 * so they are S4 guards around the dialog show, not layout:
 *   1. lifecycle >= STARTED -> show now, else defer to onResume (runOnVisible below: the
 *      DefaultLifecycleObserver trick that stops DialogFragment.show() throwing
 *      IllegalStateException in the background);
 *   2. SDK_INT < Q && !isChangingConfigurations() -> a REORDER_TO_FRONT intent brings
 *      RouterActivity back to the foreground. HarmonyOS has no analogue (an app may not raise
 *      itself from the background), so it is deliberately NOT implemented - see runOnVisible();
 *   3. running <= 0 after inFlight(false) -> the fragment removes itself, letting RouterActivity
 *      finish (inFlight() below tears the coordinator down at zero).
 *
 * ExtractorHelper.getStreamInfo(...) is the app-side svc_extractor
 * (common/extractor/ExtractorHelper.ts), NOT the extractor's own core/ExtractorHelper.ts
 * (phase2-logic-contract §9). The CompositeDisposable equivalent is disposed in
 * aboutToDisappear() (Rule 8).
 *
 * S5/S6: there is no onCreateView, so nothing of this fragment's own is visible; the only style
 * here is the window background the overlays are mounted over. No control, binding, branch or
 * presentation was added or changed for style.
 */
import { promptAction } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';

import { Localization } from '../common/i18n/Localization';
import { DownloadDialogHost } from './DownloadDialogPage';
import { LoadingDialogPage } from './LoadingDialogPage';
import { PlaylistDialog } from '../components/PlaylistDialog';
import { PlaylistAppendDialog } from '../components/PlaylistAppendDialog';
import { PlaylistCreationDialog } from '../components/PlaylistCreationDialog';
import { ExtractorHelper } from '../common/extractor/ExtractorHelper';
import { StreamInfo } from '../model/extractor/StreamInfo';
import { AppDatabase } from '../common/db/AppDatabase';
import { LocalPlaylistManager, playlistAppendToast } from '../common/db/PlaylistManager';
import { PlaylistMetadataEntry } from '../model/db/view/PlaylistMetadataEntry';
import { StreamEntity } from '../model/db/entity/StreamEntity';
import { DIALOG_MASK_COLOR } from '../common/theme/ServiceTheme';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

const TAG: string = 'PersistentFragment';
/** Toast.LENGTH_LONG. */
const TOAST_LONG_MS: number = 3500;

@Entry
@Component
export struct PersistentFragmentPage {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  /**
   * Handed in by RouterActivityPage's getPersistFragment(): the deep link this host is to
   * fetch stream info for before opening the download dialog. Empty when mounted standalone.
   */
  @Prop url: string = '';
  @Prop serviceId: number = -1;
  /**
   * Which of the fragment's two entry points this mount is for:
   * openDownloadDialog(serviceId, url) (default) or openAddToPlaylistDialog(serviceId, url).
   */
  @Prop addToPlaylist: boolean = false;

  /** `running > 0`: at least one getStreamInfo() is in flight. */
  @State isLoading: boolean = false;
  /** LoadingDialog(R.string.loading_metadata_title) - shown for the whole fetch. */
  @State showLoadingDialog: boolean = false;
  /** DownloadDialog(ctx, result) - shown once the stream info arrives. */
  @State @Watch('onDownloadDialogVisibility') showDownloadDialog: boolean = false;
  /**
   * screen_download_dialog is an AlertDialog: a CustomDialogController fades its own scrim in
   * over the whole window, where a transparent bindSheet carrying a hand-drawn scrim slid in
   * and stopped at the status bar. The flag drives the controller; an outside tap clears it.
   */
  private downloadDialog: CustomDialogController = new CustomDialogController({
    customStyle: true,
    maskColor: DIALOG_MASK_COLOR,
    cancel: (): void => {
      this.showDownloadDialog = false;
    },
    builder: DownloadDialogHost({
      isShown: this.showDownloadDialog,
      serviceId: this.serviceId,
      url: this.url
    })
  });

  private onDownloadDialogVisibility(): void {
    if (this.showDownloadDialog) {
      this.downloadDialog.open();
    } else {
      this.downloadDialog.close();
    }
  }
  /**
   * The throwable the source hands showUnsupportedUrlDialog(currentUrl) / handleError(ErrorInfo).
   * Both of those dialogs belong to RouterActivity itself (RouterActivityPage), which this file
   * does not own, so the failure is recorded and logged here and the loading dialog is dismissed.
   */
  @State errorInfo: string | null = null;

  /** PlaylistDialog.createCorrespondingDialog(): hasPlaylists() picks append vs create. */
  @State hasPlaylists: boolean = false;
  @State appendPlaylists: PlaylistMetadataEntry[] = [];

  /** `private int running` - the in-flight counter the retained fragment exists to hold. */
  private running: number = 0;
  /** onDestroy(): disposables.clear() - a late promise must not touch a torn-down coordinator. */
  private disposed: boolean = false;
  /** getLifecycle().getCurrentState().isAtLeast(Lifecycle.State.STARTED). */
  private isVisible: boolean = true;
  /** The DefaultLifecycleObserver's body, run on the next onResume. */
  private deferred: (() => void) | null = null;
  /** List.of(new StreamEntity(info)) - the stream the add-to-playlist dialog acts on. */
  private addToPlaylistStreams: StreamEntity[] = [];
  private playlistManager: LocalPlaylistManager | null = null;

  /** PlaylistDialog.createCorrespondingDialog(...) - the add-to-playlist entry point. */
  private playlistDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    builder: PlaylistDialog({
      hasPlaylists: this.hasPlaylists,
      onAppend: (): void => {
        this.playlistAppendDialog.open();
      },
      onCreate: (): void => {
        this.playlistCreationDialog.open();
      }
    })
  });

  private playlistAppendDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    // customStyle: the builder draws its own square, sized card. Without it the system
    // dialog container draws a rounded surface under the content and the corners the
    // builder sets are never visible.
    customStyle: true,
    builder: PlaylistAppendDialog({
      playlists: this.appendPlaylists,
      onSelected: (playlist: PlaylistMetadataEntry): void => {
        this.appendToPlaylist(playlist);
      },
      onNewPlaylist: (): void => {
        this.playlistCreationDialog.open();
      }
    })
  });

  private playlistCreationDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    // customStyle: the builder draws its own square, sized card. Without it the system
    // dialog container draws a rounded surface under the content and the corners the
    // builder sets are never visible.
    customStyle: true,
    builder: PlaylistCreationDialog({
      name: '',
      onCreate: (name: string): void => {
        this.createPlaylist(name);
      }
    })
  });

  /* //////////////////////////////////////////////////////////////////////////
  // Lifecycle
  ////////////////////////////////////////////////////////////////////////// */

  aboutToAppear(): void {
    if (this.url.length === 0 || this.serviceId < 0) {
      // Mounted standalone: RouterActivity only adds the fragment when it has a link.
      return;
    }
    if (this.addToPlaylist) {
      this.openAddToPlaylistDialog();
    } else {
      this.openDownloadDialog();
    }
  }

  /** onDestroy(): disposables.clear(). */
  aboutToDisappear(): void {
    this.disposed = true;
    this.deferred = null;
    this.running = 0;
    this.isLoading = false;
  }

  /** onResume(): the deferred body the runOnVisible() observer parked. */
  onPageShow(): void {
    this.isVisible = true;
    const pending: (() => void) | null = this.deferred;
    if (pending !== null) {
      this.deferred = null;
      pending();
    }
  }

  onPageHide(): void {
    this.isVisible = false;
  }

  /* //////////////////////////////////////////////////////////////////////////
  // The in-flight counter and the visibility guard
  ////////////////////////////////////////////////////////////////////////// */

  /**
   * inFlight(started): running++/--; at zero the fragment removes itself from the
   * FragmentManager (conditionalVariant 3), which is what lets RouterActivity finish.
   */
  private inFlight(started: boolean): void {
    if (started) {
      this.running++;
    } else {
      this.running--;
      if (this.running <= 0) {
        this.running = 0;
        // fm.beginTransaction().remove(this).commit(): the coordinator is done.
        this.disposed = true;
        this.deferred = null;
      }
    }
    this.isLoading = this.running > 0;
  }

  /**
   * runOnVisible(): guards against showing a dialog while in the background
   * (conditionalVariant 1). The SDK_INT < Q REORDER_TO_FRONT branch (conditionalVariant 2) has no
   * HarmonyOS analogue - an app cannot pull itself back to the foreground - so the body simply
   * waits for onPageShow, as it does on Android 10+.
   */
  private runOnVisible(action: () => void): void {
    if (this.disposed) {
      // ifPresentOrElse's empty branch: no activity context left.
      this.inFlight(false);
      return;
    }
    if (this.isVisible) {
      action();
      this.inFlight(false);
      return;
    }
    this.deferred = (): void => {
      action();
      this.inFlight(false);
    };
  }

  /**
   * pleaseWait(): "Getting the stream info usually takes a moment", shown as the fetch starts.
   * ponytail: the source cancels the toast through ambWith when the wait ends;
   * promptAction.closeToast needs a toast id from openToast (API 18+), so this one lives out its
   * LENGTH_LONG duration instead. Swap to openToast/closeToast if compatibleSdkVersion >= 18.
   */
  private pleaseWait(): void {
    promptAction.showToast({
      message: $r('app.string.processing_may_take_a_moment'),
      duration: TOAST_LONG_MS
    });
  }

  /* //////////////////////////////////////////////////////////////////////////
  // openDownloadDialog(currentServiceId, currentUrl)
  ////////////////////////////////////////////////////////////////////////// */

  private async openDownloadDialog(): Promise<void> {
    this.inFlight(true);
    this.errorInfo = null;
    // new LoadingDialog(R.string.loading_metadata_title).show(fm, "loadingDialog").
    this.showLoadingDialog = true;
    this.pleaseWait();
    try {
      // getStreamInfo(serviceId, url, true): forceLoad, so DownloadDialogPage's own read of the
      // same (serviceId, url) comes straight back off the InfoCache this call primes - the
      // ArkUI equivalent of handing `result` to new DownloadDialog(ctx, result).
      await ExtractorHelper.getStreamInfo(this.serviceId, this.url, true);
      this.runOnVisible((): void => {
        this.showLoadingDialog = false;
        this.showDownloadDialog = true;
      });
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      // throwable -> loadingDialog.dismiss(); showUnsupportedUrlDialog(currentUrl) - that dialog
      // is RouterActivity's own and lives in RouterActivityPage, which this file does not own.
      // Nothing here renders errorInfo, so the failure is toasted (the source's toast / error
      // notification fallback) - otherwise the page just stays blank after the fetch fails.
      this.errorInfo = failure.message;
      hilog.error(0x0000, TAG, 'getStreamInfo failed for %{public}s: %{public}s',
        this.url, failure.message);
      promptAction.showToast({ message: failure.message, duration: TOAST_LONG_MS });
      this.runOnVisible((): void => {
        this.showLoadingDialog = false;
      });
    }
  }

  /* //////////////////////////////////////////////////////////////////////////
  // openAddToPlaylistDialog(currentServiceId, currentUrl)
  ////////////////////////////////////////////////////////////////////////// */

  private async openAddToPlaylistDialog(): Promise<void> {
    this.inFlight(true);
    this.errorInfo = null;
    this.pleaseWait();
    try {
      // getStreamInfo(serviceId, url, false) -> List.of(new StreamEntity(info)).
      const info: StreamInfo = await ExtractorHelper.getStreamInfo(this.serviceId, this.url,
        false);
      this.addToPlaylistStreams = [StreamEntity.fromStreamInfo(info)];
      const manager: LocalPlaylistManager = await this.playlists();
      const stored: PlaylistMetadataEntry[] = await manager.getPlaylistDuplicates(info.getUrl());
      this.appendPlaylists = stored;
      this.hasPlaylists = stored.length > 0;
      // PlaylistDialog.createCorrespondingDialog() is a FACTORY in the source, not a
      // dialog of its own: with playlists it shows the append dialog, without any it
      // goes straight to creation. The port made it a visible intermediate dialog
      // carrying one unstyled Text, which rendered as a chromeless pill and meant the
      // append dialog behind it never opened at all.
      this.runOnVisible((): void => {
        if (this.hasPlaylists) {
          this.playlistAppendDialog.open();
        } else {
          this.playlistCreationDialog.open();
        }
      });
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      // throwable -> handleError(ctx, new ErrorInfo(..., UserAction.REQUESTED_STREAM, ...)):
      // the error panel belongs to RouterActivity, not to this fragment.
      this.errorInfo = failure.message;
      hilog.error(0x0000, TAG, 'add to playlist failed for %{public}s: %{public}s',
        this.url, failure.message);
      this.runOnVisible((): void => {
        this.showLoadingDialog = false;
      });
    }
  }

  private async playlists(): Promise<LocalPlaylistManager> {
    const existing: LocalPlaylistManager | null = this.playlistManager;
    if (existing !== null) {
      return existing;
    }
    const context: common.Context = getContext(this) as common.Context;
    const db: AppDatabase = await AppDatabase.getInstance(context);
    const manager: LocalPlaylistManager = new LocalPlaylistManager(db);
    this.playlistManager = manager;
    return manager;
  }

  private async appendToPlaylist(playlist: PlaylistMetadataEntry): Promise<void> {
    try {
      const manager: LocalPlaylistManager = await this.playlists();
      await manager.appendToPlaylist(playlist.uid, this.addToPlaylistStreams);
      // PlaylistAppendDialog.onPlaylistSelected() ends in a Toast on the reference - the string
      // `playlist_add_stream_success` ("Playlisted") was already in this port's resources and had
      // no caller anywhere, so an append finished silently. Every entry point that appends says
      // so, not just the one the case happens to name.
      promptAction.showToast({ message: playlistAppendToast(playlist),
        duration: 2000 });
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.errorInfo = failure.message;
      hilog.error(0x0000, TAG, 'appendToPlaylist failed: %{public}s', failure.message);
    }
  }

  private async createPlaylist(name: string): Promise<void> {
    try {
      const manager: LocalPlaylistManager = await this.playlists();
      await manager.createPlaylist(name, this.addToPlaylistStreams);
      // PlaylistCreationDialog: Toast @string/playlist_creation_success.
      promptAction.showToast({ message: $r('app.string.playlist_creation_success'),
        duration: 2000 });
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.errorInfo = failure.message;
      hilog.error(0x0000, TAG, 'createPlaylist failed: %{public}s', failure.message);
    }
  }

  @Builder
  loadingDialogBody() {
    // new LoadingDialog(R.string.loading_metadata_title) - the @StringRes constructor argument,
    // resolved by name; never a literal.
    LoadingDialogPage({
      isShown: this.showLoadingDialog,
      toolbarTitle: Localization.getString('loading_metadata_title')
    })
  }


  build() {
    Column() {
      // No onCreateView in the source: this host renders nothing of its own. The inner Column
      // exists only to carry the content cover: bindContentCover and bindSheet stacked on ONE
      // node leave the cover unable to open (device: blank page for the whole fetch, no
      // LoadingDialogPage node mounted) - the same defect SubscriptionFragmentPage splits.
      Column() {
      }
      .width('100%')
      .height('100%')
      // setCancelable(false) on LoadingDialog: a full content cover, dismissed only by its own
      // toolbar navigation button or by the owning code clearing showLoadingDialog.
      .bindContentCover($$this.showLoadingDialog, this.loadingDialogBody())
    }
    .id('PersistentFragmentPage')
    .width('100%')
    .height('100%')
    // No onCreateView in the source, so there is nothing to style here beyond the window
    // background the two overlays are mounted over.
    .backgroundColor(themedBackground(this.blackTheme))
  }
}
