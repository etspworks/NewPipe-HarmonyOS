/*
 * S3 - ChannelTabFragment (screen_channel_tab), one page of ChannelFragment's pager (Videos /
 * Shorts / Live / Playlists / Albums / Channels, whichever tabs ChannelInfo.getTabs() yields).
 * hostedBy screen_channel, so ChannelFragmentPage instantiates this struct; the route exists only
 * so a deep link resolves.
 *
 * STRUCTURE from the source. fragment_channel_tab.xml is items_list over loading_progress_bar /
 * empty_state_view / error_panel, and getListHeaderSupplier() inflates playlist_control.xml as a
 * LIST HEADER - but only on a STREAMS tab (ChannelTabHelper.isStreamsTab), and the source then
 * sets that header GONE while the adapter holds nothing but itself.
 *
 * The list is genuinely POLYMORPHIC: the same fragment renders streams, playlists or channels
 * depending on the content filter it was created with, so the row branches on the InfoItem type
 * and each type opens a DIFFERENT screen. All rows share the source's one @+id/itemRoot
 * (Rule 12's list-row exception; the replay resolves rows by index).
 *
 * S3 = structure + wiring. No colours, no typography, no spacing: those are S5/S6.
 */
import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { userMessageFor } from '../common/error/ErrorMessages';

import { InfoItem } from '../common/extractor/core/InfoItem';
import { StreamInfoItem } from '../model/extractor/StreamInfoItem';
import { ChannelInfoItem } from '../model/extractor/ChannelInfoItem';
import { PlaylistInfoItem } from '../model/extractor/PlaylistInfoItem';
import { CommentsInfoItem } from '../model/extractor/CommentsInfoItem';
import { ChannelTabInfo } from '../model/extractor/ChannelTabInfo';
import { Page } from '../model/extractor/Page';
import { InfoItemsPage } from '../model/extractor/ListExtractorInfoItemsPage';
import { PlaylistLocalItem } from '../model/db/view/PlaylistLocalItem';
import { PlaylistMetadataEntry } from '../model/db/view/PlaylistMetadataEntry';
import { StreamEntity } from '../model/db/entity/StreamEntity';
import { LocalItemType } from '../model/enums/LocalItemLocalItemType';

import { ListLinkHandler } from '../common/extractor/linkhandler/LinkHandler';
import { ListLinkHandlerFactory } from '../common/extractor/linkhandler/LinkHandlerFactory';
import { NewPipe } from '../common/extractor/core/NewPipe';
import { StreamingService } from '../common/extractor/core/StreamingService';
import { ChannelTabs } from '../common/extractor/info/ChannelTabExtractor';
import { ExtractorHelper } from '../common/extractor/ExtractorHelper';
import { AppDatabase } from '../common/db/AppDatabase';
import { LocalPlaylistManager, playlistAppendToast } from '../common/db/PlaylistManager';
import { ServiceLocator } from '../common/di/ServiceLocator';
import { CompositeDisposable } from '../common/rx/Rx';
import { AppPreferences } from '../common/prefs/Preferences';
import {
  list_view_mode_key,
  list_view_mode_value,
  list_view_mode_card_key
} from '../common/prefs/SettingsKeys';

import { InfoListAdapter, InfoItemDataSource, ItemViewMode } from '../components/InfoListAdapter';
import { resolveItemViewMode } from '../common/settings/ViewModeResolver';
import { InfoItemHolder } from '../components/InfoItemHolder';
import { HeaderFooterHolder } from '../components/HeaderFooterHolder';
import { HFHolder } from '../components/HFHolder';
import { FallbackViewHolder } from '../components/FallbackViewHolder';
import { buildStreamMenuActions, DialogAction, InfoItemDialog, StreamMenuHandlers,
  StreamMenuTarget } from '../components/InfoItemDialog';
import { enqueueStream, markStreamAsWatched,
  startStreamInPlace, enqueueNextStream, enqueueAllOnPlayer, showHoldToAppendTip }
  from '../common/util/StreamRowActions';
