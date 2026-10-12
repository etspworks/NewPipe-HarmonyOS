/**
 * S3 — PlaylistFragment (screen_playlist), structure from fragment_playlist.xml +
 * playlist_header.xml + playlist_control.xml + menu_playlist.xml.
 *
 * The REMOTE playlist screen (LocalPlaylistFragment is a different class). Its whole header —
 * title, uploader row, stream count and running total duration, collapsible description and the
 * three play buttons — is ONE adapter HEADER ROW supplied by getListHeaderSupplier(), so it
 * SCROLLS WITH THE CONTENT; it is not a fixed bar and not a collapsing toolbar.
 *
 * Rows use the MINI stream variant: this is the only screen that sets setUseMiniVariant(true), so
 * a row has no views/date line. Paginated: scroll-to-bottom loads the next page and the total
 * duration ACCUMULATES across pages, rendered in the "at least" form while more pages remain.
 *
 * The bookmark menu item is driven by a Room flowable (PlaylistRemoteEntity) and is INERT until
 * it first emits — that is the source's behaviour, not a defect.
 *
 * S5 — styled from results/traversal-source/pages/fragment_PlaylistFragment/base.png plus the
 * source layouts (playlist_header.xml, playlist_control.xml, error_panel.xml) and the app-level
 * style baseline in state.json generation.styleBaseline. Style only: the stream rows are
 * InfoListAdapter's holders, owned and styled by another screen.
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
  startStreamInPlace, enqueueNextStream, enqueueAllOnPlayer,
  showHoldToAppendTip } from '../common/util/StreamRowActions';
import { PlaylistAppendDialog } from '../components/PlaylistAppendDialog';
import { PlaylistCreationDialog } from '../components/PlaylistCreationDialog';
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
import { BackgroundWorkMode } from '../common/background/BackgroundWork';
import { PlayerService } from '../common/player/PlayerService';
import { PlayerPrefs } from '../common/player/PlayerPrefs';

import { PlayQueueItem } from '../model/app/PlayQueueItem';
import { SimplePlayQueue, setCurrentPlayQueue } from '../model/app/PlayQueue';
import { MediaSessionService } from '../common/player/MediaSessionService';
import { PlaylistInfo } from '../model/extractor/PlaylistInfo';
import { Description, DESCRIPTION_HTML } from '../model/extractor/Description';
import { htmlToPlainText } from './DescriptionFragmentPage';
import { Page } from '../model/extractor/Page';
import { InfoItemsPage } from '../model/extractor/ListExtractorInfoItemsPage';
import { YouTube, SoundCloud } from '../common/extractor/ServiceRegistry';
import {
  isYoutubeMixId,
  isYoutubeMusicMixId
} from '../common/extractor/services/youtube/YoutubeParsingHelper';
import { AppDatabase } from '../common/db/AppDatabase';
import { LocalPlaylistManager, RemotePlaylistManager, playlistAppendToast } from '../common/db/PlaylistManager';
import { PlaylistRemoteEntity } from '../model/db/entity/PlaylistRemoteEntity';
import { PlaylistMetadataEntry } from '../model/db/view/PlaylistMetadataEntry';
import { StreamEntity } from '../model/db/entity/StreamEntity';
import { HistoryRecordManager } from '../common/db/HistoryRecordManager';
import { ServiceLocator } from '../common/di/ServiceLocator';
import { ShareUtils } from '../common/share/ShareUtils';
import { InfoCache } from '../common/extractor/InfoCache';
import { Disposable, Observable } from '../common/rx/Rx';
import { DeepLinkRouter, RoutingDecision, ResolvedLink } from '../common/router/DeepLinkRouter';
import { Localization } from '../common/i18n/Localization';
import { servicePrimaryColor, DIALOG_MASK_COLOR } from '../common/theme/ServiceTheme';
import { choosePreferredImage } from '../common/image/ImageLoader';
import { AppPreferences } from '../common/prefs/Preferences';
import {
  list_view_mode_key,
  list_view_mode_value,
  list_view_mode_card_key
} from '../common/prefs/SettingsKeys';
import { MiniPlayerBar } from '../components/MiniPlayerBar';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

/** A Toast.LENGTH_SHORT: the tip follows the control's own toast instead of replacing it. */
const HOLD_TIP_AFTER_TOAST_MS: number = 2100;
const TAG: string = 'PlaylistFragmentPage';


/**
 * The fragment arguments NavigationHelper passes on: openVideoDetailFragment(serviceId, url,
 * title) and openChannelFragment(serviceId, url, name) take the same three. ArkTS has no untyped
 * object literals, so the router params are a declared class.
 */
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
 * playOnMainPlayer and playOnPopupPlayer both open VideoDetailFragmentPage - the one page that
 * owns a player surface - and `popup` is the ONLY thing that differs between them. It is also the
 * only key that page reads back (readArguments(): params['popup']), so it is the only flag these
 * params carry. The `playerType` string that used to sit here was read by nobody, and the popup
 * control bypassed this class entirely with an untyped object literal.
 */
class PlayerParams {
  serviceId: number;
  url: string;
  name: string;
  popup: boolean;

  constructor(serviceId: number, url: string, name: string, popup: boolean) {
    this.serviceId = serviceId;
    this.url = url;
    this.name = name;
    this.popup = popup;
  }
}

/* TextEllipsizer(playlistDescription, 5, service): five lines collapsed. S5 owns the sizes. */
const DESCRIPTION_LINES_COLLAPSED: number = 5;
const DESCRIPTION_LINES_EXPANDED: number = 1000;
/**
 * TextEllipsizer decides `canBeEllipsized` from the laid-out line count, which ArkUI does not
 * expose to the page. The description is treated as ellipsizable past what five collapsed lines
 * can hold; a shorter one renders in full with no toggle, as the source does.
 */
const DESCRIPTION_ELLIPSIZE_THRESHOLD: number = 250;
/** Localization.getDurationString(duration, isDurationComplete, showDurationPrefix=true). */
const DURATION_PREFIX: string = '⏱ ';
const AVATAR_SIZE: number = 24;
const CTRL_ICON_SIZE: number = 20;

/* S5 — baseline tokens (state.json generation.styleBaseline, source S0004). */
const C_ON_SURFACE: Resource = $r('app.color.on_surface');
const C_SECONDARY: Resource = $r('app.color.on_surface_variant');
/* playlist_header.xml / playlist_control.xml metrics. */
const HEADER_PADDING: number = 12;
const META_HEIGHT: number = 28;
const CTRL_HEIGHT: number = 50;
const CTRL_SEPARATOR_MARGIN: number = 10;
const SUBTEXT_SIZE: number = 12;

