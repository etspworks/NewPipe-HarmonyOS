/**
 * S3 — SearchFragment (screen_search), structure from fragment_search.xml +
 * toolbar_search_layout.xml + item_search_suggestion.xml + SearchFragment.java.
 *
 * TWO independent lists live on this screen:
 *   items_list        — InfoListAdapter, polymorphic (stream / channel / playlist), paginated,
 *                       each subtype with its OWN row and its OWN tap destination,
 *   suggestions_panel — a full-size overlay ON TOP of that list (showSuggestionsPanel /
 *                       hideSuggestionsPanel animate it in and out), holding suggestions_list.
 *
 * The search field is NOT in fragment_search.xml: it lives in the ACTIVITY toolbar
 * (toolbar_search_layout.xml, found with activity.findViewById), so migrating this screen means
 * owning that toolbar row.
 *
 * A launch with NO argument is the app's normal "open search" case (getInstance(serviceId, "")):
 * onResume's `if (TextUtils.isEmpty(searchString) || wasSearchFocused) { showKeyboardSearch();
 * showSuggestionsPanel(); }` focuses the field and shows the SEARCH HISTORY. Nothing failed and
 * nothing was requested, so it is never logged as an error.
 *
 * Structure only — S5 styles it from the capture.
 */
import { router } from '@kit.ArkUI';
import { display, MeasureText } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

import { InfoItem } from '../common/extractor/core/InfoItem';
import { StreamInfoItem } from '../model/extractor/StreamInfoItem';
import { ChannelInfoItem } from '../model/extractor/ChannelInfoItem';
import { PlaylistInfoItem } from '../model/extractor/PlaylistInfoItem';
import { CommentsInfoItem } from '../model/extractor/CommentsInfoItem';
import { PlaylistLocalItem } from '../model/db/view/PlaylistLocalItem';
import { LocalItemType } from '../model/enums/LocalItemLocalItemType';
import { SuggestionItem } from '../model/app/SuggestionItem';
import { SearchInfo } from '../model/extractor/SearchInfo';
import { Page } from '../model/extractor/Page';
import { InfoItemsPage } from '../model/extractor/ListExtractorInfoItemsPage';
import { PlaylistMetadataEntry } from '../model/db/view/PlaylistMetadataEntry';
import { StreamEntity } from '../model/db/entity/StreamEntity';

import { InfoListAdapter, InfoItemDataSource, ItemViewMode } from '../components/InfoListAdapter';
import { resolveItemViewMode } from '../common/settings/ViewModeResolver';
import { InfoItemHolder } from '../components/InfoItemHolder';
import { HeaderFooterHolder } from '../components/HeaderFooterHolder';
import { HFHolder } from '../components/HFHolder';
import { FallbackViewHolder } from '../components/FallbackViewHolder';
import { buildStreamMenuActions, DialogAction, InfoItemDialog, StreamMenuHandlers,
  StreamMenuTarget } from '../components/InfoItemDialog';
import { enqueueNextStream } from '../common/util/StreamRowActions';
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
import { LocalItemListAdapter, LocalItemDataSource } from '../components/LocalItemListAdapter';
import { LocalItemHolder } from '../components/LocalItemHolder';
import { LocalPlaylistItemHolder } from '../components/LocalPlaylistItemHolder';
import { LocalBookmarkPlaylistItemHolder } from '../components/LocalBookmarkPlaylistItemHolder';
import { RemotePlaylistItemHolder } from '../components/RemotePlaylistItemHolder';
import { RemoteBookmarkPlaylistItemHolder } from '../components/RemoteBookmarkPlaylistItemHolder';
import { LocalPlaylistStreamItemHolder } from '../components/LocalPlaylistStreamItemHolder';
import { LocalStatisticStreamItemHolder } from '../components/LocalStatisticStreamItemHolder';
import { PlaylistItemHolder } from '../components/PlaylistItemHolder';
import {
  SuggestionListAdapter,
  SuggestionItemDataSource
} from '../components/SuggestionListAdapter';
import { SuggestionItemHolder } from '../components/SuggestionItemHolder';

import { ExtractorHelper } from '../common/extractor/ExtractorHelper';
import { NewPipe } from '../common/extractor/core/NewPipe';
import { LinkType, StreamingService } from '../common/extractor/core/StreamingService';
import { AppDatabase } from '../common/db/AppDatabase';
import { HistoryRecordManager } from '../common/db/HistoryRecordManager';
import { PlayerService } from '../common/player/PlayerService';
import { PlayerPrefs } from '../common/player/PlayerPrefs';

import { MediaSessionService } from '../common/player/MediaSessionService';
import { BackgroundWorkMode } from '../common/background/BackgroundWork';
import { StreamInfo } from '../model/extractor/StreamInfo';
import { isAudioStream, isLiveStream } from '../model/app/StreamItem';
import { enqueueOnCurrentPlayQueue } from '../model/app/PlayQueue';
import { PlayQueueItem } from '../model/app/PlayQueueItem';
import { openPopupOnSurface, PopupPlayerSurface } from '../components/PopupPlayerSurface';
import { DownloadDialogHost } from './DownloadDialogPage';
import { LocalPlaylistManager, playlistAppendToast } from '../common/db/PlaylistManager';
import { AppPreferences } from '../common/prefs/Preferences';
import {
  current_service_key,
  default_service_value,
  list_view_mode_key,
  list_view_mode_value,
  show_search_suggestions_key,
  show_local_search_suggestions_key,
  show_remote_search_suggestions_key, show_meta_info_key } from '../common/prefs/SettingsKeys';
import { ServiceLocator } from '../common/di/ServiceLocator';
import { Disposable, Observable } from '../common/rx/Rx';
// ServiceList's static initialiser: importing the registry is what registers the services, so a
// cold deep-link launch straight into this page still resolves NewPipe.getService(serviceId).
import { all as allServices } from '../common/extractor/ServiceRegistry';
// The 120 ms suggestionPublisher.debounce() — one restarting timer is the same behaviour, and it
// keeps the Disposable contract so aboutToDisappear tears it down like the CompositeDisposable.
import { DebounceSaver } from '../common/util/DebounceSaver';
// BaseStateFragment.handleError() drops the whole info cache before showing the error panel.
import { InfoCache } from '../common/extractor/InfoCache';
import { Localization } from '../common/i18n/Localization';
// ThemeHelper.setTheme(context, serviceId): ?attr/colorPrimary follows the ACTIVE service,
// so the PeerTube / SoundCloud / media.ccc.de search toolbar is not the YouTube red.
import { servicePrimaryColor, DIALOG_MASK_COLOR } from '../common/theme/ServiceTheme';
import { MiniPlayerBar } from '../components/MiniPlayerBar';
// The error panel shows a MIGRATED message, not the exception's own text.
import { ErrorInfo } from '../model/app/ErrorInfo';
import { UserAction } from '../model/enums/UserAction';
// SearchFragment.onError(): NothingFoundException is the EMPTY state, not the error panel.
import { NothingFoundException } from '../common/extractor/info/SearchExtractor';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';
import { NewPipeTextView } from '../components/NewPipeTextView';
import { LinkSpan } from '../common/text/Linkify';
import { linkTextToCopy, openUrlLink } from '../common/text/InternalUrlsHandler';
import { buildMetaInfoText, MetaInfoText } from './DescriptionFragmentPage';

const TAG: string = 'SearchFragmentPage';

/** SearchFragment.THRESHOLD_NETWORK_SUGGESTION — remote suggestions need at least one letter. */
const THRESHOLD_NETWORK_SUGGESTION: number = 1;
/** SearchFragment.SUGGESTIONS_DEBOUNCE — how long typing must stop before suggestions are fetched. */
const SUGGESTIONS_DEBOUNCE: number = 120;
/** getLocalSuggestionsObservable(query, 3) when remote ones show too, 25 when they do not. */
const LOCAL_LIMIT_WITH_REMOTE: number = 3;
const LOCAL_LIMIT_ALONE: number = 25;
/** ServiceHelper.DEFAULT_FALLBACK_SERVICE — YouTube. */
const DEFAULT_FALLBACK_SERVICE_ID: number = 0;