import { PlayQueueItem } from '../model/app/PlayQueueItem';
import { StreamInfoItemHolder } from '../components/StreamInfoItemHolder';
import { DownloadDialogHost } from './DownloadDialogPage';
import { isAudioStream, isLiveStream } from '../model/app/StreamItem';
import { openPopupOnSurface, PopupPlayerSurface } from '../components/PopupPlayerSurface';
import { StreamMiniInfoItemHolder } from '../components/StreamMiniInfoItemHolder';
import { StreamGridInfoItemHolder } from '../components/StreamGridInfoItemHolder';
import { StreamCardInfoItemHolder } from '../components/StreamCardInfoItemHolder';
import { ChannelInfoItemHolder } from '../components/ChannelInfoItemHolder';
import { ChannelMiniInfoItemHolder } from '../components/ChannelMiniInfoItemHolder';
import { ChannelGridInfoItemHolder } from '../components/ChannelGridInfoItemHolder';
import { ChannelCardInfoItemHolder } from '../components/ChannelCardInfoItemHolder';
import { PlaylistInfoItemHolder } from '../components/PlaylistInfoItemHolder';
import { PlaylistMiniInfoItemHolder } from '../components/PlaylistMiniInfoItemHolder';
import { PlaylistGridInfoItemHolder } from '../components/PlaylistGridInfoItemHolder';
import { PlaylistCardInfoItemHolder } from '../components/PlaylistCardInfoItemHolder';
import { CommentInfoItemHolder } from '../components/CommentInfoItemHolder';
import { LocalItemListAdapter, LocalItemDataSource } from '../components/LocalItemListAdapter';
import { LocalItemHolder } from '../components/LocalItemHolder';
import { LocalPlaylistItemHolder } from '../components/LocalPlaylistItemHolder';
import { LocalBookmarkPlaylistItemHolder } from '../components/LocalBookmarkPlaylistItemHolder';
import { LocalPlaylistStreamItemHolder } from '../components/LocalPlaylistStreamItemHolder';
import { LocalStatisticStreamItemHolder } from '../components/LocalStatisticStreamItemHolder';
import { RemotePlaylistItemHolder } from '../components/RemotePlaylistItemHolder';
import { RemoteBookmarkPlaylistItemHolder } from '../components/RemoteBookmarkPlaylistItemHolder';
import { PlaylistItemHolder } from '../components/PlaylistItemHolder';
import { Localization } from '../common/i18n/Localization';
import { DIALOG_MASK_COLOR } from '../common/theme/ServiceTheme';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

const TAG: string = 'ChannelTabFragmentPage';

/** NavigationHelper.openVideoDetailFragment / openChannelFragment / openPlaylistFragment. */
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
 * ChannelTabHelper.isStreamsTab(tab): only these tabs get the play-control header. A Playlists,
 * Albums or Channels tab has no play buttons at all.
 */
function isStreamsTab(tab: string): boolean {
  return tab === ChannelTabs.VIDEOS || tab === ChannelTabs.TRACKS || tab === ChannelTabs.LIKES
    || tab === ChannelTabs.SHORTS || tab === ChannelTabs.LIVESTREAMS;
}

/** The append-to-playlist picker the long-press dialog opens (PlaylistAppendDialog's list). */
@CustomDialog
struct AppendPickerDialog {
  controller?: CustomDialogController;
  @BuilderParam picker: () => void = this.emptyPicker;

  @Builder
  emptyPicker() {
    Row()
  }

  build() {
    // dialog_playlists.xml is a bare list on the dialog surface - no title, no buttons.
    Column() {
      this.picker()
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .backgroundColor($r('app.color.dialog_surface'))
  }
}

@Entry
@Component
export struct ChannelTabFragmentPage {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  /**
   * infoListAdapter's backing list <- ChannelTabInfo.getRelatedItems(). The host supplies the
   * first tab's items with the ReadyChannelTabListLinkHandler it creates this page with, so it
   * is a one-way parent value the page then extends itself as more pages load.
   */
  @Prop tabItemsList: InfoItemDataSource = new InfoItemDataSource();
  /**
   * getListHeaderSupplier(): playlist_control exists only on a streams tab. The header's own
   * content filter is the tab id, so the flag is derived from tabHandler, not from the capture.
   */
  @Prop playlistControlHeader: boolean = false;
  /** The ListLinkHandler this page was created with - it IS the tab. */
  @State tabHandler: string = ChannelTabs.VIDEOS;
  /**
   * ChannelTabFragment.getInstance(serviceId, tabHandler, channelName): the three values the host
   * creates each pager page with. The tab still loads its own page of items (loadResult() ->
   * ExtractorHelper.getChannelTab), so only those identifying arguments come from the host.
   */
  @Prop hostServiceId: number = -1;
  @Watch('onHostChannelChanged') @Prop hostChannelUrl: string = '';
  @Prop hostTabFilter: string = '';
  /**
   * ChannelInfo.getTabs()' own handler for this tab, looked up on the host by tab key. A plain
   * member would go stale when the pager reuses this child, so the host passes a lookup instead.
   */
  hostLinkHandler: (key: string) => ListLinkHandler | null = (): ListLinkHandler | null => null;
  @Prop hostChannelName: string = '';
  /**
   * The host's collapsing header listens to this tab's scroll, the way a CoordinatorLayout listens
   * to its RecyclerView. Reached as a route there is no host and no header, so it is a no-op.
   */
  hostOnScrolled: (delta: number) => void = (): void => {
  };
  /**
   * playlistControlBinding: the source sets the control bar GONE while the adapter holds nothing
   * but the header itself (getItemCount() <= 1).
   */
  @State playlistControlBinding: boolean = false;

