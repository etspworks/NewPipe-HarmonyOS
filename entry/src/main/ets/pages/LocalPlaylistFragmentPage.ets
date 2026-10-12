/*
 * S3 - LocalPlaylistFragment (screen_local_playlist), the LOCAL playlist screen
 * (PlaylistFragment is the remote one).
 *
 * STRUCTURE from the source view tree: fragment_playlist.xml is items_list over
 * loading_progress_bar / empty_state_view / error_panel, and the "header" is not an app bar but
 * a RecyclerView header supplied by getListHeaderSupplier() - local_playlist_header.xml:
 * playlist_title_view (which IS the rename affordance), playlist_stream_count, and an included
 * playlist_control.xml with its three buttons, each carrying BOTH a click (play) and a long-click
 * (enqueue) through PlayButtonHelper.
 *
 * menu_local_playlist.xml puts Share in the bar (showAsAction=ifRoom) and Rename / Remove watched
 * / Remove duplicates in the overflow. Each opens an AlertDialog, and those dialogs are plain
 * @CustomDialogs owned by this screen - they are not planned overlay screens.
 *
 * S3 = structure + wiring. No colours, no typography, no spacing: those are S5/S6.
 */
import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

import { PlayQueueItem } from '../model/app/PlayQueueItem';
import { PlaylistEntity } from '../model/db/entity/PlaylistEntity';
import { SimplePlayQueue, setCurrentPlayQueue } from '../model/app/PlayQueue';
import { PlaylistStreamEntry } from '../model/db/view/PlaylistStreamEntry';
import { PlaylistLocalItem } from '../model/db/view/PlaylistLocalItem';
import { LocalItemType } from '../model/enums/LocalItemLocalItemType';
import { StreamStateEntity } from '../model/db/entity/StreamStateEntity';

import { AppDatabase } from '../common/db/AppDatabase';
import { LocalPlaylistManager, playlistAppendToast } from '../common/db/PlaylistManager';
import { HistoryRecordManager } from '../common/db/HistoryRecordManager';
import { ShareUtils, PlayListShareMode } from '../common/share/ShareUtils';
import { ServiceLocator } from '../common/di/ServiceLocator';
import { ExtractorHelper } from '../common/extractor/ExtractorHelper';
import { StreamInfo } from '../model/extractor/StreamInfo';
import { BackgroundWorkMode } from '../common/background/BackgroundWork';
import { PlayerService } from '../common/player/PlayerService';
import { PlayerPrefs } from '../common/player/PlayerPrefs';

import { MediaSessionService } from '../common/player/MediaSessionService';
import { openPopupOnSurface, PopupPlayerSurface } from '../components/PopupPlayerSurface';
import { buildStreamMenuActions, StreamMenuHandlers,
  StreamMenuTarget } from '../components/InfoItemDialog';
import { enqueueStream, markStreamAsWatched, enqueueNextStream, enqueueAllOnPlayer }
  from '../common/util/StreamRowActions';
import { isAudioStream, isLiveStream } from '../model/app/StreamItem';
import { StreamInfoItem } from '../model/extractor/StreamInfoItem';
import { PlaylistAppendDialog } from '../components/PlaylistAppendDialog';
import { PlaylistCreationDialog } from '../components/PlaylistCreationDialog';
import { DownloadDialogHost } from './DownloadDialogPage';
import { PlaylistMetadataEntry } from '../model/db/view/PlaylistMetadataEntry';
import { StreamEntity } from '../model/db/entity/StreamEntity';
import { AppPreferences } from '../common/prefs/Preferences';
import { show_hold_to_append_key } from '../common/prefs/SettingsKeys';
import { DebounceSaver } from '../common/util/DebounceSaver';
import { CompositeDisposable } from '../common/rx/Rx';

import { LocalItemListAdapter, LocalItemDataSource } from '../components/LocalItemListAdapter';
import { LocalItemHolder } from '../components/LocalItemHolder';
import { LocalPlaylistStreamItemHolder } from '../components/LocalPlaylistStreamItemHolder';
import { LocalStatisticStreamItemHolder } from '../components/LocalStatisticStreamItemHolder';
import { LocalPlaylistItemHolder } from '../components/LocalPlaylistItemHolder';
import { LocalBookmarkPlaylistItemHolder } from '../components/LocalBookmarkPlaylistItemHolder';
import { RemotePlaylistItemHolder } from '../components/RemotePlaylistItemHolder';
import { RemoteBookmarkPlaylistItemHolder } from '../components/RemoteBookmarkPlaylistItemHolder';
import { PlaylistItemHolder } from '../components/PlaylistItemHolder';
import { HeaderFooterHolder } from '../components/HeaderFooterHolder';
import { FallbackViewHolder } from '../components/FallbackViewHolder';
import { DialogAction, InfoItemDialog } from '../components/InfoItemDialog';
import { Localization } from '../common/i18n/Localization';
import { MiniPlayerBar } from '../components/MiniPlayerBar';
import { DIALOG_MASK_COLOR } from '../common/theme/ServiceTheme';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

const TAG: string = 'LocalPlaylistFragmentPage';

/** DebounceSaver's own default window - LocalPlaylistFragment uses `new DebounceSaver(this)`. */
/** Toast.LENGTH_SHORT: what the reference's first toast occupies before the tip queues. */
const HOLD_TO_APPEND_TIP_DELAY: number = 2000;

const SAVE_DEBOUNCE_MILLIS: number = 10000;
/**
 * How far the handle must travel for one position until a row reports its real height.
 * ponytail: a fixed fallback (BookmarkFragmentPage's); the measured height replaces it on layout.
 */
const DEFAULT_ROW_STEP_VP: number = 56;

/** newInstance(playlistId, name) - the fragment arguments. */
class PlaylistParams {
  playlistId: number;
  name: string;

  constructor(playlistId: number, name: string) {
    this.playlistId = playlistId;
    this.name = name;
  }
}

/** NavigationHelper.openVideoDetailFragment(serviceId, url, title). */
class ItemParams {
  serviceId: number;
  url: string;
  name: string;

  constructor(serviceId: number, url: string, name: string) {
    this.serviceId = serviceId;
    this.url = url;
    this.name = name;
  }
}

/**
 * LocalItemListAdapter renders PlaylistLocalItem, and a PlaylistStreamEntry is only a LocalItem,
 * so the row is wrapped the way StatisticsPlaylistFragment wraps its own entries.
 */
class PlaylistStreamListItem implements PlaylistLocalItem {
  readonly entry: PlaylistStreamEntry;
  readonly orderingName: string | null;
  readonly displayIndex: number | null = null;
  readonly uid: number;
  readonly thumbnailUrl: string | null;

  /** A key that is this ROW's, so the same stream twice in one playlist stays two rows. */
  readonly rowKey: string;
  private static nextRowKey: number = 0;

  constructor(entry: PlaylistStreamEntry) {
    this.entry = entry;
    PlaylistStreamListItem.nextRowKey = PlaylistStreamListItem.nextRowKey + 1;
    this.rowKey = `stream-${PlaylistStreamListItem.nextRowKey}`;
    this.orderingName = entry.streamEntity.title;
    this.uid = entry.streamId;
    this.thumbnailUrl = entry.streamEntity.thumbnailUrl;
  }

  get localItemType(): LocalItemType {
    return LocalItemType.PLAYLIST_STREAM_ITEM;
  }
}

/* //////////////////////////////////////////////////////////////////////////
// Dialogs (AlertDialogs the fragment builds itself, not planned overlay screens)
////////////////////////////////////////////////////////////////////////// */

/** createRenameDialog(): dialog_edit_text.xml prefilled with the current name. */
@CustomDialog
struct RenameDialog {
  controller?: CustomDialogController;
  @Link playlistName: string;
  onRename: (name: string) => void = (name: string): void => {
    hilog.debug(0x0000, TAG, 'RenameDialog: rename not bound');
  };

