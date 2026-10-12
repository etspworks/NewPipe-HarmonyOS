/**
 * S4 - DownloadDialog (screen_download_dialog). presentation: modal.
 *
 * NOT a routed page: an OVERLAY whose hostScreen is screen_video_detail, mounted by
 * VideoDetailFragmentPage on the TAP of detail_controls_download (the long press stays
 * openDownloads()). RouterActivityPage and PlayQueueActivityPage open the same dialog from their
 * own menus; both already carry their own slot and are NOT this call's files. It is deliberately
 * absent from main_pages.json and must never be pushed.
 *
 * Structure read verbatim off download_dialog.xml + DownloadDialog.java (codegraph):
 *  - toolbar_layout: title download_dialog_title, navigationIcon ic_arrow_back whose
 *    contentDescription is R.string.cancel and whose listener is dismiss(), plus the
 *    R.id.okay menu item. okay is `setEnabled(false)` until the DownloadManagerService
 *    connection lands and is re-enabled in onServiceConnected - that guard is the source's own,
 *    modelled by downloadServiceConnected below and set in S4.
 *  - file_name seeded from FilenameUtils.createFilename(ctx, currentInfo.getName()), auto-
 *    rewritten by onItemSelectedSetFileName() ONLY while the user has not edited it.
 *  - video_audio_group (video_button / audio_button / subtitle_button): each RadioButton is
 *    HIDDEN when its stream list is empty (setupDownloadOptions:653-657) and each swaps which
 *    spinner is shown. Those are the plan's conditionalVariants, built here as real `if`s.
 *  - The four spinner visibilities are the source's own, verbatim
 *    (setupAudioSpinner / setupVideoSpinner / onVideoStreamSelected / setupSubtitleSpinner):
 *      AUDIO    quality GONE, audio_stream VISIBLE, audio_track VISIBLE iff >1 track,
 *               audio_track_present_in_video_text GONE
 *      VIDEO    quality VISIBLE, audio_stream GONE, and per the SELECTED stream:
 *               audio_track VISIBLE iff isVideoOnly && >1 track,
 *               the note VISIBLE iff !isVideoOnly && >1 track
 *      SUBTITLE quality VISIBLE, everything else GONE
 *  - A Spinner is a custom-adapter dropdown, not a plain text picker: its rows are
 *    stream_quality_item (comp_stream_item_adapter) and, for the tracks,
 *    comp_audio_track_adapter. The open list is HEIGHT-BOUNDED so a long stream list cannot push
 *    the dialog's own buttons off-frame.
 *  - threads (SeekBar, max 31) writes progress+1 to prefs default_download_threads and updates
 *    threads_count; it is DISABLED for subtitles and forced to 1.
 *
 * The overwrite and failure AlertDialogs are separate windows in the source, so they REPLACE the
 * dialog body here rather than sitting beside it - that also keeps the two contract controls
 * both spelled `Cancel` from ever coexisting in one tree (ids must be unique per page).
 *
 * navOut: present -> screen_custom_file_picker. That screen is presentation: page with its own
 * routeUrl, so per the Stage-0 convention it is a router.pushUrl, wired on okay -> the
 * prepareSelectedDownload() folder/save-as picker (StoredDirectoryHelper.getPicker /
 * StoredFileHelper.getNewPicker -> FilePickerActivityHelper). phase2-logic-contract §2.4 routes
 * the PRIMARY pick through @kit.CoreFileKit DocumentViewPicker in S4; this page is the fallback
 * path's origin.
 *
 * S4 binds every spinner to StreamInfo through svc_extractor - never a literal option list;
 * S5/S6 own every colour, size and glyph.
 */
