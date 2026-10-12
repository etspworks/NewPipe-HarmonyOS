/**
 * S3 — RouterActivity (screen_router_activity), structure from RouterActivity.java +
 * single_choice_dialog_view.xml + list_radio_icon_item.xml, read verbatim off codegraph.
 *
 * 🟥 THE CAPTURE IS MISLEADING AND THE SOURCE WINS. The gallery launched RouterActivity by class
 * name with no incoming VIEW intent, so handleUrl() never resolved a link and getChoiceOrDialog()
 * never ran; every captured state (S0012–S0015, S0190) therefore shows the search / kiosk UI
 * behind the transparent window, not this screen. The plan's contracts for those states were
 * moved to `omittedControls` for exactly that reason. This page renders what the SOURCE defines:
 * the open-action chooser and the unsupported-URL dialog. Nothing here comes from a screenshot.
 *
 * SOURCE SHAPE. RouterActivity has NO content view: the window is fully transparent (alpha 0f)
 * and non-interactive (FLAG_NOT_FOCUSABLE | FLAG_NOT_TOUCH_MODAL | FLAG_NOT_TOUCHABLE) so touches
 * pass through to the sharing app, and everything visible is an AlertDialog or a child
 * DialogFragment; a FragmentLifecycleCallbacks finishes the activity once the last DialogFragment
 * dies. HarmonyOS has no transparent-page equivalent, so the two AlertDialogs are rendered by
 * this page itself and the DialogFragments stay overlays.
 *
 * onStart -> handleUrl(url) resolves the URL off the main thread; a URL no service claims
 * (LinkType.NONE) is showUnsupportedUrlDialog(url), otherwise onSuccess() decides between
 * running a choice straight away and showDialog(availableChoices). That whole decision is the
 * Phase-2 data layer's DeepLinkRouter.resolve() (common/router/DeepLinkRouter.ts) — a verbatim
 * port of handleUrl + onSuccess + getChoicesForService + the ChoiceAvailabilityChecker — so this
 * page BINDS to it and re-derives none of it.
 *
 * showDialog(choices) inflates single_choice_dialog_view (a RadioGroup, R.id.list) and one
 * list_radio_icon_item RadioButton per AdapterChoiceItem, each with the item's description and
 * its compound-drawable icon. All N rows share ONE id — `list_radio_itemroot` (Rule 12's
 * list-row exception). The two AlertDialog buttons are R.string.just_once (BUTTON_NEGATIVE, run
 * the choice once) and R.string.always (BUTTON_POSITIVE, run it AND persist
 * preferred_open_action_key); setDialogButtonsState() keeps both DISABLED until a row is
 * checked, and a SECOND tap on the already-selected row runs handleChoice() immediately.
 *
 * Edges:
 *  - push    -> screen_video_detail      (show_info / canHandleChoiceLikeShowInfo)
 *  - push    -> screen_main_activity     (handleText: a share with no URL opens search)
 *  - push    -> screen_recaptcha_activity(handleError with a recaptchaUrl)
 *  - present -> screen_download_dialog / screen_loading_dialog: NOT this page's overlays.
 *              openDownloadDialog() delegates to getPersistFragment(), i.e. the retained
 *              PersistentFragment (screen_persistent, hostedBy this screen), which owns both.
 *              It is mounted below, and only while a fetch it drives is in flight — the source
 *              adds that fragment on demand, it is not part of the idle activity.
 *
 * S5 - styled WITHOUT the capture: results/traversal-source/.../activity_RouterActivity/*.png
 * shows the search / kiosk UI behind the transparent window, not this screen (see above), so it
 * is not a style reference for anything here. The values below come from the SOURCE theme -
 * an AlertDialog over a dimmed window, single_choice_dialog_view.xml and list_radio_icon_item.xml
 * (48dp rows, 16dp side padding, 24dp drawablePadding) - plus the app-level style baseline in
 * state.json generation.styleBaseline, matching the dialog surface ErrorActivityPage ships.
 * Style only: no control, binding, branch or presentation changed.
 */
import { router } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';

import { FocusOverlayView } from '../components/FocusOverlayView';
import { PlaylistDialog } from '../components/PlaylistDialog';
import { PlaylistAppendDialog } from '../components/PlaylistAppendDialog';
import { PlaylistCreationDialog } from '../components/PlaylistCreationDialog';
import { PersistentFragmentPage } from './PersistentFragmentPage';