/* S5 — style only. LightTheme (styles.xml Base.V21.LightTheme) is the captured theme:
 * colorPrimary/colorPrimaryDark = light_youtube_primary_color, windowBackground =
 * light_background_color, separator_color = light_separator_color, and the toolbar's
 * ?attr/toolbarSearchColor = @color/white. Only the two AppCompat text colors have no migrated
 * resource, so they stay literals here, as on every screen styled before this one. */
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');
/** The same text at Android's disabled alpha — the divider row is an setEnabled(false) item. */
const COLOR_ON_SURFACE_DISABLED: Resource = $r('app.color.on_surface_disabled');
/** android:textColorHint on a colorPrimary toolbar — the dimmed half of toolbarSearchColor. */
const COLOR_TOOLBAR_HINT: string = '#B3FFFFFF';

/**
 * The overflow's own popup, as the source draws it. An ActionBar overflow is an Android
 * PopupMenu: a SQUARE-cornered card that hangs off the overflow button's own corner. ArkUI
 * rounds a menu and, with no placement of its own, slides the card left until it fits —
 * which is TC-SEARCH-026/027/043/233/234 ('should open from the alignment of the three
 * points … corners at 90 degrees … positioned larger'). The radius belongs to the menu
 * WINDOW, so it goes through the bind options: .borderRadius(0) on Menu does nothing.
 */
/**
 * TC-SEARCH-233 / 026 / 043 / 234 also ask for the menu to sit "a bit higher". On the reference it
 * OVERLAPS its anchor - the PopupMenu card's top edge is 4 vp under the status bar, covering the
 * toolbar it was opened from (measured: ListView `[480,114][1068,1410]` at density 3). Here it
 * lands 56 vp lower, immediately BELOW the toolbar.
 *
 * That part is NOT fixed, and not for want of trying. ArkUI anchors a bindMenu under its anchor and
 * offers no lever to move it: `MenuOptions.offset` is declared and accepted but had no effect at
 * -56 or at -200 vp (measured twice on the device, menu bounds unchanged at `[527,302][1164,1732]`),
 * and `showInSubWindow: true` did not move it either. Reproducing the overlap would mean replacing
 * a working menu with a hand-positioned overlay, which is a large change for a vertical offset.
 * Recorded as a platform difference on the cards instead.
 */
const FILTER_MENU_OPTIONS: MenuOptions = {
  borderRadius: 0,
  placement: Placement.BottomRight
};
/** See the comment on the TextInput: the hint alone, not the typed text (TC-SEARCH-235). */
const PLACEHOLDER_FONT_SIZE: number = 16;
/**
 * Everything in the toolbar Row that is NOT the field, so the field's own width is the screen
 * less this: navigate_up 56 + the field's 16 left margin + toolbar_search_clear 48 +
 * more_options 48. Each of those four is a literal on its component further down this file;
 * the sum is checked against the device's own layout dump in fitPlaceholder()'s comment.
 */
const TOOLBAR_CHROME_VP: number = 56 + 16 + 48 + 48;
/** The one character ArkUI would have drawn itself, had it truncated where we needed it to. */
const PLACEHOLDER_ELLIPSIS: string = '…';
/**
 * The PopupMenu card's width, measured on the reference: its ListView is 196 vp
 * (`[480,114][1068,1410]` at density 3), not the 240 this port had picked (TC-SEARCH-233 and its
 * three siblings, "the menu opens in the correct size").
 */
const FILTER_MENU_WIDTH: number = 196;
/** The card's own 16 vp padding, so a row knows how much of that width its content may use. */
const FILTER_MENU_PADDING: number = 16;
/** setGroupCheckable(1, true, true): ONE mutually exclusive group across both sections. */
const FILTER_RADIO_GROUP: string = 'search_content_filter';

/** NavigationHelper.openVideoDetailFragment / openChannelFragment / openPlaylistFragment args. */
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

@Entry
@Component
export struct SearchFragmentPage {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  /** infoListAdapter's backing list <- SearchInfo.getRelatedItems(). */
  @State resultsList: InfoItemDataSource = new InfoItemDataSource();
  /** suggestionListAdapter's current list <- local history zipped with remote suggestions. */
  @State suggestionsList: SuggestionItemDataSource = new SuggestionItemDataSource();
  /** The append-to-playlist picker the long-press dialog opens. */
  private appendPlaylists: LocalItemDataSource = new LocalItemDataSource();

  /** getSearchEditString(): what is in toolbar_search_edit_text right now. */
  @State searchQuery: string = '';
  /** searchString: the query the results on screen belong to. */
  @State searchString: string = '';
  /** searchEditText.setHint(search_with_service_name, service name). */
  @State searchInputHint: ResourceStr = $r('app.string.search');
  /** suggestionsPanelVisible — the panel OVERLAYS the results list. */
  @State suggestionsPanelVisible: boolean = false;
  /** result.getSearchSuggestion(), trimmed; empty means correct_suggestion is GONE. */
  @State searchSuggestion: string = '';
  /** The suggestion as the banner interpolates it — String.format(helperText, "<b><i>" +
   *  escapeHtml(searchSuggestion) + "</i></b>"), with the markup ArkUI cannot render dropped. */
  @State didYouMeanBanner: string = '';
  /** result.isCorrectedSearch(): "showing results for" instead of "did you mean". */
  @State isCorrectedSearch: boolean = false;
  /** service.getSearchQHFactory().getAvailableContentFilter() — the menu's own rows. */
  @State contentFilterMenu: string[] = [];
  /** NewPipeSettings.showLocalSearchSuggestions() / showRemoteSearchSuggestions(): both come out
   *  of the show_search_suggestions string set, and BOTH off means no suggestions panel at all. */
  @State showLocalSuggestions: boolean = true;
  @State showRemoteSuggestions: boolean = true;
  /** getSuggestionMovementFlags()/onSuggestionItemLongClick(): only a fromHistory row can be
   *  swiped away or long-pressed for the delete dialog — a remote suggestion returns 0 flags. */
  @State fromHistory: boolean = false;
  /** showMetaInfoInTextView(result.getMetaInfo(), ...) — cleared at the start of every search. */
  @State metaInfoText: string = '';
  /** Its links, one span per meta-info url (set together with metaInfoText). */
  private metaInfoSpans: LinkSpan[] = [];
  /** setSelection(): the caret is moved to the end of a correction put into the field. */
  private searchInputController: TextInputController = new TextInputController();

  @State isLoading: boolean = false;
  @State errorInfo: string | null = null;
  /** ErrorPanelHelper:101-107 — the recaptcha challenge or Report, whichever the error earns. */
  @State errorActionLabel: string = '';
  /** errorOpenInBrowser: shown only when the failed request has a browsable URL. */
  @State openInBrowserUrl: string | null = null;
  /** How many rows the adapter holds — showEmptyState() is driven by this, not by the pixels. */
  @State loadedCount: number = 0;
  /** Page.isValid(nextPage): the pignate_footer row shows while more pages remain. */
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
  /** setUseMiniVariant(...) — false on this screen. */
  @State useMiniVariant: boolean = false;
  /** LocalItemListAdapter.useItemHandle — false outside BookmarkFragment. */
  @State useItemHandle: boolean = false;

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

  /** showInfoItemDialog(item) / showDeleteSuggestionDialog(item): the title and its entries. */
  @State menuTitle: string = '';
  @State menuActions: DialogAction[] = [];

  /** getInstance(serviceId, searchString). */
  private serviceId: number = DEFAULT_FALLBACK_SERVICE_ID;
  /**
   * setQuery(): the filters every searchFor()/getMoreSearchItems() call carries.
   *
   * @State, not a plain field: it is also what the overflow's checkable group renders as
   * the selected radio, so a filter change has to repaint the menu.
   */
  @State contentFilter: string[] = [];
  private sortFilter: string = '';
  /** The query waiting on the debounce window (suggestionPublisher's last onNext). */
  private pendingQuery: string = '';
  private suggestionDebounce: DebounceSaver | null = null;
  private nextPage: Page | null = null;
  private currentWorker: Disposable | null = null;
  private historyRecordManager: HistoryRecordManager | null = null;
  private playlistManager: LocalPlaylistManager | null = null;
  /** The row the long-press menu is acting on. */
  private heldItem: StreamInfoItem | null = null;
  /** BaseStateFragment.lastPanelError: the ErrorInfo the panel shows, for its action button. */
  private lastPanelError: ErrorInfo | null = null;