  build() {
    // S0152 / S0155: a white AlertDialog, 24dp padding, 20sp title, an underlined edit field
    // and two flat text buttons on the trailing edge.
    Column() {
      Text($r('app.string.rename_playlist'))
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.on_surface'))
        .width('100%')

      // Rule 12: dialog_edit_text.xml declares @+id/dialogEditText, and that is the slug the
      // capture records for this field.
      TextInput({ text: this.playlistName })
        .id('dialogEditText')
        .width('100%')
        .fontSize(16)
        .fontColor($r('app.color.on_surface'))
        .backgroundColor($r('app.color.transparent_background_color'))
        .borderRadius(0)
        .padding({ left: 0, right: 0 })
        .border({ width: { bottom: 1 }, color: $r('app.color.separator') })
        .margin({ top: 16 })
        .onChange((value: string) => {
          this.playlistName = value;
        })

      Row() {
        Button($r('app.string.cancel'))
          .id('rename_cancel')
          .type(ButtonType.Normal)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_surface'))
          .backgroundColor($r('app.color.transparent_background_color'))
          .padding({ left: 8, right: 8, top: 10, bottom: 10 })
          .onClick(() => {
            this.controller?.close();
          })
        Button($r('app.string.rename'))
          .id('rename_confirm')
          .type(ButtonType.Normal)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_surface'))
          .backgroundColor($r('app.color.transparent_background_color'))
          .padding({ left: 8, right: 8, top: 10, bottom: 10 })
          .margin({ left: 8 })
          .onClick(() => {
            this.onRename(this.playlistName);
            this.controller?.close();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .margin({ top: 16 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(24)
    .backgroundColor($r('app.color.dialog_surface'))
  }
}

/** createShareConfirmationDialog(): three buttons, one per PlayListShareMode. */
/**
 * The AlertDialog card's own width, now that customStyle leaves sizing to the builder. Measured
 * on the reference: the card spans x 74..1006 of 1080, i.e. 86% of the screen - at 320vp the
 * third button's label was clipped to "SHARE AS YOUTUBE TEMPORARY ...".
 */
const SHARE_DIALOG_WIDTH: Dimension = '86%';

@CustomDialog
struct ShareConfirmationDialog {
  controller?: CustomDialogController;
  onShare: (mode: PlayListShareMode) => void = (mode: PlayListShareMode): void => {
    hilog.debug(0x0000, TAG, 'ShareConfirmationDialog: share not bound');
  };

  build() {
    // S0151: a white dialog, 24dp padding, 20sp title over three stacked flat buttons that
    // hug the trailing edge.
    Column() {
      Text($r('app.string.share_playlist'))
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.on_surface'))
        .width('100%')
        .margin({ bottom: 8 })

      Button(Localization.buttonLabel('share_playlist_with_titles'))
        .id('share_playlist_with_titles')
        .type(ButtonType.Normal)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.on_surface'))
        .backgroundColor($r('app.color.transparent_background_color'))
        .padding({ left: 8, right: 8, top: 12, bottom: 12 })
        .onClick(() => {
          this.onShare(PlayListShareMode.WITH_TITLES);
          this.controller?.close();
        })

      Button(Localization.buttonLabel('share_playlist_with_list'))
        .id('share_playlist_with_list')
        .type(ButtonType.Normal)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.on_surface'))
        .backgroundColor($r('app.color.transparent_background_color'))
        .padding({ left: 8, right: 8, top: 12, bottom: 12 })
        .onClick(() => {
          this.onShare(PlayListShareMode.JUST_URLS);
          this.controller?.close();
        })

      Button(Localization.buttonLabel('share_playlist_as_youtube_temporary_playlist'))
        .id('share_playlist_as_youtube_temporary_playlist')
        .type(ButtonType.Normal)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.on_surface'))
        .backgroundColor($r('app.color.transparent_background_color'))
        .padding({ left: 8, right: 8, top: 12, bottom: 12 })
        .onClick(() => {
          this.onShare(PlayListShareMode.YOUTUBE_TEMP_PLAYLIST);
          this.controller?.close();
        })
    }
    // The controller sizes the card; the Column fills it.
    .width('100%')
    .alignItems(HorizontalAlign.End)
    .padding(24)
    .backgroundColor($r('app.color.dialog_surface'))
    // Theme.AppCompat.Dialog's window background is a square nine-patch: no corner rounding.
    .borderRadius(0)
  }
}

/** openRemoveWatchedConfirmationDialog(): a programmatic checkbox plus Yes / Cancel. */
@CustomDialog
struct RemoveWatchedDialog {
  controller?: CustomDialogController;
  @Link removePartiallyWatched: boolean;
  onConfirm: () => void = (): void => {
    hilog.debug(0x0000, TAG, 'RemoveWatchedDialog: confirm not bound');
  };

  build() {
    // S0153, same white AlertDialog shell as the rename and share dialogs.
    Column() {
      // setTitle(remove_watched_popup_title) - "Remove watched streams?", not the menu item's
      // own "Remove watched", which is what the port had put here.
      Text($r('app.string.remove_watched_popup_title'))
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.on_surface'))
        .width('100%')

      // setMessage(remove_watched_popup_warning). The string was in the table and nothing
      // pointed at it, so the dialog asked the question with no explanation under it.
      Text($r('app.string.remove_watched_popup_warning'))
        .fontSize(16)
        .fontColor($r('app.color.on_surface_variant'))
        .width('100%')
        .margin({ top: 12 })

      Row() {
        Checkbox()
          // AppCompatCheckBox is a square box, not ArkUI's default circle.
          .shape(CheckBoxShape.ROUNDED_SQUARE)
          .select(this.removePartiallyWatched)
          .selectedColor($r('app.color.primary'))
          .width(20)
          .height(20)
          .onChange((value: boolean) => {
            this.removePartiallyWatched = value;
          })
        Text($r('app.string.remove_watched_popup_partially_watched_streams'))
          .fontSize(16)
          .fontColor($r('app.color.on_surface_variant'))
          .layoutWeight(1)
          .margin({ left: 8 })
      }
      .id('remove_watched_popup_partially_watched_streams')
      .width('100%')
      .margin({ top: 16 })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.removePartiallyWatched = !this.removePartiallyWatched;
      })

      Row() {
        Button(Localization.buttonLabel('cancel'))
          .id('remove_watched_cancel')
          .type(ButtonType.Normal)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_surface'))
          .backgroundColor($r('app.color.transparent_background_color'))
          .padding({ left: 8, right: 8, top: 10, bottom: 10 })
          .onClick(() => {
            this.controller?.close();
          })
        Button(Localization.buttonLabel('yes'))
          .id('yes')
          .type(ButtonType.Normal)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_surface'))
          .backgroundColor($r('app.color.transparent_background_color'))
          .padding({ left: 8, right: 8, top: 10, bottom: 10 })
          .margin({ left: 8 })
          .onClick(() => {
            this.onConfirm();
            this.controller?.close();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .margin({ top: 16 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(24)
    .backgroundColor($r('app.color.dialog_surface'))
  }
}

/** openRemoveDuplicatesDialog(): OK / Cancel. */
@CustomDialog
struct RemoveDuplicatesDialog {
  controller?: CustomDialogController;
  onConfirm: () => void = (): void => {
    hilog.debug(0x0000, TAG, 'RemoveDuplicatesDialog: confirm not bound');
  };

  build() {
    // S0154, same white AlertDialog shell.
    Column() {
      Text($r('app.string.remove_duplicates'))
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.on_surface'))
        .width('100%')

      Row() {
        Button($r('app.string.cancel'))
          .id('remove_duplicates_cancel')
          .type(ButtonType.Normal)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_surface'))
          .backgroundColor($r('app.color.transparent_background_color'))
          .padding({ left: 8, right: 8, top: 10, bottom: 10 })
          .onClick(() => {
            this.controller?.close();
          })
        Button($r('app.string.ok'))
          .id('ok')
          .type(ButtonType.Normal)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_surface'))
          .backgroundColor($r('app.color.transparent_background_color'))
          .padding({ left: 8, right: 8, top: 10, bottom: 10 })
          .margin({ left: 8 })
          .onClick(() => {
            this.onConfirm();
            this.controller?.close();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .margin({ top: 16 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(24)
    .backgroundColor($r('app.color.dialog_surface'))
  }
}

/**
 * The reference's toolbar overflows are flat white rectangles with square corners, anchored at
 * the icon - measured on three of its screens (Play queue, Subscriptions, History), all at
 * x 528..1020 of 1080. ArkUI's default menu is a rounded pale-gradient bubble with a tail.
 */
const SQUARE_MENU_CORNERS: MenuOptions = { borderRadius: 0 };

@Entry
@Component
export struct LocalPlaylistFragmentPage {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  /**
   * TRUE when this screen is a CHILD component inside MainActivityPage - a MainFragment tab, or
   * the shell's own fragment_holder - rather than a page pushed on top of it. The shell docks
   * MiniPlayerBar itself, so a child must not dock a second one beside it; a pushed page covers
   * the shell and has to dock its own.
   *
   * `mainShellOwnsToolbar` cannot answer this: MainActivityPage sets it once in aboutToAppear and
   * never clears it, so it still reads true underneath a pushed page. The embedding hosts pass
   * this one explicitly instead - the same shape as the useAsFrontPage prop the kiosk and feed
   * screens already take, but named for what it gates, since this screen is not always a front
   * page when the shell hosts it.
   */
  @Prop hostedInMainShell: boolean = false;
  /** itemListAdapter's backing list <- playlistManager.getPlaylistStreams(playlistId). */
  @State streamList: LocalItemDataSource = new LocalItemDataSource();
  /** headerBinding.playlistTitleView.setText(title); changePlaylistName() writes it too. */
  @State headerTitle: string = '';
  /** setStreamCountAndOverallDuration(itemListAdapter.getItemsList()). */
  @State headerCountLine: string = '';
  /**
   * getPlaylistObserver()'s `result`: the loaded PlaylistStreamEntry list. showEmptyState() is
   * driven by result.isEmpty(), not by the pixels.
   */
  @State result: PlaylistStreamEntry[] = [];
  /**
   * getPlayQueue() / getPlayQueueStartingAt(item): the adapter's CURRENT list from the chosen
   * index, which is what the player is handed.
   */
  @State playQueue: PlaylistStreamEntry[] = [];

  @State isLoading: boolean = true;
  @State errorInfo: string | null = null;
  /** LocalItemListAdapter.useItemHandle - TRUE here: a local playlist is reorderable. */
  @State useItemHandle: boolean = true;
  /** isRewritingPlaylist: remove-watched and remove-duplicates are inert while one runs. */
  @State isRewritingPlaylist: boolean = false;
  /** An itemHandle is held: the list stops scrolling so the handle's pan gets the move. */
  @State handleHeld: boolean = false;
  /** The overflow (Rename / Remove watched / Remove duplicates). */
  @State overflowOpen: boolean = false;

  /** showInfoItemDialog(entry): the defaults plus SET_AS_PLAYLIST_THUMBNAIL and DELETE. */
  @State menuTitle: string = '';
  @State menuActions: DialogAction[] = [];
  /** The removePartiallyWatched checkbox in the remove-watched dialog. */
  @State removePartiallyWatched: boolean = false;
  /** The name the rename dialog is editing. */
  @State editingName: string = '';

  /** newInstance(playlistId, name). */
  private playlistId: number = -1;
  /** The row a long press opened the info dialog for. */
  private menuTarget: PlaylistStreamListItem | null = null;
  /** The row being dragged by its handle, -1 when none; and the travel already spent on swaps. */
  private draggingIndex: number = -1;
  private dragBaselineY: number = 0;
  private rowStep: number = DEFAULT_ROW_STEP_VP;

  private database: AppDatabase | null = null;
  private playlistManager: LocalPlaylistManager | null = null;
  private historyRecordManager: HistoryRecordManager | null = null;
  private readonly disposables: CompositeDisposable = new CompositeDisposable();
  /**
   * DebounceSaver: a reorder is written as ONE whole-list updateJoin(playlistId, streamIds)
   * after the debounce window, not once per swap.
   */
  private readonly debounceSaver: DebounceSaver =
    new DebounceSaver(SAVE_DEBOUNCE_MILLIS, (): void => {
      this.saveImmediate();
    });

  /** PopupPlayerSurface is mounted only while a popup is being opened or is open. */
  @State popupSurfaceMounted: boolean = false;
  /** The entry the popup was raised for; read once the surface is bound. */
  private popupEntry: PlaylistStreamEntry | null = null;
  private popupSurfaceController: XComponentController = new XComponentController();

  /** StreamDialogDefaultEntry.DOWNLOAD opens DownloadDialog on the stream that was held. */
  @State downloadServiceId: number = -1;
  @State downloadUrl: string = '';
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
      serviceId: this.downloadServiceId,
      url: this.downloadUrl
    })
  });

  private onDownloadDialogVisibility(): void {
    if (this.showDownloadDialog) {
      this.downloadDialog.open();
    } else {
      this.downloadDialog.close();
    }
  }

  /** The playlists PlaylistAppendDialog lists; empty means the creation dialog instead. */
  @State appendList: PlaylistMetadataEntry[] = [];
  /** The stream "Add to playlist" was raised for. */
  private appendTarget: StreamInfoItem | null = null;

  private appendDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    customStyle: true,
    builder: PlaylistAppendDialog({
      playlists: this.appendList,
      onSelected: (playlist: PlaylistMetadataEntry): void => {
        this.appendToChosenPlaylist(playlist);
      },
      onNewPlaylist: (): void => {
        this.appendCreationDialog.open();
      }
    })
  });

  private appendCreationDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    customStyle: true,
    builder: PlaylistCreationDialog({
      name: '',
      onCreate: (name: string): void => {
        this.createPlaylistWithAppendTarget(name);
      }
    })
  });

  private infoItemDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    builder: InfoItemDialog({ title: this.menuTitle, actions: this.menuActions })
  });

  private renameDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    builder: RenameDialog({
      playlistName: $editingName,
      onRename: (name: string): void => {
        this.changePlaylistName(name);
      }
    })
  });

  private shareDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    // customStyle hands the corner treatment to the builder, which draws the square card.
    customStyle: true,
    builder: ShareConfirmationDialog({
      onShare: (mode: PlayListShareMode): void => {
        this.sharePlaylist(mode);
      }
    }),
    // The container's own width, not the builder's: ArkUI's default dialog container caps the
    // card at its grid width (~77% here), so a wider Column inside it simply clips. Measured on
    // the reference, the card spans x 74..1006 of 1080 - 86% - and that is what lets the third
    // button's label read in full. Theme.AppCompat.Dialog's nine-patch has no corner rounding.
    width: SHARE_DIALOG_WIDTH,
    cornerRadius: 0
  });

  private removeWatchedDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    builder: RemoveWatchedDialog({
      removePartiallyWatched: $removePartiallyWatched,
      onConfirm: (): void => {
        this.removeWatchedStreams(this.removePartiallyWatched);
      }
    })
  });

