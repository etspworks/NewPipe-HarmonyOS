/*
 * S3 - VideoDetailFragment (screen_video_detail): the stream page AND the app's player host.
 *
 * STRUCTURE comes from the source view tree, not from the capture. fragment_video_detail.xml is
 * a CoordinatorLayout of
 *   - app_bar_layout > CustomCollapsingToolbarLayout > detail_thumbnail_root_layout, which holds
 *     the hero image, the play-button overlay, the hold-to-append tip, the duration badge, the
 *     resume position text + bar, and player_placeholder (where MainPlayerUi is attached),
 *   - detail_content_root_layout: the title row, the loading bar, the error panel and
 *     detail_content_root_hiding (uploader row, details panel, control panel, secondary control
 *     panel, meta-info),
 *   - view_pager + tab_layout (Comments / Related / Description / Empty),
 * plus a sibling overlay_layout - the collapsed bottom-sheet mini player.
 *
 * player.xml is mounted INSIDE player_placeholder, exactly as tryAddVideoPlayerView() attaches
 * it, and only while a player is attached - which is why none of its controls appear in the
 * captured (unloaded) states.
 *
 * PRESENTATION: the source mounts this fragment into activity_main.xml's fragment_player_holder
 * bottom sheet; the port renders it as a routed @Entry page. That divergence is recorded in the
 * plan and is deliberate.
 *
 * S3 = structure + wiring. No colours, no typography, no spacing: those are S5/S6.
 */
import { PipCoverNode } from '../components/PipCoverNode';
import { promptAction, router, window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { image } from '@kit.ImageKit';
import { audio, AVVolumePanel } from '@kit.AudioKit';

import { StreamInfo } from '../model/extractor/StreamInfo';
import { StreamSegment } from '../model/extractor/StreamSegment';
import { AudioStream } from '../model/extractor/AudioStream';
import { VideoStream } from '../model/extractor/VideoStream';
import { MediaFormat } from '../model/enums/MediaFormat';
import { PlayQueueItem } from '../model/app/PlayQueueItem';
import { PlayQueue, PlayQueueEvent, SimplePlayQueue, currentPlayQueue, setCurrentPlayQueue,
  enqueueOnCurrentPlayQueue } from '../model/app/PlayQueue';
import { StreamInfoItem } from '../model/extractor/StreamInfoItem';
import { StreamEntity } from '../model/db/entity/StreamEntity';
import { PlaylistMetadataEntry } from '../model/db/view/PlaylistMetadataEntry';
import { StreamType } from '../model/enums/StreamType';

import { Localization } from '../common/i18n/Localization';
import { ExtractorHelper } from '../common/extractor/ExtractorHelper';
import { InfoCacheType } from '../common/extractor/InfoCache';
import { InfoItem } from '../common/extractor/core/InfoItem';
import { PlaybackReport, PlayerService, PlayerStatus, PlayerPosition, PipOutcome, RepeatMode,
  StreamSetAdapter } from '../common/player/PlayerService';
import {
  ShareUtils, mimeForStream, pickExternalVideo, pickExternalAudio, ExternalStreamChoice,
  externalVideoChoices, ExternalPlayerTarget, EXTERNAL_PLAYERS
} from '../common/share/ShareUtils';
import { ServiceLocator } from '../common/di/ServiceLocator';
import { AppDatabase } from '../common/db/AppDatabase';
import { HistoryRecordManager } from '../common/db/HistoryRecordManager';
import { LocalPlaylistManager, playlistAppendToast } from '../common/db/PlaylistManager';
import { CompositeDisposable, Disposable, Observable } from '../common/rx/Rx';
import { choosePreferredImage, shouldLoadImages } from '../common/image/ImageLoader';

import {
  ExpandableSurfaceView,
  SurfaceResizeMode
} from '../components/ExpandableSurfaceView';
import { CircleClipTapView } from '../components/CircleClipTapView';
import { SecondsView } from '../components/SecondsView';
import { SeekbarPreviewThumbnailHolder, SeekbarPreviewFrame }
  from '../components/SeekbarPreviewThumbnailHolder';
import {
  StreamSegmentAdapter,
  StreamSegmentDataSource
} from '../components/StreamSegmentAdapter';
import { PlayQueueAdapter, PlayQueueDataSource } from '../components/PlayQueueAdapter';
import { PlayQueueItemHolder } from '../components/PlayQueueItemHolder';
import { PlayQueueItemTouchCallback } from '../components/PlayQueueItemTouchCallback';
import { PlayQueueRowMenu } from '../components/PlayQueueRowMenu';
import { openChannelOfQueueItem } from '../common/util/QueueItemMenuUtil';
import { playWithKore } from '../common/util/KoreUtils';
import { getFilteredAudioStreams } from '../common/util/ListHelper';
import { AudioTrackGroup, audioTrackName, groupAudioTracks } from '../components/AudioTrackAdapter';
import { AudioTrackType } from '../model/extractor/AudioTrackType';
import { ScrollableTabLayout } from '../components/ScrollableTabLayout';
import { TabAdapter } from '../components/TabAdapter';
import { PlaylistDialog } from '../components/PlaylistDialog';
import { PlaylistAppendDialog } from '../components/PlaylistAppendDialog';
import { PlaylistCreationDialog } from '../components/PlaylistCreationDialog';

import { DownloadDialogHost } from './DownloadDialogPage';
import { PlaybackParameterDialogHost, PlaybackParameters, formatSpeed }
  from './PlaybackParameterDialogPage';
import { CommentsFragmentPage } from './CommentsFragmentPage';
import { RelatedItemsFragmentPage } from './RelatedItemsFragmentPage';
import { buildMetaInfoText, DescriptionFragmentPage, MetaInfoText } from './DescriptionFragmentPage';
import { NewPipeTextView } from '../components/NewPipeTextView';
import { LinkSpan } from '../common/text/Linkify';
import { linkTextToCopy, openUrlLink } from '../common/text/InternalUrlsHandler';
import { EmptyFragmentPage } from './EmptyFragmentPage';

import { MediaSessionService, MediaQueueHandler } from '../common/player/MediaSessionService';
import {
  MinimizeMode, PlayerPrefs, RESIZE_MODE_FILL, RESIZE_MODE_ZOOM
} from '../common/player/PlayerPrefs';
import { SeekbarPreview, seekbarPreviewTypeOf } from '../common/player/SeekbarPreview';
import { SubtitleLoader } from '../common/player/SubtitleLoader';
import { CueStyle, DEFAULT_CUE_STYLE, resolveCueStyle } from '../common/player/CaptionStyle';
import { preferredHeightOf } from '../common/settings/PreferredHeight';
import { readSystemCaptionStyle } from '../common/player/SystemCaptions';
import { PoTokenProviderImpl } from '../common/net/PoTokenProvider';
import { requestPoTokenWebView } from '../components/PoTokenWebView';
import { PermissionHelper } from '../common/perm/PermissionHelper';
import { DeepLinkRouter, ResolvedLink, RoutingDecision } from '../common/router/DeepLinkRouter';
import { AppPreferences } from '../common/prefs/Preferences';
import connection from '@ohos.net.connection';
import { MediaCapability, StreamingService } from '../common/extractor/core/StreamingService';
import { all as allServices } from '../common/extractor/ServiceRegistry';
import {
  show_comments_key, show_next_video_key, show_description_key, show_age_restricted_content,
  best_resolution_key, default_resolution_key, default_resolution_value,
  enable_playback_resume_key, seekbar_preview_thumbnail_key, show_higher_resolutions_key,
  show_play_with_kodi_key,
  auto_queue_key, autoplay_key, autoplay_never_key, autoplay_wifi_key,
  default_popup_resolution_key,
  default_popup_resolution_value,
  use_external_audio_player_key, use_external_video_player_key, brightness_control_key,
  volume_control_key, enable_watch_history_key, caption_user_set_key, show_hold_to_append_key,
  show_meta_info_key
} from '../common/prefs/SettingsKeys';
import { StreamStateEntity } from '../model/db/entity/StreamStateEntity';
import { SubtitlesStream } from '../model/extractor/SubtitlesStream';
import { ErrorInfo } from '../model/app/ErrorInfo';
import { UserAction } from '../model/enums/UserAction';
import { DIALOG_MASK_COLOR } from '../common/theme/ServiceTheme';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

const TAG: string = 'VideoDetailFragmentPage';

/**
 * Player.PLAY_PREV_ACTIVATION_LIMIT_MILLIS. playPrevious() restarts the CURRENT stream while it is
 * past this mark and only steps back to the previous one within it - the reference's own two-stage
 * previous, measured on device: at 00:42 the button sent Mystery back to its start, and a second
 * press inside the window moved to Punish Me.
 */
/** ServiceList.YouTube.getServiceId(), as FeedLoader and ErrorInfo already name it. */
/** The side panel's share of a >=840vp page. Chosen, not measured - see Task 5. */
const RELATED_PANEL_WIDTH: string = '32%';

const YOUTUBE_SERVICE_ID: number = 0;

/**
 * ListHelper.HIGH_RESOLUTION_LIST - the resolutions `show_higher_resolutions` gates, and the only
 * two the source gates. The settings screen already knows them as HIGH_RESOLUTION_OPTIONS; the
 * quality control did not, which is T-0195.
 */
const HIGH_RESOLUTIONS: number[] = [2160, 1440];
const PLAY_PREV_ACTIVATION_LIMIT_MILLIS: number = 5000;

/** activity_player_queue_control.xml declares its time labels as this until a position arrives. */
const NO_QUEUE_TIME: string = '-:--:--';

/** How far above the foot of the surface the cue sits - clear of the seekbar and its shadow. */
const SUBTITLE_BOTTOM_INSET_VP: number = 44;

/**
 * How far the player surface has to be dragged DOWN before the bottom sheet collapses into the
 * mini player - BottomSheetBehavior's own hide/settle distance, in vp.
 */
const COLLAPSE_DRAG_VP: number = 80;
/**
 * A downward FLING collapses the sheet from a shorter drag, as BottomSheetBehavior settles on
 * velocity as well as distance: past this speed (vp/s), any drag longer than the minimum counts.
 */
const COLLAPSE_FLING_VPS: number = 1000;
const COLLAPSE_FLING_MIN_VP: number = 24;

/**
 * detail_thumbnail_root_layout's collapsed height - the image inside declares minHeight 200dp.
 * In fullscreen the frame is the whole page instead, so the number is a value, not a literal.
 */
const PLAYER_FRAME_VP: number = 200;
/** How long the loaded thumbnail and its play arrow show before the player surface - the beat the
 * reference measured between its loading panel and its first black frame. */
const THUMBNAIL_BEAT_MS: number = 600;

/** player.xml gives every control in the two overlay rows an 8dp gap; they were flush. */
const CONTROL_SPACING_VP: number = 8;

/**
 * The player's icon controls are a 24 vp glyph inside a 36 vp touch target, which is what the
 * reference measures: its share button occupies 108x105 px at 3.035 px/dp = 35.6x34.6 dp, with a
 * uniform 7.9 dp to its neighbours. The port drew the 24 vp glyph AS the whole control and then
 * pushed each one 6 vp further out with a margin, so the targets were a third smaller and the gaps
 * uneven - 13.8 vp against the reference's 7.9.
 *
 * Applied to the SECONDARY row only. The primary row cannot take it: its labels are longer than the
 * reference's ("WebM 2160p" against "720p") and it also carries a metadataView the reference's main
 * player does not, so widening its controls overflows the row and clips moreOptionsButton - measured
 * at 28.9 vp of a 36 vp target with the right inset gone. That crowding is recorded on the card as a
 * separate finding rather than half-fixed here.
 */
const CONTROL_TOUCH_TARGET_VP: number = 36;
const CONTROL_GLYPH_INSET_VP: number = 6;
/** android:paddingHorizontal on the control row: 15.8 dp measured on the reference. */
const CONTROL_ROW_INSET_VP: number = 16;
/**
 * The horizontal padding on a 12sp text control, so a cell is a touch target rather than bare
 * text. The reference's are 150px and 177px wide on a 1080 frame for "Fit" and "english"; 6vp
 * gave the port 93px for "FIT", which is what reads as the second line packed too close.
 */
const CONTROL_LABEL_INSET_VP: number = 12;

/** CircleClipTapView's ValueAnimator duration and the burst's own hold, in ms. */
const FAST_SEEK_FADE_MS: number = 350;
const FAST_SEEK_HOLD_MS: number = 800;
/** A radius to expand to before the surface has ever been measured. */
const FAST_SEEK_MIN_RADIUS_VP: number = 120;

/** NavigationHelper.openVideoDetailFragment(serviceId, url, title) - the fragment arguments. */
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
 * One row of qualityPopupMenu. The label is StreamItemAdapter's (MediaFormat name + resolution),
 * the height is what MediaSourceResolver.resolve() is asked to land on, and videoOnly is the
 * row the source flags with a muted-speaker glyph.
 */
class QualityOption {
  label: string;
  height: number;
  videoOnly: boolean;

  constructor(label: string, height: number, videoOnly: boolean) {
    this.label = label;
    this.height = height;
    this.videoOnly = videoOnly;
  }

  /**
   * qualityTextView shows the RESOLUTION alone - measured on the reference, "Me at the zoo":
   * "360p", where the port's control read "MPEG-4 360p". The menu row keeps the full label,
   * which is what the reference's own popup shows.
   */
  indicator(): string {
    const parts: string[] = this.label.split(' ');
    return parts[parts.length - 1];
  }
}

/** StreamExtractor.NO_AGE_LIMIT - getAgeLimit() returns this when the stream is unrestricted. */
const NO_AGE_LIMIT: number = 0;

/** bottomSheetBehavior's three states; COLLAPSED and HIDDEN both show the mini player. */
enum BottomSheetState {
  EXPANDED,
  COLLAPSED,
  HIDDEN
}

/** overlay_layout's bound content: StreamInfo.name / uploaderName / thumbnails. */
class OverlayMetadata {
  title: string;
  channel: string;
  thumbnailUrl: string;

  constructor(title: string = '', channel: string = '', thumbnailUrl: string = '') {
    this.title = title;
    this.channel = channel;
    this.thumbnailUrl = thumbnailUrl;
  }
}

/**
 * MediaSessionPlayerUi's transport commands: what the AVSession (and therefore a hardware
 * media key or the system media notification) invokes on this page's queue and player.
 */
class DetailQueueHandler implements MediaQueueHandler {
  private readonly next: () => void;
  private readonly previous: () => void;
  private readonly close: () => void;
  private readonly shuffledNow: () => boolean;
  private readonly setShuffle: (on: boolean) => void;

  constructor(next: () => void, previous: () => void, close: () => void,
    shuffledNow: () => boolean, setShuffle: (on: boolean) => void) {
    this.next = next;
    this.previous = previous;
    this.close = close;
    this.shuffledNow = shuffledNow;
    this.setShuffle = setShuffle;
  }

  playNext(): void {
    this.next();
  }

  playPrevious(): void {
    this.previous();
  }

  stopPlayback(): void {
    this.close();
  }

  isShuffled(): boolean {
    return this.shuffledNow();
  }

  setShuffled(on: boolean): void {
    this.setShuffle(on);
  }
}

/** getSelectedTabTag()/pageAdapter tags - the pager children updateTabs(info) installs. */
enum DetailTab {
  COMMENTS,
  RELATED,
  DESCRIPTION,
  EMPTY
}

/**
 * QueueItemMenuUtil.openPopupMenu() raises a real popup WINDOW. Rendered inline it was a child of
 * the player-overlay Stack, which is only the 650px player frame: the six entries are ~950px
 * tall, so "Share" and "Download" were laid out past the bottom of their parent. They showed in
 * the dump with clickable=true and sensible bounds, they were even painted over the page - and a
 * tap on either did nothing, because hit-testing is clipped to the parent. Four of the six
 * entries worked and two were dead. A dialog gets its own window and cannot be clipped.
 */
@CustomDialog
struct PlayQueueRowMenuHost {
  controller?: CustomDialogController;
  onRemove: () => void = (): void => {};
  onDetails: () => void = (): void => {};
  onAppendPlaylist: () => void = (): void => {};
  onChannelDetails: () => void = (): void => {};
  onShare: () => void = (): void => {};
  onDownload: () => void = (): void => {};

  build() {
    PlayQueueRowMenu({
      onRemove: this.onRemove,
      onDetails: this.onDetails,
      onAppendPlaylist: this.onAppendPlaylist,
      onChannelDetails: this.onChannelDetails,
      onShare: this.onShare,
      onDownload: this.onDownload
    })
  }
}


/**
 * select_quality_external_players - the resolution chooser the source raises before handing a
 * stream to another app (VideoDetailFragment.showExternalVideoPlaybackDialog), with its neutral
 * "open in browser" button and its default selection.
 *
 * A dialog rather than a Menu for PlayQueueRowMenuHost's reason: a popup rendered inline is
 * clipped to the player frame and its lower rows stop taking taps.
 */
@CustomDialog
struct ExternalQualityDialog {
  controller?: CustomDialogController;
  /** select_quality_external_players, or select_audio_track_external_players for the tracks. */
  title: Resource = $r('app.string.select_quality_external_players');
  labels: string[] = [];
  @State picked: number = 0;
  onPick: (index: number) => void = (): void => {};
  onBrowser: () => void = (): void => {};

  build() {
    Column() {
      Text(this.title)
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .padding({ left: 24, right: 24, top: 24, bottom: 8 })

      List() {
        ForEach(this.labels, (label: string, index: number) => {
          ListItem() {
            Row() {
              Radio({ value: label, group: 'external_quality' })
                .checked(index === this.picked)
                .onChange((checked: boolean): void => {
                  if (checked) {
                    this.picked = index;
                  }
                })
              Text(label).fontSize(16).margin({ left: 8 })
            }
            .width('100%')
            .padding({ left: 16, right: 24, top: 8, bottom: 8 })
            .onClick((): void => {
              this.picked = index;
            })
          }
        }, (label: string, index: number) => label + index)
      }
      .width('100%')
      .constraintSize({ maxHeight: 360 })

      Row() {
        Button($r('app.string.open_in_browser'))
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .onClick((): void => {
            this.controller?.close();
            this.onBrowser();
          })
        Blank()
        Button($r('app.string.cancel'))
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .onClick((): void => this.controller?.close())
        Button($r('app.string.ok'))
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .onClick((): void => {
            this.controller?.close();
            this.onPick(this.picked);
          })
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 8, bottom: 8 })
    }
    .width('100%')
  }
}

/** The "open with" step: which installed player gets the copy (T-0212). */
@CustomDialog
struct ExternalPlayerDialog {
  controller?: CustomDialogController;
  labels: string[] = [];
  @State picked: number = 0;
  onPick: (index: number) => void = (): void => {};

  build() {
    Column() {
      Text($r('app.string.open_with'))
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .padding({ left: 24, right: 24, top: 24, bottom: 8 })

      List() {
        ForEach(this.labels, (label: string, index: number) => {
          ListItem() {
            Row() {
              Radio({ value: label, group: 'external_player' })
                .checked(index === this.picked)
                .onChange((checked: boolean): void => {
                  if (checked) {
                    this.picked = index;
                  }
                })
              Text(label).fontSize(16).margin({ left: 8 })
            }
            .width('100%')
            .padding({ left: 16, right: 24, top: 8, bottom: 8 })
            .onClick((): void => {
              this.picked = index;
            })
          }
        }, (label: string, index: number) => label + index)
      }
      .width('100%')
      .constraintSize({ maxHeight: 300 })

      Row() {
        Blank()
        Button($r('app.string.cancel'))
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .onClick((): void => this.controller?.close())
        Button($r('app.string.ok'))
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .onClick((): void => {
            this.controller?.close();
            this.onPick(this.picked);
          })
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 8, bottom: 8 })
    }
    .width('100%')
  }
}

@Entry
@Component
export struct VideoDetailFragmentPage {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  /* //////////////////////////////////////////////////////////////////////////
  // Loaded stream
  ////////////////////////////////////////////////////////////////////////// */

  /** currentInfo - the StreamInfo every bound site on this page reads. */
  @State currentInfo: StreamInfo | null = null;
  @State isLoading: boolean = false;
  /**
   * showLoading(): the source hides detail_content_root_hiding while loading, but ONLY when
   * the info is not already cached - 'transition from VISIBLE -> INVISIBLE -> VISIBLE is not
   * required' (VideoDetailFragment.java:1489). Visibility.Hidden, not an `if`, because the
   * source sets INVISIBLE: the node keeps its layout space and stays in the tree.
   *
   * The INITIAL value is false, not true: fragment_video_detail.xml:226 declares
   * detail_content_root_hiding `android:visibility="gone"`, so before any load has run the
   * source renders none of it. A launch that carries no stream url returns from startLoading()
   * before the isCached() assignment below, so this default is what such a state renders.
   */
  @State contentHidingVisible: boolean = false;
  /** handleError(): the message ErrorPanelHelper shows; empty means the panel is GONE. */
  @State lastPanelError: string = '';
  /** The classified ErrorInfo behind that message - report / reCaptcha / open-in-browser. */
  @State errorInfo: ErrorInfo | null = null;

  /* //////////////////////////////////////////////////////////////////////////
  // Bound values - everything handleResult(info) writes into the views
  ////////////////////////////////////////////////////////////////////////// */

  /** StreamInfo.name. */
  @State title: string = '';
  /** displayUploaderAsSubChannel(info): subChannelName, or the uploader name when it is empty. */
  @State uploaderSubChannelName: string = '';
  /** The RAW StreamInfo.subChannelName - empty is what drives displayUploaderAsSubChannel. */
  @State subChannelName: string = '';
  /** StreamInfo.uploaderSubscriberCount, with the uploader name when both rows are shown. */
  @State subscriberCount: string = '';
  /** StreamInfo.viewCount, worded per stream type (views / watching / listening). */
  @State viewCount: string = '';
  /** [likeCount, dislikeCount]; EMPTY when both are -1, which is "ratings disabled". */
  @State likeDislikeCounts: string[] = [];
  /** StreamInfo.duration. */
  @State durationBadge: string = '';
  /** StreamInfo.thumbnails, through choosePreferredImage(). */
  @State heroThumbnail: string = '';
  /**
   * handleResult() lays the loaded thumbnail and its play arrow out BEFORE autoplay attaches the
   * player, so the reference shows them for a beat between the loading panel and the black
   * surface. Here autoplay follows in the same tick, so the surface is held transparent for that
   * beat instead - playback itself is not delayed.
   */
  @State thumbnailBeat: boolean = false;
  /** The hero image has decoded; until then the reference shows its grey dummy thumbnail. */
  @State heroLoaded: boolean = false;
  /** [subChannelAvatar, uploaderAvatar]. */
  @State channelAvatars: string[] = [];
  /** StreamStateEntity.progressMillis - the resume bar over the thumbnail. */
  @State resumePositionBar: number = 0;
  /** showMetaInfoInTextView(info.getMetaInfo()): the banner's text; empty means GONE. */
  @State metaInfoBanner: string = '';
  /** Its links, one span per meta-info url (set together with metaInfoBanner). */
  private metaInfoSpans: LinkSpan[] = [];
  /** overlay_layout's content, from StreamInfo.name / uploaderName / thumbnails. */
  @State miniPlayerOverlay: OverlayMetadata = new OverlayMetadata();
  /** StreamInfo.getAgeLimit(); NO_AGE_LIMIT means the stream is not age restricted. */
  @State ageLimit: number = NO_AGE_LIMIT;
  /** StreamInfo.getStreamType() - live streams drop Download, reword views, badge LIVE. */
  @State streamType: StreamType = StreamType.NONE;
  /** videoStreams and videoOnlyStreams both empty: the audio-only presentation. */
  @State noVideoStreams: boolean = false;
  /** The full-length duration behind resumePositionBar, in ms. */
  @State private durationTotalMs: number = 0;
  /** prefs show_age_restricted_content - the other half of hideAgeRestrictedContent(). */
  @State private showAgeRestrictedContent: boolean = false;
  /** SubtitleLoader.activeText: the cue currently on screen. */
  @State private subtitleText: string = '';

  /**
   * What the cue is drawn with. The port used to author three literals here; the reference reads
   * the system's caption style and applies it, so this follows it. Recomputed on page show.
   */
  @State private cueStyle: CueStyle = DEFAULT_CUE_STYLE;

  /* //////////////////////////////////////////////////////////////////////////
  // View state
  ////////////////////////////////////////////////////////////////////////// */

  /** toggleTitleAndSecondaryControls(): title maxLines 1<->10, secondary panel VISIBLE<->GONE. */
  @State secondaryControlsShown: boolean = false;
  /** screen_download_dialog: a DialogFragment over this screen. */
  @State @Watch('onDownloadDialogVisibility') showDownloadDialog: boolean = false;
  /**
   * WHICH stream the download dialog is for - not always the one on screen. The queue row menu's
   * Download entry is for the HELD row, and passing the page's own (serviceId, url) opened the
   * dialog on the currently playing stream instead, whichever row had been long-pressed.
   * FeedFragmentPage keeps the same pair for the same reason.
   */
  @State private downloadServiceId: number = 0;
  @State private downloadUrl: string = '';
  /** screen_playback_parameter_dialog, opened by the top overlay's speed indicator. */
  @State @Watch('onPlaybackParametersVisibility') showPlaybackParameters: boolean = false;
  @State playbackParameters: PlaybackParameters = new PlaybackParameters(1.0, 1.0, false);
  /** pageAdapter's tags, in the order updateTabs(info) adds them. */
  @State tabPager: DetailTab[] = [];
  @State selectedTab: number = 0;
  @State tabTitles: string[] = [];
  /** bottomSheetBehavior state: EXPANDED shows the page, COLLAPSED/HIDDEN the mini player. */
  @State bottomSheetState: BottomSheetState = BottomSheetState.EXPANDED;
  /**
   * NavigationHelper.playOnPopupPlayer(): a list screen carries no XComponent, and PiPWindow
   * requires one (PiPConfiguration.componentController), so the popup entry points navigate here
   * with `popup: true` and this page - the only owner of a player surface - opens the popup for
   * them through openPopupPlayer(). Consumed once, on the first load.
   */
  private popupRequested: boolean = false;
  /** isFullscreen(): the player fills the screen, and the first back press only leaves it. */
  @State isFullscreen: boolean = false;
  /**
   * binding.relatedItemsLayout: null on the phone layout (Related is a pager tab), non-null on
   * layout-large-land, where RelatedItemsFragment gets a permanent side panel instead.
   */
  @State relatedItemsLayout: boolean = false;
  /**
   * The fragment's own LinkedList<StackItem> history, popped by onBackPress. StackItem's own
   * PlayQueue now exists (SimplePlayQueue) and is shared through currentPlayQueue, so the stack
   * only has to carry the three per-stream fields the pop restores.
   */
  @State stack: ItemParams[] = [];
  /** The RENDERED view of currentPlayQueue - readQueue() is the only thing that writes it. */
  @State playQueue: PlayQueueItem[] = [];
  /** The live queue itself; this page controls it and never owns it. */
  private livePlayQueue: PlayQueue | null = null;
  /** The live queue's own event bus, re-subscribed whenever the queue is replaced. */
  private queueEvents: Disposable | null = null;
  /**
   * cycleNextRepeatMode(): off -> one -> all. The PLAYER owns the mode; this is the page's view
   * of it, seeded in aboutToAppear so a rebuilt page shows what is actually in force.
   */
  @State repeatMode: number = 0;
  @State shuffled: boolean = false;
  /** QueueItemMenuUtil.openPopupMenu() on a queue-row long press. */
  @State rowMenuOpen: boolean = false;
  /** Which row the popup belongs to; -1 while it is closed. */
  @State heldIndex: number = -1;
  /** getResumePlaybackEnabled(): gates BOTH the stream-state query and the position views. */
  @State positionSubscriber: boolean = true;
  /** tryAddVideoPlayerView(): the MainPlayerUi view is attached only while a player exists. */
  @State playerAttached: boolean = false;

  /* //////////////////////////////////////////////////////////////////////////
  // Player state (MainPlayerUi)
  ////////////////////////////////////////////////////////////////////////// */

  @State playerStatus: PlayerStatus = PlayerStatus.IDLE;
  @State positionMs: number = 0;
  @State durationMs: number = 0;
  /** playbackSeekBar's secondary progress: where the buffered range ends. */
  @State bufferedMs: number = 0;
  /** showControls()/hideControls() - playbackControlRoot's visibility. */
  @State controlsVisible: boolean = true;
  /** moreOptionsButton: slides secondaryControls in and out. */
  @State playerSecondaryControlsShown: boolean = false;
  /** onQueueClicked() / onSegmentsClicked(): the two modes of the items-list panel. */
  @State isQueueVisible: boolean = false;
  @State areSegmentsVisible: boolean = false;
  /** setMuteButton(player.isMuted()). */
  @State muted: boolean = false;
  /** nextResizeModeAndSaveToPrefs() cycles fit / fill / zoom. */
  @State resizeMode: SurfaceResizeMode = SurfaceResizeMode.FIT;
  @State videoAspectRatio: number = 0;
  /**
   * onQualityClicked() / onCaptionClicked() / onAudioTracksClicked() labels.
   *
   * Every one of these is the CONTENT of a Text that carries the control's .bindMenu(). An
   * empty Text measures zero wide, so the control had no box, no hit area and no way of being
   * tapped - and each of them was written ONLY from inside the menu its own tap was supposed to
   * open. applyInfo() seeds all four from the loaded stream, which is what breaks that loop.
   */
  @State qualityLabel: string = '';
  @State captionLabel: string = '';
  @State audioTrackLabel: string = '';
  /** qualityPopupMenu's rows, built from videoStreams AND videoOnlyStreams. */
  @State qualityOptions: QualityOption[] = [];
  /** The height playback starts at - the Default resolution row, 0 when there is none (T-0196). */
  private startAtHeight: number = 0;
  /**
   * CHECKPOINT (T-0603): an EMPTY Text measures zero wide, so the control had no hit area and
   * .bindMenu() could never fire - and the label was only ever written from inside that same
   * menu's handler. Seeding it is what gives the control a box to be tapped on at all.
   */
  @State playbackSpeedLabel: string = '1x';
  /** audioTrackPopupMenu's rows - grouped AudioStreams, one group per selectable track. */
  @State audioTracks: AudioTrackGroup[] = [];
  @State selectedAudioTrack: number = 0;

