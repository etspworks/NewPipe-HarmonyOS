/**
 * S3 — DefaultKioskFragment (screen_default_kiosk), structure from DefaultKioskFragment.java +
 * KioskFragment.java + fragment_kiosk.xml, read verbatim off codegraph.
 *
 * DefaultKioskFragment extends KioskFragment and adds exactly ONE behaviour:
 * updateSelectedDefaultKiosk() — it follows the app-wide selected service rather than a kiosk id
 * passed in as an argument:
 *
 *   serviceId = ServiceHelper.getSelectedServiceId(ctx);
 *   kioskId   = NewPipe.getService(serviceId).getKioskList().getDefaultKioskId();
 *   url       = kioskList.getListLinkHandlerFactoryByType(kioskId).fromId(kioskId).getUrl();
 *   kioskTranslatedName = KioskTranslator.getTranslatedKioskName(kioskId, ctx); name = it;
 *   currentInfo = null; currentNextPage = null;
 *
 * run from onCreate() when `serviceId < 0`, and again from onResume() when the selected service
 * has CHANGED — there the in-flight worker is disposed first and reloadContent() follows, so the
 * same screen instance really shows a different service's kiosk. An ExtractionException from
 * NewPipe.getService(...) goes to showError(ErrorInfo(e, REQUESTED_KIOSK, "Loading default kiosk
 * for selected service")), which is why the error panel can replace the list before any load.
 *
 * Everything else — the list, the row types, pagination, the long-press dialog, the empty state
 * and the error panel — is KioskFragment's and is reproduced here from the same source, because
 * an ArkUI struct cannot extend another struct. The rows are InfoListAdapter's holders
 * (sharedNotOwned): `items_list` lives on InfoListAdapter's List and `itemRoot` on
 * InfoItemHolder's row root — one shared id across all N rows (Rule 12's list-row exception), so
 * neither id is re-declared here.
 *
 * DefaultKioskFragment is the fragment behind the DefaultKioskTab on the main page, i.e. it is
 * always useAsFrontPage — setDisplayHomeAsUpEnabled(false) — so it has no Up arrow, and its
 * controlInventory lists no navigation control.
 *
 * S5 — styled from results/traversal-source/pages/fragment_DefaultKioskFragment/base.png plus
 * the source layouts (toolbar_layout.xml, fragment_kiosk.xml, error_panel.xml) and the app-level
 * style baseline in state.json generation.styleBaseline. The capture's toolbar carries a
 * "Navigate up" button because the gallery launched this fragment inside its own container
 * activity; the SOURCE is always useAsFrontPage, so no Up arrow is added here — style only.
 * The rows themselves are InfoListAdapter's holders, owned and styled by another screen.
 */
import { router } from '@kit.ArkUI';

import { InfoItem } from '../common/extractor/core/InfoItem';
import { StreamInfoItem } from '../model/extractor/StreamInfoItem';
import { ChannelInfoItem } from '../model/extractor/ChannelInfoItem';
import { PlaylistInfoItem } from '../model/extractor/PlaylistInfoItem';
import { CommentsInfoItem } from '../model/extractor/CommentsInfoItem';
import { PlaylistLocalItem } from '../model/db/view/PlaylistLocalItem';
import { LocalItemType } from '../model/enums/LocalItemLocalItemType';

import { InfoListAdapter, InfoItemDataSource, ItemViewMode } from '../components/InfoListAdapter';
import { resolveItemViewMode } from '../common/settings/ViewModeResolver';
import { InfoItemHolder } from '../components/InfoItemHolder';
import { HeaderFooterHolder } from '../components/HeaderFooterHolder';
import { HFHolder } from '../components/HFHolder';
import { FallbackViewHolder } from '../components/FallbackViewHolder';
import { buildStreamMenuActions, DialogAction, InfoItemDialog, StreamMenuHandlers,
  StreamMenuTarget } from '../components/InfoItemDialog';
import { enqueueStream, markStreamAsWatched,
  startStreamInPlace, enqueueNextStream } from '../common/util/StreamRowActions';
import { StreamInfoItemHolder } from '../components/StreamInfoItemHolder';
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
import { LocalItemDataSource } from '../components/LocalItemListAdapter';
import { PlaylistAppendDialog } from '../components/PlaylistAppendDialog';
import { PlaylistCreationDialog } from '../components/PlaylistCreationDialog';
import { LocalItemHolder } from '../components/LocalItemHolder';
import { LocalPlaylistItemHolder } from '../components/LocalPlaylistItemHolder';
import { LocalBookmarkPlaylistItemHolder } from '../components/LocalBookmarkPlaylistItemHolder';
import { RemotePlaylistItemHolder } from '../components/RemotePlaylistItemHolder';
import { RemoteBookmarkPlaylistItemHolder } from '../components/RemoteBookmarkPlaylistItemHolder';
import { LocalPlaylistStreamItemHolder } from '../components/LocalPlaylistStreamItemHolder';
import { LocalStatisticStreamItemHolder } from '../components/LocalStatisticStreamItemHolder';
import { PlaylistItemHolder } from '../components/PlaylistItemHolder';

