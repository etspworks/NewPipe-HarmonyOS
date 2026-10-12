/**
 * S3 - RelatedItemsFragment (screen_related_items), fragment_related_items.xml +
 * related_items_header.xml + list_stream_item.xml / list_stream_card_item.xml.
 *
 * Also a registered route, but in practice it is MOUNTED by screen_video_detail as a TabContent
 * (source TabAdapter/ViewPager2), or on layout-large-land committed permanently into
 * R.id.relatedItemsLayout: VideoDetailFragmentPage instantiates this struct. It overrides
 * setTitle() and onCreateOptionsMenu() to NO-OPS - it must not touch the action bar.
 *
 * fragment_related_items.xml is the SAME RelativeLayout as fragment_comments: items_list fills
 * it, with loading_progress_bar, empty_state_view and error_panel overlaid and mutually
 * exclusive - so the root is a Stack, not a Column of siblings.
 *
 * It performs NO network call and NEVER paginates: the items come from StreamInfo.relatedItems,
 * which the HOST already loaded. An empty list here therefore means the extractor returned
 * nothing, not a load failure - S6 must not dress it as an error, and showFooter stays false.
 *
 * The list is POLYMORPHIC (InfoListAdapter over InfoItem), which is why the plan gives this
 * screen THREE push edges. The row branches on the item type and each subtype has its OWN
 * destination, all through rows sharing ONE `itemRoot` slug (Rule 12's list-row exception - the
 * replay resolves rows by index):
 *   stream row   -> openVideoDetailFragment -> VideoDetailFragment
 *   channel row  -> ChannelFragment
 *   playlist row -> PlaylistFragment
 *
 * Source facts this tree reproduces:
 *  - The autoplay row is a REAL ADAPTER ROW injected by getListHeaderSupplier() at position 0,
 *    not page chrome - hence InfoListAdapter's `hasHeader` slot rather than a Column above it.
 *    The supplier returns NULL when relatedItemsInfo (or its items) is null, so there is then no
 *    header row at all: a conditionalVariant bound to relatedItemsInfo.
 *  - autoplay_switch reads prefs auto_queue_key on bind, writes it on change, AND is pushed back
 *    by onSharedPreferenceChanged when something else changes it. Two-way, through
 *    svc_preferences - S4 wires both directions.
 *  - getItemViewMode() is CLAMPED to LIST or CARD; GRID and MINI fall back to LIST, which is why
 *    the row branch below never selects a grid or mini holder.
 *  - showLoading() sets the header root INVISIBLE (not GONE) so the list does not jump;
 *    handleResult sets it back to VISIBLE and slides the view up.
 *  - Long-press opens InfoItemDialog attached to the PARENT fragment, so it survives the host
 *    loading a new stream.
 *
 * S4 binds relatedItemsList to StreamInfo.relatedItems and the switch to the preference; S5/S6
 * style it - no colours, spacing or typography are chosen here.
 */
import { servicePrimaryColor, DIALOG_MASK_COLOR } from '../common/theme/ServiceTheme';
import { router, promptAction } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

import { InfoItem } from '../common/extractor/core/InfoItem';
import { toError } from '../common/extractor/core/Errors';
import { StreamInfo } from '../model/extractor/StreamInfo';
import { ExtractorHelper } from '../common/extractor/ExtractorHelper';
import { AppPreferences } from '../common/prefs/Preferences';
import { Localization } from '../common/i18n/Localization';
import {
  auto_queue_key,
  list_view_mode_key,
  list_view_mode_value,
  list_view_mode_card_key
} from '../common/prefs/SettingsKeys';
import { StreamInfoItem } from '../model/extractor/StreamInfoItem';
import { ChannelInfoItem } from '../model/extractor/ChannelInfoItem';
import { PlaylistInfoItem } from '../model/extractor/PlaylistInfoItem';
import { CommentsInfoItem } from '../model/extractor/CommentsInfoItem';
import { ErrorInfo } from '../model/app/ErrorInfo';
import { UserAction } from '../model/enums/UserAction';
import { ServiceLocator } from '../common/di/ServiceLocator';