  /* //////////////////////////////////////////////////////////////////////////
  // Gesture overlays (BasePlayerGestureListener)
  ////////////////////////////////////////////////////////////////////////// */

  @State fastSeekShowing: boolean = false;
  @State fastSeekForward: boolean = true;
  @State fastSeekX: number = 0;
  @State fastSeekY: number = 0;
  @State fastSeekRadius: number = 0;
  @State fastSeekSeconds: number = 0;
  @State fastSeekIconAlpha: number[] = [1, 1, 1];
  /** Which burst the pending hide belongs to, so a later tap cancels an earlier one's timer. */
  private fastSeekTicks: number = 0;
  /** The window's brightness, so a swipe continues from it instead of from zero. */
  private windowBrightness: number = 0.5;
  /** volumeRelativeLayout / brightnessRelativeLayout: shown only during their swipe. */
  @State volumeOverlayShowing: boolean = false;
  @State volumeProgress: number = 0;
  @State brightnessOverlayShowing: boolean = false;
  @State brightnessProgress: number = 0;
  /**
   * The swipe used to write a percentage taken straight off the gesture's offset, so every
   * drag began at zero whatever the level actually was. These carry the LIVE level between
   * gestures, exactly as BasePlayerGestureListener reads it off the AudioManager / the window.
   */
  private volumeAtGestureStart: number = -1;
  private brightnessAtGestureStart: number = -1;
  /**
   * AudioReactor.setVolume(): the swipe moves the DEVICE's media volume, as the source does, not
   * the player's attenuation - which could only ever turn the sound down. AVVolumePanel is the
   * one way an app may set the system volume; it takes the level through this prop.
   */
  @State private systemVolumeLevel: number = -1;
  private systemMaxVolume: number = 15;
  /** The level to come back to when the mute toggle is switched off again. */
  private unmutedVolume: number = 1;
  /** bottomSeekbarPreviewLayout: only while the seek bar is being dragged. */
  @State seekPreviewShowing: boolean = false;
  /**
   * onStartTrackingTouch/onStopTrackingTouch: NewPipe seeks only after a real drag or tap.
   * ArkUI also fires onChange for the programmatic value change of every position tick, so
   * without this an End with no user gesture behind it would seek the player ~10x/second.
   */
  private seekBarTouched: boolean = false;
  @State seekPreviewDisplay: string = '';
  /** A holder, not a bare PixelMap: @Prop would deep-copy the map and lose its native
   *  handle - see SeekbarPreviewFrame. */
  @State seekPreviewFrame: SeekbarPreviewFrame = new SeekbarPreviewFrame();

  /* //////////////////////////////////////////////////////////////////////////
  // Lists
  ////////////////////////////////////////////////////////////////////////// */

  /** buildQueue(): the items-list panel bound to the player's PlayQueue. */
  private queueSource: PlayQueueDataSource = new PlayQueueDataSource();
  @State queueIndex: number = 0;
  /** buildSegments(): the same panel bound to info.getStreamSegments(). */
  private segmentSource: StreamSegmentDataSource = new StreamSegmentDataSource();
  @State segmentIndex: number = 0;
  /** app:showSegments - the chapters control exists only for a stream that has chapters. */
  @State hasSegments: boolean = false;

  /** PlaylistDialog.createCorrespondingDialog(...) - the append-to-playlist chain. */
  @State hasPlaylists: boolean = false;
  @State appendPlaylists: PlaylistMetadataEntry[] = [];

  /* //////////////////////////////////////////////////////////////////////////
  // Arguments and services
  ////////////////////////////////////////////////////////////////////////// */

  /**
   * @State, not plain fields: the download dialog is a CustomDialogController member, and a
   * member controller's builder only re-reads what the framework observes.
   */
  @State private serviceId: number = 0;
  /** False when the arguments carried a URL but no service - i.e. this was a deep link. */
  private serviceIdKnown: boolean = false;
  @State private url: string = '';
  private name: string = '';

  /** Handed to ExpandableSurfaceView, and to PiPWindow.create() by openPopupPlayer(). */
  private surfaceController: XComponentController = new XComponentController();
  /**
   * The detail page's own scroll. BottomSheetBehavior collapses the sheet when the player is
   * scrolled away from, so the offset has to be readable - onDidScroll hands over a DELTA.
   */
  private detailScroller: Scroller = new Scroller();
  /** The page was at its top when the current drag on the detail header began. */
  private dragStartedAtTop: boolean = false;
  /**
   * The scroller's viewport height, which is what the pager page is sized to: the header above
   * it then scrolls away exactly as far as it is tall, and never further.
   */
  @State private pagerViewportVp: number = 0;
  /** The player surface's measured width, so a double tap resolves to left / middle / right. */
  @State private playerWidth: number = 0;
  /** The gesture range: the reference maps HALF the frame's height to the whole 0-100 sweep. */
  @State private playerHeight: number = 0;

  private database: AppDatabase | null = null;
  private historyRecordManager: HistoryRecordManager | null = null;
  private playlistManager: LocalPlaylistManager | null = null;
  private readonly disposables: CompositeDisposable = new CompositeDisposable();