import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { promptAction } from '@kit.ArkUI';

import { ExtractorHelper } from '../common/extractor/ExtractorHelper';
import { StreamInfo } from '../model/extractor/StreamInfo';
import { PlayerService } from '../common/player/PlayerService';
import { PlayerPrefs } from '../common/player/PlayerPrefs';

import { MediaSessionService } from '../common/player/MediaSessionService';
import { BackgroundWorkMode } from '../common/background/BackgroundWork';
import { openPopupOnSurface, PopupPlayerSurface } from '../components/PopupPlayerSurface';
import { DownloadDialogHost } from './DownloadDialogPage';
import { NewPipe } from '../common/extractor/core/NewPipe';
import { StreamingService } from '../common/extractor/core/StreamingService';
import { SoundCloud, MediaCCC } from '../common/extractor/ServiceRegistry';
import { KioskInfo } from '../model/extractor/KioskInfo';
import { Page } from '../model/extractor/Page';
import { InfoItemsPage } from '../model/extractor/ListExtractorInfoItemsPage';
import { getTranslatedKioskName } from '../model/app/Tab';
import { Localization } from '../common/i18n/Localization';
import { AppPreferences } from '../common/prefs/Preferences';
import {
  current_service_key,
  default_service_value,
  list_view_mode_key,
  list_view_mode_value,
  list_view_mode_card_key
} from '../common/prefs/SettingsKeys';
import { AppDatabase } from '../common/db/AppDatabase';
import { HistoryRecordManager } from '../common/db/HistoryRecordManager';
import { LocalPlaylistManager, playlistAppendToast } from '../common/db/PlaylistManager';
import { StreamEntity } from '../model/db/entity/StreamEntity';
import { PlaylistMetadataEntry } from '../model/db/view/PlaylistMetadataEntry';
import { ServiceLocator } from '../common/di/ServiceLocator';
import { ErrorInfo } from '../model/app/ErrorInfo';
import { UserAction } from '../model/enums/UserAction';
import { InfoCache } from '../common/extractor/InfoCache';
import { Disposable, Observable } from '../common/rx/Rx';
import { servicePrimaryColor, DIALOG_MASK_COLOR } from '../common/theme/ServiceTheme';
import { isAudioStream, isLiveStream } from '../model/app/StreamItem';
import { MiniPlayerBar } from '../components/MiniPlayerBar';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

const TAG: string = 'DefaultKioskFragmentPage';

/* S5 — baseline tokens (state.json generation.styleBaseline, source S0004). */
const C_ON_SURFACE: Resource = $r('app.color.on_surface');

/** NavigationHelper.openVideoDetailFragment / openChannelFragment take the same three. */
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

/** MediaCCCLiveStreamKiosk.KIOSK_ID — the one kiosk with its own empty message. */
const LIVE_STREAM_KIOSK_ID: string = 'live';
/** ServiceHelper.DEFAULT_FALLBACK_SERVICE — YouTube. */
const DEFAULT_FALLBACK_SERVICE_ID: number = 0;

@Entry
@Component
export struct DefaultKioskFragmentPage {
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
  /** infoListAdapter's backing list <- KioskInfo.relatedItems. */

  /**
   * MainActivityPage's toolbar already carries the kiosk name - MainFragmentPage
   * writes the tab name into it - so drawing this screen's own title band put the
   * same word on screen twice. Skipped while the shell owns the bar.
   */
  @StorageProp('mainShellOwnsToolbar') private shellOwnsToolbar: boolean = false;
  @State kioskItemsList: InfoItemDataSource = new InfoItemDataSource();
  /**
   * onTabReselected(tab): a second tap on the kiosk's own tab sends the list back to the top,
   * which is the only thing TabLayout's reselect callback is for here. MainFragment bumps the
   * counter; the strip and this list are two container boundaries apart.
   */
  @StorageProp('mainTabReselectRequest') @Watch('onTabReselected') tabReselectRequest: number = 0;

  /** The InfoListAdapter List's scroller, so scrollToPosition(0) has something to talk to. */
  private listScroller: Scroller = new Scroller();
  /** The append-to-playlist picker's list, opened from the row long-press dialog. */
  private appendPlaylists: LocalItemDataSource = new LocalItemDataSource();

  /**
   * name = kioskTranslatedName = KioskTranslator.getTranslatedKioskName(kioskId): WHICH kiosk
   * this screen is currently showing, resolved from the selected service — never a literal.
   */
  @State whichKioskIsShown: string = '';
  /** ServiceHelper.getSelectedServiceId(ctx); -1 until updateSelectedDefaultKiosk() has run. */
  @State serviceId: number = -1;
  /** kioskList.getDefaultKioskId() for the selected service. */
  @State kioskId: string = '';

  /** KioskFragment.contentCountry — inherited: a change on resume forces reloadContent(). */
  @State contentCountry: string = '';
  /**
   * onResume() is where the source re-resolves the kiosk after a service change, but this page
   * renders inside MainFragmentPage's Swiper, where page lifecycle never fires — onPageShow
   * belongs to the ROUTED page, not to a hosted child, so the drawer's service choice reached
   * this tab only if the user left and re-entered the whole page. The shell publishes that
   * choice here (MainActivityPage.ets:405,684), so watching it is the hosted child's onResume.
   */
  @StorageProp('mainSelectedServiceId') @Watch('onSelectedServiceChanged')
  private activeServiceId: number = -1;