import { InfoListAdapter, InfoItemDataSource, ItemViewMode } from '../components/InfoListAdapter';
import { InfoItemHolder } from '../components/InfoItemHolder';
import { HFHolder } from '../components/HFHolder';
import { InfoItemDialog, DialogAction } from '../components/InfoItemDialog';
import { PlayQueueItem } from '../model/app/PlayQueueItem';
import { enqueueOnCurrentPlayQueue } from '../model/app/PlayQueue';
import { FallbackViewHolder } from '../components/FallbackViewHolder';
import { CommentInfoItemHolder } from '../components/CommentInfoItemHolder';
import { StreamMiniInfoItemHolder } from '../components/StreamMiniInfoItemHolder';
import { common } from '@kit.AbilityKit';
import { StreamInfoItemHolder } from '../components/StreamInfoItemHolder';
import { buildStreamMenuActions, StreamMenuHandlers,
  StreamMenuTarget } from '../components/InfoItemDialog';
import { enqueueStream, markStreamAsWatched,
  startStreamInPlace, enqueueNextStream } from '../common/util/StreamRowActions';
import { isAudioStream, isLiveStream } from '../model/app/StreamItem';
import { PlaylistAppendDialog } from '../components/PlaylistAppendDialog';
import { PlaylistCreationDialog } from '../components/PlaylistCreationDialog';
import { PlaylistMetadataEntry } from '../model/db/view/PlaylistMetadataEntry';
import { PlaylistLocalItem } from '../model/db/view/PlaylistLocalItem';
import { StreamEntity } from '../model/db/entity/StreamEntity';
import { LocalPlaylistManager, playlistAppendToast } from '../common/db/PlaylistManager';
import { AppDatabase } from '../common/db/AppDatabase';
import { openPopupOnSurface, PopupPlayerSurface } from '../components/PopupPlayerSurface';
import { DownloadDialogHost } from './DownloadDialogPage';
import { StreamGridInfoItemHolder } from '../components/StreamGridInfoItemHolder';
import { StreamCardInfoItemHolder } from '../components/StreamCardInfoItemHolder';
import { ChannelMiniInfoItemHolder } from '../components/ChannelMiniInfoItemHolder';
import { ChannelInfoItemHolder } from '../components/ChannelInfoItemHolder';
import { ChannelGridInfoItemHolder } from '../components/ChannelGridInfoItemHolder';
import { ChannelCardInfoItemHolder } from '../components/ChannelCardInfoItemHolder';
import { PlaylistMiniInfoItemHolder } from '../components/PlaylistMiniInfoItemHolder';
import { PlaylistInfoItemHolder } from '../components/PlaylistInfoItemHolder';
import { PlaylistGridInfoItemHolder } from '../components/PlaylistGridInfoItemHolder';
import { PlaylistCardInfoItemHolder } from '../components/PlaylistCardInfoItemHolder';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

const TAG: string = 'RelatedItemsFragmentPage';

/** NavigationHelper's per-destination arguments (serviceId, url, name). */
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
export struct RelatedItemsFragmentPage {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  /** headerBinding.autoplaySwitch <- prefs auto_queue_key; two-way, never a literal. */
  @Prop autoplaySwitch: boolean = false;
  /**
   * new RelatedItemsInfo(streamInfo).getRelatedItems(). The array is the BOUND value; the data
   * source beside it is what LazyForEach reads.
   */
  @Watch('onRelatedItemsListChanged') @Prop relatedItemsList: InfoItem[] = [];
  /**
   * Whether there is a RelatedItemsInfo at all - getListHeaderSupplier() returns null without
   * one, so there is then no autoplay header row.
   */
  @State relatedItemsInfo: boolean = false;
  /** How many rows the adapter holds - the empty branch reads it. */
  @State loadedCount: number = 0;
  @State isLoading: boolean = false;
  @State errorInfo: string | null = null;
  /**
   * BaseStateFragment.lastPanelError - the classified error ErrorPanelHelper's action button
   * acts on. error_panel.xml declares error_action_button and ErrorPanelHelper shows it for a
   * reCaptcha challenge, else for a reportable error; without it the panel is unreportable.
   */
  @State panelError: ErrorInfo | null = null;