import { formatBytes } from '../common/text/ByteFormat';
import { promptAction, router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { StreamItemAdapter, StreamItemEntry } from '../components/StreamItemAdapter';
import { AudioTrackGroup, audioTrackName } from '../components/AudioTrackAdapter';
import { AudioStream } from '../model/extractor/AudioStream';
import { VideoStream } from '../model/extractor/VideoStream';
import { SubtitlesStream } from '../model/extractor/SubtitlesStream';
import { ItagItem } from '../common/extractor/core/ItagItem';
import { StreamInfo } from '../model/extractor/StreamInfo';
import { MissionState } from '../model/enums/MissionState';
import { DownloadMission, MissionRecoveryInfo } from '../model/app/DownloadMission';
import { ExtractorHelper } from '../common/extractor/ExtractorHelper';
import { DownloadManager } from '../common/download/DownloadManager';
import { FileAccess, StoredDirectory, StoredFile, TAG_AUDIO, TAG_VIDEO } from '../common/file/FileAccess';
import {
  charset_letters_and_digits_value, charset_most_special_value,
  prefer_descriptive_audio_key, prefer_original_audio_key, settings_file_charset_key,
  settings_file_replacement_character_default_value, settings_file_replacement_character_key
} from '../common/prefs/SettingsKeys';
import { PlayerPrefs } from '../common/player/PlayerPrefs';
import {
  getAudioFormatComparator, getAudioIndexByHighestRank, getAudioStreamFor,
  getAudioTrackComparator, getDefaultResolutionIndex, getSortedStreamVideosList
} from '../common/util/ListHelper';
import {
  ALGORITHM_M4A_NO_DASH, ALGORITHM_MP4_FROM_DASH_MUXER, ALGORITHM_OGG_FROM_WEBM_DEMUXER,
  ALGORITHM_TTML_CONVERTER, ALGORITHM_WEBM_MUXER
} from '../common/download/postprocessing/Postprocessing';
import { Localization } from '../common/i18n/Localization';
import { PermissionHelper } from '../common/perm/PermissionHelper';
import { ServiceLocator } from '../common/di/ServiceLocator';
import { AppPreferences } from '../common/prefs/Preferences';
import { Stream } from '../model/extractor/Stream';
import { MediaFormat } from '../model/enums/MediaFormat';
import { NewPipe } from '../common/extractor/core/NewPipe';
import { Localization as ExtractorLocalization } from '../common/extractor/downloader/Localization';
import { intl } from '@kit.LocalizationKit';
import { DownloaderImpl } from '../common/net/Downloader';

/**
 * The three fields the CLOSED spinner shows. It exists so spinnerCollapsed() can take one
 * parameter by reference ($$): an ArkUI @Builder called with value parameters is rendered once
 * and never again, so the closed row kept whatever it was built with - the first quality in the
 * list - however many times the selection changed underneath it. A $$ parameter re-evaluates
 * the call-site expression when the state it reads changes, which is what a spinner needs.
 */
interface SpinnerRow {
  formatName: string;
  quality: string;
  size: string;
}

const TAG: string = 'DownloadDialogPage';

/** videoAudioGroup's three checked states. */
export enum DownloadKind {
  VIDEO,
  AUDIO,
  SUBTITLE
}

/** An open dropdown cannot push the button bar off-frame, so its list is height-bounded. */
const DROPDOWN_MAX_HEIGHT: number = 280;

/**
 * The reference's spinner dropdown is a floating window, not part of the dialog: measured on
 * EPHUT20709003067 the caption list runs x 120..816 of 1080 (64% of the screen) and reaches the
 * bottom edge at y 2208, well past the dialog card. A menu is the only ArkUI construct that can
 * paint outside the dialog's own window.
 */
const SPINNER_MENU_WIDTH: string = '64%';
const SPINNER_MENU_OPTIONS: MenuOptions = { borderRadius: 0 };

/** prefs keys the dialog reads and writes. */
const DEFAULT_DOWNLOAD_THREADS_KEY: string = 'default_download_threads';
const LAST_USED_DOWNLOAD_TYPE_KEY: string = 'last_used_download_type';



@Component
export struct DownloadDialogPage {
  /** Two-way with the host's visibility flag: the toolbar navigation icon calls dismiss(). */
  @Link isShown: boolean;
  /** fileName.setText(FilenameUtils.createFilename(ctx, currentInfo.getName())). */
  @Prop fileNameField: string = '';
  /** videoAudioGroup checked id. prefs last_used_download_type picks the initial one in S4. */
  @State selectedKind: DownloadKind = DownloadKind.VIDEO;
  /** prefs default_download_threads, default 3. */
  @State threads: number = 3;
  /** okButton.setEnabled(false) until onServiceConnected - the source's own guard. */
  @State downloadServiceConnected: boolean = false;

  /** Each RadioButton is HIDDEN when its own stream list is empty. */
  @State hasVideoStreams: boolean = true;
  @State hasAudioStreams: boolean = true;
  @State hasSubtitleStreams: boolean = true;
  /** setRadioButtonsState(enabled) - all three go dead while the sizes are being fetched. */
  @State radioButtonsEnabled: boolean = true;

  /** Spinner contents come from StreamInfo through svc_extractor; never a literal option list. */
  @Prop qualitySpinner: StreamItemEntry[] = [];
  @Prop audioStreamSpinner: StreamItemEntry[] = [];
  /** wrappedAudioTracks - the audio_track_spinner's groups. */
  @Prop audioTrackSpinner: AudioTrackGroup[] = [];
  /** getStreamsOfSpecifiedDelivery(info.getSubtitles(), PROGRESSIVE_HTTP). */
  @Prop subtitleSpinner: StreamItemEntry[] = [];
  /**
   * StreamInfoWrapper.fetchMoreInfoForWrapper(): the byte size per row of the CURRENT spinner.
   * A zero means "not known yet", which is what leaves stream_size GONE.
   */
  @Prop streamSizes: number[] = [];
  /** The kinds whose sizes have already been fetched: the source fetches each wrapper once. */
  private sizedKinds: Set<DownloadKind> = new Set<DownloadKind>();
  @State isLoading: boolean = false;
  @State errorInfo: string | null = null;
  @State selectedQualityIndex: number = 0;
  @State selectedAudioStreamIndex: number = 0;
  @State selectedAudioTrackIndex: number = 0;
  /** videoStreamsAdapter.getItem(selectedVideoIndex).isVideoOnly(). */
  @State selectedVideoIsVideoOnly: boolean = false;

  /** Which dropdown is open; a Spinner shows one list at a time. */

  /** The two AlertDialogs prepareSelectedDownload() can raise. */
  @State showOverwriteDialog: boolean = false;
  @State showFailedDialog: boolean = false;
  /** checkForExistingMission(): PendingRunning offers "generate unique name" instead. */
  /**
   * checkForExistingMission()'s answer, kept whole: the source picks BOTH the message and the
   * positive button from it (DownloadDialog.java:898-945), so a boolean could only ever carry
   * half of that and the dialog came up with no message at all.
   */
  @State overwriteState: MissionState = MissionState.None;
  /** mainStorage + filename + mime: what createUniqueFile() needs on the PendingRunning branch. */
  private pendingDirectory: StoredDirectory | null = null;
  private pendingFilename: string = '';
  private pendingMime: string = '';

  /**
   * new DownloadDialog(activity, currentInfo): the source hands the dialog the host fragment's
   * CURRENT stream, not the route's original arguments - VideoDetailFragment.loadItem() swaps
   * serviceId/url in place without a new push, so the route params go stale. The host passes its
   * live pair in; router.getParams() stays as the fallback for a host that has none.
   */
  @Prop serviceId: number = 0;
  @Prop url: string = '';
  /** currentInfo: the StreamInfo every spinner is built from. */
  private currentInfo: StreamInfo | null = null;
  /** selectedSubtitleIndex: kept apart so switching kinds comes back to the same caption. */
  private selectedSubtitleIndex: number = 0;
  /** userHasModifiedFileName: once true, onItemSelectedSetFileName() stops rewriting the name. */
  private userHasModifiedFileName: boolean = false;
  /** The streams behind each spinner row, kept so the OK press can resolve the chosen url. */
  private videoStreams: VideoStream[] = [];
  /** getWrappedAudioStreams(): the selected track's streams, sorted by the format comparator. */
  private audioStreams: AudioStream[] = [];
  /** Every audio stream of the info, which the tracks are grouped from. */
  private allAudioStreams: AudioStream[] = [];
  private subtitleStreams: SubtitlesStream[] = [];
  /** The StoredFile the save picker returned, held across the overwrite confirmation. */
  private pendingStorage: StoredFile | null = null;

  /* //////////////////////////////////////////////////////////////////////////
  // The source's own visibility rules
  ////////////////////////////////////////////////////////////////////////// */

  /* //////////////////////////////////////////////////////////////////////////
  // Loading — the StreamInfo the host already has, and the four adapters over it
  ////////////////////////////////////////////////////////////////////////// */

  aboutToAppear(): void {
    this.prepare();
  }

  /**
   * onCreate(): !PermissionHelper.checkStoragePermissions(...) dismisses straight out, and
   * onViewCreated then returns early. Otherwise the dialog loads its stream lists.
   */
  private async prepare(): Promise<void> {
    const permissions: PermissionHelper = ServiceLocator.get().permissions;
    if (!permissions.checkStoragePermissions()) {
      // dismiss() straight out of onCreate; onViewCreated then returns early.
      this.isShown = false;
      return;
    }
    this.readThreadPreference();
    // onServiceConnected: the manager is initialised at startup, so the service is connected
    // before the stream fetch, not after it. Setting this AFTER the await left OK disabled for
    // the whole fetch with nothing on screen to say why - a tap then did nothing and logged
    // nothing, which is what TC-LIBRARY-017 kept reporting. The fetch has its own state below.
    this.downloadServiceConnected = true;
    await this.loadStreams();
  }

  /** prefs default_download_threads, default 3. */
  private readThreadPreference(): void {
    this.threads = AppPreferences.instance().getIntSync(DEFAULT_DOWNLOAD_THREADS_KEY, 3);
  }

  private readArguments(): void {
    if (this.url.length > 0) {
      // The host already handed in its current (serviceId, url) - that pair wins.
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
   * setupDownloadOptions(): the three radio buttons exist only while their own stream list is
   * non-empty, and each spinner is filled from the StreamInfo the host already loaded.
   */
  private async loadStreams(): Promise<void> {
    this.readArguments();
    if (this.url.length === 0) {
      return;
    }
    this.isLoading = true;
    try {
      const info: StreamInfo =
        await ExtractorHelper.getStreamInfo(this.serviceId, this.url, false);
      this.currentInfo = info;
      // FilenameUtils.createFilename(ctx, currentInfo.getName())
      if (!this.userHasModifiedFileName) {
        this.fileNameField = DownloadDialogPage.createFilename(info.getName());
      }

      this.allAudioStreams = info.getAudioStreams();
      // ListHelper.getGroupedAudioStreams(ctx, audioStreams): one group per audio track.
      this.audioTrackSpinner = DownloadDialogPage.groupAudioTracks(this.allAudioStreams);
      // getSortedStreamVideosList(ctx, video, videoOnly, false, wrappedAudioTracks.size() > 1):
      // the default video format and show_higher_resolutions decide what is offered.
      this.videoStreams = getSortedStreamVideosList(PlayerPrefs.defaultVideoFormat(),
        PlayerPrefs.showHigherResolutions(), info.getVideoStreams(), info.videoOnlyStreams, false,
        this.audioTrackSpinner.length > 1);
      this.subtitleStreams = info.subtitles;
      // getDefaultResolutionIndex / getDefaultAudioTrackGroup / getDefaultAudioFormat: the dialog
      // opens on the user's default resolution and audio format, not on the first row.
      this.selectedQualityIndex = Math.max(0, this.defaultVideoIndex());
      this.selectedAudioTrackIndex = Math.max(0, this.defaultAudioTrackIndex());
      this.audioStreams = this.sortedTrackStreams();
      this.selectedAudioStreamIndex = Math.max(0, this.defaultAudioStreamIndex());
      // getSubtitleIndexBy(): the preferred language, and its country if one matches exactly.
      this.selectedSubtitleIndex = this.defaultSubtitleIndex();

      this.qualitySpinner = this.videoStreams.map((stream: VideoStream): StreamItemEntry =>
        new StreamItemEntry(DownloadDialogPage.formatNameOf(stream.getFormat()),
          stream.getResolution(), ''));
      this.audioStreamSpinner = this.audioStreams.map((stream: AudioStream): StreamItemEntry =>
        new StreamItemEntry(DownloadDialogPage.formatNameOf(stream.getFormat()),
          `${stream.getAverageBitrate()}kbps`, ''));
      // StreamItemAdapter.getView(): a SubtitlesStream's format_name is its LANGUAGE TAG and its
      // quality line is the display language name, with " (Auto-generated)" appended for a
      // generated track. The two were the wrong way round, so every row headlined the format -
      // "Timed Text Markup Language" on all of them - and the tag was the only thing naming the
      // language.
      this.subtitleSpinner =
        this.subtitleStreams.map((stream: SubtitlesStream): StreamItemEntry =>
          new StreamItemEntry(stream.getLanguageTag(),
            DownloadDialogPage.subtitleName(stream), ''));
      this.hasVideoStreams = this.videoStreams.length > 0;
      this.hasAudioStreams = this.allAudioStreams.length > 0;
      this.hasSubtitleStreams = this.subtitleStreams.length > 0;
      this.applyInitialKind();
      this.fetchStreamSizes(this.selectedKind);
    } catch (err) {
      this.errorInfo = (err as BusinessError).message;
    } finally {
      this.isLoading = false;
    }
  }

  /**
   * prefs last_used_download_type picks the initially checked radio, falling back to the first
   * available kind; with nothing at all the source toasts and dismisses.
   */
  private applyInitialKind(): void {
    const lastUsed: string =
      AppPreferences.instance().getStringSync(LAST_USED_DOWNLOAD_TYPE_KEY, '');
    if (lastUsed === 'video' && this.hasVideoStreams) {
      this.selectedKind = DownloadKind.VIDEO;
    } else if (lastUsed === 'audio' && this.hasAudioStreams) {
      this.selectedKind = DownloadKind.AUDIO;
    } else if (lastUsed === 'subtitle' && this.hasSubtitleStreams) {
      this.selectedKind = DownloadKind.SUBTITLE;
    } else if (this.hasVideoStreams) {
      this.selectedKind = DownloadKind.VIDEO;
    } else if (this.hasAudioStreams) {
      this.selectedKind = DownloadKind.AUDIO;
    } else if (this.hasSubtitleStreams) {
      this.selectedKind = DownloadKind.SUBTITLE;
    } else {
      // toast R.string.no_streams_available_download; dismiss()
      promptAction.showToast({
        message: $r('app.string.no_streams_available_download'), duration: 2000
      });
      this.isShown = false;
      return;
    }
    if (this.selectedKind === DownloadKind.SUBTITLE) {
      this.selectedQualityIndex = this.selectedSubtitleIndex;
    }
    this.onItemSelectedSetFileName();
    this.rememberKind();
    this.updateSelectedVideoIsVideoOnly();
  }

  /** The radio choice is persisted, so the next dialog opens on the same kind. */
  private rememberKind(): void {
    const value: string = this.selectedKind === DownloadKind.AUDIO ? 'audio'
      : (this.selectedKind === DownloadKind.SUBTITLE ? 'subtitle' : 'video');
    AppPreferences.putString(LAST_USED_DOWNLOAD_TYPE_KEY, value)
      .catch((err: BusinessError): void => {
        hilog.error(0x0000, TAG, 'last_used_download_type: %{public}s', err.message);
      });
  }

  /** onVideoStreamSelected(): the audio-track spinner follows the selected stream. */
  private updateSelectedVideoIsVideoOnly(): void {
    const stream: VideoStream | undefined = this.videoStreams[this.selectedQualityIndex];
    this.selectedVideoIsVideoOnly = stream !== undefined && stream.isVideoOnly;
  }

  /**
   * ListHelper.getDefaultResolutionIndex(context, videoStreams): default_resolution (lowered by
   * the mobile-data limit) in the default video format, else the nearest fit, else the top row.
   */
  private defaultVideoIndex(): number {
    return getDefaultResolutionIndex(PlayerPrefs.computeDefaultResolution(),
      PlayerPrefs.defaultVideoFormat(), this.videoStreams);
  }

  /** getAudioTrackComparator(context): the preferences the source reads for it. */
  private static audioTrackComparator(): (a: AudioStream, b: AudioStream) => number {
    const prefs: AppPreferences = AppPreferences.instance();
    return getAudioTrackComparator(Localization.getPreferredLocalization(),
      prefs.getBooleanSync(prefer_original_audio_key, true),
      prefs.getBooleanSync(prefer_descriptive_audio_key, false));
  }

  /** getDefaultAudioTrackGroup(): the group whose first stream ranks highest. */
  private defaultAudioTrackIndex(): number {
    const firsts: AudioStream[] = [];
    for (const group of this.audioTrackSpinner) {
      const first: AudioStream | null = group.first();
      if (first !== null) {
        firsts.push(first);
      }
    }
    return getAudioIndexByHighestRank(firsts, DownloadDialogPage.audioTrackComparator());
  }

  /** getDefaultAudioFormat(): the best track first, then default_audio_format and bitrate. */
  private defaultAudioStreamIndex(): number {
    const track: (a: AudioStream, b: AudioStream) => number =
      DownloadDialogPage.audioTrackComparator();
    const format: (a: AudioStream, b: AudioStream) => number = getAudioFormatComparator(
      PlayerPrefs.defaultAudioFormat(), PlayerPrefs.isLimitingDataUsage());
    return getAudioIndexByHighestRank(this.audioStreams,
      (a: AudioStream, b: AudioStream): number => {
        const cmp: number = track(a, b);
        return cmp !== 0 ? cmp : format(a, b);
      });
  }

  /** getWrappedAudioStreams(): the selected audio track's streams. */
  private trackAudioStreams(): AudioStream[] {
    const group: AudioTrackGroup | undefined = this.audioTrackSpinner[this.selectedAudioTrackIndex];
    return group === undefined ? this.allAudioStreams : group.streams;
  }

  /** getGroupedAudioStreams()'s per-track order: the format comparator, preferred last. */
  private sortedTrackStreams(): AudioStream[] {
    const format: (a: AudioStream, b: AudioStream) => number = getAudioFormatComparator(
      PlayerPrefs.defaultAudioFormat(), PlayerPrefs.isLimitingDataUsage());
    return this.trackAudioStreams().slice().sort(format);
  }

  /** onItemSelected(audio_track_spinner): the audio list and the video sizes follow the track. */
  private onAudioTrackChanged(): void {
    this.audioStreams = this.sortedTrackStreams();
    this.selectedAudioStreamIndex = Math.max(0, this.defaultAudioStreamIndex());
    this.audioStreamSpinner = this.audioStreams.map((stream: AudioStream): StreamItemEntry =>
      new StreamItemEntry(DownloadDialogPage.formatNameOf(stream.getFormat()),
        `${stream.getAverageBitrate()}kbps`, ''));
    this.sizedKinds.delete(DownloadKind.AUDIO);
    this.sizedKinds.delete(DownloadKind.VIDEO);
    this.fetchStreamSizes(this.selectedKind);
  }

  /** getSubtitleIndexBy(streams). */
  private defaultSubtitleIndex(): number {
    const preferred: ExtractorLocalization = NewPipe.getPreferredLocalization();
    const language: string = preferred.getLanguageCode().split('-')[0].toLowerCase();
    let candidate: number = 0;
    for (let i: number = 0; i < this.subtitleStreams.length; i++) {
      const locale: intl.Locale = this.subtitleStreams[i].getLocale();
      if (locale.language !== undefined && locale.language.toLowerCase() === language) {
        if (locale.region !== undefined && locale.region === preferred.getCountryCode()) {
          return i;
        }
        candidate = i;
      }
    }
    return candidate;
  }

  /**
   * onItemSelectedSetFileName(): while the user has not edited the name, a caption download is
   * named "<title>-<language tag>" (caption_file_name) and the others "<title>".
   */
  private onItemSelectedSetFileName(): void {
    const info: StreamInfo | null = this.currentInfo;
    if (info === null) {
      return;
    }
    const fileName: string = DownloadDialogPage.createFilename(info.getName());
    // only update the file name field if it was not edited by the user - judged, as the source
    // does, by the field still holding one of the names this method writes
    const prev: string = this.fileNameField;
    if (prev.length > 0 && prev !== fileName && !prev.startsWith(
      Localization.getStringArgs('caption_file_name', [fileName, '']))) {
      return;
    }
    if (this.selectedKind === DownloadKind.SUBTITLE) {
      const subtitle: SubtitlesStream | undefined =
        this.subtitleStreams[this.selectedQualityIndex];
      this.fileNameField = subtitle === undefined ? fileName
        : Localization.getStringArgs('caption_file_name', [fileName, subtitle.getLanguageTag()]);
    } else {
      this.fileNameField = fileName;
    }
  }

  /** The SecondaryStreamHelper a video-only row is muxed with, or null for none. */
  private secondaryAudioFor(video: VideoStream): AudioStream | null {
    return getAudioStreamFor(this.trackAudioStreams(), video, PlayerPrefs.isLimitingDataUsage());
  }

  /** ListHelper.getGroupedAudioStreams(): the streams bucketed by their audio-track name. */
  private static groupAudioTracks(streams: AudioStream[]): AudioTrackGroup[] {
    const byTrack: Map<string, AudioStream[]> = new Map<string, AudioStream[]>();
    for (const stream of streams) {
      const name: string | null = stream.getAudioTrackName();
      const key: string = name === null ? '' : name;
      const bucket: AudioStream[] | undefined = byTrack.get(key);
      if (bucket === undefined) {
        byTrack.set(key, [stream]);
      } else {
        bucket.push(stream);
      }
    }
    const groups: AudioTrackGroup[] = [];
    byTrack.forEach((bucket: AudioStream[]) => {
      groups.push(new AudioTrackGroup(bucket));
    });
    return groups;
  }

  /**
   * FilenameUtils.createFilename(): the characters the chosen charset rejects become the chosen
   * replacement character (letters and digits only, or the most special characters, or a custom
   * pattern the user typed).
   */
  private static createFilename(name: string): string {
    const prefs: AppPreferences = AppPreferences.instance();
    const replacement: string = prefs.getStringSync(settings_file_replacement_character_key,
      settings_file_replacement_character_default_value);
    let selected: string = prefs.getStringSync(settings_file_charset_key, '');
    if (selected.length === 0) {
      selected = charset_most_special_value;
    }
    const charset: string = selected === charset_letters_and_digits_value ? '[^\\w\\d]+'
      : (selected === charset_most_special_value ? '[\\n\\r|?*<":\\\\>/\']+' : selected);
    let pattern: RegExp;
    try {
      pattern = new RegExp(charset, 'g');
    } catch (err) {
      pattern = new RegExp('[\\n\\r|?*<":\\\\>/\']+', 'g');
    }
    // Matcher.quoteReplacement(): the replacement is literal text.
    return name.replace(pattern, (): string => replacement).trim();
  }

  /**
   * StreamItemAdapter.getView(): qualityString = getDisplayLanguageName(), plus
   * " (" + caption_auto_generated + ")" when the track is generated.
   */
  private static subtitleName(stream: SubtitlesStream): string {
    const name: string = stream.getDisplayLanguageName();
    if (!stream.isAutoGenerated()) {
      return name;
    }
    let generated: string = '';
    try {
      generated = (getContext() as common.Context).resourceManager
        .getStringSync($r('app.string.caption_auto_generated'));
    } catch (err) {
      hilog.warn(0x0000, TAG, 'caption_auto_generated lookup: %{public}s',
        (err as BusinessError).message);
      return name;
    }
    return `${name} (${generated})`;
  }

  private static formatNameOf(format: MediaFormat | null): string {
    // StreamItemAdapter.getView(): unknown_format when the stream names none, "opus" for
    // WEBMA_OPUS - the reference's rows read "opus", not the format's own "WebM Opus" name - and
    // the MediaFormat name for everything else.
    if (format === null) {
      try {
        return (getContext() as common.Context).resourceManager
          .getStringSync($r('app.string.unknown_format'));
      } catch (err) {
        return '';
      }
    }
    if (format === MediaFormat.WEBMA_OPUS) {
      return 'opus';
    }
    return format.getName();
  }

  /**
   * StreamInfoWrapper.fetchMoreInfoForWrapper(): the size of each row comes from a HTTP HEAD
   * Content-Length, so the spinner starts with no size and fills in as the answers arrive.
   * setRadioButtonsState(false) holds the radios dead while that is in flight.
   */
  private async fetchStreamSizes(kind: DownloadKind): Promise<void> {
    // The source wraps EACH kind's list in its own StreamInfoWrapper and fetches the sizes of the
    // one on screen. This only ever fetched the video list, so every audio row showed no size at
    // all where the reference shows one per row.
    const streams: Stream[] = kind === DownloadKind.AUDIO
      ? this.audioStreams : (kind === DownloadKind.SUBTITLE
        ? this.subtitleStreams : this.videoStreams);
    if (streams.length === 0 || this.sizedKinds.has(kind)) {
      return;
    }
    this.radioButtonsEnabled = false;
    const downloader: DownloaderImpl = DownloaderImpl.getInstance();
    const sizes: number[] = [];
    try {
      for (const stream of streams) {
        // fetchMoreInfoForWrapper(): the itag already carries contentLength for the streams the
        // extractor read it from, and only the rest cost a HEAD. Going to the network for all of
        // them left the DASH rows sizeless whenever their URL answers a HEAD with no
        // Content-Length - two rows of the quality list showed no size at all.
        const itag: ItagItem | null = stream.getItagItem();
        const known: number = itag === null ? 0 : itag.getContentLength();
        if (known > 0) {
          sizes.push(known);
          continue;
        }
        try {
          sizes.push(await downloader.getContentLength(stream.getContent()));
        } catch (err) {
          // An unreadable size is not a failure: the row simply shows none. It is logged, though
          // - a silently sizeless spinner is indistinguishable from one that was never fetched.
          hilog.warn(0x0000, TAG, 'content length for %{public}s: %{public}s',
            stream.getContent().slice(0, 60), (err as BusinessError).message);
          sizes.push(0);
        }
      }
      if (kind === DownloadKind.VIDEO) {
        // StreamItemAdapter: a video-only row's size is the video's plus its secondary audio's.
        for (let i: number = 0; i < this.videoStreams.length && i < sizes.length; i++) {
          const secondary: AudioStream | null = this.videoStreams[i].isVideoOnly
            ? this.secondaryAudioFor(this.videoStreams[i]) : null;
          if (secondary !== null && sizes[i] > 0) {
            const extra: number = await DownloadDialogPage.sizeOf(downloader, secondary);
            sizes[i] = extra > 0 ? sizes[i] + extra : sizes[i];
          }
        }
      }
      this.sizedKinds.add(kind);
      this.streamSizes = sizes;
      // The spinner rows carry the size once it is known; until then stream_size stays GONE.
      if (kind === DownloadKind.AUDIO) {
        this.audioStreamSpinner = this.audioStreams.map(
          (stream: AudioStream, index: number): StreamItemEntry =>
            new StreamItemEntry(DownloadDialogPage.formatNameOf(stream.getFormat()),
              `${stream.getAverageBitrate()}kbps`, this.sizeText(index)));
      } else if (kind === DownloadKind.SUBTITLE) {
        this.subtitleSpinner = this.subtitleStreams.map(
          (stream: SubtitlesStream, index: number): StreamItemEntry =>
            new StreamItemEntry(stream.getLanguageTag(),
              DownloadDialogPage.subtitleName(stream), this.sizeText(index)));
      } else {
        this.qualitySpinner = this.videoStreams.map(
          (stream: VideoStream, index: number): StreamItemEntry =>
            new StreamItemEntry(DownloadDialogPage.formatNameOf(stream.getFormat()),
              stream.getResolution(), this.sizeText(index)));
      }
    } finally {
      this.radioButtonsEnabled = true;
    }
  }

  /** fetchMoreInfoForWrapper() for one stream: the itag's length, else a HEAD; 0 if unknown. */
  private static async sizeOf(downloader: DownloaderImpl, stream: Stream): Promise<number> {
    const itag: ItagItem | null = stream.getItagItem();
    const known: number = itag === null ? 0 : itag.getContentLength();
    if (known > 0) {
      return known;
    }
    try {
      return await downloader.getContentLength(stream.getContent());
    } catch (err) {
      return 0;
    }
  }

  /** stream_size: empty while the size is unknown, which is what keeps the view GONE. */
  private sizeText(index: number): string {
    const bytes: number = index < this.streamSizes.length ? this.streamSizes[index] : 0;
    if (bytes <= 0) {
      return '';
    }
    // Utility.formatBytes(): B / kB / MB / GB with two decimals. This rendered MB only, with one
    // decimal, so a 4 GB stream read "3905.3 MB" where the reference reads "3.81 GB" - the units
    // this case asks for. The Downloads list has always used this same stepping; it is now one
    // function instead of two.
    return formatBytes(bytes);
  }

  /* //////////////////////////////////////////////////////////////////////////
  // prepareSelectedDownload() -> continueSelectedDownload()
  ////////////////////////////////////////////////////////////////////////// */

  /**
   * prepareSelectedDownload(): pick where the file goes (feat_saf_storage - DocumentViewPicker,
   * with the ported picker as the fallback), then check for an existing mission before writing.
   */
  private async prepareSelectedDownload(): Promise<void> {
    const access: FileAccess = ServiceLocator.get().fileAccess;
    const kindTag: string = this.selectedKind === DownloadKind.AUDIO ? TAG_AUDIO : TAG_VIDEO;
    let storage: StoredFile | null = null;

    // prepareSelectedDownload(), the branch the port had dropped: the source only shows a picker
    // when there is no configured folder, when `Ask where to download` is on, or when the folder
    // it has cannot be written. Otherwise it creates the file in that folder and starts straight
    // away. Without this the two `download folder` rows configured nothing - whatever they were
    // set to, every download still went through the save picker (T-0183/T-0186).
    const manager: DownloadManager = ServiceLocator.get().downloadManager;
    const mainStorage: StoredDirectory | null = manager.getMainStorage(kindTag);
    // `Ask where to download` is not offered on HarmonyOS (the settings row is disabled), so a
    // value stored by an earlier build no longer sends every download through the picker.
    if (mainStorage !== null && mainStorage.canWrite()) {
      const name: string = this.outputFileName();
      const mime: string = this.outputSuffixAndMime()[1];
      storage = mainStorage.createFile(name, mime);
      if (storage === null) {
        hilog.error(0x0000, TAG, 'could not create the file in %{public}s', mainStorage.getUri());
        return;
      }
      await this.startWithStorage(storage, mainStorage, name, mime);
      return;
    }

    try {
      // StoredFileHelper.getNewPicker(ctx, filename + "." + format.suffix, format.mimeType, ...):
      // the source names the file WITH its extension and hands the picker the real MIME type.
      // The port passed the bare field and application/octet-stream, so every download landed as
      // an extension-less file - the system cannot tell what it is, which is why a finished
      // download could not be opened on the device.
      storage = await access.pickFileToSave(this.outputFileName(), this.outputSuffixAndMime()[1],
        kindTag);
    } catch (err) {
      // No system picker: fall back to the ported NoNonsense picker, this screen's one navOut.
      hilog.warn(0x0000, TAG, 'save picker unavailable: %{public}s',
        (err as BusinessError).message);
      router.pushUrl({ url: 'pages/CustomFilePickerFragmentPage' })
        .catch((pushErr: BusinessError): void => {
          hilog.error(0x0000, TAG, 'file picker push failed: %{public}s', pushErr.message);
        });
      return;
    }
    if (storage === null) {
      // The picker was dismissed. The source returns here too, but SILENTLY - and three device
      // sessions burned on TC-LIBRARY-017 because a cancelled picker and a failed enqueue look
      // exactly alike in the log. One line makes them different.
      hilog.info(0x0000, TAG, 'save picker cancelled: no mission started');
      return;
    }
    await this.startWithStorage(storage);
  }

  /**
   * checkForExistingMission(storage): Finished/Pending warn, PendingRunning offers a unique name,
   * None writes straight away. Shared by both halves of prepareSelectedDownload().
   */
  private async startWithStorage(storage: StoredFile, directory: StoredDirectory | null = null,
    filename: string = '', mime: string = ''): Promise<void> {
    this.pendingStorage = storage;
    this.pendingDirectory = directory;
    this.pendingFilename = filename;
    this.pendingMime = mime;
    const manager: DownloadManager = ServiceLocator.get().downloadManager;
    const state: MissionState = manager.checkForExistingMission(storage);
    if (state === MissionState.None) {
      await this.continueSelectedDownload();
      return;
    }
    this.overwriteState = state;
    this.showOverwriteDialog = true;
  }

  /** R.string.download_already_pending / _running / overwrite_finished_warning, by state. */
  private overwriteMessage(): Resource {
    if (this.overwriteState === MissionState.PendingRunning) {
      return $r('app.string.download_already_running');
    }
    if (this.overwriteState === MissionState.Pending) {
      return $r('app.string.download_already_pending');
    }
    return $r('app.string.overwrite_finished_warning');
  }

  /**
   * The positive button, which is not one action but two (DownloadDialog.java:973-1012):
   *
   *  - Finished / Pending: forgetMission(storage), then download over the same name - the record
   *    and the half-written file go, which is what "Overwrite" promises.
   *  - PendingRunning: the running mission is NOT touched. createUniqueFile() appends " (1)" and
   *    the new download goes beside it - "Generate unique name". The port used to call
   *    continueSelectedDownload() for both, so answering the dialog wrote over a download that
   *    was still running.
   */
  private async resolveOverwrite(): Promise<void> {
    this.showOverwriteDialog = false;
    const manager: DownloadManager = ServiceLocator.get().downloadManager;
    if (this.overwriteState === MissionState.PendingRunning) {
      const directory: StoredDirectory | null = this.pendingDirectory;
      const unique: StoredFile | null = directory === null
        ? null : directory.createUniqueFile(this.pendingFilename, this.pendingMime);
      if (unique === null) {
        this.showFailedDialog = true;
        return;
      }
      this.pendingStorage = unique;
      await this.continueSelectedDownload();
      return;
    }
    const storage: StoredFile | null = this.pendingStorage;
    if (storage !== null) {
      manager.forgetMission(storage);
    }
    await this.continueSelectedDownload();
  }

  /** continueSelectedDownload(): the mission itself. */
  private async continueSelectedDownload(): Promise<void> {
    // The source asks for POST_NOTIFICATIONS before it starts a download, because the transfer is
    // reported in the shade. This port published nothing and asked for nothing, so a download was
    // invisible once the screen was closed - and with notifications off at the system level
    // (`isNotificationEnabled … allowed=0`, measured) the new progress row would have been
    // dropped silently too. Asked once; a denial is remembered by the platform.
    await ServiceLocator.get().notifications.ensureEnabled(
      getContext(this) as common.UIAbilityContext);
    const storage: StoredFile | null = this.pendingStorage;
    const streams: Stream[] = this.selectedStreams();
    const urls: string[] = streams.map((stream: Stream): string => stream.getContent());
    if (storage === null || urls.length === 0) {
      this.showFailedDialog = true;
      return;
    }
    try {
      const kindTag: string = this.selectedKind === DownloadKind.AUDIO ? TAG_AUDIO : TAG_VIDEO;
      const mission: DownloadMission = DownloadMission.create(urls, storage, kindTag);
      // continueSelectedDownload(): `mission.source = currentInfo.getUrl()`. The SOURCE of a
      // mission is the page the download came from, not the file it pulls - R.id.source ('Show
      // info') hands it to RouterActivity to reopen. create() defaults it to urls[0], which is
      // the media CDN link: the router cannot resolve one of those and falls through to its
      // unsupported-link screen, which is what TC-LIBRARY-185 reports. The dialog is created with
      // the stream page url, so set it here, exactly where the source does.
      if (this.url.length > 0) {
        mission.source = this.url;
      }
      // `new MissionRecoveryInfo(stream)` per url: what a 403 (expired url) is recovered from.
      mission.recoveryInfo = streams.map((stream: Stream): MissionRecoveryInfo =>
        MissionRecoveryInfo.of(stream));
      // continueSelectedDownload(): the post-processing step, and one thread for a subtitle.
      const postprocessing: string[] = this.selectedPostprocessing();
      mission.setPostprocessing(postprocessing[0], postprocessing.slice(1));
      const info: StreamInfo | null = this.currentInfo;
      if (info !== null) {
        // Postprocessing.getAlgorithm(psName, psArgs, streamInfo): the Opus tags' source.
        const uploadDate: number | null = info.getUploadDate();
        mission.psStreamInfo = [info.getUrl(), info.getCategory(), info.getUploaderName(),
          info.getName(), uploadDate === null ? '' : uploadDate.toString()];
      }
      mission.threadCount = this.selectedKind === DownloadKind.SUBTITLE ? 1 : this.threads;
      const manager: DownloadManager = ServiceLocator.get().downloadManager;
      hilog.info(0x0000, TAG, 'startMission: %{public}d url(s) -> %{public}s ps=%{public}s',
        urls.length, storage.getName(), postprocessing[0]);
      await manager.startMission(mission);
      this.isShown = false;
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      hilog.error(0x0000, TAG, 'startMission failed: %{public}s', failure.message);
      this.errorInfo = failure.message;
      this.showFailedDialog = true;
    }
  }

  /**
   * continueSelectedDownload()'s psName / psArgs: [name, ...args], name '' for none. M4A audio
   * loses its DASH wrapping, Opus is demuxed to Ogg, a video-only row is muxed with its audio
   * and a TTML caption becomes SRT.
   */
  private selectedPostprocessing(): string[] {
    const format: MediaFormat | null = this.selectedMediaFormat();
    if (this.selectedKind === DownloadKind.AUDIO) {
      if (format === MediaFormat.M4A) {
        return [ALGORITHM_M4A_NO_DASH];
      }
      return format === MediaFormat.WEBMA_OPUS ? [ALGORITHM_OGG_FROM_WEBM_DEMUXER] : [''];
    }
    if (this.selectedKind === DownloadKind.SUBTITLE) {
      return format === MediaFormat.TTML ? [ALGORITHM_TTML_CONVERTER, format.suffix, 'false'] : [''];
    }
    const video: VideoStream | undefined = this.videoStreams[this.selectedQualityIndex];
    if (video === undefined || !video.isVideoOnly || this.secondaryAudioFor(video) === null) {
      return [''];
    }
    return [format === MediaFormat.MPEG_4 ? ALGORITHM_MP4_FROM_DASH_MUXER : ALGORITHM_WEBM_MUXER];
  }

  /**
   * prepareSelectedDownload()'s file type: what the file IS after post-processing - Opus lands as
   * "opus" in an Ogg container and a TTML caption as SRT.
   */
  private outputSuffixAndMime(): string[] {
    const format: MediaFormat | null = this.selectedMediaFormat();
    if (format === null) {
      return ['', 'application/octet-stream'];
    }
    if (this.selectedKind === DownloadKind.AUDIO && format === MediaFormat.WEBMA_OPUS) {
      return ['opus', 'audio/ogg'];
    }
    if (this.selectedKind === DownloadKind.SUBTITLE && format === MediaFormat.TTML) {
      return [MediaFormat.SRT.suffix, MediaFormat.SRT.mimeType];
    }
    return [format.suffix, format.mimeType];
  }

  /** The MediaFormat of the row the download will pull, which names the file's extension. */
  private selectedMediaFormat(): MediaFormat | null {
    if (this.selectedKind === DownloadKind.AUDIO) {
      const audio: AudioStream | undefined = this.audioStreams[this.selectedAudioStreamIndex];
      return audio === undefined ? null : audio.getFormat();
    }
    if (this.selectedKind === DownloadKind.SUBTITLE) {
      const subtitle: SubtitlesStream | undefined =
        this.subtitleStreams[this.selectedQualityIndex];
      return subtitle === undefined ? null : subtitle.getFormat();
    }
    const video: VideoStream | undefined = this.videoStreams[this.selectedQualityIndex];
    return video === undefined ? null : video.getFormat();
  }

  /**
   * filename + "." + suffix, and never a second copy of a suffix the user already typed.
   * getNameEditText(): the field, trimmed and cleaned with the filename charset, or the title.
   */
  private outputFileName(): string {
    const typed: string = this.fileNameField.trim();
    const info: StreamInfo | null = this.currentInfo;
    const name: string = DownloadDialogPage.createFilename(
      typed.length === 0 && info !== null ? info.getName() : typed);
    const suffix: string = this.outputSuffixAndMime()[0];
    if (suffix.length === 0) {
      return name;
    }
    return name.toLowerCase().endsWith('.' + suffix.toLowerCase()) ? name : `${name}.${suffix}`;
  }

  /** The stream(s) the selected row downloads; a video-only stream also pulls its audio track. */
  private selectedStreams(): Stream[] {
    if (this.selectedKind === DownloadKind.AUDIO) {
      const audio: AudioStream | undefined = this.audioStreams[this.selectedAudioStreamIndex];
      return audio === undefined ? [] : [audio];
    }
    if (this.selectedKind === DownloadKind.SUBTITLE) {
      const subtitle: SubtitlesStream | undefined =
        this.subtitleStreams[this.selectedQualityIndex];
      return subtitle === undefined ? [] : [subtitle];
    }
    const video: VideoStream | undefined = this.videoStreams[this.selectedQualityIndex];
    if (video === undefined) {
      return [];
    }
    if (!video.isVideoOnly) {
      return [video];
    }
    // A video-only stream is muxed with its secondary audio (SecondaryStreamHelper), so BOTH
    // urls are downloaded and the post-processing step joins them.
    const audio: AudioStream | null = this.secondaryAudioFor(video);
    return audio === null ? [video] : [video, audio];
  }

  /** setupVideoSpinner / setupSubtitleSpinner show it; setupAudioSpinner sets it GONE. */
  private showQualitySpinner(): boolean {
    return this.selectedKind !== DownloadKind.AUDIO;
  }

  /** Only setupAudioSpinner makes it VISIBLE. */
  private showAudioStreamSpinner(): boolean {
    return this.selectedKind === DownloadKind.AUDIO;
  }

  /**
   * AUDIO: wrappedAudioTracks.size() > 1.
   * VIDEO: isVideoOnly && wrappedAudioTracks.size() > 1.
   * SUBTITLE: always GONE.
   */
  private showAudioTrackSpinner(): boolean {
    if (this.audioTrackSpinner.length <= 1) {
      return false;
    }
    if (this.selectedKind === DownloadKind.AUDIO) {
      return true;
    }
    return this.selectedKind === DownloadKind.VIDEO && this.selectedVideoIsVideoOnly;
  }

  /** VIDEO only, and only when the selected stream ALREADY carries its audio. */
  private showAudioTrackPresentNote(): boolean {
    return this.selectedKind === DownloadKind.VIDEO && !this.selectedVideoIsVideoOnly
      && this.audioTrackSpinner.length > 1;
  }

  /** The threads bar is disabled for subtitles, where the count is forced to 1. */
  private threadsEnabled(): boolean {
    return this.selectedKind !== DownloadKind.SUBTITLE;
  }

  /** The label a closed spinner shows: its currently selected row. */
  private selectedLabel(entries: StreamItemEntry[], index: number): string {
    if (index < 0 || index >= entries.length) {
      return '';
    }
    return entries[index].quality;
  }

  /** stream_format_name of the closed spinner's selected row. */
  private selectedFormat(entries: StreamItemEntry[], index: number): string {
    if (index < 0 || index >= entries.length) {
      return '';
    }
    return entries[index].formatName;
  }

  /** stream_size of the closed spinner's selected row; empty until the size fetch lands. */
  private selectedSize(entries: StreamItemEntry[], index: number): string {
    if (index < 0 || index >= entries.length) {
      return '';
    }
    return entries[index].size;
  }

  /**
   * The audio-track spinner's rows, in the same StreamItemEntry shape the quality and
   * audio-stream spinners use: getAudioTrackId() as the format line ("en.4"),
   * Localization.audioTrackName() as the quality line ("English original"), and NO size -
   * AudioTracksAdapter hides sizeView on a track row.
   */
  private audioTrackEntries(): StreamItemEntry[] {
    const entries: StreamItemEntry[] = [];
    for (const group of this.audioTrackSpinner) {
      const first: AudioStream | null = group.first();
      const id: string | null = first === null ? null : first.getAudioTrackId();
      entries.push(new StreamItemEntry(id === null ? '' : id, audioTrackName(first), ''));
    }
    return entries;
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Builders
  ////////////////////////////////////////////////////////////////////////// */

  /**
   * A Spinner's CLOSED view. StreamItemAdapter.getView() inflates the SAME
   * stream_quality_item.xml for the closed spinner as for a dropdown row, which is why
   * base.ui.json reports stream_format_name / stream_quality / stream_size INSIDE the
   * Spinner node itself ([120,1243][924,1387]: format 22vp band, quality 26vp band, size
   * right-aligned and ending at 816). The caret is the Spinner background's own
   * ic_arrow_drop_down, drawn in the 36vp the size view leaves before the right edge.
   * S5 rendered the closed spinner as one flat 14sp line, which dropped the format and the
   * byte size off the screen and left nothing that reads as a spinner at all.
   */
  @Builder
  spinnerCollapsed($$: SpinnerRow) {
    Row() {
      Column() {
        // TextAppearance.AppCompat.Caption at 12sp in a 22dp band, secondary text.
        Text($$.formatName)
          .height(22)
          .maxLines(1)
          .fontSize(12)
          .fontColor($r('app.color.on_surface_variant'))
          .textAlign(TextAlign.Start)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        // TextAppearance.AppCompat.Body1 at 14sp in a 26dp band, primary text.
        Text($$.quality)
          .height(26)
          .maxLines(1)
          .fontSize(14)
          .fontColor($r('app.color.on_surface'))
          .textAlign(TextAlign.Start)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .padding({ left: 12, right: 18 })
      .alignItems(HorizontalAlign.Start)

      // sizeView is GONE until the size fetch lands.
      if ($$.size.length > 0) {
        Text($$.size)
          .maxLines(1)
          .height(48)
          .padding({ left: 8, right: 8 })
          .fontSize(12)
          .fontColor($r('app.color.on_surface_variant'))
          .textAlign(TextAlign.End)
      }

      Image($r('app.media.ic_arrow_drop_down'))
        .width(24)
        .height(24)
        .margin({ left: 6, right: 6 })
        .fillColor($r('app.color.on_surface_variant'))
        .objectFit(ImageFit.Contain)
    }
    .width('100%')
    .height(48)
    .alignItems(VerticalAlign.Center)
  }

  /**
   * toolbar_layout. Its own @Builder because all three states of this dialog draw it: the
   * preparing spinner and the load-error panel must keep a working navigation icon, or a
   * fetch that hangs or fails leaves the screen with no way out.
   */
  @Builder
  dialogToolbar() {
    // toolbar_layout ────────────────────────────────────────────────────────
    Row() {
      // navigationIcon ic_arrow_back, contentDescription R.string.cancel, listener dismiss().
      // base.ui.json: [60,696][228,864] = a 56vp box on a 56vp toolbar.
      Image($r('app.media.ic_arrow_back'))
        .id('Cancel')
        .accessibilityText($r('app.string.navigate_back'))
        .width(56)
        .height(56)
        .padding(16)
        .fillColor($r('app.color.on_primary'))
        .objectFit(ImageFit.Contain)
        .onClick(() => {
          // dismiss()
          this.isShown = false;
        })

      // Title x=276px = the 72vp toolbar inset measured from the card's own left edge.
      Text($r('app.string.download_dialog_title'))
        .layoutWeight(1)
        .maxLines(1)
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.on_primary'))
        .margin({ left: 16 })
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      // dialog_url.xml: R.id.okay, showAsAction always.
      // An ifRoom action item, not a filled button: white 14sp on ?attr/colorPrimary.
      Button($r('app.string.ok'))
        .id('okay')
        .type(ButtonType.Normal)
        .height(48)
        .backgroundColor(Color.Transparent)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.on_primary'))
        .padding({ left: 12, right: 12 })
      // okButton.setEnabled(onServiceConnected) — plus the fetch, because the spinners the OK
      // press reads are empty until loadStreams() lands. The dialog draws its preparing state
      // while that is true, so this is never a dead-looking button on a ready-looking form.
        .enabled(this.downloadServiceConnected && !this.isLoading)
        .onClick(() => {
          this.prepareSelectedDownload();
        })
    }
    .id('toolbar_layout')
    .width('100%')
    .height(56)
    .backgroundColor($r('app.color.primary'))
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  dialogBody() {
    Column() {
      this.dialogToolbar()

      // android:layout_margin 24/12/24/6; base.png samples the label at #6D6D6D.
      Text($r('app.string.msg_name'))
        .id('file_name_text_view')
        .width('100%')
        .fontSize(14)
        .fontColor($r('app.color.on_surface_variant'))
        .padding({ left: 24, right: 24 })
        .margin({ top: 12, bottom: 6 })

      // The underline is drawn at the component's own width, so this one is inset by a wrapper
      // rather than by padding - padding would leave the line running to both screen edges.
      Row() {
        TextInput({ text: this.fileNameField })
          .id('file_name')
          .maxLines(1)
          .layoutWeight(1)
          .height(45)
          .fontSize(16)
          .fontColor($r('app.color.on_surface'))
          .placeholderColor($r('app.color.on_surface_variant'))
          .backgroundColor(Color.Transparent)
          .borderRadius(0)
          .padding({ left: 0, right: 0 })
          .showUnderline(true)
          .onChange((value: string) => {
            // userHasModifiedFileName: once the user edits it, onItemSelectedSetFileName() stops
            // rewriting it.
            this.fileNameField = value;
            this.userHasModifiedFileName = true;
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20 })
      .margin({ bottom: 6 })

      // video_audio_group ─────────────────────────────────────────────────────
      Row() {
        if (this.hasVideoStreams) {
          Row() {
            Radio({ value: 'video', group: 'video_audio_group' })
              .id('video_button')
              // base.png samples the checked radio at pure black: the dialog theme's colorAccent
              // is @color/light_youtube_accent_color.
              .radioStyle({ checkedBackgroundColor: $r('app.color.accent') })
              .width(24)
              .height(24)
              .checked(this.selectedKind === DownloadKind.VIDEO)
              .enabled(this.radioButtonsEnabled)
              .onClick(() => {
                this.selectedKind = DownloadKind.VIDEO;
                this.selectedQualityIndex = Math.max(0, this.defaultVideoIndex());
                this.onItemSelectedSetFileName();
                this.updateSelectedVideoIsVideoOnly();
                this.rememberKind();
                this.fetchStreamSizes(DownloadKind.VIDEO);
              })
            Text($r('app.string.video'))
              .fontSize(16)
              .fontColor($r('app.color.on_surface'))
              .margin({ left: 4 })
          }
          .height(32)
          .margin({ right: 12 })
          .alignItems(VerticalAlign.Center)
        }

        if (this.hasAudioStreams) {
          Row() {
            Radio({ value: 'audio', group: 'video_audio_group' })
              .id('audio_button')
              // base.png samples the checked radio at pure black: the dialog theme's colorAccent
              // is @color/light_youtube_accent_color.
              .radioStyle({ checkedBackgroundColor: $r('app.color.accent') })
              .width(24)
              .height(24)
              .checked(this.selectedKind === DownloadKind.AUDIO)
              .enabled(this.radioButtonsEnabled)
              .onClick(() => {
                this.selectedKind = DownloadKind.AUDIO;
                this.onItemSelectedSetFileName();
                this.rememberKind();
                this.fetchStreamSizes(DownloadKind.AUDIO);
              })
            Text($r('app.string.audio'))
              .fontSize(16)
              .fontColor($r('app.color.on_surface'))
              .margin({ left: 4 })
          }
          .height(32)
          .margin({ right: 12 })
          .alignItems(VerticalAlign.Center)
        }

        if (this.hasSubtitleStreams) {
          Row() {
            Radio({ value: 'subtitle', group: 'video_audio_group' })
              .id('subtitle_button')
              // base.png samples the checked radio at pure black: the dialog theme's colorAccent
              // is @color/light_youtube_accent_color.
              .radioStyle({ checkedBackgroundColor: $r('app.color.accent') })
              .width(24)
              .height(24)
              .checked(this.selectedKind === DownloadKind.SUBTITLE)
              .enabled(this.radioButtonsEnabled)
              .onClick(() => {
                this.selectedKind = DownloadKind.SUBTITLE;
                this.selectedQualityIndex = this.selectedSubtitleIndex;
                this.onItemSelectedSetFileName();
                // The threads bar is disabled for a subtitle; the mission alone uses 1.
                this.rememberKind();
                this.fetchStreamSizes(DownloadKind.SUBTITLE);
              })
            Text($r('app.string.caption_setting_title'))
              .fontSize(16)
              .fontColor($r('app.color.on_surface'))
              .margin({ left: 4 })
          }
          .height(32)
          .margin({ right: 12 })
          .alignItems(VerticalAlign.Center)
        }
      }
      .id('video_audio_group')
      .width('100%')
      .padding({ left: 20 })
      .margin({ bottom: 6 })
      .alignItems(VerticalAlign.Center)

      // quality_spinner doubles as the SUBTITLE spinner; GONE for the audio kind.
      if (this.showQualitySpinner()) {
        Column() {
          // setupSubtitleSpinner points the SAME spinner at the subtitle adapter.
          Row() {
            this.spinnerCollapsed({
              formatName: this.selectedFormat(this.selectedKind === DownloadKind.SUBTITLE
                ? this.subtitleSpinner : this.qualitySpinner, this.selectedQualityIndex),
              quality: this.selectedLabel(this.selectedKind === DownloadKind.SUBTITLE
                ? this.subtitleSpinner : this.qualitySpinner, this.selectedQualityIndex),
              size: this.selectedSize(this.selectedKind === DownloadKind.SUBTITLE
                ? this.subtitleSpinner : this.qualitySpinner, this.selectedQualityIndex)
            })
          }
            .id('quality_spinner')
            .width('100%')
            .height(48)
            .bindMenu(this.qualityDropdownBody, SPINNER_MENU_OPTIONS)
        }
        .width('100%')
        // android:layout_margin 20/20/12 on each Spinner.
        .padding({ left: 20, right: 20 })
        .margin({ bottom: 12 })
      }

      // audio_track_spinner: the grouped tracks, drawn by the same row adapter as the other
      // two spinners so it floats over the dialog instead of growing the card.
      if (this.showAudioTrackSpinner()) {
        Column() {
          Row() {
            this.spinnerCollapsed({
              formatName: this.selectedFormat(this.audioTrackEntries(),
                this.selectedAudioTrackIndex),
              quality: this.selectedLabel(this.audioTrackEntries(), this.selectedAudioTrackIndex),
              size: ''
            })
          }
            .id('audio_track_spinner')
            .width('100%')
            .height(48)
            .bindMenu(this.audioTrackDropdownBody, SPINNER_MENU_OPTIONS)
        }
        .width('100%')
        // android:layout_margin 20/20/12 on each Spinner.
        .padding({ left: 20, right: 20 })
        .margin({ bottom: 12 })
      }

      // audio_stream_spinner: format + bitrate, VISIBLE only for the audio kind.
      if (this.showAudioStreamSpinner()) {
        Column() {
          Row() {
            this.spinnerCollapsed({
              formatName: this.selectedFormat(this.audioStreamSpinner,
                this.selectedAudioStreamIndex),
              quality: this.selectedLabel(this.audioStreamSpinner, this.selectedAudioStreamIndex),
              size: this.selectedSize(this.audioStreamSpinner, this.selectedAudioStreamIndex)
            })
          }
            .id('audio_stream_spinner')
            .width('100%')
            .height(48)
            .bindMenu(this.audioStreamDropdownBody, SPINNER_MENU_OPTIONS)
        }
        .width('100%')
        // android:layout_margin 20/20/12 on each Spinner.
        .padding({ left: 20, right: 20 })
        .margin({ bottom: 12 })
      }

      // The note REPLACES the track spinner when the chosen video already carries its audio.
      if (this.showAudioTrackPresentNote()) {
        Text($r('app.string.audio_track_present_in_video'))
          .id('audio_track_present_in_video_text')
          .width('100%')
          .textAlign(TextAlign.Center)
          .fontSize(12)
          .fontColor($r('app.color.on_surface_variant'))
          .padding({ left: 24, right: 24 })
          .margin({ bottom: 12 })
      }

      // threads ───────────────────────────────────────────────────────────────
      Text($r('app.string.msg_threads'))
        .id('threads_text_view')
        .width('100%')
        .fontSize(14)
        .fontColor($r('app.color.on_surface_variant'))
        .padding({ left: 24, right: 24 })
        .margin({ bottom: 6 })

      Row() {
        Text(this.threads.toString())
          .id('threads_count')
          .width(25)
          .padding({ left: 2 })
          .fontSize(14)
          .fontColor($r('app.color.on_surface'))

        // android:max="31", android:progress="3"; the count written to prefs is progress + 1.
        // base.png: a black thumb on a #CCCCCC track - the dialog theme's colorAccent.
        Slider({ value: this.threads - 1, min: 0, max: 31, step: 1 })
          .id('threads')
          .layoutWeight(1)
          .trackThickness(2)
          .trackColor('#CCCCCC')
          .selectedColor($r('app.color.accent'))
          .blockColor($r('app.color.accent'))
          .blockSize({ width: 14, height: 14 })
          .enabled(this.threadsEnabled())
          .onChange((value: number) => {
            this.threads = value + 1;
            // onProgressChanged(): the count is the new default the moment it moves.
            AppPreferences.putInt(DEFAULT_DOWNLOAD_THREADS_KEY, this.threads)
              .catch((err: BusinessError): void => {
                hilog.error(0x0000, TAG, 'default_download_threads: %{public}s', err.message);
              });
          })
      }
      .id('threads_layout')
      .width('100%')
      .padding({ left: 24, right: 24 })
      .margin({ bottom: 12 })
      .alignItems(VerticalAlign.Center)

      // The unnamed NewPipeTextView footer.
      Text($r('app.string.streams_not_yet_supported_removed'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .fontSize(12)
        .fontColor($r('app.color.on_surface_variant'))
        .padding({ left: 24, right: 24 })
        .margin({ bottom: 12 })
    }
    .width('100%')
    // The dialog window: base.png samples the body at #EEEEEE below the 56vp red toolbar.
    .backgroundColor($r('app.color.dialog_background'))
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * The quality/subtitle spinner's dropdown, as a menu so it floats over the dialog the way the
   * reference's does instead of growing the card. bindMenu is given the BUILDER, not a $$ flag:
   * the two-way form took the UI down on device (see T-0041 on the board).
   */
  @Builder
  qualityDropdownBody() {
    Scroll() {
      StreamItemAdapter({
        entries: this.selectedKind === DownloadKind.SUBTITLE
          ? this.subtitleSpinner : this.qualitySpinner,
        selectedIndex: this.selectedQualityIndex,
        onItemSelected: (index: number): void => {
          this.selectedQualityIndex = index;
          if (this.selectedKind === DownloadKind.SUBTITLE) {
            this.selectedSubtitleIndex = index;
            this.onItemSelectedSetFileName();
          }
          this.updateSelectedVideoIsVideoOnly();
          // onVideoStreamSelected() re-evaluates the audio-track visibility - S4 reads
          // isVideoOnly() off the newly selected stream.
        }
      })
    }
    .width(SPINNER_MENU_WIDTH)
    .constraintSize({ maxHeight: DROPDOWN_MAX_HEIGHT })
  }

  /** The audio-track spinner's dropdown, floating over the dialog like the other two. */
  @Builder
  audioTrackDropdownBody() {
    Scroll() {
      StreamItemAdapter({
        entries: this.audioTrackEntries(),
        selectedIndex: this.selectedAudioTrackIndex,
        onItemSelected: (index: number): void => {
          // Only an ACTUAL change re-runs updateSecondaryStreams()+fetchStreamsSize().
          if (index !== this.selectedAudioTrackIndex) {
            this.selectedAudioTrackIndex = index;
            this.onAudioTrackChanged();
          }
        }
      })
    }
    .width(SPINNER_MENU_WIDTH)
    .constraintSize({ maxHeight: DROPDOWN_MAX_HEIGHT })
  }

  /** The audio-stream spinner's dropdown, floating over the dialog like the quality one. */
  @Builder
  audioStreamDropdownBody() {
    Scroll() {
      StreamItemAdapter({
        entries: this.audioStreamSpinner,
        selectedIndex: this.selectedAudioStreamIndex,
        onItemSelected: (index: number): void => {
          this.selectedAudioStreamIndex = index;
        }
      })
    }
    .width(SPINNER_MENU_WIDTH)
    .constraintSize({ maxHeight: DROPDOWN_MAX_HEIGHT })
  }

  build() {
    Column() {
      if (this.showOverwriteDialog) {
        // AlertDialog.Builder: setTitle(download_dialog_title), setMessage(the state's string),
        // setNegativeButton(cancel), setPositiveButton(overwrite | generate_unique_name). The
        // port drew the two buttons and nothing else - no title, no message - so the dialog asked
        // a question it never printed, and the buttons sat stacked where the source has a row.
        Column() {
          Text($r('app.string.download_dialog_title'))
            .id('alertTitle')
            .width('100%')
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.on_surface'))
            .margin({ bottom: 12 })

          Text(this.overwriteMessage())
            .id('overwrite_dialog_message')
            .width('100%')
            .fontSize(16)
            .lineHeight(22)
            .fontColor($r('app.color.on_surface_variant'))
            .margin({ bottom: 20 })

          Row() {
            Button($r('app.string.cancel'))
              .id('button2')
              .type(ButtonType.Normal)
              .height(36)
              .borderRadius(2)
              .backgroundColor(Color.Transparent)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.on_surface'))
              .padding({ left: 8, right: 8 })
              .onClick(() => {
                // A null listener in the source: it dismisses without starting a download.
                this.showOverwriteDialog = false;
              })

            Button(this.overwriteState === MissionState.PendingRunning
              ? $r('app.string.generate_unique_name') : $r('app.string.overwrite'))
              .id('Overwrite')
              .type(ButtonType.Normal)
              .height(36)
              .borderRadius(2)
              .backgroundColor(Color.Transparent)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.on_surface'))
              .padding({ left: 8, right: 8 })
              .margin({ left: 8 })
              .onClick(() => {
                this.resolveOverwrite();
              })
          }
          .width('100%')
          .justifyContent(FlexAlign.End)
        }
        .id('overwrite_dialog')
        .width('100%')
        .padding({ left: 24, right: 24, top: 20, bottom: 12 })
        .backgroundColor($r('app.color.dialog_background'))
        .borderRadius(2)
        .alignItems(HorizontalAlign.Start)
      } else if (this.showFailedDialog) {
        // showFailedDialog(): R.string.general_error with a single dismissing OK.
        Column() {
          Text($r('app.string.general_error'))
            .id('failed_dialog_message')
            .width('100%')
            .fontSize(16)
            .fontColor($r('app.color.on_surface'))
            .margin({ bottom: 16 })

          Button($r('app.string.ok'))
            .id('OK')
            .type(ButtonType.Normal)
            .height(36)
            .borderRadius(2)
            .backgroundColor(Color.Transparent)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.on_surface'))
            .padding({ left: 8, right: 8 })
            .onClick(() => {
              this.showFailedDialog = false;
              // ...and with it the message it was raised for, or the load-error panel below
              // would take over a dialog whose streams actually loaded fine.
              this.errorInfo = null;
            })
        }
        .id('failed_dialog')
        .width('100%')
        .padding({ left: 24, right: 24, top: 20, bottom: 12 })
        .backgroundColor($r('app.color.dialog_background'))
        .borderRadius(2)
        .alignItems(HorizontalAlign.End)
      } else if (this.isLoading) {
        // The source shows a progress dialog while it prepares the download, and this screen
        // set isLoading for it and then drew NOTHING: the dialog looked ready while its
        // spinners were still empty and its OK was still dead.
        this.dialogToolbar()
        Column() {
          LoadingProgress()
            .id('download_dialog_loading_progress_bar')
            .width(48)
            .height(48)
            .color($r('app.color.primary'))
        }
        .width('100%')
        .height(180)
        .justifyContent(FlexAlign.Center)
      } else if (this.errorInfo !== null) {
        // ...and the same for errorInfo: the fetch's failure was recorded and never shown, so a
        // download started with no network simply sat on an empty form.
        this.dialogToolbar()
        Column() {
          Text(this.errorInfo)
            .id('download_dialog_error_message')
            .fontSize(16)
            .fontColor($r('app.color.on_surface_variant'))
            .textAlign(TextAlign.Center)
        }
        .id('download_dialog_error_panel')
        .width('100%')
        .height(180)
        .justifyContent(FlexAlign.Center)
        .padding(16)
      } else {
        this.dialogBody()
      }
    }
    .id('DownloadDialogPage')
    // A centred, self-sized card with square corners, not the whole screen: at 100% x 100% the
    // red toolbar sat in the status-bar band under the clock and the form trailed 1700px of
    // empty grey (TC-PLAYER-816). The hosts size nothing - customStyle / bindSheet both let the
    // content decide - so the width and the absence of a height are what make it a card.
    // ponytail: no Scroll - the body is ~1000px tall and fits every folded/unfolded orientation
    // of this device; wrap dialogBody() in a Scroll if a shorter window ever clips it.
    .width('92%')
    .borderRadius(0)
    .clip(true)
    .backgroundColor($r('app.color.dialog_background'))
  }
}

/**
 * DownloadDialogPage is a @Component, and a CustomDialogController's builder
 * HAS to be a @CustomDialog struct: handing it the @Component directly threw
 * "class constructor cannot called without 'new'" while the page's members were being built, so
 * the whole host page died before its first frame. This wrapper is the @CustomDialog the
 * controller wants and forwards the visibility @Link and the (serviceId, url) pair unchanged.
 */
@CustomDialog
export struct DownloadDialogHost {
  @Link isShown: boolean;
  @Prop serviceId: number = 0;
  @Prop url: string = '';
  controller?: CustomDialogController;

  build() {
    DownloadDialogPage({
      isShown: this.isShown,
      serviceId: this.serviceId,
      url: this.url
    })
  }
}