  @State isLoading: boolean = true;
  /** showError(ErrorInfo(...)) — the panel replaces the list. */
  @State errorInfo: string | null = null;
  /** ErrorPanelHelper:101-107 — the recaptcha/report button's label, empty when it has none. */
  @State errorActionLabel: string = '';
  /** ErrorPanelHelper.showAndSetOpenInBrowserButtonAction(url) — null hides the button. */
  @State openInBrowserUrl: string | null = null;
  /** BaseStateFragment.lastPanelError: the ErrorInfo the panel shows, for its action button. */
  private lastPanelError: ErrorInfo | null = null;

  /** How many rows the adapter holds — showEmptyState() is driven by this, not by the pixels. */
  @State loadedCount: number = 0;
  /** Page.isValid(currentNextPage): the pignate_footer row shows while more pages remain. */
  @State hasMoreItems: boolean = false;
  /** ThemeHelper.getItemViewMode() - the one copy lives in ViewModeResolver. */
  @State itemViewMode: ItemViewMode = ItemViewMode.LIST;
  /**
   * AppearanceSettingsFragmentPage publishes the chosen list_view_mode here right after it writes
   * the preference, so a page that is ALREADY drawn re-reads it instead of keeping the template it
   * was built with. @Watch never fires on init, so aboutToAppear's own read still stands.
   */
  @StorageProp('listViewMode') @Watch('setupItemViewMode')
  private listViewModeSignal: string = '';
  /** setUseMiniVariant(...) — false on this screen. */
  @State useMiniVariant: boolean = false;
  /** LocalItemListAdapter.useItemHandle — false outside BookmarkFragment. */
  @State useItemHandle: boolean = false;

  /** The Download entry's sheet, and the stream it was raised for. */
  @State downloadServiceId: number = 0;
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

  /** showInfoItemDialog(item): the long-press menu title and its entries. */
  @State menuTitle: string = '';
  @State menuActions: DialogAction[] = [];

  /** The default kiosk's own list URL, from the service's link-handler factory. */
  private url: string = '';
  /** currentNextPage — Page.isValid() decides whether loadMoreItems() may run. */
  private nextPage: Page | null = null;
  /** currentInfo; updateSelectedDefaultKiosk() wipes it so the new service really refetches. */
  private currentInfo: KioskInfo | null = null;
  /** currentWorker: a superseded load is DISPOSED, not rendered. */
  private currentWorker: Disposable | null = null;

  private historyRecordManager: HistoryRecordManager | null = null;
  private playlistManager: LocalPlaylistManager | null = null;
  /** The row the long-press menu is acting on. */
  private heldItem: StreamInfoItem | null = null;

  /** The playlists PlaylistAppendDialog lists; empty means the creation dialog instead. */
  @State appendList: PlaylistMetadataEntry[] = [];