  /** getItemViewMode(), clamped: GRID and MINI both fall back to LIST here. */
  @State itemViewMode: ItemViewMode = ItemViewMode.LIST;
  /**
   * AppearanceSettingsFragmentPage publishes the chosen list_view_mode here right after it writes
   * the preference, so a page that is ALREADY drawn re-reads it instead of keeping the template it
   * was built with. @Watch never fires on init, so aboutToAppear's own read still stands.
   */
  @StorageProp('listViewMode') @Watch('setupItemViewMode')
  private listViewModeSignal: string = '';

  /** showInfoItemDialog(item): the long-press menu title and its entries. */
  @State menuTitle: string = '';
  @State menuActions: DialogAction[] = [];

  private relatedItemsSource: InfoItemDataSource = new InfoItemDataSource();
  /** The host page's route arguments; the pager mounts this tab inside the same page. */
  private serviceId: number = 0;
  private url: string = '';

  /**
   * getInstance(StreamInfo) -> setInitialData(info): the HOST hands this fragment the StreamInfo
   * it has already loaded, and loadResult() is `Single.fromCallable(() -> relatedItemsInfo)` — it
   * performs no extraction of its own. VideoDetailFragmentPage mounts this struct instead of
   * constructing a fragment, so those constructor arguments arrive as props.
   *
   * They were missing: both mount sites passed NOTHING, router.getParams() carried no stream on
   * the pager tab, and every launch took the "no StreamInfo" error path.
   */
  @Prop hostServiceId: number = -1;
  @Watch('onHostStreamChanged') @Prop hostUrl: string = '';
  /**
   * Watched as well as hostUrl: ArkUI syncs the two props one at a time, so the url's watcher
   * ran while the items were still the previous (empty) list and cleared the tab - every stream
   * showed no related items and no autoplay header. The items' own sync now reloads it.
   */
  @Watch('onHostStreamChanged') @Prop hostRelatedItems: InfoItem[] = [];

  aboutToAppear(): void {
    this.setupItemViewMode();
    this.readArguments();
    this.readAutoQueuePreference();
    this.loadRelatedItems();
  }

  /**
   * getItemViewMode(): super's LIST / GRID / CARD preference, CLAMPED here -
   *
   *   ItemViewMode mode = super.getItemViewMode();
   *   // Only list mode is supported. Either List or card will be used.
   *   if (mode != ItemViewMode.LIST && mode != ItemViewMode.CARD) { mode = ItemViewMode.LIST; }
   *
   * so GRID picks the card template's LIST fallback, never a grid holder, and this list is never
   * laned - the column count is a GRID-only affair. It still decides the ROW: a CARD preference
   * draws the card holders below, which nothing could reach while this was never assigned.
   */
  private setupItemViewMode(): void {
    const store: AppPreferences = AppPreferences.instance();
    const mode: string = store.getStringSync(list_view_mode_key,
      store.resolveDefault(list_view_mode_value));
    this.itemViewMode = mode === list_view_mode_card_key ? ItemViewMode.CARD : ItemViewMode.LIST;
  }

  /**
   * loadItem() can swap the host's stream while this tab stays mounted (the pager keys its pages
   * by tab, not by stream), where the source would have built a fresh fragment for the new
   * StreamInfo. Re-running setInitialData + loadResult is that rebuild.
   */
  private onHostStreamChanged(): void {
    this.readArguments();
    this.loadRelatedItems();
  }