  /** itemView.setOnLongClickListener -> showInfoItemDialog(item). */
  private infoItemDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    builder: InfoItemDialog({ title: this.menuTitle, actions: this.menuActions })
  });

  /* //////////////////////////////////////////////////////////////////////////
  // Lifecycle
  ////////////////////////////////////////////////////////////////////////// */

  aboutToAppear(): void {
    // initSuggestionObserver()'s debounce: every keystroke re-arms this window, and only the
    // last one inside it reaches the local + remote merge.
    this.suggestionDebounce = new DebounceSaver(SUGGESTIONS_DEBOUNCE, (): void => {
      this.updateSuggestions(this.pendingQuery);
    });
    this.readArguments();
    this.readSuggestionPreferences();
    this.setupItemViewMode();
    this.updateService();
    if (this.searchString.length === 0) {
      // The argument-free launch: focus the field and show the search history, per onResume().
      hilog.info(0x0000, TAG, 'opened with no query — showing the search-history suggestions');
      this.suggestionsPanelVisible = true;
    } else {
      this.searchQuery = this.searchString;
      this.startLoading();
    }
    this.updateSuggestions(this.searchQuery);
  }

  /**
   * onBackPressed(): while the suggestions cover results that have finished loading, Back hides
   * them and puts the searched text back in the field instead of leaving the screen.
   */
  onBackPress(): boolean {
    if (this.suggestionsPanelVisible && this.loadedCount > 0 && !this.isLoading) {
      this.suggestionsPanelVisible = false;
      // hideKeyboardSearch()
      this.getUIContext().getFocusController().clearFocus();
      // searchEditText.setText(lastSearchedString): the query the results on screen belong to.
      this.searchQuery = this.searchString;
      this.publishSuggestionQuery(this.searchString);
      return true;
    }
    return false;
  }

  aboutToDisappear(): void {
    this.disposeWorker();
    // suggestionDisposable.dispose(): a pending debounce must not fire onto a dead page.
    const debounce: DebounceSaver | null = this.suggestionDebounce;
    if (debounce !== null) {
      debounce.dispose();
    }
  }

  /**
   * NewPipeSettings.showLocalSearchSuggestions() / showRemoteSearchSuggestions(): one string-set
   * preference holds both switches, and it defaults to BOTH enabled.
   */
  private readSuggestionPreferences(): void {
    const enabled: string[] = AppPreferences.instance().getStringSetSync(show_search_suggestions_key,
      [show_local_search_suggestions_key, show_remote_search_suggestions_key]);
    this.showLocalSuggestions = enabled.indexOf(show_local_search_suggestions_key) >= 0;
    this.showRemoteSuggestions = enabled.indexOf(show_remote_search_suggestions_key) >= 0;
  }

  /** suggestionPublisher.onNext(query) — debounced by SUGGESTIONS_DEBOUNCE before it is served. */
  private publishSuggestionQuery(query: string): void {
    this.pendingQuery = query;
    const debounce: DebounceSaver | null = this.suggestionDebounce;
    if (debounce === null) {
      this.updateSuggestions(query);
      return;
    }
    debounce.setHasChangesToSave();
  }

  private disposeWorker(): void {
    const worker: Disposable | null = this.currentWorker;
    if (worker !== null) {
      worker.dispose();
      this.currentWorker = null;
    }
  }

  /** SearchFragment.getInstance(serviceId, searchString). */
  private readArguments(): void {
    const params: Record<string, Object> | undefined =
      router.getParams() as Record<string, Object> | undefined;
    let requestedService: number = -1;
    if (params !== undefined && params !== null) {
      const sid: Object | undefined = params['serviceId'];
      if (sid !== undefined && sid !== null) {
        requestedService = Number(sid.toString());
      }
      const query: Object | undefined = params['searchString'];
      if (query !== undefined && query !== null) {
        this.searchString = query.toString();
      }
    }
    this.serviceId =
      requestedService >= 0 ? requestedService : SearchFragmentPage.selectedServiceId();
  }

  /**
   * ServiceHelper.getSelectedServiceId(): the preference holds the service NAME, and an
   * unresolvable one falls back to DEFAULT_FALLBACK_SERVICE_ID.
   *
   * Resolved over ServiceList.all() rather than NewPipe.getServiceByName() alone, because
   * touching the registry is what runs its static initialiser — on a cold deep-link launch
   * straight into this page nothing else has imported it yet.
   */
  private static selectedServiceId(): number {
    const name: string = AppPreferences.instance()
      .getStringResolvedSync(current_service_key, default_service_value);
    const services: StreamingService[] = allServices();
    for (const service of services) {
      if (service.getServiceInfo().getName() === name) {
        return service.getServiceId();
      }
    }
    return DEFAULT_FALLBACK_SERVICE_ID;
  }

  /** updateService() plus the service name in the field's hint and its content-filter rows. */
  private updateService(): void {
    try {
      const service: StreamingService = NewPipe.getService(this.serviceId);
      // buildMenu(): the rows ARE the service's own available content filters.
      this.contentFilterMenu = service.getSearchQHFactory().getAvailableContentFilter();
      this.applyContentFilterHint(service);
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      hilog.warn(0x0000, TAG, 'getting service for id: %{public}s', failure.message);
    }
  }

  /**
   * changeContentFilter()'s hint half: search_with_service_name while nothing is filtered,
   * search_with_service_name_and_filter once a real filter is picked.
   *
   * Resolved to TEXT here rather than left as a parameterised $r(): the filter half of the hint
   * is the menu row's own title, which is a Resource, and a Resource cannot be a $r() format
   * argument. The port passed the raw filter KEY instead, so the field read "(music_songs)"
   * where TC-SEARCH-045 / TC-SEARCH-235 expect "Search SoundCloud (Tracks)" /
   * "Search YouTube (Videos)".
   */
  private applyContentFilterHint(service: StreamingService): void {
    const name: string = service.getServiceInfo().getName();
    const isNotFiltered: boolean =
      this.contentFilter.length === 0 || this.contentFilter[0] === 'all';
    this.searchInputHint = isNotFiltered
      ? Localization.getStringArgs('search_with_service_name', [name])
      : SearchFragmentPage.fitPlaceholder(
        Localization.getStringArgs('search_with_service_name_and_filter',
          [name, this.translatedFilterString(this.contentFilter[0])]));
  }

  /**
   * TC-SEARCH-216/217/218: the hint, cut to what the field can actually draw.
   *
   * PLACEHOLDER_FONT_SIZE fits every YouTube and SoundCloud label, but
   * `Search media.ccc.de (Conferences)` is 33 characters and fits NEITHER device — measured on
   * both handsets, it overflows the port's 206 vp field and the reference's 200 vp one. What
   * differed was how each gave up, and that difference is the defect:
   *
   *   reference  `Search media.ccc.de (Co`   — EditText clips at the field edge, mid-word
   *   port       `Search media.ccc.de …`     — the filter name is dropped WHOLE
   *
   * ArkUI wraps non-CJK text at SPACES ONLY, so the last token goes as one piece and the hint
   * ends up naming no filter at all — the one word it exists to show. That cannot be styled
   * away: `.wordBreak(WordBreak.BREAK_ALL)` and `.textOverflow(TextOverflow.Clip)` were both
   * applied to this TextInput and measured on the device, and NEITHER reaches the placeholder —
   * both rendered `Search media.ccc.de …` unchanged. So the platform is not asked to truncate:
   * it is handed a string that already fits, cut per character the way the reference cuts.
   *
   * The budget is the field's own width. It is `layoutWeight(1)` between four fixed-width
   * siblings, so it is the screen less TOOLBAR_CHROME_VP — 374.15 − 168 = 206.15 vp on the
   * port, which is exactly the 670 px / 3.25 its layout dump reports for
   * `toolbar_search_edit_text`. Measuring costs one pass per FILTER PICK, not per keystroke:
   * the unfiltered hint never goes through here, and a service name alone has always fit.
   */
  private static fitPlaceholder(hint: string): string {
    const budgetPx: number = display.getDefaultDisplaySync().width - vp2px(TOOLBAR_CHROME_VP);
    if (budgetPx <= 0) {
      return hint;
    }
    if (SearchFragmentPage.placeholderWidthPx(hint) <= budgetPx) {
      return hint;
    }
    // Drop one character at a time, as the reference's own clip does. ~35 characters worst
    // case, so a linear walk is cheaper than the arithmetic to avoid one.
    for (let end: number = hint.length - 1; end > 0; end--) {
      const candidate: string = hint.substring(0, end) + PLACEHOLDER_ELLIPSIS;
      if (SearchFragmentPage.placeholderWidthPx(candidate) <= budgetPx) {
        return candidate;
      }
    }
    return hint;
  }

  private static placeholderWidthPx(text: string): number {
    return MeasureText.measureText({ textContent: text, fontSize: PLACEHOLDER_FONT_SIZE });
  }

  /**
   * onCreateOptionsMenu(): the toolbar overflow IS the content-filter list — one row per
   * service.getSearchQHFactory().getAvailableContentFilter() entry, group 1 checkable, plus a
   * DISABLED divider row in group 2 ahead of the service's second section.
   *
   * bindMenu(MenuElement[]) cannot draw that checkable group: every element is a bare label with
   * no selected state, which is the "Radio buttons cannot be displayed" 18 SEARCH cards report.
   * A @Builder Menu can — MenuItem takes a CustomBuilder, so a row is the source's RadioButton
   * plus its title, and MenuItemGroup's header is the disabled divider row: a label with no
   * radio, no click and no dismissal (TC-SEARCH-167).
   */
  @Builder
  contentFilterMenuContent() {
    Menu() {
      ForEach(this.filtersBeforeGroup(), (filter: string, index: number) => {
        this.contentFilterRow(filter);
      }, (filter: string, index: number) => `lead-${index}-${filter}`)
      if (this.contentFilterGroupHeader().length > 0) {
        // T-0162: the header is a DISABLED row, not a MenuItemGroup. ArkUI rules a line above
        // every group header; the reference draws none - measured while T-0134/0135/0136/0138
        // were reviewed, where every other metric of this menu matched to the vp. There is no
        // way to turn that rule off, so the group is not declared as a group: the header is one
        // more MenuItem, `.enabled(false)`, which is what the source does to it anyway
        // (setEnabled(false)) and what keeps it inert with the menu open - the behaviour
        // TC-SEARCH-167 pins. The rows that followed it stay in the same order.
        MenuItem((): void => {
          this.contentFilterGroupHeaderRow();
        })
          .enabled(false)
        ForEach(this.filtersInGroup(), (filter: string, index: number) => {
          this.contentFilterRow(filter);
        }, (filter: string, index: number) => `group-${index}-${filter}`)
      }
    }
    .width(FILTER_MENU_WIDTH)
  }

  /**
   * The divider row's label. A plain string header draws BOLDER and DARKER than the option
   * labels, but the source adds this row with setEnabled(false), so it has to read as dimmed
   * (TC-SEARCH-233). A CustomBuilder header is the only way to carry the disabled colour.
   */
  @Builder
  contentFilterGroupHeaderRow() {
    Text(this.contentFilterGroupHeader())
      .maxLines(1)
      .fontSize(16)
      .fontColor(COLOR_ON_SURFACE_DISABLED)
      .height(48)
      .width('100%')
      .textAlign(TextAlign.Start)
  }

  /** One checkable row. MenuItem is what dismisses the popup on selection, as a PopupMenu does. */
  @Builder
  contentFilterRow(filter: string) {
    MenuItem((): void => {
      this.contentFilterRowContent(filter);
    })
      .onClick(() => {
        this.changeContentFilter(filter);
      })
  }

  /**
   * The checkable item's own views. The RadioButton is NOT the tap target — the MenuItem around
   * it is, so re-tapping the selected row cannot toggle it off (TC-SEARCH-172) and the whole row
   * is clickable the way a menu row is.
   */
  @Builder
  contentFilterRowContent(filter: string) {
    Row() {
      Text(this.translatedFilterString(filter))
        .maxLines(1)
        .fontSize(16)
        .fontColor(COLOR_ON_SURFACE)
        .layoutWeight(1)
      Radio({ value: filter, group: FILTER_RADIO_GROUP })
        .checked(this.activeContentFilter() === filter)
        .hitTestBehavior(HitTestMode.None)
        .width(20)
        .height(20)
    }
    // The radio goes AFTER the label, hard against the row's trailing edge - measured on the
    // reference, whose radio occupies [308,340] vp inside a menu ending at 356, while this port
    // drew it at [126,146], to the LEFT of the label. That is the "buttons should be aligned to
    // the right" the four SEARCH cards report.
    //
    // A trailing radio needs the row to KNOW the width it is aligning against, so unlike the
    // leading-radio version this one is sized: the menu's width less the card's own padding.
    // layoutWeight on the label then pushes the radio to the end.
    .width(FILTER_MENU_WIDTH - FILTER_MENU_PADDING * 2)
    .height(48)
    .alignItems(VerticalAlign.Center)
  }

  /**
   * The checked row. Nothing picked yet is the FIRST row — onCreateOptionsMenu() calls
   * setChecked(true) on whichever filter it adds first, whatever that filter happens to be
   * (TC-SEARCH-163/215). Hard-coding `all` left PeerTube with no checked radio at all: its
   * getAvailableContentFilter() is [videos, playlists, channels, sepia_videos] and carries no
   * `all` row for the check to land on (TC-SEARCH-027).
   */
  private activeContentFilter(): string {
    if (this.contentFilter.length > 0) {
      return this.contentFilter[0];
    }
    return this.contentFilterMenu.length === 0 ? '' : this.contentFilterMenu[0];
  }

  /**
   * Where the service's SECOND, labelled section starts. The source adds its divider row before
   * music_songs and before sepia_videos, with a literal title in both cases — neither is a
   * string resource there, so neither is one here.
   */
  private contentFilterGroupStart(): number {
    for (let i: number = 0; i < this.contentFilterMenu.length; i++) {
      const filter: string = this.contentFilterMenu[i];
      if (filter === 'music_songs' || filter === 'sepia_videos') {
        return i;
      }
    }
    return -1;
  }

  private contentFilterGroupHeader(): string {
    const start: number = this.contentFilterGroupStart();
    if (start < 0) {
      return '';
    }
    return this.contentFilterMenu[start] === 'music_songs' ? 'YouTube Music' : 'Sepia Search';
  }

  private filtersBeforeGroup(): string[] {
    const start: number = this.contentFilterGroupStart();
    return start < 0 ? this.contentFilterMenu : this.contentFilterMenu.slice(0, start);
  }

  private filtersInGroup(): string[] {
    const start: number = this.contentFilterGroupStart();
    return start < 0 ? [] : this.contentFilterMenu.slice(start);
  }

  /**
   * ServiceHelper.getTranslatedFilterString(filter, context) — its when-branches, resolved to
   * TEXT. Both callers need text: the menu row draws it, and the field's hint substitutes it.
   */
  private translatedFilterString(filter: string): string {
    const name: string = SearchFragmentPage.filterStringName(filter);
    return name.length === 0 ? filter : Localization.getString(name);
  }

  private static filterStringName(filter: string): string {
    if (filter === 'all') {
      return 'all';
    }
    if (filter === 'videos' || filter === 'sepia_videos' || filter === 'music_videos') {
      return 'videos_string';
    }
    if (filter === 'channels') {
      return 'channels';
    }
    if (filter === 'playlists' || filter === 'music_playlists') {
      return 'playlists';
    }
    if (filter === 'tracks') {
      return 'tracks';
    }
    if (filter === 'users') {
      return 'users';
    }
    if (filter === 'conferences') {
      return 'conferences';
    }
    if (filter === 'events') {
      return 'events';
    }
    if (filter === 'music_songs') {
      return 'songs';
    }
    if (filter === 'music_albums') {
      return 'albums';
    }
    if (filter === 'music_artists') {
      return 'artists';
    }
    return '';
  }

  /**
   * changeContentFilter(item, theContentFilter): re-hint, then re-run the query already on
   * screen. The hint carries the raw filter name where the source carries the menu title.
   */
  private changeContentFilter(filter: string): void {
    this.contentFilter = [filter];
    try {
      this.applyContentFilterHint(NewPipe.getService(this.serviceId));
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      hilog.warn(0x0000, TAG, 'getting service for id: %{public}s', failure.message);
    }
    if (this.searchString.length > 0) {
      this.search(this.searchString, this.contentFilter, this.sortFilter);
    }
  }

  /** ThemeHelper.getItemViewMode() - the one copy lives in ViewModeResolver. */
  private setupItemViewMode(): void {
    const store: AppPreferences = AppPreferences.instance();
    const mode: string = store.getStringSync(list_view_mode_key,
      store.resolveDefault(list_view_mode_value));
    this.itemViewMode = resolveItemViewMode(mode);
  }

  private async ensureLocalServices(): Promise<HistoryRecordManager | null> {
    const existing: HistoryRecordManager | null = this.historyRecordManager;
    if (existing !== null) {
      return existing;
    }
    try {
      const context: common.Context = getContext(this) as common.Context;
      const db: AppDatabase = await AppDatabase.getInstance(context);
      const history: HistoryRecordManager = new HistoryRecordManager(db);
      this.historyRecordManager = history;
      this.playlistManager = new LocalPlaylistManager(db);
      return history;
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.showSnackBarError(failure.message);
      return null;
    }
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Suggestions
  ////////////////////////////////////////////////////////////////////////// */

  /**
   * initSuggestionObserver()'s switchMap (the 120 ms debounce is S4's): local and remote
   * suggestions merged, local first, remote duplicates of a local entry dropped.
   */
  private async updateSuggestions(query: string): Promise<void> {
    const wantRemote: boolean =
      this.showRemoteSuggestions && query.length >= THRESHOLD_NETWORK_SUGGESTION;
    if (!this.showLocalSuggestions && !wantRemote) {
      this.suggestionsList.submitList([]);
      return;
    }
    const merged: SuggestionItem[] = [];
    if (this.showLocalSuggestions) {
      const history: HistoryRecordManager | null = await this.ensureLocalServices();
      if (history !== null) {
        try {
          const limit: number = wantRemote ? LOCAL_LIMIT_WITH_REMOTE : LOCAL_LIMIT_ALONE;
          const local: string[] =
            await history.getRelatedSearches(query, limit, LOCAL_LIMIT_ALONE);
          local.forEach((entry: string) => {
            merged.push(new SuggestionItem(true, entry));
          });
        } catch (err) {
          const failure: BusinessError = err as BusinessError;
          hilog.warn(0x0000, TAG, 'search history unreadable: %{public}s', failure.message);
        }
      }
    }
    if (wantRemote) {
      try {
        const remote: string[] = await ExtractorHelper.suggestionsFor(this.serviceId, query);
        remote.forEach((entry: string) => {
          let seen: boolean = false;
          merged.forEach((item: SuggestionItem) => {
            if (item.query === entry) {
              seen = true;
            }
          });
          if (!seen) {
            merged.push(new SuggestionItem(false, entry));
          }
        });
      } catch (err) {
        const failure: BusinessError = err as BusinessError;
        hilog.warn(0x0000, TAG, 'suggestions unavailable: %{public}s', failure.message);
      }
    }
    this.suggestionsList.submitList(merged);
    // The argument-free launch renders whatever the LOCAL search history holds, so this line is
    // what separates "the read never ran" from "the read ran and search_history is empty".
    hilog.info(0x0000, TAG, 'suggestions for %{public}s: %{public}d row(s), local=%{public}s',
      query.length === 0 ? '<empty query>' : query, merged.length,
      this.showLocalSuggestions ? 'on' : 'off');
  }

  /**
   * onSuggestionItemSelected(item): put the query in the field and run the search.
   *
   * T-0160: with the CURRENT filters, not a reset. This was the one caller of search() that
   * passed an empty content filter, so picking Channels and then re-running the query from a
   * suggestion row silently handed back unfiltered results - measured against the reference,
   * which keeps the filter (`Channels checked="true"`) where this port reset it to `all`.
   * Every other caller - the filter pick, the IME submit, the error-panel reload and the
   * correct-suggestion tap - already passes these two.
   */
  private onSuggestionItemSelected(item: SuggestionItem): void {
    this.searchQuery = item.query;
    this.search(item.query, this.contentFilter, this.sortFilter);
  }

  /** onSuggestionItemInserted(item): copy it into the field WITHOUT searching. */
  private onSuggestionItemInserted(item: SuggestionItem): void {
    this.searchQuery = item.query;
    this.publishSuggestionQuery(item.query);
  }

  /** onSuggestionItemLongClick(item): only a history row can be deleted. */
  private onSuggestionItemLongClick(item: SuggestionItem): void {
    this.fromHistory = item.fromHistory;
    if (!this.fromHistory) {
      return;
    }
    this.showDeleteSuggestionDialog(item);
  }

  /**
   * onSuggestionItemSwiped(viewHolder): delete that query from history, then re-emit the text
   * that is in the field right now so the list redraws without it.
   *
   * getSuggestionMovementFlags() only hands LEFT|RIGHT to a fromHistory row, so a remote
   * suggestion can never reach this — the guard is that rule, not defensiveness.
   */
  private onSuggestionItemSwiped(item: SuggestionItem): void {
    this.fromHistory = item.fromHistory;
    if (!this.fromHistory) {
      return;
    }
    this.deleteSearchHistory(item.query);
  }

  /** showDeleteSuggestionDialog(item): the title is the query, with Cancel / Delete. */
  private showDeleteSuggestionDialog(item: SuggestionItem): void {
    this.menuTitle = item.query;
    const actions: DialogAction[] = [];
    actions.push(new DialogAction($r('app.string.cancel'), 'Cancel', (): void => {
      // setNegativeButton(R.string.cancel, null): dismisses, nothing changes.
      hilog.info(0x0000, TAG, 'delete-from-history cancelled');
    }));
    actions.push(new DialogAction($r('app.string.delete'), 'Delete', (): void => {
      this.deleteSearchHistory(item.query);
    }));
    this.menuActions = actions;
    this.infoItemDialog.open();
  }

  /** historyRecordManager.deleteSearchHistory(query), then re-emit the current text. */
  private async deleteSearchHistory(query: string): Promise<void> {
    const history: HistoryRecordManager | null = await this.ensureLocalServices();
    if (history === null) {
      return;
    }
    try {
      await history.deleteSearchHistory(query);
      // suggestionPublisher.onNext(getSearchEditString()).
      this.publishSuggestionQuery(this.searchQuery);
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.showSnackBarError(failure.message);
    }
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Search
  ////////////////////////////////////////////////////////////////////////// */

  /**
   * search(theSearchString): an empty query does nothing, and a query NewPipe resolves as a
   * content URL opens that stream, channel or playlist instead of being searched.
   */
  private search(theSearchString: string, theContentFilter: string[],
    theSortFilter: string): void {
    if (theSearchString.length === 0) {
      return;
    }
    let service: StreamingService | null = null;
    try {
      service = NewPipe.getServiceByUrl(theSearchString);
    } catch (err) {
      // "Exception occurred, it's not a url" — carry on and search for it.
      hilog.debug(0x0000, TAG, 'not a supported url, searching for it instead');
    }
    if (service !== null) {
      this.openLink(service, theSearchString);
      return;
    }
    this.searchString = theSearchString;
    this.contentFilter = theContentFilter;
    this.sortFilter = theSortFilter;
    this.resultsList.clearItems();
    this.loadedCount = 0;
    this.suggestionsPanelVisible = false;
    this.metaInfoText = '';
    // store search query if search history is enabled
    this.recordSearched(theSearchString);
    // suggestionPublisher.onNext(theSearchString), then startLoading(false).
    this.publishSuggestionQuery(theSearchString);
    this.startLoading();
  }

  /**
   * NavigationHelper.getIntentByLink(): the page for that kind of link, opened in place of this
   * one (getFM().popBackStackImmediate() before startActivity), so Back skips the search. A link
   * the service resolves to nothing is the "Unsupported URL" error.
   */
  private openLink(service: StreamingService, url: string): void {
    const linkType: LinkType = service.getLinkTypeByUrl(url);
    const page: string = linkType === LinkType.STREAM ? 'pages/VideoDetailFragmentPage'
      : linkType === LinkType.CHANNEL ? 'pages/ChannelFragmentPage'
        : linkType === LinkType.PLAYLIST ? 'pages/PlaylistFragmentPage' : '';
    if (page.length === 0) {
      // showTextError(getString(R.string.unsupported_url)).
      this.hideErrorPanel();
      this.errorInfo = Localization.getString('unsupported_url');
      return;
    }
    router.replaceUrl({ url: page, params: new ItemParams(service.getServiceId(), url, '') })
      .catch((err: BusinessError): void => {
        hilog.error(0x0000, TAG, 'opening the link failed: %{public}s', err.message);
      });
  }

  /** historyRecordManager.onSearched(serviceId, theSearchString). */
  private async recordSearched(theSearchString: string): Promise<void> {
    const history: HistoryRecordManager | null = await this.ensureLocalServices();
    if (history === null) {
      return;
    }
    try {
      await history.onSearched(this.serviceId, theSearchString);
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      hilog.warn(0x0000, TAG, 'search not recorded: %{public}s', failure.message);
    }
  }

  /** BaseListInfoFragment.startLoading(): a new load disposes the previous one. */
  private startLoading(): void {
    this.disposeWorker();
    this.isLoading = true;
    this.hideErrorPanel();
    this.currentWorker = Observable
      .fromPromise(ExtractorHelper.searchFor(this.serviceId, this.searchString,
        this.contentFilter, this.sortFilter))
      .subscribeCallbacks((info: SearchInfo): void => {
        this.handleResult(info);
      }, (error: Error): void => {
        this.handleError(error);
      });
  }

  /** handleResult(result): the suggestion banner, the meta info, then the rows. */
  private handleResult(info: SearchInfo): void {
    this.searchSuggestion = info.getSearchSuggestion().trim();
    // String.format(helperText, "<b><i>" + escapeHtml(searchSuggestion) + "</i></b>") — the
    // emphasis is styling, so only the escaped text itself is carried here.
    this.didYouMeanBanner = this.searchSuggestion;
    this.isCorrectedSearch = info.isCorrectedSearch;
    // ExtractorHelper.showMetaInfoInTextView(): nothing at all while show_meta_info is off.
    const metaInfo: MetaInfoText = buildMetaInfoText(AppPreferences.instance()
      .getBooleanSync(show_meta_info_key, true) ? info.getMetaInfo() : []);
    this.metaInfoSpans = metaInfo.spans;
    this.metaInfoText = metaInfo.text;
    this.resultsList.clearItems();
    this.resultsList.addItems(info.getRelatedItems());
    this.loadedCount = this.resultsList.totalCount();
    this.nextPage = info.getNextPage();
    this.hasMoreItems = Page.isValid(this.nextPage);
    this.isLoading = false;
    this.hideErrorPanel();
  }

  /** loadMoreItemsLogic() -> ExtractorHelper.getMoreSearchItems(...). */
  private loadMoreItems(): void {
    const nextPage: Page | null = this.nextPage;
    if (!this.hasMoreItems || this.isLoading || nextPage === null) {
      return;
    }
    this.disposeWorker();
    this.isLoading = true;
    this.currentWorker = Observable
      .fromPromise(ExtractorHelper.getMoreSearchItems(this.serviceId, this.searchString,
        this.contentFilter, this.sortFilter, nextPage))
      .subscribeCallbacks((page: InfoItemsPage<InfoItem>): void => {
        this.resultsList.addItems(page.getItems());
        this.loadedCount = this.resultsList.totalCount();
        this.nextPage = page.getNextPage();
        this.hasMoreItems = Page.isValid(this.nextPage);
        this.isLoading = false;
      }, (error: Error): void => {
        this.handleError(error);
      });
  }

  /**
   * handleError(): super.handleError() clears the info cache and drops the loading/empty views,
   * then SearchFragment's override hides the suggestions panel and the keyboard alongside the
   * error panel.
   *
   * The panel shows the MIGRATED message ErrorInfo maps the throwable to — "Network error." for
   * an IOException. The port put `error.message` there instead, and a HarmonyOS BusinessError
   * stringifies to "[object Object]", which is what TC-SEARCH-221 photographed.
   */
  private handleError(error: Error): void {
    hilog.error(0x0000, TAG, 'search failed: %{public}s', error.message);
    this.isLoading = false;
    // A query that simply matched nothing is not a failure: the source clears the adapter and
    // shows the empty state, so the extractor's own "Nothing found" never reaches a panel
    // (TC-SEARCH-036).
    if (error instanceof NothingFoundException) {
      this.resultsList.clearItems();
      this.loadedCount = 0;
      this.nextPage = null;
      this.hasMoreItems = false;
      this.hideErrorPanel();
      this.suggestionsPanelVisible = false;
      return;
    }
    InfoCache.getInstance().clearCache();
    const info: ErrorInfo = ErrorInfo.fromThrowable(error, UserAction.SEARCHED,
      `Searching for: ${this.searchString}`, this.serviceId);
    this.lastPanelError = info;
    this.errorInfo = info.message.formatArgs.length === 0
      ? Localization.getString(info.message.stringName)
      : Localization.getStringArgs(info.message.stringName, info.message.formatArgs);
    // ErrorPanelHelper:101-107 — the recaptcha challenge takes the action button when there is
    // one, otherwise Report, and neither when the error is not worth reporting.
    this.errorActionLabel = info.recaptchaUrl !== null
      ? Localization.getString('recaptcha_solve')
      : (info.isReportable ? Localization.getString('error_snackbar_action') : '');
    this.openInBrowserUrl = info.openInBrowserUrl;
    this.suggestionsPanelVisible = false;
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

  /** ErrorPanelHelper -> reloadContent(): re-run the last query, or clear back to the field. */
  private reloadContent(): void {
    if (this.searchString.length === 0 && this.searchQuery.length === 0) {
      // searchEditText.setText(""); showKeyboardSearch(); hideErrorPanel();
      this.hideErrorPanel();
      this.searchQuery = '';
      this.suggestionsPanelVisible = true;
      this.publishSuggestionQuery('');
      return;
    }
    this.hideErrorPanel();
    this.search(this.searchString.length > 0 ? this.searchString : this.searchQuery,
      this.contentFilter, this.sortFilter);
  }

  /* //////////////////////////////////////////////////////////////////////////
  // The toolbar's own controls
  ////////////////////////////////////////////////////////////////////////// */

  /** toolbar_search_clear: a BLANK field is gotoMainFragment(), otherwise it clears. */
  private clearOrLeave(): void {
    if (this.searchQuery.length === 0) {
      router.back();
      return;
    }
    this.searchSuggestion = '';
    this.searchQuery = '';
    this.suggestionsPanelVisible = true;
    this.publishSuggestionQuery('');
  }

  /** correct_suggestion tap: hide it, search the suggestion, and put it in the field. */
  private acceptSearchSuggestion(): void {
    const suggestion: string = this.searchSuggestion;
    this.searchSuggestion = '';
    this.searchQuery = suggestion;
    // search(searchSuggestion, contentFilter, sortFilter) — the CURRENT filters, not a reset.
    this.search(suggestion, this.contentFilter, this.sortFilter);
  }

  /**
   * correct_suggestion long press: the suggestion goes into the field with the caret at its end
   * and the keyboard up (setText + setSelection + showKeyboardSearch), without searching.
   */
  private insertSearchSuggestion(): void {
    const suggestion: string = this.searchSuggestion;
    this.searchQuery = suggestion;
    this.publishSuggestionQuery(suggestion);
    try {
      this.getUIContext().getFocusController().requestFocus('toolbar_search_edit_text');
    } catch (err) {
      hilog.warn(0x0000, TAG, 'search field not focusable: %{public}s', (err as BusinessError).message);
    }
    // After the field has taken the new text, or the caret lands inside the old one.
    setTimeout((): void => {
      this.searchInputController.caretPosition(suggestion.length);
    }, 0);
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Row gestures
  ////////////////////////////////////////////////////////////////////////// */

  /** onItemSelected(): each subtype has its OWN destination. */
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

  /** onItemHeld(): showInfoItemDialog(item) — streams only, as in the source. */
  private onItemHeld(item: InfoItem): void {
    if (!(item instanceof StreamInfoItem)) {
      return;
    }
    const stream: StreamInfoItem = item as StreamInfoItem;
    this.heldItem = stream;
    this.menuTitle = stream.getName();

    // InfoItemDialog.Builder owns the entry list and its order. This screen used to offer three
    // entries of its own - Add to playlist, Share, Open in browser - against the reference's
    // nine, measured on a long press on "Me at the zoo" in search results.
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
      enqueueOnCurrentPlayQueue([PlayQueueItem.fromStreamInfoItem(stream)]);
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
      this.startPlayer(stream, true);
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
      this.popupServiceId = stream.serviceId;
      this.popupUrl = stream.url;
      this.popupSurfaceMounted = true;
    };
    handlers.onDownload = (): void => {
      this.downloadServiceId = stream.getServiceId();
      this.downloadUrl = stream.getUrl();
      this.showDownloadDialog = true;
    };
    handlers.onAddToPlaylist = (): void => {
      this.openAppendPicker();
    };
    handlers.onMarkAsWatched = (): void => {
      this.markAsWatched(stream);
    };
    handlers.onShowChannelDetails = (): void => {
      router.pushUrl({
        url: 'pages/ChannelFragmentPage',
        params: new ItemParams(stream.getServiceId(), target.uploaderUrl,
          stream.getUploaderName())
      });
    };

    this.menuActions = buildStreamMenuActions(target, handlers);
    this.infoItemDialog.open();
  }

  /** The in-place start every other list uses: resolve the stream and hand it to the player. */
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

  /** StreamDialogDefaultEntry.MARK_AS_WATCHED -> recordManager.markAsWatched(item). */
  private async markAsWatched(stream: StreamInfoItem): Promise<void> {
    const history: HistoryRecordManager | null = await this.ensureLocalServices();
    if (history === null) {
      return;
    }
    try {
      await history.markAsWatched(stream);
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      promptAction.showToast({ message: failure.message, duration: 2000 });
    }
  }

  /** StreamDialogDefaultEntry.APPEND_PLAYLIST -> the local-playlist picker over this list. */
  private async openAppendPicker(): Promise<void> {
    if (await this.ensureLocalServices() === null) {
      return;
    }
    const manager: LocalPlaylistManager | null = this.playlistManager;
    if (manager === null) {
      return;
    }
    try {
      const playlists: PlaylistMetadataEntry[] = await manager.getPlaylists();
      this.appendPlaylists.setItems(playlists);
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.showSnackBarError(failure.message);
    }
  }

  /** The picker's row tap: append the held stream to the chosen playlist. */
  private async appendToPlaylist(playlist: PlaylistLocalItem): Promise<void> {
    const manager: LocalPlaylistManager | null = this.playlistManager;
    const item: StreamInfoItem | null = this.heldItem;
    this.appendPlaylists.setItems([]);
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

  private showSnackBarError(message: string): void {
    hilog.error(0x0000, TAG, '%{public}s', message);
    promptAction.showToast({ message: message, duration: 3000 });
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Builders
  ////////////////////////////////////////////////////////////////////////// */

  /** getListHeaderSupplier() == null for a search, so the slot never renders. */
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
      FallbackViewHolder()
    }
  }

  /** SuggestionListAdapter.onBindViewHolder(): the three listeners it installs per row. */
  @Builder
  suggestionRow(item: SuggestionItem) {
    SuggestionItemHolder({
      item: item,
      onSelected: (): void => {
        this.onSuggestionItemSelected(item);
      },
      onInserted: (): void => {
        this.onSuggestionItemInserted(item);
      },
      onLongClick: (): void => {
        this.onSuggestionItemLongClick(item);
      }
    })
  }

  /** LocalItemListAdapter.getItemViewType() + onCreateViewHolder() for the append picker. */
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

  /** PlaylistItemHolder: the views every playlist row shares. */
  @Builder
  playlistBody(item: PlaylistLocalItem) {
    PlaylistItemHolder({
      thumbnailUrl: item.thumbnailUrl,
      title: item.orderingName,
      showUploader: item.localItemType === LocalItemType.PLAYLIST_REMOTE_ITEM
    })
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
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        // toolbar_search_layout.xml — the ACTIVITY toolbar's search row.
        Row() {
          // MainActivity.updateDrawerNavigation(): every fragment that is NOT MainFragment gets
          // setDisplayHomeAsUpEnabled(true) and a navigation click of onHomeButtonPressed(). From
          // SearchFragment that is popBackStackImmediate(SEARCH_FRAGMENT_TAG, 0) — false, since
          // nothing sits above it — then gotoMainFragment(). The 24dp glyph is centred in the
          // ?attr/actionBarSize target (capture: [0,72][168,240] at density 3.0), and it is what
          // insets the field to 72dp.
          Image($r('app.media.ic_arrow_back'))
            .id('navigate_up')
            .accessibilityText($r('app.string.navigate_back'))
            .width(56)
            .height(56)
            .padding(16)
            .objectFit(ImageFit.Contain)
            .fillColor($r('app.color.on_primary'))
            .onClick(() => {
              router.back();
            })

          TextInput({ text: this.searchQuery, placeholder: this.searchInputHint,
            controller: this.searchInputController })
            .id('toolbar_search_edit_text')
            .layoutWeight(1)
            // NewPipeEditText: match_parent in the ?attr/actionBarSize toolbar, 4dp top/bottom
            // margins, android:background="@null". ArkUI's TextInput paints a rounded filled
            // field of its own, so it is cleared back to the bare text the source draws.
            .height(48)
            .margin({ top: 4, bottom: 4, left: 16 })
            .padding({ left: 0, right: 0, top: 0, bottom: 0 })
            .backgroundColor(Color.Transparent)
            .borderRadius(0)
            // AppCompat EditText default 18sp (measured 39px glyph span at density 3 in the
            // capture); textColor ?attr/toolbarSearchColor = @color/white.
            .fontSize(18)
            .fontColor($r('app.color.on_primary'))
            .caretColor($r('app.color.on_primary'))
            // TC-SEARCH-235: the HINT is a size smaller than the text the user types, and only
            // the hint. Both are 18 in the source, but this platform's default face is wider than
            // the reference's: measured on the two devices, the same nominal 18 draws at about
            // 8.7 vp per character here against 6.8 there. `Search YouTube (Playlists)` fits the
            // reference's 200 vp field and overflowed this one's 206 vp, and ArkUI breaks at the
            // last space - so the whole `(Playlists)` was dropped and the hint named no filter at
            // all. A hint that fits carries more of the reference's meaning than a matching font
            // size that loses the filter name.
            .placeholderFont({ size: PLACEHOLDER_FONT_SIZE })
            .placeholderColor(COLOR_TOOLBAR_HINT)
            .maxLines(1)
            .enterKeyType(EnterKeyType.Search)
            .onChange((value: string) => {
              // onViewCreated calls showSearchOnStart() (searchEditText.setText(searchString))
              // BEFORE initSearchListeners(), so the source's TextWatcher never sees a
              // programmatic set — only a keystroke opens the suggestions panel. ArkUI fires
              // onChange for our own write too, and the write is what makes value === searchQuery.
              if (value === this.searchQuery) {
                return;
              }
              // the TextWatcher: push the trimmed text into suggestionPublisher, debounced.
              this.searchQuery = value;
              this.suggestionsPanelVisible = true;
              this.publishSuggestionQuery(value.trim());
            })
            .onFocus(() => {
              this.suggestionsPanelVisible = true;
            })
            .onSubmit((enterKey: EnterKeyType, event: SubmitEvent) => {
              // setOnEditorActionListener: ENTER / IME_ACTION_SEARCH runs the search.
              this.search(this.searchQuery.trim(), this.contentFilter, this.sortFilter);
            })

          // toolbar_search_clear: the 48dp frame around ic_close.
          Row() {
            Image($r('app.media.ic_close'))
              .id('toolbar_search_clear_icon')
              .width(24)
              .height(24)
              .objectFit(ImageFit.Contain)
              // app:tint="?attr/toolbarSearchColor"
              .fillColor($r('app.color.on_primary'))
          }
          .id('toolbar_search_clear')
          .accessibilityText($r('app.string.clear'))
          .width(48)
          .height(48)
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.clearOrLeave();
          })

          // The ActionBar overflow the capture records as "More options" — no resource-id in
          // the source, so the slug is its content-desc. Its rows are onCreateOptionsMenu's
          // content filters.
          //
          // T-0161: and ONLY when there are any. onCreateOptionsMenu inflates this overflow from
          // getAvailableContentFilter(), so a service that publishes none never gets the button -
          // which is why the reference draws no overflow at all on a Bandcamp search. This port
          // drew it unconditionally, so on Bandcamp it was a button that opened an empty popup:
          // measured on the device, the node tree before and after the tap was identical, no menu
          // node of any kind. The test is on the SERVICE's filter list, not on the service, so
          // every service with nothing to choose behaves the same and none is special-cased.
          if (this.contentFilterMenu.length > 0) {
            Image($r('app.media.ic_more_vert'))
              .id('more_options')
              .accessibilityText($r('app.string.more_options'))
              .width(48)
              .height(48)
              .padding(12)
              .objectFit(ImageFit.Contain)
              .fillColor($r('app.color.on_primary'))
              .bindMenu(this.contentFilterMenuContent(), FILTER_MENU_OPTIONS)
          }
        }
        .width('100%')
        // The toolbar band: ?attr/actionBarSize tall on ?attr/colorPrimary. The capture's 72dp
        // text inset is the ACTIVITY toolbar's navigation button, which this page does not
        // render, so the field keeps the Toolbar's plain 16dp contentInsetStart.
        .height(56)
        .alignItems(VerticalAlign.Center)
        // ThemeHelper.setTheme(context, serviceId): the band is the ACTIVE service's
        // ?attr/colorPrimary, so a PeerTube search is orange-red and not YouTube red.
        .backgroundColor(servicePrimaryColor(this.serviceId))

        Stack() {
          Column() {
            // correct_suggestion: GONE while the result carries no suggestion.
            if (this.searchSuggestion.length > 0) {
              Text(this.isCorrectedSearch
                ? $r('app.string.search_showing_result_for', this.didYouMeanBanner)
                : $r('app.string.did_you_mean', this.didYouMeanBanner))
                .id('correct_suggestion')
                .width('100%')
                .padding(12)
                .fontSize($r('app.float.search_suggestion_text_size'))
                .fontColor(COLOR_ON_SURFACE)
                .onClick(() => {
                  this.acceptSearchSuggestion();
                })
                .gesture(LongPressGesture().onAction(() => {
                  this.insertSearchSuggestion();
                }))
            }

            // search_meta_info_text_view plus its 1px separator.
            if (this.metaInfoText.length > 0) {
              // TextLinkifier.fromHtml(..., SET_LINK_MOVEMENT_METHOD): each meta-info link is a
              // UrlLongPressClickableSpan - a tap opens it, a long press copies it.
              Column() {
                NewPipeTextView({
                  slug: 'search_meta_info_text_view',
                  content: this.metaInfoText,
                  linkSpans: this.metaInfoSpans,
                  // @dimen/video_item_detail_description_text_size
                  textSizeFp: 13,
                  textColorValue: COLOR_ON_SURFACE,
                  textAlignment: TextAlign.Center,
                  onLinkTapped: (span: LinkSpan): void => {
                    const url: string | null = span.url;
                    if (url !== null) {
                      openUrlLink(url);
                    }
                  },
                  onLinkLongPressed: (span: LinkSpan): void => {
                    ServiceLocator.get().share.copyToClipboard(linkTextToCopy(span, this.serviceId, ''));
                  }
                })
              }
              .width('100%')
              .padding(12)
              Divider()
                .id('search_meta_info_separator')
                .strokeWidth(1)
                .color($r('app.color.separator'))
                .margin({ left: 8, right: 8 })
            }

            InfoListAdapter({
              dataSource: this.resultsList,
              viewMode: this.itemViewMode,
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
          .width('100%')
          .height('100%')

          // The append-to-playlist picker the long-press dialog opens over this list.
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
              .color(servicePrimaryColor(this.serviceId))
          }

          // handleError(): the error_panel include. It is a message and up to THREE buttons -
          // the port drew only the message and Retry, which is TC-SEARCH-221's 'displayed
          // incompletely'. Same shape as KioskFragmentPage's, which is the panel every other
          // ported list screen shows.
          if (this.errorInfo !== null) {
            Column() {
              // error_panel.xml: 16sp bold, centred, in a 16dp-padded column.
              Text(this.errorInfo)
                .id('error_message_view')
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor(COLOR_ON_SURFACE)
                .textAlign(TextAlign.Center)

              // ServiceColoredButton: colorButtonNormal = ?attr/colorPrimary, white label,
              // android:textAllCaps - which is where RETRY's casing comes from.
              // error_panel.xml orders the actions REPORT, RETRY, OPEN IN BROWSER, and the reference
              // build shows exactly that on a reportable failure - device-checked on an invalid video
              // link, which renders "Could not parse website" above REPORT / RETRY / OPEN IN BROWSER.
              // This page had retry first, so the report action sat in the middle. A network failure
              // carries no action label and still shows only RETRY and OPEN IN BROWSER, as it should.
              if (this.errorActionLabel.length > 0) {
                Button(this.errorActionLabel.toUpperCase())
                  .id('error_button_action')
                  .type(ButtonType.Normal)
                  .fontSize(16)
                  .fontColor($r('app.color.on_primary'))
                  .backgroundColor(servicePrimaryColor(this.serviceId))
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
                .fontSize(16)
                .fontColor($r('app.color.on_primary'))
                .backgroundColor(servicePrimaryColor(this.serviceId))
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
                  .fontSize(16)
                  .fontColor($r('app.color.on_primary'))
                  .backgroundColor(servicePrimaryColor(this.serviceId))
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
          if (!this.isLoading && this.errorInfo === null && this.loadedCount === 0
            && this.searchString.length > 0) {
            Column() {
              Text('╰(°●°╰)')
                .fontFamily('monospace')
                .fontSize(35)
                .fontColor(COLOR_ON_SURFACE)
                .margin({ bottom: 10 })
              Text($r('app.string.search_no_results'))
                .fontSize(24)
                .fontColor(COLOR_ON_SURFACE)
            }
            .id('empty_state_view')
            .alignItems(HorizontalAlign.Center)
          }

          // suggestions_panel: match_parent OVER the results list, with its own opaque
          // background. It lives INSIDE fragment_holder in the source, so it covers the results
          // and nothing else — the toolbar above it stays tappable while it is up.
          // showSuggestionsPanel() is only ever reached when at least one suggestion source is on
          // ((showLocalSuggestions || showRemoteSuggestions) && !isErrorPanelVisible()), so with both
          // switched off in settings the panel does not exist at all.
          if (this.suggestionsPanelVisible && (this.showLocalSuggestions || this.showRemoteSuggestions)) {
            Column() {
              SuggestionListAdapter({
                dataSource: this.suggestionsList,
                row: (item: SuggestionItem): void => {
                  this.suggestionRow(item);
                },
                onSwiped: (item: SuggestionItem): void => {
                  this.onSuggestionItemSwiped(item);
                }
              })
            }
            .id('suggestions_panel')
            .width('100%')
            .height('100%')
            .backgroundColor(themedBackground(this.blackTheme))
          }
        }
        .width('100%')
        .layoutWeight(1)
        .backgroundColor(themedBackground(this.blackTheme))

        // fragment_player_holder, docked. This screen is only ever a pushUrl target, so the shell
        // sits underneath it and its bar cannot draw here. The root is a Stack, but its single
        // child is this full-height Column whose results Stack carries layoutWeight(1), so the bar
        // docks as the Column's last child - shortening the results instead of covering the last
        // row - and needs neither a bottom-aligned wrapper nor an inset.
        MiniPlayerBar({ idPrefix: 'search_' })
      }
      .width('100%')
      .height('100%')

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
    .id('SearchFragmentPage')
    .width('100%')
    .height('100%')
    .backgroundColor(themedBackground(this.blackTheme))
  }

  /** DownloadDialog over the results, mounted the way the feed and the kiosks mount it. */
}