/**
 * The reference's toolbar overflows are flat white rectangles with square corners, anchored at
 * the icon - measured on three of its screens (Play queue, Subscriptions, History), all at
 * x 528..1020 of 1080. ArkUI's default menu is a rounded pale-gradient bubble with a tail.
 */
const SQUARE_MENU_CORNERS: MenuOptions = { borderRadius: 0 };

@Entry
@Component
export struct PlaylistFragmentPage {
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
  /** infoListAdapter <- PlaylistInfo.relatedItems, appended page by page. */
  /**
   * ThemeHelper.setTheme(context, ServiceHelper.getSelectedServiceId(context)) swaps the whole
   * ACTIVITY theme, and a pushed detail fragment lives in that same activity - so every
   * ?attr/colorPrimary on this screen follows the selected service upstream, exactly as the
   * kiosk shell behind it does. Naming the YouTube colour here left this page's toolbar red
   * over a Bandcamp-cyan shell.
   */
  @StorageProp('mainSelectedServiceId') private activeServiceId: number = 0;

  @State streamList: InfoItemDataSource = new InfoItemDataSource();
  /** The append-to-playlist picker's list (PlaylistAppendDialog). */
  private appendPlaylists: LocalItemDataSource = new LocalItemDataSource();

  /** headerBinding.playlistTitleView.setText(title); setTitle(title) writes the same value. */
  @State headerTitle: string = '';
  /** result.getUploaderName(), or @string/playlist_no_uploader when empty. */
  @State uploaderName: string = '';
  /** CoilHelper.loadAvatar(result.getUploaderAvatars()). */
  @State uploaderAvatar: string = '';
  /** TextUtils.isEmpty(getUploaderUrl()) leaves the uploader row NON-clickable. */
  @State uploaderUrl: string = '';
  /** concatenateStrings(localizeStreamCount(n), getDurationString(total, isDurationComplete)). */
  @State streamCountAndTotalDuration: string = '';
  /** TextEllipsizer(playlistDescription, 5, service).setContent(result.getDescription()). */
  @State description: string = '';
  /** The ellipsizer's expanded flag — the read-more toggle swaps show_more / show_less. */
  @State descriptionExpanded: boolean = false;
  /** canBeEllipsized == false hides the toggle and renders the description in full. */
  @State descriptionEllipsizable: boolean = false;
  /** remotePlaylistManager.getPlaylist(result): null -> ic_playlist_add, else _add_check. */
  @State bookmarkMenuState: boolean = false;
  /** isBookmarkButtonReady — the item is INERT until the DB flowable has emitted once. */
  @State isBookmarkButtonReady: boolean = false;
  /** YoutubeParsingHelper.isYoutubeMixId / isYoutubeMusicMixId: a square ic_radio avatar. */
  @State isYoutubeMix: boolean = false;
  /** !result.hasNextPage(): the accumulated duration stops rendering the "at least" form. */
  @State isDurationComplete: boolean = false;

  @State isLoading: boolean = true;
  @State errorInfo: string | null = null;
  @State loadedCount: number = 0;
  /** Page.isValid(currentNextPage) — the pignate_footer row while more pages remain. */
  @State hasMoreItems: boolean = false;
  /** ThemeHelper.getItemViewMode(); rows are MINI on this screen whatever the mode's variant. */
  @State itemViewMode: ItemViewMode = ItemViewMode.LIST;
  /**
   * AppearanceSettingsFragmentPage publishes the chosen list_view_mode here right after it writes
   * the preference, so a page that is ALREADY drawn re-reads it instead of keeping the template it
   * was built with. @Watch never fires on init, so aboutToAppear's own read still stands.
   */
  @StorageProp('listViewMode') @Watch('setupItemViewMode')
  private listViewModeSignal: string = '';
  /** setUseMiniVariant(true) — the one screen that does. */
  @State useMiniVariant: boolean = true;
  /** LocalItemListAdapter.useItemHandle — false outside BookmarkFragment. */
  @State useItemHandle: boolean = false;

  /** showInfoItemDialog(item): the long-press menu title and entries. */
  @State menuTitle: string = '';
  @State menuActions: DialogAction[] = [];
  /** PlaylistDialog.createCorrespondingDialog(): the append branch needs a playlist to exist. */
  @State hasPlaylists: boolean = false;
  @State pickerPlaylists: PlaylistMetadataEntry[] = [];

  /** setInitialData(serviceId, url, name). */
  /* -1, not 0: YouTube IS service id 0, so a 0 default is indistinguishable from a real
   * YouTube argument and every YouTube playlist would be re-resolved as a deep link. */
  private serviceId: number = -1;
  private url: string = '';
  private name: string = '';
  /** currentInfo — handleResult() keeps it for share, bookmark and the append dialog. */
  private currentInfo: PlaylistInfo | null = null;
  /** currentNextPage. */
  private nextPage: Page | null = null;
  /** streamCount + playlistOverallDurationSeconds, accumulated across pages. */
  private streamCount: number = 0;
  private overallDurationSeconds: number = 0;
  /** playlistEntity — null until the bookmark row is read, and null again once removed. */
  private playlistEntity: PlaylistRemoteEntity | null = null;
  private remotePlaylistManager: RemotePlaylistManager | null = null;
  private localPlaylistManager: LocalPlaylistManager | null = null;
  private historyRecordManager: HistoryRecordManager | null = null;
  /** BaseListInfoFragment.currentWorker: a superseded load is DISPOSED, not rendered. */
  private currentWorker: Disposable | null = null;
  /** The streams the append dialog and START_HERE_ON_BACKGROUND act on. */
  private heldItem: StreamInfoItem | null = null;
  /**
   * The three play controls commit on the FIRST tap. A second one landing before the first had
   * settled pushed a second VideoDetailFragmentPage onto the router stack, or toasted and
   * prepared the same stream twice. Cleared at the end of startPlayer() for the control that
   * stays on this screen, and by onPageShow() for the two that navigate away.
   */
  private launching: boolean = false;
  /** Likewise for the share panel: a second tap raised a second sheet on top of the first. */
  private sharePending: boolean = false;