  @State isLoading: boolean = true;
  @State errorInfo: string | null = null;
  /** How many rows the adapter holds - showEmptyState() is driven by this, not by the pixels. */
  @State loadedCount: number = 0;
  /** Page.isValid(currentNextPage): the pignate_footer row shows while more pages remain. */
  @State hasMoreItems: boolean = false;
  /** ThemeHelper.getItemViewMode(). */
  @State itemViewMode: ItemViewMode = ItemViewMode.LIST;
  /**
   * AppearanceSettingsFragmentPage publishes the chosen list_view_mode here right after it writes
   * the preference, so a page that is ALREADY drawn re-reads it instead of keeping the template it
   * was built with. @Watch never fires on init, so aboutToAppear's own read still stands.
   */
  @StorageProp('listViewMode') @Watch('setupItemViewMode')
  private listViewModeSignal: string = '';
  /** setUseMiniVariant(...) - false on this screen. */
  @State useMiniVariant: boolean = false;
  /** LocalItemListAdapter.useItemHandle - false outside BookmarkFragment. */
  @State useItemHandle: boolean = false;
  /** currentInfo.getService() == SoundCloud -> no_streams instead of no_videos. */
  @State isSoundCloud: boolean = false;

  /** showInfoItemDialog(item): the title and its entries. */
  @State menuTitle: string = '';
  @State menuActions: DialogAction[] = [];

  private serviceId: number = 0;
  private url: string = '';
  private name: string = '';
  /** getMoreChannelTabItems(serviceId, tabHandler, currentNextPage). */
  private currentNextPage: Page | null = null;
  private linkHandler: ListLinkHandler | null = null;
  /** The row the long press opened the dialog for. */
  private menuTarget: StreamInfoItem | null = null;

  /** The append-to-playlist picker's own list. */
  private appendPlaylists: LocalItemDataSource = new LocalItemDataSource();

  private database: AppDatabase | null = null;
  private playlistManager: LocalPlaylistManager | null = null;
  private readonly disposables: CompositeDisposable = new CompositeDisposable();