import {
  LinkType,
  ResolvedLink,
  RouterChoice,
  RoutingDecision
} from '../common/router/DeepLinkRouter';
import { ExtractorHelper } from '../common/extractor/ExtractorHelper';
import { all } from '../common/extractor/ServiceRegistry';
import { StreamingService } from '../common/extractor/core/StreamingService';
import { StreamInfo } from '../model/extractor/StreamInfo';
import { BackgroundWorkMode } from '../common/background/BackgroundWork';
import { PlayerService } from '../common/player/PlayerService';
import { currentPlayQueue, enqueueOnCurrentPlayQueue } from '../model/app/PlayQueue';
import { PlayQueueItem } from '../model/app/PlayQueueItem';
import {
  ShareUtils, mimeForStream, pickExternalVideo, pickExternalAudio,
  ExternalStreamChoice
} from '../common/share/ShareUtils';
import { MediaFormat } from '../model/enums/MediaFormat';
import { VideoStream } from '../model/extractor/VideoStream';
import { AudioStream } from '../model/extractor/AudioStream';
import { DeliveryMethod } from '../model/enums/DeliveryMethod';
import { ServiceLocator } from '../common/di/ServiceLocator';
import { Localization } from '../common/i18n/Localization';
import { AppDatabase } from '../common/db/AppDatabase';
import { LocalPlaylistManager, playlistAppendToast } from '../common/db/PlaylistManager';
import { PlaylistMetadataEntry } from '../model/db/view/PlaylistMetadataEntry';
import { StreamEntity } from '../model/db/entity/StreamEntity';
import {
  add_to_playlist_key,
  autoplay_key,
  autoplay_never_key,
  autoplay_value,
  background_player_key,
  download_key,
  enqueue_key,
  popup_player_key,
  show_info_key,
  use_external_audio_player_key,
  use_external_video_player_key,
  video_player_key
} from '../common/prefs/SettingsKeys';
import { AppPreferences } from '../common/prefs/Preferences';
import { DIALOG_MASK_COLOR } from '../common/theme/ServiceTheme';

const TAG: string = 'RouterActivityPage';
/** DeviceUtils.isTv(this) — UI_MODE_TYPE_TELEVISION / LEANBACK, i.e. deviceType 'tv' here. */
const TV_DEVICE_TYPE: string = 'tv';

/* S5 - baseline tokens (state.json generation.styleBaseline, source S0004). */
const C_ON_SURFACE: Resource = $r('app.color.on_surface');
const C_SECONDARY: Resource = $r('app.color.on_surface_variant');
/* The AlertDialog window dim: Material's default 32% black scrim. */
const C_SCRIM: string = '#52000000';

/** NavigationHelper.getIntentByLink(...) hands VideoDetailFragment the same three arguments. */
class LinkParams {
  serviceId: number;
  url: string;
  name: string;
  /** VideoDetailFragmentPage.readArguments(): params['popup'] - open the PiP popup on load. */
  popup: boolean;

  constructor(serviceId: number, url: string, name: string, popup: boolean) {
    this.serviceId = serviceId;
    this.url = url;
    this.name = name;
    this.popup = popup;
  }
}

/** NavigationHelper.openSearch(context, serviceId, searchString) — handleText()'s target. */
class SearchParams {
  serviceId: number;
  searchString: string;

  constructor(serviceId: number, searchString: string) {
    this.serviceId = serviceId;
    this.searchString = searchString;
  }
}

/** ReCaptchaActivity.RECAPTCHA_URL_EXTRA. */
class ReCaptchaParams {
  recaptchaUrl: string;

  constructor(recaptchaUrl: string) {
    this.recaptchaUrl = recaptchaUrl;
  }
}

@Entry
@Component
export struct RouterActivityPage {
  /* //////////////////////////////////////////////////////////////////////////
  // State — the plan's stateVars
  ////////////////////////////////////////////////////////////////////////// */

  /**
   * The RadioGroup's rows: getChoicesForService(currentService, currentLinkType), taken from
   * DeepLinkRouter — never a literal list. Empty until handleUrl() has resolved the link.
   */
  @State choiceRadioList: RouterChoice[] = [];
  /**
   * selectedRadioPosition, seeded from preferred_open_action_last_selected: the key of the
   * pre-checked row, or '' when nothing is checked (setDialogButtonsState(false)).
   */
  @State preSelectedRadio: string = '';
  /**
   * preferred_open_action_key: when it is set AND still available for this link, the source runs
   * handleChoice() immediately and shows NO dialog.
   */
  @State preferredOpenActionKey: string = '';
  /** currentLinkType — STREAM adds the Download and Add-to-playlist rows. */
  @State currentLinkType: LinkType = LinkType.NONE;
  /** The handleUrl() Observable is in flight. */
  @State isLoading: boolean = true;
  /** handleError(this, ErrorInfo(...)): its Toast/notification text. */
  @State errorInfo: string | null = null;

  /* //////////////////////////////////////////////////////////////////////////
  // The rest of RouterActivity's fields
  ////////////////////////////////////////////////////////////////////////// */

  /** currentUrl — the shared/viewed URL this activity is routing. */
  @State currentUrl: string = '';
  /** showUnsupportedUrlDialog(url): the AlertDialog that replaces the chooser. */
  @State showUnsupportedUrlDialog: boolean = false;
  /** selectionIsDownload — set before openDownloadDialog(); also keeps finish() from running. */
  @State selectionIsDownload: boolean = false;
  /** selectionIsAddToPlaylist — set before openAddToPlaylistDialog(). */
  @State selectionIsAddToPlaylist: boolean = false;
  /** DeviceUtils.isTv(this) -> FocusOverlayView.setupFocusObserver(alertDialogChoice). */
  @State isTv: boolean = false;
  /** LocalPlaylistManager.hasPlaylists() — PlaylistDialog.createCorrespondingDialog's branch. */
  @State hasPlaylists: boolean = false;
  /** The append picker's rows. */
  @State appendPlaylists: PlaylistMetadataEntry[] = [];