  /** Long-press: the standard InfoItemDialog EXTENDED with START_HERE_ON_BACKGROUND. */
  private infoItemDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    builder: InfoItemDialog({ title: this.menuTitle, actions: this.menuActions })
  });

  private appendDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    // customStyle: the builder draws its own square, sized card. Without it the system
    // dialog container draws a rounded surface under the content and the corners the
    // builder sets are never visible.
    customStyle: true,
    builder: PlaylistAppendDialog({
      playlists: this.pickerPlaylists,
      onSelected: (playlist: PlaylistMetadataEntry): void => {
        this.appendStreamsTo(playlist.uid, playlist);
      },
      onNewPlaylist: (): void => {
        this.creationDialog.open();
      }
    })
  });

  private creationDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    // customStyle: the builder draws its own square, sized card. Without it the system
    // dialog container draws a rounded surface under the content and the corners the
    // builder sets are never visible.
    customStyle: true,
    builder: PlaylistCreationDialog({
      name: '',
      onCreate: (name: string): void => {
        this.createPlaylistFromStreams(name);
      }
    })
  });

  /* //////////////////////////////////////////////////////////////////////////
  // Lifecycle
  ////////////////////////////////////////////////////////////////////////// */

  aboutToAppear(): void {
    this.readArguments();
    // setTitle(name): the argument paints before the network answers.
    this.headerTitle = this.name;
    this.setupItemViewMode();
    // A deep-link launch carries only the URI; RouterActivity is what turns one into
    // (serviceId, url), so without a serviceId that resolution has to happen here.
    if (this.serviceId < 0 && this.url.length > 0) {
      this.resolveDeepLinkThenLoad();
    } else {
      this.startLoading(false);
    }
  }

  /**
   * The two play controls that navigate cannot clear `launching` themselves - they are gone by
   * the time the route settles. Being back on top IS the signal that the launch they started is
   * over, so the controls are re-armed here.
   */
  onPageShow(): void {
    this.launching = false;
  }

  /** onDestroyView()/onDestroy(): the bookmark reactor is cancelled and the load abandoned. */
  aboutToDisappear(): void {
    this.disposeWorker();
    this.isBookmarkButtonReady = false;
  }

  private disposeWorker(): void {
    const worker: Disposable | null = this.currentWorker;
    if (worker !== null) {
      worker.dispose();
      this.currentWorker = null;
    }
  }

  /** RouterActivity.handleUrl(url) for the PLAYLIST link type, on the way in. */
  private resolveDeepLinkThenLoad(): void {
    const deepLink: DeepLinkRouter = ServiceLocator.get().deepLinkRouter;
    deepLink.resolve(this.url)
      .then((decision: RoutingDecision): void => {
        const link: ResolvedLink | null = decision.link;
        if (link !== null) {
          this.serviceId = link.serviceId;
          this.url = link.url;
        }
        this.startLoading(false);
      })
      .catch((err: BusinessError): void => {
        this.handleError(err.message);
      });
  }

  /** PlaylistFragment.getInstance(serviceId, url, name). */
  private readArguments(): void {
    const params: Record<string, Object> | undefined =
      router.getParams() as Record<string, Object> | undefined;
    if (params === undefined || params === null) {
      return;
    }
    const sid: Object | undefined = params['serviceId'];
    if (sid !== undefined && sid !== null) {
      this.serviceId = Number(sid.toString());
    }
    const playlistUrl: Object | undefined = params['url'];
    if (playlistUrl !== undefined && playlistUrl !== null) {
      this.url = playlistUrl.toString();
    }
    const playlistName: Object | undefined = params['name'];
    if (playlistName !== undefined && playlistName !== null) {
      this.name = playlistName.toString();
    }
  }

  /** ThemeHelper.getItemViewMode(); the MINI variant is forced on top of it here. */
  private setupItemViewMode(): void {
    const store: AppPreferences = AppPreferences.instance();
    const mode: string = store.getStringSync(list_view_mode_key,
      store.resolveDefault(list_view_mode_value));
    this.itemViewMode = resolveItemViewMode(mode);
  }

  private async ensureServices(): Promise<RemotePlaylistManager | null> {
    const existing: RemotePlaylistManager | null = this.remotePlaylistManager;
    if (existing !== null) {
      return existing;
    }
    try {
      const context: common.Context = getContext(this) as common.Context;
      const db: AppDatabase = await AppDatabase.getInstance(context);
      const manager: RemotePlaylistManager = new RemotePlaylistManager(db);
      this.remotePlaylistManager = manager;
      this.localPlaylistManager = new LocalPlaylistManager(db);
      this.historyRecordManager = new HistoryRecordManager(db);
      return manager;
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.showSnackBarError(failure.message);
      return null;
    }
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Load and handle
  ////////////////////////////////////////////////////////////////////////// */

  /**
   * startLoading(forceLoad): currentWorker = loadResult(forceLoad).subscribe(handleResult,
   * onError) - a new load disposes the previous one.
   */
  private startLoading(forceLoad: boolean): void {
    if (this.url.length === 0) {
      // PlaylistFragment.getInstance(serviceId, url, name) is the ONLY way the source ever
      // constructs this screen, so with no url there is no playlist to load and nothing to
      // fabricate one from. Returning here used to leave isLoading true for ever — a spinner
      // that never resolves, with the header bound to empty values behind it. The source's
      // BaseStateFragment answers an unusable load with showError(), so do that instead.
      // NOT `handleError`: that one logs at hilog.error, which is the app saying a load it
      // attempted FAILED. Nothing was attempted here — the page was opened with no arguments,
      // which the source cannot do at all (getInstance always carries a url). Logging it as an
      // app error made a launch with no arguments indistinguishable from a real load failure.
      const context: common.Context = getContext(this) as common.Context;
      hilog.info(0x0000, TAG, 'no playlist url in the launch arguments — showing the error state');
      InfoCache.getInstance().clearCache();
      this.errorInfo = context.resourceManager.getStringSync($r('app.string.general_error').id);
      this.isLoading = false;
      return;
    }
    this.disposeWorker();
    this.isLoading = true;
    this.errorInfo = null;
    this.currentWorker = Observable
      .fromPromise(ExtractorHelper.getPlaylistInfo(this.serviceId, this.url, forceLoad))
      .subscribeCallbacks((info: PlaylistInfo): void => {
        this.handleResult(info);
      }, (error: Error): void => {
        this.handleError(error.message);
      });
  }

  /** handleResult(result): every header binding this screen has, from the PlaylistInfo. */
  private handleResult(info: PlaylistInfo): void {
    this.currentInfo = info;
    this.serviceId = info.getServiceId();
    this.headerTitle = info.getName();

    this.streamList.clearItems();
    this.streamList.addItems(info.getRelatedItems());
    this.loadedCount = this.streamList.totalCount();
    this.nextPage = info.getNextPage();
    this.hasMoreItems = Page.isValid(this.nextPage);

    // The uploader row: an empty NAME shows @string/playlist_no_uploader, and an empty URL
    // leaves the row non-clickable even when the name is there.
    this.uploaderName = info.getUploaderName();
    this.uploaderUrl = info.getUploaderUrl();

    // An auto-generated YouTube (music) mix has no channel avatar — a square ic_radio is shown.
    this.isYoutubeMix = info.getServiceId() === YouTube.getServiceId()
      && (isYoutubeMixId(info.getId()) || isYoutubeMusicMixId(info.getId()));
    const avatar: string | null = choosePreferredImage(info.getUploaderAvatars());
    this.uploaderAvatar = avatar === null ? '' : avatar;

    this.streamCount = info.getStreamCount();
    this.overallDurationSeconds = 0;
    this.setStreamCountAndOverallDuration(info.getRelatedItems(), !Page.isValid(this.nextPage));

    // description == null / EMPTY_DESCRIPTION / blank -> both description views are GONE.
    const description: Description = info.getDescription();
    // Description.getType() decides how the body is rendered. Bandcamp returns the album's
    // about/credits/license blocks as raw HTML (DESCRIPTION_HTML), and it was going straight
    // into a Text, so the markup itself was on screen - <br>, and a trailing
    // <span class="cc-icons commercial"></span> before "all rights reserved".
    // DescriptionFragmentPage already does this for the stream description.
    const content: string = description.getType() === DESCRIPTION_HTML
      ? htmlToPlainText(description.getContent()) : description.getContent();
    if (description !== Description.EMPTY_DESCRIPTION && content.trim().length > 0) {
      this.description = content;
      // TextEllipsizer.setOnContentChanged(canBeEllipsized): the toggle exists only when the
      // text really overflows the five collapsed lines.
      this.descriptionEllipsizable = content.length > DESCRIPTION_ELLIPSIZE_THRESHOLD;
    } else {
      this.description = '';
      this.descriptionEllipsizable = false;
    }

    const errors: Error[] = info.getErrors();
    if (errors.length > 0) {
      this.showSnackBarError(errors[errors.length - 1].message);
    }

    this.isLoading = false;
    this.errorInfo = null;
    this.loadBookmarkState(info);
  }

  /** handleNextItems(result): the accumulated duration is completed by the LAST page. */
  private loadMoreItems(): void {
    const nextPage: Page | null = this.nextPage;
    if (!this.hasMoreItems || this.isLoading || nextPage === null) {
      return;
    }
    this.disposeWorker();
    this.isLoading = true;
    this.currentWorker = Observable
      .fromPromise(ExtractorHelper.getMorePlaylistItems(this.serviceId, this.url, nextPage))
      .subscribeCallbacks((page: InfoItemsPage<StreamInfoItem>): void => {
        this.streamList.addItems(page.getItems());
        this.loadedCount = this.streamList.totalCount();
        this.nextPage = page.getNextPage();
        this.hasMoreItems = Page.isValid(this.nextPage);
        this.setStreamCountAndOverallDuration(page.getItems(), !page.hasNextPage());
        this.isLoading = false;
      }, (error: Error): void => {
        this.handleError(error.message);
      });
  }

  /**
   * setStreamCountAndOverallDuration(list, isDurationComplete): the duration ACCUMULATES over
   * every loaded page; the "+" the incomplete form carries is added at render time.
   */
  private setStreamCountAndOverallDuration(items: StreamInfoItem[], isComplete: boolean): void {
    for (const item of items) {
      this.overallDurationSeconds += item.duration;
    }
    this.isDurationComplete = isComplete;
    this.streamCountAndTotalDuration = Localization.concatenateStrings([
      Localization.localizeStreamCount(this.streamCount),
      DURATION_PREFIX + Localization.getDurationString(this.overallDurationSeconds)
    ]);
  }

  /** BaseStateFragment.handleError(): the cached info is dropped, then the panel is shown. */
  private handleError(message: string): void {
    hilog.error(0x0000, TAG, 'playlist load failed: %{public}s', message);
    InfoCache.getInstance().clearCache();
    this.errorInfo = message;
    this.isLoading = false;
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Bookmark
  ////////////////////////////////////////////////////////////////////////// */

  /**
   * remotePlaylistManager.getPlaylist(result) -> getPlaylistBookmarkSubscriber(): the menu item
   * is INERT until this has answered once.
   */
  private async loadBookmarkState(info: PlaylistInfo): Promise<void> {
    const manager: RemotePlaylistManager | null = await this.ensureServices();
    if (manager === null) {
      return;
    }
    try {
      const rows: PlaylistRemoteEntity[] = await manager.getPlaylistOf(info);
      this.playlistEntity = rows.length === 0 ? null : rows[0];
      this.bookmarkMenuState = this.playlistEntity !== null;
      this.isBookmarkButtonReady = true;
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      hilog.warn(0x0000, TAG, 'bookmark state unreadable: %{public}s', failure.message);
    }
  }

  /*//////////////////////////////////////////////////////////////////////////
  // Handlers
  //////////////////////////////////////////////////////////////////////////*/

  private reloadContent(): void {
    this.startLoading(true);
  }

  /** uploader_layout: attached ONLY when both uploaderName and uploaderUrl are non-empty. */
  private openUploader(): void {
    if (this.uploaderName.length === 0 || this.uploaderUrl.length === 0) {
      return;
    }
    router.pushUrl({
      url: 'pages/ChannelFragmentPage',
      params: new ItemParams(this.serviceId, this.uploaderUrl, this.uploaderName)
    });
  }

  /** playlist_description / playlist_description_read_more: ellipsizer.toggle(). */
  private toggleDescription(): void {
    this.descriptionExpanded = !this.descriptionExpanded;
  }

  /** getPlayQueue(index): the loaded StreamInfoItems, starting at `index`. */
  private playQueueStreams(): StreamInfoItem[] {
    const streams: StreamInfoItem[] = [];
    for (const item of this.streamList.getItemsList()) {
      if (item instanceof StreamInfoItem) {
        streams.push(item as StreamInfoItem);
      }
    }
    return streams;
  }

  /**
   * getPlayQueue(index) HANDS OVER the whole playlist. Every control here resolved the list down
   * to `streams[index]` and passed that one item on, so the play queue never held more than the
   * stream that happened to start - which is what "only one video can be added to the queue"
   * describes. The queue is published BEFORE the player is touched, so whatever picks the stream
   * up (this page's own prepare, or the detail screen it routes to) already has the full list.
   */
  private publishPlayQueue(streams: StreamInfoItem[], index: number): void {
    const items: PlayQueueItem[] = [];
    for (const stream of streams) {
      items.push(PlayQueueItem.fromStreamInfoItem(stream));
    }
    setCurrentPlayQueue(new SimplePlayQueue(index, items));
  }

  /** getPlayQueueStartingAt(infoItem): max(indexOf(item), 0). */
  private playQueueStartIndex(item: StreamInfoItem | null): number {
    if (item === null) {
      return 0;
    }
    const index: number = this.playQueueStreams().indexOf(item);
    return index < 0 ? 0 : index;
  }

  /**
   * playOnMainPlayer(activity, queue) is openVideoDetailFragment(item.serviceId, item.url,
   * item.title, queue) on the queue's CURRENT item — the ONLY one of the three play controls
   * that navigates. Background and popup start PlayerService in place (startPlayer()).
   */
  private openPlayer(startIndex: number, popup: boolean): void {
    const streams: StreamInfoItem[] = this.playQueueStreams();
    // A second tap before the route had settled pushed a SECOND VideoDetailFragmentPage onto
    // the stack, so the user had to go back twice and two pages were bound to one queue.
    if (streams.length === 0 || this.launching) {
      return;
    }
    this.launching = true;
    const index: number = startIndex < streams.length ? startIndex : 0;
    const item: StreamInfoItem = streams[index];
    this.publishPlayQueue(streams, index);
    router.pushUrl({
      url: 'pages/VideoDetailFragmentPage',
      params: new PlayerParams(item.getServiceId(), item.getUrl(), item.getName(), popup)
    });
  }

  /** NavigationHelper.playOnMainPlayer(activity, getPlayQueue()). */
  private playAll(): void {
    this.openPlayer(0, false);
  }

  /**
   * PlayButtonHelper's long press: NavigationHelper.enqueueOnPlayer() appends the playlist to the
   * running player's queue; with nothing playing the playlist starts in that player instead.
   */
  private enqueueAll(audioOnly: boolean, popup: boolean): void {
    const streams: StreamInfoItem[] = this.playQueueStreams();
    if (streams.length === 0) {
      return;
    }
    const items: PlayQueueItem[] = streams.map((stream: StreamInfoItem): PlayQueueItem =>
      PlayQueueItem.fromStreamInfoItem(stream));
    if (enqueueAllOnPlayer(items)) {
      return;
    }
    if (audioOnly) {
      this.startPlayer(0, true);
    } else if (popup) {
      this.playOnPopup();
    } else {
      this.openPlayer(0, false);
    }
  }

  /**
   * playOnBackgroundPlayer / playOnPopupPlayer (NavigationHelper.java:144-171) hand the queue to
   * PlayerService and NEVER navigate - only playOnMainPlayer opens the detail fragment. So these
   * start the shared PlayerService in place, the way RouterActivityPage's background choice does,
   * and the playlist stays on screen. The popup player's own window needs SYSTEM_FLOAT_WINDOW,
   * which a self-signed build cannot grant: the registered substitution is PiP with the in-app
   * mini player as its fallback, and this page carries no XComponent surface for PiP, so the mini
   * player MainActivityPage docks off PlayerService.state is what the popup control gets.
   */
  private async startPlayer(startIndex: number, audioOnly: boolean): Promise<void> {
    const streams: StreamInfoItem[] = this.playQueueStreams();
    // playQueue.getItem() == null: the source's play controls do nothing on an empty queue.
    // `launching`: a double tap prepared the same stream twice and started a second AVSession.
    if (streams.length === 0 || this.launching) {
      return;
    }
    this.launching = true;
    const index: number = startIndex < streams.length ? startIndex : 0;
    const item: StreamInfoItem = streams[index];
    // playOnBackgroundPlayer(activity, getPlayQueue()) hands over the QUEUE; only the item it
    // currently points at is the one prepared now.
    this.publishPlayQueue(streams, index);
    try {
      const info: StreamInfo = await ServiceLocator.get().backgroundWork.runWithBackgroundTask(
        BackgroundWorkMode.DATA_TRANSFER,
        (): Promise<StreamInfo> =>
          ExtractorHelper.getStreamInfo(item.getServiceId(), item.getUrl(), false));
      await PlayerService.getInstance().prepare(info, audioOnly,
      audioOnly ? 0 : PlayerPrefs.defaultPlaybackHeight());
      // Without this there is no AVSession and no continuous task: the system shows no media
      // controls and stops the audio as soon as the app is backgrounded, which is what the
      // "background process is not running" reports come from. Only the detail fragment was
      // starting one.
      await MediaSessionService.getInstance()
        .startDetached(getContext(this) as common.UIAbilityContext, info);
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.showSnackBarError(failure.message);
    }
    // This control never leaves the screen, so onPageShow() will not fire for it.
    this.launching = false;
  }

  /** playOnBackgroundPlayer(): the source toasts before it starts the audio player. */
  private playOnBackground(): void {
    // The guard is read BEFORE the toast, not just inside startPlayer: a double tap otherwise
    // stacked two "playing in background" toasts over one playback session.
    if (this.launching) {
      return;
    }
    promptAction.showToast({
      message: $r('app.string.background_player_playing_toast'),
      duration: 2000
    });
    this.startPlayer(0, true);
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

  /**
   * playOnPopupPlayer(): the float window opens OVER the screen the user is on, so the playlist
   * stays visible behind it. This page used to hand the stream to VideoDetailFragmentPage,
   * because PiPWindow renders from an XComponent surface (PiPConfiguration.componentController)
   * and that page owned the only one - the user landed on the standard player instead, which is
   * the defect TC-LIBRARY-252 reported for a bookmarked playlist. PopupPlayerSurface is this
   * page's own surface; openPopupOnSurface() is the implementation every list screen shares,
   * mini-player fallback included, so the toast belongs here now rather than on the detail page.
   */
  private playOnPopup(): void {
    const streams: StreamInfoItem[] = this.playQueueStreams();
    // A burst of taps must open ONE popup: the surface's onLoad fires once, so a second item set
    // behind a mounted surface would simply never be played.
    if (streams.length === 0 || this.launching || this.popupSurfaceMounted) {
      return;
    }
    this.publishPlayQueue(streams, 0);
    promptAction.showToast({ message: $r('app.string.popup_playing_toast'), duration: 2000 });
    this.popupItem = streams[0];
    this.popupSurfaceMounted = true;
  }

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

  /** menu_item_share -> ShareUtils.shareText(name, url) — the implicit sendData Want. */
  private sharePlaylist(): void {
    // show() resolves once the panel is UP, so the guard covers exactly the window in which a
    // second tap would have stacked a second sheet - and lifts as soon as the first is on screen,
    // which is what lets a dismissed sheet be raised again straight away.
    if (this.sharePending) {
      return;
    }
    this.sharePending = true;
    // ShareUtils.shareText(context, name, url, thumbnails) - the system share panel;
    // ShareUtils owns the failure fallback (clipboard + toast), so this settles either way.
    const share: ShareUtils = ServiceLocator.get().share;
    share.shareText(this.headerTitle, this.url)
      .then((): void => {
        this.sharePending = false;
      })
      .catch((): void => {
        this.sharePending = false;
      });
  }

  /** onBookmarkClicked(): returns immediately while the DB read has not answered. */
  private async onBookmarkClicked(): Promise<void> {
    const manager: RemotePlaylistManager | null = this.remotePlaylistManager;
    const info: PlaylistInfo | null = this.currentInfo;
    if (!this.isBookmarkButtonReady || manager === null || info === null) {
      return;
    }
    const entity: PlaylistRemoteEntity | null = this.playlistEntity;
    try {
      if (entity === null) {
        await manager.onBookmark(info);
      } else {
        await manager.deletePlaylist(entity.uid);
      }
      await this.loadBookmarkState(info);
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.showSnackBarError(failure.message);
    }
  }

  /** action_settings -> NavigationHelper.openSettings(). */
  private openSettings(): void {
    router.pushUrl({ url: 'pages/SettingsActivityPage' });
  }

  /** menu_item_openInBrowser -> ShareUtils.openUrlInBrowser(url). */
  private openInBrowser(): void {
    const share: ShareUtils = ServiceLocator.get().share;
    share.openUrlInBrowser(this.url);
  }

  /** menu_item_append_playlist -> PlaylistDialog over the playlist's streams. */
  private async appendPlaylist(): Promise<void> {
    // createCorrespondingDialog(): the append branch only when a local playlist exists.
    if (await this.ensureServices() === null) {
      return;
    }
    const local: LocalPlaylistManager | null = this.localPlaylistManager;
    if (local === null) {
      return;
    }
    try {
      this.hasPlaylists = await local.hasPlaylists();
      // getPlaylistDuplicates(streamUrl) rather than getPlaylists(): the rows then carry
      // timesStreamIsContained, which is what lets PlaylistAppendDialog grey out a
      // playlist that already holds this stream and refuse a second append.
      const held: StreamInfoItem | null = this.heldItem;
      this.pickerPlaylists = held === null
        ? await local.getPlaylists()
        : await local.getPlaylistDuplicates(held.getUrl());
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      hilog.warn(0x0000, TAG, 'playlists unreadable: %{public}s', failure.message);
      this.hasPlaylists = false;
    }
    // PlaylistDialog is ABSTRACT in the source and createCorrespondingDialog() is a static
    // factory: it renders nothing of its own, it only picks WHICH concrete dialog is shown.
    // Opening it as a dialog painted an intermediate chooser instead of the real one.
    if (this.hasPlaylists) {
      this.appendDialog.open();
    } else {
      this.creationDialog.open();
    }
  }

  /** The dialog's chosen playlist: every loaded stream is appended, as getPlayQueue() feeds it. */
  private async appendStreamsTo(playlistId: number, playlist: object | null): Promise<void> {
    const local: LocalPlaylistManager | null = this.localPlaylistManager;
    if (local === null) {
      return;
    }
    try {
      await local.appendToPlaylist(playlistId, this.streamEntities());
      this.appendDialog.close();
      promptAction.showToast({ message: playlistAppendToast(playlist),
        duration: 2000 });
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.showSnackBarError(failure.message);
    }
  }

  private async createPlaylistFromStreams(name: string): Promise<void> {
    const local: LocalPlaylistManager | null = this.localPlaylistManager;
    if (local === null || name.length === 0) {
      return;
    }
    try {
      await local.createPlaylist(name, this.streamEntities());
      // PlaylistCreationDialog: Toast @string/playlist_creation_success.
      promptAction.showToast({ message: $r('app.string.playlist_creation_success'),
        duration: 2000 });
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.showSnackBarError(failure.message);
    }
  }

  /** getPlayQueue().getStreams().map(StreamEntity::new). */
  private streamEntities(): StreamEntity[] {
    const entities: StreamEntity[] = [];
    for (const stream of this.playQueueStreams()) {
      entities.push(StreamEntity.fromInfoItem(stream));
    }
    return entities;
  }

  private onItemSelected(item: InfoItem): void {
    router.pushUrl({
      url: 'pages/VideoDetailFragmentPage',
      params: new ItemParams(item.getServiceId(), item.getUrl(), item.getName())
    });
  }

  /**
   * showInfoItemDialog(item): the standard entries EXTENDED with START_HERE_ON_BACKGROUND, which
   * plays getPlayQueueStartingAt(infoItem) so playback begins at the pressed row.
   */
  private onItemHeld(item: InfoItem): void {
    if (!(item instanceof StreamInfoItem)) {
      return;
    }
    const stream: StreamInfoItem = item as StreamInfoItem;
    this.heldItem = stream;
    this.menuTitle = stream.getName();

    // InfoItemDialog.Builder owns the entry list and its order; this screen only says what each
    // entry does. It used to write out a shorter list of its own - see T-0118.
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
      this.appendPlaylist();
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

  /** START_HERE_ON_BACKGROUND: playOnBackgroundPlayer(getPlayQueueStartingAt(item), true). */
  private playFromHeldItem(): void {
    promptAction.showToast({
      message: $r('app.string.background_player_playing_toast'),
      duration: 2000
    });
    this.startPlayer(this.playQueueStartIndex(this.heldItem), true);
  }

  private appendToPlaylist(playlist: PlaylistLocalItem): void {
    this.appendStreamsTo(playlist.uid, playlist);
  }

  private showSnackBarError(message: string): void {
    hilog.error(0x0000, TAG, '%{public}s', message);
    promptAction.showToast({ message: message, duration: 3000 });
  }

  /*//////////////////////////////////////////////////////////////////////////
  // getListHeaderSupplier(): playlist_header.xml, one adapter row.
  //////////////////////////////////////////////////////////////////////////*/

  @Builder
  listHeader() {
    HeaderFooterHolder() {
      Column() {
        // textAppearanceLarge at @dimen/playlist_detail_title_text_size (16sp), inset by
        // @dimen/video_item_search_padding on both sides and above.
        Text(this.headerTitle)
          .id('playlist_title_view')
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontSize(16)
          .fontColor(C_ON_SURFACE)
          .padding({ left: HEADER_PADDING, right: HEADER_PADDING, top: HEADER_PADDING })

        Row() {
          // uploader_layout is GONE until the uploader is known, and stays non-clickable
          // while uploaderUrl is empty — setOnClickListener(null) is called FIRST every time.
          Row() {
            // A YouTube mix has no channel avatar: the source swaps in a SQUARE ic_radio.
            if (this.isYoutubeMix) {
              // The mix avatar is SQUARE with a transparent stroke, never the round channel one.
              Image($r('app.media.ic_radio'))
                .id('uploader_avatar_view')
                .width(AVATAR_SIZE)
                .height(AVATAR_SIZE)
                .objectFit(ImageFit.Contain)
            } else {
              // app:shapeAppearance="@style/CircularImageView" with a 1dp white stroke.
              Image(this.uploaderAvatar)
                .id('uploader_avatar_view')
                .width(AVATAR_SIZE)
                .height(AVATAR_SIZE)
                .objectFit(ImageFit.Cover)
                .borderRadius(AVATAR_SIZE / 2)
                .border({ width: 1, color: $r('app.color.white') })
                .backgroundColor($r('app.color.placeholder_background'))
            }

            Text(this.uploaderName.length > 0
              ? this.uploaderName
              : $r('app.string.playlist_no_uploader'))
              .id('uploader_name')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontSize(SUBTEXT_SIZE)
              .fontColor(C_SECONDARY)
              .padding({ left: 6, right: 6 })
          }
          .id('uploader_layout')
          .layoutWeight(1)
          .height(META_HEIGHT)
          .alignItems(VerticalAlign.Center)
          // setOnClickListener(null) is called FIRST every time, and re-attached only when the
          // name AND the url are there — an empty url leaves the row non-clickable.
          .enabled(this.uploaderUrl.length === 0 ? false : this.uploaderName.length > 0)
          .onClick(() => {
            this.openUploader();
          })

          // getDurationString(total, isDurationComplete, true): while pages remain the duration
          // is only a lower bound and the source appends "+".
          Text(this.isDurationComplete
            ? this.streamCountAndTotalDuration
            : this.streamCountAndTotalDuration + '+')
            .id('playlist_stream_count')
            .maxLines(1)
            .fontSize(SUBTEXT_SIZE)
            .fontColor(C_SECONDARY)
            .textAlign(TextAlign.End)
            .margin({ left: 6 })
        }
        .id('playlist_meta')
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ left: HEADER_PADDING, right: HEADER_PADDING, top: 6 })

        // description == null / EMPTY_DESCRIPTION / blank -> both views are GONE.
        if (this.description.length > 0) {
          Text(this.description)
            .id('playlist_description')
            .width('100%')
            .maxLines(this.descriptionExpanded ? DESCRIPTION_LINES_EXPANDED : DESCRIPTION_LINES_COLLAPSED)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontSize(14)
            .fontColor(C_SECONDARY)
            .padding({ left: HEADER_PADDING, right: HEADER_PADDING, top: 6 })
            .onClick(() => {
              this.toggleDescription();
            })

          // VISIBLE only when the text is actually ellipsizable.
          if (this.descriptionEllipsizable) {
            Text(this.descriptionExpanded
              ? $r('app.string.show_less')
              : $r('app.string.show_more'))
              .id('playlist_description_read_more')
              .width('100%')
              // android:gravity="end", android:textColor="?attr/colorPrimary".
              .textAlign(TextAlign.End)
              .fontSize(14)
              .fontColor(servicePrimaryColor(this.activeServiceId))
              .padding({ left: HEADER_PADDING, right: HEADER_PADDING, top: 6 })
              .margin({ bottom: 6 })
              .onClick(() => {
                this.toggleDescription();
              })
          }
        }

        // playlist_control.xml — three equal-weight cells, in the source's order.
        Row() {
          Row() {
            Image($r('app.media.ic_headset'))
              .width(CTRL_ICON_SIZE)
              .height(CTRL_ICON_SIZE)
              .objectFit(ImageFit.Contain)
              .fillColor($r('app.color.accent'))
            Text($r('app.string.controls_background_title'))
              .fontSize(SUBTEXT_SIZE)
              .fontColor($r('app.color.accent'))
              .margin({ left: 4 })
          }
          .id('playlist_ctrl_play_bg_button')
          .layoutWeight(1)
          .height(CTRL_HEIGHT)
          .alignItems(VerticalAlign.Center)
          .justifyContent(FlexAlign.Center)
          .onClick(() => {
            this.playOnBackground();
            showHoldToAppendTip(HOLD_TIP_AFTER_TOAST_MS);
          })
          .gesture(LongPressGesture().onAction(() => {
            // enqueueOnPlayer(activity, getPlayQueue(), PlayerType.AUDIO)
            this.enqueueAll(true, false);
          }))

          Divider()
            .vertical(true)
            .strokeWidth(1)
            .color($r('app.color.accent'))
            .height(CTRL_HEIGHT - 2 * CTRL_SEPARATOR_MARGIN)

          Row() {
            Image($r('app.media.ic_playlist_play'))
              .width(CTRL_ICON_SIZE)
              .height(CTRL_ICON_SIZE)
              .objectFit(ImageFit.Contain)
              .fillColor($r('app.color.accent'))
            Text($r('app.string.play_all'))
              .fontSize(SUBTEXT_SIZE)
              .fontColor($r('app.color.accent'))
              .margin({ left: 4 })
          }
          .id('playlist_ctrl_play_all_button')
          .layoutWeight(1)
          .height(CTRL_HEIGHT)
          .alignItems(VerticalAlign.Center)
          .justifyContent(FlexAlign.Center)
          .onClick(() => {
            this.playAll();
            showHoldToAppendTip();
          })
          .gesture(LongPressGesture().onAction(() => {
            // enqueueOnPlayer(activity, getPlayQueue(), PlayerType.MAIN)
            this.enqueueAll(false, false);
          }))

          Divider()
            .vertical(true)
            .strokeWidth(1)
            .color($r('app.color.accent'))
            .height(CTRL_HEIGHT - 2 * CTRL_SEPARATOR_MARGIN)

          Row() {
            Image($r('app.media.ic_picture_in_picture'))
              .width(CTRL_ICON_SIZE)
              .height(CTRL_ICON_SIZE)
              .objectFit(ImageFit.Contain)
              .fillColor($r('app.color.accent'))
            Text($r('app.string.controls_popup_title'))
              .fontSize(SUBTEXT_SIZE)
              .fontColor($r('app.color.accent'))
              .margin({ left: 4 })
          }
          .id('playlist_ctrl_play_popup_button')
          .layoutWeight(1)
          .height(CTRL_HEIGHT)
          .alignItems(VerticalAlign.Center)
          .justifyContent(FlexAlign.Center)
          .onClick(() => {
            this.playOnPopup();
            showHoldToAppendTip(HOLD_TIP_AFTER_TOAST_MS);
          })
          .gesture(LongPressGesture().onAction(() => {
            // enqueueOnPlayer(activity, getPlayQueue(), PlayerType.POPUP)
            this.enqueueAll(false, true);
          }))
        }
        .id('playlist_control')
        .width('100%')
        .height(CTRL_HEIGHT)
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      // playlist_header.xml: android:background="?attr/contrast_background_color".
      .backgroundColor($r('app.color.contrast_background'))
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
    }
  }

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

  /** InfoListAdapter.getItemViewType() + onCreateViewHolder(), with useMiniVariant true here. */
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

  /*//////////////////////////////////////////////////////////////////////////
  // PlaylistAppendDialog's picker rows — LocalItemListAdapter's item-type switch.
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

  @Builder
  playlistBody(item: PlaylistLocalItem) {
    PlaylistItemHolder({
      thumbnailUrl: item.thumbnailUrl,
      title: item.orderingName,
      showUploader: item.localItemType === LocalItemType.PLAYLIST_REMOTE_ITEM
    })
  }

  /**
   * menu_playlist.xml's showAsAction="never" items. The source shows these in a PopupMenu, whose
   * two defining behaviours - a floating card sized to its own content, and a tap anywhere else
   * dismissing it - are what ArkUI's .bindMenu() is. Drawn by hand as a Column in the page's
   * Stack instead, it had neither: the rows carried width('100%'), which resolves against the
   * AVAILABLE space, so the "card" spanned the whole screen as a band, and with nothing over the
   * content behind it a tap outside fell straight through to the row underneath, triggering it
   * while the menu stayed open.
   */
  @Builder
  overflowMenu() {
    Menu() {
      MenuItem({ content: $r('app.string.settings') })
        .id('action_settings')
        .onClick(() => {
          this.openSettings();
        })
      MenuItem({ content: $r('app.string.open_in_browser') })
        .id('menu_item_openInBrowser')
        .onClick(() => {
          this.openInBrowser();
        })
      MenuItem({ content: $r('app.string.add_to_playlist') })
        .id('menu_item_append_playlist')
        .onClick(() => {
          this.appendPlaylist();
        })
    }
  }

  build() {
    Column() {
      // The activity toolbar menu_playlist.xml inflates into.
      Row() {
        // toolbar_layout's ToolbarTheme tints the 24dp glyph white inside a 56dp
        // (?attr/actionBarSize) touch target.
        Image($r('app.media.ic_arrow_back'))
          .id('navigate_back')
          .accessibilityText($r('app.string.navigate_back'))
          .width(56)
          .height(56)
          .padding(16)
          .objectFit(ImageFit.Contain)
          .fillColor($r('app.color.on_primary'))
          .onClick(() => {
            router.back();
          })

        // Widget.AppCompat.Toolbar.Title: 20sp medium, 16dp past the navigation button.
        Text(this.headerTitle)
          .id('playlist_toolbar_title')
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_primary'))
          .margin({ left: 16, right: 16 })

        Image($r('app.media.ic_share'))
          .id('menu_item_share')
          .accessibilityText($r('app.string.share'))
          .width(48)
          .height(48)
          .padding(12)
          .objectFit(ImageFit.Contain)
          .fillColor($r('app.color.on_primary'))
          .onClick(() => {
            this.sharePlaylist();
          })

        // The icon swaps with the Room flowable's emission; the item is inert until then.
        Image(this.bookmarkMenuState
          ? $r('app.media.ic_playlist_add_check')
          : $r('app.media.ic_playlist_add'))
          .id('menu_item_bookmark')
          .accessibilityText(this.bookmarkMenuState
            ? $r('app.string.unbookmark_playlist') : $r('app.string.bookmark_playlist'))
          .width(48)
          .height(48)
          .padding(12)
          .objectFit(ImageFit.Contain)
          .fillColor($r('app.color.on_primary'))
          .enabled(this.isBookmarkButtonReady)
          .onClick(() => {
            this.onBookmarkClicked();
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
      .width('100%')
      // Toolbar: ?attr/actionBarSize tall, android:background="?attr/colorPrimary".
      .height(56)
      .alignItems(VerticalAlign.Center)
      .backgroundColor(servicePrimaryColor(this.activeServiceId))

      Stack() {
        Column() {
          InfoListAdapter({
            dataSource: this.streamList,
            viewMode: this.itemViewMode,
            // getListHeaderSupplier() != null on this screen. The adapter wraps it in a
            // ListItemGroup, so it spans the lanes instead of taking one.
            hasHeader: true,
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
        .width('100%')
        .height('100%')

        // The append-to-playlist picker the overflow item and the long-press dialog open.
        if (this.appendPlaylists.totalCount() > 0) {
          LocalItemListAdapter({
            dataSource: this.appendPlaylists,
            row: (item: PlaylistLocalItem): void => {
              this.appendRow(item);
            }
          })
        }

        if (this.isLoading) {
          LoadingProgress()
            .id('loading_progress_bar')
            .width(48)
            .height(48)
            .color(servicePrimaryColor(this.activeServiceId))
        }

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
            Button(Localization.buttonLabel('retry'))
              .id('error_retry_button')
              .type(ButtonType.Normal)
              .backgroundColor(servicePrimaryColor(this.activeServiceId))
              .fontSize(16)
              .fontColor($r('app.color.subscribe_text_color'))
              .borderRadius(2)
              .margin({ top: 4 })
              .padding({ left: 16, right: 16, top: 6, bottom: 6 })
              .onClick(() => {
                this.reloadContent();
              })
          }
          .id('error_panel')
          .padding(16)
          .alignItems(HorizontalAlign.Center)
        }

        // showEmptyState() — INSTEAD of the content, never beside it.
        if (!this.isLoading && this.errorInfo === null && this.loadedCount === 0) {
          Column() {
            // fragment_playlist.xml owns its empty view: monospace 35sp, 10dp above the message.
            Text('(ಠ_ಠ)')
              .fontFamily('monospace')
              .fontSize(35)
              .fontColor(C_ON_SURFACE)
              .margin({ bottom: 10 })
            // setEmptyStateMessage(): SoundCloud says "no streams", every other service "no videos".
            if (this.serviceId === SoundCloud.getServiceId()) {
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
        MiniPlayerBar({ idPrefix: 'playlist_' })
      }

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
    .id('PlaylistFragmentPage')
    .width('100%')
    .height('100%')
    // ?attr/windowBackground = @color/light_background_color in the light theme.
    .backgroundColor(themedBackground(this.blackTheme))
  }

  /** DownloadDialog over this list, mounted the way the feed mounts it. */
}