  private removeDuplicatesDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    builder: RemoveDuplicatesDialog({
      onConfirm: (): void => {
        this.removeDuplicatesInPlaylist();
      }
    })
  });

  /* //////////////////////////////////////////////////////////////////////////
  // Lifecycle
  ////////////////////////////////////////////////////////////////////////// */

  aboutToAppear(): void {
    this.readArguments();
    this.startLoading();
  }

  /** onDestroy(): flush a pending reorder, then dispose everything (Rule 8). */
  aboutToDisappear(): void {
    this.saveImmediate();
    this.debounceSaver.dispose();
    this.disposables.dispose();
  }

  private readArguments(): void {
    const params: Record<string, Object> | undefined =
      router.getParams() as Record<string, Object> | undefined;
    if (params === undefined || params === null) {
      return;
    }
    const id: Object | undefined = params['playlistId'];
    if (id !== undefined && id !== null) {
      this.playlistId = Number(id.toString());
    }
    const name: Object | undefined = params['name'];
    if (name !== undefined && name !== null) {
      this.headerTitle = name.toString();
      this.editingName = this.headerTitle;
    }
  }

  private async ensureServices(): Promise<LocalPlaylistManager | null> {
    const existing: LocalPlaylistManager | null = this.playlistManager;
    if (existing !== null) {
      return existing;
    }
    try {
      const context: common.Context = getContext(this) as common.Context;
      const db: AppDatabase = await AppDatabase.getInstance(context);
      this.database = db;
      this.historyRecordManager = new HistoryRecordManager(db);
      const manager: LocalPlaylistManager = new LocalPlaylistManager(db);
      this.playlistManager = manager;
      return manager;
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.errorInfo = failure.message;
      return null;
    }
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Load
  ////////////////////////////////////////////////////////////////////////// */

  /** getPlaylistObserver(): the playlist's ordered streams, plus the header numbers. */
  private async startLoading(): Promise<void> {
    this.isLoading = true;
    this.errorInfo = null;
    const manager: LocalPlaylistManager | null = await this.ensureServices();
    if (manager === null || this.playlistId < 0) {
      this.isLoading = false;
      return;
    }
    // debounceSaver.getIsModified(): a database emission must not overwrite a reorder in flight.
    if (this.debounceSaver.getIsModified()) {
      this.isLoading = false;
      return;
    }
    try {
      const entries: PlaylistStreamEntry[] = await manager.getPlaylistStreams(this.playlistId);
      this.applyEntries(entries);
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.errorInfo = failure.message;
    } finally {
      this.isLoading = false;
    }
  }

  private applyEntries(entries: PlaylistStreamEntry[]): void {
    const rows: PlaylistLocalItem[] = [];
    for (const entry of entries) {
      rows.push(new PlaylistStreamListItem(entry));
    }
    this.streamList.setItems(rows);
    this.result = entries;
    this.setStreamCountAndOverallDuration(entries);
  }

  /** Localization.concatenateStrings(localizeStreamCount(n), getDurationString(total)). */
  private setStreamCountAndOverallDuration(entries: PlaylistStreamEntry[]): void {
    let total: number = 0;
    for (const entry of entries) {
      total = total + entry.streamEntity.duration;
    }
    // setStreamCountAndOverallDuration(): concatenateStrings(localizeStreamCount(count),
    // getDurationString(overallSeconds)) - "2 videos • 1:23:45". Concatenating the two raw numbers
    // printed "2 - -2", because an entry whose duration is unknown carries -1 and they summed.
    this.headerCountLine = Localization.concatenateStrings([
      Localization.localizeStreamCount(entries.length),
      Localization.getDurationString(total)
    ]);
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Reorder (DebounceSaver -> updateJoin)
  ////////////////////////////////////////////////////////////////////////// */

  /**
   * itemHandle ACTION_DOWN -> itemTouchHelper.startDrag(viewHolder). Found by the row's own key:
   * the same stream may sit in the playlist twice. The pan reports its travel cumulatively from
   * the pickup, so the baseline starts at zero.
   */
  private onRowDragStart(row: PlaylistLocalItem): void {
    if (this.isRewritingPlaylist || !(row instanceof PlaylistStreamListItem)) {
      return;
    }
    const key: string = (row as PlaylistStreamListItem).rowKey;
    this.draggingIndex = this.streamList.getItemsList().findIndex(
      (candidate: PlaylistLocalItem): boolean => candidate instanceof PlaylistStreamListItem
        && (candidate as PlaylistStreamListItem).rowKey === key);
    this.dragBaselineY = 0;
  }

  /**
   * onMove(source, target): each full row of travel swaps the row with its neighbour
   * (swapItems) and flags the saver, as the source callback does.
   */
  private onRowDragUpdate(offsetY: number): void {
    if (this.draggingIndex < 0) {
      return;
    }
    const delta: number = offsetY - this.dragBaselineY;
    if (delta >= this.rowStep) {
      this.moveRow(this.draggingIndex + 1);
      this.dragBaselineY = this.dragBaselineY + this.rowStep;
    } else if (delta <= -this.rowStep) {
      this.moveRow(this.draggingIndex - 1);
      this.dragBaselineY = this.dragBaselineY - this.rowStep;
    }
  }

  private moveRow(targetIndex: number): void {
    if (!this.streamList.swapItems(this.draggingIndex, targetIndex)) {
      return;
    }
    this.draggingIndex = targetIndex;
    this.result = this.currentEntries();
    this.debounceSaver.setHasChangesToSave();
  }

  /** clearView(): the drop writes the new order at once (saveImmediate). */
  private onRowDragEnd(): void {
    if (this.draggingIndex < 0) {
      return;
    }
    this.draggingIndex = -1;
    this.saveImmediate();
  }

  /** clearView() -> saveImmediate(): playlistManager.updateJoin(playlistId, streamIds). */
  private async saveImmediate(): Promise<void> {
    const manager: LocalPlaylistManager | null = this.playlistManager;
    if (manager === null || this.playlistId < 0 || !this.debounceSaver.getIsModified()) {
      return;
    }
    const streamIds: number[] = [];
    for (const row of this.streamList.getItemsList()) {
      streamIds.push(row.uid);
    }
    try {
      await manager.updateJoin(this.playlistId, streamIds);
      this.debounceSaver.setNoChangesToSave();
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      hilog.warn(0x0000, TAG, 'updateJoin: %{public}s', failure.message);
    }
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Menu actions
  ////////////////////////////////////////////////////////////////////////// */

  /** createRenameDialog(), reached from the overflow AND from the title itself. */
  private createRenameDialog(): void {
    this.overflowOpen = false;
    this.editingName = this.headerTitle;
    this.renameDialog.open();
  }

  private async changePlaylistName(name: string): Promise<void> {
    const manager: LocalPlaylistManager | null = this.playlistManager;
    if (manager === null || this.playlistId < 0 || name.length === 0) {
      return;
    }
    try {
      await manager.renamePlaylist(this.playlistId, name);
      this.headerTitle = name;
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      hilog.warn(0x0000, TAG, 'renamePlaylist: %{public}s', failure.message);
    }
  }

  private createShareConfirmationDialog(): void {
    this.overflowOpen = false;
    this.shareDialog.open();
  }

  /** sharePlaylist(shareMode): ExportPlaylist.export() then the system share panel. */
  private sharePlaylist(mode: PlayListShareMode): void {
    const entries: PlaylistStreamEntry[] = this.currentEntries();
    const urlsText: string = ShareUtils.exportPlaylist(mode, entries);
    // WITH_TITLES wraps the list in share_playlist_content_details: the playlist name, then it.
    const text: string = mode === PlayListShareMode.WITH_TITLES
      ? Localization.getStringArgs('share_playlist_content_details', [this.headerTitle, urlsText])
      : urlsText;
    const share: ShareUtils = ServiceLocator.get().share;
    share.shareText(this.headerTitle, text);
  }

  private currentEntries(): PlaylistStreamEntry[] {
    const entries: PlaylistStreamEntry[] = [];
    for (const row of this.streamList.getItemsList()) {
      if (row instanceof PlaylistStreamListItem) {
        entries.push((row as PlaylistStreamListItem).entry);
      }
    }
    return entries;
  }

  /** openRemoveWatchedConfirmationDialog(), a no-op while a rewrite is running. */
  private openRemoveWatchedConfirmationDialog(): void {
    this.overflowOpen = false;
    if (this.isRewritingPlaylist) {
      return;
    }
    this.removeWatchedDialog.open();
  }

  /**
   * removeWatchedStreams(removePartiallyWatched): the source zips the playlist with the watch
   * history and each stream's playback state; here the state lookup is one batch read.
   */
  private async removeWatchedStreams(removePartially: boolean): Promise<void> {
    const history: HistoryRecordManager | null = this.historyRecordManager;
    if (history === null || this.isRewritingPlaylist) {
      return;
    }
    this.isRewritingPlaylist = true;
    try {
      // The ENTRIES, not the list rows: the batch read recognises PlaylistStreamEntry, and the
      // row wrappers made it answer null for every stream, so nothing was ever removed.
      const entries: PlaylistStreamEntry[] = this.currentEntries();
      const states: Array<StreamStateEntity | null> =
        await history.loadLocalStreamStateBatch(entries);
      // getStreamHistorySortedById(): only a stream that is in the watch history counts.
      const watched: Set<number> = new Set<number>();
      for (const row of await history.getStreamHistorySortedById()) {
        watched.add(row.streamId);
      }
      const manager: LocalPlaylistManager | null = this.playlistManager;
      const thumbnailPermanent: boolean = manager === null
        ? true : await manager.getIsPlaylistThumbnailPermanent(this.playlistId);
      const thumbnailId: number = manager === null
        ? -1 : await manager.getPlaylistThumbnailStreamId(this.playlistId);
      let thumbnailRemoved: boolean = false;
      const kept: PlaylistStreamEntry[] = [];
      for (let i = 0; i < entries.length; i++) {
        const entry: PlaylistStreamEntry = entries[i];
        const state: StreamStateEntity | null = states[i];
        if (!watched.has(entry.streamId) || state === null
          || (!removePartially && !state.isFinished(entry.streamEntity.duration))) {
          kept.push(entry);
        } else if (!thumbnailPermanent && entry.streamEntity.uid === thumbnailId) {
          thumbnailRemoved = true;
        }
      }
      this.applyEntries(kept);
      this.debounceSaver.setHasChangesToSave();
      await this.saveImmediate();
      if (thumbnailRemoved) {
        await this.updateThumbnailUrl();
      }
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      hilog.warn(0x0000, TAG, 'removeWatchedStreams: %{public}s', failure.message);
    } finally {
      this.isRewritingPlaylist = false;
    }
  }

  private openRemoveDuplicatesDialog(): void {
    this.overflowOpen = false;
    if (this.isRewritingPlaylist) {
      return;
    }
    this.removeDuplicatesDialog.open();
  }

  /** removeDuplicatesInPlaylist(): getDistinctPlaylistStreams(playlistId), then updateJoin. */
  private async removeDuplicatesInPlaylist(): Promise<void> {
    const manager: LocalPlaylistManager | null = this.playlistManager;
    if (manager === null || this.playlistId < 0 || this.isRewritingPlaylist) {
      return;
    }
    this.isRewritingPlaylist = true;
    try {
      const distinct: PlaylistStreamEntry[] =
        await manager.getDistinctPlaylistStreams(this.playlistId);
      this.applyEntries(distinct);
      this.debounceSaver.setHasChangesToSave();
      await this.saveImmediate();
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      hilog.warn(0x0000, TAG, 'removeDuplicates: %{public}s', failure.message);
    } finally {
      this.isRewritingPlaylist = false;
    }
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Rows
  ////////////////////////////////////////////////////////////////////////// */

  /** OnClickGesture.selected -> openVideoDetailFragment for that PlaylistStreamEntry. */
  private onItemSelected(item: PlaylistLocalItem): void {
    if (!(item instanceof PlaylistStreamListItem)) {
      return;
    }
    const entry: PlaylistStreamEntry = (item as PlaylistStreamListItem).entry;
    router.pushUrl({
      url: 'pages/VideoDetailFragmentPage',
      params: new ItemParams(entry.streamEntity.serviceId, entry.streamEntity.url,
        entry.streamEntity.title)
    });
  }

  /** OnClickGesture.held -> showInfoItemDialog(entry). */
  private onItemHeld(item: PlaylistLocalItem): void {
    if (!(item instanceof PlaylistStreamListItem)) {
      return;
    }
    const row: PlaylistStreamListItem = item as PlaylistStreamListItem;
    const stream: StreamInfoItem = row.entry.toStreamInfoItem();
    this.menuTarget = row;
    this.menuTitle = row.entry.streamEntity.title;

    // InfoItemDialog.Builder owns the entry list and its order; this screen only says what each
    // entry does, plus the two that belong to it alone. Measured on the reference, a local
    // playlist row: Background / Popup / SET AS PLAYLIST THUMBNAIL / DELETE / Download / Add to
    // playlist / Share / Open in browser / Mark as watched / Show channel details - both extras
    // sit straight after the start-here block, thumbnail first.
    const target: StreamMenuTarget = new StreamMenuTarget();
    target.serviceId = row.entry.streamEntity.serviceId;
    target.url = row.entry.streamEntity.url;
    target.title = row.entry.streamEntity.title;
    target.uploader = row.entry.streamEntity.uploader;
    const uploaderUrl: string | null = row.entry.streamEntity.uploaderUrl;
    target.uploaderUrl = uploaderUrl === null ? '' : uploaderUrl;
    target.audioOnly = isAudioStream(row.entry.streamEntity.streamType);
    target.live = isLiveStream(row.entry.streamEntity.streamType);

    const handlers: StreamMenuHandlers = new StreamMenuHandlers();
    handlers.onEnqueue = (): void => {
      promptAction.showToast({ message: $r('app.string.enqueued'), duration: 2000 });
      enqueueStream(stream);
    };
    handlers.onEnqueueNext = (): void => {
      // NavigationHelper.enqueueNextOnPlayer(): straight after the playing stream.
      enqueueNextStream(stream);
    };
    handlers.onBackground = (): void => {
      this.startHereOnBackground(row);
    };
    handlers.onPopup = (): void => {
      // This screen owns a popup surface (T-0060), so the row popup entry opens the window in
      // place the same way its header control does.
      if (this.popupSurfaceMounted) {
        return;
      }
      promptAction.showToast({ message: $r('app.string.popup_playing_toast'), duration: 2000 });
      this.popupEntry = row.entry;
      this.popupSurfaceMounted = true;
    };
    handlers.onDownload = (): void => {
      this.downloadServiceId = target.serviceId;
      this.downloadUrl = target.url;
      this.showDownloadDialog = true;
    };
    handlers.onAddToPlaylist = (): void => {
      this.openAppendPicker(stream);
    };
    handlers.onMarkAsWatched = (): void => {
      markStreamAsWatched(getContext(this) as common.Context, stream);
    };
    handlers.onShowChannelDetails = (): void => {
      router.pushUrl({
        url: 'pages/ChannelFragmentPage',
        params: new ItemParams(target.serviceId, target.uploaderUrl, target.uploader)
      });
    };
    handlers.afterStartHere = [
      new DialogAction($r('app.string.set_as_playlist_thumbnail'), 'set_as_playlist_thumbnail',
        (): void => {
          this.setAsPlaylistThumbnail(row);
        }),
      new DialogAction($r('app.string.delete'), 'delete', (): void => {
        this.deleteItem(row);
      })
    ];

    this.menuActions = buildStreamMenuActions(target, handlers);
    this.infoItemDialog.open();
  }

  /** changeThumbnailStreamId(uid, true) - the choice becomes permanent. */
  private async setAsPlaylistThumbnail(row: PlaylistStreamListItem): Promise<void> {
    await this.changeThumbnailStreamId(row.uid, true);
  }

  /**
   * changeThumbnailStreamId(): an automatic change never overrides a permanent choice, and every
   * change that lands says so (playlist_thumbnail_change_success).
   */
  private async changeThumbnailStreamId(thumbnailStreamId: number,
    isPermanent: boolean): Promise<void> {
    const manager: LocalPlaylistManager | null = this.playlistManager;
    if (manager === null || this.playlistId < 0) {
      return;
    }
    try {
      if (!isPermanent && await manager.getIsPlaylistThumbnailPermanent(this.playlistId)) {
        return;
      }
      await manager.changePlaylistThumbnail(this.playlistId, thumbnailStreamId, isPermanent);
      promptAction.showToast({ message: $r('app.string.playlist_thumbnail_change_success'),
        duration: 2000 });
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      hilog.warn(0x0000, TAG, 'changePlaylistThumbnail: %{public}s', failure.message);
    }
  }

  /**
   * updateThumbnailUrl(): a playlist whose thumbnail stream left it takes its (new) first stream,
   * or the default when it is empty - unless the thumbnail was chosen by hand.
   */
  private async updateThumbnailUrl(): Promise<void> {
    const manager: LocalPlaylistManager | null = this.playlistManager;
    if (manager === null || await manager.getIsPlaylistThumbnailPermanent(this.playlistId)) {
      return;
    }
    const entries: PlaylistStreamEntry[] = this.currentEntries();
    await this.changeThumbnailStreamId(entries.length > 0
      ? entries[0].streamEntity.uid : PlaylistEntity.DEFAULT_THUMBNAIL_ID, false);
  }

  /** deleteItem(item): drop the row, refresh a thumbnail it was, then saveImmediate(). */
  private async deleteItem(row: PlaylistStreamListItem): Promise<void> {
    if (!this.streamList.removeItem(row)) {
      return;
    }
    const manager: LocalPlaylistManager | null = this.playlistManager;
    if (manager !== null
      && await manager.getPlaylistThumbnailStreamId(this.playlistId) === row.entry.streamId) {
      await this.updateThumbnailUrl();
    }
    this.result = this.currentEntries();
    this.setStreamCountAndOverallDuration(this.result);
    this.debounceSaver.setHasChangesToSave();
    this.saveImmediate();
  }

  /** START_HERE_ON_BACKGROUND, rebound: the queue starts AT this item. */
  private startHereOnBackground(row: PlaylistStreamListItem): void {
    this.openPlayer(this.streamList.getItemsList().indexOf(row), 'AUDIO');
  }

  /**
   * getPlayQueue() / getPlayQueueStartingAt(item): the player takes the adapter's CURRENT list,
   * from the given index.
   */
  private openPlayer(startIndex: number, playerType: string): void {
    const entries: PlaylistStreamEntry[] = this.currentEntries();
    if (entries.length === 0) {
      return;
    }
    const index: number = startIndex >= 0 && startIndex < entries.length ? startIndex : 0;
    // SinglePlayQueue(streamInfoItems, index): the queue starts AT the chosen item.
    this.playQueue = entries.slice(index);
    const entry: PlaylistStreamEntry = entries[index];
    // getPlayQueue(index): the WHOLE playlist, not just the entry that starts. Handing over one
    // item is why nothing but the playing stream was ever in the queue - the same defect
    // StatisticsPlaylistFragmentPage fixed with publishPlayQueue(), which this screen never got.
    // Without it, shuffle and repeat-all have a one-item queue to work on (TC-PLAYER-193/194).
    this.publishPlayQueue(entries, index);
    if (playerType === 'POPUP') {
      // playOnPopupPlayer() opens the float window OVER the screen the user is on - the playlist
      // stays visible behind it. The port used to push VideoDetailFragmentPage here, because
      // PiPWindow renders from an XComponent surface (PiPConfiguration.componentController) and
      // that page owned the only one; the user landed on the standard player, which is what
      // TC-LIBRARY-252 reports. PopupPlayerSurface is that surface, mounted here, so the popup
      // opens in place. The mini player remains the documented fallback when PiP is unavailable.
      // Same guard as the row menu's onPopup and as Most Played's header: a second tap while
      // the first popup is still opening must do nothing, or the surface is left mounted with
      // no window and the control stops responding (TC-LIBRARY-457).
      if (this.popupSurfaceMounted) {
        return;
      }
      this.popupEntry = entry;
      this.popupSurfaceMounted = true;
      return;
    }
    if (playerType !== 'MAIN') {
      // playOnBackgroundPlayer never navigates: it starts the shared player in place and the
      // playlist stays on screen.
      this.startPlayer(entry, true);
      return;
    }
    router.pushUrl({
      url: 'pages/VideoDetailFragmentPage',
      params: new ItemParams(entry.streamEntity.serviceId, entry.streamEntity.url,
        entry.streamEntity.title)
    });
  }

  /** The same in-place start PlaylistFragmentPage and the history screen use. */
  private async startPlayer(entry: PlaylistStreamEntry, audioOnly: boolean): Promise<void> {
    try {
      const info: StreamInfo = await ServiceLocator.get().backgroundWork.runWithBackgroundTask(
        BackgroundWorkMode.DATA_TRANSFER,
        (): Promise<StreamInfo> => ExtractorHelper.getStreamInfo(
          entry.streamEntity.serviceId, entry.streamEntity.url, false));
      await PlayerService.getInstance().prepare(info, audioOnly,
      audioOnly ? 0 : PlayerPrefs.defaultPlaybackHeight());
      await MediaSessionService.getInstance()
        .startDetached(getContext(this) as common.UIAbilityContext, info);
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      promptAction.showToast({ message: failure.message, duration: 2000 });
    }
  }

  /* //////////////////////////////////////////////////////////////////////////
  // playlist_control (PlayButtonHelper.initPlaylistControlClickListener)
  ////////////////////////////////////////////////////////////////////////// */

  /**
   * showHoldToAppendToastIfNeeded(): every one of the three buttons ends here, and the
   * show_hold_to_append preference defaults to TRUE, so a tap is always visible even when the
   * play path itself does nothing.
   */
  private showHoldToAppendTipIfNeeded(delayMillis: number = 0): void {
    // promptAction.showToast REPLACES the visible toast instead of queueing behind it the way
    // Android's Toast does, so raising the tip at once wiped the action's own message. Measured
    // on the reference (Popup on a bookmarked playlist): "Playing in popup mode" is up for about
    // 1.4 s and "Hold to enqueue" follows at ~2.1 s - one Toast.LENGTH_SHORT apart. Delaying the
    // tip by that much reproduces the pair. MAIN toasts nothing of its own, so its tip still
    // fires at once.
    if (!AppPreferences.instance().getBooleanSync(show_hold_to_append_key, true)) {
      return;
    }
    if (delayMillis <= 0) {
      promptAction.showToast({ message: $r('app.string.hold_to_append'), duration: 2000 });
      return;
    }
    setTimeout((): void => {
      promptAction.showToast({ message: $r('app.string.hold_to_append'), duration: 2000 });
    }, delayMillis);
  }

  /**
   * playOnMainPlayer(activity, getPlayQueue()): the ONLY empty-queue guard in the source -
   * `playQueue.getItem()` is null, so nothing opens. openPlayer() carries that guard, and the
   * hold-to-append tip is then the whole visible effect, exactly as in the source.
   */
  private playAll(): void {
    this.openPlayer(0, 'MAIN');
    this.showHoldToAppendTipIfNeeded();
  }

  /**
   * PlayButtonHelper's long press: NavigationHelper.enqueueOnPlayer() APPENDS the playlist to the
   * running player's queue with an "Enqueued" toast. With nothing playing there is no queue to
   * join, and the playlist starts in that player instead.
   */
  private enqueueAll(playerType: string): void {
    const entries: PlaylistStreamEntry[] = this.currentEntries();
    if (entries.length === 0) {
      return;
    }
    const items: PlayQueueItem[] = entries.map((entry: PlaylistStreamEntry): PlayQueueItem =>
      PlayQueueItem.fromStreamInfoItem(entry.toStreamInfoItem()));
    if (!enqueueAllOnPlayer(items)) {
      this.openPlayer(0, playerType);
    }
  }

  /** The same hand-over StatisticsPlaylistFragmentPage does: the whole list, starting at index. */
  private publishPlayQueue(entries: PlaylistStreamEntry[], index: number): void {
    const items: PlayQueueItem[] = [];
    for (const entry of entries) {
      items.push(PlayQueueItem.fromStreamInfoItem(entry.toStreamInfoItem()));
    }
    setCurrentPlayQueue(new SimplePlayQueue(index, items));
  }

  /** playOnBackgroundPlayer(): toasts BEFORE the audio player starts, empty queue or not. */
  private playOnBackground(): void {
    promptAction.showToast({
      message: $r('app.string.background_player_playing_toast'),
      duration: 2000
    });
    this.openPlayer(0, 'AUDIO');
  }

  /**
   * playOnPopupPlayer(): the same unconditional toast, then openPlayer('POPUP') hands the stream
   * to VideoDetailFragmentPage with popup:true, whose openPopupPlayer() is the ONE popup
   * implementation - PiP, with the docked mini player as its fallback (see openPlayer()).
   */
  private playOnPopup(): void {
    promptAction.showToast({
      message: $r('app.string.popup_playing_toast'),
      duration: 2000
    });
    this.openPlayer(0, 'POPUP');
    // The reference raises the tip after this button too; the popup now stays on this screen, so
    // the tip lands where the reference shows it instead of on a page the user never asked for.
    this.showHoldToAppendTipIfNeeded(HOLD_TO_APPEND_TIP_DELAY);
  }

  /**
   * The surface is bound: prepare the stream on it and hand it to PiP. enterPip() reports which
   * of the two it managed - the real float window, or the in-app mini player - and the popup
   * entry point must visibly do one of them, never nothing.
   */
  private async onPopupSurfaceReady(): Promise<void> {
    const entry: PlaylistStreamEntry | null = this.popupEntry;
    if (entry === null) {
      return;
    }
    this.popupEntry = null;
    await openPopupOnSurface(getContext(this) as common.UIAbilityContext,
      entry.streamEntity.serviceId, entry.streamEntity.url, this.popupSurfaceController,
      (): void => {
        this.popupSurfaceMounted = false;
      });
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Builders
  ////////////////////////////////////////////////////////////////////////// */

  /** getListHeaderSupplier(): local_playlist_header.xml + the included playlist_control.xml. */
  @Builder
  listHeader() {
    HeaderFooterHolder() {
      Column() {
        // playlist_title_view IS the rename affordance - there is no separate edit button.
        // 16sp, 12dp horizontal / 12dp top / 6dp bottom padding, at most two lines.
        Text(this.headerTitle)
          .id('playlist_title_view')
          .width('100%')
          .fontSize(16)
          .fontColor($r('app.color.on_surface'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({ left: 12, right: 12, top: 12, bottom: 6 })
          .onClick(() => {
            this.createRenameDialog();
          })

        Text(this.headerCountLine)
          .id('playlist_stream_count')
          .width('100%')
          .fontSize(12)
          .fontColor($r('app.color.on_surface_variant'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({ left: 12, right: 12 })

        // playlist_control.xml: three weight-1 cells 50dp tall, each a drawableStart glyph and
        // a 12sp ?attr/colorAccent label with 4dp between them, split by 1dp accent rules that
        // are inset 10dp top and bottom.
        Row() {
          Row() {
            Image($r('app.media.ic_headset'))
              .width(24)
              .height(24)
              .objectFit(ImageFit.Contain)
              .fillColor($r('app.color.accent'))
            Text($r('app.string.controls_background_title'))
              .fontSize(12)
              .fontColor($r('app.color.accent'))
              .maxLines(1)
              .margin({ left: 4 })
          }
          .id('playlist_ctrl_play_bg_button')
          .layoutWeight(1)
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.playOnBackground();
          })
          .gesture(LongPressGesture().onAction(() => {
            // enqueueOnPlayer(activity, getPlayQueue(), PlayerType.AUDIO)
            this.enqueueAll('AUDIO');
          }))

          Divider()
            .vertical(true)
            .strokeWidth(1)
            .color($r('app.color.accent'))
            .height('100%')
            .margin({ top: 10, bottom: 10 })

          Row() {
            Image($r('app.media.ic_playlist_play'))
              .width(24)
              .height(24)
              .objectFit(ImageFit.Contain)
              .fillColor($r('app.color.accent'))
            Text($r('app.string.play_all'))
              .fontSize(12)
              .fontColor($r('app.color.accent'))
              .maxLines(1)
              .margin({ left: 4 })
          }
          .id('playlist_ctrl_play_all_button')
          .layoutWeight(1)
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.playAll();
          })
          .gesture(LongPressGesture().onAction(() => {
            // enqueueOnPlayer(activity, getPlayQueue(), PlayerType.MAIN)
            this.enqueueAll('MAIN');
          }))

          Divider()
            .vertical(true)
            .strokeWidth(1)
            .color($r('app.color.accent'))
            .height('100%')
            .margin({ top: 10, bottom: 10 })

          Row() {
            Image($r('app.media.ic_picture_in_picture'))
              .width(24)
              .height(24)
              .objectFit(ImageFit.Contain)
              .fillColor($r('app.color.accent'))
            Text($r('app.string.controls_popup_title'))
              .fontSize(12)
              .fontColor($r('app.color.accent'))
              .maxLines(1)
              .margin({ left: 4 })
          }
          .id('playlist_ctrl_play_popup_button')
          .layoutWeight(1)
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.playOnPopup();
          })
          .gesture(LongPressGesture().onAction(() => {
            // enqueueOnPlayer(activity, getPlayQueue(), PlayerType.POPUP)
            this.enqueueAll('POPUP');
          }))
        }
        .id('playlist_control')
        .width('100%')
        .height(50)
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      // local_playlist_header root: android:background="?attr/contrast_background_color".
      .backgroundColor($r('app.color.contrast_background'))
    }
  }

  /** LocalItemHolder owns the row root (itemRoot) and its click / long-click. */
  @Builder
  itemRow(item: PlaylistLocalItem) {
    LocalItemHolder({
      item: item,
      onSelected: (selected: PlaylistLocalItem): void => {
        this.onItemSelected(selected);
      },
      onHeld: (held: PlaylistLocalItem): void => {
        this.onItemHeld(held);
      },
      // An arrow keeps `this` on this page; `this.itemBody` would re-bind it to the holder.
      body: (row: PlaylistLocalItem): void => {
        this.itemBody(row);
      }
    })
  }

  /** LocalItemListAdapter.getItemViewType() + onCreateViewHolder(), in its branch order. */
  @Builder
  itemBody(item: PlaylistLocalItem) {
    if (item.localItemType === LocalItemType.PLAYLIST_STREAM_ITEM) {
      LocalPlaylistStreamItemHolder({
        thumbnailUrl: item.thumbnailUrl,
        title: item.orderingName,
        uploader: this.rowUploader(item),
        duration: this.rowDuration(item),
        showItemHandle: this.useItemHandle,
        onHandleDragStart: (): void => {
          this.onRowDragStart(item);
        },
        onHandleDragUpdate: (offsetY: number): void => {
          this.onRowDragUpdate(offsetY);
        },
        onHandleDragEnd: (): void => {
          this.onRowDragEnd();
        },
        onHandleTouch: (held: boolean): void => {
          this.handleHeld = held;
        }
      })
    } else if (item.localItemType === LocalItemType.STATISTIC_STREAM_ITEM) {
      LocalStatisticStreamItemHolder({
        thumbnailUrl: item.thumbnailUrl,
        title: item.orderingName
      })
    } else if (item.localItemType === LocalItemType.PLAYLIST_LOCAL_ITEM) {
      if (this.useItemHandle) {
        LocalBookmarkPlaylistItemHolder({
          item: item,
          body: (row: PlaylistLocalItem): void => {
            this.playlistBody(row);
          }
        })
      } else {
        LocalPlaylistItemHolder({
          item: item,
          body: (row: PlaylistLocalItem): void => {
            this.playlistBody(row);
          }
        })
      }
    } else if (item.localItemType === LocalItemType.PLAYLIST_REMOTE_ITEM) {
      if (this.useItemHandle) {
        RemoteBookmarkPlaylistItemHolder({
          item: item,
          body: (row: PlaylistLocalItem): void => {
            this.playlistBody(row);
          }
        })
      } else {
        RemotePlaylistItemHolder({
          item: item,
          body: (row: PlaylistLocalItem): void => {
            this.playlistBody(row);
          }
        })
      }
    } else {
      FallbackViewHolder()
    }
  }

  /** PlaylistItemHolder: the views every playlist row shares. */
  @Builder
  playlistBody(item: PlaylistLocalItem) {
    PlaylistItemHolder({
      thumbnailUrl: item.thumbnailUrl,
      title: item.orderingName,
      showUploader: item.localItemType === LocalItemType.PLAYLIST_REMOTE_ITEM
    })
  }

  private rowUploader(item: PlaylistLocalItem): string | null {
    return item instanceof PlaylistStreamListItem
      ? (item as PlaylistStreamListItem).entry.streamEntity.uploader : null;
  }

  /** Localization.getDurationString(streamEntity.duration) - S4 formats it. */
  private rowDuration(item: PlaylistLocalItem): string | null {
    if (!(item instanceof PlaylistStreamListItem)) {
      return null;
    }
    const duration: number = (item as PlaylistStreamListItem).entry.streamEntity.duration;
    return duration < 0 ? null : Localization.getDurationString(duration);
  }

  /** menu_local_playlist.xml: Share in the bar, the other three in the overflow. */
  @Builder
  overflowMenu() {
    Menu() {
      MenuItem({ content: $r('app.string.rename_playlist') })
        .id('menu_item_rename_playlist')
        .onClick(() => {
          this.createRenameDialog();
        })
      MenuItem({ content: $r('app.string.remove_watched') })
        .id('menu_item_remove_watched')
        .onClick(() => {
          this.openRemoveWatchedConfirmationDialog();
        })
      MenuItem({ content: $r('app.string.remove_duplicates') })
        .id('menu_item_remove_duplicates')
        .onClick(() => {
          this.openRemoveDuplicatesDialog();
        })
    }
  }

  /**
   * StreamDialogDefaultEntry.APPEND_PLAYLIST -> PlaylistAppendDialog over the local playlists,
   * and PlaylistDialog.createCorrespondingDialog rule: with no playlists at all it goes straight
   * to creation instead of showing an empty picker.
   */
  private async openAppendPicker(stream: StreamInfoItem): Promise<void> {
    const manager: LocalPlaylistManager | null = this.playlistManager;
    if (manager === null) {
      return;
    }
    this.appendTarget = stream;
    try {
      const playlists: PlaylistMetadataEntry[] =
        await manager.getPlaylistDuplicates(stream.getUrl());
      this.appendList = playlists;
      if (playlists.length === 0) {
        this.appendCreationDialog.open();
      } else {
        this.appendDialog.open();
      }
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      promptAction.showToast({ message: failure.message, duration: 2000 });
    }
  }

  /** PlaylistAppendDialog row tap: append the held stream to the chosen playlist. */
  private async appendToChosenPlaylist(playlist: PlaylistLocalItem): Promise<void> {
    const manager: LocalPlaylistManager | null = this.playlistManager;
    const item: StreamInfoItem | null = this.appendTarget;
    this.appendList = [];
    this.infoItemDialog.close();
    if (manager === null || item === null) {
      return;
    }
    try {
      await manager.appendToPlaylist(playlist.uid, [StreamEntity.fromInfoItem(item)]);
      promptAction.showToast({ message: playlistAppendToast(playlist),
        duration: 2000 });
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      promptAction.showToast({ message: failure.message, duration: 2000 });
    }
  }

  /** PlaylistCreationDialog confirm: a new playlist carrying the stream that was held. */
  private async createPlaylistWithAppendTarget(name: string): Promise<void> {
    const manager: LocalPlaylistManager | null = this.playlistManager;
    const item: StreamInfoItem | null = this.appendTarget;
    this.infoItemDialog.close();
    if (manager === null || item === null || name.length === 0) {
      return;
    }
    try {
      await manager.createPlaylist(name, [StreamEntity.fromInfoItem(item)]);
      // PlaylistCreationDialog: Toast @string/playlist_creation_success.
      promptAction.showToast({ message: $r('app.string.playlist_creation_success'),
        duration: 2000 });
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      promptAction.showToast({ message: failure.message, duration: 2000 });
    }
  }


  build() {
    Column() {
      // toolbar / toolbar_layout - the activity bar this fragment publishes its title into.
      Row() {
        // setDisplayHomeAsUpEnabled: this screen is PUSHED, so nothing else draws its Up arrow -
        // the 72dp inset below reserved the space and left it empty. A 56dp box with the 16dp
        // icon padding is the same affordance the import screen draws.
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

        // Widget.AppCompat.Toolbar.Title: 20sp medium on ?attr/colorPrimary, inset 16dp from the
        // Up arrow that now precedes it.
        Text(this.headerTitle)
          .id('toolbar_title')
          .margin({ left: 16 })
          .layoutWeight(1)
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        // 48dp action items, ToolbarTheme tints them ?attr/actionColor = white.
        Image($r('app.media.ic_share'))
          .id('menu_item_share_playlist')
          .accessibilityText($r('app.string.share'))
          .width(48)
          .height(48)
          .padding(12)
          .objectFit(ImageFit.Contain)
          .fillColor($r('app.color.on_primary'))
          .onClick(() => {
            this.createShareConfirmationDialog();
          })

        Image($r('app.media.ic_more_vert'))
          .id('toolbar_overflow')
          .width(48)
          .height(48)
          .padding(12)
          .objectFit(ImageFit.Contain)
          .fillColor($r('app.color.on_primary'))
          .bindMenu(this.overflowMenu(), SQUARE_MENU_CORNERS)
      }
      .id('toolbar')
      .width('100%')
      .height(56)
      .alignItems(VerticalAlign.Center)
      .backgroundColor($r('app.color.primary'))

      // getListHeaderSupplier(): a RecyclerView HEADER, hidden only while the load is IN FLIGHT.
      // showLoading() animates headerBinding + playlistControlBinding to alpha 0 + GONE, and
      // hideLoading() brings them back. handleResult() calls super.handleResult(result) FIRST
      // (LocalPlaylistFragment.java:502), and BaseStateFragment.handleResult (:150-155) is just
      // hideLoading() - so the header and control bar are already back BEFORE the empty branch
      // returns at :509-512. The settled Android capture proves it: base.ui.json renders
      // playlist_title_view 'Playlist', playlist_stream_count, playlist_control and all three
      // play buttons visible=true alongside empty_state_message 'No videos'. What the empty
      // branch skips is PlayButtonHelper.initPlaylistControlClickListener, so the bar is drawn
      // but its taps are no-ops - which is what openPlayer()'s empty-queue early return does.
      if (!this.isLoading) {
        this.listHeader()
      }

      Stack() {
        LocalItemListAdapter({
          dataSource: this.streamList,
          row: (item: PlaylistLocalItem): void => {
            this.itemRow(item);
          },
          // getItemTouchCallback(): rows are dragged by their handle into a new order, saved on
          // drop; a long press only opens the row's menu (isLongPressDragEnabled() is false).
          onRowHeight: (height: number): void => {
            this.rowStep = height;
          },
          scrollLocked: this.handleHeld,
          rowKey: (item: PlaylistLocalItem): string => item instanceof PlaylistStreamListItem
            ? (item as PlaylistStreamListItem).rowKey : `${item.localItemType}-${item.uid}`
        })

        if (this.isLoading) {
          LoadingProgress()
            .id('loading_progress_bar')
            .width(48)
            .height(48)
            .color($r('app.color.primary'))
        }

        // showEmptyState(): the footer goes and the header above is already hidden.
        // 35sp monospace emoticon, 10dp gap, 24sp message, centred with a 90dp top pad.
        if (!this.isLoading && this.result.length === 0 && this.errorInfo === null) {
          Column() {
            Text('(ಠ_ಠ)')
              .fontSize(35)
              .fontFamily('monospace')
              .fontColor($r('app.color.on_surface_variant'))
              .margin({ bottom: 10 })
            Text($r('app.string.empty_view_no_videos'))
              .id('empty_state_message')
              .fontSize(24)
              .fontColor($r('app.color.on_surface_variant'))
              .textAlign(TextAlign.Center)
          }
          .id('empty_state_view')
          .width('100%')
          .height('100%')
          .padding({ top: 90 })
          .alignItems(HorizontalAlign.Center)
          .justifyContent(FlexAlign.Center)
        }

        // error_panel.xml: 16dp padding, centred, the message bold at 16sp.
        if (this.errorInfo !== null) {
          Column() {
            Text(this.errorInfo)
              .id('error_message_view')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.on_surface'))
              .textAlign(TextAlign.Center)
              .width('100%')
            Button(Localization.buttonLabel('retry'))
              .id('error_retry_button')
              .fontSize(16)
              .fontColor($r('app.color.on_primary'))
              .backgroundColor($r('app.color.primary'))
              .margin({ top: 12 })
              .onClick(() => {
                this.startLoading();
              })
          }
          .id('error_panel')
          .width('100%')
          .padding(16)
          .alignItems(HorizontalAlign.Center)
          .justifyContent(FlexAlign.Center)
        }
      }
      .layoutWeight(1)
      .width('100%')

      // fragment_player_holder, docked. This screen is a pushUrl target, so MainActivityPage's own
      // bar is underneath it in the stack and cannot draw here; the bar has to be mounted per page.
      // Last child of the root Column, so it shortens the layoutWeight(1) list instead of covering
      // its last row. Visibility.None while the player is IDLE gives that height straight back.
      // Skipped when the shell embeds this screen as a child, where the shell's own bar is showing.
      if (!this.hostedInMainShell) {
        MiniPlayerBar({ idPrefix: 'local_playlist_' })
      }

      // The popup's surface, mounted only while one is being opened or is open. 1x1 and
      // transparent: PiP composites the video into its own window, the in-page node only has to
      // exist and be bound to the player.
      if (this.popupSurfaceMounted) {
        PopupPlayerSurface({
          controller: this.popupSurfaceController,
          onSurfaceReady: (): void => {
            this.onPopupSurfaceReady();
          }
        })
      }
    }
    .id('LocalPlaylistFragmentPage')
    .width('100%')
    .height('100%')
    .backgroundColor(themedBackground(this.blackTheme))
  }
}