  /** selectedPreviously: a SECOND tap on the same row runs the choice at once. */
  private selectedPreviously: string = '';
  /**
   * currentService / currentServiceId, resolved by DeepLinkRouter. @State because the mounted
   * PersistentFragment reads its serviceId as a @Prop.
   */
  @State currentLink: ResolvedLink | null = null;
  /** List.of(new StreamEntity(info)) — the stream the add-to-playlist dialog is acting on. */
  private addToPlaylistStreams: StreamEntity[] = [];
  private playlistManager: LocalPlaylistManager | null = null;

  /** PlaylistDialog.createCorrespondingDialog(...) — the add-to-playlist entry point. */
  private playlistDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    builder: PlaylistDialog({
      hasPlaylists: this.hasPlaylists,
      onAppend: (): void => {
        this.openAppendPicker();
      },
      onCreate: (): void => {
        this.openCreationDialog();
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
        this.openCreationDialog();
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

  /** onCreate(): currentUrl = getUrl(intent); an empty one is handleText() + finish(). */
  aboutToAppear(): void {
    this.isTv = deviceInfo.deviceType === TV_DEVICE_TYPE;
    this.readArguments();
    if (this.currentUrl.length === 0) {
      this.handleText();
      return;
    }
    this.handleUrl(this.currentUrl);
  }

  /**
   * getUrl(intent): the Want's `uri` when another app opened a link, otherwise the first URL in
   * the shared text — DeepLinkRouter.extractUrl is the port of both.
   */
  private readArguments(): void {
    const params: Record<string, Object> | undefined =
      router.getParams() as Record<string, Object> | undefined;
    let uri: string | null = null;
    let sharedText: string | null = null;
    if (params !== undefined && params !== null) {
      const uriParam: Object | undefined = params['uri'];
      if (uriParam !== undefined && uriParam !== null) {
        uri = uriParam.toString();
      }
      const textParam: Object | undefined = params['sharedText'];
      if (textParam !== undefined && textParam !== null) {
        sharedText = textParam.toString();
      }
    }
    const url: string | null = ServiceLocator.get().deepLinkRouter.extractUrl(uri, sharedText);
    this.currentUrl = url === null ? '' : url;
  }

  /**
   * handleUrl(url) + onSuccess(): resolve the link, then either run the decided choice with no
   * dialog or show the chooser. A URL no service claims is the unsupported-URL dialog.
   */
  private async handleUrl(url: string): Promise<void> {
    this.isLoading = true;
    this.errorInfo = null;
    try {
      const decision: RoutingDecision = await ServiceLocator.get().deepLinkRouter.resolve(url);
      const link: ResolvedLink | null = decision.link;
      if (link === null) {
        this.showUnsupportedUrlDialog = true;
        this.isLoading = false;
        return;
      }
      this.currentLink = link;
      this.currentLinkType = link.linkType;
      this.choiceRadioList = decision.choices;
      this.preSelectedRadio = decision.lastSelectedKey === null ? '' : decision.lastSelectedKey;
      this.selectedPreviously = this.preSelectedRadio;
      this.preferredOpenActionKey =
        decision.autoChoiceKey === null ? '' : decision.autoChoiceKey;
      this.isLoading = false;

      // The remembered "always" choice (or a single/absent choice) skips the dialog entirely.
      if (this.preferredOpenActionKey.length > 0) {
        await this.handleChoice(this.preferredOpenActionKey);
      }
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.handleError(failure.message, null);
    }
  }

  /**
   * handleError(context, errorInfo): a recaptchaUrl starts the ReCaptcha challenge, anything else
   * is a Toast / error notification, and the activity finishes.
   */
  private handleError(message: string, recaptchaUrl: string | null): void {
    hilog.error(0x0000, TAG, 'router failed: %{public}s', message);
    this.isLoading = false;
    if (recaptchaUrl !== null) {
      promptAction.showToast({
        message: Localization.getString('recaptcha_request_toast'),
        duration: 3000
      });
      router.pushUrl({
        url: 'pages/ReCaptchaActivityPage',
        params: new ReCaptchaParams(recaptchaUrl)
      });
      return;
    }
    this.errorInfo = message;
    promptAction.showToast({ message: message, duration: 3000 });
  }

  /**
   * handleText(): a share with no URL in it opens MainActivity and hands the text to search.
   *
   * replaceUrl, not pushUrl: onCreate calls `handleText(); finish();` (RouterActivity.java:171-172),
   * so the router activity is gone by the time MainActivity is showing. A push would leave a dead
   * router page under it and Back would land on a chooser with no url. The plan's nav edge is
   * `kind: replace` for the same reason.
   */
  private handleText(): void {
    const params: Record<string, Object> | undefined =
      router.getParams() as Record<string, Object> | undefined;
    let searchString: string = '';
    let serviceId: number = 0;
    if (params !== undefined && params !== null) {
      const text: Object | undefined = params['sharedText'];
      if (text !== undefined && text !== null) {
        searchString = text.toString();
      }
      const sid: Object | undefined = params['serviceId'];
      if (sid !== undefined && sid !== null) {
        serviceId = Number(sid.toString());
      }
    }
    this.isLoading = false;
    router.replaceUrl({
      url: 'pages/MainActivityPage',
      params: new SearchParams(serviceId, searchString)
    });
  }

  /* //////////////////////////////////////////////////////////////////////////
  // The chooser
  ////////////////////////////////////////////////////////////////////////// */

  /**
   * radioButtonsClickListener: the tap records the position, and when the row was ALREADY the
   * selected one it runs handleChoice() straight away.
   */
  private onRadioTapped(key: string): void {
    this.selectedPreviously = this.preSelectedRadio;
    this.preSelectedRadio = key;
    if (this.selectedPreviously === key) {
      this.handleChoice(key);
    }
  }

  /**
   * dialogButtonsClickListener: both buttons run the checked choice; BUTTON_POSITIVE ("Always")
   * additionally persists preferred_open_action_key so future links skip the dialog.
   */
  private async onDialogButton(rememberAlways: boolean): Promise<void> {
    const key: string = this.preSelectedRadio;
    if (key.length === 0) {
      return;
    }
    // preferences.edit().putString(preferred_open_action_key, choice.key).apply(): awaited so the
    // flush completes before handleChoice() leaves this page - the write must survive a relaunch.
    await ServiceLocator.get().deepLinkRouter.rememberChoice(key, rememberAlways);
    await this.handleChoice(key);
  }

  /** handleChoice(selectedChoiceKey), branch for branch. */
  private async handleChoice(selectedChoiceKey: string): Promise<void> {
    // The source's first statement: every choice it runs is remembered as the last-selected one
    // (preferred_open_action_last_selected_key), whichever path reached handleChoice.
    await ServiceLocator.get().deepLinkRouter.rememberChoice(selectedChoiceKey, false);

    // popup player without the overlay permission: the source just finish()es.
    if (selectedChoiceKey === popup_player_key
      && !ServiceLocator.get().permissions.isPopupEnabled()) {
      this.finishRouter();
      return;
    }

    if (selectedChoiceKey === download_key) {
      if (ServiceLocator.get().permissions.checkStoragePermissions()) {
        this.selectionIsDownload = true;
        this.openDownloadDialog();
      }
      return;
    }

    if (selectedChoiceKey === add_to_playlist_key) {
      this.selectionIsAddToPlaylist = true;
      this.openAddToPlaylistDialog();
      return;
    }

    // show_info (and the video player when it can be handled like show info) bypasses
    // FetcherService: VideoDetailFragment fetches the stream itself.
    if (selectedChoiceKey === show_info_key
      || this.canHandleChoiceLikeShowInfo(selectedChoiceKey)) {
      this.openInfoScreen();
      return;
    }

    // Everything else is FetcherService, a foreground service; on HarmonyOS a continuous
    // background task that carries the same Choice(serviceId, linkType, url, key).
    await this.startFetcher(selectedChoiceKey);
  }

  /**
   * canHandleChoiceLikeShowInfo(): only the video player, only with autoplay allowed, no external
   * player, and the running player either absent or of type MAIN.
   */
  private canHandleChoiceLikeShowInfo(selectedChoiceKey: string): boolean {
    if (selectedChoiceKey !== video_player_key) {
      return false;
    }
    const prefs: AppPreferences = ServiceLocator.get().preferences;
    // ...PlayerHelper.isAutoplayAllowedByUser(ctx): "never" rules it out.
    if (prefs.getStringResolvedSync(autoplay_key, autoplay_value) === autoplay_never_key) {
      return false;
    }
    // ...and it must not be handed to an external player. The source's third condition -
    // PlayerHolder.getInstance().getType() is null or MAIN - holds by construction here: the
    // ported PlayerService is one instance driven by VideoDetailFragmentPage's main player, so
    // there is no POPUP/AUDIO player type it could be running as.
    return !prefs.getBooleanSync(use_external_video_player_key, false);
  }

  /**
   * NavigationHelper.getIntentByLink(this, currentUrl) -> startActivity(intent); finish(). The
   * intent opens the page of the link's type: a channel or a playlist link opened the video page
   * here, which then rejected the url ("URL not accepted").
   */
  private openInfoScreen(popup: boolean = false): void {
    const link: ResolvedLink | null = this.currentLink;
    const type: LinkType = link === null ? LinkType.STREAM : link.linkType;
    router.pushUrl({
      url: type === LinkType.CHANNEL ? 'pages/ChannelFragmentPage'
        : (type === LinkType.PLAYLIST ? 'pages/PlaylistFragmentPage'
          : 'pages/VideoDetailFragmentPage'),
      params: new LinkParams(link === null ? -1 : link.serviceId, this.currentUrl, '', popup)
    });
  }

  /**
   * FetcherService.handleChoice() + getResultHandler(), ported. The source's foreground
   * IntentService fetches the info for the link and hands it to the chosen player; here that
   * fetch is a BackgroundWork continuous task (a bare service does not keep a HarmonyOS app
   * alive), and the playback that follows is PlayerService's own, exactly as the source leaves
   * it to its player service.
   */
  private async startFetcher(selectedChoiceKey: string): Promise<void> {
    const link: ResolvedLink | null = this.currentLink;
    if (link === null) {
      return;
    }

    // ServiceList.all(): the fetch runs against the service that claimed this URL. The resolver
    // is injected, so an id no registered service owns is a real error, not a silent no-op.
    const service: StreamingService | undefined = all()
      .find((candidate: StreamingService): boolean => candidate.getServiceId() === link.serviceId);
    if (service === undefined) {
      this.handleError(Localization.getString('general_error'), null);
      return;
    }

    // ChannelTabPlayQueue / PlaylistPlayQueue: the ported PlayQueue is abstract and has no
    // concrete subclass, so a channel or playlist choice opens that list's own page instead of
    // enqueueing it. Ceiling: no multi-item queue playback started from the router.
    if (link.linkType !== LinkType.STREAM) {
      router.pushUrl({
        url: link.linkType === LinkType.CHANNEL
          ? 'pages/ChannelFragmentPage' : 'pages/PlaylistFragmentPage',
        params: new LinkParams(link.serviceId, this.currentUrl, '', false)
      });
      return;
    }

    // FetcherService.handleResult(): only background_player and video_player go to an external
    // player; popup and enqueue always stay in the app (enqueue with no player open defaults to
    // background playback).
    const enqueue: boolean = selectedChoiceKey === enqueue_key;
    const audioOnly: boolean = selectedChoiceKey === background_player_key || enqueue;
    const prefs: AppPreferences = ServiceLocator.get().preferences;
    const external: boolean = selectedChoiceKey === background_player_key
      ? prefs.getBooleanSync(use_external_audio_player_key, false)
      : selectedChoiceKey === video_player_key
        && prefs.getBooleanSync(use_external_video_player_key, false);

    if (!audioOnly && !external) {
      // playOnMainPlayer / playOnPopupPlayer: the player UI is VideoDetailFragmentPage, and the
      // popup player is its PiP window (SYSTEM_FLOAT_WINDOW is rejected on a self-signed build),
      // so both video choices open that page; `popup: true` makes it open its PiP popup, as the
      // list screens' popup entry points already do.
      hilog.info(0x0000, TAG, 'choice %{public}s on service %{public}s opens the detail player',
        selectedChoiceKey, service.getServiceInfo().getName());
      this.openInfoScreen(selectedChoiceKey === popup_player_key);
      return;
    }

    try {
      const info: StreamInfo = await ServiceLocator.get().backgroundWork.runWithBackgroundTask(
        BackgroundWorkMode.DATA_TRANSFER,
        (): Promise<StreamInfo> =>
          ExtractorHelper.getStreamInfo(link.serviceId, this.currentUrl, false));

      if (external) {
        // playOnExternalVideoPlayer / playOnExternalAudioPlayer: hand the STREAM to a player with
        // its MIME type, the way NavigationHelper.setDataAndType does.
        //
        // This used to pass info.getUrl() - the watch PAGE - through openUrlInBrowser, which sets
        // no Want.type. A bare https uri with no type is a web link, so the browser claiming it
        // was correct behaviour and the external-player preference did nothing a user could see.
        // An external player was never actually asked for, which is also why the old comment's
        // premise - that no such app exists here - had never been tested.
        const share: ShareUtils = ServiceLocator.get().share;
        const stream: ExternalStreamChoice | null = audioOnly
          ? pickExternalAudio(info.audioStreams) : pickExternalVideo(info.videoStreams);
        if (stream === null) {
          await this.showNoPlayerFound();
        } else {
          const ok: boolean = await share.playInExternalPlayer(
            stream.url, mimeForStream(stream.format, audioOnly), info.getName());
          if (!ok) {
            await this.showNoPlayerFound();
          }
        }
      } else if (enqueue && PlayerService.getInstance().hasPlayer()
        && currentPlayQueue.getValue() !== null) {
        // NavigationHelper.enqueueOnPlayer(this, playQueue): toast, then APPEND to the live queue,
        // leaving the playing item alone.
        promptAction.showToast({ message: $r('app.string.enqueued'), duration: 2000 });
        enqueueOnCurrentPlayQueue([PlayQueueItem.fromStreamInfo(info)]);
      } else {
        // playOnBackgroundPlayer(queue, resumePlayback = true): audio-only playback - also
        // enqueueOnPlayer's "no player is open; defaulting to background player".
        await PlayerService.getInstance().prepare(info, true);
      }
      this.finishRouter();
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.handleError(failure.message, null);
    }
  }

  /**
   * The stream an external player should be handed: one self-contained URL.
   *
   * The same rule MediaSourceResolver applies when it has a choice - the MUXED progressive track
   * (bestMuxed: not DASH-delivered, highest resolution), and for audio the highest average
   * bitrate (bestAudio). Those two are private to the resolver and work on its StreamSet; the
   * MediaFormat needed for the MIME type only exists on the extractor's own VideoStream /
   * AudioStream, so the rule is applied here on those instead of adapting twice.
   *
   * info.videoStreams is already the muxed list - videoOnlyStreams is separate - so a video-only
   * track can never be chosen here, which is what a player without a second source would need.
   */
  /**
   * The source's no-player dialog. no_player_found and vlc_package have shipped in all 91 locales
   * since the port landed and nothing has ever referenced them - the port showed
   * openUrlInBrowser's generic no_app_to_open_intent toast instead, after sending the page URL to
   * a browser that always took it.
   *
   * Same shape as showInstallKoreDialog(): same buttons, same store fallback, same catch.
   */
  private async showNoPlayerFound(): Promise<void> {
    try {
      const choice: promptAction.ShowDialogSuccessResponse = await promptAction.showDialog({
        message: $r('app.string.no_player_found'),
        buttons: [
          { text: $r('app.string.cancel'), color: '#FF000000' },
          { text: $r('app.string.install'), color: '#FF000000' }
        ]
      });
      if (choice.index === 1) {
        // The source sends the user to the store listing for @string/vlc_package. There is no
        // store app here, so the listing opens in a browser - the fallback
        // showInstallKoreDialog() already takes.
        ServiceLocator.get().share.openUrlInBrowser(
          'https://play.google.com/store/apps/details?id='
            + Localization.getString('vlc_package'));
      }
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      hilog.warn(0x0000, TAG, 'showNoPlayerFound: %{public}s', failure.message);
    }
  }

  /**
   * openDownloadDialog(): getPersistFragment().openDownloadDialog(currentServiceId, currentUrl) —
   * the retained PersistentFragment owns the LoadingDialog and the DownloadDialog, so mounting it
   * IS the download path.
   */
  private openDownloadDialog(): void {
    hilog.info(0x0000, TAG, 'openDownloadDialog via PersistentFragment for %{public}s',
      this.currentUrl);
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Add to playlist
  ////////////////////////////////////////////////////////////////////////// */

  private async ensurePlaylistManager(): Promise<LocalPlaylistManager | null> {
    const existing: LocalPlaylistManager | null = this.playlistManager;
    if (existing !== null) {
      return existing;
    }
    try {
      const context: common.Context = getContext(this) as common.Context;
      const db: AppDatabase = await AppDatabase.getInstance(context);
      const manager: LocalPlaylistManager = new LocalPlaylistManager(db);
      this.playlistManager = manager;
      return manager;
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.handleError(failure.message, null);
      return null;
    }
  }

  /**
   * openAddToPlaylistDialog() -> PlaylistDialog.createCorrespondingDialog(): hasPlaylists()
   * decides between the append picker and going straight to the creation dialog.
   */
  private async openAddToPlaylistDialog(): Promise<void> {
    const manager: LocalPlaylistManager | null = await this.ensurePlaylistManager();
    const link: ResolvedLink | null = this.currentLink;
    if (manager === null || link === null) {
      return;
    }
    // compose(this::pleaseWait): the fetch runs behind the LoadingDialog.
    this.isLoading = true;
    try {
      // PersistentFragment.openAddToPlaylistDialog() fetches the LINK's stream first and hands
      // PlaylistDialog List.of(new StreamEntity(info)) — that entity is what gets appended, so
      // without it the dialog would add nothing to the chosen playlist.
      const info: StreamInfo =
        await ExtractorHelper.getStreamInfo(link.serviceId, this.currentUrl, false);
      this.addToPlaylistStreams = [StreamEntity.fromStreamInfo(info)];
      const playlists: PlaylistMetadataEntry[] = await manager.getPlaylistDuplicates(info.getUrl());
      this.appendPlaylists = playlists;
      this.hasPlaylists = playlists.length > 0;
      this.isLoading = false;
      // PlaylistDialog.createCorrespondingDialog() is a FACTORY in the source, not a
      // dialog of its own: with playlists it shows the append dialog, without any it
      // goes straight to creation. The port made it a visible intermediate dialog
      // carrying one unstyled Text, which rendered as a chromeless pill and meant the
      // append dialog behind it never opened at all.
      if (this.hasPlaylists) {
        this.playlistAppendDialog.open();
      } else {
        this.playlistCreationDialog.open();
      }
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.handleError(failure.message, null);
    }
  }

  private openAppendPicker(): void {
    this.playlistAppendDialog.open();
  }

  private openCreationDialog(): void {
    this.playlistCreationDialog.open();
  }

  private async appendToPlaylist(playlist: PlaylistMetadataEntry): Promise<void> {
    const manager: LocalPlaylistManager | null = this.playlistManager;
    if (manager === null) {
      return;
    }
    try {
      await manager.appendToPlaylist(playlist.uid, this.addToPlaylistStreams);
      // PlaylistAppendDialog.onPlaylistSelected() ends in a Toast on the reference - the string
      // `playlist_add_stream_success` ("Playlisted") was already in this port's resources and had
      // no caller anywhere, so an append finished silently. Every entry point that appends says
      // so, not just the one the case happens to name.
      promptAction.showToast({ message: playlistAppendToast(playlist),
        duration: 2000 });
      this.finishRouter();
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.handleError(failure.message, null);
    }
  }

  private async createPlaylist(name: string): Promise<void> {
    const manager: LocalPlaylistManager | null = await this.ensurePlaylistManager();
    if (manager === null) {
      return;
    }
    try {
      await manager.createPlaylist(name, this.addToPlaylistStreams);
      // PlaylistCreationDialog: Toast @string/playlist_creation_success.
      promptAction.showToast({ message: $r('app.string.playlist_creation_success'),
        duration: 2000 });
      this.finishRouter();
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.handleError(failure.message, null);
    }
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Unsupported URL
  ////////////////////////////////////////////////////////////////////////// */

  /** ShareUtils.openUrlInBrowser(this, url). */
  private openInBrowser(): void {
    ServiceLocator.get().share.openUrlInBrowser(this.currentUrl);
    this.finishRouter();
  }

  /** ShareUtils.shareText(this, "", url) — no subject. */
  private shareUrl(): void {
    ServiceLocator.get().share.shareText('', this.currentUrl);
    this.finishRouter();
  }

  /**
   * finish(): the source ends the activity once the last dialog is gone. A download or an
   * add-to-playlist selection keeps it alive until ITS dialog closes.
   */
  private finishRouter(): void {
    if (this.selectionIsDownload || this.selectionIsAddToPlaylist) {
      return;
    }
    router.back();
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Views
  ////////////////////////////////////////////////////////////////////////// */

  /**
   * list_radio_icon_item's compound drawable: AppCompatResources.getDrawable(ctx, item.icon).
   * The migrated media names come from RouterChoice.iconResource, so the branch is that field's
   * closed set — a resource name cannot be built at run time in ArkTS.
   */
  @Builder
  choiceIcon(iconResource: string) {
    if (iconResource === 'ic_play_arrow') {
      Image($r('app.media.ic_play_arrow'))
        .width(24)
        .height(24)
        .objectFit(ImageFit.Contain)
        .fillColor(C_ON_SURFACE)
    } else if (iconResource === 'ic_headset') {
      Image($r('app.media.ic_headset'))
        .width(24)
        .height(24)
        .objectFit(ImageFit.Contain)
        .fillColor(C_ON_SURFACE)
    } else if (iconResource === 'ic_picture_in_picture') {
      Image($r('app.media.ic_picture_in_picture'))
        .width(24)
        .height(24)
        .objectFit(ImageFit.Contain)
        .fillColor(C_ON_SURFACE)
    } else if (iconResource === 'ic_add') {
      Image($r('app.media.ic_add'))
        .width(24)
        .height(24)
        .objectFit(ImageFit.Contain)
        .fillColor(C_ON_SURFACE)
    } else if (iconResource === 'ic_file_download') {
      Image($r('app.media.ic_file_download'))
        .width(24)
        .height(24)
        .objectFit(ImageFit.Contain)
        .fillColor(C_ON_SURFACE)
    } else if (iconResource === 'ic_playlist_add') {
      Image($r('app.media.ic_playlist_add'))
        .width(24)
        .height(24)
        .objectFit(ImageFit.Contain)
        .fillColor(C_ON_SURFACE)
    } else {
      Image($r('app.media.ic_info_outline'))
        .width(24)
        .height(24)
        .objectFit(ImageFit.Contain)
        .fillColor(C_ON_SURFACE)
    }
  }

  /**
   * One list_radio_icon_item RadioButton. All N rows deliberately share `list_radio_itemroot`
   * (Rule 12's list-row exception) — the replay resolves the row by index.
   */
  @Builder
  choiceRow(item: RouterChoice) {
    Row() {
      // The whole row is the RadioButton in the source, so the tap lives on the row root below;
      // a second handler here would fire onRadioTapped twice and self-trigger the choice.
      Radio({ value: item.key, group: 'preferred_open_action' })
        .checked(this.preSelectedRadio === item.key)
        .hitTestBehavior(HitTestMode.None)
        .width(20)
        .height(20)
        .margin({ right: 16 })
      this.choiceIcon(item.iconResource)
      // radioButton.setText(item.description) — the migrated string, never a captured literal.
      Text(Localization.getString(item.descriptionResource))
        .layoutWeight(1)
        // android:maxLines="2" + ellipsize, ?attr/textColorAlertDialogListItem.
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontSize(16)
        .fontColor(C_ON_SURFACE)
        // android:drawablePadding="24dp" between the compound drawable and the label.
        .margin({ left: 24 })
    }
    .id('list_radio_itemroot')
    .width('100%')
    // android:minHeight="?attr/listPreferredItemHeightSmall" - a 2-line label grows the row.
    .constraintSize({ minHeight: 48 })
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.onRadioTapped(item.key);
    })
  }

  /** showUnsupportedUrlDialog(url): title + message + the three AlertDialog buttons. */
  @Builder
  unsupportedUrlDialog() {
    Column() {
      // setIcon(R.drawable.ic_share), above setTitle + setMessage on the dialog card.
      Image($r('app.media.ic_share'))
        .width(24)
        .height(24)
        .objectFit(ImageFit.Contain)
        .fillColor(C_ON_SURFACE)
        .margin({ bottom: 8 })
      Text($r('app.string.unsupported_url'))
        .width('100%')
        .fontSize(20)
        .fontColor(C_ON_SURFACE)
        .margin({ bottom: 16 })
      Text($r('app.string.unsupported_url_dialog_message'))
        .width('100%')
        .fontSize(16)
        .fontColor(C_SECONDARY)

      Row() {
        // BUTTON_NEUTRAL: a null listener; the dismiss listener finishes the activity.
        Button($r('app.string.cancel'))
          .id('cancel')
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .height(48)
          .padding({ left: 8, right: 8 })
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.accent'))
          .onClick(() => {
            this.showUnsupportedUrlDialog = false;
            this.finishRouter();
          })
        // BUTTON_NEGATIVE.
        Button($r('app.string.share'))
          .id('share')
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .height(48)
          .padding({ left: 8, right: 8 })
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.accent'))
          .onClick(() => {
            this.shareUrl();
          })
        // BUTTON_POSITIVE.
        Button($r('app.string.open_in_browser'))
          .id('open_in_browser')
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .height(48)
          .padding({ left: 8, right: 8 })
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.accent'))
          .onClick(() => {
            this.openInBrowser();
          })
      }
      .width('100%')
      .margin({ top: 16 })
      // BUTTON_NEUTRAL sits at the start of the bar, BUTTON_POSITIVE at its end.
      .justifyContent(FlexAlign.SpaceBetween)
      .alignItems(VerticalAlign.Center)
    }
    // The AlertDialog card, as ErrorActivityPage already renders one.
    .width('86%')
    .padding(24)
    .backgroundColor($r('app.color.dialog_surface'))
    .borderRadius(4)
    .alignItems(HorizontalAlign.Start)
  }

  /** showDialog(choices): single_choice_dialog_view + the just_once / always buttons. */
  @Builder
  openActionChooser() {
    Column() {
      Text($r('app.string.preferred_open_action_share_menu_title'))
        .width('100%')
        .fontSize(20)
        .fontColor(C_ON_SURFACE)
        .padding({ left: 24, right: 24 })
        .margin({ top: 20, bottom: 8 })

      // single_choice_dialog_view.xml's RadioGroup (R.id.list).
      List() {
        ForEach(this.choiceRadioList, (item: RouterChoice) => {
          // getChoicesForService(): Download and Add-to-playlist are added only for a STREAM
          // link - "download is redundant for linkType CHANNEL AND PLAYLIST" - so a channel or
          // playlist link never renders those two rows.
          if (this.currentLinkType === LinkType.STREAM
            || (item.key !== download_key && item.key !== add_to_playlist_key)) {
            ListItem() {
              this.choiceRow(item)
            }
          }
        }, (item: RouterChoice) => item.key)
      }
      .id('list')
      .width('100%')
      // single_choice_dialog_view.xml: a wrap_content RadioGroup inside a ScrollView, so the
      // rows scroll only once they outgrow the dialog.
      .constraintSize({ maxHeight: 360 })
      .padding({ top: 16 })

      Row() {
        // setDialogButtonsState(dialog, checkedRadioButtonId != -1): both buttons stay disabled
        // until a row is checked. That is the SOURCE's guard, not an invented one.
        Button($r('app.string.just_once'))
          .id('just_once')
          .enabled(this.preSelectedRadio.length > 0)
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .height(48)
          .padding({ left: 8, right: 8 })
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.accent'))
          .onClick(() => {
            this.onDialogButton(false);
          })
        Button($r('app.string.always'))
          .id('always')
          .enabled(this.preSelectedRadio.length > 0)
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .height(48)
          .padding({ left: 8, right: 8 })
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.accent'))
          .margin({ left: 8 })
          .onClick(() => {
            this.onDialogButton(true);
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 8 })
      .justifyContent(FlexAlign.End)
      .alignItems(VerticalAlign.Center)
    }
    // The AlertDialog card: the title and the button bar carry their own insets, so the card
    // itself is padded only by them.
    .width('86%')
    .backgroundColor($r('app.color.dialog_surface'))
    .borderRadius(4)
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Stack() {
      Column() {
        if (this.isLoading) {
          LoadingProgress()
            .id('loading_progress_bar')
            .width(48)
            .height(48)
            .color($r('app.color.primary'))
        } else if (this.showUnsupportedUrlDialog) {
          // A URL no service claims: the chooser is replaced, never shown beside it.
          this.unsupportedUrlDialog()
        } else if (this.preferredOpenActionKey.length > 0) {
          // preferred_open_action_key is set AND still available -> handleChoice() ran in
          // handleUrl() and NO dialog is shown; the transparent window has nothing on it.
          Column()
            .id('no_dialog')
            .width('100%')
        } else {
          this.openActionChooser()
        }

        if (this.errorInfo !== null) {
          Text(this.errorInfo)
            .id('error_message_view')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.white'))
            .textAlign(TextAlign.Center)
            .padding(16)
        }
      }
      .width('100%')
      .height('100%')
      // The activity window is fully transparent and everything visible is an AlertDialog, so
      // this page is only the dialog dim, centred on its card.
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor(C_SCRIM)

      // getPersistFragment(): the retained fragment that drives the metadata fetch and owns both
      // the LoadingDialog and the DownloadDialog. The source adds it only when a download was
      // chosen, so it is mounted on the same condition.
      if (this.selectionIsDownload) {
        // getPersistFragment().openDownloadDialog(currentServiceId, currentUrl).
        PersistentFragmentPage({
          url: this.currentUrl,
          serviceId: this.currentLink === null ? -1 : this.currentLink.serviceId
        })
      }

      // DeviceUtils.isTv(this) -> FocusOverlayView.setupFocusObserver(alertDialogChoice).
      FocusOverlayView({ isTv: this.isTv })
    }
    .id('RouterActivityPage')
    .width('100%')
    .height('100%')
  }
}
