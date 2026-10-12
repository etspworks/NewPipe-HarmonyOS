/*
 * Port of org.schabi.newpipe.extractor.services.youtube.extractors.YoutubeStreamExtractor
 * (NewPipeExtractor v0.26.5).
 *
 * 🟥 THE NSIG-FREE SUBSTITUTION LANDS HERE (phase2-logic-contract.md §2.3).
 *
 * The source calls YoutubeJavaScriptPlayerManager to (a) decipher a `signatureCipher` URL and
 * (b) deobfuscate the `n` throttling parameter. Both need a JavaScript engine, and ArkTS has
 * none — `@ohos.JSVM` is NDK-only, `eval`/`new Function` are banned, and NDK/wasm/sidecar
 * bridges are disallowed by Rule 11. So neither is ported, and instead:
 *
 *  - streams are resolved through the InnerTube clients whose player response hands out
 *    ready-to-play URLs: **IOS, then VISIONOS, then ANDROID** (NSIG_FREE_CLIENT_ORDER in
 *    ../YoutubeStreamHelper.ts). `fetchIosClient` therefore defaults to TRUE here, where Java
 *    defaults it to false and lets the app opt in — the Apple clients are the primary path now,
 *    not an extra;
 *  - a format that carries only a `signatureCipher` is SKIPPED, not deciphered, and the next
 *    client's formats are tried;
 *  - if every client yielded nothing but ciphered formats, getItags raises
 *    ContentNotAvailableException("stream unavailable for this client") rather than returning a
 *    silently empty list or fabricating a URL. An empty list with no ciphered format seen is a
 *    genuine "this stream type has no such formats" and is returned as the source returns it.
 *
 * Other deviations: `Pair` becomes the small StreamingDataSource class below; DateTimeFormatter
 * date parsing becomes explicit English month parsing; java.util.Locale becomes a BCP-47 string.
 */

import { JsonArray, JsonObject, JsonWriter } from '../../../json/NanoJson';
import { Downloader, Request } from '../../../downloader/Downloader';
import { Localization } from '../../../downloader/Localization';
import { ContentCountry } from '../../../localization/ContentCountry';
import { StreamingService } from '../../../core/StreamingService';
import { JsonUtils } from '../../../core/JsonUtils';
import {
  NO_AGE_LIMIT,
  Privacy,
  StreamExtractor,
  UNKNOWN_SUBSCRIBER_COUNT
} from '../../../info/StreamExtractor';
import { LinkHandler } from '../../../linkhandler/LinkHandler';
import { DateWrapper } from '../../../localization/DateWrapper';
import { TimeAgoParser } from '../../../localization/TimeAgoParser';
import { TimeAgoPatternsManager } from '../../../localization/TimeAgoPatternsManager';
import {
  AccountTerminatedException,
  AgeRestrictedContentException,
  ContentNotAvailableException,
  ExtractionException,
  GeographicRestrictionException,
  PaidContentException,
  ParsingException,
  PrivateContentException,
  SignInConfirmNotBotException,
  YoutubeMusicPremiumContentException
} from '../../../exceptions/Exceptions';
import { isNullOrEmpty, mixedNumberWordToLong, removeNonDigitCharacters } from '../../../core/Utils';
import { AudioStream, AudioStreamBuilder } from '../../../../../model/extractor/AudioStream';
import { Description, DESCRIPTION_HTML, DESCRIPTION_PLAIN_TEXT } from '../../../../../model/extractor/Description';
import { Frameset } from '../../../../../model/extractor/Frameset';
import { Image } from '../../../../../model/extractor/Image';
import { MetaInfo } from '../../../../../model/extractor/MetaInfo';
import { Stream } from '../../../../../model/extractor/Stream';
import { StreamSegment } from '../../../../../model/extractor/StreamSegment';
import { SubtitlesStream, SubtitlesStreamBuilder } from '../../../../../model/extractor/SubtitlesStream';
import { VideoStream, VideoStreamBuilder } from '../../../../../model/extractor/VideoStream';
import { DeliveryMethod } from '../../../../../model/enums/DeliveryMethod';
import { MediaFormat } from '../../../../../model/enums/MediaFormat';
import { StreamType } from '../../../../../model/enums/StreamType';
import { MultiInfoItemsCollector } from '../../../core/MultiInfoItemsCollector';
import {
  APPROX_DURATION_MS_UNKNOWN,
  CONTENT_LENGTH_UNKNOWN,
  ItagItem,
  ItagType
} from '../ItagItem';
import { ItagInfo } from './ItagInfo';
import { PoTokenProvider, PoTokenResult } from '../PoToken';
import {
  CONTENT_CHECK_OK,
  CPN,
  RACY_CHECK_OK,
  VIDEO_ID,
  extractAudioTrackType,
  fixThumbnailUrl,
  generateContentPlaybackNonce,
  getFirstCollaborator,
  getImagesFromThumbnailsArray,
  getJsonPostResponse,
  getTextFromObject,
  getTextFromObjectHtml,
  hasArtistOrVerifiedIconBadgeAttachment,
  isVerified,
  prepareDesktopJsonBuilder
} from '../YoutubeParsingHelper';
import { attributedDescriptionToHtml } from '../YoutubeDescriptionHelper';
import { getMetaInfo } from '../YoutubeMetaInfoHelper';
import {
  getAndroidPlayerResponse,
  getAndroidReelPlayerResponse,
  getIosPlayerResponse,
  getVisionOsPlayerResponse,
  getWebMetadataPlayerResponse
} from '../YoutubeStreamHelper';
import { YoutubeChannelLinkHandlerFactory } from '../linkHandler/YoutubeChannelLinkHandlerFactory';
import { YoutubeStreamInfoItemExtractor } from './YoutubeStreamInfoItemExtractor';
import { YoutubeMixOrPlaylistInfoItemExtractor } from './YoutubePlaylistInfoItemExtractor';
import { YoutubeMixOrPlaylistLockupInfoItemExtractor } from './YoutubeLockupInfoItemExtractors';
import { YoutubeStreamInfoItemLockupExtractor } from './YoutubeStreamInfoItemLockupExtractor';

const PREMIERED: string = 'Premiered ';
const PREMIERED_ON: string = 'Premiered on ';
const FORMATS: string = 'formats';
const ADAPTIVE_FORMATS: string = 'adaptiveFormats';
const STREAMING_DATA: string = 'streamingData';
const NEXT: string = 'next';
const SIGNATURE_CIPHER: string = 'signatureCipher';
const CIPHER: string = 'cipher';
const PLAYER_CAPTIONS_TRACKLIST_RENDERER: string = 'playerCaptionsTracklistRenderer';
const CAPTIONS: string = 'captions';
const PLAYABILITY_STATUS: string = 'playabilityStatus';
const THUMBNAIL: string = 'thumbnail';
const THUMBNAILS: string = 'thumbnails';
const VIDEO_DETAILS: string = 'videoDetails';
const TITLE: string = 'title';

const ENGLISH_MONTHS: string[] = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep',
  'Oct', 'Nov', 'Dec'];

/** Module-level statics, matching the source's static fields. */
let poTokenProvider: PoTokenProvider | null = null;
/**
 * Java defaults this to false; here it is TRUE, because the IOS client is the FIRST nsig-free
 * source of playable URLs (§2.3), not an optional extra the app switches on.
 */
let fetchIosClientFlag: boolean = true;

/** Registers the app-side WebView poToken provider; see ../PoToken.ts. */
export function setPoTokenProvider(provider: PoTokenProvider | null): void {
  poTokenProvider = provider;
}