  /**
   * PlaylistDialog.createCorrespondingDialog(): with playlists it appends, without any it goes
   * straight to creation. This screen - the app's home tab - had neither dialog:
   * openAppendPicker() filled a data source that a plain LocalItemDataSource field backed, so
   * nothing re-rendered and 'Add to playlist' did nothing at all. Same fix KioskFragmentPage
   * already carries.
   */
  private appendDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    // customStyle: the builder draws its own square, sized card. Without it the system
    // dialog container draws a rounded surface under the content and the corners the
    // builder sets are never visible.
    customStyle: true,
    builder: PlaylistAppendDialog({
      playlists: this.appendList,
      onSelected: (playlist: PlaylistMetadataEntry): void => {
        this.appendToPlaylist(playlist);
      },
      onNewPlaylist: (): void => {
        this.creationDialog.open();
      }
    })
  });

  private creationDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    customStyle: true,
    builder: PlaylistCreationDialog({
      name: '',
      onCreate: (name: string): void => {
        this.createPlaylistWithHeldItem(name);
      }
    })
  });

  /** itemView.setOnLongClickListener -> showInfoItemDialog(item). */
  private infoItemDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    builder: InfoItemDialog({ title: this.menuTitle, actions: this.menuActions })
  });

  /* //////////////////////////////////////////////////////////////////////////
  // Lifecycle
  ////////////////////////////////////////////////////////////////////////// */

  /** onCreate(): `if (serviceId < 0) { updateSelectedDefaultKiosk(); }`. */
  aboutToAppear(): void {
    this.setupItemViewMode();
    // super.onCreate(): KioskFragment records the preferred content country.
    this.contentCountry = Localization.getPreferredContentCountry();
    if (this.serviceId < 0) {
      this.updateSelectedDefaultKiosk();
    }
    this.startLoading(false);
  }

  /**
   * onResume(): when the app-wide selected service has changed, the in-flight worker is disposed,
   * the kiosk identity is re-resolved for the NEW service and reloadContent() runs.
   */
  onPageShow(): void {
    // super.onResume(): KioskFragment refetches when the preferred content country changed.
    const country: string = Localization.getPreferredContentCountry();
    if (this.contentCountry !== country) {
      this.contentCountry = country;
      this.reloadContent();
    }
    // useAsFrontPage && activity != null -> setTitle(kioskTranslatedName).
    this.whichKioskIsShown = getTranslatedKioskName(this.kioskId);

    this.onSelectedServiceChanged();
  }

  /** updateSelectedDefaultKiosk() + reloadContent(), but only when the service really changed. */
  private onSelectedServiceChanged(): void {
    if (this.serviceId !== DefaultKioskFragmentPage.selectedServiceId()) {
      this.disposeWorker();
      this.updateSelectedDefaultKiosk();
      this.reloadContent();
    }
  }

  aboutToDisappear(): void {
    // currentWorker.dispose(): a result still in flight must not touch a torn-down page.
    this.disposeWorker();
  }

  private disposeWorker(): void {
    const worker: Disposable | null = this.currentWorker;
    if (worker !== null) {
      worker.dispose();
      this.currentWorker = null;
    }
  }

  /**
   * DefaultKioskFragment.updateSelectedDefaultKiosk(), verbatim: the selected service decides the
   * kiosk, and the cached info + next page are wiped so the list really changes.
   */
  private updateSelectedDefaultKiosk(): void {
    try {
      this.serviceId = DefaultKioskFragmentPage.selectedServiceId();

      const service: StreamingService = NewPipe.getService(this.serviceId);
      const defaultKiosk: string | null = service.getKioskList().getDefaultKioskId();
      this.kioskId = defaultKiosk === null ? '' : defaultKiosk;
      this.url = service.getKioskList()
        .getListLinkHandlerFactoryByType(this.kioskId)
        .fromIdAsList(this.kioskId)
        .getUrl();

      this.whichKioskIsShown = getTranslatedKioskName(this.kioskId);

      this.currentInfo = null;
      this.nextPage = null;
      this.hasMoreItems = false;
    } catch (err) {
      // ExtractionException -> showError(REQUESTED_KIOSK, "Loading default kiosk for selected
      // service"): the error panel replaces the list before any load happens.
      this.handleError(ErrorInfo.fromThrowable(err as Error, UserAction.REQUESTED_KIOSK,
        'Loading default kiosk for selected service', this.serviceId));
    }
  }

  /** ServiceHelper.getSelectedServiceId(): the preference holds the service NAME. */
  private static selectedServiceId(): number {
    const name: string = AppPreferences.instance()
      .getStringResolvedSync(current_service_key, default_service_value);
    try {
      return NewPipe.getServiceByName(name).getServiceId();
    } catch (err) {
      return DEFAULT_FALLBACK_SERVICE_ID;
    }
  }

  /** ThemeHelper.getItemViewMode(): the user's LIST / GRID / CARD preference. */
  private setupItemViewMode(): void {
    const store: AppPreferences = AppPreferences.instance();
    const mode: string = store.getStringSync(list_view_mode_key,
      store.resolveDefault(list_view_mode_value));
    this.itemViewMode = resolveItemViewMode(mode);
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Load — inherited from BaseListInfoFragment / KioskFragment
  ////////////////////////////////////////////////////////////////////////// */

  /** startLoading(forceLoad): a new load disposes the previous one. */
  private startLoading(forceLoad: boolean): void {
    if (this.url.length === 0) {
      return;
    }
    this.disposeWorker();
    this.isLoading = true;
    this.hideErrorPanel();
    this.currentWorker = Observable
      .fromPromise(ExtractorHelper.getKioskInfo(this.serviceId, this.url, forceLoad))
      .subscribeCallbacks((info: KioskInfo): void => {
        this.handleResult(info);
      }, (error: Error): void => {
        this.handleError(ErrorInfo.fromThrowable(error, UserAction.REQUESTED_KIOSK, this.url,
          this.serviceId, this.url));
      });
  }

  /** handleResult(result): the adapter is REPLACED, and the next page decides the footer. */
  private handleResult(info: KioskInfo): void {
    this.currentInfo = info;
    this.serviceId = info.getServiceId();
    this.kioskItemsList.clearItems();
    this.kioskItemsList.addItems(info.getRelatedItems());
    this.loadedCount = this.kioskItemsList.totalCount();
    this.nextPage = info.getNextPage();
    this.hasMoreItems = Page.isValid(this.nextPage);
    this.isLoading = false;
    // ExtractorHelper.getItemsPageOrLogError() does not throw: PeerTube's kiosk extractor leaves
    // onFetchPage() empty and does all its I/O in getInitialPage(), so a failed request is
    // recorded on the Info and an EMPTY page comes back. The subscriber's error callback
    // therefore never fires and the screen fell through to its empty state - offline read as
    // "this kiosk has no videos". BaseListInfoFragment reads result.getErrors() on the view side
    // for exactly this reason. YouTube is unaffected because it fetches in fetchPage().
    const errors: Error[] = info.getErrors();
    if (this.loadedCount === 0 && errors.length > 0) {
      this.handleError(ErrorInfo.fromThrowables(errors, UserAction.REQUESTED_KIOSK, this.url,
        this.serviceId, this.url));
      return;
    }
    this.hideErrorPanel();
  }

  /** loadMoreItemsLogic() -> ExtractorHelper.getMoreKioskItems(serviceId, url, currentNextPage). */
  private loadMoreItems(): void {
    const nextPage: Page | null = this.nextPage;
    if (!this.hasMoreItems || this.isLoading || nextPage === null) {
      return;
    }
    this.disposeWorker();
    this.isLoading = true;
    this.currentWorker = Observable
      .fromPromise(ExtractorHelper.getMoreKioskItems(this.serviceId, this.url, nextPage))
      .subscribeCallbacks((page: InfoItemsPage<StreamInfoItem>): void => {
        this.kioskItemsList.addItems(page.getItems());
        this.loadedCount = this.kioskItemsList.totalCount();
        this.nextPage = page.getNextPage();
        this.hasMoreItems = Page.isValid(this.nextPage);
        this.isLoading = false;
      }, (error: Error): void => {
        this.handleError(ErrorInfo.fromThrowable(error, UserAction.REQUESTED_KIOSK, this.url,
          this.serviceId, this.url));
      });
  }

  /** onTabReselected(tab) -> itemsList.scrollToPosition(0). */
  private onTabReselected(): void {
    if (this.errorInfo === null) {
      this.listScroller.scrollEdge(Edge.Top);
    }
  }

  /** ErrorPanelHelper -> reloadContent() -> startLoading(true). */
  private reloadContent(): void {
    this.startLoading(true);
  }

  /**
   * BaseStateFragment.handleError(): the cached info is dropped so a retry really refetches,
   * then the panel replaces the content and the load ends. It takes the whole ErrorInfo, not
   * just its message — isReportable, recaptchaUrl and openInBrowserUrl are what decide whether
   * the panel gets its REPORT and OPEN IN BROWSER buttons at all.
   */
  private handleError(info: ErrorInfo): void {
    const message: string = info.message.formatArgs.length === 0
      ? Localization.getString(info.message.stringName)
      : Localization.getStringArgs(info.message.stringName, info.message.formatArgs);
    hilog.error(0x0000, TAG, 'default kiosk load failed: %{public}s', info.request);
    InfoCache.getInstance().clearCache();
    this.lastPanelError = info;
    this.errorInfo = message;
    // ErrorPanelHelper:101-107 - the recaptcha challenge takes the action button when there is
    // one, otherwise Report, and neither when the error is not worth reporting.
    this.errorActionLabel = info.recaptchaUrl !== null
      ? Localization.getString('recaptcha_solve')
      : (info.isReportable ? Localization.getString('error_snackbar_action') : '');
    this.openInBrowserUrl = info.openInBrowserUrl;
    this.isLoading = false;
  }

  /** ErrorPanelHelper.hide(): the panel's buttons go with its message. */
  private hideErrorPanel(): void {
    this.lastPanelError = null;
    this.errorInfo = null;
    this.errorActionLabel = '';
    this.openInBrowserUrl = null;
  }

  /** errorOpenInBrowser: ShareUtils.openUrlInBrowser(url). */
  private openErrorInBrowser(): void {
    const url: string | null = this.openInBrowserUrl;
    if (url !== null) {
      ServiceLocator.get().share.openUrlInBrowser(url);
    }
  }

  /** ErrorPanelHelper:101-107 showAndSetErrorButtonAction (recaptcha / report). */
  private runErrorAction(): void {
    const info: ErrorInfo | null = this.lastPanelError;
    if (info === null) {
      return;
    }
    const recaptchaUrl: string | null = info.recaptchaUrl;
    if (recaptchaUrl !== null) {
      const params: Record<string, Object> = { 'recaptcha_url': recaptchaUrl };
      router.pushUrl({ url: 'pages/ReCaptchaActivityPage', params: params });
      return;
    }
    if (info.isReportable) {
      ServiceLocator.get().errorReporter.openActivity(info);
    }
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Items
  ////////////////////////////////////////////////////////////////////////// */

  /** InfoListAdapter's OnClickGesture.selected: the route depends on the item TYPE. */
  private onItemSelected(item: InfoItem): void {
    if (item instanceof ChannelInfoItem) {
      router.pushUrl({
        url: 'pages/ChannelFragmentPage',
        params: new ItemParams(item.getServiceId(), item.getUrl(), item.getName())
      });
    } else if (item instanceof PlaylistInfoItem) {
      router.pushUrl({
        url: 'pages/PlaylistFragmentPage',
        params: new ItemParams(item.getServiceId(), item.getUrl(), item.getName())
      });
    } else {
      router.pushUrl({
        url: 'pages/VideoDetailFragmentPage',
        params: new ItemParams(item.getServiceId(), item.getUrl(), item.getName())
      });
    }
  }

  /** OnClickGesture.held -> showInfoItemDialog(infoItem). */
  private onItemHeld(item: InfoItem): void {
    if (!(item instanceof StreamInfoItem)) {
      return;
    }
    const stream: StreamInfoItem = item as StreamInfoItem;
    this.heldItem = stream;
    this.menuTitle = stream.getName();

    // InfoItemDialog.Builder owns the entry list and its order; this screen only says what each
    // entry does. It used to write out its own shorter list, which is how the port's menus drifted
    // apart from one another - see T-0118.
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
      // T-0197: this used to start the stream in the DOCKED player, on the reasoning that a
      // list screen carries no XComponent surface for PiP. It carries none by default - but
      // PopupPlayerSurface is exactly the surface a list mounts to get one, and four screens
      // already do it. Without it `prepare()` ran with `audioOnly` false and no surfaceId, so
      // AVPlayer had no render target and the decoder reported `width 0, height 0`: a popup entry
      // that played sound and drew nothing.
      // A burst of taps must open ONE popup: the surface's onLoad fires once, so a second
      // item set behind a mounted surface would simply never be played.
      if (this.popupSurfaceMounted) {
        return;
      }
      promptAction.showToast({ message: $r('app.string.popup_playing_toast'), duration: 2000 });
      this.popupServiceId = target.serviceId;
      this.popupUrl = target.url;
      this.popupSurfaceMounted = true;
    };
    handlers.onDownload = (): void => {
      this.downloadServiceId = target.serviceId;
      this.downloadUrl = target.url;
      this.showDownloadDialog = true;
    };
    handlers.onAddToPlaylist = (): void => {
      this.openAppendPicker();
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

  private async ensureLocalServices(): Promise<LocalPlaylistManager | null> {
    const existing: LocalPlaylistManager | null = this.playlistManager;
    if (existing !== null) {
      return existing;
    }
    try {
      const context: common.Context = getContext(this) as common.Context;
      const db: AppDatabase = await AppDatabase.getInstance(context);
      this.historyRecordManager = new HistoryRecordManager(db);
      const manager: LocalPlaylistManager = new LocalPlaylistManager(db);
      this.playlistManager = manager;
      return manager;
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.showSnackBarError(failure.message);
      return null;
    }
  }

  /** StreamDialogDefaultEntry.APPEND_PLAYLIST -> PlaylistAppendDialog over the local playlists. */
  private async openAppendPicker(): Promise<void> {
    const manager: LocalPlaylistManager | null = await this.ensureLocalServices();
    if (manager === null) {
      return;
    }
    const held: StreamInfoItem | null = this.heldItem;
    try {
      // getPlaylistDuplicates(streamUrl) rather than getPlaylists(): the rows then carry
      // timesStreamIsContained, which is what lets PlaylistAppendDialog grey out a
      // playlist that already holds this stream and refuse a second append.
      const playlists: PlaylistMetadataEntry[] = held === null
        ? await manager.getPlaylists()
        : await manager.getPlaylistDuplicates(held.getUrl());
      this.appendList = playlists;
      if (playlists.length === 0) {
        this.creationDialog.open();
      } else {
        this.appendDialog.open();
      }
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.showSnackBarError(failure.message);
    }
  }

  /** PlaylistCreationDialog's confirm: a new playlist carrying the stream that was held. */
  private async createPlaylistWithHeldItem(name: string): Promise<void> {
    const manager: LocalPlaylistManager | null = this.playlistManager;
    const item: StreamInfoItem | null = this.heldItem;
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
      this.showSnackBarError(failure.message);
    }
  }

  /** NavigationHelper.playOnBackgroundPlayer(): PlayerService, in place - the list stays up. */
  private async startPlayer(item: StreamInfoItem, audioOnly: boolean): Promise<void> {
    try {
      const info: StreamInfo = await ServiceLocator.get().backgroundWork.runWithBackgroundTask(
        BackgroundWorkMode.DATA_TRANSFER,
        (): Promise<StreamInfo> =>
          ExtractorHelper.getStreamInfo(item.getServiceId(), item.getUrl(), false));
      await PlayerService.getInstance().prepare(info, audioOnly,
      audioOnly ? 0 : PlayerPrefs.defaultPlaybackHeight());
      // Without this there is no AVSession and no continuous task: the system shows no media
      // controls and stops the audio as soon as the app is backgrounded.
      await MediaSessionService.getInstance()
        .startDetached(getContext(this) as common.UIAbilityContext, info);
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      promptAction.showToast({ message: failure.message, duration: 2000 });
    }
  }


  /** StreamDialogDefaultEntry.MARK_AS_WATCHED -> HistoryRecordManager.markAsWatched(item). */
  private async markAsWatched(item: StreamInfoItem): Promise<void> {
    if (await this.ensureLocalServices() === null) {
      return;
    }
    const history: HistoryRecordManager | null = this.historyRecordManager;
    if (history === null) {
      return;
    }
    try {
      await history.markAsWatched(item);
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.showSnackBarError(failure.message);
    }
  }

  private showSnackBarError(message: string): void {
    hilog.error(0x0000, TAG, '%{public}s', message);
    promptAction.showToast({ message: message, duration: 3000 });
  }

  /**
   * showEmptyState(): @string/no_live_streams for the media.ccc.de live kiosk, the inherited
   * @string/no_streams for SoundCloud, otherwise @string/no_videos — the branch reads the
   * RESOLVED kiosk identity (kioskId + serviceId), which is what this screen decides.
   */
  @Builder
  emptyStateMessage() {
    if (this.kioskId === LIVE_STREAM_KIOSK_ID && this.serviceId === MediaCCC.getServiceId()) {
      Text($r('app.string.no_live_streams'))
        .id('empty_state_message')
        .fontSize(24)
        .fontColor(C_ON_SURFACE)
        .textAlign(TextAlign.Center)
    } else if (this.serviceId === SoundCloud.getServiceId()) {
      Text($r('app.string.no_streams'))
        .id('empty_state_message')
        .fontSize(24)
        .fontColor(C_ON_SURFACE)
        .textAlign(TextAlign.Center)
    } else {
      Text($r('app.string.no_videos'))
        .id('empty_state_message')
        .fontSize(24)
        .fontColor(C_ON_SURFACE)
        .textAlign(TextAlign.Center)
    }
  }

  /** getListHeaderSupplier() returns null for a kiosk, so this slot never renders. */
  @Builder
  listHeader() {
    HeaderFooterHolder()
  }

  /** onCreateViewHolder(FOOTER_TYPE): the pignate_footer indeterminate row. */
  @Builder
  listFooter() {
    HFHolder() {
      LoadingProgress()
        .id('pignate_footer')
        .width(32)
        .height(32)
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
      // onCreateViewHolder()'s default: an item type no holder claims.
      FallbackViewHolder()
    }
  }

  /*//////////////////////////////////////////////////////////////////////////
  // InfoItemDialog -> "append to playlist": the local-playlist picker's rows.
  //////////////////////////////////////////////////////////////////////////*/

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

  /** PlaylistItemHolder: the views every playlist row shares (super.updateFromItem()). */
  @Builder
  playlistBody(item: PlaylistLocalItem) {
    PlaylistItemHolder({
      thumbnailUrl: item.thumbnailUrl,
      title: item.orderingName,
      showUploader: item.localItemType === LocalItemType.PLAYLIST_REMOTE_ITEM
    })
  }

  /** PlaylistAppendDialog's row tap: append the held stream to the chosen playlist. */
  private async appendToPlaylist(playlist: PlaylistLocalItem): Promise<void> {
    const manager: LocalPlaylistManager | null = this.playlistManager;
    const item: StreamInfoItem | null = this.heldItem;
    this.appendList = [];
    this.infoItemDialog.close();
    if (manager === null || item === null) {
      return;
    }
    try {
      await manager.appendToPlaylist(playlist.uid, [StreamEntity.fromInfoItem(item)]);
      // PlaylistAppendDialog.onPlaylistSelected() ends in a Toast on the reference - the string
      // `playlist_add_stream_success` ("Playlisted") was already in this port's resources and had
      // no caller anywhere, so an append finished silently. Every entry point that appends says
      // so, not just the one the case happens to name.
      promptAction.showToast({ message: playlistAppendToast(playlist),
        duration: 2000 });
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.showSnackBarError(failure.message);
    }
  }


  /** PopupPlayerSurface is mounted only while a popup is being opened or is open (T-0197). */
  @State popupSurfaceMounted: boolean = false;
  /** The row the popup was raised for; read once the surface is bound. */
  private popupServiceId: number = 0;
  private popupUrl: string = '';
  private popupSurfaceController: XComponentController = new XComponentController();

  /** The surface is bound: the shared launcher prepares the stream and hands it to PiP. */
  private async onPopupSurfaceReady(): Promise<void> {
    const url: string = this.popupUrl;
    if (url.length === 0) {
      return;
    }
    this.popupUrl = '';
    await openPopupOnSurface(getContext(this) as common.UIAbilityContext, this.popupServiceId,
      url, this.popupSurfaceController, (): void => {
        this.popupSurfaceMounted = false;
      });
  }

  build() {
    Column() {
      // setTitle(kioskTranslatedName): WHICH kiosk is shown, from the selected service's default
      // kiosk id — never a literal. No Up arrow: this fragment is always the front-page tab.
      // Widget.AppCompat.Toolbar.Title: 20sp medium white on ?attr/colorPrimary, in a
      // ?attr/actionBarSize band. A front-page kiosk has no navigation button, so the title
      // keeps the 16dp inset itself and is the toolbar's only child.
      if (!this.shellOwnsToolbar) {
        Text(this.whichKioskIsShown)
          .id('kiosk_title')
          .width('100%')
          .height(56)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_primary'))
          .align(Alignment.Start)
          .padding({ left: 16, right: 16 })
          .backgroundColor(servicePrimaryColor(this.serviceId))
      }
      Stack() {
        // BaseListFragment.showError(): `showListFooter(false); itemsList.setVisibility(GONE)`
        // before the panel is shown - the panel REPLACES the list rather than covering it, which
        // is what the kiosk error case asks for. Without the gate a failure during pagination
        // drew the panel over the rows already on screen.
        if (this.errorInfo === null) {
          InfoListAdapter({
            dataSource: this.kioskItemsList,
            scroller: this.listScroller,
            viewMode: this.itemViewMode,
            // getListHeaderSupplier() == null for a kiosk.
            hasHeader: false,
            showFooter: this.hasMoreItems,
            onReachEnd: (): void => {
              this.loadMoreItems();
            },
            header: (): void => {
              this.listHeader();
            },
            footer: (): void => {
              this.listFooter();
            },
            row: (item: InfoItem): void => {
              this.itemRow(item);
            }
          })
        }

        if (this.isLoading) {
          LoadingProgress()
            .id('loading_progress_bar')
            .width(48)
            .height(48)
            .color(servicePrimaryColor(this.serviceId))
        }

        // showError(...): the error_panel include, with its retry button.
        if (this.errorInfo !== null) {
          Column() {
            // error_panel.xml: 16sp bold, centred, in a 16dp-padded column.
            Text(this.errorInfo)
              .id('error_message_view')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor(C_ON_SURFACE)
              .textAlign(TextAlign.Center)

            // ServiceColoredButton: colorButtonNormal = ?attr/colorPrimary, white label.
            // error_panel.xml orders the actions REPORT, RETRY, OPEN IN BROWSER, and the reference
            // build shows exactly that on a reportable failure - device-checked on an invalid video
            // link, which renders "Could not parse website" above REPORT / RETRY / OPEN IN BROWSER.
            // This page had retry first, so the report action sat in the middle. A network failure
            // carries no action label and still shows only RETRY and OPEN IN BROWSER, as it should.
            if (this.errorActionLabel.length > 0) {
              Button(this.errorActionLabel.toUpperCase())
                .id('error_button_action')
                .type(ButtonType.Normal)
                .backgroundColor(servicePrimaryColor(this.serviceId))
                .fontSize(16)
                .fontColor($r('app.color.subscribe_text_color'))
                .borderRadius(2)
                .margin({ top: 4 })
                .padding({ left: 16, right: 16, top: 6, bottom: 6 })
                .onClick(() => {
                  this.runErrorAction();
                })
            }
            Button(Localization.buttonLabel('retry'))
              .id('error_retry_button')
              .type(ButtonType.Normal)
              .backgroundColor(servicePrimaryColor(this.serviceId))
              .fontSize(16)
              .fontColor($r('app.color.subscribe_text_color'))
              .borderRadius(2)
              .margin({ top: 4 })
              .padding({ left: 16, right: 16, top: 6, bottom: 6 })
              .onClick(() => {
                this.reloadContent();
              })
            if (this.openInBrowserUrl !== null) {
              Button(Localization.buttonLabel('open_in_browser'))
                .id('error_open_in_browser')
                .type(ButtonType.Normal)
                .backgroundColor(servicePrimaryColor(this.serviceId))
                .fontSize(16)
                .fontColor($r('app.color.subscribe_text_color'))
                .borderRadius(2)
                .margin({ top: 4 })
                .padding({ left: 16, right: 16, top: 6, bottom: 6 })
                .onClick(() => {
                  this.openErrorInBrowser();
                })
            }
          }
          .id('error_panel')
          .padding(16)
          .alignItems(HorizontalAlign.Center)
        }

        // showEmptyState() — rendered INSTEAD of content, never beside it.
        if (!this.isLoading && this.errorInfo === null && this.loadedCount === 0) {
          Column() {
            // fragment_kiosk.xml owns its empty view: monospace 35sp, 10dp above the message.
            Text('(╯°-°)╯')
              .fontFamily('monospace')
              .fontSize(35)
              .fontColor(C_ON_SURFACE)
              .margin({ bottom: 10 })
            this.emptyStateMessage()
          }
          .id('empty_state_view')
          // android:layout_centerInParent + android:paddingTop="90dp".
          .padding({ top: 90 })
          .alignItems(HorizontalAlign.Center)
        }
      }
      .width('100%')
      .layoutWeight(1)

      // fragment_player_holder, docked. This screen is a pushUrl target, so MainActivityPage's own
      // bar is underneath it in the stack and cannot draw here; the bar has to be mounted per page.
      // Last child of the root Column, so it shortens the layoutWeight(1) list instead of covering
      // its last row. Visibility.None while the player is IDLE gives that height straight back.
      // Skipped when the shell embeds this screen as a child, where the shell's own bar is showing.
      if (!this.hostedInMainShell) {
        MiniPlayerBar({ idPrefix: 'default_kiosk_' })
      }

      // The popup's surface, mounted only while one is being opened or is open. 1x1 and
      // transparent: PiP composites the video into its own window (T-0197).
      if (this.popupSurfaceMounted) {
        PopupPlayerSurface({
          controller: this.popupSurfaceController,
          onSurfaceReady: (): void => {
            this.onPopupSurfaceReady();
          }
        })
      }
    }
    .id('DefaultKioskFragmentPage')
    .width('100%')
    .height('100%')
    // ?attr/windowBackground = @color/light_background_color in the light theme.
    .backgroundColor(themedBackground(this.blackTheme))
  }
}