  private infoItemDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    builder: InfoItemDialog({ title: this.menuTitle, actions: this.menuActions })
  });

  private appendDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    builder: AppendPickerDialog({
      picker: (): void => {
        this.appendPicker();
      }
    })
  });

  /* //////////////////////////////////////////////////////////////////////////
  // Lifecycle
  ////////////////////////////////////////////////////////////////////////// */

  aboutToAppear(): void {
    this.setupItemViewMode();
    this.readArguments();
    this.startLoading(false);
  }

  /** ThemeHelper.getItemViewMode() - the one copy lives in ViewModeResolver. */
  private setupItemViewMode(): void {
    const store: AppPreferences = AppPreferences.instance();
    const mode: string = store.getStringSync(list_view_mode_key,
      store.resolveDefault(list_view_mode_value));
    this.itemViewMode = resolveItemViewMode(mode);
  }

  aboutToDisappear(): void {
    this.disposables.dispose();
  }

  /**
   * loadItem() can swap the channel while the pager keeps this page mounted, where the source
   * would have built a fresh ChannelTabFragment through getInstance(). Re-reading the arguments
   * and re-running startLoading() is that rebuild.
   */
  private onHostChannelChanged(): void {
    this.linkHandler = null;
    this.readArguments();
    this.startLoading(false);
  }

  private readArguments(): void {
    // getInstance(serviceId, tabHandler, channelName) — the host's values win whenever it
    // supplied them; router.getParams() only serves the registered-route entry.
    if (this.hostChannelUrl.length !== 0) {
      this.serviceId = this.hostServiceId;
      this.url = this.hostChannelUrl;
      this.tabHandler = this.hostTabFilter;
      this.name = this.hostChannelName;
      this.playlistControlHeader = isStreamsTab(this.tabHandler);
      return;
    }
    const params: Record<string, Object> | undefined =
      router.getParams() as Record<string, Object> | undefined;
    if (params === undefined || params === null) {
      return;
    }
    const sid: Object | undefined = params['serviceId'];
    if (sid !== undefined && sid !== null) {
      this.serviceId = Number(sid.toString());
    }
    const tabUrl: Object | undefined = params['url'];
    if (tabUrl !== undefined && tabUrl !== null) {
      this.url = tabUrl.toString();
    }
    const tab: Object | undefined = params['tab'];
    if (tab !== undefined && tab !== null) {
      this.tabHandler = tab.toString();
    }
    const tabName: Object | undefined = params['name'];
    if (tabName !== undefined && tabName !== null) {
      this.name = tabName.toString();
    }
    this.playlistControlHeader = isStreamsTab(this.tabHandler);
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
      const manager: LocalPlaylistManager = new LocalPlaylistManager(db);
      this.playlistManager = manager;
      return manager;
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      hilog.warn(0x0000, TAG, 'ensureServices: %{public}s', failure.message);
      return null;
    }
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Load
  ////////////////////////////////////////////////////////////////////////// */

  /** loadResult(forceLoad) -> ExtractorHelper.getChannelTab(serviceId, tabHandler, forceLoad). */
  private async startLoading(forceLoad: boolean): Promise<void> {
    const handler: ListLinkHandler | null = this.buildHandler();
    if (handler === null) {
      this.isLoading = false;
      return;
    }
    this.isLoading = true;
    this.errorInfo = null;
    try {
      const info: ChannelTabInfo =
        await ExtractorHelper.getChannelTab(this.serviceId, handler, forceLoad);
      this.tabItemsList.clearItems();
      this.tabItemsList.addItems(info.getRelatedItems());
      this.loadedCount = this.tabItemsList.totalCount();
      this.currentNextPage = info.getNextPage();
      this.hasMoreItems = this.currentNextPage !== null;
      this.playlistControlBinding = this.playlistControlHeader && this.loadedCount > 0;
      // ExtractorHelper.getItemsPageOrLogError() does not throw: it records the failure on the
      // Info and hands back an empty page, which is the extractor's own design and keeps one bad
      // block from losing a whole screen. The catch below therefore never runs for a page that
      // failed to load, and the screen fell through to its empty state - a failed tab and a tab
      // with nothing in it looked identical. BaseListInfoFragment reads info.getErrors() for
      // exactly this reason.
      const errors: Error[] = info.getErrors();
      if (this.loadedCount === 0 && errors.length > 0) {
        this.errorInfo = userMessageFor(errors[0]);
      }
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.errorInfo = userMessageFor(failure);
    } finally {
      this.isLoading = false;
    }
  }

  /**
   * The ListLinkHandler the pager page carries. It must come from the service's own channel-tab
   * factory, the way ChannelInfo.getTabs() builds it in the source: the handler's ID is what the
   * extractor resolves the channel from, and its URL is what the info cache is keyed on.
   *
   * Hand-building it from the channel URL got BOTH wrong. The id became the whole URL, so
   * YoutubeChannelTabExtractor.onFetchPage fed "https://www.youtube.com/channel/UC..." to
   * resolveChannelId(), whose first segment is then "https:" - neither "UC..." nor "channel" - so
   * it asked navigation/resolve_url for "https://www.youtube.com/https://www.youtube.com/..." and
   * InnerTube answered INVALID_ARGUMENT. And the url was the channel's, identical for every tab,
   * so all of a channel's tabs shared one InfoCache key.
   *
   * fromQuery(id, [tab], '') fixes both: getUrlWithFilters appends the tab's own URL suffix, and
   * the id keeps its "channel/UC..." / "@handle" prefix, which is what resolveChannelId expects.
   */
  private buildHandler(): ListLinkHandler | null {
    const existing: ListLinkHandler | null = this.linkHandler;
    if (existing !== null) {
      return existing;
    }
    // ChannelInfo.getTabs() built a handler for this tab already, and for Bandcamp it is a
    // ReadyChannelTabListLinkHandler carrying the discography the channel page fetched.
    // Rebuilding a plain handler from the URL below threw that away: BandcampChannelTab's id is
    // a numeric band id resolved only for the BARE artist URL, so getId() on ".../album" missed
    // the cache, the catch fell through to the plain handler, and band_details was asked for a
    // band_id that was really a tab URL - an empty discography, and "No videos" on every tab.
    const fromHost: ListLinkHandler | null = this.hostLinkHandler(this.tabHandler);
    if (fromHost !== null) {
      this.linkHandler = fromHost;
      return fromHost;
    }
    if (this.url.length === 0) {
      return null;
    }
    let handler: ListLinkHandler | null = null;
    try {
      const service: StreamingService = NewPipe.getService(this.serviceId);
      const factory: ListLinkHandlerFactory | null = service.getChannelTabLHFactory();
      if (factory !== null) {
        handler = factory.fromQuery(factory.getId(this.url), [this.tabHandler], '', null);
      }
    } catch (err) {
      // A service with no tab factory, or a URL it does not accept: fall through to the plain
      // handler below rather than losing the tab entirely.
      hilog.warn(0x0000, TAG, 'buildHandler tab=%{public}s url=%{public}s: %{public}s',
        this.tabHandler, this.url, (err as BusinessError).message);
    }
    if (handler === null) {
      handler = new ListLinkHandler(this.url, this.url, this.url, [this.tabHandler], '');
    }
    this.linkHandler = handler;
    return handler;
  }

  /** OnScrollBelowItemsListener -> loadMoreItems() while Page.isValid(currentNextPage). */
  private async loadMoreItems(): Promise<void> {
    const handler: ListLinkHandler | null = this.buildHandler();
    const next: Page | null = this.currentNextPage;
    if (handler === null || next === null || this.isLoading) {
      return;
    }
    this.isLoading = true;
    try {
      const page: InfoItemsPage<InfoItem> =
        await ExtractorHelper.getMoreChannelTabItems(this.serviceId, handler, next);
      this.tabItemsList.addItems(page.getItems());
      this.loadedCount = this.tabItemsList.totalCount();
      this.currentNextPage = page.getNextPage();
      this.hasMoreItems = this.currentNextPage !== null;
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.errorInfo = userMessageFor(failure);
    } finally {
      this.isLoading = false;
    }
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Items
  ////////////////////////////////////////////////////////////////////////// */

  /** The list is polymorphic, so the tap route follows the ITEM TYPE, not the tab. */
  private onItemSelected(item: InfoItem): void {
    if (item instanceof ChannelInfoItem) {
      const channel: ChannelInfoItem = item as ChannelInfoItem;
      router.pushUrl({
        url: 'pages/ChannelFragmentPage',
        params: new ItemParams(channel.getServiceId(), channel.getUrl(), channel.getName())
      });
    } else if (item instanceof PlaylistInfoItem) {
      const playlist: PlaylistInfoItem = item as PlaylistInfoItem;
      router.pushUrl({
        url: 'pages/PlaylistFragmentPage',
        params: new ItemParams(playlist.getServiceId(), playlist.getUrl(), playlist.getName())
      });
    } else {
      router.pushUrl({
        url: 'pages/VideoDetailFragmentPage',
        params: new ItemParams(item.getServiceId(), item.getUrl(), item.getName())
      });
    }
  }

  /** OnClickGesture.held -> showInfoItemDialog(item). */
  private onItemHeld(item: InfoItem): void {
    if (!(item instanceof StreamInfoItem)) {
      return;
    }
    const stream: StreamInfoItem = item as StreamInfoItem;
    this.menuTarget = stream;
    this.menuTitle = stream.getName();

    // InfoItemDialog.Builder owns the entry list and its order; this screen only says what each
    // entry does. It used to offer four entries of its own against the reference's full set.
    const target: StreamMenuTarget = new StreamMenuTarget();
    target.serviceId = stream.getServiceId();
    target.url = stream.getUrl();
    target.title = stream.getName();
    target.uploader = stream.getUploaderName();
    const uploaderUrl: string | null = stream.getUploaderUrl();
    target.uploaderUrl = uploaderUrl === null ? '' : uploaderUrl;
    target.audioOnly = isAudioStream(stream.getStreamType());
    target.live = isLiveStream(stream.getStreamType());

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
      promptAction.showToast({
        message: $r('app.string.background_player_playing_toast'),
        duration: 2000
      });
      startStreamInPlace(getContext(this) as common.UIAbilityContext, target.serviceId,
        target.url, true);
    };
    handlers.onPopup = (): void => {
      // This screen owns a popup surface (T-0115), so the row's popup entry opens the window in
      // place the same way its header control does.
      if (this.popupSurfaceMounted) {
        return;
      }
      promptAction.showToast({ message: $r('app.string.popup_playing_toast'), duration: 2000 });
      this.popupItem = stream;
      this.popupSurfaceMounted = true;
    };
    handlers.onDownload = (): void => {
      this.downloadServiceId = target.serviceId;
      this.downloadUrl = target.url;
      this.showDownloadDialog = true;
    };
    handlers.onAddToPlaylist = (): void => {
      this.openAppendDialog();
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

    this.menuActions = buildStreamMenuActions(target, handlers);
    this.infoItemDialog.open();
  }

  private async openAppendDialog(): Promise<void> {
    const manager: LocalPlaylistManager | null = await this.ensureServices();
    if (manager === null) {
      return;
    }
    try {
      const playlists: PlaylistMetadataEntry[] = await manager.getPlaylists();
      const rows: PlaylistLocalItem[] = [];
      for (const playlist of playlists) {
        rows.push(playlist);
      }
      this.appendPlaylists.setItems(rows);
      this.appendDialog.open();
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      hilog.warn(0x0000, TAG, 'getPlaylists: %{public}s', failure.message);
    }
  }

  private async appendToPlaylist(playlist: PlaylistLocalItem): Promise<void> {
    const manager: LocalPlaylistManager | null = this.playlistManager;
    const stream: StreamInfoItem | null = this.menuTarget;
    if (manager === null || stream === null) {
      return;
    }
    try {
      await manager.appendToPlaylist(playlist.uid, [StreamEntity.fromInfoItem(stream)]);
      // PlaylistAppendDialog.onPlaylistSelected() ends in a Toast on the reference - the string
      // `playlist_add_stream_success` ("Playlisted") was already in this port's resources and had
      // no caller anywhere, so an append finished silently. Every entry point that appends says
      // so, not just the one the case happens to name.
      promptAction.showToast({ message: playlistAppendToast(playlist),
        duration: 2000 });
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      hilog.warn(0x0000, TAG, 'appendToPlaylist: %{public}s', failure.message);
    }
  }

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

  /** PopupPlayerSurface is mounted only while a popup is being opened or is open. */
  @State popupSurfaceMounted: boolean = false;
  /** The item the popup was raised for; read once the surface is bound. */
  private popupItem: StreamInfoItem | null = null;
  private popupSurfaceController: XComponentController = new XComponentController();

  /** The surface is bound: the shared launcher prepares the stream and hands it to PiP. */
  private async onPopupSurfaceReady(): Promise<void> {
    const item: StreamInfoItem | null = this.popupItem;
    if (item === null) {
      return;
    }
    this.popupItem = null;
    await openPopupOnSurface(getContext(this) as common.UIAbilityContext, item.getServiceId(),
      item.getUrl(), this.popupSurfaceController, (): void => {
        this.popupSurfaceMounted = false;
      });
  }

  /**
   * PlayButtonHelper.initPlaylistControlClickListener: getPlayQueue() builds a
   * ChannelTabPlayQueue from the loaded StreamInfoItems plus the next page, so the queue keeps
   * extending past what is on screen.
   */
  /**
   * PlayButtonHelper's long press: the tab's streams join the running player's queue; with nothing
   * playing they start in that player instead.
   */
  private enqueueAll(playerType: string): void {
    const items: PlayQueueItem[] = [];
    for (const item of this.tabItemsList.getItemsList()) {
      if (item instanceof StreamInfoItem) {
        items.push(PlayQueueItem.fromStreamInfoItem(item as StreamInfoItem));
      }
    }
    if (items.length > 0 && !enqueueAllOnPlayer(items)) {
      this.openPlayer(0, playerType);
    }
  }

  private openPlayer(startIndex: number, playerType: string): void {
    const items: InfoItem[] = this.tabItemsList.getItemsList();
    for (let i = startIndex; i < items.length; i++) {
      const item: InfoItem = items[i];
      if (item instanceof StreamInfoItem) {
        if (playerType === 'POPUP') {
          // playOnPopupPlayer() opens the float window OVER the screen the user is on - the
          // channel tab stays visible behind it. This page used to push VideoDetailFragmentPage,
          // because PiPWindow renders from an XComponent surface (PiPConfiguration
          // .componentController) and that page owned the only one; the user landed on the
          // standard player instead. PopupPlayerSurface is this page's own surface, and
          // openPopupOnSurface() is the one implementation every list screen shares.
          // A burst of taps must open ONE popup: the surface's onLoad fires once, so a second
          // item set behind a mounted surface would simply never be played.
          if (this.popupSurfaceMounted) {
            return;
          }
          promptAction.showToast({ message: $r('app.string.popup_playing_toast'), duration: 2000 });
          this.popupItem = item as StreamInfoItem;
          this.popupSurfaceMounted = true;
          return;
        }
        this.onItemSelected(item);
        return;
      }
    }
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Builders
  ////////////////////////////////////////////////////////////////////////// */

  /** getListHeaderSupplier(): playlist_control.xml, on a streams tab only. */
  @Builder
  listHeader() {
    HeaderFooterHolder() {
      // playlist_control.xml: three weight-1 cells 50dp tall, a drawableStart glyph 4dp before
      // a 12sp ?attr/colorAccent label, split by 1dp accent rules inset 10dp top and bottom.
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
          this.openPlayer(0, 'AUDIO');
          showHoldToAppendTip();
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
          this.openPlayer(0, 'MAIN');
          showHoldToAppendTip();
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
          this.openPlayer(0, 'POPUP');
          showHoldToAppendTip(2100);
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
  }

  /** onCreateViewHolder(FOOTER_TYPE): the pignate_footer indeterminate row. */
  @Builder
  listFooter() {
    HFHolder() {
      LoadingProgress()
        .id('pignate_footer')
        .width(32)
        .height(32)
        .color($r('app.color.primary'))
        .margin({ top: 8, bottom: 8 })
    }
  }

  /** InfoItemHolder owns the row root (itemRoot) and its click / long-click. */
  @Builder
  itemRow(item: InfoItem) {
    InfoItemHolder({
      onSelected: (): void => {
        this.onItemSelected(item);
      },
      onHeld: (): void => {
        this.onItemHeld(item);
      }
    }) {
      this.holderFor(item)
    }
  }

  /** InfoListAdapter.getItemViewType() + onCreateViewHolder(), in its branch order. */
  @Builder
  holderFor(item: InfoItem) {
    if (item instanceof StreamInfoItem) {
      if (this.itemViewMode === ItemViewMode.CARD) {
        StreamCardInfoItemHolder({ item: item as StreamInfoItem })
      } else if (this.itemViewMode === ItemViewMode.GRID) {
        StreamGridInfoItemHolder({ item: item as StreamInfoItem })
      } else if (this.useMiniVariant) {
        StreamMiniInfoItemHolder({ item: item as StreamInfoItem })
      } else {
        StreamInfoItemHolder({ item: item as StreamInfoItem })
      }
    } else if (item instanceof ChannelInfoItem) {
      if (this.itemViewMode === ItemViewMode.CARD) {
        ChannelCardInfoItemHolder({ item: item as ChannelInfoItem })
      } else if (this.itemViewMode === ItemViewMode.GRID) {
        ChannelGridInfoItemHolder({ item: item as ChannelInfoItem })
      } else if (this.useMiniVariant) {
        ChannelMiniInfoItemHolder({ item: item as ChannelInfoItem })
      } else {
        ChannelInfoItemHolder({ item: item as ChannelInfoItem })
      }
    } else if (item instanceof PlaylistInfoItem) {
      if (this.itemViewMode === ItemViewMode.CARD) {
        PlaylistCardInfoItemHolder({ item: item as PlaylistInfoItem })
      } else if (this.itemViewMode === ItemViewMode.GRID) {
        PlaylistGridInfoItemHolder({ item: item as PlaylistInfoItem })
      } else if (this.useMiniVariant) {
        PlaylistMiniInfoItemHolder({ item: item as PlaylistInfoItem })
      } else {
        PlaylistInfoItemHolder({ item: item as PlaylistInfoItem })
      }
    } else if (item instanceof CommentsInfoItem) {
      CommentInfoItemHolder({ item: item as CommentsInfoItem })
    } else {
      FallbackViewHolder()
    }
  }

  /** PlaylistAppendDialog's list: LocalItemListAdapter over the user's local playlists. */
  @Builder
  appendPicker() {
    LocalItemListAdapter({
      dataSource: this.appendPlaylists,
      row: (item: PlaylistLocalItem): void => {
        this.appendRow(item);
      }
    })
  }

  @Builder
  appendRow(item: PlaylistLocalItem) {
    LocalItemHolder({
      item: item,
      onSelected: (selected: PlaylistLocalItem): void => {
        this.appendToPlaylist(selected);
      },
      onHeld: (held: PlaylistLocalItem): void => {
        this.appendToPlaylist(held);
      },
      // An arrow keeps `this` on this page; `this.appendBody` would re-bind it to the holder.
      body: (row: PlaylistLocalItem): void => {
        this.appendBody(row);
      }
    })
  }

  /** LocalItemListAdapter.getItemViewType() + onCreateViewHolder() for the append picker. */
  @Builder
  appendBody(item: PlaylistLocalItem) {
    if (item.localItemType === LocalItemType.PLAYLIST_LOCAL_ITEM) {
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
    } else if (item.localItemType === LocalItemType.PLAYLIST_STREAM_ITEM) {
      LocalPlaylistStreamItemHolder({
        thumbnailUrl: item.thumbnailUrl,
        title: item.orderingName,
        showItemHandle: this.useItemHandle
      })
    } else if (item.localItemType === LocalItemType.STATISTIC_STREAM_ITEM) {
      LocalStatisticStreamItemHolder({
        thumbnailUrl: item.thumbnailUrl,
        title: item.orderingName
      })
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

  build() {
    Column() {
      /*
       * The control bar is a LIST HEADER in the source, and it exists only on a streams tab -
       * and only once the adapter holds more than the header itself.
       */
      // It is handed to the adapter as its HEADER, not drawn above the list. Rendered as a sibling
      // it sat outside the scroller, so it stayed on screen while the list moved under it - the
      // reference lets it scroll away with the content, leaving only the toolbar and the tab strip
      // once the channel header has collapsed. That is what TC-FEED-001 reports as the top area not
      // closing the same way.
      //
      // !ChannelTabHelper.isStreamsTab(tabHandler): a Playlists, Albums or Channels tab gets
      // NO header at all, and on a streams tab the bar is GONE until the adapter holds a row.
      Stack() {
        InfoListAdapter({
          dataSource: this.tabItemsList,
          viewMode: this.itemViewMode,
          hasHeader: isStreamsTab(this.tabHandler) && this.playlistControlBinding,
          header: (): void => {
            this.listHeader();
          },
          showFooter: this.hasMoreItems,
          onReachEnd: (): void => {
            this.loadMoreItems();
          },
          onScrolled: (delta: number): void => {
            this.hostOnScrolled(delta);
          },
          footer: (): void => {
            this.listFooter();
          },
          row: (item: InfoItem): void => {
            this.itemRow(item);
          }
        })

        if (this.isLoading) {
          LoadingProgress()
            .id('loading_progress_bar')
            .width(48)
            .height(48)
            .color($r('app.color.primary'))
        }

        // showEmptyState(): no_streams on SoundCloud, no_videos elsewhere.
        // fragment_channel_videos.xml: 35sp monospace kaomoji, 10dp gap, 24sp message,
        // centred with a 90dp top pad.
        if (!this.isLoading && this.loadedCount === 0 && this.errorInfo === null) {
          Column() {
            Text('(╯°□°)╯︵ ┻━┻')
              .fontSize(35)
              .fontFamily('monospace')
              .fontColor($r('app.color.on_surface_variant'))
              .margin({ bottom: 10 })
            Text(this.isSoundCloud
              ? $r('app.string.no_streams') : $r('app.string.no_videos'))
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
                this.startLoading(true);
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

      // The popup's surface, mounted only while one is being opened or is open. 1x1 and
      // transparent: PiP composites the video into its own window.
      if (this.popupSurfaceMounted) {
        PopupPlayerSurface({
          controller: this.popupSurfaceController,
          onSurfaceReady: (): void => {
            this.onPopupSurfaceReady();
          }
        })
      }
    }
    .id('ChannelTabFragmentPage')
    .width('100%')
    .height('100%')
    .backgroundColor(themedBackground(this.blackTheme))
  }

  /** DownloadDialog over this list, mounted the way the feed mounts it. */
}