export function setFetchIosClient(fetchIosClient: boolean): void {
  fetchIosClientFlag = fetchIosClient;
}

/** Stands in for the source's Pair<JsonObject, String>: one client's streaming data + poToken. */
class StreamingDataSource {
  readonly streamingData: JsonObject | null;
  readonly cpn: string;
  readonly poToken: string | null;

  constructor(streamingData: JsonObject | null, cpn: string, poToken: string | null) {
    this.streamingData = streamingData;
    this.cpn = cpn;
    this.poToken = poToken;
  }
}

/** Parse an English `MMM dd, yyyy` or `dd MMM yyyy` date; null when it does not match. */
function parseOptionalEnglishDate(date: string, dayFirst: boolean): Date | null {
  const pattern: RegExp = dayFirst
    ? new RegExp('^(\\d{1,2}) ([A-Za-z]{3})[a-z]* (\\d{4})$')
    : new RegExp('^([A-Za-z]{3})[a-z]* (\\d{1,2}), (\\d{4})$');
  pattern.lastIndex = 0;
  const match: RegExpExecArray | null = pattern.exec(date.trim());
  if (match === null) {
    return null;
  }
  const monthName: string = dayFirst ? match[2] : match[1];
  const dayText: string = dayFirst ? match[1] : match[2];
  const monthIndex: number = ENGLISH_MONTHS.indexOf(
    monthName.charAt(0).toUpperCase() + monthName.substring(1).toLowerCase());
  if (monthIndex < 0) {
    return null;
  }
  return new Date(Date.UTC(Number.parseInt(match[3], 10), monthIndex,
    Number.parseInt(dayText, 10), 0, 0, 0));
}

/** Java's Integer.parseInt on a JSON string field, with the source's default when absent. */
function parseIntOr(value: string | null, fallback: number): number {
  if (value === null) {
    return fallback;
  }
  const parsed: number = Number.parseInt(value, 10);
  return Number.isNaN(parsed) ? fallback : parsed;
}

export class YoutubeStreamExtractor extends StreamExtractor {
  private playerResponse: JsonObject = new JsonObject();
  private nextResponse: JsonObject = new JsonObject();
  private visionOsStreamingData: JsonObject | null = null;
  private iosStreamingData: JsonObject | null = null;
  private androidStreamingData: JsonObject | null = null;
  private videoPrimaryInfoRenderer: JsonObject | null = null;
  private videoSecondaryInfoRenderer: JsonObject | null = null;
  private playerMicroFormatRenderer: JsonObject = new JsonObject();
  private playerCaptionsTracklistRenderer: JsonObject = new JsonObject();
  private thumbnailsArray: JsonArray = new JsonArray();
  private ageLimit: number = -1;
  private streamType: StreamType = StreamType.VIDEO_STREAM;

  // The contentPlaybackNonces must be appended to videoplayback URLs (the cpn parameter). A nonce
  // should be unique, so it differs per client: three different strings.
  private visionOsCpn: string = '';
  private iosCpn: string = '';
  private androidCpn: string = '';

  private androidStreamingUrlsPoToken: string | null = null;
  private iosStreamingUrlsPoToken: string | null = null;