  private readArguments(): void {
    // setInitialData(info.getServiceId(), info.getUrl(), info.getName()) — the host's values win
    // whenever it supplied them; router.getParams() only serves the registered-route entry.
    if (this.hostUrl.length !== 0) {
      this.serviceId = this.hostServiceId;
      this.url = this.hostUrl;
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
    const streamUrl: Object | undefined = params['url'];
    if (streamUrl !== undefined && streamUrl !== null) {
      this.url = streamUrl.toString();
    }
  }

  /**
   * headerBinding.autoplaySwitch.setChecked(pref.getBoolean(auto_queue_key, false)), and the
   * onSharedPreferenceChanged half is the same read on every re-entry.
   */
  private readAutoQueuePreference(): void {
    this.autoplaySwitch = AppPreferences.instance().getBooleanSync(auto_queue_key, false);
  }

  /**
   * The fragment is constructed with the StreamInfo the host already loaded and performs NO
   * network call of its own; ExtractorHelper returns that same cached instance.
   */
  private async loadRelatedItems(forceLoad: boolean = false): Promise<void> {
    if (this.hostUrl.length !== 0) {
      // loadResult() is `Single.fromCallable(() -> relatedItemsInfo)` — the host's StreamInfo,
      // never a fetch. forceLoad changes nothing here, exactly as in the source.
      const items: InfoItem[] = this.hostRelatedItems;
      this.isLoading = false;
      this.errorInfo = null;
      this.panelError = null;
      // getListHeaderSupplier() returns null when there is no RelatedItemsInfo - NOT when that
      // info's item list happens to be empty. Keying the header off the item COUNT hid the
      // autoplay row (the "Auto-enqueuing" toggle) on every stream the extractor returned no
      // related items for, and the toggle is the header's whole content.
      this.relatedItemsInfo = true;
      this.relatedItemsList = items;
      return;
    }
    if (this.url.length === 0) {
      // loadResult() is `Single.fromCallable(() -> relatedItemsInfo)` and relatedItemsInfo is
      // set ONLY by setInitialData(StreamInfo). With no StreamInfo the callable yields null,
      // which RxJava3 turns into onError -> BaseListInfoFragment.showError() -> the error panel
      // (R.string.error_snackbar_message). The source never shows the empty state here, so
      // returning silently left this screen with no error text and no interactive node at all.
      this.isLoading = false;
      const missing: Error = new Error('no StreamInfo: RelatedItemsFragment was not given one');
      this.panelError = ErrorInfo.fromThrowable(missing, UserAction.REQUESTED_STREAM, this.url,
        this.serviceId);
      this.errorInfo = Localization.getString('error_snackbar_message');
      return;
    }
    this.isLoading = true;
    this.errorInfo = null;
    this.panelError = null;
    try {
      const info: StreamInfo =
        await ExtractorHelper.getStreamInfo(this.serviceId, this.url, forceLoad);
      const items: InfoItem[] = info.getRelatedItems();
      // A loaded StreamInfo IS the RelatedItemsInfo, however many items came with it.
      this.relatedItemsInfo = true;
      this.relatedItemsList = items;
    } catch (err) {
      // toError() is the port's ONE narrowing for a catch binding (ArkTS forbids typing one).
      // The hand-rolled copy below it was fine, but `(err as BusinessError).message` was not: a
      // non-Error throw has no `message`, so the panel was shown with undefined text and the
      // retry button under a blank error.
      const failure: Error = toError(err as Object);
      this.panelError = ErrorInfo.fromThrowable(failure, UserAction.REQUESTED_STREAM, this.url,
        this.serviceId);
      this.errorInfo = failure.message;
    } finally {
      this.isLoading = false;
    }
  }

  /** The @Prop is the bound value; the data source mirrors it for LazyForEach. */
  private onRelatedItemsListChanged(): void {
    this.relatedItemsSource.clearItems();
    this.relatedItemsSource.addItems(this.relatedItemsList);
    this.loadedCount = this.relatedItemsList.length;
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

  /** The stream the menu was raised for. */
  private heldItem: StreamInfoItem | null = null;
  /** The playlists PlaylistAppendDialog lists; empty means the creation dialog instead. */
  @State appendList: PlaylistMetadataEntry[] = [];
  private appendTarget: StreamInfoItem | null = null;
  private appendManager: LocalPlaylistManager | null = null;

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

  /** BaseListFragment.useMiniVariant - false, and the clamp keeps the mini holders unreachable. */
  private useMiniVariant: boolean = false;

  private errorText(): string {
    return this.errorInfo === null ? '' : this.errorInfo;
  }

  /**
   * ErrorPanelHelper.showError(): the action button is the reCaptcha challenge, else the report
   * action, else nothing at all. android:textAllCaps="true" on every error_panel button.
   */
  private errorActionLabel(): string {
    const info: ErrorInfo | null = this.panelError;
    if (info === null) {
      return '';
    }
    if (info.recaptchaUrl !== null) {
      return Localization.getString('recaptcha_solve').toUpperCase();
    }
    return info.isReportable ? Localization.getString('error_snackbar_action').toUpperCase() : '';
  }

  /** ErrorPanelHelper.showAndSetErrorButtonAction(): ReCaptchaActivity, else ErrorUtil.openActivity. */
  private runErrorAction(): void {
    const info: ErrorInfo | null = this.panelError;
    if (info === null) {
      return;
    }
    const recaptchaUrl: string | null = info.recaptchaUrl;
    if (recaptchaUrl !== null) {
      // ReCaptchaActivityPage reads its challenge url from the `recaptcha_url` param.
      const challenge: Record<string, Object> = { 'recaptcha_url': recaptchaUrl };
      router.pushUrl({ url: 'pages/ReCaptchaActivityPage', params: challenge });
      return;
    }
    ServiceLocator.get().errorReporter.openActivity(info);
  }

  /**
   * showEmptyState(): only while the ADAPTER is empty - and the autoplay header is an adapter row,
   * so a stream with no related items still has one and is not empty. Without that the kaomoji
   * overlay would be drawn straight over the toggle.
   */
  private showEmptyState(): boolean {
    return this.loadedCount === 0 && !this.relatedItemsInfo && !this.isLoading
      && this.errorInfo === null;
  }

  private showErrorPanel(): boolean {
    return this.errorInfo !== null && this.loadedCount === 0;
  }

  /**
   * onItemSelected: each SUBTYPE has its own destination. Collapsing them onto VideoDetail would
   * silently drop the channel and playlist rows the extractor puts in relatedItems.
   */
  private onItemSelected(item: InfoItem): void {
    if (item instanceof ChannelInfoItem) {
      const channel: ChannelInfoItem = item as ChannelInfoItem;
      router.pushUrl({
        url: 'pages/ChannelFragmentPage',
        params: new ItemParams(channel.getServiceId(), channel.getUrl(), channel.getName())
      });
      return;
    }
    if (item instanceof PlaylistInfoItem) {
      const playlist: PlaylistInfoItem = item as PlaylistInfoItem;
      router.pushUrl({
        url: 'pages/PlaylistFragmentPage',
        params: new ItemParams(playlist.getServiceId(), playlist.getUrl(), playlist.getName())
      });
      return;
    }
    router.pushUrl({
      url: 'pages/VideoDetailFragmentPage',
      params: new ItemParams(item.getServiceId(), item.getUrl(), item.getName())
    });
  }

  /**
   * OnClickGesture.held -> InfoItemDialog attached to the PARENT fragment. S4 fills the entries
   * from the same InfoItemDialog builder the other lists use.
   */
  private onItemHeld(item: InfoItem): void {
    if (!(item instanceof StreamInfoItem)) {
      return;
    }
    const stream: StreamInfoItem = item as StreamInfoItem;
    this.heldItem = stream;
    this.menuTitle = stream.getName();

    // InfoItemDialog.Builder owns the entry list and its order; this screen only says what each
    // entry does. It used to offer ONE entry - Enqueue - against the reference full set.
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
      // NavigationHelper.enqueueOnPlayer(): APPEND to the live queue, which the stream this list
      // hangs off already published.
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

    this.menuActions = buildStreamMenuActions(target, handlers);
    this.infoItemDialog.open();
  }

  /* //////////////////////////////////////////////////////////////////////////
  // InfoListAdapter's header slot + getItemViewType() + onCreateViewHolder()
  ////////////////////////////////////////////////////////////////////////// */

  /**
   * related_items_header.xml: a label plus autoplay_switch. It is adapter ROW 0, supplied by
   * getListHeaderSupplier(), which returns null when there is no RelatedItemsInfo.
   */
  @Builder
  listHeader() {
    // getListHeaderSupplier() returns NULL when there is no RelatedItemsInfo, so the autoplay
    // row does not exist at all then - it is not merely hidden.
    if (this.relatedItemsInfo) {
      HFHolder() {
        Row() {
          // related_items_header.xml: next_video_title ('Next') as a plain 16sp label, then the
          // auto_queue_toggle-captioned switch. Ruling 2026-09-17 (T-0635/T-0636, T-1493 retired).
          // next_stream is the media-notification label, not this header.
          Text($r('app.string.next_video_title'))
            .layoutWeight(1)
            .fontSize(16)
            .fontColor($r('app.color.on_surface_variant'))

          Text($r('app.string.auto_queue_toggle'))
            .fontSize(14)
            .fontColor($r('app.color.on_surface_variant'))
            .margin({ right: 8 })

          Toggle({ type: ToggleType.Switch, isOn: this.autoplaySwitch })
            .id('autoplay_switch')
            // TC-PLAYER-817: colorControlActivated = ?attr/colorPrimary, and on the reference
            // ?attr/colorPrimary FOLLOWS THE SELECTED SERVICE - ThemeHelper.setTheme(ctx,
            // serviceId). Measured on a Bandcamp album: the reference's switch is that service's
            // cyan, this port's was the app's red, while the toolbar two rows above it was
            // already cyan on both. The app-wide primary was the wrong token here, not the wrong
            // colour: every other service-themed surface in this port already calls
            // servicePrimaryColor(), and the switch simply had not been given the service.
            .selectedColor(servicePrimaryColor(this.hostServiceId))
            .onChange((isOn: boolean) => {
              // The switch WRITES prefs auto_queue_key; the flushing put is what makes the
              // choice survive a relaunch, which is the other half of the two-way binding.
              this.autoplaySwitch = isOn;
              AppPreferences.putBoolean(auto_queue_key, isOn)
                .catch((err: BusinessError): void => {
                  hilog.error(0x0000, TAG, 'auto_queue_key write failed: %{public}s', err.message);
                });
            })
        }
        .id('related_items_header')
        .width('100%')
        .constraintSize({ minHeight: 48 })
        .padding({ left: 16, right: 16, top: 4, bottom: 4 })
        .alignItems(VerticalAlign.Center)
      }
    }
  }

  @Builder
  itemRow(item: InfoItem) {
    InfoItemHolder({
      onSelected: () => {
        this.onItemSelected(item);
      },
      onHeld: () => {
        this.onItemHeld(item);
      }
    }) {
      this.holderFor(item)
    }
  }

  @Builder
  holderFor(item: InfoItem) {
    if (item instanceof StreamInfoItem) {
      // The clamp leaves exactly two reachable stream presentations: CARD and LIST.
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

  /** The local playlist store, opened on first use. */
  private async ensureAppendServices(): Promise<LocalPlaylistManager | null> {
    const existing: LocalPlaylistManager | null = this.appendManager;
    if (existing !== null) {
      return existing;
    }
    try {
      const db: AppDatabase = await AppDatabase.getInstance(getContext(this) as common.Context);
      const manager: LocalPlaylistManager = new LocalPlaylistManager(db);
      this.appendManager = manager;
      return manager;
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      promptAction.showToast({ message: failure.message, duration: 2000 });
      return null;
    }
  }

  /**
   * StreamDialogDefaultEntry.APPEND_PLAYLIST -> PlaylistAppendDialog over the local playlists,
   * and PlaylistDialog.createCorrespondingDialog rule: with no playlists at all it goes straight
   * to creation instead of showing an empty picker.
   */
  private async openAppendPicker(stream: StreamInfoItem): Promise<void> {
    const manager: LocalPlaylistManager | null = await this.ensureAppendServices();
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
    const manager: LocalPlaylistManager | null = await this.ensureAppendServices();
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
    const manager: LocalPlaylistManager | null = await this.ensureAppendServices();
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
    Stack() {
      InfoListAdapter({
        dataSource: this.relatedItemsSource,
        // getListHeaderSupplier() returns null without a RelatedItemsInfo - no header row at all.
        hasHeader: this.relatedItemsInfo,
        // This screen NEVER paginates, so there is no pignate_footer.
        showFooter: false,
        onReachEnd: () => {
          hilog.debug(0x0000, TAG, 'related items never paginate');
        },
        // A @Builder passed as `this.listHeader` re-binds `this` to the CHILD adapter, so every
        // page member the builder touches reads back undefined. The arrow keeps `this` here.
        header: (): void => {
          this.listHeader();
        },
        row: (item: InfoItem): void => {
          this.itemRow(item);
        }
      })

      if (this.isLoading) {
        // loading_progress_bar: layout_centerInParent - the Stack's own default alignment.
        LoadingProgress()
          .id('loading_progress_bar')
          .width(48)
          .height(48)
          .color($r('app.color.primary'))
      }

      if (this.showEmptyState()) {
        Column() {
          // The kaomoji is a literal in the layout itself, not data.
          Text('(╯°-°)╯')
            .fontFamily('monospace')
            .fontSize(35)
            .fontColor($r('app.color.on_surface_variant'))
            .margin({ bottom: 10 })
          Text($r('app.string.empty_view_no_videos'))
            .id('empty_state_desc')
            .fontSize(24)
            .fontColor($r('app.color.on_surface_variant'))
        }
        .id('empty_state_view')
        .width('100%')
        // layout_centerHorizontal + paddingTop 85dp: the block hangs from the TOP edge, it is
        // NOT centred in the parent the way error_panel is. Without an explicit full height the
        // Stack's default Center alignment would float it to the middle of the screen.
        .height('100%')
        .justifyContent(FlexAlign.Start)
        .alignItems(HorizontalAlign.Center)
        .padding({ top: 85 })
      }

      if (this.showErrorPanel()) {
        Column() {
          // error_panel.xml: 16sp bold, centred. base.png samples the glyph core at #6D6D6D,
          // which is the theme's default TextView colour (#8A000000) over the #EEEEEE window.
          Text(this.errorText())
            .id('error_message_view')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.on_surface_variant'))
            .textAlign(TextAlign.Center)

          // error_panel.xml declares error_action_button ABOVE the retry button, marginTop 8dp,
          // same @style/ServiceColoredButton. ErrorPanelHelper keeps it GONE unless the error is
          // a reCaptcha challenge or reportable, which is what the empty label stands for.
          if (this.errorActionLabel().length > 0) {
            Button(this.errorActionLabel())
              .id('error_action_button')
              .type(ButtonType.Normal)
              .height(48)
              .borderRadius(2)
              .backgroundColor($r('app.color.primary'))
              .fontSize(16)
              .fontColor($r('app.color.subscribe_text_color'))
              .padding({ left: 16, right: 16 })
              .margin({ top: 8 })
              .onClick(() => {
                this.runErrorAction();
              })
          }

          // @style/ServiceColoredButton: colorButtonNormal = ?attr/colorPrimary, white label at
          // 16sp. base.ui.json puts error_retry_button at [408,1340][672,1484] = 88x48vp.
          Button(Localization.buttonLabel('retry'))
            .id('error_retry_button')
            .type(ButtonType.Normal)
            .height(48)
            .borderRadius(2)
            .backgroundColor($r('app.color.primary'))
            .fontSize(16)
            .fontColor($r('app.color.subscribe_text_color'))
            .padding({ left: 16, right: 16 })
            .margin({ top: 4 })
            .onClick(() => {
              // ErrorPanelHelper.onRetryButtonClicked() -> reloadContent() -> startLoading(true).
              // Clearing errorInfo alone left isLoading pinned true and the spinner spinning for
              // ever, so the button LOOKED wired and did nothing; the reload is the whole effect.
              this.loadRelatedItems(true);
            })
        }
        .id('error_panel')
        .padding(16)
        .alignItems(HorizontalAlign.Center)
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
    .id('RelatedItemsFragmentPage')
    .width('100%')
    .height('100%')
    .backgroundColor(themedBackground(this.blackTheme))
  }
}