  /**
   * screen_download_dialog is an AlertDialog in the source, and .bindSheet() rendered it as a
   * full-bleed sheet - the "window is too large and does not fit on the screen" the cases
   * report. CustomDialogController({ customStyle: true }) is the same pattern the three
   * dialogs below already use: a centred, self-sized, square-cornered card.
   *
   * The dialog dismisses itself through its @Link, so the flag drives the controller rather
   * than the other way round - see onDownloadDialogVisibility().
   */
  private downloadDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    customStyle: true,
    // A tap outside (or a back gesture) closes the controller WITHOUT going through the
    // dialog's own @Link, so the flag would stay true and the next tap on Download - no state
    // change, no @Watch - would open nothing at all.
    cancel: (): void => {
      this.showDownloadDialog = false;
    },
    builder: DownloadDialogHost({
      isShown: this.showDownloadDialog,
      serviceId: this.downloadServiceId,
      url: this.downloadUrl
    })
  });

  /** The one way in: point the dialog at a stream, then show it. */
  private openDownloadFor(serviceId: number, url: string): void {
    if (url.length === 0) {
      return;
    }
    this.downloadServiceId = serviceId;
    this.downloadUrl = url;
    this.showDownloadDialog = true;
  }

  private onDownloadDialogVisibility(): void {
    if (this.showDownloadDialog) {
      this.downloadDialog.open();
    } else {
      this.downloadDialog.close();
    }
  }

  private playlistDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    builder: PlaylistDialog({
      hasPlaylists: this.hasPlaylists,
      onAppend: (): void => {
        this.openAppendDialog();
      },
      onCreate: (): void => {
        this.creationDialog.open();
      }
    })
  });

  private appendDialog: CustomDialogController = new CustomDialogController({
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
      onCreate: (playlistName: string): void => {
        this.createPlaylistWithTarget(playlistName);
      }
    })
  });

  /* //////////////////////////////////////////////////////////////////////////
  // Lifecycle
  ////////////////////////////////////////////////////////////////////////// */

  /** KoreUtils.shouldShowPlayWithKodi(): show_play_with_kodi, which defaults to OFF. */
  @State showPlayWithKodi: boolean = false;

  /**
   * KoreUtils.shouldShowPlayWithKodi(context, serviceId) is the preference AND the service:
   * `serviceId == ServiceList.YouTube.getServiceId() && isKeyEnabled(...)`. Both comments in this
   * file said so and the service half was never written, so with the preference on the control was
   * drawn on a Bandcamp track and a PeerTube video too - streams Kore cannot take (T-0192). The
   * preference is read in aboutToAppear, before readArguments() knows the service, so the two
   * halves meet here rather than in showPlayWithKodi itself.
   *
   * THIS WAS REVERTED ONCE (8d72d07) AND REINSTATED. The revert was made on a reference reading
   * that looked like "Bandcamp shows Kodi too", and it was a mis-navigation: the page being read
   * was still a YouTube one. Re-measured 2026-09-30 with two controls in the same app session,
   * `adb shell dumpsys activity top` (which lists invisible views, so V and G are unambiguous):
   *
   *   YouTube video   detail_controls_play_with_kodi  V  714,0-1062,165
   *   Bandcamp track  detail_controls_popup           G   <- proves it IS the Bandcamp page
   *                   detail_controls_play_with_kodi  G  0,0-0,0
   *                   share/open_in_browser widen to 522px each, filling Kodi's space
   *
   * Two things to know before re-measuring: the reference does not apply
   * `Show "Play with Kodi"` in the running process - force-stop and relaunch after flipping it -
   * and `detail_controls_popup` being GONE is the cheap proof that the page really is an
   * audio-only Bandcamp one. Check the page identity before reading the control.
   */
  private kodiAvailableForStream(): boolean {
    return this.showPlayWithKodi && this.serviceId === YOUTUBE_SERVICE_ID;
  }

  aboutToAppear(): void {
    // The player owns the repeat mode; show what is actually in force rather than OFF.
    this.repeatMode = PlayerService.getInstance().getRepeatMode() as number;
    // retrieveResizeModeFromPrefs(): the mode the last session ended on.
    this.resizeMode =
      VideoDetailFragmentPage.surfaceModeOf(PlayerService.getInstance().getResizeMode());
    this.showPlayWithKodi =
      VideoDetailFragmentPage.prefBool(show_play_with_kodi_key, false);
    this.readArguments();
    this.showAgeRestrictedContent =
      VideoDetailFragmentPage.prefBool(show_age_restricted_content, false);
    // getResumePlaybackEnabled(activity): with resume off there is no stream-state query at all.
    this.positionSubscriber = VideoDetailFragmentPage.prefBool(enable_playback_resume_key, true);
    this.observePlayer();
    this.observeQueue();
    this.seedBrightness();
    this.refreshCueStyle();
    this.loadThenPopupIfRequested();
  }

  /** A caption style changed in Settings has to reach a page that is already built. */
  onPageHide(): void {
    // The hand-off starts another app, which hides this page; the choice is made by then, so
    // neither dialog should be waiting here when the viewer comes back.
    this.closeHandOffDialogs();
  }

  onPageShow(): void {
    this.refreshCueStyle();
  }

  /** The cue's look, resolved from the system style and the user's override. */
  private async refreshCueStyle(): Promise<void> {
    // The in-app caption override is no longer reachable (the Captions row is disabled), so a
    // value saved by it earlier must not keep restyling cues with no way left to undo it.
    this.cueStyle = resolveCueStyle(readSystemCaptionStyle(), null);
  }

  /**
   * startLoading() is fire-and-forget from aboutToAppear, but a popup started from a list has to
   * wait for the stream: openPopupPlayer() is the ONE popup implementation and it needs the
   * loaded info and this page's surface.
   */
  private async loadThenPopupIfRequested(): Promise<void> {
    await this.startLoading();
    if (this.fullscreenRequested && this.currentInfo !== null) {
      this.fullscreenRequested = false;
      this.popupRestored();
    }
    if (this.popupRequested) {
      this.popupRequested = false;
      // PiPWindow renders the popup FROM this page's XComponent, and a restore hands that same
      // surface back here, so the page cannot leave while the window is up - which is why the
      // popup left the user parked on a full player they never opened. It leaves when the window
      // does instead, putting them back on the screen they tapped Popup from.
      if (await this.openPopupPlayer()) {
        this.openedForPopup = true;
        PlayerService.getInstance().setPipClosedListener((): void => {
          this.leaveWithThePopup();
        });
      }
      return;
    }
    // handleResult(): `if (autoPlayEnabled) { openVideoPlayerAutoFullscreen(); }` - tapping an
    // item OPENS this screen and STARTS the stream. Nothing here did the second half, so every
    // tap landed on a loaded page parked at 00:00 behind the play overlay. Only a popup entry
    // opts out (it starts its own player above), and a load that failed has nothing to start.
    //
    // T-0194: that gate used to be `!this.playerAttached`, which asks whether the player holds
    // ANYTHING - and the answer is yes whenever something else is already playing. Tapping a
    // stream from a list then opened this page, loaded the new stream's metadata and drew its
    // player - title, seekbar, and for a live stream the LIVE badge - while the service kept the
    // OLD source. The previous track carried on behind it and stopped at ITS length: measured on
    // the port, a live page whose position ran to 02:17, exactly the length of the Bandcamp track
    // underneath, and then logged `stateChange=completed`. A live stream does not complete.
    //
    // The same defect was found and fixed twice already, on the queue-selection path in
    // loadItem()'s caller below and on the queue-handover path in startLoading(); both of their
    // comments describe this symptom. This was the third entry point and the last one left.
    //
    // The question is whether the player already holds THIS stream - which is how the page is
    // entered from the mini player, and where starting again would restart what the user is
    // listening to - not whether it holds anything at all.
    // Both sides of the comparison are the EXTRACTOR's url, not the router's. `this.url` is
    // whatever the caller passed in readArguments(), and a short or parameterised link -
    // youtu.be/..., a `t=` suffix - would not match the StreamInfo the player holds for the very
    // same stream, which would restart what the user is listening to. The loaded info is the one
    // this page and the player both got from the same place.
    const playing: StreamInfo | null = PlayerService.getInstance().currentInfo.getValue();
    const loaded: StreamInfo | null = this.currentInfo;
    const alreadyPlayingThisStream: boolean =
      playing !== null && loaded !== null && playing.getUrl() === loaded.getUrl();
    if (this.currentInfo !== null && !alreadyPlayingThisStream
      && VideoDetailFragmentPage.isAutoplayAllowedByUser()) {
      await this.openVideoPlayerAutoFullscreen();
    }
  }

  /**
   * openVideoPlayerAutoFullscreen(): the main player, in fullscreen straight away when
   * start_main_player_fullscreen asks for it - behind replaceQueueIfUserConfirms().
   */
  private async openVideoPlayerAutoFullscreen(): Promise<void> {
    if (!await this.userAllowsQueueReplacement()) {
      return;
    }
    if (PlayerPrefs.isStartMainPlayerFullscreenEnabled() && !this.isFullscreen) {
      this.toggleFullscreen();
    }
    await this.openVideoPlayer(false);
  }

  /**
   * replaceQueueIfUserConfirms(): with clear_queue_confirmation on, starting this stream over a
   * player that is still busy with ANOTHER queue asks first. The other queue is only replaced when
   * this stream really starts (see pendingQueue), so declining simply leaves it playing.
   */
  private async userAllowsQueueReplacement(): Promise<boolean> {
    if (!PlayerPrefs.isClearingQueueConfirmationRequired() || this.pendingQueue === null
      || !this.playerBusyWithAnotherStream()) {
      return true;
    }
    try {
      const choice: promptAction.ShowDialogSuccessResponse = await promptAction.showDialog({
        title: Localization.getString('clear_queue_confirmation_description'),
        buttons: [
          { text: $r('app.string.cancel'), color: '#FF000000' },
          { text: $r('app.string.ok'), color: '#FF000000' }
        ]
      });
      if (choice.index === 1) {
        return true;
      }
    } catch (err) {
      // Dismissed: the same as Cancel.
    }
    return false;
  }

  /**
   * The fragment's own playQueue, as opposed to the PLAYER's: the one-item queue of the stream on
   * this page while the player is still busy with something else. It becomes the live queue when
   * this stream starts playing (promotePendingQueue), never merely because the page was opened -
   * replacing the live queue on load left a queue that no longer held what was playing.
   */
  private pendingQueue: PlayQueue | null = null;

  /** isPlayerAvailable() && the player is on a DIFFERENT stream that has not stopped. */
  private playerBusyWithAnotherStream(): boolean {
    const player: PlayerService = PlayerService.getInstance();
    const playing: StreamInfo | null = player.currentInfo.getValue();
    const status: PlayerStatus | null = player.state.getValue();
    const loaded: StreamInfo | null = this.currentInfo;
    return player.hasPlayer() && playing !== null
      && (loaded === null || playing.getUrl() !== loaded.getUrl())
      && (status === PlayerStatus.PLAYING || status === PlayerStatus.PAUSED
        || status === PlayerStatus.BUFFERING);
  }

  private promotePendingQueue(): void {
    const pending: PlayQueue | null = this.pendingQueue;
    if (pending !== null) {
      this.pendingQueue = null;
      setCurrentPlayQueue(pending);
    }
  }

  /**
   * openBackgroundPlayer(true) / openPopupPlayer(true): a LONG press enqueues this stream on the
   * running player instead of replacing what it plays - NavigationHelper.enqueueOnPlayer(), with
   * its "Enqueued" toast. With nothing playing there is no queue to join, so the stream starts in
   * that player, which is where the source's enqueue intent falls through to.
   */
  private enqueueOnPlayer(audioOnly: boolean): void {
    const info: StreamInfo | null = this.currentInfo;
    if (info === null) {
      return;
    }
    promptAction.showToast({ message: $r('app.string.enqueued'), duration: 2000 });
    const player: PlayerService = PlayerService.getInstance();
    if (player.hasPlayer() && player.currentInfo.getValue() !== null
      && currentPlayQueue.getValue() !== null) {
      enqueueOnCurrentPlayQueue([PlayQueueItem.fromStreamInfo(info)]);
      return;
    }
    if (audioOnly) {
      this.openBackgroundPlayer();
    } else {
      this.openPopupPlayer();
    }
  }

  /** Set only on a page pushed BY a popup entry point, whose popup really became a PiP window. */
  private openedForPopup: boolean = false;
  /** The second a timestamp link asked for; consumed by the first play. -1 = none. */
  private pendingStartSeconds: number = -1;
  /** loadStreamState(info)'s answer, kept for the resume decision when playback starts. */
  private savedStreamState: StreamStateEntity | null = null;
  /**
   * A queue selection and a hand-over after a finished item play from the start: only the
   * player's FIRST item resumes from its saved position (Player.handleIntent, RESUME_PLAYBACK).
   */
  private skipResumeOnce: boolean = false;

  /** The popup's window closed; this page existed for it, so it goes back where it came from. */
  private leaveWithThePopup(): void {
    if (!this.openedForPopup) {
      return;
    }
    this.openedForPopup = false;
    try {
      router.back();
    } catch (err) {
      hilog.warn(0x0000, TAG, 'back after the popup closed: %{public}s',
        (err as BusinessError).message);
    }
  }

  /**
   * getScreenBrightness(): the swipe continues from where the screen IS. A window that follows
   * the system reports -1, which is not a level and cannot be added to.
   */
  private async seedBrightness(): Promise<void> {
    try {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const win: window.Window = await window.getLastWindow(context);
      const level: number = win.getWindowProperties().brightness;
      this.windowBrightness = level >= 0 && level <= 1 ? level : 0.5;
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      hilog.warn(0x0000, TAG, 'getWindowProperties: %{public}s', failure.message);
    }
  }

  /** onDestroy(): dispose every subscription and persist where the user got to (Rule 8). */
  aboutToDisappear(): void {
    this.saveProgress();
    // The page is going anyway: nothing for the popup's close to send away.
    this.openedForPopup = false;
    PlayerService.getInstance().setPipClosedListener(null);
    PlayerService.getInstance().clearPipRestoredListener(this.popupRestored);
    // Its surface goes with it, so no PiP can be opened from it on app switch any more.
    PlayerService.getInstance().disarmAutoPip();
    // The orientation is a WINDOW property and outlives the page; leaving it on LANDSCAPE
    // would hand the next screen a sideways window.
    if (this.isFullscreen) {
      this.applyOrientation(false);
      this.restoreDefaultBrightness();
    }
    const events: Disposable | null = this.queueEvents;
    if (events !== null) {
      events.dispose();
      this.queueEvents = null;
    }
    this.disposables.dispose();
  }

  private readArguments(): void {
    const params: Record<string, Object> | undefined =
      router.getParams() as Record<string, Object> | undefined;
    if (params === undefined || params === null) {
      return;
    }
    const sid: Object | undefined = params['serviceId'];
    if (sid !== undefined && sid !== null) {
      this.serviceId = Number(sid.toString());
      this.serviceIdKnown = true;
    }
    const streamUrl: Object | undefined = params['url'];
    if (streamUrl !== undefined && streamUrl !== null) {
      this.url = streamUrl.toString();
    }
    const streamName: Object | undefined = params['name'];
    if (streamName !== undefined && streamName !== null) {
      this.name = streamName.toString();
    }
    const popup: Object | undefined = params['popup'];
    this.popupRequested = popup !== undefined && popup !== null && popup.toString() === 'true';
    // Back from a popup a list screen opened: "starting directly in fullscreen".
    const fullscreen: Object | undefined = params['fullscreen'];
    this.fullscreenRequested = fullscreen !== undefined && fullscreen !== null
      && fullscreen.toString() === 'true';
    // A timestamp link opens the stream AT that second (TimestampChangeData.seconds).
    const startPosition: Object | undefined = params['startPosition'];
    if (startPosition !== undefined && startPosition !== null) {
      const seconds: number = Number.parseInt(startPosition.toString(), 10);
      this.pendingStartSeconds = Number.isNaN(seconds) ? -1 : seconds;
    }
    // "Switch to Main" pushes this page WITHOUT the popup flag while the PiP window the previous
    // instance opened is still up - so the stream played in the embedded player AND in a floating
    // window at the same time, both drawing, until the app was killed. Arriving in main mode
    // closes any popup this app owns.
    if (!this.popupRequested) {
      const player: PlayerService = PlayerService.getInstance();
      if (player.isPipActive()) {
        player.exitPip().catch((err: BusinessError): void => {
          hilog.warn(0x0000, TAG, 'exit pip: %{public}s', err.message);
        });
      }
    }
  }

  /** PlayerService's state / position subjects replace the ExoPlayer listener callbacks. */
  /** One guarded read: the preference store is opened by EntryAbility, not by this page. */
  private static prefString(key: string, defValue: string): string {
    try {
      const prefs: AppPreferences = ServiceLocator.get().preferences;
      return prefs.getStringSync(key, defValue);
    } catch (err) {
      hilog.warn(0x0000, TAG, 'preference %{public}s: %{public}s', key,
        (err as BusinessError).message);
      return defValue;
    }
  }

  /** One guarded read: the preference store is opened by EntryAbility, not by this page. */
  private static prefBool(key: string, defValue: boolean): boolean {
    try {
      const prefs: AppPreferences = ServiceLocator.get().preferences;
      return prefs.getBooleanSync(key, defValue);
    } catch (err) {
      return defValue;
    }
  }

  /**
   * PlayerHelper.isAutoplayAllowedByUser(context): @string/autoplay_key is a three-way choice -
   * "never" rules autoplay out, "wifi" (the default) allows it off a metered network, "always"
   * allows it unconditionally. RouterActivityPage already reads the same preference; nothing on
   * THIS screen did, which is why a tapped stream loaded and then sat at 00:00.
   */
  private static isAutoplayAllowedByUser(): boolean {
    let choice: string = autoplay_wifi_key;
    try {
      // getStringSync with the literal default, the way VideoAudioSettingsFragmentPage reads the
      // same row: @string/autoplay_wifi_key has no string resource behind it, so the RESOLVED
      // form hands back the unresolved "@string/..." and matches none of the three choices.
      choice = ServiceLocator.get().preferences.getStringSync(autoplay_key, autoplay_wifi_key);
    } catch (err) {
      choice = autoplay_wifi_key;
    }
    if (choice === autoplay_never_key) {
      return false;
    }
    if (choice !== autoplay_wifi_key) {
      return true;
    }
    return !VideoDetailFragmentPage.isMeteredNetwork();
  }

  /**
   * ListHelper.isMeteredNetwork(context): the source asks ConnectivityManager and, with no
   * active network to ask about, answers false - so a read that fails still autoplays.
   * ponytail: cellular stands for metered here; if a metered Wi-Fi ever has to count, read
   * NET_CAPABILITY_NOT_METERED off the same capabilities instead.
   */
  private static isMeteredNetwork(): boolean {
    try {
      const caps: connection.NetCapabilities =
        connection.getNetCapabilitiesSync(connection.getDefaultNetSync());
      const bearers: connection.NetBearType[] = caps.bearerTypes;
      return bearers !== undefined && bearers !== null
        && bearers.includes(connection.NetBearType.BEARER_CELLULAR);
    } catch (err) {
      return false;
    }
  }

  private observePlayer(): void {
    const player: PlayerService = PlayerService.getInstance();
    this.disposables.add(player.position.subscribeCallbacks((at: PlayerPosition): void => {
      this.positionMs = at.positionMs;
      this.durationMs = at.durationMs;
      // onProgressUpdate has spoken: the header stops standing in and prints what it was told,
      // 00:00 included. The placeholder belongs to the time BEFORE the first update, not to
      // every zero - measured on the reference, whose live stream reads "3:59:59/00:00".
      this.queueTimeReported = true;
      // onTextTracksChanged/onCues: the loader picks the cue for the current position.
      SubtitleLoader.getInstance().update(at.positionMs);
    }, (error: Error): void => {
      hilog.warn(0x0000, TAG, 'player position: %{public}s', error.message);
    }));
    this.disposables.add(player.bufferedMs.subscribeCallbacks((bufferedMs: number): void => {
      this.bufferedMs = bufferedMs;
    }, (error: Error): void => {
      hilog.warn(0x0000, TAG, 'player buffer: %{public}s', error.message);
    }));
    this.disposables.add(SubtitleLoader.getInstance().activeText
      .subscribeCallbacks((cue: string): void => {
        this.subtitleText = cue;
      }, (error: Error): void => {
        hilog.warn(0x0000, TAG, 'subtitles: %{public}s', error.message);
      }));
    this.disposables.add(player.state.subscribeCallbacks((status: PlayerStatus): void => {
      const wasPlaying: boolean = this.playerStatus !== PlayerStatus.COMPLETED;
      this.playerStatus = status;
      this.playerAttached = status !== PlayerStatus.IDLE;
      const playing: StreamInfo | null = PlayerService.getInstance().currentInfo.getValue();
      const shown: StreamInfo | null = this.currentInfo;
      if (status === PlayerStatus.PLAYING && playing !== null && shown !== null
        && playing.getUrl() === shown.getUrl()) {
        // The player can swap a refused synthesized rendition for the muxed file on its own, so
        // the chip re-reads what is really playing rather than what prepare() first reported.
        this.showServedQuality(new PlaybackReport(PlayerService.getInstance().getSource(), ''));
      }
      // onPlaybackEnded(). `wasPlaying` keeps a repeated COMPLETED from advancing twice. The
      // auto_queue preference is NOT spent here any more: the source appends the related stream
      // when playback STARTS (Player.maybeAutoQueueNextStream), see playInner().
      if (status === PlayerStatus.COMPLETED && wasPlaying) {
        // onPlaybackEnded() consults the repeat mode FIRST: REPEAT_ONE restarts this stream,
        // REPEAT_ALL wraps the queue instead of stopping at its end. The mode used to live as a
        // bare @State here, so a finished stream simply stopped no matter what the control showed.
        if (this.handleRepeatOnCompletion()) {
          return;
        }
        // onPlaybackEnded() -> the queue hands over to whatever is behind the finished stream.
        // The port stopped dead instead: nothing advanced the cursor, so a queue only ever moved
        // when the user pressed Next. That is why the auto-queue preference looked broken - it
        // APPENDED the related stream correctly (verified on device: the queue went from one item
        // to two) and then nobody played it. The same gap stopped an ordinary playlist after its
        // first entry. Repeat ONE and ALL have already returned above, so this is the OFF path.
        this.advanceAfterCompletion();
      }
    }, (error: Error): void => {
      hilog.warn(0x0000, TAG, 'player state: %{public}s', error.message);
    }));
    // The label has to follow the rate AVPlayer could really deliver, not the one asked for.
    this.disposables.add(player.appliedSpeed.subscribeCallbacks((rate: number): void => {
      // T-0132: the readout is the requested rate, not the enum step it snapped to.
      this.playbackSpeedLabel = formatSpeed(PlayerService.getInstance().displayRate());
    }, (error: Error): void => {
      hilog.warn(0x0000, TAG, 'player speed: %{public}s', error.message);
    }));
    this.disposables.add(player.behindLiveEdge.subscribeCallbacks((behind: boolean): void => {
      this.behindLiveEdge = behind;
    }, (error: Error): void => {
      hilog.warn(0x0000, TAG, 'live edge: %{public}s', error.message);
    }));
    this.disposables.add(player.lastError.subscribeCallbacks((message: string): void => {
      if (message.length > 0) {
        this.lastPanelError = message;
      } else if (this.errorInfo === null) {
        // A player error the player has since recovered from (a stall, a fallback source) is
        // not the page's to keep showing. A LOAD failure (errorInfo) stays until a reload.
        this.lastPanelError = '';
      }
    }, (error: Error): void => {
      hilog.warn(0x0000, TAG, 'player error: %{public}s', error.message);
    }));
  }

  private async ensureServices(): Promise<void> {
    if (this.database !== null) {
      return;
    }
    try {
      const context: common.Context = getContext(this) as common.Context;
      const db: AppDatabase = await AppDatabase.getInstance(context);
      this.database = db;
      this.historyRecordManager = new HistoryRecordManager(db);
      this.playlistManager = new LocalPlaylistManager(db);
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      hilog.warn(0x0000, TAG, 'ensureServices: %{public}s', failure.message);
    }
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Load
  ////////////////////////////////////////////////////////////////////////// */

  /** startLoading(forceLoad) -> ExtractorHelper.getStreamInfo(serviceId, url, forceLoad). */
  private async startLoading(forceLoad: boolean = false): Promise<void> {
    if (this.url.length === 0) {
      return;
    }
    await this.resolveDeepLink();
    this.isLoading = true;
    // showLoading(): the title the caller handed in is on screen at once, and initTabs() has
    // already built the pager's strip - the reference shows both while the info is in flight.
    if (this.name.length > 0) {
      this.title = this.name;
    }
    if (this.tabPager.length === 0) {
      this.updateTabs(this.serviceId);
    }
    this.contentHidingVisible =
      ExtractorHelper.isCached(this.serviceId, this.url, InfoCacheType.STREAM);
    this.lastPanelError = '';
    this.errorInfo = null;
    await this.ensureServices();
    await this.ensurePoToken();
    try {
      const info: StreamInfo = await ExtractorHelper.getStreamInfo(
        this.serviceId, this.url, forceLoad);
      this.currentInfo = info;
      this.contentHidingVisible = true;
      this.name = info.getName();
      // BEFORE applyInfo(): applyInfo seeds audioTrackLabel from audioTrackName(0), which reads
      // this.audioTracks. Grouped after, the list was still empty at that moment, so the control
      // read "Unknown" on every stream - including one whose tracks are all named.
      this.audioTracks = VideoDetailFragmentPage.groupAudioTracks(info.audioStreams);
      this.applyInfo(info);
      this.thumbnailBeat = true;
      setTimeout(() => {
        this.thumbnailBeat = false;
      }, THUMBNAIL_BEAT_MS);
      this.updateTabs(info.getServiceId());
      this.segmentSource.setItems(info.streamSegments);
      // segmentsButton is GONE on a stream with no chapters, which is what the reference does -
      // its primary row carries the control on "Me at the zoo" and does not on a stream without
      // them. So the count decides the control, not an empty list behind it.
      this.hasSegments = info.streamSegments.length > 0;
      await this.loadResumePosition(info);
      await this.prepareSeekbarPreview(info);
      if (this.handingOverToNextItem) {
        // The queue handed over to this item because the one before it finished, so it has to
        // START. The page's other auto-start lives in loadThenPopupIfRequested(), which runs on
        // the FIRST load only and is gated on `!playerAttached` - and after a COMPLETED the
        // player is still attached, it has merely run out of stream. Neither half could carry a
        // handover, which is why the queue advanced on screen and nothing played.
        this.handingOverToNextItem = false;
        await this.play(info, false);
      }
    } catch (err) {
      // handleError(): the panel replaces the content, and ErrorInfo classifies WHICH panel -
      // reportable, retryable, a reCaptcha challenge, or openable in a browser.
      const failure: Error = err instanceof Error
        ? err as Error : new Error(VideoDetailFragmentPage.describeThrown(err));
      this.errorInfo = ErrorInfo.fromThrowable(failure, UserAction.REQUESTED_STREAM,
        this.url, this.serviceId, this.url);
      this.lastPanelError = failure.message;
    } finally {
      this.isLoading = false;
    }
  }

  /**
   * A thrown BusinessError is not an Error, and interpolating one prints "[object Object]" -
   * which is what the panel and the player's own error toast were showing.
   */
  private static describeThrown(err: ESObject): string {
    const failure: BusinessError = err as BusinessError;
    if (failure !== undefined && failure !== null && failure.message !== undefined) {
      return failure.code + ': ' + failure.message;
    }
    return String(err);
  }

  /**
   * getUrl(intent) -> RouterActivity: a deep link arrives as a bare URL, so the service that
   * claims it must be resolved before the stream can be loaded at all. Nothing to do when the
   * caller already passed a serviceId (the in-app navigation path).
   */
  private async resolveDeepLink(): Promise<void> {
    if (this.serviceIdKnown || this.url.length === 0) {
      return;
    }
    const linkRouter: DeepLinkRouter = ServiceLocator.get().deepLinkRouter;
    try {
      const decision: RoutingDecision = await linkRouter.resolve(this.url);
      const link: ResolvedLink | null = decision.link;
      if (link !== null && link.serviceId >= 0) {
        this.serviceId = link.serviceId;
        this.url = link.url;
        this.serviceIdKnown = true;
      }
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      hilog.warn(0x0000, TAG, 'deep link: %{public}s', failure.message);
    }
  }

  /**
   * PoTokenProviderImpl.prepare(videoId): the WEB client needs a poToken before the streams
   * resolve. requestPoTokenWebView() asks the host to mount the off-screen WebView that
   * registers the driver; with no driver prepare() resolves false at once and the extractor
   * simply falls back to the nsig-free client.
   */
  private async ensurePoToken(): Promise<void> {
    if (this.serviceId !== 0 || this.url.length === 0) {
      return;
    }
    requestPoTokenWebView();
    try {
      await PoTokenProviderImpl.getInstance().prepare(VideoDetailFragmentPage.videoIdOf(this.url));
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      hilog.warn(0x0000, TAG, 'poToken: %{public}s', failure.message);
    }
  }

  /** The `v=` parameter YouTube identifies the stream by, else the whole url. */
  private static videoIdOf(url: string): string {
    const match: RegExpMatchArray | null = url.match(/[?&]v=([A-Za-z0-9_-]+)/);
    return match === null ? url : match[1];
  }

  /** loadStreamState(info): the resume position, queried ONLY when resume is enabled. */
  private async loadResumePosition(info: StreamInfo): Promise<void> {
    this.savedStreamState = null;
    if (!this.positionSubscriber) {
      this.resumePositionBar = 0;
      return;
    }
    const history: HistoryRecordManager | null = this.historyRecordManager;
    if (history === null) {
      return;
    }
    try {
      const state: StreamStateEntity | null = await history.loadStreamStateOfInfo(info);
      this.savedStreamState = state;
      this.resumePositionBar = state === null ? 0 : state.progressMillis;
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      hilog.warn(0x0000, TAG, 'loadStreamState: %{public}s', failure.message);
    }
  }

  /** SeekbarPreviewThumbnailHelper: the framesets this stream exposes, at the stored quality. */
  private async prepareSeekbarPreview(info: StreamInfo): Promise<void> {
    let stored: string = '';
    try {
      const prefs: AppPreferences = ServiceLocator.get().preferences;
      stored = prefs.getStringSync(seekbar_preview_thumbnail_key, '');
    } catch (err) {
      stored = '';
    }
    try {
      await SeekbarPreview.getInstance()
        .resetFrom(info.previewFrames, seekbarPreviewTypeOf(stored));
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      hilog.warn(0x0000, TAG, 'seekbar preview: %{public}s', failure.message);
    }
  }

  /**
   * Player.maybeAutoQueueNextStream(info), run when a stream starts playing: when its item is the
   * LAST in the queue, repeat is off and auto_queue_key is on, PlayerHelper.autoQueueOf() appends
   * one related stream - the first related item when it is a stream not already queued, else a
   * random one of those. It used to run only when playback COMPLETED (FL-044), so the queue never
   * showed the next stream while this one played.
   *
   * autoplay_switch wrote the preference and NOTHING read it - device-checked: with the switch
   * on, the stream ran to 09:56 and the queue still held its single item. The switch was the only
   * half of the feature that existed.
   */
  private autoEnqueueRelated(info: StreamInfo): void {
    let enabled: boolean = false;
    try {
      enabled = AppPreferences.instance().getBooleanSync(auto_queue_key, false);
    } catch (err) {
      enabled = false;
    }
    if (!enabled || PlayerService.getInstance().getRepeatMode() !== RepeatMode.OFF) {
      return;
    }
    const live: PlayQueue | null = currentPlayQueue.getValue();
    // Something is already queued behind this item - the source only fills an EMPTY tail.
    if (live !== null && live.getIndex() < live.size() - 1) {
      return;
    }
    const queued: Set<string> = new Set<string>();
    if (live !== null) {
      live.getStreams().forEach((item: PlayQueueItem) => {
        queued.add(item.getUrl());
      });
    }
    const candidates: StreamInfoItem[] = [];
    for (const candidate of info.relatedItems) {
      if (candidate instanceof StreamInfoItem && !queued.has(candidate.getUrl())) {
        candidates.push(candidate as StreamInfoItem);
      }
    }
    if (candidates.length === 0) {
      return;
    }
    const pick: StreamInfoItem = candidates[0] === info.relatedItems[0]
      ? candidates[0] : candidates[Math.floor(Math.random() * candidates.length)];
    const next: PlayQueueItem = PlayQueueItem.fromStreamInfoItem(pick);
    // setAutoQueued(true): the source marks it so a later manual enqueue can replace it.
    next.setAutoQueued(true);
    enqueueOnCurrentPlayQueue([next]);
  }

  /** bottomSeekbarPreviewLayout: the frame under the finger while the seek bar is dragged. */
  private async updateSeekPreview(positionMs: number): Promise<void> {
    if (!SeekbarPreview.getInstance().isEnabled()) {
      this.seekPreviewFrame.frame = null;
      return;
    }
    try {
      this.seekPreviewFrame.frame = await SeekbarPreview.getInstance().previewAt(positionMs);
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      hilog.warn(0x0000, TAG, 'seekbar preview frame: %{public}s', failure.message);
    }
  }

  /**
   * onCaptionClicked(): the chosen subtitle track is loaded and rendered over the surface, and -
   * as captionPopupMenu's items do - the choice is remembered under caption_user_set_key, so the
   * next stream opens with the same language; "none" forgets it.
   */
  private async selectCaption(index: number, remember: boolean = true): Promise<void> {
    const info: StreamInfo | null = this.currentInfo;
    const loader: SubtitleLoader = SubtitleLoader.getInstance();
    if (info === null || index < 0 || index >= info.subtitles.length) {
      loader.clear();
      // NOT '': an empty label is a zero-wide control that can never be tapped again.
      this.captionLabel = Localization.getString('caption_none');
      this.subtitleText = '';
      if (remember) {
        VideoDetailFragmentPage.rememberCaptionLanguage(null);
      }
      return;
    }
    const subtitle: SubtitlesStream = info.subtitles[index];
    this.captionLabel = this.captionLabelOf(subtitle);
    if (remember) {
      VideoDetailFragmentPage.rememberCaptionLanguage(this.captionLabel);
    }
    try {
      await loader.load(subtitle);
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      hilog.warn(0x0000, TAG, 'subtitle load: %{public}s', failure.message);
    }
  }

  private static rememberCaptionLanguage(language: string | null): void {
    try {
      const prefs: AppPreferences = ServiceLocator.get().preferences;
      if (language === null) {
        prefs.remove(caption_user_set_key);
      } else {
        prefs.putString(caption_user_set_key, language);
      }
      prefs.flush().catch((): void => {
      });
    } catch (err) {
      hilog.warn(0x0000, TAG, 'caption language not saved: %{public}s',
        (err as BusinessError).message);
    }
  }

  /**
   * onTextTracksChanged(): the language the user last picked is selected again on a new stream -
   * the exact track first, then one of the same language stem (the authored track before the
   * auto-generated one, which is what ROLE_FLAG_CAPTION asks the selector for).
   */
  private applyPreferredCaption(info: StreamInfo): void {
    const wanted: string = VideoDetailFragmentPage.prefString(caption_user_set_key, '');
    if (wanted.length === 0 || info.subtitles.length === 0) {
      return;
    }
    const stemOf: (label: string) => string = (label: string): string => {
      const cut: number = label.indexOf(' (');
      return cut > 0 ? label.substring(0, cut) : label;
    };
    let match: number = -1;
    for (let i: number = 0; i < info.subtitles.length; i++) {
      if (this.captionLabelOf(info.subtitles[i]) === wanted) {
        match = i;
        break;
      }
    }
    if (match < 0) {
      for (let i: number = 0; i < info.subtitles.length; i++) {
        const candidate: SubtitlesStream = info.subtitles[i];
        if (stemOf(this.captionLabelOf(candidate)) === stemOf(wanted)
          && (match < 0 || (info.subtitles[match].isAutoGenerated() && !candidate.isAutoGenerated()))) {
          match = i;
        }
      }
    }
    if (match >= 0) {
      this.selectCaption(match, false);
    }
  }

  /** AudioTrackAdapter.AudioTracksWrapper: one group per audioTrackId. */
  private static groupAudioTracks(streams: AudioStream[]): AudioTrackGroup[] {
    return groupAudioTracks(streams);
  }

  /**
   * initTabs()/updateTabs(info): Comments exists only when the service supports them and the
   * preference is on; Related and Description likewise; when nothing is enabled the adapter gets
   * a single EmptyFragment page instead (conditionalVariant pageAdapter.getCount() == 0).
   */
  private updateTabs(serviceId: number): void {
    const built: DetailTab[] = [];
    const titles: string[] = [];
    // shouldShowComments(): the preference AND the service's own MediaCapabilities.
    if (VideoDetailFragmentPage.prefBool(show_comments_key, true)
      && this.serviceSupports(serviceId, MediaCapability.COMMENTS)) {
      built.push(DetailTab.COMMENTS);
      // updateTabsIconAndDescription(): the strip is icon-only, so the title IS the content
      // description - @string/comments_tab_description and its two siblings.
      titles.push(Localization.getString('comments_tab_description'));
    }
    // Related items are a pager tab only on the phone layout; large-land gets the side panel.
    if (VideoDetailFragmentPage.prefBool(show_next_video_key, true) && !this.relatedItemsLayout) {
      built.push(DetailTab.RELATED);
      titles.push(Localization.getString('related_items_tab_description'));
    }
    if (VideoDetailFragmentPage.prefBool(show_description_key, true)) {
      built.push(DetailTab.DESCRIPTION);
      titles.push(Localization.getString('description_tab_description'));
    }
    if (built.length === 0) {
      built.push(DetailTab.EMPTY);
      titles.push('EMPTY TAB');
    }
    this.tabPager = built;
    this.tabTitles = titles;
    // getSelectedTabTag(): the related tab is the one a freshly loaded stream opens on - the
    // screen is literally named for it - not whatever happens to sit at index 0.
    const related: number = built.indexOf(DetailTab.RELATED);
    this.selectedTab = related >= 0 ? related : 0;
  }

  /**
   * updateTabsIconAndDescription(): tab.setIcon(...) + setContentDescription(...). One Resource
   * per entry of tabPager, in the same order, so ScrollableTabLayout renders icon-only cells.
   */
  private tabIcons(): Resource[] {
    const icons: Resource[] = [];
    for (const tab of this.tabPager) {
      if (tab === DetailTab.COMMENTS) {
        icons.push($r('app.media.ic_comment'));
      } else if (tab === DetailTab.RELATED) {
        // R.drawable.ic_art_track - a picture beside lines, as the reference's middle tab shows.
        icons.push($r('app.media.ic_art_track'));
      } else if (tab === DetailTab.DESCRIPTION) {
        icons.push($r('app.media.ic_description'));
      } else {
        icons.push($r('app.media.ic_info_outline'));
      }
    }
    return icons;
  }

  /** service.getServiceInfo().getMediaCapabilities().contains(capability). */
  private serviceSupports(serviceId: number, capability: MediaCapability): boolean {
    for (const service of allServices()) {
      if (service.getServiceId() === serviceId) {
        const supported: StreamingService = service;
        return supported.getServiceInfo().getMediaCapabilities().has(capability);
      }
    }
    return false;
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Playback
  ////////////////////////////////////////////////////////////////////////// */

  /**
   * openVideoPlayerAutoFullscreen() - the thumbnail tap. autoPlayEnabled = true, then the main
   * player starts on the resolved source. registerStreamViewed(): the source records the view in
   * the watch history the moment playback starts, which is the ONLY write path a plain
   * launch + play reaches.
   */
  private async openVideoPlayer(audioOnly: boolean, targetHeight: number = -1): Promise<void> {
    const info: StreamInfo | null = this.currentInfo;
    if (info === null) {
      await this.startLoading();
      const loaded: StreamInfo | null = this.currentInfo;
      if (loaded === null) {
        return;
      }
      if (await this.handedToExternalPlayer(loaded, audioOnly)) {
        return;
      }
      await this.play(loaded, audioOnly, targetHeight);
      return;
    }
    if (await this.handedToExternalPlayer(info, audioOnly)) {
      return;
    }
    await this.play(info, audioOnly, targetHeight);
  }

  /**
   * use_external_video_player / use_external_audio_player, honoured HERE and not only on a link
   * opened from outside the app.
   *
   * T-0212: openVideoPlayer() in the source reads use_external_video_player_key and raises
   * showExternalVideoPlaybackDialog() instead of the main player (VideoDetailFragment:1130). The
   * port read the preference in RouterActivityPage alone, so a viewer who turned it on and pressed
   * Play inside the app saw the built-in player and nothing else - the setting did nothing a user
   * could reach.
   *
   * Deviation from the source, deliberate and the same one the router already makes: the source
   * first shows a resolution chooser (select_quality_external_players) with an "open in browser"
   * button. This hands over the stream the resolver would pick itself - tallest progressive URL
   * for video, loudest for audio - rather than asking. One behaviour for both entry points beats
   * two, and the chooser is a UI the port does not have.
   *
   * Returns true when the play was handed over - including when no player took it, which raises
   * the source's own no_player_found dialog rather than silently starting the built-in player.
   */
  private async handedToExternalPlayer(info: StreamInfo, audioOnly: boolean): Promise<boolean> {
    const prefs: AppPreferences = ServiceLocator.get().preferences;
    const wanted: boolean = audioOnly
      ? prefs.getBooleanSync(use_external_audio_player_key, false)
      : prefs.getBooleanSync(use_external_video_player_key, false);
    if (!wanted) {
      return false;
    }
    if (audioOnly) {
      this.showExternalAudioPlaybackDialog(info);
      return true;
    }

    const choices: ExternalStreamChoice[] =
      externalVideoChoices(info.videoStreams.concat(info.videoOnlyStreams));
    if (choices.length === 0) {
      promptAction.showToast({
        message: $r('app.string.no_video_streams_available_for_external_players'), duration: 2000
      });
      return true;
    }
    // select_quality_external_players: the viewer picks the rung, as the source asks them to.
    //
    // The controller is a FIELD, not a local. A local one went out of scope the moment this
    // method returned, so its close() had nothing to close: the quality dialog stayed under the
    // Open with dialog and was still there when the viewer came back from the player.
    this.closeHandOffDialogs();
    this.qualityDialog = new CustomDialogController({
      maskColor: DIALOG_MASK_COLOR,
      builder: ExternalQualityDialog({
        labels: choices.map((c: ExternalStreamChoice): string => c.label),
        picked: this.defaultExternalChoice(choices),
        onPick: (index: number): void => {
          this.qualityDialog?.close();
          this.askWhichPlayer(info, choices[index]);
        },
        onBrowser: (): void => {
          this.qualityDialog?.close();
          ServiceLocator.get().share.openUrlInBrowser(info.getUrl());
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    });
    this.qualityDialog.open();
    return true;
  }

  /**
   * showExternalAudioPlaybackDialog(): one row per audio TRACK (getFilteredAudioStreams), the
   * default track preselected; a single track is handed over without asking.
   */
  private showExternalAudioPlaybackDialog(info: StreamInfo): void {
    const handable: AudioStream[] = info.audioStreams.filter((a: AudioStream): boolean =>
      pickExternalAudio([a]) !== null);
    const tracks: AudioStream[] = getFilteredAudioStreams(handable,
      PlayerPrefs.defaultAudioFormat(), PlayerPrefs.isLimitingDataUsage())
      .sort((a: AudioStream, b: AudioStream): number =>
        audioTrackName(a).localeCompare(audioTrackName(b)));
    if (tracks.length === 0) {
      promptAction.showToast({
        message: $r('app.string.no_audio_streams_available_for_external_players'), duration: 2000
      });
      return;
    }
    const choiceOf = (stream: AudioStream): ExternalStreamChoice =>
      new ExternalStreamChoice(stream.content, stream.getFormat(), audioTrackName(stream));
    if (tracks.length === 1) {
      this.handOver(info, choiceOf(tracks[0]), true);
      return;
    }
    // getDefaultAudioFormat(activity, audioTracks): the preferred track (original audio first,
    // as the player's own track choice ranks them), then the format.
    let picked: number = 0;
    for (let i: number = 0; i < tracks.length; i++) {
      if (tracks[i].getAudioTrackType() === AudioTrackType.ORIGINAL) {
        picked = i;
        break;
      }
    }
    this.closeHandOffDialogs();
    this.qualityDialog = new CustomDialogController({
      maskColor: DIALOG_MASK_COLOR,
      builder: ExternalQualityDialog({
        title: $r('app.string.select_audio_track_external_players'),
        labels: tracks.map((t: AudioStream): string => audioTrackName(t)),
        picked: picked,
        onPick: (index: number): void => {
          this.qualityDialog?.close();
          this.handOver(info, choiceOf(tracks[index]), true);
        },
        onBrowser: (): void => {
          this.qualityDialog?.close();
          ServiceLocator.get().share.openUrlInBrowser(info.getUrl());
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    });
    this.qualityDialog.open();
  }

  /** default_resolution if this stream serves it, else the top rung - getDefaultResolutionIndex. */
  private defaultExternalChoice(choices: ExternalStreamChoice[]): number {
    const wanted: string = PlayerPrefs.computeDefaultResolution();
    for (let i: number = 0; i < choices.length; i++) {
      if (choices[i].label === wanted) {
        return i;
      }
    }
    return 0;
  }

  /**
   * Which player, after which resolution.
   *
   * Android raises the system chooser at this point and the port cannot: the call that lists the
   * abilities matching a want is a system API, and `ohos.want.action.select` does not exist here
   * (`10104001`). So the rows are a named list - see EXTERNAL_PLAYERS - with a System player row
   * that leaves the choice to the system, which is what this step did before it asked.
   */
  private askWhichPlayer(info: StreamInfo, stream: ExternalStreamChoice): void {
    this.playerDialog = new CustomDialogController({
      maskColor: DIALOG_MASK_COLOR,
      builder: ExternalPlayerDialog({
        labels: EXTERNAL_PLAYERS.map((t: ExternalPlayerTarget): string => t.label),
        onPick: (index: number): void => {
          this.playerDialog?.close();
          this.handOver(info, stream, false, EXTERNAL_PLAYERS[index]);
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    });
    this.playerDialog.open();
  }

  /**
   * Both hand-off dialogs, shut.
   *
   * Called before a new hand-off starts and when the page goes away: handing the stream to
   * another app leaves this page in the background, and a dialog still standing when the viewer
   * comes back is a dialog about a choice they already made.
   */
  private closeHandOffDialogs(): void {
    this.qualityDialog?.close();
    this.playerDialog?.close();
    this.qualityDialog = undefined;
    this.playerDialog = undefined;
  }

  /** startOnExternalPlayer: the stream with its MIME type, and the source's dialog when nothing
   * takes it. */
  private async handOver(info: StreamInfo, stream: ExternalStreamChoice,
    audioOnly: boolean, target: ExternalPlayerTarget | null = null): Promise<void> {
    const ok: boolean = await ServiceLocator.get().share.playInExternalPlayer(
      stream.url, mimeForStream(stream.format, audioOnly), info.getName(), target);
    if (!ok) {
      promptAction.showToast({ message: $r('app.string.no_player_found'), duration: 2000 });
    }
  }

  /**
   * True once the viewer has picked an audio track for the CURRENT stream. Background, popup and
   * every other re-prepare carry that choice; a stream nobody has chosen for carries none, so the
   * resolver applies prefer_original_audio instead (T-0210).
   */
  private audioTrackPicked: boolean = false;
  /*
   * T-0211: the language the viewer last picked is kept by PlayerService, not here - opening
   * another video builds a NEW page, so a field on this one dies at the stream boundary, which is
   * the symptom itself. Measured on the reference: picking "German dubbed" and opening a different
   * video leaves its control reading "German d...". The id's suffix is a per-stream index, so the
   * LANGUAGE is what can be carried; a stream that does not offer it lets the choice lapse and
   * prefer_original_audio decides, exactly as for someone who has picked nothing.
   */

  /** A second tap on Background or Popup before the first has finished is one action, not two. */
  private playbackStarting: boolean = false;
  /** The external hand-off's two dialogs, owned here so closing them actually closes them. */
  private qualityDialog?: CustomDialogController;
  private playerDialog?: CustomDialogController;

  private async play(info: StreamInfo, audioOnly: boolean,
    targetHeight: number = -1): Promise<void> {
    if (this.playbackStarting) {
      return;
    }
    this.playbackStarting = true;
    try {
      await this.playInner(info, audioOnly, targetHeight);
    } finally {
      this.playbackStarting = false;
    }
  }

  private async playInner(info: StreamInfo, audioOnly: boolean,
    targetHeight: number = -1): Promise<void> {
    // The reference attaches the player with its controls hidden: the first frames are the bare
    // surface with only the loading panel on it, and a tap brings the controls up.
    if (!this.playerAttached) {
      this.controlsVisible = false;
    }
    this.playerAttached = true;
    // T-0196: start at the Default resolution row, not at whatever the resolver thinks is best.
    // Audio-only has no height to honour.
    // T-0207: a caller may name its own ceiling - the Popup button opens at `Default popup
    // resolution`, which is a separate preference and was reaching nothing on this page.
    const wanted: number = targetHeight >= 0 ? targetHeight : this.startAtHeight;
    // T-0210: Background prepared with no track id, so bestAudio(set, '') re-ran the preference
    // and a chosen dub became the original - measured, "Hindi dubbed" turned into "English (US)
    // original" the moment the viewer backgrounded it. A pick made for this stream rides along;
    // a fresh open still passes nothing, so prefer_original_audio keeps deciding there.
    const track: string =
      this.audioTrackPicked ? this.audioTrackIdAt(this.selectedAudioTrack) : '';
    // This stream starts now, so its queue becomes the player's.
    this.promotePendingQueue();
    const report: PlaybackReport = await PlayerService.getInstance().prepare(info, audioOnly,
      audioOnly ? 0 : wanted, track, false, this.startPositionFor(info));
    if (report.source !== null) {
      this.autoEnqueueRelated(info);
    }
    // T-0196/T-0198: the chip must say what is PLAYING, not what was asked for. The resolver
    // clamps a request it cannot serve - above SYNTH_CEILING, or a height with no H.264 track -
    // and reports the rendition it actually chose. Measured: asking for 2160p serves 1080p,
    // because YouTube publishes nothing above 1080p in avc1
    // (docs/qa/evidence/fix-T-0198b/ladder.txt). A chip that kept saying 2160p would be the same
    // class of lie as the speed chip in T-0133.
    if (!audioOnly) {
      this.showServedQuality(report);
    }
    this.showAppliedAudioTrack(report);
    if (audioOnly) {
      // NavigationHelper.playOnBackgroundPlayer(): Toast @string/background_player_playing_toast.
      promptAction.showToast({
        message: $r('app.string.background_player_playing_toast'), duration: 2000
      });
    }
    // The view itself is recorded by the player, for every start of a new stream.
    // MediaSessionPlayerUi is initialised AFTER the player, so nothing about playback waits on
    // the session being created.
    await this.startMediaSession(info);
    // After the session: it hands the player this page's queue, and the popup's control row
    // (Previous/Next or the seek pair) is fixed when the window is created.
    this.armMinimizeToPopup(audioOnly);
  }

  /**
   * minimize_on_exit = popup. The PiP window has to exist before the app is left - HarmonyOS opens
   * it itself on the way out - so it is armed whenever the main player starts a video here, and
   * disarmed when this page stops owning the surface.
   */
  private armMinimizeToPopup(audioOnly: boolean): void {
    const player: PlayerService = PlayerService.getInstance();
    if (audioOnly || PlayerPrefs.minimizeOnExitAction() !== MinimizeMode.POPUP
      || player.isPipActive()) {
      player.disarmAutoPip();
      return;
    }
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    player.armAutoPip(context, this.surfaceController, new PipCoverNode());
    player.setPipRestoredListener(this.popupRestored);
  }

  /**
   * The popup's fullscreen button (PopupPlayerUi -> playOnMainPlayer): PiP's restore control is
   * its stand-in, and coming back from the window the main player starts in fullscreen.
   */
  private readonly popupRestored: () => void = (): void => {
    if (!this.isFullscreen) {
      this.toggleFullscreen();
    }
  };

  /**
   * MediaSessionPlayerUi: the AVSession carries the metadata, the transport commands (which is
   * how a hardware media key reaches the player at all) and the system media notification, and
   * it holds the continuous task that keeps audio alive once the app is backgrounded.
   */
  private async startMediaSession(info: StreamInfo): Promise<void> {
    const handler: MediaQueueHandler = new DetailQueueHandler(
      (): void => {
        this.playNext();
      },
      (): void => {
        this.playPrevious();
      },
      (): void => {
        this.closePlayer();
      },
      (): boolean => this.shuffled,
      (on: boolean): void => {
        this.setShuffledFromSession(on);
      });
    try {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const session: MediaSessionService = MediaSessionService.getInstance();
      await session.start(context, handler);
      await session.setMetadata(info);
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      hilog.warn(0x0000, TAG, 'media session: %{public}s', failure.message);
    }
  }

  /**
   * The close affordances: the player goes, and so do the session and its continuous task.
   * pause() left the stream loaded and the thumbnail showing - the X "closed" nothing. The
   * source's onClose() releases the player and leaves the screen, so this does both.
   */
  private closePlayer(): void {
    this.playerAttached = false;
    this.bottomSheetState = BottomSheetState.EXPANDED;
    this.saveProgress();
    PlayerService.getInstance().release();
    MediaSessionService.getInstance().stop();
    if (this.stack.length > 0) {
      const previous: ItemParams = this.stack[this.stack.length - 1];
      this.stack = this.stack.slice(0, this.stack.length - 1);
      this.loadItem(previous);
      return;
    }
    router.back();
  }

  /* //////////////////////////////////////////////////////////////////////////
  // The play queue (model/app/PlayQueue.ts)
  ////////////////////////////////////////////////////////////////////////// */

  /**
   * getPlayQueue(): the items panel showed a list this page SYNTHESISED from the stream it had
   * just loaded, so it could never hold more than one row whatever a producer handed over. It now
   * binds the app's one queue - the handle for when the queue is REPLACED, the queue's own
   * broadcast for when it changes.
   */
  private observeQueue(): void {
    this.disposables.add(currentPlayQueue.subscribeCallbacks((queue: PlayQueue | null): void => {
      this.bindQueue(queue);
    }, (error: Error): void => {
      hilog.warn(0x0000, TAG, 'play queue: %{public}s', error.message);
    }));
  }

  private bindQueue(queue: PlayQueue | null): void {
    const previous: Disposable | null = this.queueEvents;
    if (previous !== null) {
      previous.dispose();
    }
    this.queueEvents = null;
    this.livePlayQueue = queue;
    if (queue === null) {
      this.queueIndex = 0;
      this.playQueue = [];
      this.queueSource.setItems(this.playQueue);
      return;
    }
    const bus: Observable<PlayQueueEvent> | null = queue.getBroadcastReceiver();
    if (bus !== null) {
      this.queueEvents = bus.subscribeCallbacks((event: PlayQueueEvent): void => {
        this.readQueue();
      }, (error: Error): void => {
        hilog.warn(0x0000, TAG, 'play queue event: %{public}s', error.message);
      });
    }
    this.readQueue();
  }

  /** The one writer of playQueue / queueSource / queueIndex / shuffled. */
  private readQueue(): void {
    const queue: PlayQueue | null = this.livePlayQueue;
    if (queue === null) {
      return;
    }
    this.queueIndex = queue.getIndex();
    this.playQueue = queue.getStreams();
    this.shuffled = queue.isShuffled();
    this.queueSource.setItems(this.playQueue);
  }

  /** Where in the queue the given stream sits, by (serviceId, url) - PlayQueueItem.isSameItem. */
  private static indexOfStream(queue: PlayQueue, info: StreamInfo): number {
    const probe: PlayQueueItem = PlayQueueItem.fromStreamInfo(info);
    const streams: PlayQueueItem[] = queue.getStreams();
    for (let i: number = 0; i < streams.length; i++) {
      if (streams[i].isSameItem(probe)) {
        return i;
      }
    }
    return -1;
  }

  /**
   * handleResult(): `if (playQueue == null) { playQueue = new SinglePlayQueue(result); }` - an
   * INCOMING queue is kept, and that is now a real queue rather than a one-element array this
   * page built for itself. A stream the live queue already holds just moves its cursor; a stream
   * it does not hold is a new single-item queue, which is what opening an unrelated video does.
   */
  private syncQueueWithLoadedStream(info: StreamInfo): void {
    const live: PlayQueue | null = currentPlayQueue.getValue();
    if (live !== null) {
      const at: number = VideoDetailFragmentPage.indexOfStream(live, info);
      if (at >= 0) {
        if (live.getIndex() !== at) {
          live.setIndex(at);
        } else {
          this.readQueue();
        }
        return;
      }
    }
    // Replacing a real queue with a single item throws away everything the caller published, so
    // it is worth knowing WHY the lookup missed: the two urls are what isSameItem() compares.
    const fresh: PlayQueue = new SimplePlayQueue(0, [PlayQueueItem.fromStreamInfo(info)]);
    if (live !== null && this.playerBusyWithAnotherStream()) {
      // The player still plays from `live`; this page's queue waits until its stream starts.
      this.pendingQueue = fresh;
      return;
    }
    this.pendingQueue = null;
    setCurrentPlayQueue(fresh);
  }

  /**
   * Selecting another queue item plays it HERE: the current stream is pushed onto the
   * fragment's own stack first, so back returns to it instead of leaving the screen.
   *
   * It is also the ONE bounds-checked entry point, which is why the AVSession's next / previous
   * commands worked while the on-screen buttons - which assigned queueIndex and nothing else -
   * did not.
   */
  private selectQueueItem(index: number): void {
    if (index < 0 || index >= this.playQueue.length) {
      return;
    }
    const item: PlayQueueItem = this.playQueue[index];
    // setIndex() moves the QUEUE's cursor; queueIndex follows through the SelectEvent.
    const queue: PlayQueue | null = this.livePlayQueue;
    if (queue !== null) {
      queue.setIndex(index);
    } else {
      this.queueIndex = index;
    }
    if (item.getUrl() === this.url) {
      return;
    }
    this.stack = this.stack.concat([new ItemParams(this.serviceId, this.url, this.name)]);
    this.skipResumeOnce = true;
    // TC-PLAYER-556/557/558: loadItem() renders the new track; on its own it does NOT play it.
    // The page's only autoplay is in loadThenPopupIfRequested(), which runs when the PAGE opens
    // and is guarded by `!playerAttached` - so with a track already playing, picking another row
    // swapped the title, the metadata and the queue highlight while the old audio carried on.
    // Measured on the device before this fix: the transport still read 01:44/05:06, the previous
    // track's duration, and the player logged no state change at all.
    //
    // A queue selection is an explicit "play this", so it starts the stream itself once the load
    // has one. It does not consult the autoplay preference: that preference is about what a page
    // does when it opens, not about whether "play this track" means play it.
    this.loadItem(new ItemParams(item.getServiceId(), item.getUrl(), item.getTitle()))
      .then((): void => {
        if (this.currentInfo !== null) {
          this.openVideoPlayer(false);
        }
      });
  }

  /** setupFromHistoryItem(item): re-render the popped video in place. */
  private loadItem(item: ItemParams): Promise<void> {
    this.serviceId = item.serviceId;
    this.url = item.url;
    this.name = item.name;
    this.currentInfo = null;
    // playQueue is NOT cleared here any more: it is the live queue's rendering, and walking to
    // another item of that queue must not empty it - clearing it is what made every in-page
    // navigation fall back to a fresh one-item list.
    this.resetFastSeek();
    // Returned, not dropped: selectQueueItem() needs to know when the stream is ready so it can
    // start it. Every other caller ignores the promise exactly as before.
    return this.startLoading();
  }

  /**
   * Where a fresh start begins, in ms, or -1 for "the stream's own start". A tapped timestamp
   * wins; otherwise, with Resume playback on, the saved position of a stream that was not played
   * to its end (Player.handleIntent: `!state.isFinished(duration)`). A url that carries its own
   * timestamp keeps it, as a PlayQueueItem with a recovery position does in the source.
   */
  private startPositionFor(info: StreamInfo): number {
    const skipResume: boolean = this.skipResumeOnce;
    this.skipResumeOnce = false;
    if (this.pendingStartSeconds >= 0) {
      const seconds: number = this.pendingStartSeconds;
      this.pendingStartSeconds = -1;
      return seconds * 1000;
    }
    if (skipResume || !this.positionSubscriber || info.startPosition > 0) {
      return -1;
    }
    const state: StreamStateEntity | null = this.savedStreamState;
    if (state === null || state.isFinished(info.getDuration())) {
      return -1;
    }
    return state.progressMillis;
  }

  /**
   * saveStreamProgressState(): on the way out, so resume position survives - and, as in the
   * source, only while watch history is on.
   */
  private async saveProgress(): Promise<void> {
    const info: StreamInfo | null = this.currentInfo;
    const history: HistoryRecordManager | null = this.historyRecordManager;
    if (info === null || history === null
      || !VideoDetailFragmentPage.prefBool(enable_watch_history_key, true)) {
      return;
    }
    try {
      await history.saveStreamState(info, PlayerService.getInstance().currentPositionMs());
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      hilog.warn(0x0000, TAG, 'saveStreamState: %{public}s', failure.message);
    }
  }

  /**
   * openPopupPlayer(): SYSTEM_FLOAT_WINDOW is not grantable to a self-signed build, so the
   * Phase-2 contract substitutes PiP and falls back to the in-app minimized player. The button
   * therefore always does one of the two - it is never a no-op.
   */
  private async openPopupPlayer(): Promise<boolean> {
    // TC-PLAYER-610: `popupOpening` alone is TIME-bounded - it only refuses while the previous
    // call's promise is in flight. Once that resolves the flag clears, so tapping Popup again
    // called enterPip() on a session that was ALREADY up: a second popup, and eventually
    // `Player error 401: Invalid Parameter: SurfaceUtils cannot convert ID to Surface` - the same
    // 401 a redundant surface re-registration raises, seen on this board during the T-0102 work.
    //
    // The guard has to be STATE-bounded too: a popup that is already open is not opened again.
    if (this.popupOpening || PlayerService.getInstance().isPipActive()) {
      return false;
    }
    this.popupOpening = true;
    try {
      return await this.openPopupPlayerInner();
    } finally {
      this.popupOpening = false;
    }
  }

  /** `Default popup resolution`, as a height prepare() can be asked for. */
  private static popupTargetHeight(): number {
    return preferredHeightOf(PlayerPrefs.computeDefaultResolution(
      default_popup_resolution_key, default_popup_resolution_value));
  }

  private popupOpening: boolean = false;
  /** readArguments(): the page was opened by a popup's restore control (PopupPlayerSurface). */
  private fullscreenRequested: boolean = false;

  /**
   * openBackgroundPlayer(): the stream goes on as audio and the reference's sheet collapses, so
   * the screen the viewer came from is back with the mini player docked over it.
   */
  private async openBackgroundPlayer(): Promise<void> {
    await this.openVideoPlayer(true);
    if (this.playerAttached) {
      this.collapseToPreviousScreen();
    }
  }

  /**
   * BottomSheetBehavior.STATE_COLLAPSED. On Android the detail fragment is a sheet over the
   * screen it was opened from, so collapsing it HANDS THAT SCREEN BACK with the mini player
   * docked at its foot. Here the detail is a page of its own: collapsing it in place left the
   * viewer on a frameless detail page they could not get out from under. So the page steps back
   * instead - the player keeps going, the previous page's MiniPlayerBar picks it up, and a tap on
   * that bar reopens this page. Only a page with nothing under it (opened from a link) still
   * collapses in place.
   */
  private collapseToPreviousScreen(): void {
    if (Number(router.getLength()) > 1) {
      router.back();
      return;
    }
    this.bottomSheetState = BottomSheetState.COLLAPSED;
  }

  /** True when a real PiP window took over; false when the mini-player fallback was used. */
  private async openPopupPlayerInner(): Promise<boolean> {
    // NavigationHelper.playOnPopupPlayer(): Toast @string/popup_playing_toast, shown as the
    // mode is entered - before the PiP attempt, because the fallback is still popup mode.
    promptAction.showToast({ message: $r('app.string.popup_playing_toast'), duration: 2000 });
    // isPopupEnabledElseAsk(activity): without the popup permission the source never opens one.
    const permissions: PermissionHelper = ServiceLocator.get().permissions;
    if (!permissions.isPopupEnabled()) {
      hilog.info(0x0000, TAG, 'popup player: not permitted, docking the mini player');
      // Still popup mode, so still `Default popup resolution` - openPopupOnSurface() prepares at
      // the popup height before its own permission check, and this branch must match it (T-0207
      // review). Unreachable on a handset where PiPWindow.isPiPEnabled() is true.
      await this.openVideoPlayer(false, VideoDetailFragmentPage.popupTargetHeight());
      this.collapseToPreviousScreen();
      return false;
    }
    // T-0207: the popup has its own preference, and this page was not reading it - the list
    // screens got it in T-0197 through openPopupOnSurface(), the detail page's own button did not,
    // so `Default popup resolution` = 144p still prepared the Default resolution height.
    await this.openVideoPlayer(false, VideoDetailFragmentPage.popupTargetHeight());
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const outcome: PipOutcome = await PlayerService.getInstance()
      .enterPip(context, this.surfaceController, new PipCoverNode());
    if (outcome === PipOutcome.PIP) {
      PlayerService.getInstance().setPipRestoredListener(this.popupRestored);
      return true;
    }
    // The documented fallback: dock the in-app mini player, so the button is never a no-op.
    hilog.info(0x0000, TAG, 'popup player: PiP unavailable, docking the mini player');
    this.collapseToPreviousScreen();
    return false;
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Controls
  ////////////////////////////////////////////////////////////////////////// */

  private toggleTitleAndSecondaryControls(): void {
    this.secondaryControlsShown = !this.secondaryControlsShown;
  }

  /**
   * playbackSeekBar's secondaryProgress - the buffered range, white over the white_secondary
   * track. Slider has no second progress, but its track takes a LinearGradient (API 12), and two
   * hard stops at the buffered fraction ARE a second fill - on the track's own geometry, so it
   * lines up with the primary fill without a stacked Progress to align by hand.
   */
  private seekBarTrack(): LinearGradient {
    const total: number = this.durationMs > 0 ? this.durationMs : 1;
    const at: number = Math.min(1, Math.max(0, this.bufferedMs / total));
    // app.color.white / app.color.white_secondary as literals: the Slider doc drops the whole
    // gradient on a stop colour it cannot read, and its examples are all hex strings.
    const stops: ColorStop[] = [
      { color: '#FFFFFF', offset: 0 },
      { color: '#FFFFFF', offset: at },
      { color: '#C9CACB', offset: at },
      { color: '#C9CACB', offset: 1 }
    ];
    return new LinearGradient(stops);
  }

  /** openChannel(subChannelUrl, or uploaderUrl when the sub-channel url is empty). */
  private openChannel(useUploader: boolean): void {
    const info: StreamInfo | null = this.currentInfo;
    if (info === null) {
      return;
    }
    const useSubChannel: boolean = !useUploader && info.subChannelUrl.length > 0;
    const channelUrl: string = useSubChannel ? info.subChannelUrl : info.uploaderUrl;
    const channelName: string = useSubChannel ? info.subChannelName : info.uploaderName;
    if (channelUrl.length === 0) {
      return;
    }
    router.pushUrl({
      url: 'pages/ChannelFragmentPage',
      params: new ItemParams(info.getServiceId(), channelUrl, channelName)
    });
  }

  /** svc_share owns the implicit sendData Want plus the clipboard + toast fallback. */
  private share(): ShareUtils {
    return ServiceLocator.get().share;
  }

  /** ShareUtils.shareText(ctx, info.getName(), info.getUrl(), info.getThumbnails()). */
  private shareStream(): void {
    const info: StreamInfo | null = this.currentInfo;
    if (info === null) {
      return;
    }
    this.share().shareText(info.getName(), info.getUrl());
  }

  /**
   * Player.getVideoUrlAtCurrentTime(): a YouTube url gets `&t=<seconds>`; a live stream has no
   * meaningful position and keeps its bare url.
   */
  private videoUrlAtCurrentTime(info: StreamInfo): string {
    const seconds: number = Math.floor(PlayerService.getInstance().currentPositionMs() / 1000);
    if (StreamSetAdapter.isLive(info.getStreamType()) || seconds < 0
      || info.getServiceId() !== YOUTUBE_SERVICE_ID) {
      return info.getUrl();
    }
    return info.getUrl() + '&t=' + seconds;
  }

  /** KoreUtils.playWithKore(); see common/util/KoreUtils.ts for why only its install branch runs. */
  private playWithKodi(): void {
    if (this.currentInfo !== null) {
      playWithKore();
    }
  }

  private openInBrowser(): void {
    const info: StreamInfo | null = this.currentInfo;
    if (info === null) {
      return;
    }
    this.share().openUrlInBrowser(info.getUrl());
  }

  /**
   * ErrorPanelHelper's own handler: `ShareUtils.openUrlInBrowser(context, errorInfo.openInBrowserUrl)`.
   *
   * The panel's button was calling openInBrowser() above, which reads `currentInfo` and returns
   * when it is null - and on a failed load it is ALWAYS null, so the button did nothing at all.
   * The url is already on the ErrorInfo: startUp()'s catch builds it with
   * `ErrorInfo.fromThrowable(failure, REQUESTED_STREAM, this.url, this.serviceId, this.url)`,
   * whose last argument is openInBrowserUrl, matching VideoDetailFragment.java:885.
   */
  private openErrorUrlInBrowser(): void {
    const url: string | null =
      this.errorInfo === null ? null : this.errorInfo.openInBrowserUrl;
    if (url === null || url.length === 0) {
      return;
    }
    this.share().openUrlInBrowser(url);
  }

  /**
   * PlaylistDialog: the append branch exists only when a local playlist does.
   *
   * hasPlaylists() is a database round trip, so a second tap before the first one has opened
   * anything ran the whole thing again and opened (or toggled shut) a second dialog. One
   * in-flight flag, cleared in the finally, is the source's "the dialog is already showing".
   */
  private playlistDialogOpening: boolean = false;
  /**
   * The rows the playlist dialogs write: the loaded stream by default, the HELD queue row when a
   * queue row's menu opened them (QueueItemMenuUtil: List.of(new StreamEntity(item))).
   */
  private appendTargets: StreamEntity[] | null = null;

  private playlistRows(): StreamEntity[] {
    const targets: StreamEntity[] | null = this.appendTargets;
    if (targets !== null) {
      return targets;
    }
    const info: StreamInfo | null = this.currentInfo;
    return info === null ? [] : [StreamEntity.fromStreamInfo(info)];
  }

  private async openPlaylistDialog(targets: StreamEntity[] | null = null): Promise<void> {
    if (this.playlistDialogOpening) {
      return;
    }
    this.appendTargets = targets;
    this.playlistDialogOpening = true;
    try {
      await this.openPlaylistDialogInner();
    } finally {
      this.playlistDialogOpening = false;
    }
  }

  private async openPlaylistDialogInner(): Promise<void> {
    await this.ensureServices();
    const manager: LocalPlaylistManager | null = this.playlistManager;
    if (manager === null) {
      return;
    }
    try {
      this.hasPlaylists = await manager.hasPlaylists();
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      hilog.warn(0x0000, TAG, 'hasPlaylists: %{public}s', failure.message);
      this.hasPlaylists = false;
    }
    // PlaylistDialog.createCorrespondingDialog() is a FACTORY in the source, not a
    // dialog of its own: with playlists it shows the append dialog, without any it
    // goes straight to creation. The port made it a visible intermediate dialog
    // carrying one unstyled Text, which rendered as a chromeless pill and meant the
    // append dialog behind it never opened at all.
    if (this.hasPlaylists) {
      this.openAppendDialog();
    } else {
      this.creationDialog.open();
    }
  }

  private async openAppendDialog(): Promise<void> {
    const manager: LocalPlaylistManager | null = this.playlistManager;
    if (manager === null) {
      return;
    }
    try {
      // getPlaylistDuplicates(streams[0].url): the rows say which playlists already hold it.
      const rows: StreamEntity[] = this.playlistRows();
      this.appendPlaylists = rows.length === 0
        ? await manager.getPlaylists() : await manager.getPlaylistDuplicates(rows[0].url);
      this.appendDialog.open();
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      hilog.warn(0x0000, TAG, 'getPlaylists: %{public}s', failure.message);
    }
  }

  private async appendToPlaylist(playlist: PlaylistMetadataEntry): Promise<void> {
    const manager: LocalPlaylistManager | null = this.playlistManager;
    const rows: StreamEntity[] = this.playlistRows();
    if (manager === null || rows.length === 0) {
      return;
    }
    try {
      await manager.appendToPlaylist(playlist.uid, rows);
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

  private async createPlaylistWithTarget(playlistName: string): Promise<void> {
    const manager: LocalPlaylistManager | null = this.playlistManager;
    const rows: StreamEntity[] = this.playlistRows();
    if (manager === null || rows.length === 0 || playlistName.length === 0) {
      return;
    }
    try {
      await manager.createPlaylist(playlistName, rows);
      // PlaylistCreationDialog: Toast @string/playlist_creation_success.
      promptAction.showToast({ message: $r('app.string.playlist_creation_success'),
        duration: 2000 });
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      hilog.warn(0x0000, TAG, 'createPlaylist: %{public}s', failure.message);
    }
  }

  /**
   * toggleFullscreen(): the player fills the page AND the window turns, which is what the
   * bottom-right control does in the source. A grep over entry/src/main/ets finds no other
   * orientation call in the app - this is the one, and it must stay the only one.
   */
  private toggleFullscreen(): void {
    this.isFullscreen = !this.isFullscreen;
    this.applyOrientation(this.isFullscreen);
    this.setupBrightness();
  }

  private async applyOrientation(fullscreen: boolean): Promise<void> {
    // onScreenRotationButtonClicked(): on a tablet fullscreen is a LAYOUT change only - the screen
    // is not turned (DeviceUtils.isTablet, which the Tablet mode setting can force either way).
    if (PlayerPrefs.isTablet()) {
      return;
    }
    try {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const win: window.Window = await window.getLastWindow(context);
      await win.setPreferredOrientation(fullscreen
        ? window.Orientation.LANDSCAPE : window.Orientation.PORTRAIT);
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      hilog.warn(0x0000, TAG, 'setPreferredOrientation: %{public}s', failure.message);
    }
  }

  /**
   * BottomSheetBehavior: the sheet collapses into the mini player when the page is scrolled
   * past the player frame, exactly as the downward drag on the surface collapses it. Only ever
   * collapses - restoring is the overlay's own tap, so removing the frame cannot re-trigger it.
   */
  private onDetailScrolled(): void {
    if (!this.playerAttached || this.bottomSheetState !== BottomSheetState.EXPANDED) {
      return;
    }
    if (this.detailScroller.currentOffset().yOffset > PLAYER_FRAME_VP) {
      this.bottomSheetState = BottomSheetState.COLLAPSED;
    }
  }

  /** overlay_layout's three tap targets: the sheet comes back, at the top of the page. */
  private expandSheet(): void {
    this.bottomSheetState = BottomSheetState.EXPANDED;
    this.detailScroller.scrollEdge(Edge.Top);
  }

  /**
   * onResizeClicked(): setResizeMode(nextResizeModeAndSaveToPrefs(...)) - fit / fill / zoom, saved
   * so the next session opens on the same one. The label used to cycle while the picture stayed
   * stretched in all three; the PLAYER scales the picture now (see PlayerService.setResizeMode).
   */
  private cycleResizeMode(): void {
    const player: PlayerService = PlayerService.getInstance();
    const next: number = PlayerPrefs.nextResizeModeAndSave(player.getResizeMode());
    player.setResizeMode(next);
    this.resizeMode = VideoDetailFragmentPage.surfaceModeOf(next);
  }

  private static surfaceModeOf(mode: number): SurfaceResizeMode {
    if (mode === RESIZE_MODE_FILL) {
      return SurfaceResizeMode.FILL;
    }
    return mode === RESIZE_MODE_ZOOM ? SurfaceResizeMode.ZOOM : SurfaceResizeMode.FIT;
  }

  /** onQueueClicked(): the items-list panel in queue mode. */
  private showQueue(): void {
    this.isQueueVisible = true;
    this.areSegmentsVisible = false;
  }

  /** onSegmentsClicked(): the same panel, chapters mode - header title on, shuffle/repeat off. */
  private showSegments(): void {
    this.areSegmentsVisible = true;
    this.isQueueVisible = false;
  }

  /** closeItemsList(), bound in both buildQueue() and buildSegments(). */
  private closeItemsList(): void {
    this.isQueueVisible = false;
    this.areSegmentsVisible = false;
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Bound values
  ////////////////////////////////////////////////////////////////////////// */

  /**
   * handleResult(info): the ONE place every bound view on this page is filled from the loaded
   * StreamInfo, so no displayed value can drift from the info the screen is showing.
   */
  private applyInfo(info: StreamInfo): void {
    this.title = info.getName();
    this.streamType = info.getStreamType();
    this.ageLimit = info.getAgeLimit();
    this.subChannelName = info.getSubChannelName();
    this.uploaderSubChannelName = info.getSubChannelName().length > 0
      ? info.getSubChannelName() : info.getUploaderName();
    // Localization.shortSubscriberCount(): "16M subscribers", not 15800000. Interpolating the
    // number prints the raw count, which is what the uploader row was showing.
    const subscribers: string = info.getUploaderSubscriberCount() < 0
      ? '' : Localization.shortSubscriberCount(info.getUploaderSubscriberCount());
    if (info.getSubChannelName().length === 0) {
      // displayUploaderAsSubChannel(): the uploader row keeps only the subscriber count.
      this.subscriberCount = subscribers;
    } else {
      this.subscriberCount = subscribers.length === 0
        ? info.getUploaderName() : info.getUploaderName() + ' - ' + subscribers;
    }
    // VideoDetailFragment.java:1543-1557 words the count per stream type - an audio live stream
    // is LISTENING, a video live stream is WATCHING, anything else is VIEWS - and hides the row
    // entirely below zero. The plurals and the zero cases live in Localization, as in the source.
    if (info.getViewCount() < 0) {
      this.viewCount = '';
    } else if (info.getStreamType() === StreamType.AUDIO_LIVE_STREAM) {
      this.viewCount = Localization.listeningCount(info.getViewCount());
    } else if (info.getStreamType() === StreamType.LIVE_STREAM) {
      this.viewCount = Localization.localizeWatchingCount(info.getViewCount());
    } else {
      this.viewCount = Localization.localizeViewCount(info.getViewCount());
    }
    // Both counts -1 is the source's "ratings disabled": no counts, both icons, the hint.
    this.likeDislikeCounts = info.getLikeCount() === -1 && info.getDislikeCount() === -1
      ? []
      // Localization.shortCount() - the compact form, "2.1M" rather than 2134233.
      : [info.getLikeCount() < 0 ? '' : Localization.shortCount(info.getLikeCount()),
        info.getDislikeCount() < 0 ? '' : Localization.shortCount(info.getDislikeCount())];
    // Localization.getDurationString(): "1:01:14", not 3674. getDuration() is SECONDS, and the
    // badge was printing them unformatted.
    this.durationBadge = info.getDuration() < 0
      ? '' : Localization.getDurationString(info.getDuration());
    this.durationTotalMs = info.getDuration() > 0 ? info.getDuration() * 1000 : 0;
    const hero: string | null = choosePreferredImage(info.getThumbnails());
    this.heroLoaded = false;
    this.heroThumbnail = hero === null ? '' : hero;
    const subAvatar: string | null = choosePreferredImage(info.getSubChannelAvatars().length > 0
      ? info.getSubChannelAvatars() : info.getUploaderAvatars());
    const uploaderAvatar: string | null = choosePreferredImage(info.getUploaderAvatars());
    this.channelAvatars = [subAvatar === null ? '' : subAvatar,
      uploaderAvatar === null ? '' : uploaderAvatar];
    // ExtractorHelper.showMetaInfoInTextView(): GONE while show_meta_info is off.
    const metaInfo: MetaInfoText = buildMetaInfoText(
      VideoDetailFragmentPage.prefBool(show_meta_info_key, true) ? info.metaInfo : []);
    this.metaInfoSpans = metaInfo.spans;
    this.metaInfoBanner = metaInfo.text;
    this.noVideoStreams =
      info.getVideoStreams().length === 0 && info.getVideoOnlyStreams().length === 0;
    // The four overlay labels. Seeded HERE, from the stream, so each control has a measured
    // box - and therefore a hit area - before the user has picked anything out of its menu.
    this.qualityOptions = VideoDetailFragmentPage.qualityOptions(info,
      VideoDetailFragmentPage.prefBool(show_higher_resolutions_key, false));
    // The row the user's Default resolution names, not simply the tallest (T-0196). Playback
    // starts at the same one, so the chip and the stream cannot disagree.
    // computeDefaultResolution(): the stored row, lowered to the mobile-data limit on a metered
    // network (limit_mobile_data_usage).
    const chosen: number = VideoDetailFragmentPage.defaultQualityIndex(this.qualityOptions,
      PlayerPrefs.computeDefaultResolution());
    this.startAtHeight = chosen >= 0 ? this.qualityOptions[chosen].height : 0;
    this.qualityLabel = chosen >= 0
      ? this.qualityOptions[chosen].indicator() : Localization.getString('unknown_quality');
    // setupSubtitleView(): captions start OFF, and the label is the source's "no captions" row -
    // unless the user picked a language before, which a new stream offers again.
    this.captionLabel = Localization.getString('caption_none');
    SubtitleLoader.getInstance().clear();
    this.subtitleText = '';
    this.applyPreferredCaption(info);
    this.selectedAudioTrack = this.defaultAudioTrackIndex();
    this.audioTrackLabel = this.audioTrackLabelAt(this.selectedAudioTrack);
    // T-0211: a new stream does not inherit the previous stream's track INDEX - the lists differ -
    // but it does inherit the viewer's language, when it offers one. Without a match the choice
    // lapses and prefer_original_audio decides, as it does for someone who has picked nothing.
    const carried: number =
      this.trackIndexForLanguage(PlayerService.getInstance().pickedAudioLanguage());
    this.audioTrackPicked = carried >= 0;
    if (carried >= 0) {
      this.selectedAudioTrack = carried;
      this.audioTrackLabel = this.audioTrackLabelAt(carried);
    }
    this.playbackSpeedLabel = formatSpeed(PlayerService.getInstance().displayRate());
    this.miniPlayerOverlay =
      new OverlayMetadata(info.getName(), this.uploaderSubChannelName, this.heroThumbnail);
    // playQueue == null after load -> SinglePlayQueue(result); an incoming queue is kept.
    this.syncQueueWithLoadedStream(info);
  }

  /** detail_sub_channel_thumbnail_view (0) and detail_uploader_thumbnail_view (1). */
  private channelAvatar(index: number): string {
    return index < this.channelAvatars.length ? this.channelAvatars[index] : '';
  }

  private likeText(): string {
    return this.likeDislikeCounts.length > 0 ? this.likeDislikeCounts[0] : '';
  }

  private dislikeText(): string {
    return this.likeDislikeCounts.length > 1 ? this.likeDislikeCounts[1] : '';
  }

  /** Both counts -1: the two texts go, the two icons stay, "disabled" appears. */
  private ratingsDisabled(): boolean {
    return this.currentInfo !== null && this.likeDislikeCounts.length === 0;
  }

  private hasAudioOrVideo(): boolean {
    const info: StreamInfo | null = this.currentInfo;
    return info !== null && (info.audioStreams.length > 0 || info.videoStreams.length > 0);
  }

  /* RelatedItemsFragment.getInstance(currentInfo) -> setInitialData(info): the three constructor
     arguments the related-items tab is built with. Without them it has no StreamInfo and shows
     its error panel forever. */
  private relatedServiceId(): number {
    const info: StreamInfo | null = this.currentInfo;
    return info === null ? -1 : info.getServiceId();
  }

  private relatedUrl(): string {
    const info: StreamInfo | null = this.currentInfo;
    return info === null ? '' : info.getUrl();
  }

  private relatedItems(): InfoItem[] {
    const info: StreamInfo | null = this.currentInfo;
    return info === null ? [] : info.getRelatedItems();
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Builders - pager
  ////////////////////////////////////////////////////////////////////////// */

  /** The pager pages TabAdapter renders: the four fragments updateTabs(info) installs. */
  @Builder
  pagerPages() {
    ForEach(this.tabPager, (tab: DetailTab, index: number) => {
      if (tab === DetailTab.COMMENTS) {
        CommentsFragmentPage()
      } else if (tab === DetailTab.RELATED) {
        RelatedItemsFragmentPage({
          hostServiceId: this.relatedServiceId(),
          hostUrl: this.relatedUrl(),
          hostRelatedItems: this.relatedItems()
        })
      } else if (tab === DetailTab.DESCRIPTION) {
        // updateItem(DESCRIPTION_TAB_TAG, new DescriptionFragment(info)): the tab renders the
        // StreamInfo the host already loaded and never fetches one itself.
        DescriptionFragmentPage({
          streamInfo: this.currentInfo,
          hostServiceId: this.relatedServiceId(),
          hostUrl: this.relatedUrl()
        })
      } else {
        EmptyFragmentPage({ messageVisibility: true })
      }
    }, (tab: DetailTab, index: number) => `${index}-${tab}`)
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Builders - items-list panel rows
  ////////////////////////////////////////////////////////////////////////// */

  /**
   * One queue row. The drag / swipe wrapper is PlayQueueItemTouchCallback (the source's
   * ItemTouchHelper callback), the row body is PlayQueueItemHolder. The builder is passed to the
   * adapter through an ARROW - a bare `this.queueRow` would re-bind `this` to the child.
   */
  @Builder
  queueRow(item: PlayQueueItem, index: number) {
    PlayQueueItemTouchCallback({
      index: index,
      onMove: (fromIndex: number, toIndex: number): void => {
        // TouchCallback.onMove -> playQueue.move(). Moving the rendered copy left the queue in
        // its old order, so a reorder survived only until the next refresh.
        this.moveQueueItem(fromIndex, toIndex);
      },
      onSwiped: (removeIndex: number): void => {
        this.removeQueueItem(removeIndex);
      }
    }) {
      PlayQueueItemHolder({
        item: item,
        // This mount IS the dark panel (@color/queue_background_color), which is the holder's
        // default ground, so only the highlight has to be passed.
        selected: index === this.queueIndex,
        onSelected: (): void => {
          this.selectQueueItem(index);
        },
        onHeld: (): void => {
          // PlayQueueItemBuilder.held(item) -> QueueItemMenuUtil.openPopupMenu(). It opened the
          // add-to-playlist dialog instead, so Remove, Details, Show channel details, Share and
          // Download had no way in on this surface at all - only "Drag here" showed.
          this.openRowMenu(index);
        }
      })
    }
  }

  /**
   * The next item after the one that just finished, or nothing when the queue ends there. NOT
   * playNext(): that is the transport button, and PlayQueue.setIndex()'s wrap would send the last
   * stream back to the first for ever. A finished queue simply stops, as it does in the source.
   */
  private advanceAfterCompletion(): void {
    const queue: PlayQueue | null = this.livePlayQueue;
    const length: number = queue === null ? this.playQueue.length : queue.getStreams().length;
    const next: number = (queue === null ? this.queueIndex : queue.getIndex()) + 1;
    if (next < length) {
      this.handingOverToNextItem = true;
      this.selectQueueItem(next);
    }
  }

  /** Set for exactly one load: the one that follows a finished stream. */
  private handingOverToNextItem: boolean = false;

  /**
   * The repeat half of onPlaybackEnded(). Returns true when the mode decided what happens next,
   * so the caller leaves the stream alone.
   */
  private handleRepeatOnCompletion(): boolean {
    const mode: RepeatMode = PlayerService.getInstance().getRepeatMode();
    if (mode === RepeatMode.ONE) {
      // The same stream from the top. seekTo(0) alone leaves a completed AVPlayer completed, so
      // playback is asked for explicitly.
      PlayerService.getInstance().seekTo(0);
      PlayerService.getInstance().play().catch((err: Error): void => {
        hilog.warn(0x0000, TAG, 'repeat one: %{public}s', err.message);
      });
      return true;
    }
    if (mode === RepeatMode.ALL) {
      const queue: PlayQueue | null = this.livePlayQueue;
      if (queue === null || queue.isEmpty()) {
        return false;
      }
      const next: number = queue.getIndex() + 1;
      // The wrap is the whole point of ALL: the last item hands back to the first.
      this.selectQueueItem(next >= queue.getStreams().length ? 0 : next);
      return true;
    }
    return false;
  }

  /**
   * The index PlayQueue.setIndex() would settle on for this offset, without moving the cursor
   * first. Its rules, verbatim: below zero clamps to the head, past the end wraps modulo when the
   * queue is complete and clamps to the last item when it is not. selectQueueItem() rejects an
   * out-of-range index - correct for a row tap, wrong for the transport buttons, which is why the
   * last item's Next did nothing where the reference wrapped to the first.
   */
  private queueTargetIndex(offset: number): number {
    const queue: PlayQueue | null = this.livePlayQueue;
    const length: number = queue === null ? this.playQueue.length : queue.getStreams().length;
    if (length === 0) {
      return -1;
    }
    const raw: number = this.queueIndex + offset;
    if (raw < 0) {
      return 0;
    }
    if (raw < length) {
      return raw;
    }
    return queue !== null && queue.isComplete() ? raw % length : length - 1;
  }

  /**
   * player.playPrevious(): past the activation limit the button restarts this stream; inside it,
   * it steps back. The port stepped back unconditionally, so a stream could never be restarted
   * from the control and the first item's Previous did nothing at all.
   */
  private playPrevious(): void {
    // "Also restart the track if the current track is the first in a queue."
    if (this.positionMs > PLAY_PREV_ACTIVATION_LIMIT_MILLIS || this.queueIndex === 0) {
      PlayerService.getInstance().seekTo(0);
      return;
    }
    const target: number = this.queueTargetIndex(-1);
    if (target >= 0) {
      this.selectQueueItem(target);
    }
  }

  /** player.playNext(): the queue's own wrap, not a bare increment. */
  private playNext(): void {
    const target: number = this.queueTargetIndex(1);
    if (target >= 0) {
      this.selectQueueItem(target);
    }
  }

  /**
   * "position/duration" for the queue panel's header. Both halves read `-:--:--` until the player
   * has reported a position at all - activity_player_queue_control.xml's own declared value - and
   * are formatted from then on, so a stream with no duration reads 00:00 rather than staying on
   * the placeholder. That is what the reference does: its live stream's header is "3:59:59/00:00".
   */
  private queueHeaderTime(): string {
    if (!this.queueTimeReported) {
      return NO_QUEUE_TIME + '/' + NO_QUEUE_TIME;
    }
    const at: string = Localization.getDurationString(Math.floor(this.positionMs / 1000));
    const total: string = Localization.getDurationString(Math.floor(this.durationMs / 1000));
    return at + '/' + total;
  }

  /** False until the player's first position report; see queueHeaderTime(). */
  @State queueTimeReported: boolean = false;
  /** touch_append_detail's alpha: faded in on a touch of Background or Popup, then out again. */
  @State holdToAppendTipAlpha: number = 0;

  /**
   * The controls' touch listener: ACTION_DOWN on Background or Popup fades the "Hold to enqueue"
   * tip in over the thumbnail (250 ms) and back out (1500 ms, after 1000 ms) - when
   * show_hold_to_append is on.
   */
  private flashHoldToAppendTip(event: TouchEvent): void {
    if (event.type !== TouchType.Down
      || !VideoDetailFragmentPage.prefBool(show_hold_to_append_key, true)) {
      return;
    }
    animateTo({ duration: 250 }, () => {
      this.holdToAppendTipAlpha = 1;
    });
    setTimeout((): void => {
      animateTo({ duration: 1500 }, () => {
        this.holdToAppendTipAlpha = 0;
      });
    }, 1250);
  }

  /** !player.isLiveEdge(): the LIVE label is a button only while the broadcast lags behind. */
  @State behindLiveEdge: boolean = false;

  /** Player.seekToDefault() for a live stream; see PlayerService.syncToLiveEdge(). */
  private seekToLiveEdge(): void {
    if (this.behindLiveEdge) {
      PlayerService.getInstance().syncToLiveEdge();
    }
  }


  /** TouchCallback.onMove -> playQueue.move(); the queue's MoveEvent refreshes the list. */
  private moveQueueItem(fromIndex: number, toIndex: number): void {
    const queue: PlayQueue | null = this.livePlayQueue;
    if (queue === null) {
      this.queueSource.move(fromIndex, toIndex);
      return;
    }
    queue.move(fromIndex, toIndex);
  }

  /**
   * onSwiped / menu_item_remove -> playQueue.remove().
   *
   * Removing the row that is CURRENTLY PLAYING has to move playback too: PlayQueue.remove() emits
   * a RemoveEvent, never a SelectEvent, so removeInternal() slides the cursor onto the item that
   * takes the removed one's place and nothing re-prepares the player - the deleted stream would
   * have kept playing off a row that no longer exists. An emptied queue closes the player, which
   * is the source's own end-of-queue behaviour.
   */
  private removeQueueItem(index: number): void {
    const queue: PlayQueue | null = this.livePlayQueue;
    if (queue === null) {
      this.queueSource.removeAt(index);
      return;
    }
    const wasPlaying: boolean = index === queue.getIndex();
    queue.remove(index);
    if (!wasPlaying) {
      return;
    }
    if (queue.isEmpty()) {
      this.closePlayer();
      return;
    }
    // readQueue() has already re-read the list off the RemoveEvent, so this is the new current
    // item. loadItem(), not selectQueueItem(): the removed stream must not go on the back stack.
    const next: PlayQueueItem | undefined = this.playQueue[queue.getIndex()];
    if (next !== undefined) {
      this.loadItem(new ItemParams(next.getServiceId(), next.getUrl(), next.getTitle()));
    }
  }

  /**
   * The system media card asks for a shuffle STATE, not a toggle. Idempotent, because setLoopMode
   * can arrive carrying the state the queue is already in.
   */
  private setShuffledFromSession(on: boolean): void {
    const queue: PlayQueue | null = this.livePlayQueue;
    if (queue === null) {
      this.shuffled = on;
      return;
    }
    if (queue.isShuffled() === on) {
      return;
    }
    this.toggleShuffle();
  }

  /** control_shuffle -> playQueue.shuffle() / unshuffle(). */
  private toggleShuffle(): void {
    const queue: PlayQueue | null = this.livePlayQueue;
    if (queue === null) {
      this.shuffled = !this.shuffled;
      return;
    }
    if (queue.isShuffled()) {
      queue.unshuffle();
    } else {
      queue.shuffle();
    }
    // A queue of two or fewer emits no ReorderEvent, so read the flag back rather than wait.
    this.shuffled = queue.isShuffled();
  }

  private openRowMenu(index: number): void {
    this.heldIndex = index;
    this.rowMenuOpen = true;
    this.rowMenuDialog.open();
  }

  private closeRowMenu(): void {
    if (this.rowMenuOpen) {
      this.rowMenuOpen = false;
      this.rowMenuDialog.close();
    }
    this.heldIndex = -1;
  }

  /** The held row, for the popup's own navigations. */
  private heldItem(): PlayQueueItem | null {
    const item: PlayQueueItem | undefined = this.playQueue[this.heldIndex];
    return item === undefined ? null : item;
  }

  /**
   * menu_play_queue_item: the same component the queue screen raises, which is why it was lifted
   * out of that page's @Builder member in wave 1 - a @Builder member cannot be mounted from
   * another struct. Every action stays here, because only this page knows which row is held.
   */
  private rowMenuDialog: CustomDialogController = new CustomDialogController({
    // customStyle: PlayQueueRowMenu draws its own white, square-cornered card; the system
    // container would put a second rounded surface under it.
    customStyle: true,
    // A tap outside or a back gesture closes the controller WITHOUT going through a menu entry,
    // so the flag has to be cleared here or the next long press would re-open nothing.
    cancel: (): void => {
      this.rowMenuOpen = false;
      this.heldIndex = -1;
    },
    builder: PlayQueueRowMenuHost({
      onRemove: (): void => {
        if (this.heldIndex >= 0) {
          this.removeQueueItem(this.heldIndex);
        }
        this.closeRowMenu();
      },
      onDetails: (): void => {
        // NavigationHelper.openVideoDetail(): this screen IS the video detail, so the held item
        // is loaded in place rather than stacked behind a second copy of the same page.
        const index: number = this.heldIndex;
        this.closeRowMenu();
        this.selectQueueItem(index);
      },
      onAppendPlaylist: (): void => {
        // QueueItemMenuUtil: the dialog writes the HELD row, not the stream on screen.
        const item: PlayQueueItem | null = this.heldItem();
        this.closeRowMenu();
        if (item !== null) {
          const row: StreamEntity = new StreamEntity(item.serviceId, item.url, item.title,
            item.streamType, item.duration, item.uploader);
          row.uploaderUrl = item.uploaderUrl;
          this.openPlaylistDialog([row]);
        }
      },
      onChannelDetails: (): void => {
        // fetchUploaderUrlIfSparse(): a sparse row has its stream fetched for the url first.
        const item: PlayQueueItem | null = this.heldItem();
        this.closeRowMenu();
        if (item !== null) {
          openChannelOfQueueItem(item);
        }
      },
      onShare: (): void => {
        const item: PlayQueueItem | null = this.heldItem();
        this.closeRowMenu();
        if (item !== null) {
          this.share().shareText(item.getTitle(), item.getUrl())
            .catch((err: BusinessError): void => {
              hilog.error(0x0000, TAG, 'share failed: %{public}s', err.message);
            });
        }
      },
      onDownload: (): void => {
        // openDownloadDialog(): the DownloadDialog overlay is hosted by THIS screen, so unlike
        // the queue activity's copy this entry really opens it - and it opens on the HELD row,
        // not on whatever happens to be playing.
        const item: PlayQueueItem | null = this.heldItem();
        this.closeRowMenu();
        if (item !== null) {
          this.openDownloadFor(item.getServiceId(), item.getUrl());
        }
      }
    })
  });

  /* //////////////////////////////////////////////////////////////////////////
  // Builders - the player's popup menus
  ////////////////////////////////////////////////////////////////////////// */

  /**
   * audioTrackPopupMenu, under POPUP_MENU_ID_AUDIO_TRACK.
   *
   * This drew AudioTrackAdapter's rows, and on device every row came out BLANK: the adapter
   * labels a row from getAudioTrackId() / getAudioTrackName() / getAudioLocale(), and a YouTube
   * stream with a single unnamed track returns null for all three, so all of the row's Texts
   * were the empty string and the popup was a white pill with nothing in it. The adapter also
   * feeds DownloadDialogPage's spinner, so the fix lives here: the rows are MenuItems labelled
   * by this page's own audioTrackName(), which already falls back to "Unknown". Same shape as
   * qualityMenu() and captionMenu() right below - both device-verified.
   */
  @Builder
  audioTrackMenu() {
    Menu() {
      ForEach(this.audioTracks, (group: AudioTrackGroup, index: number) => {
        MenuItem({ content: this.audioTrackLabelAt(index) })
          // The reference's popups are dark panels with light text, anchored under the control;
          // this one came out as ArkUI's default white sheet, which is the "UI design is faulty"
          // half of the report.
          .contentFontColor($r('app.color.on_primary'))
          .onClick(() => {
            this.selectAudioTrack(index);
          })
      }, (group: AudioTrackGroup, index: number) => `${index}`)
    }
    .backgroundColor($r('app.color.player_popup_background'))
  }

  /** qualityPopupMenu: one row per stream, labelled MediaFormat + resolution. */
  @Builder
  qualityMenu() {
    Menu() {
      // No muted-speaker glyph on any row. It used to mark the rows backed by a video-only
      // stream, on the reasoning that such a row plays without sound - and that was true while a
      // video-only pick fell back to a muxed rendition. It is not true any more: since T-0074 a
      // picked height the muxed set cannot give is SYNTHESISED, video-only plus the chosen audio,
      // so every row in this list plays with sound. A glyph that says otherwise now misleads.
      // The reference draws no glyph on any of its rows either - measured on "Me at the zoo"
      // (MPEG-4 360p / 240p / 144p) and on a 4K-capable stream (1080p down to 144p).
      ForEach(this.qualityOptions, (option: QualityOption, index: number) => {
        MenuItem({ content: option.label })
          .onClick(() => {
            this.selectQuality(option);
          })
      }, (option: QualityOption, index: number) => `${index}-${option.label}`)
    }
  }

  /**
   * onQualityItemClick(): the label AND the player move. The port only ever assigned the
   * label, so playback stayed on whatever the resolver picked the first time.
   */
  private async selectQuality(option: QualityOption): Promise<void> {
    this.qualityLabel = option.indicator();
    const info: StreamInfo | null = this.currentInfo;
    if (info === null || !this.playerAttached) {
      return;
    }
    // PlayerService carries player.currentTime into the re-source, so the switch keeps the
    // viewer's position instead of starting the stream again at 0:00.
    // T-0204: the picked AUDIO TRACK has to ride along, the mirror of T-0203. Without it the
    // re-source fell back to bestAudio(set, ''), the loudest track of ANY language, while the
    // audio control went on naming the one the user chose. Measured on a MrBeast video carrying
    // several dubs: with "Bangla dubbed" showing, re-selecting that same track still produced a
    // re-source, which prepare()'s early return makes impossible when the track is really the
    // one playing.
    const report: PlaybackReport = await PlayerService.getInstance()
      .prepare(info, false, option.height, this.audioTrackIdAt(this.selectedAudioTrack));
    // T-0196: a PICKED rung gets the same honesty as the opening one. The resolver refuses a
    // height it cannot build - no avc1 track that tall, or synthesis that would not beat the
    // muxed file (T-0202) - and serves the nearest muxed rendition instead. Measured on
    // iG9CE55wbtY: picking 720p or 144p left the decoder on the one muxed track
    // ("video size change, width 320, height 240" unchanged) while the chip read the picked
    // rung. The chip now says what is playing, which is what playInner() already did.
    this.showServedQuality(report);
  }

  /**
   * The audio control reads the track the player APPLIED, never the one the list happens to start
   * with.
   *
   * T-0208: defaultAudioTrackIndex() names the ORIGINAL row on every fresh open and was only ever
   * reconciled after an explicit pick, so it did not read prefer_original_audio either. With that
   * preference OFF the resolver takes the loudest track - measured, ar.3 on a MrBeast upload -
   * while the control went on reading "English original". This is the same reconciliation
   * changeAudioTrack() already does, moved to where the FIRST prepare() finishes.
   *
   * An empty applied id means a muxed file is playing, which carries the stream's own soundtrack
   * and no label of its own: the ORIGINAL row the list already shows is the truthful answer, so
   * it is left alone.
   */
  private showAppliedAudioTrack(report: PlaybackReport): void {
    const applied: string = report.source === null ? '' : report.source.audioTrackId;
    if (applied.length === 0) {
      return;
    }
    for (let i: number = 0; i < this.audioTracks.length; i++) {
      if (this.audioTrackIdAt(i) === applied) {
        this.selectedAudioTrack = i;
        this.audioTrackLabel = this.audioTrackLabelAt(i);
        return;
      }
    }
  }

  /** The chip reads the rendition the resolver SERVED, never the one that was asked for. */
  private showServedQuality(report: PlaybackReport): void {
    const served: string = report.source === null ? '' : report.source.resolution;
    if (served.length > 0 && served !== 'auto') {
      this.qualityLabel = served;
    }
  }

  /** captionPopupMenu: the subtitle tracks, rebuilt in onTextTracksChanged. */
  @Builder
  captionMenu() {
    Menu() {
      // The source's list always carries the "no captions" row - it is how captions are turned
      // back OFF once a track has been chosen, and it is the whole list when none exist.
      MenuItem({ content: $r('app.string.caption_none') })
        .contentFontColor($r('app.color.on_primary'))
        .onClick(() => {
          this.selectCaption(-1);
        })
      ForEach(this.captionLabels(), (label: string, index: number) => {
        MenuItem({ content: label })
          .contentFontColor($r('app.color.on_primary'))
          .onClick(() => {
            this.selectCaption(index);
          })
      }, (label: string, index: number) => `${index}-${label}`)
    }
    // The reference's caption popup is the same dark panel its audio-track popup is; this one
    // was ArkUI's default white sheet over the video.
    .backgroundColor($r('app.color.player_popup_background'))
  }

  /**
   * MainPlayerUi.onPlaybackSpeedClicked() opens PlaybackParameterDialog - the same dialog the
   * queue screen opens, mounted here as a SECOND instance with its own @Link. Its id is
   * parameterised because a component .id() is application-global and two live nodes under one
   * id is a hazard for the id-driven QA harness.
   */
  private playbackParameterDialog: CustomDialogController = new CustomDialogController({
    customStyle: true,
    // The AlertDialog's backgroundDimAmount 0.6; the system default mask is much lighter.
    maskColor: DIALOG_MASK_COLOR,
    // An outside tap or back gesture closes the controller without touching the @Link.
    cancel: (): void => {
      this.showPlaybackParameters = false;
    },
    builder: PlaybackParameterDialogHost({
      dialogId: 'videoDetailPlaybackParameterDialogPage',
      isShown: this.showPlaybackParameters,
      initialValues: this.playbackParameters,
      onPlaybackParameterChanged:
        (tempo: number, pitchPercent: number, skipSilence: boolean): void => {
          this.onPlaybackParameterChanged(tempo, pitchPercent, skipSilence);
        }
    })
  });

  private onPlaybackParametersVisibility(): void {
    if (this.showPlaybackParameters) {
      this.playbackParameterDialog.open();
    } else {
      this.playbackParameterDialog.close();
    }
  }

  /**
   * Callback.onPlaybackParameterChanged(tempo, pitch, skipSilence). AVPlayer exposes setSpeed()
   * and nothing for pitch or skip-silence (risk_playback_speed_enum), so the tempo is really
   * applied - setSpeed returns the rate the enum could deliver, which is what the label shows -
   * and the other two are carried and logged rather than silently dropped.
   */
  private onPlaybackParameterChanged(tempo: number, pitchPercent: number,
    skipSilence: boolean): void {
    this.playbackParameters = new PlaybackParameters(tempo, pitchPercent, skipSilence);
    // Player.setPlaybackParameters(): applied AND saved, so the next session starts at it.
    PlayerService.getInstance().setPlaybackParameters(tempo, pitchPercent, skipSilence);
    this.playbackSpeedLabel = formatSpeed(PlayerService.getInstance().displayRate());
    hilog.info(0x0000, TAG,
      'playback parameters: tempo=%{public}f pitch=%{public}f skipSilence=%{public}d',
      tempo, pitchPercent, skipSilence ? 1 : 0);
  }

  /**
   * StreamItemAdapter's rows: the muxed videoStreams AND the videoOnlyStreams, tallest first,
   * each labelled MediaFormat name + resolution. The port listed only videoStreams, which on
   * YouTube is the 360p-and-below rump - everything above it is video-only.
   */
  /**
   * ListHelper.getDefaultResolutionIndex(): the row `Default resolution` names.
   *
   * The port never read that preference. `default_resolution_key` was declared, written by the
   * settings screen and consulted by nothing, so every stream opened at the TALLEST rendition it
   * had - measured against the reference on the same 4K video, the port opened 1080p60 where the
   * reference opened its configured 720p60 (T-0196).
   *
   * The options are sorted tallest-first, so index 0 is `best_resolution`. A stream that does not
   * carry the configured resolution falls to the next one DOWN, as the source does - never up,
   * which would spend data the user declined - and to the lowest it has when everything is taller.
   */
  private static defaultQualityIndex(options: QualityOption[], preferred: string): number {
    if (options.length === 0) {
      return -1;
    }
    if (preferred === best_resolution_key) {
      return 0;
    }
    for (let i = 0; i < options.length; i++) {
      if (options[i].indicator() === preferred) {
        return i;
      }
    }
    // '720p60' -> 720. The fps suffix only breaks a tie between two rows of the same height, and
    // an exact match above has already had its chance.
    const wanted: number = Number.parseInt(preferred, 10);
    if (!Number.isNaN(wanted)) {
      for (let i = 0; i < options.length; i++) {
        if (options[i].height <= wanted) {
          return i;
        }
      }
    }
    return options.length - 1;
  }

  private static qualityOptions(info: StreamInfo, showHigherResolutions: boolean): QualityOption[] {
    // The list is the streams this player can actually SWITCH TO, which is the muxed set.
    //
    // Video-only streams used to be listed too, flagged with the muted-speaker glyph. Three things
    // followed, and all three are what TC-PLAYER-006 reports:
    //   * choosing one did nothing it said - selectQuality() passes a target HEIGHT, and
    //     MediaSourceResolver.resolve() reaches for the muxed set first, so a video-only 144p
    //     landed on muxed 240p instead. Measured on device: the label read "MPEG-4 144p" while
    //     the decoder reported `video size change, width 320, height 240`.
    //   * the same resolution appeared twice - "MPEG-4 360p" muxed and "MPEG-4 360p" video-only
    //     are two rows with one name.
    //   * the list ran long with rows the reference does not carry at all. Measured on the
    //     reference for the same streams: "Me at the zoo" lists MPEG-4 360p / 240p / 144p, and a
    //     4K-capable stream lists MPEG-4 1080p down to 144p - muxed only, no WebM, no glyphs.
    //
    // A resolution the resolver cannot honour does not belong in a control whose whole purpose is
    // to pick one.
    // ListHelper.getSortedStreamVideosList(): the muxed and video-only sets are MERGED and then
    // reduced to ONE ROW PER RESOLUTION, the preferred format winning the tie. The port listed
    // both sets whole, which is what TC-PLAYER-006 reports:
    //   * the same resolution twice - "MPEG-4 360p" muxed and "MPEG-4 360p" video-only;
    //   * rows the reference does not carry (the WebM renditions);
    //   * and a pick that did nothing it said, because a video-only height fell back to the
    //     nearest muxed one. That half is fixed in the resolver, which now synthesises a height
    //     the muxed set cannot give.
    // Measured on the reference: "Me at the zoo" offers MPEG-4 360p / 240p / 144p, and a
    // 4K-capable stream MPEG-4 1080p down to 144p - one row per resolution, all MPEG-4.
    const byHeight: Map<number, QualityOption> = new Map<number, QualityOption>();
    const consider = (stream: VideoStream, videoOnly: boolean): void => {
      const height: number = VideoDetailFragmentPage.heightOf(stream);
      if (height <= 0) {
        return;
      }
      // ListHelper.getSortedStreamVideosList(): with show_higher_resolutions off - and it ships
      // off - 2160p and 1440p are dropped from the list entirely. The port carried no such filter,
      // so on stock settings it offered two rows the reference does not and, because the label is
      // seeded from the tallest row, opened the stream at 2160p where the reference opened at
      // 1080p and below (T-0195).
      if (!showHigherResolutions && HIGH_RESOLUTIONS.indexOf(height) >= 0) {
        return;
      }
      const label: string = VideoDetailFragmentPage.qualityLabelOf(stream);
      const held: QualityOption | undefined = byHeight.get(height);
      if (held === undefined) {
        byHeight.set(height, new QualityOption(label, height, videoOnly));
        return;
      }
      // A tie is broken the way the source's preferred-format setting breaks it: MPEG-4 first,
      // and a stream that already carries audio ahead of one that does not.
      const heldPreferred: boolean = held.label.indexOf('MPEG-4') === 0;
      const minePreferred: boolean = label.indexOf('MPEG-4') === 0;
      if ((minePreferred && !heldPreferred) || (minePreferred === heldPreferred
        && !videoOnly && held.videoOnly)) {
        byHeight.set(height, new QualityOption(label, height, videoOnly));
      }
    };
    for (const stream of info.getVideoStreams()) {
      consider(stream, false);
    }
    for (const stream of info.getVideoOnlyStreams()) {
      consider(stream, true);
    }
    const options: QualityOption[] = [];
    byHeight.forEach((option: QualityOption): void => {
      options.push(option);
    });
    options.sort((a: QualityOption, b: QualityOption): number => b.height - a.height);
    return options;
  }

  private static qualityLabelOf(stream: VideoStream): string {
    const format: MediaFormat | null = stream.getFormat();
    const resolution: string = stream.getResolution();
    const name: string = format === null ? '' : format.getName();
    if (resolution.length === 0) {
      return name.length === 0 ? Localization.getString('unknown_quality') : name;
    }
    return name.length === 0 ? resolution : name + ' ' + resolution;
  }

  /**
   * The height a row MEANS, taken from the resolution the row shows.
   *
   * getHeight() and getResolution() do not always agree: measured on "Me at the zoo", a video-only
   * stream the itag table calls "MPEG-4 360p" reports `height` 240 from the response. Keying on
   * the declared height therefore filed a 360p row under 240 and handed the resolver 240 when the
   * user picked 360 - the label said one thing and the player did another, which is the heart of
   * TC-PLAYER-006. The resolution string is what the user reads and picks, so it is the number
   * this control works in; the declared height is the fallback for a stream that carries no
   * resolution string at all. StreamSetAdapter.videoTrack() takes the same view, so the resolver
   * compares like with like.
   */
  private static heightOf(stream: VideoStream): number {
    const digits: RegExpMatchArray | null = stream.getResolution().match(/(\d+)/);
    if (digits !== null) {
      return Number.parseInt(digits[1], 10);
    }
    return stream.getHeight();
  }

  /**
   * Localization.audioTrackName(context, stream). This used to be a second, poorer copy of it:
   * it took the name or the locale and STOPPED, so every row read as a bare language - "Arabic",
   * "German" - where the reference reads "Arabic dubbed", "English original". AudioTrackAdapter
   * already carries the real one, and the download dialog's spinner already uses it.
   */
  private audioTrackLabelAt(index: number): string {
    if (index < 0 || index >= this.audioTracks.length) {
      return Localization.getString('unknown_audio_track');
    }
    const label: string = audioTrackName(this.audioTracks[index].first());
    return label.length > 0 ? label : Localization.getString('unknown_audio_track');
  }

  /** `de` out of `de.3`, `en-US` out of `en-US.4`; '' when the stream does not label its tracks. */
  private static languageOf(trackId: string): string {
    const at: number = trackId.lastIndexOf('.');
    return at > 0 ? trackId.substring(0, at) : trackId;
  }

  /** The row carrying a language, or -1 - this stream may simply not offer it (T-0211). */
  private trackIndexForLanguage(language: string): number {
    if (language.length === 0) {
      return -1;
    }
    for (let i: number = 0; i < this.audioTracks.length; i++) {
      if (VideoDetailFragmentPage.languageOf(this.audioTrackIdAt(i)) === language) {
        return i;
      }
    }
    return -1;
  }

  /** The audioTrackId of a group, '' when the stream does not label its tracks. */
  private audioTrackIdAt(index: number): string {
    if (index < 0 || index >= this.audioTracks.length) {
      return '';
    }
    const stream: AudioStream | null = this.audioTracks[index].first();
    if (stream === null) {
      return '';
    }
    const id: string | null = stream.getAudioTrackId();
    return id === null ? '' : id;
  }

  /**
   * Which track is playing before the user touches anything. A muxed progressive file - what the
   * resolver reaches for first - carries the ORIGINAL soundtrack, so that is the row the control
   * has to show. It used to show index 0 of a list ordered by locale, which on a video dubbed
   * into a dozen languages is Arabic: the control read "Arabic" while English played, which is
   * this case's report.
   */
  private defaultAudioTrackIndex(): number {
    for (let i: number = 0; i < this.audioTracks.length; i++) {
      const stream: AudioStream | null = this.audioTracks[i].first();
      if (stream !== null && stream.getAudioTrackType() === AudioTrackType.ORIGINAL) {
        return i;
      }
    }
    return 0;
  }

  /**
   * onAudioTrackClicked(): the chosen language is handed to the PLAYER, which re-sources the
   * stream onto that track. The row used to set two @State strings and nothing else, so the
   * label moved and the audio did not. The label is then re-read from what the player applied -
   * a stream that does not really carry the track leaves the original playing, and the control
   * says so instead of claiming the switch happened.
   */
  private async selectAudioTrack(index: number): Promise<void> {
    this.selectedAudioTrack = index;
    // T-0210: from here on this stream has a track the VIEWER chose, and every later prepare()
    // has to carry it. Before the pick there is none - passing the list's default row instead
    // would override prefer_original_audio, which is the resolver's business, not the page's.
    this.audioTrackPicked = true;
    PlayerService.getInstance().rememberPickedAudioLanguage(
      VideoDetailFragmentPage.languageOf(this.audioTrackIdAt(index)));
    this.audioTrackLabel = this.audioTrackLabelAt(index);
    const info: StreamInfo | null = this.currentInfo;
    if (info === null || !this.playerAttached) {
      return;
    }
    await PlayerService.getInstance()
      .prepare(info, false, this.currentTargetHeight(), this.audioTrackIdAt(index));
    const applied: string = PlayerService.getInstance().getAudioTrackId();
    if (applied === this.audioTrackIdAt(index)) {
      return;
    }
    if (applied.length === 0) {
      // Nothing separate could be played, so the stream's own soundtrack - the original - is
      // what is running. Saying otherwise is exactly the defect this case reports.
      this.selectedAudioTrack = this.defaultAudioTrackIndex();
      this.audioTrackLabel = this.audioTrackLabelAt(this.selectedAudioTrack);
      return;
    }
    for (let i: number = 0; i < this.audioTracks.length; i++) {
      if (this.audioTrackIdAt(i) === applied) {
        this.selectedAudioTrack = i;
        this.audioTrackLabel = this.audioTrackLabelAt(i);
        return;
      }
    }
  }

  /**
   * The height the quality control last asked for, so an audio switch does not undo it.
   *
   * T-0203: this compared `option.label` - the full row, "MPEG-4 480p" - against `qualityLabel`,
   * which only ever holds the bare indicator ("480p") or a served resolution string. The two can
   * never be equal, so it always returned 0 and an audio-track switch silently dropped the height
   * the user had picked: the one thing the comment above says it prevents. The indicator is what
   * the chip is set from in both places (playInner() and showServedQuality()), so that is what it
   * has to be matched against.
   */
  private currentTargetHeight(): number {
    for (const option of this.qualityOptions) {
      if (option.indicator() === this.qualityLabel) {
        return option.height;
      }
    }
    return 0;
  }

  /**
   * VideoDetailFragment.onCaptionsClicked(): the display language, and " (Auto-generated)" when
   * the track is one. YouTube carries BOTH an authored and an auto-generated English track for
   * most videos, so dropping the qualifier put two rows reading "English" in the list with
   * nothing to tell them apart - the control could be opened but not meaningfully used, which is
   * this case's "the function cannot be controlled". The string resource was already here and
   * unused.
   */
  private captionLabelOf(subtitle: SubtitlesStream): string {
    const name: string = subtitle.getDisplayLanguageName();
    return subtitle.isAutoGenerated()
      ? name + ' (' + Localization.getString('caption_auto_generated') + ')' : name;
  }

  private captionLabels(): string[] {
    const info: StreamInfo | null = this.currentInfo;
    if (info === null) {
      return [];
    }
    const labels: string[] = [];
    for (const subtitle of info.subtitles) {
      labels.push(this.captionLabelOf(subtitle));
    }
    return labels;
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Builders - player (player.xml, attached into player_placeholder)
  ////////////////////////////////////////////////////////////////////////// */

  /** topControls > primaryControls. */
  @Builder
  playerPrimaryControls() {
    Row({ space: CONTROL_SPACING_VP }) {
      Image($r('app.media.ic_close'))
        .id('playerCloseButton')
        .accessibilityText($r('app.string.close'))
        .width(24)
        .height(24)
        .objectFit(ImageFit.Contain)
        .fillColor($r('app.color.on_primary'))
        .onClick(() => {
          this.closePlayer();
        })

      // metadataView is GONE in popup mode; in the main player it carries the two labels.
      Column() {
        Text(this.title)
          .id('titleTextView')
          .fontSize(14)
          .fontColor($r('app.color.on_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.uploaderSubChannelName)
          .id('channelTextView')
          .fontSize(11)
          .fontColor($r('app.color.white_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .id('metadataView')
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 8, right: 8 })

      // onAudioTracksClicked(): audioTrackPopupMenu.show() - the grouped tracks, one MenuItem each.
      // Player.updateStreamRelatedViews(): the control is GONE unless there is more than one
      // track to choose between. The port drew it always, so a stream with a single unnamed
      // track showed a language slot reading "Unknown" where the reference shows no control at
      // all - measured on "Me at the zoo", whose reference primary row is close / 360p / 1x /
      // queue / chapters / more.
      if (this.audioTracks.length > 1) {
        Text(this.audioTrackLabel)
          .id('audioTrackTextView')
          .fontSize(12)
          .fontColor($r('app.color.on_primary'))
          .padding({ left: CONTROL_LABEL_INSET_VP, right: CONTROL_LABEL_INSET_VP })
          .bindMenu(this.audioTrackMenu())
      }

      // onQualityClicked(): qualityPopupMenu.show() over info.getVideoStreams().
      // YouTube returns videoStreams for a broadcast too, but the live path plays the HLS
      // manifest and ignores the chosen height entirely (e412093), so every row was a no-op.
      // The control is not offered rather than offering twelve rows that do nothing.
      if (!StreamSetAdapter.isLive(this.streamType)) {
        Text(this.qualityLabel)
          .id('qualityTextView')
          .fontSize(12)
          .fontColor($r('app.color.on_primary'))
          .padding({ left: CONTROL_LABEL_INSET_VP, right: CONTROL_LABEL_INSET_VP })
          .bindMenu(this.qualityMenu())
      }

      // MainPlayerUi.onPlaybackSpeedClicked(): PlaybackParameterDialog, not a popup menu.
      Text(this.playbackSpeedLabel)
        .id('playbackSpeed')
        .fontSize(12)
        .fontColor($r('app.color.on_primary'))
        .padding({ left: CONTROL_LABEL_INSET_VP, right: CONTROL_LABEL_INSET_VP })
        .onClick(() => {
          // Seed the dialog from what the control shows, so reopening it does not quietly
          // replace the user's 0.1x with the 0.125x step it maps to (T-0132).
          // Pitch and skip-silence come back from where setPlaybackParameters() saved them.
          this.playbackParameters = new PlaybackParameters(
            PlayerService.getInstance().displayRate(),
            PlayerPrefs.playbackPitch(1.0), PlayerPrefs.playbackSkipSilence());
          this.showPlaybackParameters = true;
        })

      Image($r('app.media.ic_list'))
        .id('queueButton')
        .accessibilityText($r('app.string.open_play_queue'))
        .width(24)
        .height(24)
        .objectFit(ImageFit.Contain)
        .fillColor($r('app.color.on_primary'))
        .margin({ left: 6 })
        .onClick(() => {
          this.showQueue();
        })

      // onSegmentsClicked(): segmentsButton sits between the queue control and more options on
      // the reference (queueButton [666..771], segmentsButton [795..900], moreOptions [924..]),
      // and opens the same items panel in chapters mode. showSegments() was written and NOTHING
      // called it - there was no control anywhere in this page, which is the whole of "Chapter
      // button is missing".
      if (this.hasSegments) {
        Image($r('app.media.ic_menu_book'))
          .id('segmentsButton')
          .accessibilityText($r('app.string.chapters'))
          .width(24)
          .height(24)
          .objectFit(ImageFit.Contain)
          .fillColor($r('app.color.on_primary'))
          .margin({ left: 6 })
          .onClick(() => {
            this.showSegments();
          })
      }

      Image($r('app.media.ic_expand_more'))
        .id('moreOptionsButton')
        .accessibilityText($r('app.string.more_options'))
        .width(24)
        .height(24)
        .objectFit(ImageFit.Contain)
        .fillColor($r('app.color.on_primary'))
        .margin({ left: 6 })
        // MainPlayerUi.onMoreOptionsClicked(): the arrow turns UP while the secondary row is out,
        // as the reference shows it. The port left it pointing down in both states, so the
        // control never said which way it would go.
        .rotate({ angle: this.playerSecondaryControlsShown ? 180 : 0 })
        .onClick(() => {
          this.playerSecondaryControlsShown = !this.playerSecondaryControlsShown;
        })
        // moreOptionsButton's long click: hideControls(0, 0), and onMoreOptionsLongClicked() slides
        // the page up by the player's height over 500 ms (DecelerateInterpolator) so the title and
        // description come into view. Fullscreen has no page behind the player to scroll.
        .gesture(LongPressGesture().onAction(() => {
          this.controlsVisible = false;
          if (!this.isFullscreen) {
            this.detailScroller.scrollTo({
              xOffset: 0,
              yOffset: PLAYER_FRAME_VP,
              animation: { duration: 500, curve: Curve.EaseOut }
            });
          }
        }))
    }
    .id('primaryControls')
    .width('100%')
    // The same inset secondaryControls already used. At 8vp the last control sat 11px from the
    // frame edge against the reference's 48px on a 1080 frame, which is the chevron "not fitting
    // on the screen" - and the two rows did not line up with each other either.
    .padding({
      left: CONTROL_ROW_INSET_VP, right: CONTROL_ROW_INSET_VP, top: 8, bottom: 8
    })
    .alignItems(VerticalAlign.Center)
  }

  /** topControls > secondaryControls - slid in and out by moreOptionsButton. */
  @Builder
  playerSecondaryControls() {
    Row({ space: CONTROL_SPACING_VP }) {
      Text(this.resizeModeLabel())
        .id('resizeTextView')
        .fontSize(12)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.on_primary'))
        .padding({ left: CONTROL_LABEL_INSET_VP, right: CONTROL_LABEL_INSET_VP })
        .onClick(() => {
          this.cycleResizeMode();
        })

      // onCaptionClicked(): captionPopupMenu.show() over info.getSubtitles(). Player.java hides
      // the control when there are no subtitles to choose between, the same rule the audio-track
      // control follows. Measured on the reference, a media.ccc.de talk with no subtitles: its
      // second row is Fit / globe / share / mute, with no caption cell at all, where the port
      // showed "No Captions".
      if (this.currentInfo !== null && this.currentInfo.subtitles.length > 0) {
        Text(this.captionLabel)
          .id('captionTextView')
          .fontSize(12)
          .fontColor($r('app.color.on_primary'))
          .padding({ left: CONTROL_LABEL_INSET_VP, right: CONTROL_LABEL_INSET_VP })
          .bindMenu(this.captionMenu())
      }

      // The reference's secondary row spans the frame: the two text controls sit at the start and
      // the icon group is pushed to the far end, 94.9 dp of clear space between them. The port
      // packed everything against the left and left 136.6 vp of dead space on the right, which is
      // what put its buttons on top of one another.
      Blank()
        .layoutWeight(1)

      // KoreUtils.shouldShowPlayWithKodi(): the preference, exactly as the bottom copy of this
      // control is already gated in controlPanels(). It was drawn unconditionally here.
      if (this.kodiAvailableForStream()) {
        Image($r('app.media.ic_cast'))
          .id('playWithKodi')
          .accessibilityText($r('app.string.play_with_kodi_title'))
          .width(CONTROL_TOUCH_TARGET_VP)
          .height(CONTROL_TOUCH_TARGET_VP)
          .padding(CONTROL_GLYPH_INSET_VP)
          .objectFit(ImageFit.Contain)
          .fillColor($r('app.color.on_primary'))
          .onClick(() => {
            // VideoPlayerUi.onPlayWithKodiClicked(): player.pause() before the hand-off. Only the
            // player's copy pauses; the detail row's detail_controls_play_with_kodi does not.
            if (this.currentInfo !== null) {
              PlayerService.getInstance().pause();
            }
            this.playWithKodi();
          })
      }

      Image($r('app.media.ic_language'))
        .id('openInBrowser')
        .accessibilityText($r('app.string.open_in_browser'))
        .width(CONTROL_TOUCH_TARGET_VP)
        .height(CONTROL_TOUCH_TARGET_VP)
        .padding(CONTROL_GLYPH_INSET_VP)
        .objectFit(ImageFit.Contain)
        .fillColor($r('app.color.on_primary'))
        .onClick(() => {
          this.openInBrowser();
        })

      Image($r('app.media.ic_share'))
        .id('share')
        .accessibilityText($r('app.string.share'))
        .width(CONTROL_TOUCH_TARGET_VP)
        .height(CONTROL_TOUCH_TARGET_VP)
        .padding(CONTROL_GLYPH_INSET_VP)
        .objectFit(ImageFit.Contain)
        .fillColor($r('app.color.on_primary'))
        .onClick(() => {
          // VideoPlayerUi's share: the url AT THE CURRENT TIME, unlike the page's own Share.
          const info: StreamInfo | null = this.currentInfo;
          if (info !== null) {
            this.share().shareText(info.getName(), this.videoUrlAtCurrentTime(info));
          }
        })
        .gesture(LongPressGesture().onAction(() => {
          const info: StreamInfo | null = this.currentInfo;
          if (info !== null) {
            this.share().copyToClipboard(this.videoUrlAtCurrentTime(info));
          }
        }))

      Image(this.muted ? $r('app.media.ic_volume_off') : $r('app.media.ic_volume_up'))
        .id('switchMute')
        .accessibilityText(this.muted ? $r('app.string.unmute') : $r('app.string.mute'))
        .width(CONTROL_TOUCH_TARGET_VP)
        .height(CONTROL_TOUCH_TARGET_VP)
        .padding(CONTROL_GLYPH_INSET_VP)
        .objectFit(ImageFit.Contain)
        .fillColor($r('app.color.on_primary'))
        .onClick(() => {
          // The icon was the whole of it - the audio never changed. AVPlayer has no mute, so
          // mute IS setVolume(0), and unmuting restores the level the swipe overlay set.
          this.muted = !this.muted;
          PlayerService.getInstance().setVolume(this.muted ? 0 : this.unmutedVolume);
        })

      // No fullScreenButton here. MainPlayerUi's secondary row is resize / captions / Kodi /
      // browser / share / mute; the fullscreen toggle lives once, bottom-right, on
      // bottomControls as screenRotationButton - this was a second one of it.
    }
    .id('secondaryControls')
    .width('100%')
    .padding({ left: CONTROL_ROW_INSET_VP, right: CONTROL_ROW_INSET_VP, bottom: 8 })
    .alignItems(VerticalAlign.Center)
  }

  /** PlayerHelper.resizeTypeOf(): "Fit" / "Fill" / "Zoom", the source's own strings. */
  private resizeModeLabel(): string {
    if (this.resizeMode === SurfaceResizeMode.FILL) {
      return Localization.getString('resize_fill');
    }
    return Localization.getString(this.resizeMode === SurfaceResizeMode.ZOOM
      ? 'resize_zoom' : 'resize_fit');
  }

  /** bottomControls: the seek bar row plus the orientation button. */
  @Builder
  playerBottomControls() {
    Row() {
      // Localization.getDurationString() takes SECONDS; positionMs is milliseconds. The source's
      // player writes its two time labels the same way, and this printed the raw millisecond
      // count instead - '166113' where 2:46:53 belongs.
      // A live stream keeps its elapsed clock on the LEFT; only the right-hand label becomes the
      // live indicator. Measured on the reference, lofi hip hop radio: bottom-left "3:59:58",
      // bottom-right "LIVE". The port wrote the live word on both sides on the reasoning that a
      // live stream "has no meaningful elapsed clock" - the reference disagrees, and the position
      // it shows is exactly what playbackLiveSync on the right is offered against. That is the
      // "time format at the bottom left is incorrect" this case reports.
      Text(Localization.getDurationString(this.positionMs / 1000))
        .id('playbackCurrentTime')
        .fontSize(12)
        .fontColor($r('app.color.on_primary'))

      Slider({
        value: this.positionMs,
        min: 0,
        max: this.durationMs > 0 ? this.durationMs : 1
      })
        .id('playbackSeekBar')
        .layoutWeight(1)
        .selectedColor($r('app.color.primary'))
        .trackColor(this.seekBarTrack())
        .blockColor($r('app.color.primary'))
        // A live stream cannot be seeked at all (see seekPlayerTo): with no reachable position
        // to drag to, the bar carries no affordance rather than a fatal one.
        .enabled(!StreamSetAdapter.isLive(this.streamType))
        .onChange((value: number, mode: SliderChangeMode) => {
          this.seekPreviewShowing = mode === SliderChangeMode.Moving;
          // The bubble over the seek bar is the same clock as the labels either side of it.
          this.seekPreviewDisplay = Localization.getDurationString(Math.round(value) / 1000);
          if (mode === SliderChangeMode.Moving) {
            this.updateSeekPreview(value);
          }
          if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving
            || mode === SliderChangeMode.Click) {
            this.seekBarTouched = true;
          }
          if (mode === SliderChangeMode.End && this.seekBarTouched) {
            this.seekBarTouched = false;
            this.seekPlayerTo(value);
          }
        })

      // playbackEndTime is hidden for a live stream, which shows playbackLiveSync instead.
      if (this.streamType !== StreamType.LIVE_STREAM
        && this.streamType !== StreamType.AUDIO_LIVE_STREAM) {
        Text(Localization.getDurationString(this.durationMs / 1000))
          .id('playbackEndTime')
          .fontSize(12)
          .fontColor($r('app.color.on_primary'))
      } else {
        Text('LIVE')
          .id('playbackLiveSync')
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.primary'))
          .padding({ left: 4, right: 4 })
          // player::seekToDefault, clickable only while !isLiveEdge(). AVPlayer cannot seek a live
          // stream, so the way back to the edge is a fresh manifest for the same broadcast.
          .enabled(this.behindLiveEdge)
          .onClick(() => {
            this.seekToLiveEdge();
          })
      }

      Image($r('app.media.ic_fullscreen'))
        .id('screenRotationButton')
        .accessibilityText($r('app.string.toggle_fullscreen'))
        .width(24)
        .height(24)
        .objectFit(ImageFit.Contain)
        .fillColor($r('app.color.on_primary'))
        .margin({ left: 6 })
        .onClick(() => {
          // toggleFullscreen(): the frame takes the page AND the window turns; the first back
          // press then only leaves fullscreen.
          this.toggleFullscreen();
        })
    }
    .id('bottomControls')
    .width('100%')
    .padding({ left: 8, right: 8, top: 4, bottom: 8 })
    .alignItems(VerticalAlign.Center)
  }

  /** The centre transport row (playPrevious / playPause / playNext). */
  @Builder
  playerCenterControls() {
    Row() {
      Image($r('app.media.ic_previous'))
        .id('playPreviousButton')
        .accessibilityText($r('app.string.previous_stream'))
        .width(32)
        .height(32)
        .objectFit(ImageFit.Contain)
        .fillColor($r('app.color.on_primary'))
        .onClick(() => {
          // player.playPrevious(): restart this stream when past the activation limit, step back
          // within it.
          this.playPrevious();
        })

      Image(this.playerStatus === PlayerStatus.PLAYING
        ? $r('app.media.ic_pause') : $r('app.media.ic_play_arrow'))
        .id('playPauseButton')
        .accessibilityText(this.playerStatus === PlayerStatus.PLAYING
          ? $r('app.string.pause') : $r('app.string.play'))
        .width(48)
        .height(48)
        .objectFit(ImageFit.Contain)
        .fillColor($r('app.color.on_primary'))
        .margin({ left: 32, right: 32 })
        // While buffering, the spinner in playerOverlays() sits at exactly this point: drawing a
        // play triangle over it reads as "stopped" rather than "loading", which is the whole of
        // what TC-PLAYER-205 asks to see. Hidden, not None, so previous/next do not shift.
        .visibility(this.playerStatus === PlayerStatus.BUFFERING
          ? Visibility.Hidden : Visibility.Visible)
        .onClick(() => {
          PlayerService.getInstance().togglePlayPause();
        })

      Image($r('app.media.ic_next'))
        .id('playNextButton')
        .accessibilityText($r('app.string.next_stream'))
        .width(32)
        .height(32)
        .objectFit(ImageFit.Contain)
        .fillColor($r('app.color.on_primary'))
        .onClick(() => {
          // player.playNext(): the queue wraps at its end, the way setIndex() does.
          this.playNext();
        })
    }
    .id('playbackWindowRootCenter')
    .alignItems(VerticalAlign.Center)
  }

  /** itemsListPanel: one panel, two modes (queue and chapters). */
  @Builder
  playerItemsListPanel() {
    Column() {
      Row() {
        // The chapters panel is titled "Chapters" on the reference, not with the stream's own
        // name - measured on "Me at the zoo", whose panel header reads Chapters while the stream
        // title sits on the page behind it. The duration header belongs to queue mode.
        if (this.areSegmentsVisible) {
          Text($r('app.string.chapters'))
            .id('itemsListHeaderTitle')
            .layoutWeight(1)
            .fontSize(14)
            .fontColor($r('app.color.on_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        } else {
          // onRepeatModeChanged(): the source swaps ic_repeat_one in for REPEAT_ONE and dims the
          // glyph for REPEAT_OFF. There is no ic_repeat_one drawable in this port, and alpha alone
          // left ONE and ALL pixel-identical - a user tapping through the cycle saw two states
          // where the reference shows three - so the "1" that drawable carries is drawn as a badge
          // instead, exactly as the queue screen already does it.
          Stack({ alignContent: Alignment.Center }) {
            Image($r('app.media.ic_repeat'))
              .width(24)
              .height(24)
              .objectFit(ImageFit.Contain)
              .fillColor($r('app.color.on_primary'))
            if (this.repeatMode === 1) {
              Text('1')
                .id('repeatOneBadge')
                .fontSize(9)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.on_primary'))
                .backgroundColor($r('app.color.black'))
                .padding({ left: 1, right: 1 })
            }
          }
            .id('repeatButton')
            .accessibilityText($r('app.string.notification_action_repeat'))
            .margin({ right: 12 })
            .opacity(this.repeatMode === 0 ? 0.3 : 1.0)
            .onClick(() => {
              // player.cycleNextRepeatMode(): off -> one -> all, and the PLAYER keeps the mode.
              this.repeatMode = PlayerService.getInstance().cycleNextRepeatMode() as number;
            })

          Image($r('app.media.ic_shuffle'))
            .id('shuffleButton')
            .accessibilityText($r('app.string.notification_action_shuffle'))
            .width(24)
            .height(24)
            .objectFit(ImageFit.Contain)
            .fillColor($r('app.color.on_primary'))
            .margin({ right: 12 })
            // onPlayModeChanged(): the same 77/255 alpha the queue screen's control uses.
            .opacity(this.shuffled ? 1.0 : 0.3)
            .onClick(() => {
              // playQueue.shuffle() / unshuffle(). Reversing the RENDERED copy left the queue
              // untouched, and a one-item list reverses to itself - so the button did nothing
              // observable at all.
              this.toggleShuffle();
            })

          // itemsListHeader's time is "position/duration", both formatted - the reference reads
          // "1:35:17/10:10:10" on this stream. The port interpolated the raw millisecond field,
          // so the same header read "36610276". `-:--:--` stands in for either half until the
          // player reports it, which is what activity_player_queue_control.xml declares.
          Text(this.queueHeaderTime())
            .id('itemsListHeaderDuration')
            .layoutWeight(1)
            .fontSize(12)
            .fontColor($r('app.color.white_secondary'))

          Image($r('app.media.ic_playlist_add'))
            .id('addToPlaylistButton')
            .accessibilityText($r('app.string.add_to_playlist'))
            .width(24)
            .height(24)
            .objectFit(ImageFit.Contain)
            .fillColor($r('app.color.on_primary'))
            .margin({ left: 12 })
            .onClick(() => {
              this.openPlaylistDialog();
            })
        }

        Image($r('app.media.ic_close'))
          .id('itemsListClose')
          .accessibilityText($r('app.string.close'))
          .width(24)
          .height(24)
          .objectFit(ImageFit.Contain)
          .fillColor($r('app.color.on_primary'))
          .margin({ left: 12 })
          .onClick(() => {
            this.closeItemsList();
          })
      }
      .id('itemsListControl')
      .width('100%')
      .padding(12)
      .alignItems(VerticalAlign.Center)

      Column() {
        if (this.areSegmentsVisible) {
          StreamSegmentAdapter({
            dataSource: this.segmentSource,
            currentIndex: this.segmentIndex,
            onItemClick: (segment: StreamSegment): void => {
              this.seekPlayerTo(segment.getStartTimeSeconds() * 1000);
            },
            // MainPlayerUi's StreamSegmentListener.onItemLongClick(): YouTube only, and the
            // timestamped link goes to the share sheet (ShareUtils.shareText), not the clipboard.
            onItemLongClick: (segment: StreamSegment): void => {
              const info: StreamInfo | null = this.currentInfo;
              if (info !== null && info.getServiceId() === YOUTUBE_SERVICE_ID) {
                this.share().shareText(info.getName(),
                  info.getUrl() + '&t=' + segment.getStartTimeSeconds());
              }
            }
          })
        } else if (this.playQueue.length > 0) {
          PlayQueueAdapter({
            dataSource: this.queueSource,
            selectedIndex: this.queueIndex,
            onReachEnd: (): void => {
              hilog.debug(0x0000, TAG, 'play queue fetch');
            },
            row: (item: PlayQueueItem, index: number): void => {
              this.queueRow(item, index);
            }
          })
        }
      }
      .width('100%')
      .layoutWeight(1)
    }
    .id('itemsListPanel')
    .width('100%')
    .height('100%')
    // The queue/segments panel sits over the surface on @color/queue_background_color.
    .backgroundColor($r('app.color.queue_background_color'))
  }

  /** player_overlays: the loading panel and the two swipe overlays. */
  @Builder
  playerOverlays() {
    Stack() {
      if (this.playerStatus === PlayerStatus.BUFFERING) {
        // The reference's loading panel, measured on device: a static refresh glyph in
        // ?colorPrimary, 50dp of ink centred on the frame - not a white spinner.
        Image($r('app.media.ic_refresh'))
          .id('progressBarLoadingPanel')
          .width(76)
          .height(76)
          .fillColor($r('app.color.primary'))
      }

      if (this.volumeOverlayShowing) {
        Column() {
          Progress({ value: this.volumeProgress, total: 100 })
            .id('volumeProgressBar')
            .color($r('app.color.on_primary'))
            .width(48)
          Image(this.volumeGlyph())
            .id('volumeImageView')
            .width(24)
            .height(24)
            .fillColor($r('app.color.on_primary'))
            .margin({ top: 8 })
        }
        .id('volumeRelativeLayout')
        .padding(12)
        .backgroundColor('#64000000')
      }

      if (this.brightnessOverlayShowing) {
        Column() {
          Progress({ value: this.brightnessProgress, total: 100 })
            .id('brightnessProgressBar')
            .color($r('app.color.on_primary'))
            .width(48)
          Image(this.brightnessGlyph())
            .id('brightnessImageView')
            .width(24)
            .height(24)
            .fillColor($r('app.color.on_primary'))
            .margin({ top: 8 })
        }
        .id('brightnessRelativeLayout')
        .padding(12)
        .backgroundColor('#64000000')
      }
    }
    .id('player_overlays')
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /** player.xml, mounted by tryAddVideoPlayerView() into player_placeholder. */
  @Builder
  playerView() {
    Stack() {
      // The system volume's setter. It draws nothing of its own here: the swipe shows the
      // player's volumeRelativeLayout, as the source's does.
      if (this.systemVolumeLevel >= 0) {
        AVVolumePanel({
          volumeLevel: this.systemVolumeLevel,
          volumeParameter: { position: { x: -10000, y: -10000 } }
        })
          .width(1)
          .height(1)
          .opacity(0)
          .hitTestBehavior(HitTestMode.None)
      }

      ExpandableSurfaceView({
        videoAspectRatio: this.videoAspectRatio,
        resizeMode: this.resizeMode,
        controller: this.surfaceController,
        onSurfaceReady: (surfaceId: string): void => {
          hilog.info(0x0000, TAG, 'AVPlayer surface ready: %{public}s', surfaceId);
          PlayerService.getInstance().setSurfaceId(surfaceId);
        },
        onSurfaceDestroyed: (surfaceId: string): void => {
          hilog.info(0x0000, TAG, 'AVPlayer surface destroyed: %{public}s', surfaceId);
          PlayerService.getInstance().clearSurfaceId(surfaceId);
        }
      })

      // TC-PLAYER-492 / TC-KIOSK-179: an AUDIO-ONLY stream gives the surface no frames, so the
      // XComponent stayed black and the player showed nothing while the audio played - "during
      // playback, the video player started showing a black screen. The player should display the
      // video cover". The reference draws the artwork in that case.
      //
      // The surface cannot simply be dropped: PiPWindow.create() needs its XComponentController
      // (see openPopupPlayer). So the cover is drawn OVER it, below the overlays and controls,
      // only while the stream carries no video.
      if (this.noVideoStreams && shouldLoadImages()) {
        Image(this.heroThumbnail)
          .id('audio_cover_view')
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Contain)
          .backgroundColor(themedBackground(this.blackTheme))
      }

      this.playerOverlays()

      // subtitleView: the cue SubtitleLoader resolved for the current position. player.xml pins
      // it to the BOTTOM of the surface, above the controls; as a bare child of this Stack it
      // was centred, so every cue was drawn across the middle of the picture - over the faces
      // the viewer is watching. Measured against the reference on the same stream: the cue sits
      // in the lower quarter of the frame there and halfway down here.
      if (this.subtitleText.length > 0) {
        Column() {
          // SubtitleView draws a box AROUND THE TEXT, one per line, centred - measured on the
          // reference at 556 px of 1080 for a four-line cue, with each line's ground ending where
          // its own text does. The port drew one band across the full width of the frame whatever
          // the cue said, which is the "design should be fixed" half of this case. Splitting the
          // cue and letting each line size itself is the whole difference.
          ForEach(this.subtitleLines(), (line: string, index: number) => {
            Text(line)
              .id(index === 0 ? 'subtitleView' : `subtitleView_${index}`)
              .textAlign(TextAlign.Center)
              .fontSize(this.cueStyle.fontSizeFp)
              .fontColor(this.cueStyle.fontColor)
              .backgroundColor(this.cueStyle.backgroundColor)
              .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          }, (line: string, index: number) => `${index}-${line}`)
        }
        .alignItems(HorizontalAlign.Center)
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
        .padding({ bottom: SUBTITLE_BOTTOM_INSET_VP })
        // The column spans the surface only to push the cue down; taps belong to the surface.
        .hitTestBehavior(HitTestMode.None)
      }

      if (this.controlsVisible) {
        Column() {
          this.playerPrimaryControls()
          if (this.playerSecondaryControlsShown) {
            this.playerSecondaryControls()
          }

          Column()
            .layoutWeight(1)

          SeekbarPreviewThumbnailHolder({
            showing: this.seekPreviewShowing,
            seekDisplay: this.seekPreviewDisplay,
            previewFrame: this.seekPreviewFrame
          })

          this.playerBottomControls()
        }
        .id('playbackControlRoot')
        .width('100%')
        .height('100%')
        // player.xml darkens the surface behind the controls with @color/video_overlay_color.
        .backgroundColor($r('app.color.video_overlay_color'))

        this.playerCenterControls()
      }

      // fast_seek_overlay sits AFTER playbackControlRoot: that root is a full-bleed 100% x 100%
      // scrim, so drawn before it the ripple and the seconds readout were painted over by it
      // and the double tap looked like it had done nothing at all.
      if (this.fastSeekShowing) {
        Row() {
          // CircleClipTapView is a 50%-wide clip pinned to the START of its parent, so on a
          // forward seek it has to be pushed to the OTHER half - it was drawing the rewind
          // ripple on the left however far right the tap landed.
          if (this.fastSeekForward) {
            Blank()
              .layoutWeight(1)
          }
          CircleClipTapView({
            // The tap is in surface coordinates; the clip owns half of it.
            tapX: this.fastSeekForward
              ? this.fastSeekX - this.playerWidth / 2 : this.fastSeekX,
            tapY: this.fastSeekY,
            forward: this.fastSeekForward,
            showing: this.fastSeekShowing,
            circleRadius: this.fastSeekRadius
          })
          if (!this.fastSeekForward) {
            Blank()
              .layoutWeight(1)
          }
        }
        .id('fast_seek_overlay')
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)

        // seconds_view: layout_gravity center_vertical on the half being seeked, which is where
        // the chevrons and the "+N seconds" readout belong - not stretched beside the clip.
        SecondsView({
          seconds: this.fastSeekSeconds,
          forward: this.fastSeekForward,
          iconAlpha: this.fastSeekIconAlpha
        })
      }

      if (this.isQueueVisible || this.areSegmentsVisible) {
        this.playerItemsListPanel()
      }


      // player_popup_close_overlay.xml#closeButton is GONE. It only ever rendered while the
      // sheet was collapsed - and while the sheet is collapsed the player frame is not built
      // at all any more, so it was a red circle floating over a docked bar that already has
      // its own overlay_close_button. Three cases report exactly that circle.
    }
    .width('100%')
    .height('100%')
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.playerWidth = Number(newValue.width);
      this.playerHeight = Number(newValue.height);
    })
    // BasePlayerGestureListener: single tap toggles the controls, double tap in the middle
    // play/pauses, double tap left/right fast-seeks, vertical swipes are volume / brightness.
    //
    // EXCLUSIVE, and the single tap is a TapGesture rather than an .onClick: run in parallel,
    // every double tap ALSO fired the single one, so five rapid taps in the middle toggled the
    // controls five times as well as play/pausing - the stutter the case reports.
    .gesture(
      GestureGroup(GestureMode.Parallel,
        GestureGroup(GestureMode.Exclusive,
          TapGesture({ count: 2 })
            .onAction((event: GestureEvent) => {
              this.onDoubleTap(event);
            }),
          TapGesture({ count: 1 })
            .onAction((event: GestureEvent) => {
              this.onSingleTap();
            })
        ),
        PanGesture({ direction: PanDirection.Vertical })
          .onActionUpdate((event: GestureEvent) => {
            this.onVerticalSwipe(event);
          })
          .onActionEnd((event: GestureEvent) => {
            this.volumeOverlayShowing = false;
            this.brightnessOverlayShowing = false;
            this.volumeAtGestureStart = -1;
            this.brightnessAtGestureStart = -1;
            // BottomSheetBehavior: dragging the player down past the settle distance collapses
            // the sheet into the mini player. Without this the sheet only ever went the other
            // way and the mini player could not be reached from a playing stream at all.
            if (!this.isFullscreen && this.isCollapseDrag(event)) {
              this.collapseToPreviousScreen();
            }
          })
      )
    )
  }

  /** BottomSheetBehavior's settle rule: far enough down, or a quick downward fling. */
  private isCollapseDrag(event: GestureEvent): boolean {
    return event.offsetY > COLLAPSE_DRAG_VP
      || (event.offsetY > COLLAPSE_FLING_MIN_VP && event.velocityY > COLLAPSE_FLING_VPS);
  }

  /**
   * Every seek this page issues. AVPlayer refuses seek() on a live stream with err 801
   * ("Unsupport Capability: The stream is live stream, not support seek"), and that arrives on
   * the player's error channel, which tears the player down behind the fatal panel - so a stray
   * touch on the seek bar killed the broadcast. NewPipe does not seek a live stream either, so
   * the call is simply not made and playback continues, the same shape applySpeed() already
   * uses for the live 801 on setSpeed().
   */
  private seekPlayerTo(positionMs: number): void {
    if (StreamSetAdapter.isLive(this.streamType)) {
      return;
    }
    PlayerService.getInstance().seekTo(positionMs);
  }

  /** onDoubleTap(DisplayPortion): MIDDLE play/pauses, LEFT/RIGHT accumulate a fast seek. */
  private onDoubleTap(event: GestureEvent): void {
    const x: number = event.fingerList.length > 0 ? event.fingerList[0].localX : 0;
    const y: number = event.fingerList.length > 0 ? event.fingerList[0].localY : 0;
    const width: number = this.playerWidth > 0 ? this.playerWidth : 1;
    const portion: number = x / width;
    if (portion > 0.33 && portion < 0.66) {
      PlayerService.getInstance().togglePlayPause();
      return;
    }
    if (StreamSetAdapter.isLive(this.streamType)) {
      // Nothing to fast-seek to, and the overlay would promise a jump that never happens.
      return;
    }
    const forward: boolean = portion >= 0.66;
    // A tap on the OTHER half starts a new seek: the source's listener resets the accumulated
    // seconds when the direction changes, it does not keep adding to the old total.
    // retrieveSeekDurationFromPreferences(): the step is the user's seek_duration, not a constant.
    const stepMs: number = PlayerPrefs.seekDurationMs();
    const stepSeconds: number = Math.round(stepMs / 1000);
    this.fastSeekSeconds = this.fastSeekShowing && this.fastSeekForward === forward
      ? this.fastSeekSeconds + stepSeconds : stepSeconds;
    this.fastSeekForward = forward;
    this.fastSeekX = x;
    this.fastSeekY = y;
    this.fastSeekShowing = true;
    this.animateFastSeek();
    PlayerService.getInstance().seekBy(forward ? stepMs : -stepMs);
  }

  /**
   * CircleClipTapView's ValueAnimator plus SecondsView.startAnimation(): the circle expands out
   * of the tap point and the three chevrons run their alphas in sequence. NOTHING drove either
   * of them - circleRadius stayed 0, so the ripple had no size and the overlay was invisible
   * even where it rendered, and fastSeekSeconds accumulated for the life of the page.
   */
  private animateFastSeek(): void {
    this.fastSeekTicks = this.fastSeekTicks + 1;
    const tick: number = this.fastSeekTicks;
    this.fastSeekRadius = 0;
    this.fastSeekIconAlpha = [1, 0.4, 0.4];
    animateTo({ duration: FAST_SEEK_FADE_MS, curve: Curve.EaseOut }, () => {
      this.fastSeekRadius = this.playerWidth > 0
        ? this.playerWidth / 2 : FAST_SEEK_MIN_RADIUS_VP;
      this.fastSeekIconAlpha = [0.4, 1, 1];
    });
    // The overlay is a burst, not a state: it goes when the last tap of the burst has aged out.
    setTimeout((): void => {
      if (this.fastSeekTicks === tick) {
        this.fastSeekShowing = false;
        this.fastSeekSeconds = 0;
        this.fastSeekRadius = 0;
      }
    }, FAST_SEEK_HOLD_MS);
  }

  /** A new stream starts with no burst on screen and no accumulated seconds. */
  private resetFastSeek(): void {
    this.fastSeekShowing = false;
    this.fastSeekSeconds = 0;
    this.fastSeekRadius = 0;
    this.fastSeekTicks = this.fastSeekTicks + 1;
  }

  /**
   * The cue's lines. A cue carries its own line breaks and the reference gives each line its own
   * ground; empty lines are dropped so a trailing break cannot draw an empty box.
   */
  private subtitleLines(): string[] {
    const lines: string[] = [];
    for (const line of this.subtitleText.split(String.fromCharCode(10))) {
      if (line.trim().length > 0) {
        lines.push(line);
      }
    }
    return lines;
  }

  /** onSurfaceTap(): a single tap toggles the controls - never alongside the double tap. */
  private onSingleTap(): void {
    this.controlsVisible = !this.controlsVisible;
  }

  /**
   * The left half of the surface is brightness, the right half volume, as in the source - and
   * BasePlayerGestureListener arms neither outside fullscreen. Both start from the LIVE level
   * rather than from zero, and both are actually applied.
   */
  private onVerticalSwipe(event: GestureEvent): void {
    if (!this.isFullscreen) {
      return;
    }
    const width: number = this.playerWidth > 0 ? this.playerWidth : 1;
    const height: number = this.playerHeight > 0 ? this.playerHeight : 1;
    const x: number = event.fingerList.length > 0 ? event.fingerList[0].localX : 0;
    // onScrollVolume()/onScrollBrightness() move the level BY A FRACTION OF THE FRAME, which is
    // what makes the control dialable: on the reference a 150 px drag moves the ring about a
    // quarter of its sweep. This read the offset as one percent per vp, so any drag a finger
    // actually makes - 650 px is ~186 vp - saturated the bar on its first update. Measured on
    // device before the change: every swipe, long or short, reported brightnessProgressBar
    // "100.000000". That is the case's "it cannot change the brightness".
    //
    // The downward half was not handled at all: the update returned early on a positive offset,
    // so a level could be raised and NEVER lowered. The bottom sheet is the non-fullscreen
    // layout's gesture and these swipes are armed only in fullscreen, so there was nothing to
    // yield to - onActionEnd's collapse is gated to match.
    const delta: number = -event.offsetY / (height / 2) * 100;
    // getActionForRightGestureSide() / getActionForLeftGestureSide(): each half does what the
    // user assigned it - volume, brightness, or nothing at all.
    const action: string = x / width >= 0.5
      ? PlayerPrefs.rightGestureAction() : PlayerPrefs.leftGestureAction();
    if (action === volume_control_key) {
      if (this.volumeAtGestureStart < 0) {
        // "If we just started sliding, change the progress bar to match the system volume."
        this.volumeAtGestureStart = this.readSystemVolumePercent();
      }
      this.volumeProgress =
        Math.round(Math.min(100, Math.max(0, this.volumeAtGestureStart + delta)));
      this.volumeOverlayShowing = true;
      this.brightnessOverlayShowing = false;
      const level: number = Math.round(this.systemMaxVolume * this.volumeProgress / 100);
      if (level !== this.systemVolumeLevel) {
        this.systemVolumeLevel = level;
      }
    } else if (action === brightness_control_key) {
      if (this.brightnessAtGestureStart < 0) {
        this.brightnessAtGestureStart = Math.round(this.windowBrightness * 100);
      }
      this.brightnessProgress =
        Math.round(Math.min(100, Math.max(0, this.brightnessAtGestureStart + delta)));
      this.brightnessOverlayShowing = true;
      this.volumeOverlayShowing = false;
      this.applyBrightness(this.brightnessProgress / 100);
      // PlayerHelper.setScreenBrightness(): the level is kept for the next fullscreen.
      PlayerPrefs.saveScreenBrightness(this.brightnessProgress / 100);
    }
  }

  /** audioReactor.getVolume() / getMaxVolume(), as a percentage of the media stream's range. */
  private readSystemVolumePercent(): number {
    try {
      const manager: audio.AudioVolumeGroupManager = audio.getAudioManager().getVolumeManager()
        .getVolumeGroupManagerSync(audio.DEFAULT_VOLUME_GROUP_ID);
      const max: number = manager.getMaxVolumeSync(audio.AudioVolumeType.MEDIA);
      const current: number = manager.getVolumeSync(audio.AudioVolumeType.MEDIA);
      this.systemMaxVolume = max > 0 ? max : this.systemMaxVolume;
      this.systemVolumeLevel = current;
      return max > 0 ? Math.round(current / max * 100) : 0;
    } catch (err) {
      hilog.warn(0x0000, TAG, 'system volume: %{public}s', (err as BusinessError).message);
      return Math.round(PlayerService.getInstance().currentVolume() * 100);
    }
  }

  /** onScrollVolume()'s glyph: off / mute / down / up by the level. */
  private volumeGlyph(): Resource {
    if (this.volumeProgress <= 0) {
      return $r('app.media.ic_volume_off');
    }
    if (this.volumeProgress < 25) {
      return $r('app.media.ic_volume_mute');
    }
    return this.volumeProgress < 75 ? $r('app.media.ic_volume_down') : $r('app.media.ic_volume_up');
  }

  /** onScrollBrightness()'s glyph: low / medium / high by the level. */
  private brightnessGlyph(): Resource {
    if (this.brightnessProgress < 25) {
      return $r('app.media.ic_brightness_low');
    }
    return this.brightnessProgress < 75
      ? $r('app.media.ic_brightness_medium') : $r('app.media.ic_brightness_high');
  }

  /**
   * setupBrightness(): outside fullscreen the window follows the system; in fullscreen it takes
   * back the level the last swipe left - unless neither side of the surface controls brightness.
   */
  private setupBrightness(): void {
    if (!this.isFullscreen || this.bottomSheetState !== BottomSheetState.EXPANDED) {
      this.restoreDefaultBrightness();
      return;
    }
    if (PlayerPrefs.rightGestureAction() !== brightness_control_key
      && PlayerPrefs.leftGestureAction() !== brightness_control_key) {
      return;
    }
    const saved: number = PlayerPrefs.screenBrightness();
    if (saved >= 0) {
      this.applyBrightness(saved);
    }
  }

  /** restoreDefaultBrightness(): -1 hands the window back to the system's level. */
  private restoreDefaultBrightness(): void {
    this.applyBrightness(-1);
  }

  /**
   * getScreenBrightness() / setScreenBrightness(): the level is a WINDOW property. The port
   * never touched it, which is why the overlay moved and the screen did not.
   */
  private async applyBrightness(level: number): Promise<void> {
    if (level >= 0) {
      this.windowBrightness = level;
    }
    try {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const win: window.Window = await window.getLastWindow(context);
      await win.setWindowBrightness(level);
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      hilog.warn(0x0000, TAG, 'setWindowBrightness: %{public}s', failure.message);
    }
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Builders - page sections
  ////////////////////////////////////////////////////////////////////////// */

  /** app_bar_layout > CustomCollapsingToolbarLayout > detail_thumbnail_root_layout. */
  @Builder
  thumbnailSection() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      // The dummy thumbnail Picasso shows until the real one arrives - the grey frame with a
      // darker triangle the reference shows under its play arrow. Not while loading: the frame is
      // bare window background then.
      if (!this.isLoading && !this.heroLoaded) {
        // dummy_thumbnail's #999999 ground. The SVG drawable was tried and kept its own aspect
        // inside the frame, leaving most of it black; the ground is what reads, the dark
        // triangle under it sits behind the white play arrow anyway.
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#999999')
      }
      if (shouldLoadImages()) {
        // detail_thumbnail_image_view: scaleType fitCenter over ?windowBackground, minHeight 200dp.
        Image(this.heroThumbnail)
          .id('detail_thumbnail_image_view')
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Contain)
          .backgroundColor(this.heroLoaded || this.isLoading
            ? $r('app.color.background') : Color.Transparent)
          .onComplete(() => {
            this.heroLoaded = true;
          })
      }

      // noVideoStreams -> ic_headset_shadow (audio-only presentation), else the play arrow.
      // layout_gravity="center" inside a bottom|end stack - anchored by its own midpoint.
      // showLoading() fades it out; there is nothing to play until the info arrives.
      Image(this.noVideoStreams
        ? $r('app.media.ic_headset_shadow') : $r('app.media.ic_play_arrow_shadow'))
        .id('detail_thumbnail_play_button')
        .visibility(this.isLoading ? Visibility.Hidden : Visibility.Visible)
        .width(64)
        .height(64)
        .objectFit(ImageFit.Contain)
        .position({ x: '50%', y: '50%' })
        .markAnchor({ x: '50%', y: '50%' })

      // #64000000 scrim, 30dp/10dp padding, white 20sp bold, centred.
      Text($r('app.string.hold_to_append'))
        .id('touch_append_detail')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.on_primary'))
        .backgroundColor('#64000000')
        .padding({ left: 30, right: 30, top: 10, bottom: 10 })
        .position({ x: '50%', y: '50%' })
        .markAnchor({ x: '50%', y: '50%' })
        .opacity(this.holdToAppendTipAlpha)
        .hitTestBehavior(HitTestMode.None)

      // LIVE_STREAM with no duration shows @string/duration_live instead of a time.
      // detail_duration_view: bottom|right, #23000000 at alpha .6, white 12sp bold, all caps.
      if (this.streamType === StreamType.LIVE_STREAM && this.durationTotalMs <= 0) {
        Text($r('app.string.duration_live'))
          .id('detail_duration_view')
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.on_primary'))
          .backgroundColor($r('app.color.live_duration_background_color'))
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .margin({ left: 12, right: 12, top: 8, bottom: 8 })
      } else if (this.durationBadge.length > 0) {
        Text(this.durationBadge)
          .id('detail_duration_view')
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.on_primary'))
          .backgroundColor('#23000000')
          .opacity(0.6)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .margin({ left: 12, right: 12, top: 8, bottom: 8 })
      }

      // positionView / detailPositionView are GONE when resume playback is disabled - and also
      // when there is no saved state at all: updateProgressInfo() is only ever called WITH a
      // StreamStateEntity, and the empty branch calls hideProgressInfo(). The port drew the pair
      // on the strength of the preference alone, so a stream nobody had watched - a live stream
      // among them, which never gets a state - showed a "00:00" badge and a zero-width bar under
      // the frame where the reference shows nothing.
      // TC-PLAYER-819: these badges belong to the THUMBNAIL - the resume position and the
      // duration a viewer reads before pressing play. Once the player is attached the thumbnail is
      // covered by the video surface, but this chip kept painting and stuck out BELOW the player's
      // bottom edge as a half-clipped red box, on every screen the main player opens: "the red
      // area ... should be removed. (It shows the video duration, and that indicator should not be
      // present.)" A playing stream shows its position in the transport, not in a badge.
      if (this.positionSubscriber && this.resumePositionBar > 0 && !this.playerAttached) {
        // detail_position_view: bottom|left twin of the duration badge, on ?colorPrimary.
        // The same badge as the duration, on the other corner, so the same formatting.
        // resumePositionBar is MILLISECONDS (StreamStateEntity.progressMillis) and
        // getDurationString takes seconds.
        Text(Localization.getDurationString(this.resumePositionBar / 1000))
          .id('detail_position_view')
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.on_primary'))
          .backgroundColor($r('app.color.primary'))
          .opacity(0.6)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .margin({ left: 12, right: 12, top: 8, bottom: 8 })
          .position({ x: 0, y: '100%' })
          .markAnchor({ x: 0, y: '100%' })

        // AnimatedProgressBar: 2dp tall, pinned to the bottom edge.
        Progress({
          value: this.resumePositionBar,
          total: this.durationTotalMs > 0 ? this.durationTotalMs : 1
        })
          .id('position_view')
          .width('100%')
          .height(2)
          .color($r('app.color.primary'))
          .backgroundColor($r('app.color.transparent_background_color'))
      }

      // player_placeholder: MainPlayerUi is attached here, over the thumbnail.
      Stack() {
        if (this.playerAttached) {
          this.playerView()
        }
      }
      .id('player_placeholder')
      .width('100%')
      .height('100%')
      .opacity(this.thumbnailBeat ? 0 : 1)
    }
    .id('detail_thumbnail_root_layout')
    .width('100%')
    // android:background="@android:color/black"; the image inside declares minHeight 200dp.
    // In fullscreen the frame IS the page: build() hangs it straight off detail_main_content,
    // so '100%' resolves against the whole screen rather than against the scroll's viewport.
    .height(this.isFullscreen ? '100%' : PLAYER_FRAME_VP)
    .backgroundColor($r('app.color.black'))
    // detail_thumbnail_root_layout's listener is the PRE-PLAYBACK thumbnail's. Once the player
    // is attached, player.xml is on top of it and owns every tap - without this guard the two
    // were stacked and the root re-entered openVideoPlayer on taps meant for the surface.
    .onClick(() => {
      if (!this.playerAttached) {
        this.openVideoPlayerAutoFullscreen();
      }
    })
  }

  /** detail_root: the uploader row and the details panel. */
  @Builder
  uploaderSection() {
    // detail_root is a 55dp RelativeLayout: the uploader fills the row, details_panel is pinned
    // to its end (layout_alignParentEnd), so the two sit side by side, not stacked.
    Row() {
      Row() {
        Stack({ alignContent: Alignment.BottomEnd }) {
          // CircularImageView shapeAppearance: video_item_detail_uploader_image_size = 32dp.
          Image(this.channelAvatar(0))
            .id('detail_sub_channel_thumbnail_view')
            .width(32)
            .height(32)
            .borderRadius(16)
            .objectFit(ImageFit.Cover)
          // GONE when the sub-channel name is empty (displayUploaderAsSubChannel).
          // video_item_detail_sub_channel_image_size = 16dp, gravity bottom|right.
          if (this.subChannelName.length > 0) {
            Image(this.channelAvatar(1))
              .id('detail_uploader_thumbnail_view')
              .width(16)
              .height(16)
              .borderRadius(8)
              .objectFit(ImageFit.Cover)
          }
        }

        Column() {
          Text(this.uploaderSubChannelName)
            .id('detail_sub_channel_text_view')
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.on_surface'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(this.subscriberCount)
            .id('detail_uploader_text_view')
            .fontSize(12)
            .fontColor($r('app.color.on_surface_variant'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .justifyContent(FlexAlign.Center)
        .margin({ left: 8 })
      }
      .id('detail_uploader_root_layout')
      .layoutWeight(1)
      .height('100%')
      .padding(6)
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.openChannel(false);
      })
      .gesture(LongPressGesture().onAction(() => {
        // Long press opens the PARENT uploader channel, and only when there is a sub-channel:
        // without one this row already is the uploader, and the source does nothing.
        const info: StreamInfo | null = this.currentInfo;
        if (info !== null && info.subChannelUrl.length > 0) {
          this.openChannel(true);
        }
      }))

      // details_panel: the view count centred over the like / dislike row, 6dp side padding.
      Column() {
        Text(this.viewCount)
          .id('detail_view_count_view')
          .fontSize(13)
          .fontColor($r('app.color.on_surface'))
          .maxLines(1)
          .margin({ top: 6, bottom: 6 })

        // updateDetails(): with ratings disabled both icons show over the hint; otherwise an
        // icon whose count is unknown (< 0) is not shown. YouTube no longer publishes dislikes,
        // so the thumbs-down is unknown on every YouTube video and live stream - the port drew
        // the icon regardless, with nothing beside it. It is HIDDEN rather than removed, so it
        // keeps its space and the like count above the view count does not shift.
        Row() {
          if (this.ratingsDisabled() || this.likeText().length > 0) {
            Image($r('app.media.ic_thumb_up'))
              .id('detail_thumbs_up_img_view')
              .width(18)
              .height(18)
              .fillColor($r('app.color.on_surface_variant'))
          }
          if (!this.ratingsDisabled() && this.likeText().length > 0) {
            Text(this.likeText())
              .id('detail_thumbs_up_count_view')
              .fontSize(12)
              .fontColor($r('app.color.on_surface'))
              .maxLines(1)
              .margin({ left: 5 })
          }

          Image($r('app.media.ic_thumb_down'))
            .id('detail_thumbs_down_img_view')
            .width(18)
            .height(18)
            .fillColor($r('app.color.on_surface_variant'))
            .margin({ left: 12 })
            .visibility(this.ratingsDisabled() || this.dislikeText().length > 0
              ? Visibility.Visible : Visibility.Hidden)
          if (!this.ratingsDisabled() && this.dislikeText().length > 0) {
            Text(this.dislikeText())
              .id('detail_thumbs_down_count_view')
              .fontSize(12)
              .fontColor($r('app.color.on_surface'))
              .maxLines(1)
              .margin({ left: 5 })
          }

          if (this.ratingsDisabled()) {
            Text($r('app.string.disabled'))
              .id('detail_thumbs_disabled_view')
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.on_surface'))
              .margin({ left: 12 })
          }
        }
        .alignItems(VerticalAlign.Center)
      }
      .id('details_panel')
      .padding({ left: 6, right: 6 })
      .alignItems(HorizontalAlign.Center)
      .justifyContent(FlexAlign.Center)
    }
    .id('detail_root')
    .width('100%')
    .height(55)
    // layout_margin 12dp / 12dp / 6dp, taken inside the 100% width so nothing overflows.
    .padding({ left: 12, right: 12 })
    .margin({ top: 6 })
    .alignItems(VerticalAlign.Center)
  }

  /** detail_control_panel + detail_secondary_control_panel. */
  @Builder
  controlPanels() {
    Column() {
      Row() {
        // Every control is one NewPipeTextView with drawableTop: the glyph above a 12sp label,
        // in an 80dp x 55dp weight-1 cell with 6dp vertical padding. The id and the click stay
        // on the cell (the outermost tappable container), never on the label.
        Column() {
          Image($r('app.media.ic_playlist_add'))
            .width(24)
            .height(24)
            .fillColor($r('app.color.on_surface'))
          Text($r('app.string.controls_add_to_playlist_title'))
            .fontSize(12)
            .fontColor($r('app.color.on_surface'))
            .maxLines(1)
            .textAlign(TextAlign.Center)
        }
        .id('detail_controls_playlist_append')
        .layoutWeight(1)
        .height(55)
        .padding({ top: 6, bottom: 6 })
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.openPlaylistDialog();
        })

        // GONE when the stream has neither audio nor video streams.
        if (this.hasAudioOrVideo()) {
          Column() {
            Image($r('app.media.ic_headset'))
              .width(24)
              .height(24)
              .fillColor($r('app.color.on_surface'))
            Text($r('app.string.controls_background_title'))
              .fontSize(12)
              .fontColor($r('app.color.on_surface'))
              .maxLines(1)
              .textAlign(TextAlign.Center)
          }
          .id('detail_controls_background')
          .layoutWeight(1)
          .height(55)
          .padding({ top: 6, bottom: 6 })
          .justifyContent(FlexAlign.Center)
          .onClick(() => {
            this.openBackgroundPlayer();
          })
          .onTouch((event: TouchEvent) => {
            this.flashHoldToAppendTip(event);
          })
          .gesture(LongPressGesture().onAction(() => {
            this.enqueueOnPlayer(true);
          }))
        }

        // GONE when there is no video stream at all (audio-only presentation).
        if (!this.noVideoStreams) {
          Column() {
            Image($r('app.media.ic_picture_in_picture'))
              .width(24)
              .height(24)
              .fillColor($r('app.color.on_surface'))
            Text($r('app.string.controls_popup_title'))
              .fontSize(12)
              .fontColor($r('app.color.on_surface'))
              .maxLines(1)
              .textAlign(TextAlign.Center)
          }
          .id('detail_controls_popup')
          .layoutWeight(1)
          .height(55)
          .padding({ top: 6, bottom: 6 })
          .justifyContent(FlexAlign.Center)
          .onClick(() => {
            this.openPopupPlayer();
          })
          .onTouch((event: TouchEvent) => {
            this.flashHoldToAppendTip(event);
          })
          .gesture(LongPressGesture().onAction(() => {
            this.enqueueOnPlayer(false);
          }))
        }

        // StreamTypeUtil.isLiveStream(streamType) -> the Download button is GONE.
        if (this.streamType !== StreamType.LIVE_STREAM
          && this.streamType !== StreamType.AUDIO_LIVE_STREAM) {
          Column() {
            Image($r('app.media.ic_file_download'))
              .width(24)
              .height(24)
              .fillColor($r('app.color.on_surface'))
            Text($r('app.string.download'))
              .fontSize(12)
              .fontColor($r('app.color.on_surface'))
              .maxLines(1)
              .textAlign(TextAlign.Center)
          }
          .id('detail_controls_download')
          .layoutWeight(1)
          .height(55)
          .padding({ top: 6, bottom: 6 })
          .justifyContent(FlexAlign.Center)
          .onClick(() => {
            // openDownloadDialog(): `if (currentInfo == null) { return; }` - the source opens
            // nothing before the stream info has arrived.
            if (this.currentInfo === null) {
              return;
            }
            this.openDownloadFor(this.serviceId, this.url);
          })
          .gesture(LongPressGesture().onAction(() => {
            router.pushUrl({ url: 'pages/DownloadActivityPage' });
          }))
        }
      }
      .id('detail_control_panel')
      .width('100%')
      .padding(6)
      .alignItems(VerticalAlign.Center)

      if (this.secondaryControlsShown) {
        Row() {
          Column() {
            Image($r('app.media.ic_share'))
              .width(24)
              .height(24)
              .fillColor($r('app.color.on_surface'))
            Text($r('app.string.share'))
              .fontSize(12)
              .fontColor($r('app.color.on_surface'))
              .maxLines(1)
              .textAlign(TextAlign.Center)
          }
          .id('detail_controls_share')
          .layoutWeight(1)
          .height(55)
          .padding({ top: 6, bottom: 6 })
          .justifyContent(FlexAlign.Center)
          .onClick(() => {
            this.shareStream();
          })

          Column() {
            Image($r('app.media.ic_language'))
              .width(24)
              .height(24)
              .fillColor($r('app.color.on_surface'))
            Text($r('app.string.open_in_browser'))
              .fontSize(12)
              .fontColor($r('app.color.on_surface'))
              .maxLines(1)
              .textAlign(TextAlign.Center)
          }
          .id('detail_controls_open_in_browser')
          .layoutWeight(1)
          .height(55)
          .padding({ top: 6, bottom: 6 })
          .justifyContent(FlexAlign.Center)
          .onClick(() => {
            this.openInBrowser();
          })

          // KoreUtils.shouldShowPlayWithKodi(ctx, serviceId): the preference AND a service Kore
          // can take. The comment said so and the guard was never written, so the control was
          // drawn on every stream - Android, whose show_play_with_kodi defaults to false, shows
          // nothing there.
          if (this.kodiAvailableForStream()) {
          Column() {
            Image($r('app.media.ic_cast'))
              .width(24)
              .height(24)
              .fillColor($r('app.color.on_surface'))
            Text($r('app.string.play_with_kodi_title'))
              .fontSize(12)
              .fontColor($r('app.color.on_surface'))
              .maxLines(1)
              .textAlign(TextAlign.Center)
          }
          .id('detail_controls_play_with_kodi')
          .layoutWeight(1)
          .height(55)
          .padding({ top: 6, bottom: 6 })
          .justifyContent(FlexAlign.Center)
          .onClick(() => {
            this.playWithKodi();
          })
          }

          // DEBUG + show_crash_the_player_key only; never visible in a release build.
          Column() {
            Image($r('app.media.ic_bug_report'))
              .width(24)
              .height(24)
              .fillColor($r('app.color.on_surface'))
            Text($r('app.string.crash_the_player'))
              .fontSize(12)
              .fontColor($r('app.color.on_surface'))
              .maxLines(1)
              .textAlign(TextAlign.Center)
          }
          .id('detail_controls_crash_the_player')
          .layoutWeight(1)
          .height(55)
          .padding({ top: 6, bottom: 6 })
          .justifyContent(FlexAlign.Center)
          .visibility(Visibility.None)
        }
        .id('detail_secondary_control_panel')
        .width('100%')
        .padding({ left: 6, right: 6, bottom: 6 })
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
  }

  /** error_panel.xml, included by fragment_video_detail as @+id/error_panel. */
  @Builder
  errorPanel() {
    Column() {
      // error_panel.xml: 16dp padding, centred, 16sp - bold / plain / italic in that order.
      Text(this.lastPanelError)
        .id('error_message_view')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.on_surface'))
        .textAlign(TextAlign.Center)
        .width('100%')
      Text('')
        .id('error_message_service_info_view')
        .fontSize(16)
        .fontColor($r('app.color.on_surface'))
        .textAlign(TextAlign.Center)
        .width('100%')
      Text('')
        .id('error_message_service_explanation_view')
        .fontSize(16)
        .fontStyle(FontStyle.Italic)
        .fontColor($r('app.color.on_surface_variant'))
        .textAlign(TextAlign.Center)
        .width('100%')

      // ErrorPanelHelper: a reCaptcha challenge is solved in the WebView page, anything else
      // reportable goes to the error report screen.
      Button($r('app.string.error_snackbar_action'))
        .id('error_action_button')
        .fontSize(16)
        .fontColor($r('app.color.on_primary'))
        .backgroundColor($r('app.color.primary'))
        .margin({ top: 12 })
        .onClick(() => {
          this.runErrorAction();
        })

      // isRetryable(): the retry entry exists only when retrying can help.
      if (this.errorInfo === null || this.errorInfo.isRetryable) {
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

      // ErrorPanelHelper.showError(): the entry exists only when the error carries a url -
      //     if (errorInfo.openInBrowserUrl != null) { errorOpenInBrowserButton.isVisible = true }
      // - and it opens THAT url, not the loaded stream's. On a failed load there is no loaded
      // stream, which is exactly when this button matters.
      if (this.errorInfo !== null && this.errorInfo.openInBrowserUrl !== null) {
        Button(Localization.buttonLabel('open_in_browser'))
          .id('error_open_in_browser')
          .fontSize(16)
          .fontColor($r('app.color.on_primary'))
          .backgroundColor($r('app.color.primary'))
          .margin({ top: 12 })
          .onClick(() => {
            this.openErrorUrlInBrowser();
          })
      }
    }
    .id('error_panel')
    .width('100%')
    .padding(16)
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * ErrorPanelHelper's action entry: a ReCaptchaException opens the challenge page (which is
   * what makes the next extractor call stop returning 429), everything else is reported.
   */
  private runErrorAction(): void {
    const info: ErrorInfo | null = this.errorInfo;
    if (info !== null && info.recaptchaUrl !== null) {
      router.pushUrl({
        url: 'pages/ReCaptchaActivityPage',
        params: new ItemParams(this.serviceId, info.recaptchaUrl, this.name)
      });
      return;
    }
    if (info === null) {
      router.pushUrl({ url: 'pages/ErrorActivityPage' });
      return;
    }
    ServiceLocator.get().errorReporter.openActivity(info);
  }

  /** overlay_layout: the collapsed bottom-sheet mini player. */
  @Builder
  miniPlayerOverlayBar() {
    Column() {
    Row() {
      // overlay_thumbnail: 62dp x 60dp ImageButton, fitCenter, 12dp side padding, transparent.
      Image(this.miniPlayerOverlay.thumbnailUrl)
        .id('overlay_thumbnail')
        .width(62)
        .height(60)
        .objectFit(ImageFit.Contain)
        .padding({ left: 12, right: 12 })
        .backgroundColor($r('app.color.transparent_background_color'))
        .onClick(() => {
          this.expandSheet();
        })
        .gesture(LongPressGesture().onAction(() => {
          this.openChannel(true);
        }))

      Column() {
        // video_item_search_title_text_size = 14sp / uploader = 11sp, both single-line marquee.
        Text(this.miniPlayerOverlay.title)
          .id('overlay_title_text_view')
          .fontSize(14)
          .fontColor($r('app.color.on_surface'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.miniPlayerOverlay.channel)
          .id('overlay_channel_text_view')
          .fontSize(11)
          .fontColor($r('app.color.on_surface_variant'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .id('overlay_metadata_layout')
      .layoutWeight(1)
      .height(60)
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.expandSheet();
      })
      .gesture(LongPressGesture().onAction(() => {
        this.openChannel(true);
      }))

      // 40dp / 40dp / 48dp full-height ImageButtons, glyph centred, ContrastTintTheme.
      Row() {
        Image($r('app.media.ic_list'))
          .id('overlay_play_queue_button')
          .accessibilityText($r('app.string.title_activity_play_queue'))
          .width(40)
          .height(60)
          .padding(8)
          .objectFit(ImageFit.Contain)
          .fillColor($r('app.color.on_surface'))
          .onClick(() => {
            router.pushUrl({ url: 'pages/PlayQueueActivityPage' });
          })

        Image(this.playerStatus === PlayerStatus.PLAYING
          ? $r('app.media.ic_pause') : $r('app.media.ic_play_arrow'))
          .id('overlay_play_pause_button')
          .accessibilityText(this.playerStatus === PlayerStatus.PLAYING
            ? $r('app.string.pause') : $r('app.string.play'))
          .width(40)
          .height(60)
          .padding(8)
          .objectFit(ImageFit.Contain)
          .fillColor($r('app.color.on_surface'))
          .onClick(() => {
            PlayerService.getInstance().togglePlayPause();
          })

        Image($r('app.media.ic_close'))
          .id('overlay_close_button')
          .accessibilityText($r('app.string.close'))
          .width(48)
          .height(60)
          .padding({ left: 8, right: 16, top: 8, bottom: 8 })
          .objectFit(ImageFit.Contain)
          .fillColor($r('app.color.on_surface'))
          .onClick(() => {
            this.closePlayer();
          })
      }
      .id('overlay_buttons_layout')
      .height(60)
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.expandSheet();
      })
    }
    .id('overlay_layout')
    .width('100%')
    // android:alpha="0.9" over ?attr/windowBackground, 60dp of bar.
    .height(60)
    .alignItems(VerticalAlign.Center)
    .opacity(0.9)
    .backgroundColor(themedBackground(this.blackTheme))

      // @+id/overlay_play_pause_button's companion: the thin position bar along the foot of
      // the collapsed overlay. There was no indicator on the bar at all.
      Progress({
        value: this.positionMs,
        total: this.durationMs > 0 ? this.durationMs : 1
      })
        .id('overlay_position_view')
        .width('100%')
        .height(2)
        .color($r('app.color.primary'))
        .backgroundColor($r('app.color.transparent_background_color'))
    }
    .width('100%')
    // BottomSheetBehavior on the collapsed sheet: dragged up it expands (FL-187), dragged down it
    // goes to STATE_HIDDEN, whose cleanUp() stops the player - the close button's effect (FL-188).
    .gesture(PanGesture({ direction: PanDirection.Vertical })
      .onActionEnd((event: GestureEvent) => {
        if (event.offsetY < -COLLAPSE_FLING_MIN_VP) {
          this.expandSheet();
        } else if (event.offsetY > COLLAPSE_FLING_MIN_VP) {
          this.closePlayer();
        }
      }))
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Render
  ////////////////////////////////////////////////////////////////////////// */

  /**
   * onKeyDown/onBackPressed: fullscreen is left first, then the fragment's OWN stack is popped
   * and the previous video re-rendered in place; only an empty stack leaves the screen.
   */
  onBackPress(): boolean {
    if (this.isFullscreen) {
      // onBackPressed(): "exit from it via first back press" - and on a phone the source pauses
      // the player too (`if (!DeviceUtils.isTablet(activity)) player.pause()`). The fullscreen
      // BUTTON only toggles the layout; it is this Back that stops the video.
      if (!PlayerPrefs.isTablet()) {
        PlayerService.getInstance().pause();
      }
      this.toggleFullscreen();
      return true;
    }
    if (this.stack.length > 0) {
      const previous: ItemParams = this.stack[this.stack.length - 1];
      this.stack = this.stack.slice(0, this.stack.length - 1);
      this.loadItem(previous);
      return true;
    }
    return false;
  }

  build() {
    // A Column, not a Stack: COLLAPSED RESTRUCTURES the page. The overlay bar used to be
    // stacked over a detail_main_content that was still rendering its 200vp player frame
    // underneath, so the "mini player" was a bar drawn on top of the full player. Now the
    // frame is not built at all while the sheet is collapsed and the bar is the last row.
    Column() {
      // detail_main_content: the CoordinatorLayout.
      Column() {
        // hideAgeRestrictedContent(): an age-restricted stream with the preference off is
        // replaced ENTIRELY by showTextError(@string/restricted_video) - no metadata, no
        // tabs, no player.
        if (this.ageLimit !== NO_AGE_LIMIT && !this.showAgeRestrictedContent) {
          Text($r('app.string.restricted_video'))
            .id('empty_state_view')
            .width('100%')
            .fontSize(14)
            .fontColor($r('app.color.on_surface_variant'))
            .textAlign(TextAlign.Center)
            .padding(16)
            .margin({ top: 50 })
        } else if (this.isFullscreen) {
          // Fullscreen: the player IS the page. Nothing else is laid out, which is what makes
          // '100%' on detail_thumbnail_root_layout resolve against the whole screen.
          this.thumbnailSection()
        } else {
          // THE 840vp BRANCH IS A SIDE PANEL, so the two halves have to sit in a Row. They used to
          // be siblings in this page's vertical Column, and the panel carried width('100%'), which
          // put Related Items UNDERNEATH the content - the one thing the breakpoint exists to
          // change. A Flex whose direction follows the breakpoint keeps the phone path identical
          // by construction: below 840vp relatedItemsLayout is false, the direction is Column, and
          // the panel is not emitted at all.
          Flex({
            direction: this.relatedItemsLayout ? FlexDirection.Row : FlexDirection.Column
          }) {
          Column() {
          Scroll(this.detailScroller) {
            Column() {
              // While the sheet is collapsed the player lives in the overlay bar at the bottom
              // of the page, so the frame is not rendered here at all.
              if (this.bottomSheetState === BottomSheetState.EXPANDED) {
                this.thumbnailSection()
              }

              // detail_content_root_layout.
              Column() {
                Row() {
                  // video_item_detail_title_text_size = 15sp, paddingTop 12dp / bottom 8dp,
                  // marginEnd 30dp for the chevron; ellipsized at one line until expanded.
                  Text(this.title)
                    .id('detail_video_title_view')
                    .fontSize(15)
                    .fontColor($r('app.color.on_surface'))
                    .maxLines(this.secondaryControlsShown ? 10 : 1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .padding({ top: 12, bottom: 8 })
                    .margin({ right: 30 })
                    .layoutWeight(1)
                  // 20dp glyph, gravity top|end, marginTop 11dp / marginEnd 10dp. showLoading()
                  // sets it GONE; handleResult() brings it back.
                  if (!this.isLoading) {
                    Image($r('app.media.ic_expand_more'))
                      .id('detail_toggle_secondary_controls_view')
                      .width(20)
                      .height(20)
                      .fillColor($r('app.color.on_surface'))
                      .margin({ top: 11, right: 10 })
                      .rotate({ angle: this.secondaryControlsShown ? 180 : 0 })
                  }
                }
                .id('detail_title_root_layout')
                .accessibilityText(this.secondaryControlsShown
                  ? $r('app.string.show_less') : $r('app.string.show_more'))
                .width('100%')
                .padding({ left: 12 })
                .alignItems(VerticalAlign.Top)
                .onClick(() => {
                  // detailTitleRootLayout.setClickable(false) for the length of showLoading().
                  if (!this.isLoading) {
                    this.toggleTitleAndSecondaryControls();
                  }
                })
                .gesture(LongPressGesture().onAction(() => {
                  const info: StreamInfo | null = this.currentInfo;
                  if (info !== null) {
                    this.share().copyToClipboard(info.getName());
                  }
                }))

                if (this.isLoading) {
                  // layout_marginTop = video_item_detail_error_panel_margin (50dp), centred.
                  // What the reference shows in this slot, measured on device across the whole
                  // load: a static 48dp refresh glyph in ?colorPrimary (32dp of ink), not a
                  // spinning ring.
                  Image($r('app.media.ic_refresh'))
                    .id('loading_progress_bar')
                    .width(48)
                    .height(48)
                    .fillColor($r('app.color.primary'))
                    .margin({ top: 50 })
                }

                if (this.lastPanelError.length > 0) {
                  this.errorPanel()
                }

                // detail_content_root_hiding: everything the error panel replaces - on a LOAD
                // failure only. A player error is the player's (VideoDetailFragment.onPlayerError
                // hides the player, not the page): the uploader row and the Add to / Background /
                // Popup / Download buttons are page controls and stay under the panel.
                if (this.errorInfo === null) {
                  Column() {
                    this.uploaderSection()
                    this.controlPanels()

                    if (this.metaInfoBanner.length > 0) {
                      // 1px separator inset 8dp on both sides, on ?attr/separator_color.
                      Divider()
                        .id('detail_meta_info_separator')
                        .color($r('app.color.separator'))
                        .strokeWidth(1)
                        .margin({ left: 8, right: 8 })
                      // TextLinkifier.fromHtml(..., SET_LINK_MOVEMENT_METHOD): each link is a
                      // UrlLongPressClickableSpan - a tap opens it, a long press copies it. Keyed
                      // on the text: another stream on this page builds a fresh view, as
                      // NewPipeTextView reads its content once.
                      ForEach([this.metaInfoBanner], (banner: string) => {
                        Column() {
                          NewPipeTextView({
                            slug: 'detail_meta_info_text_view',
                            content: banner,
                            linkSpans: this.metaInfoSpans,
                            textSizeFp: 13,
                            textAlignment: TextAlign.Center,
                            onLinkTapped: (span: LinkSpan): void => {
                              const url: string | null = span.url;
                              if (url !== null) {
                                openUrlLink(url);
                              }
                            },
                            onLinkLongPressed: (span: LinkSpan): void => {
                              this.share().copyToClipboard(linkTextToCopy(span, -1, ''));
                            }
                          })
                        }
                        .padding(12)
                        .width('100%')
                      }, (banner: string) => banner)
                      Divider()
                        .color($r('app.color.separator'))
                        .strokeWidth(1)
                        .margin({ left: 8, right: 8 })
                    }
                  }
                  .id('detail_content_root_hiding')
                  .visibility(this.contentHidingVisible ? Visibility.Visible : Visibility.Hidden)
                  .width('100%')
                  .padding({ bottom: 10 })
                }
              }
              .id('detail_content_root_layout')
              .width('100%')
              // BottomSheetBehavior drags the whole sheet, not only the player: pulling the
              // title / channel / action rows down while the page is at its top collapses it into
              // the mini player too. Parallel, so the page still scrolls under the same finger;
              // a drag that began with the page scrolled is a scroll back up, never a collapse.
              // The related-items pager below is left out: its list scrolls on its own.
              .parallelGesture(
                PanGesture({ direction: PanDirection.Down })
                  .onActionStart(() => {
                    this.dragStartedAtTop = this.detailScroller.currentOffset().yOffset <= 0;
                  })
                  .onActionEnd((event: GestureEvent) => {
                    if (this.dragStartedAtTop && !this.isFullscreen
                      && this.bottomSheetState === BottomSheetState.EXPANDED
                      && this.isCollapseDrag(event)) {
                      this.collapseToPreviousScreen();
                    }
                    this.dragStartedAtTop = false;
                  })
              )

              // view_pager - TabAdapter owns that id, as it does on every pager host.
              //
              // INSIDE the scroller, one viewport tall. The pager used to be a SIBLING of the
              // scroller, each holding layoutWeight(1): two independent scroll regions splitting
              // the screen, so the action row scrolled under a scrollbar of its own while the
              // strip below it stood still. The source has ONE scroll - detail_content_root_layout
              // sits in the AppBarLayout with scroll flags and the pager's list is its
              // NestedScrollingChild, which is why swiping the comments collapses the header.
              // A viewport-tall page plus PARENT_FIRST on the child lists is that, in ArkUI terms.
              Column() {
                TabAdapter({
                  count: this.tabPager.length,
                  selectedIndex: $selectedTab
                }) {
                  this.pagerPages()
                }
              }
              .width('100%')
              .height(this.pagerViewportVp)
            }
            .width('100%')
          }
          .layoutWeight(1)
          .align(Alignment.Top)
          // The reference's CoordinatorLayout draws no scrollbar down the page.
          .scrollBar(BarState.Off)
          .onAreaChange((oldValue: Area, newValue: Area) => {
            // The scroller's own height IS the viewport the pager has to fill.
            this.pagerViewportVp = Number(newValue.height);
          })
          .onDidScroll((xOffset: number, yOffset: number, scrollState: ScrollState) => {
            this.onDetailScrolled();
          })

          // tab_layout is GONE while the pager holds fewer than two pages; the id belongs to the
          // HOST, because ScrollableTabLayout is reused by MainFragment under a different slug.
          // It sits BELOW the pager, not between the detail content and it: the strip is the
          // page's bottom bar, which is where it is on Android and where the cases look for it.
          // The CONTAINER goes with its contents in fullscreen, not just the strip inside it.
          // Hiding only the strip left this Column in the tree with its ?attr/windowBackground
          // ground and its 16dp shadow still painted: a pale band across the foot of an
          // otherwise edge-to-edge video, which is the "white area at the bottom of the screen"
          // this case reports. The reference's fullscreen is black from edge to edge.
          if (!this.isFullscreen) {
          Column() {
            // GONE below two pages and on a load failure's error panel.
            if (this.tabPager.length > 1 && this.errorInfo === null) {
              ScrollableTabLayout({
                titles: this.tabTitles,
                // updateTabsIconAndDescription(): an icon-only strip whose label survives as
                // the content description, which is what tabIcons() below supplies.
                icons: this.tabIcons(),
                // The strip is not a service-coloured app bar down here - it is the page's
                // bottom bar, on app:tabBackground="?attr/windowBackground" with glyphs in the
                // foreground colour. A black ground with white glyphs was this port's own
                // invention and read as a black bar under the content.
                tabBackground: $r('app.color.background'),
                tabIconTint: $r('app.color.on_surface'),
                // This strip is the page's bottom bar, so its indicator runs along the TOP edge,
                // against the content it belongs to - measured on the reference at the first row
                // of the strip, not its last.
                indicatorOnTop: true,
                selectedIndex: $selectedTab
              })
            }
          }
          .id('tab_layout')
          .width('100%')
          // app:tabBackground="?attr/windowBackground", elevation 16dp above the pager.
          .backgroundColor(themedBackground(this.blackTheme))
          .shadow({ radius: 16, color: $r('app.color.shadow_start') })
          }
          }
          // The content half: everything the phone shows, keeping the majority of the width.
          .layoutWeight(1)
          .height('100%')

          // layout-large-land: relatedItemsLayout is non-null, so RelatedItemsFragment lives in
          // a permanent side panel instead of a pager tab - and is INVISIBLE while fullscreen.
          if (this.relatedItemsLayout) {
            Column() {
              if (!this.isFullscreen) {
                RelatedItemsFragmentPage({
                  hostServiceId: this.relatedServiceId(),
                  hostUrl: this.relatedUrl(),
                  hostRelatedItems: this.relatedItems()
                })
              }
            }
            .id('relatedItemsLayout')
            // 32% is CHOSEN, not measured: no wide Android device was available to compare the
            // reference's layout-large-land proportions against. It leaves the video the majority
            // of the width, which is the shape the reference has.
            .width(RELATED_PANEL_WIDTH)
            .height('100%')
          }
          }
          .width('100%')
          .height('100%')
        }
      }
      .id('detail_main_content')
      .width('100%')
      .layoutWeight(1)

      // The mini player REPLACES the player frame while the bottom sheet is collapsed or
      // hidden - a real 60vp row at the foot of the page, under the content, not over it.
      if (this.bottomSheetState !== BottomSheetState.EXPANDED) {
        this.miniPlayerOverlayBar()
      }
    }
    .id('VideoDetailFragmentPage')
    .width('100%')
    .height('100%')
    // video_item_detail's root FrameLayout: android:background="?attr/windowBackground".
    .backgroundColor(themedBackground(this.blackTheme))
    // binding.relatedItemsLayout exists only on the large-land layout, which is what this
    // breakpoint stands for; on a phone it stays null and Related is a pager tab.
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.relatedItemsLayout = Number(newValue.width) >= 840;
    })
  }
}