  constructor(service: StreamingService, linkHandler: LinkHandler) {
    super(service, linkHandler);
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Metadata
  ////////////////////////////////////////////////////////////////////////// */

  getName(): string {
    this.assertPageFetched();
    // Try to get the video's original, untranslated title first
    let title: string | null = this.playerResponse.getObject(VIDEO_DETAILS).getString(TITLE);
    if (isNullOrEmpty(title)) {
      title = getTextFromObject(this.getVideoPrimaryInfoRenderer().getObject(TITLE));
      if (isNullOrEmpty(title)) {
        throw new ParsingException('Could not get name');
      }
    }
    return title as string;
  }

  getTextualUploadDate(): string | null {
    let timestamp: string = this.playerMicroFormatRenderer.getString('uploadDate', '') as string;
    if (timestamp.length === 0) {
      timestamp = this.playerMicroFormatRenderer.getString('publishDate', '') as string;
    }
    if (timestamp.length > 0) {
      return timestamp;
    }

    const liveDetails: JsonObject =
      this.playerMicroFormatRenderer.getObject('liveBroadcastDetails');
    timestamp = liveDetails.getString('endTimestamp', '') as string; // an ended live stream
    if (timestamp.length === 0) {
      // a running live stream
      timestamp = liveDetails.getString('startTimestamp', '') as string;
    }
    if (timestamp.length > 0) {
      return timestamp;
    }
    if (this.getStreamType() === StreamType.LIVE_STREAM) {
      // Should never be reached, but a live stream without an upload date is valid
      return null;
    }

    const rendererDateText: string | null =
      getTextFromObject(this.getVideoPrimaryInfoRenderer().getObject('dateText'));
    if (rendererDateText === null) {
      return null;
    }
    if (rendererDateText.startsWith(PREMIERED_ON)) { // Premiered on 21 Feb 2020
      return rendererDateText.substring(PREMIERED_ON.length);
    }
    if (rendererDateText.startsWith(PREMIERED)) {
      // Premiered 20 hours ago / Premiered Feb 21, 2020
      return rendererDateText.substring(PREMIERED.length);
    }
    return rendererDateText;
  }

  getUploadDate(): DateWrapper | null {
    const dateText: string | null = this.getTextualUploadDate();
    if (dateText === null) {
      return null;
    }

    try {
      return DateWrapper.fromOffsetDateTime(dateText);
    } catch (e) {
      // Try the other patterns first
    }

    try { // Premiered 20 hours ago
      const parser: TimeAgoParser | null =
        TimeAgoPatternsManager.getTimeAgoParserFor(new Localization('en'));
      if (parser !== null) {
        return parser.parse(dateText);
      }
    } catch (e) {
      // Try the other patterns first
    }

    // TODO (as in the source): this parses English-formatted dates only
    let parsed: Date | null = parseOptionalEnglishDate(dateText, false); // MMM dd, yyyy
    if (parsed === null) {
      parsed = parseOptionalEnglishDate(dateText, true); // dd MMM yyyy
    }
    if (parsed !== null) {
      return new DateWrapper(parsed, true);
    }

    throw new ParsingException('Could not parse upload date \"' + dateText + '\"');
  }

  getThumbnails(): Image[] {
    this.assertPageFetched();
    try {
      return getImagesFromThumbnailsArray(this.thumbnailsArray);
    } catch (e) {
      throw new ParsingException('Could not get thumbnails');
    }
  }

  getDescription(): Description {
    this.assertPageFetched();

    // The description carrying the richer link info
    const videoSecondaryInfoRendererDescription: string | null = getTextFromObjectHtml(
      this.getVideoSecondaryInfoRenderer().getObject('description'), true);
    if (!isNullOrEmpty(videoSecondaryInfoRendererDescription)) {
      return new Description(videoSecondaryInfoRendererDescription, DESCRIPTION_HTML);
    }

    const attributedDescription: string | null = attributedDescriptionToHtml(
      this.getVideoSecondaryInfoRenderer().getObject('attributedDescription'));
    if (!isNullOrEmpty(attributedDescription)) {
      return new Description(attributedDescription, DESCRIPTION_HTML);
    }

    let description: string | null =
      this.playerResponse.getObject(VIDEO_DETAILS).getString('shortDescription');
    if (description === null) {
      description = getTextFromObject(this.playerMicroFormatRenderer.getObject('description'));
    }

    // The raw, non-html description
    return new Description(description, DESCRIPTION_PLAIN_TEXT);
  }

  getAgeLimit(): number {
    if (this.ageLimit !== -1) {
      return this.ageLimit;
    }

    let ageRestricted: boolean = false;
    for (const metadataRow of this.getVideoSecondaryInfoRenderer()
      .getObject('metadataRowContainer')
      .getObject('metadataRowContainerRenderer')
      .getArray('rows')
      .streamAsJsonObjects()) {
      for (const content of metadataRow.getObject('metadataRowRenderer').getArray('contents')
        .streamAsJsonObjects()) {
        for (const run of content.getArray('runs').streamAsJsonObjects()) {
          if ((run.getString('text', '') as string).includes('Age-restricted')) {
            ageRestricted = true;
            break;
          }
        }
      }
    }

    this.ageLimit = ageRestricted ? 18 : NO_AGE_LIMIT;
    return this.ageLimit;
  }

  getLength(): number {
    this.assertPageFetched();
    const duration: string | null =
      this.playerResponse.getObject(VIDEO_DETAILS).getString('lengthSeconds');
    const parsed: number = duration === null ? Number.NaN : Number.parseInt(duration, 10);
    if (!Number.isNaN(parsed)) {
      return parsed;
    }
    return this.getDurationFromFirstAdaptiveFormat(
      [this.androidStreamingData, this.iosStreamingData]);
  }

  private getDurationFromFirstAdaptiveFormat(streamingDatas: Array<JsonObject | null>): number {
    for (const streamingData of streamingDatas) {
      if (streamingData === null) {
        continue;
      }
      const adaptiveFormats: JsonArray = streamingData.getArray(ADAPTIVE_FORMATS);
      if (adaptiveFormats.size() === 0) {
        continue;
      }
      const durationMs: string | null =
        adaptiveFormats.getObject(0).getString('approxDurationMs');
      const parsed: number = durationMs === null ? Number.NaN : Number.parseInt(durationMs, 10);
      if (!Number.isNaN(parsed)) {
        return Math.round(parsed / 1000);
      }
    }
    throw new ParsingException('Could not get duration');
  }

  getTimeStamp(): number {
    const timestamp: number = this.getTimestampSeconds('((#|&|\\?)t=\\d*h?\\d*m?\\d+s?)');
    if (timestamp === -2) {
      // The timestamp regex did not match
      return 0;
    }
    return timestamp;
  }

  getViewCount(): number {
    let views: string | null = getTextFromObject(this.getVideoPrimaryInfoRenderer()
      .getObject('viewCount')
      .getObject('videoViewCountRenderer')
      .getObject('viewCount'));
    if (isNullOrEmpty(views)) {
      views = this.playerResponse.getObject(VIDEO_DETAILS).getString('viewCount');
      if (isNullOrEmpty(views)) {
        throw new ParsingException('Could not get view count');
      }
    }
    if ((views as string).toLowerCase().includes('no views')) {
      return 0;
    }
    return Number.parseInt(removeNonDigitCharacters(views as string), 10);
  }

  getLikeCount(): number {
    this.assertPageFetched();
    // With ratings disabled there is no like count
    if (!this.playerResponse.getObject(VIDEO_DETAILS).getBoolean('allowRatings')) {
      return -1;
    }

    const topLevelButtons: JsonArray = this.getVideoPrimaryInfoRenderer()
      .getObject('videoActions')
      .getObject('menuRenderer')
      .getArray('topLevelButtons');

    try {
      return YoutubeStreamExtractor.parseLikeCountFromLikeButtonViewModel(topLevelButtons);
    } catch (ignored) {
      // A segmentedLikeDislikeButtonRenderer can come back instead of the view-model shape, so
      // extraction errors on the view model are ignored
    }

    try {
      return YoutubeStreamExtractor.parseLikeCountFromLikeButtonRenderer(topLevelButtons);
    } catch (e) {
      throw new ParsingException('Could not get like count',
        e instanceof Error ? e as Error : null);
    }
  }

  private static parseLikeCountFromLikeButtonRenderer(topLevelButtons: JsonArray): number {
    let likesString: string | null = null;

    let likeToggleButtonRenderer: JsonObject | null = null;
    for (const button of topLevelButtons.streamAsJsonObjects()) {
      const renderer: JsonObject = button.getObject('segmentedLikeDislikeButtonRenderer')
        .getObject('likeButton')
        .getObject('toggleButtonRenderer');
      if (renderer.size() > 0) {
        likeToggleButtonRenderer = renderer;
        break;
      }
    }

    if (likeToggleButtonRenderer !== null) {
      // One of the available accessibility strings (same path as the comments' like count)
      likesString = likeToggleButtonRenderer.getObject('accessibilityData')
        .getObject('accessibilityData')
        .getString('label');
      // The other accessibility string, which carries the exact like count
      if (likesString === null) {
        likesString = likeToggleButtonRenderer.getObject('accessibility').getString('label');
      }
      // Last resort: defaultText's accessibility data, exact too except at 0 likes, where a
      // localized string comes back instead
      if (likesString === null) {
        likesString = likeToggleButtonRenderer.getObject('defaultText')
          .getObject('accessibility')
          .getObject('accessibilityData')
          .getString('label');
      }
      // This check only works with English localizations
      if (likesString !== null && likesString.toLowerCase().includes('no likes')) {
        return 0;
      }
    }

    // Ratings allowed and no likes string means the full like count could not be extracted
    if (likesString === null) {
      throw new ParsingException('Could not get like count from accessibility data');
    }

    const parsed: number = Number.parseInt(removeNonDigitCharacters(likesString), 10);
    if (Number.isNaN(parsed)) {
      throw new ParsingException('Could not parse \"' + likesString + '\" as a long');
    }
    return parsed;
  }

  private static parseLikeCountFromLikeButtonViewModel(topLevelButtons: JsonArray): number {
    // Try the current video-actions button structure first
    let likeToggleButtonViewModel: JsonObject | null = null;
    for (const button of topLevelButtons.streamAsJsonObjects()) {
      const buttonViewModel: JsonObject = button.getObject('segmentedLikeDislikeButtonViewModel')
        .getObject('likeButtonViewModel')
        .getObject('likeButtonViewModel')
        .getObject('toggleButtonViewModel')
        .getObject('toggleButtonViewModel')
        .getObject('defaultButtonViewModel')
        .getObject('buttonViewModel');
      if (buttonViewModel.size() > 0) {
        likeToggleButtonViewModel = buttonViewModel;
        break;
      }
    }

    if (likeToggleButtonViewModel === null) {
      throw new ParsingException('Could not find buttonViewModel object');
    }

    const accessibilityText: string | null =
      likeToggleButtonViewModel.getString('accessibilityText');
    if (accessibilityText === null) {
      throw new ParsingException('Could not find buttonViewModel\'s accessibilityText string');
    }

    // This element always carries the like count as a number, even for videos with no likes
    const parsed: number = Number.parseInt(removeNonDigitCharacters(accessibilityText), 10);
    if (Number.isNaN(parsed)) {
      throw new ParsingException('Could not parse \"' + accessibilityText + '\" as a long');
    }
    return parsed;
  }

  getUploaderUrl(): string {
    this.assertPageFetched();
    // The id in videoSecondaryRenderer is the DISPLAYED id, which differs from the real one on
    // music and auto-generated channels
    const uploaderId: string | null =
      this.playerResponse.getObject(VIDEO_DETAILS).getString('channelId');
    if (!isNullOrEmpty(uploaderId)) {
      return YoutubeChannelLinkHandlerFactory.getInstance().getUrl('channel/' + uploaderId);
    }
    throw new ParsingException('Could not get uploader url');
  }

  getUploaderName(): string {
    this.assertPageFetched();
    // As above: the name in videoSecondaryRenderer is the displayed one
    const uploaderName: string | null =
      this.playerResponse.getObject(VIDEO_DETAILS).getString('author');
    if (isNullOrEmpty(uploaderName)) {
      throw new ParsingException('Could not get uploader name');
    }
    return uploaderName as string;
  }

  isUploaderVerified(): boolean {
    const videoOwnerRenderer: JsonObject = this.getVideoSecondaryInfoRenderer()
      .getObject('owner')
      .getObject('videoOwnerRenderer');

    if (videoOwnerRenderer.has('badges')) {
      return isVerified(videoOwnerRenderer.getArray('badges'));
    }

    const channel: JsonObject | null =
      getFirstCollaborator(videoOwnerRenderer.getObject('navigationEndpoint'));
    if (channel === null) {
      return false;
    }
    return hasArtistOrVerifiedIconBadgeAttachment(
      channel.getObject(TITLE).getArray('attachmentRuns'));
  }

  getUploaderAvatars(): Image[] {
    this.assertPageFetched();
    const owner: JsonObject = this.getVideoSecondaryInfoRenderer()
      .getObject('owner')
      .getObject('videoOwnerRenderer');

    let imageList: Image[];
    if (owner.has('avatarStack')) {
      imageList = getImagesFromThumbnailsArray(owner.getObject('avatarStack')
        .getObject('avatarStackViewModel')
        .getArray('avatars')
        // only the first collaborator, which is the video owner
        .getObject(0)
        .getObject('avatarViewModel')
        .getObject('image')
        .getArray('sources'));
    } else {
      imageList = getImagesFromThumbnailsArray(owner.getObject(THUMBNAIL).getArray(THUMBNAILS));
    }

    if (imageList.length === 0 && this.ageLimit === NO_AGE_LIMIT) {
      throw new ParsingException('Could not get uploader avatars');
    }
    return imageList;
  }

  getUploaderSubscriberCount(): number {
    const videoOwnerRenderer: JsonObject =
      JsonUtils.getObject(this.getVideoSecondaryInfoRenderer(), 'owner.videoOwnerRenderer');

    let subscriberCountText: string | null = null;
    if (videoOwnerRenderer.has('subscriberCountText')) {
      subscriberCountText = getTextFromObject(videoOwnerRenderer.getObject('subscriberCountText'));
    } else {
      const collaborator: JsonObject | null =
        getFirstCollaborator(videoOwnerRenderer.getObject('navigationEndpoint'));
      if (collaborator !== null) {
        const content: string = collaborator.getObject('subtitle')
          .getString('content', '') as string;
        const parts: string[] = content.split('•');
        if (parts.length > 1) {
          subscriberCountText = parts[1];
        }
      }
    }

    if (isNullOrEmpty(subscriberCountText)) {
      return UNKNOWN_SUBSCRIBER_COUNT;
    }
    try {
      return mixedNumberWordToLong(subscriberCountText as string);
    } catch (e) {
      throw new ParsingException('Could not get uploader subscriber count',
        e instanceof Error ? e as Error : null);
    }
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Manifests and streams
  ////////////////////////////////////////////////////////////////////////// */

  getDashMpdUrl(): string {
    this.assertPageFetched();
    // The iOS and visionOS clients carry no DASH manifest.
    // NOTE (§2.5): AVPlayer is never fed a DASH .mpd; this getter exists because StreamInfo
    // reads it, and the player lane ignores it in favour of progressive / HLS.
    return YoutubeStreamExtractor.getManifestUrl('dash',
      [new StreamingDataSource(this.androidStreamingData, '', this.androidStreamingUrlsPoToken)],
      // Version 7 is the latest DASH manifest, smaller and playable by more DASH players
      'mpd_version=7');
  }

  getHlsUrl(): string {
    this.assertPageFetched();
    // An Apple client's HLS manifest comes first: on livestreams it separates audio and video,
    // and non-Apple clients carry no HLS manifest URL for videos at all
    return YoutubeStreamExtractor.getManifestUrl('hls',
      [new StreamingDataSource(this.visionOsStreamingData, '', null),
        new StreamingDataSource(this.iosStreamingData, '', this.iosStreamingUrlsPoToken),
        new StreamingDataSource(this.androidStreamingData, '',
          this.androidStreamingUrlsPoToken)],
      '');
  }

  private static getManifestUrl(manifestType: string, sources: StreamingDataSource[],
    partToAppendToManifestUrlEnd: string): string {
    const manifestKey: string = manifestType + 'ManifestUrl';
    for (const source of sources) {
      const streamingData: JsonObject | null = source.streamingData;
      if (streamingData === null) {
        continue;
      }
      const manifestUrl: string | null = streamingData.getString(manifestKey);
      if (isNullOrEmpty(manifestUrl)) {
        continue;
      }
      if (source.poToken === null) {
        return manifestUrl + '?' + partToAppendToManifestUrlEnd;
      }
      return manifestUrl + '?pot=' + source.poToken + '&' + partToAppendToManifestUrlEnd;
    }
    return '';
  }

  async getAudioStreams(): Promise<AudioStream[]> {
    this.assertPageFetched();
    return this.getAudioItags();
  }

  async getVideoStreams(): Promise<VideoStream[]> {
    this.assertPageFetched();
    return this.getVideoItags(FORMATS, ItagType.VIDEO, false, 'video');
  }

  async getVideoOnlyStreams(): Promise<VideoStream[]> {
    this.assertPageFetched();
    return this.getVideoItags(ADAPTIVE_FORMATS, ItagType.VIDEO_ONLY, true, 'video-only');
  }

  async getSubtitlesDefault(): Promise<SubtitlesStream[]> {
    return this.getSubtitles(MediaFormat.TTML);
  }

  async getSubtitles(format: MediaFormat): Promise<SubtitlesStream[]> {
    this.assertPageFetched();
    // The subtitles list is not cached, because the media format can change
    const subtitlesToReturn: SubtitlesStream[] = [];
    const captionsArray: JsonArray =
      this.playerCaptionsTracklistRenderer.getArray('captionTracks');

    for (let i = 0; i < captionsArray.size(); i++) {
      const caption: JsonObject = captionsArray.getObject(i);
      const languageCode: string | null = caption.getString('languageCode');
      const baseUrl: string | null = caption.getString('baseUrl');
      const vssId: string | null = caption.getString('vssId');

      if (languageCode !== null && baseUrl !== null && vssId !== null) {
        const isAutoGenerated: boolean = vssId.startsWith('a.');
        const cleanUrl: string = baseUrl
          // Remove a preexisting format, if any
          .replace(new RegExp('&fmt=[^&]*', 'g'), '')
          // Remove the translation language
          .replace(new RegExp('&tlang=[^&]*', 'g'), '');

        subtitlesToReturn.push(new SubtitlesStreamBuilder()
          .setContent(cleanUrl + '&fmt=' + format.getSuffix(), true)
          .setMediaFormat(format)
          .setLanguageCode(languageCode)
          .setAutoGenerated(isAutoGenerated)
          .build());
      }
    }

    return subtitlesToReturn;
  }

  getStreamType(): StreamType {
    this.assertPageFetched();
    return this.streamType;
  }

  private setStreamType(): void {
    if (this.playerResponse.getObject(PLAYABILITY_STATUS).has('liveStreamability')) {
      this.streamType = StreamType.LIVE_STREAM;
    } else if (this.playerResponse.getObject(VIDEO_DETAILS).getBoolean('isPostLiveDvr', false)) {
      this.streamType = StreamType.POST_LIVE_STREAM;
    } else {
      this.streamType = StreamType.VIDEO_STREAM;
    }
  }

  async getRelatedItems(): Promise<MultiInfoItemsCollector | null> {
    this.assertPageFetched();
    if (this.getAgeLimit() !== NO_AGE_LIMIT) {
      return null;
    }

    try {
      const collector: MultiInfoItemsCollector =
        new MultiInfoItemsCollector(this.getServiceId());
      const results: JsonArray = this.nextResponse
        .getObject('contents')
        .getObject('twoColumnWatchNextResults')
        .getObject('secondaryResults')
        .getObject('secondaryResults')
        .getArray('results');
      const timeAgoParser: TimeAgoParser = this.getTimeAgoParser();

      for (const result of results.streamAsJsonObjects()) {
        if (result.has('compactVideoRenderer')) {
          collector.commit(new YoutubeStreamInfoItemExtractor(
            result.getObject('compactVideoRenderer'), timeAgoParser));
        } else if (result.has('compactRadioRenderer')) {
          collector.commit(new YoutubeMixOrPlaylistInfoItemExtractor(
            result.getObject('compactRadioRenderer')));
        } else if (result.has('compactPlaylistRenderer')) {
          collector.commit(new YoutubeMixOrPlaylistInfoItemExtractor(
            result.getObject('compactPlaylistRenderer')));
        } else if (result.has('lockupViewModel')) {
          const lockupViewModel: JsonObject = result.getObject('lockupViewModel');
          const contentType: string | null = lockupViewModel.getString('contentType');
          if (contentType === 'LOCKUP_CONTENT_TYPE_PLAYLIST'
            || contentType === 'LOCKUP_CONTENT_TYPE_PODCAST') {
            collector.commit(
              new YoutubeMixOrPlaylistLockupInfoItemExtractor(lockupViewModel));
          } else if (contentType === 'LOCKUP_CONTENT_TYPE_VIDEO') {
            collector.commit(
              new YoutubeStreamInfoItemLockupExtractor(lockupViewModel, timeAgoParser));
          }
        }
      }

      return collector;
    } catch (e) {
      throw new ParsingException('Could not get related videos',
        e instanceof Error ? e as Error : null);
    }
  }

  getErrorMessage(): string | null {
    try {
      return getTextFromObject(this.playerResponse.getObject(PLAYABILITY_STATUS)
        .getObject('errorScreen')
        .getObject('playerErrorMessageRenderer')
        .getObject('reason'));
    } catch (e) {
      return null; // No error message
    }
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Fetch page
  ////////////////////////////////////////////////////////////////////////// */

  async onFetchPage(downloader: Downloader): Promise<void> {
    const videoId: string = this.getId();
    const localization: Localization = this.getExtractorLocalization();
    const contentCountry: ContentCountry = this.getExtractorContentCountry();

    const provider: PoTokenProvider | null = poTokenProvider;
    const androidPoTokenResult: PoTokenResult | null =
      provider === null ? null : provider.getAndroidClientPoToken(videoId);

    await this.fetchAndroidClient(localization, contentCountry, videoId, androidPoTokenResult);
    this.setStreamType();

    if (fetchIosClientFlag) {
      const iosPoTokenResult: PoTokenResult | null =
        provider === null ? null : provider.getIosClientPoToken(videoId);
      await this.fetchIosClient(localization, contentCountry, videoId, iosPoTokenResult);
    }

    await this.fetchVisionOsClient(localization, contentCountry, videoId);
    await this.fetchWebClientMetadataAndSetThumbnails(localization, contentCountry, videoId);

    const nextBody: ArrayBuffer = Request.utf8Body(JsonWriter.stringValue(
      (await prepareDesktopJsonBuilder(localization, contentCountry))
        .value(VIDEO_ID, videoId)
        .value(CONTENT_CHECK_OK, true)
        .value(RACY_CHECK_OK, true)
        .done()));

    this.nextResponse = await getJsonPostResponse(NEXT, nextBody, localization);
  }

  private static checkPlayabilityStatus(playabilityStatus: JsonObject): void {
    const status: string | null = playabilityStatus.getString('status');
    if (status === null || status.toUpperCase() === 'OK') {
      return;
    }

    const reason: string | null = playabilityStatus.getString('reason');
    if (reason !== null) {
      const upperStatus: string = status.toUpperCase();
      if (upperStatus === 'LOGIN_REQUIRED') {
        if (reason.includes('inappropriate for some users')) {
          throw new AgeRestrictedContentException(
            'This age-restricted video cannot be watched anonymously');
        }
        if (reason.includes('private')) {
          throw new PrivateContentException('This video is private');
        }
        if (reason.includes('a bot')) {
          throw new SignInConfirmNotBotException(
            'YouTube probably temporarily blocked anonymous watch access with this IP , got error '
            + status + ': \"' + reason + '\"');
        }
      }
      if (upperStatus === 'UNPLAYABLE' || upperStatus === 'ERROR') {
        if (reason.includes('Music Premium')) {
          throw new YoutubeMusicPremiumContentException();
        }
        if (reason.includes('payment')) {
          throw new PaidContentException('This video is a paid video');
        }
        if (reason.includes('members')) {
          throw new PaidContentException(
            'This video is only available for members of the channel of this video');
        }
        if (reason.includes('country')) {
          throw new GeographicRestrictionException(
            'This video is not available in client\'s country.');
        }
        if (reason.includes('closed') || reason.includes('terminated')) {
          throw new AccountTerminatedException(reason);
        }
      }
    }

    throw new ContentNotAvailableException('Got error ' + status + ': \"' + reason + '\"');
  }

  private async fetchAndroidClient(localization: Localization, contentCountry: ContentCountry,
    videoId: string, androidPoTokenResult: PoTokenResult | null): Promise<void> {
    this.androidCpn = generateContentPlaybackNonce();

    if (androidPoTokenResult === null) {
      this.playerResponse = await getAndroidReelPlayerResponse(contentCountry, localization,
        videoId, this.androidCpn);
    } else {
      this.playerResponse = await getAndroidPlayerResponse(contentCountry, localization, videoId,
        this.androidCpn, androidPoTokenResult);
    }

    YoutubeStreamExtractor.checkPlayabilityStatus(
      this.playerResponse.getObject(PLAYABILITY_STATUS));

    if (YoutubeStreamExtractor.isPlayerResponseNotValid(this.playerResponse, videoId)) {
      throw new ExtractionException('ANDROID player response is not valid');
    }

    this.androidStreamingData = this.playerResponse.getObject(STREAMING_DATA);
    this.playerCaptionsTracklistRenderer = this.playerResponse.getObject(CAPTIONS)
      .getObject(PLAYER_CAPTIONS_TRACKLIST_RENDERER);

    if (androidPoTokenResult !== null) {
      this.androidStreamingUrlsPoToken = androidPoTokenResult.streamingDataPoToken;
    }
  }

  private async fetchIosClient(localization: Localization, contentCountry: ContentCountry,
    videoId: string, iosPoTokenResult: PoTokenResult | null): Promise<void> {
    try {
      this.iosCpn = generateContentPlaybackNonce();
      const iosPlayerResponse: JsonObject = await getIosPlayerResponse(contentCountry,
        localization, videoId, this.iosCpn, iosPoTokenResult);

      if (!YoutubeStreamExtractor.isPlayerResponseNotValid(iosPlayerResponse, videoId)) {
        this.iosStreamingData = iosPlayerResponse.getObject(STREAMING_DATA);
        if (this.playerCaptionsTracklistRenderer.size() === 0) {
          this.playerCaptionsTracklistRenderer = iosPlayerResponse.getObject(CAPTIONS)
            .getObject(PLAYER_CAPTIONS_TRACKLIST_RENDERER);
        }
        if (iosPoTokenResult !== null) {
          this.iosStreamingUrlsPoToken = iosPoTokenResult.streamingDataPoToken;
        }
      }
    } catch (ignored) {
      // Fetching or parsing the IOS client is not compulsory to play content, so its failures
      // are ignored and the next client is tried
    }
  }

  private async fetchVisionOsClient(localization: Localization, contentCountry: ContentCountry,
    videoId: string): Promise<void> {
    try {
      this.visionOsCpn = generateContentPlaybackNonce();
      const visionOsPlayerResponse: JsonObject = await getVisionOsPlayerResponse(contentCountry,
        localization, videoId, this.visionOsCpn);

      if (!YoutubeStreamExtractor.isPlayerResponseNotValid(visionOsPlayerResponse, videoId)) {
        this.visionOsStreamingData = visionOsPlayerResponse.getObject(STREAMING_DATA);
        if (this.playerCaptionsTracklistRenderer.size() === 0) {
          this.playerCaptionsTracklistRenderer = visionOsPlayerResponse.getObject(CAPTIONS)
            .getObject(PLAYER_CAPTIONS_TRACKLIST_RENDERER);
        }
      }
    } catch (ignored) {
      // As above: a VISIONOS failure is not fatal
    }
  }

  private async fetchWebClientMetadataAndSetThumbnails(localization: Localization,
    contentCountry: ContentCountry, videoId: string): Promise<void> {
    try {
      const webPlayerResponse: JsonObject =
        await getWebMetadataPlayerResponse(localization, contentCountry, videoId);

      // Deliberately NO checkPlayabilityStatus() here: this request is used for metadata only,
      // and the metadata is often present even when YouTube reports a playability error
      if (!YoutubeStreamExtractor.isPlayerResponseNotValid(webPlayerResponse, videoId)) {
        // The microformat object is only returned on the WEB client, so it is stored rather than
        // read back off playerResponse
        this.playerMicroFormatRenderer = webPlayerResponse.getObject('microformat')
          .getObject('playerMicroformatRenderer');

        // The web player response's thumbnails should be higher quality than the mobile ones
        const thumbnailWebJsonObj: JsonObject = webPlayerResponse.getObject(VIDEO_DETAILS)
          .getObject(THUMBNAIL);
        if (thumbnailWebJsonObj.has(THUMBNAILS)) {
          this.thumbnailsArray = thumbnailWebJsonObj.getArray(THUMBNAILS);
        } else {
          this.thumbnailsArray = this.playerResponse.getObject(VIDEO_DETAILS)
            .getObject(THUMBNAIL)
            .getArray(THUMBNAILS);
        }
      }
    } catch (e) {
      // A WEB client failure is not compulsory to play content; fall back to playerResponse
      this.playerMicroFormatRenderer = new JsonObject();
      this.thumbnailsArray = this.playerResponse.getObject(VIDEO_DETAILS)
        .getObject(THUMBNAIL)
        .getArray(THUMBNAILS);
    }
  }

  /** A player response for a different video than the one requested is not usable. */
  private static isPlayerResponseNotValid(playerResponse: JsonObject, videoId: string): boolean {
    return playerResponse.getObject(VIDEO_DETAILS).getString('videoId') !== videoId;
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Utils
  ////////////////////////////////////////////////////////////////////////// */

  private getVideoPrimaryInfoRenderer(): JsonObject {
    let renderer: JsonObject | null = this.videoPrimaryInfoRenderer;
    if (renderer === null) {
      renderer = this.getVideoInfoRenderer('videoPrimaryInfoRenderer');
      this.videoPrimaryInfoRenderer = renderer;
    }
    return renderer;
  }

  private getVideoSecondaryInfoRenderer(): JsonObject {
    let renderer: JsonObject | null = this.videoSecondaryInfoRenderer;
    if (renderer === null) {
      renderer = this.getVideoInfoRenderer('videoSecondaryInfoRenderer');
      this.videoSecondaryInfoRenderer = renderer;
    }
    return renderer;
  }

  private getVideoInfoRenderer(videoRendererName: string): JsonObject {
    for (const content of this.nextResponse.getObject('contents')
      .getObject('twoColumnWatchNextResults')
      .getObject('results')
      .getObject('results')
      .getArray('contents')
      .streamAsJsonObjects()) {
      if (content.has(videoRendererName)) {
        return content.getObject(videoRendererName);
      }
    }
    return new JsonObject();
  }

  /** The three clients' streaming data, in the source's order. */
  private streamingDataSources(): StreamingDataSource[] {
    return [
      new StreamingDataSource(this.androidStreamingData, this.androidCpn,
        this.androidStreamingUrlsPoToken),
      new StreamingDataSource(this.visionOsStreamingData, this.visionOsCpn, null),
      new StreamingDataSource(this.iosStreamingData, this.iosCpn, this.iosStreamingUrlsPoToken)
    ];
  }

  /**
   * Port of getItags() for audio. The generic + Function<ItagInfo, T> of the source collapses
   * into one method per stream kind, because ArkTS cannot express the builder-helper generic
   * without an `any`.
   */
  private getAudioItags(): AudioStream[] {
    try {
      const videoId: string = this.getId();
      const streamList: AudioStream[] = [];
      let skippedCipheredFormats: number = 0;

      for (const source of this.streamingDataSources()) {
        const collected: ItagInfo[] = this.getStreamsFromStreamingDataKey(videoId,
          source.streamingData, ADAPTIVE_FORMATS, ItagType.AUDIO, source.cpn, source.poToken);
        skippedCipheredFormats += this.lastSkippedCipheredFormats;

        for (const itagInfo of collected) {
          const stream: AudioStream = this.buildAudioStream(itagInfo);
          if (!Stream.containSimilarStream(stream, streamList)) {
            streamList.push(stream);
          }
        }
      }

      YoutubeStreamExtractor.assertNotOnlyCiphered(streamList.length, skippedCipheredFormats,
        'audio');
      return streamList;
    } catch (e) {
      if (e instanceof ContentNotAvailableException) {
        throw e;
      }
      throw new ParsingException('Could not get audio streams',
        e instanceof Error ? e as Error : null);
    }
  }

  /** Port of getItags() for the two video kinds. */
  private getVideoItags(streamingDataKey: string, itagTypeWanted: ItagType,
    areStreamsVideoOnly: boolean, streamTypeExceptionMessage: string): VideoStream[] {
    try {
      const videoId: string = this.getId();
      const streamList: VideoStream[] = [];
      let skippedCipheredFormats: number = 0;

      for (const source of this.streamingDataSources()) {
        const collected: ItagInfo[] = this.getStreamsFromStreamingDataKey(videoId,
          source.streamingData, streamingDataKey, itagTypeWanted, source.cpn, source.poToken);
        skippedCipheredFormats += this.lastSkippedCipheredFormats;

        for (const itagInfo of collected) {
          const stream: VideoStream = this.buildVideoStream(itagInfo, areStreamsVideoOnly);
          if (!Stream.containSimilarStream(stream, streamList)) {
            streamList.push(stream);
          }
        }
      }

      YoutubeStreamExtractor.assertNotOnlyCiphered(streamList.length, skippedCipheredFormats,
        streamTypeExceptionMessage);
      return streamList;
    } catch (e) {
      if (e instanceof ContentNotAvailableException) {
        throw e;
      }
      throw new ParsingException('Could not get ' + streamTypeExceptionMessage + ' streams',
        e instanceof Error ? e as Error : null);
    }
  }

  /**
   * §2.3: surface "stream unavailable for this client" instead of an empty list, but ONLY when
   * formats really were dropped for being ciphered. No formats at all is a legitimate empty
   * result (e.g. a live stream has no progressive formats) and is returned as such.
   */
  private static assertNotOnlyCiphered(built: number, skippedCiphered: number,
    streamKind: string): void {
    if (built === 0 && skippedCiphered > 0) {
      throw new ContentNotAvailableException('This video\'s ' + streamKind + ' streams are all'
        + ' signature-ciphered, which needs a JavaScript engine this platform does not have —'
        + ' stream unavailable for this client');
    }
  }

  /** Set by getStreamsFromStreamingDataKey; read straight after, by the two getItags. */
  private lastSkippedCipheredFormats: number = 0;

  private buildAudioStream(itagInfo: ItagInfo): AudioStream {
    const itagItem: ItagItem = itagInfo.getItagItem();
    const builder: AudioStreamBuilder = new AudioStreamBuilder()
      .setId('' + itagItem.id)
      .setContent(itagInfo.getContent(), itagInfo.getIsUrl())
      .setMediaFormat(itagItem.getMediaFormat())
      .setAverageBitrate(itagItem.getAverageBitrate())
      .setAudioTrackId(itagItem.getAudioTrackId())
      .setAudioTrackName(itagItem.getAudioTrackName())
      .setAudioLocale(itagItem.getAudioLocale())
      .setAudioTrackType(itagItem.getAudioTrackType())
      .setItagItem(itagItem);

    if (this.streamType === StreamType.LIVE_STREAM
      || this.streamType === StreamType.POST_LIVE_STREAM
      || !itagInfo.getIsUrl()) {
      // OTF streams, and every stream of a post-live or live stream, can only use DASH
      builder.setDeliveryMethod(DeliveryMethod.DASH);
    }
    return builder.build();
  }

  private buildVideoStream(itagInfo: ItagInfo, areStreamsVideoOnly: boolean): VideoStream {
    const itagItem: ItagItem = itagInfo.getItagItem();
    const builder: VideoStreamBuilder = new VideoStreamBuilder()
      .setId('' + itagItem.id)
      .setContent(itagInfo.getContent(), itagInfo.getIsUrl())
      .setMediaFormat(itagItem.getMediaFormat())
      .setIsVideoOnly(areStreamsVideoOnly)
      .setItagItem(itagItem);

    const resolutionString: string | null = itagItem.getResolutionString();
    builder.setResolution(resolutionString !== null ? resolutionString : '');

    if (this.streamType !== StreamType.VIDEO_STREAM || !itagInfo.getIsUrl()) {
      // As above: OTF and (post-)live streams can only use DASH
      builder.setDeliveryMethod(DeliveryMethod.DASH);
    }
    return builder.build();
  }

  private getStreamsFromStreamingDataKey(videoId: string, streamingData: JsonObject | null,
    streamingDataKey: string, itagTypeWanted: ItagType, contentPlaybackNonce: string,
    poToken: string | null): ItagInfo[] {
    this.lastSkippedCipheredFormats = 0;
    if (streamingData === null || !streamingData.has(streamingDataKey)) {
      return [];
    }

    const result: ItagInfo[] = [];
    for (const formatData of streamingData.getArray(streamingDataKey).streamAsJsonObjects()) {
      try {
        const itagItem: ItagItem = ItagItem.getItag(formatData.getInt('itag'));
        if (itagItem.itagType !== itagTypeWanted) {
          continue;
        }
        if (!formatData.has('url')) {
          /*
           * 🟥 NSIG-FREE (§2.3). The source would decipher this format's `signatureCipher` with
           * YoutubeJavaScriptPlayerManager and then deobfuscate its `n` throttling parameter;
           * neither is possible without a JavaScript engine, so the format is SKIPPED and the
           * next client's formats are tried — which is exactly why the ANDROID / IOS / VISIONOS
           * clients are requested: their player responses carry a plain `url`.
           * Counting the skips is what turns an all-ciphered video into an explicit
           * "stream unavailable for this client" instead of a silently empty list.
           */
          if (!isNullOrEmpty(formatData.getString(CIPHER,
            formatData.getString(SIGNATURE_CIPHER)))) {
            this.lastSkippedCipheredFormats++;
          }
          continue;
        }
        result.push(this.buildItagInfo(formatData, itagItem, itagItem.itagType,
          contentPlaybackNonce, poToken));
      } catch (ignored) {
        // An unsupported itag, or a buildItagInfo failure, ends up here, as in the source
      }
    }
    return result;
  }

  /** Only ever called for a format that carries a plain `url`; see the caller's nsig-free note. */
  private buildItagInfo(formatData: JsonObject, itagItem: ItagItem, itagType: ItagType,
    contentPlaybackNonce: string, poToken: string | null): ItagInfo {
    let streamUrl: string = formatData.getString('url', '') as string;

    // Add the content playback nonce to the stream URL
    streamUrl += '&' + CPN + '=' + contentPlaybackNonce;
    // Add the poToken, if there is one
    if (poToken !== null) {
      streamUrl += '&pot=' + poToken;
    }

    const initRange: JsonObject = formatData.getObject('initRange');
    const indexRange: JsonObject = formatData.getObject('indexRange');
    const mimeType: string = formatData.getString('mimeType', '') as string;
    const codec: string = mimeType.includes('codecs') ? mimeType.split('"')[1] : '';

    itagItem.setBitrate(formatData.getInt('bitrate'));
    itagItem.setWidth(formatData.getInt('width'));
    itagItem.setHeight(formatData.getInt('height'));
    itagItem.setInitStart(parseIntOr(initRange.getString('start', '-1'), -1));
    itagItem.setInitEnd(parseIntOr(initRange.getString('end', '-1'), -1));
    itagItem.setIndexStart(parseIntOr(indexRange.getString('start', '-1'), -1));
    itagItem.setIndexEnd(parseIntOr(indexRange.getString('end', '-1'), -1));
    itagItem.setQuality(formatData.getString('quality', '') as string);
    itagItem.setCodec(codec);
    itagItem.setIsDrc(formatData.getBoolean('isDrc', false));
    itagItem.setLastModified(parseIntOr(formatData.getString('lastModified', '-1'), -1));
    itagItem.setXtags(formatData.getString('xtags', '') as string);

    if (this.streamType === StreamType.LIVE_STREAM
      || this.streamType === StreamType.POST_LIVE_STREAM) {
      itagItem.setTargetDurationSec(formatData.getInt('targetDurationSec'));
    }

    if (itagType === ItagType.VIDEO || itagType === ItagType.VIDEO_ONLY) {
      itagItem.setFps(formatData.getInt('fps'));
    } else if (itagType === ItagType.AUDIO) {
      // YouTube returns the audio sample rate as a string
      itagItem.setSampleRate(parseIntOr(formatData.getString('audioSampleRate'), -1));
      // Most audio streams have two channels; using that default prevents an exception when
      // building the AudioChannelConfiguration element of a DASH manifest
      itagItem.setAudioChannels(formatData.getInt('audioChannels', 2));

      const audioTrackId: string | null = formatData.getObject('audioTrack').getString('id');
      if (!isNullOrEmpty(audioTrackId)) {
        const trackId: string = audioTrackId as string;
        itagItem.setAudioTrackId(trackId);
        const audioTrackIdLastLocaleCharacter: number = trackId.indexOf('.');
        if (audioTrackIdLastLocaleCharacter !== -1) {
          // Audio track IDs are of the form LANGUAGE_CODE.TRACK_NUMBER; the locale is a BCP-47
          // string in this port
          itagItem.setAudioLocale(trackId.substring(0, audioTrackIdLastLocaleCharacter));
        }
        itagItem.setAudioTrackType(extractAudioTrackType(itagItem.getXtags()));
      }
      itagItem.setAudioTrackName(formatData.getObject('audioTrack').getString('displayName'));
    }

    // YouTube returns the content length and the approximate duration as strings
    itagItem.setContentLength(parseIntOr(formatData.getString('contentLength'),
      CONTENT_LENGTH_UNKNOWN));
    itagItem.setApproxDurationMs(parseIntOr(formatData.getString('approxDurationMs'),
      APPROX_DURATION_MS_UNKNOWN));

    const itagInfo: ItagInfo = new ItagInfo(streamUrl, itagItem);

    if (this.streamType === StreamType.VIDEO_STREAM) {
      itagInfo.setIsUrl(
        (formatData.getString('type', '') as string).toUpperCase()
        !== 'FORMAT_STREAM_TYPE_OTF');
    } else {
      // DASH manifests cannot be generated for running livestreams, so — given what StreamInfo
      // requires — those are returned as DASH URL streams (even if not playable); ended
      // livestreams are returned as non-URL streams
      itagInfo.setIsUrl(this.streamType !== StreamType.POST_LIVE_STREAM);
    }

    return itagInfo;
  }

  getFrames(): Frameset[] {
    try {
      const storyboards: JsonObject = this.playerResponse.getObject('storyboards');
      const storyboardsRenderer: JsonObject = storyboards.getObject(
        storyboards.has('playerLiveStoryboardSpecRenderer')
          ? 'playerLiveStoryboardSpecRenderer' : 'playerStoryboardSpecRenderer');
      if (storyboardsRenderer.size() === 0) {
        return [];
      }

      const storyboardsRendererSpec: string | null = storyboardsRenderer.getString('spec');
      if (storyboardsRendererSpec === null) {
        return [];
      }

      const spec: string[] = storyboardsRendererSpec.split('|');
      const url: string = spec[0];
      const result: Frameset[] = [];

      for (let i = 1; i < spec.length; i++) {
        const parts: string[] = spec[i].split('#');
        if (parts.length !== 8 || Number.parseInt(parts[5], 10) === 0) {
          continue;
        }
        const totalCount: number = Number.parseInt(parts[2], 10);
        const framesPerPageX: number = Number.parseInt(parts[3], 10);
        const framesPerPageY: number = Number.parseInt(parts[4], 10);
        const baseUrl: string = url.replace('$L', '' + (i - 1)).replace('$N', parts[6])
          + '&sigh=' + parts[7];

        let urls: string[];
        if (baseUrl.includes('$M')) {
          const totalPages: number = Math.ceil(totalCount / (framesPerPageX * framesPerPageY));
          urls = [];
          for (let j = 0; j < totalPages; j++) {
            urls.push(baseUrl.replace('$M', '' + j));
          }
        } else {
          urls = [baseUrl];
        }

        result.push(new Frameset(urls, Number.parseInt(parts[0], 10),
          Number.parseInt(parts[1], 10), totalCount, Number.parseInt(parts[5], 10),
          framesPerPageX, framesPerPageY));
      }

      return result;
    } catch (e) {
      throw new ExtractionException('Could not get frames',
        e instanceof Error ? e as Error : null);
    }
  }

  getPrivacy(): Privacy {
    if (this.playerMicroFormatRenderer.getBoolean('isUnlisted')) {
      return Privacy.UNLISTED;
    }
    for (const badge of this.getVideoPrimaryInfoRenderer().getArray('badges')
      .streamAsJsonObjects()) {
      if (badge.getObject('metadataBadgeRenderer').getObject('icon').getString('iconType')
        === 'PRIVACY_UNLISTED') {
        return Privacy.UNLISTED;
      }
    }
    return Privacy.PUBLIC;
  }

  getCategory(): string {
    return this.playerMicroFormatRenderer.getString('category', '') as string;
  }

  getLicence(): string {
    const metadataRowRenderer: JsonObject = this.getVideoSecondaryInfoRenderer()
      .getObject('metadataRowContainer')
      .getObject('metadataRowContainerRenderer')
      .getArray('rows')
      .getObject(0)
      .getObject('metadataRowRenderer');

    const contents: JsonArray = metadataRowRenderer.getArray('contents');
    const license: string | null = getTextFromObject(contents.getObject(0));

    return license !== null
      && getTextFromObject(metadataRowRenderer.getObject(TITLE)) === 'Licence'
      ? license : 'YouTube licence';
  }

  /** A BCP-47 language tag; the source returns null here too. */
  getLanguageInfo(): string | null {
    return null;
  }

  getTags(): string[] {
    return JsonUtils.getStringListFromJsonArray(
      this.playerResponse.getObject(VIDEO_DETAILS).getArray('keywords'));
  }

  getStreamSegments(): StreamSegment[] {
    if (!this.nextResponse.has('engagementPanels')) {
      return [];
    }

    let segmentsArray: JsonArray | null = null;
    for (const panel of this.nextResponse.getArray('engagementPanels').streamAsJsonObjects()) {
      // Check that this is the chapters panel
      if (panel.getObject('engagementPanelSectionListRenderer').getString('panelIdentifier')
        === 'engagement-panel-macro-markers-description-chapters') {
        segmentsArray = panel.getObject('engagementPanelSectionListRenderer')
          .getObject('content')
          .getObject('macroMarkersListRenderer')
          .getArray('contents');
        break;
      }
    }

    if (segmentsArray === null) {
      return [];
    }

    const duration: number = this.getLength();
    const segments: StreamSegment[] = [];

    for (const item of segmentsArray.streamAsJsonObjects()) {
      const segmentJson: JsonObject = item.getObject('macroMarkersListItemRenderer');

      const startTimeSeconds: number = segmentJson.getObject('onTap')
        .getObject('watchEndpoint')
        .getInt('startTimeSeconds', -1);
      if (startTimeSeconds === -1) {
        throw new ParsingException('Could not get stream segment start time.');
      }
      if (startTimeSeconds > duration) {
        break;
      }

      const title: string | null = getTextFromObject(segmentJson.getObject(TITLE));
      if (isNullOrEmpty(title)) {
        throw new ParsingException('Could not get stream segment title.');
      }

      const segment: StreamSegment = new StreamSegment(title as string, startTimeSeconds);
      segment.setUrl(this.getUrl() + '?t=' + startTimeSeconds);

      if (segmentJson.has(THUMBNAIL)) {
        const previewsArray: JsonArray =
          segmentJson.getObject(THUMBNAIL).getArray(THUMBNAILS);
        if (previewsArray.size() > 0) {
          // Assume the highest-resolution thumbnail is last
          const previewUrl: string | null =
            previewsArray.getObject(previewsArray.size() - 1).getString('url');
          if (previewUrl !== null) {
            segment.setPreviewUrl(fixThumbnailUrl(previewUrl));
          }
        }
      }

      segments.push(segment);
    }

    return segments;
  }

  getMetaInfo(): MetaInfo[] {
    return getMetaInfo(this.nextResponse
      .getObject('contents')
      .getObject('twoColumnWatchNextResults')
      .getObject('results')
      .getObject('results')
      .getArray('contents'));
  }
}
