/*
 * Port of org.schabi.newpipe.extractor.services.peertube.extractors.PeertubeStreamExtractor
 * (NewPipeExtractor v0.26.5).
 *
 * DEVIATION, forced by the async model (phase2-logic-contract.md §1): four of the source's
 * getters do HTTP, and only onFetchPage() is a Promise here. The full description (when the API
 * truncated it at 250 chars), the chapters and the storyboards are therefore fetched in
 * onFetchPage and cached, exactly as the source already does for the subtitles. The requests and
 * their results are unchanged; they are just issued eagerly.
 * ponytail: eager prefetch of chapters + storyboards, 2 extra requests per video. StreamInfo
 * reads both on every load, so the real call path costs the same; revisit only if a caller
 * appears that wants the video json without them.
 */

import {
  NO_AGE_LIMIT,
  Privacy,
  StreamExtractor
} from '../../../info/StreamExtractor';
import { InfoItemExtractor, InfoItemsCollector } from '../../../core/Collector';
import { InfoItem } from '../../../core/InfoItem';
import { StreamingService } from '../../../core/StreamingService';
import { LinkHandler } from '../../../linkhandler/LinkHandler';
import { ListLinkHandlerFactory } from '../../../linkhandler/LinkHandlerFactory';
import { Downloader, Response } from '../../../downloader/Downloader';
import { JsonArray, JsonObject, JsonParser } from '../../../json/NanoJson';
import { JsonUtils } from '../../../core/JsonUtils';
import { encodeUrlUtf8, isBlank, isNullOrEmpty } from '../../../core/Utils';
import { toError } from '../../../core/Errors';
import { ExtractionException, ParsingException } from '../../../exceptions/Exceptions';
import { MultiInfoItemsCollector } from '../../../core/MultiInfoItemsCollector';
import { DateWrapper } from '../../../localization/DateWrapper';
import { MediaFormat } from '../../../../../model/enums/MediaFormat';
import { DeliveryMethod } from '../../../../../model/enums/DeliveryMethod';
import { StreamType } from '../../../../../model/enums/StreamType';
import { AudioStream, AudioStreamBuilder, UNKNOWN_BITRATE } from '../../../../../model/extractor/AudioStream';
import { Description, DESCRIPTION_MARKDOWN } from '../../../../../model/extractor/Description';
import { Frameset } from '../../../../../model/extractor/Frameset';
import { Image } from '../../../../../model/extractor/Image';
import { Stream } from '../../../../../model/extractor/Stream';
import { StreamSegment } from '../../../../../model/extractor/StreamSegment';
import { SubtitlesStream, SubtitlesStreamBuilder } from '../../../../../model/extractor/SubtitlesStream';
import { VideoStream, VideoStreamBuilder } from '../../../../../model/extractor/VideoStream';
import {
  getAvatarsFromOwnerAccountOrVideoChannelObject,
  getThumbnailsFromPlaylistOrVideoItem,
  validate
} from '../PeertubeParsingHelper';
import { VIDEO_API_ENDPOINT } from '../linkHandler/PeertubeStreamLinkHandlerFactory';
import { SEARCH_ENDPOINT_VIDEOS } from '../linkHandler/PeertubeSearchQueryHandlerFactory';
import { PeertubeStreamInfoItemExtractor } from './PeertubeStreamInfoItemExtractor';

const ACCOUNT_HOST: string = 'account.host';
const ACCOUNT_NAME: string = 'account.name';
const FILES: string = 'files';
const FILE_DOWNLOAD_URL: string = 'fileDownloadUrl';
const FILE_URL: string = 'fileUrl';
const PLAYLIST_URL: string = 'playlistUrl';
const RESOLUTION_ID: string = 'resolution.id';
const STREAMING_PLAYLISTS: string = 'streamingPlaylists';

/** Instance-relative account path; the source builds it as API_ENDPOINT + "accounts/". */
const ACCOUNTS_API_ENDPOINT: string = '/api/v1/accounts/';

const TIMESTAMP_PATTERN: string = '((#|&|\\?)start=\\d{0,3}h?\\d{0,3}m?\\d{1,3}s?)';

export class PeertubeStreamExtractor extends StreamExtractor {
  private readonly baseUrl: string;
  private json: JsonObject = new JsonObject();

  private readonly subtitles: SubtitlesStream[] = [];
  private readonly audioStreams: AudioStream[] = [];
  private readonly videoStreams: VideoStream[] = [];

  private subtitlesException: ParsingException | null = null;

  /** Prefetched in onFetchPage; see the header note. */
  private description: Description = Description.EMPTY_DESCRIPTION;
  private streamSegments: StreamSegment[] = [];
  private framesets: Frameset[] = [];

  constructor(service: StreamingService, linkHandler: LinkHandler) {
    super(service, linkHandler);
    this.baseUrl = this.getBaseUrl();
  }

  getTextualUploadDate(): string | null {
    return JsonUtils.getString(this.json, 'publishedAt');
  }

  getUploadDate(): DateWrapper | null {
    return DateWrapper.fromInstant(this.getTextualUploadDate());
  }

  getThumbnails(): Image[] {
    return getThumbnailsFromPlaylistOrVideoItem(this.baseUrl, this.json);
  }

  getDescription(): Description {
    return this.description;
  }

  private async loadDescription(): Promise<void> {
    let text: string;
    try {
      text = JsonUtils.getString(this.json, 'description');
    } catch (e) {
      this.description = Description.EMPTY_DESCRIPTION;
      return;
    }
    if (text.length === 250 && text.substring(247) === '...') {
      // If description is shortened, get full description
      try {
        const response: Response = await this.getDownloader().get(this.baseUrl
          + VIDEO_API_ENDPOINT + this.getId() + '/description');
        const jsonObject: JsonObject = JsonParser.object().from(response.responseBody());
        text = JsonUtils.getString(jsonObject, 'description');
      } catch (e) {
        // Something went wrong when getting the full description, use the shortened one
      }
    }
    this.description = new Description(text, DESCRIPTION_MARKDOWN);
  }

  getAgeLimit(): number {
    const isNSFW: boolean = JsonUtils.getBoolean(this.json, 'nsfw');
    return isNSFW ? 18 : NO_AGE_LIMIT;
  }

  getLength(): number {
    return this.json.getLong('duration');
  }

  getTimeStamp(): number {
    const timestamp: number = this.getTimestampSeconds(TIMESTAMP_PATTERN);
    if (timestamp === -2) {
      // regex for timestamp was not found
      return 0;
    }
    return timestamp;
  }

  getViewCount(): number {
    return this.json.getLong('views');
  }

  getLikeCount(): number {
    return this.json.getLong('likes');
  }

  getDislikeCount(): number {
    return this.json.getLong('dislikes');
  }

  getUploaderUrl(): string {
    const name: string = JsonUtils.getString(this.json, ACCOUNT_NAME);
    const host: string = JsonUtils.getString(this.json, ACCOUNT_HOST);
    const factory: ListLinkHandlerFactory | null = this.getService().getChannelLHFactory();
    if (factory === null) {
      throw new ParsingException('This service does not support channels');
    }
    return factory.fromId('accounts/' + name + '@' + host, this.baseUrl).getUrl();
  }

  getUploaderName(): string {
    return JsonUtils.getString(this.json, 'account.displayName');
  }

  getUploaderAvatars(): Image[] {
    return getAvatarsFromOwnerAccountOrVideoChannelObject(this.baseUrl,
      this.json.getObject('account'));
  }

  getSubChannelUrl(): string {
    return JsonUtils.getString(this.json, 'channel.url');
  }

  getSubChannelName(): string {
    return JsonUtils.getString(this.json, 'channel.displayName');
  }

  getSubChannelAvatars(): Image[] {
    return getAvatarsFromOwnerAccountOrVideoChannelObject(this.baseUrl,
      this.json.getObject('channel'));
  }

  getHlsUrl(): string {
    this.assertPageFetched();

    if (this.getStreamType() === StreamType.VIDEO_STREAM
      && this.json.getObject(FILES).size() > 0) {
      const playlistUrl: string | null = this.json.getObject(FILES).getString(PLAYLIST_URL, '');
      return playlistUrl === null ? '' : playlistUrl;
    }

    const fromPlaylists: string | null = this.json.getArray(STREAMING_PLAYLISTS).getObject(0)
      .getString(PLAYLIST_URL, '');
    return fromPlaylists === null ? '' : fromPlaylists;
  }

  async getAudioStreams(): Promise<AudioStream[]> {
    this.assertPageFetched();

    /*
    Some videos have audio streams; others don't.
    So an audio stream may be available if a video stream is available.
    Audio streams are also not returned as separated streams for livestreams.
    That's why the extraction of audio streams is only run when there are video streams
    extracted and when the content is not a livestream.
     */
    if (this.audioStreams.length === 0 && this.videoStreams.length === 0
      && this.getStreamType() === StreamType.VIDEO_STREAM) {
      this.getStreams();
    }

    return this.audioStreams;
  }

  async getVideoStreams(): Promise<VideoStream[]> {
    this.assertPageFetched();

    if (this.videoStreams.length === 0) {
      if (this.getStreamType() === StreamType.VIDEO_STREAM) {
        this.getStreams();
      } else {
        this.extractLiveVideoStreams();
      }
    }

    return this.videoStreams;
  }

  async getVideoOnlyStreams(): Promise<VideoStream[]> {
    return [];
  }

  async getSubtitlesDefault(): Promise<SubtitlesStream[]> {
    if (this.subtitlesException !== null) {
      throw this.subtitlesException;
    }
    return this.subtitles;
  }

  async getSubtitles(format: MediaFormat): Promise<SubtitlesStream[]> {
    if (this.subtitlesException !== null) {
      throw this.subtitlesException;
    }
    return this.subtitles.filter((sub: SubtitlesStream): boolean => sub.getFormat() === format);
  }

  getStreamType(): StreamType {
    return this.json.getBoolean('isLive') ? StreamType.LIVE_STREAM : StreamType.VIDEO_STREAM;
  }

  async getRelatedItems(): Promise<InfoItemsCollector<InfoItem, InfoItemExtractor> | null> {
    const tags: string[] = this.getTags();
    let apiUrl: string;
    if (tags.length === 0) {
      apiUrl = this.baseUrl + ACCOUNTS_API_ENDPOINT + JsonUtils.getString(this.json, ACCOUNT_NAME)
        + '@' + JsonUtils.getString(this.json, ACCOUNT_HOST)
        + '/videos?start=0&count=8';
    } else {
      apiUrl = this.getRelatedItemsUrl(tags);
    }

    if (isBlank(apiUrl)) {
      return null;
    }
    // DEVIATION: the source builds a StreamInfoItemsCollector, which ArkTS/TS will not accept as
    // the InfoItemsCollector<InfoItem, InfoItemExtractor> the ported base declares (the base's
    // `comparator` is a property, so the type parameters are invariant). MultiInfoItemsCollector
    // IS that type and dispatches every PeertubeStreamInfoItemExtractor to an internal
    // StreamInfoItemsCollector, so the items and the collected errors are the same. The base
    // signature is a core API defect reported to the orchestrator; every service hits it.
    const collector: MultiInfoItemsCollector = new MultiInfoItemsCollector(this.getServiceId());
    await this.getStreamsFromApi(collector, apiUrl);
    return collector;
  }

  getTags(): string[] {
    return JsonUtils.getStringListFromJsonArray(this.json.getArray('tags'));
  }

  getSupportInfo(): string {
    try {
      return JsonUtils.getString(this.json, 'support');
    } catch (e) {
      return '';
    }
  }

  getStreamSegments(): StreamSegment[] {
    return this.streamSegments;
  }

  private async loadStreamSegments(): Promise<void> {
    const segments: StreamSegment[] = [];
    let segmentsJson: JsonObject | null;
    try {
      segmentsJson = await this.fetchSubApiContent('chapters');
    } catch (e) {
      throw new ParsingException('Could not get stream segments', toError(e));
    }
    if (segmentsJson !== null && segmentsJson.has('chapters')) {
      const segmentsArray: JsonArray = segmentsJson.getArray('chapters');
      for (let i = 0; i < segmentsArray.size(); i++) {
        const segmentObject: JsonObject = segmentsArray.getObject(i);
        const title: string | null = segmentObject.getString('title');
        segments.push(new StreamSegment(title === null ? '' : title,
          segmentObject.getInt('timecode')));
      }
    }
    this.streamSegments = segments;
  }

  getFrames(): Frameset[] {
    return this.framesets;
  }

  private async loadFrames(): Promise<void> {
    const framesets: Frameset[] = [];
    let storyboards: JsonObject | null;
    try {
      storyboards = await this.fetchSubApiContent('storyboards');
    } catch (e) {
      throw new ExtractionException('Could not get frames', toError(e));
    }
    if (storyboards !== null && storyboards.has('storyboards')) {
      for (const storyboardObject of storyboards.getArray('storyboards').streamAsJsonObjects()) {
        const storyboardPath: string | null = storyboardObject.getString('storyboardPath');
        const width: number = storyboardObject.getInt('spriteWidth');
        const height: number = storyboardObject.getInt('spriteHeight');
        const totalWidth: number = storyboardObject.getInt('totalWidth');
        const totalHeight: number = storyboardObject.getInt('totalHeight');
        const framesPerPageX: number = Math.trunc(totalWidth / width);
        const framesPerPageY: number = Math.trunc(totalHeight / height);
        const count: number = framesPerPageX * framesPerPageY;
        const durationPerFrame: number = storyboardObject.getInt('spriteDuration') * 1000;

        framesets.push(new Frameset(
          // there is only one composite image per video containing all frames
          [this.baseUrl + (storyboardPath === null ? '' : storyboardPath)],
          width, height, count,
          durationPerFrame, framesPerPageX, framesPerPageY));
      }
    }
    this.framesets = framesets;
  }

  private getRelatedItemsUrl(tags: string[]): string {
    const url: string = this.baseUrl + SEARCH_ENDPOINT_VIDEOS;
    let params: string = 'start=0&count=8&sort=-createdAt';
    for (const tag of tags) {
      params += '&tagsOneOf=' + encodeUrlUtf8(tag);
    }
    return url + '?' + params;
  }

  private async getStreamsFromApi(collector: MultiInfoItemsCollector,
    apiUrl: string): Promise<void> {
    const response: Response = await this.getDownloader().get(apiUrl);
    let relatedVideosJson: JsonObject | null = null;
    if (!isBlank(response.responseBody())) {
      try {
        relatedVideosJson = JsonParser.object().from(response.responseBody());
      } catch (e) {
        throw new ParsingException('Could not parse json data for related videos', toError(e));
      }
    }

    if (relatedVideosJson !== null) {
      this.collectStreamsFrom(collector, relatedVideosJson);
    }
  }

  private collectStreamsFrom(collector: MultiInfoItemsCollector, jsonObject: JsonObject): void {
    let contents: JsonArray;
    try {
      contents = JsonUtils.getArray(jsonObject, 'data');
    } catch (e) {
      throw new ParsingException('Could not extract related videos', toError(e));
    }

    for (const item of contents.streamAsJsonObjects()) {
      const extractor: PeertubeStreamInfoItemExtractor =
        new PeertubeStreamInfoItemExtractor(item, this.baseUrl);
      // Do not add the same stream in related streams
      if (extractor.getUrl() !== this.getUrl()) {
        collector.commit(extractor);
      }
    }
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
    const response: Response =
      await downloader.get(this.baseUrl + VIDEO_API_ENDPOINT + this.getId());
    this.setInitialData(response.responseBody());

    await this.loadSubtitles();
    await this.loadDescription();
    await this.loadStreamSegments();
    await this.loadFrames();
  }

  private setInitialData(responseBody: string): void {
    try {
      this.json = JsonParser.object().from(responseBody);
    } catch (e) {
      throw new ExtractionException('Could not extract PeerTube stream data', toError(e));
    }
    validate(this.json);
  }

  private async loadSubtitles(): Promise<void> {
    if (this.subtitles.length === 0) {
      try {
        const response: Response = await this.getDownloader().get(this.baseUrl
          + VIDEO_API_ENDPOINT + this.getId() + '/captions');
        const captionsJson: JsonObject = JsonParser.object().from(response.responseBody());
        const captions: JsonArray = JsonUtils.getArray(captionsJson, 'data');
        for (const caption of captions.streamAsJsonObjects()) {
          const url: string = this.baseUrl + JsonUtils.getString(caption, 'captionPath');
          const languageCode: string = JsonUtils.getString(caption, 'language.id');
          const ext: string = url.substring(url.lastIndexOf('.') + 1);
          const fmt: MediaFormat | null = MediaFormat.getFromSuffix(ext);
          if (fmt !== null && !isNullOrEmpty(languageCode)) {
            this.subtitles.push(new SubtitlesStreamBuilder()
              .setContent(url, true)
              .setMediaFormat(fmt)
              .setLanguageCode(languageCode)
              .setAutoGenerated(false)
              .build());
          }
        }
      } catch (e) {
        this.subtitlesException = new ParsingException('Could not get subtitles', toError(e));
      }
    }
  }

  private extractLiveVideoStreams(): void {
    try {
      for (const stream of this.json.getArray(STREAMING_PLAYLISTS).streamAsJsonObjects()) {
        // Don't use the containsSimilarStream method because it will always return
        // false so if there are multiples HLS URLs returned, only the first will be
        // extracted in this case.
        this.videoStreams.push(new VideoStreamBuilder()
          .setId(stream.getInt('id', -1).toString())
          .setContent(this.stringOrEmpty(stream.getString(PLAYLIST_URL, '')), true)
          .setIsVideoOnly(false)
          .setResolution('')
          .setMediaFormat(MediaFormat.MPEG_4)
          .setDeliveryMethod(DeliveryMethod.HLS)
          .build());
      }
    } catch (e) {
      throw new ParsingException('Could not get video streams', toError(e));
    }
  }

  private stringOrEmpty(value: string | null): string {
    return value === null ? '' : value;
  }

  private getStreams(): void {
    // Progressive streams
    this.getStreamsFromArray(this.json.getArray(FILES), '');

    // HLS streams
    try {
      for (const playlist of this.json.getArray(STREAMING_PLAYLISTS).streamAsJsonObjects()) {
        this.getStreamsFromArray(playlist.getArray(FILES),
          this.stringOrEmpty(playlist.getString(PLAYLIST_URL)));
      }
    } catch (e) {
      throw new ParsingException('Could not get streams', toError(e));
    }
  }

  private getStreamsFromArray(streams: JsonArray, playlistUrl: string): void {
    try {
      /*
      Starting with version 3.4.0 of PeerTube, the HLS playlist of stream resolutions
      contains the UUID of the streams, so we can't use the same method to get the URL of
      the HLS playlist without fetching the master playlist.
      These UUIDs are the same as the ones returned into the fileUrl and fileDownloadUrl
      strings.
      */
      const isInstanceUsingRandomUuidsForHlsStreams: boolean = !isNullOrEmpty(playlistUrl)
        && playlistUrl.endsWith('-master.m3u8');
      for (const stream of streams.streamAsJsonObjects()) {
        // Extract stream version of streams first
        const url: string = JsonUtils.getString(stream,
          stream.has(FILE_URL) ? FILE_URL : FILE_DOWNLOAD_URL);
        if (isNullOrEmpty(url)) {
          // Not a valid stream URL
          return;
        }

        const resolution: string = JsonUtils.getString(stream, 'resolution.label');
        const idSuffix: string = stream.has(FILE_URL) ? FILE_URL : FILE_DOWNLOAD_URL;

        if (resolution.toLowerCase().includes('audio')) {
          // An audio stream
          this.addNewAudioStream(stream, isInstanceUsingRandomUuidsForHlsStreams, resolution,
            idSuffix, url, playlistUrl);
        } else {
          // A video stream
          this.addNewVideoStream(stream, isInstanceUsingRandomUuidsForHlsStreams, resolution,
            idSuffix, url, playlistUrl);
        }
      }
    } catch (e) {
      throw new ParsingException('Could not get streams from array', toError(e));
    }
  }

  private getHlsPlaylistUrlFromFragmentedFileUrl(streamJsonObject: JsonObject, idSuffix: string,
    format: string, url: string): string {
    const streamUrl: string = FILE_DOWNLOAD_URL === idSuffix
      ? JsonUtils.getString(streamJsonObject, FILE_URL)
      : url;
    return streamUrl.replace('-fragmented.' + format, '.m3u8');
  }

  private getHlsPlaylistUrlFromMasterPlaylist(streamJsonObject: JsonObject,
    playlistUrl: string): string {
    return playlistUrl.replace('master',
      JsonUtils.getNumber(streamJsonObject, RESOLUTION_ID).toString());
  }

  private addNewAudioStream(streamJsonObject: JsonObject,
    isInstanceUsingRandomUuidsForHlsStreams: boolean, resolution: string, idSuffix: string,
    url: string, playlistUrl: string | null): void {
    const extension: string = url.substring(url.lastIndexOf('.') + 1);
    const format: MediaFormat | null = MediaFormat.getFromSuffix(extension);
    const id: string = resolution + '-' + extension;

    // Add progressive HTTP streams first
    this.audioStreams.push(new AudioStreamBuilder()
      .setId(id + '-' + idSuffix + '-' + DeliveryMethod.PROGRESSIVE_HTTP)
      .setContent(url, true)
      .setMediaFormat(format)
      .setAverageBitrate(UNKNOWN_BITRATE)
      .build());

    // Then add HLS streams
    if (!isNullOrEmpty(playlistUrl)) {
      const resolvedPlaylistUrl: string = playlistUrl as string;
      const hlsStreamUrl: string = isInstanceUsingRandomUuidsForHlsStreams
        ? this.getHlsPlaylistUrlFromFragmentedFileUrl(streamJsonObject, idSuffix, extension, url)
        : this.getHlsPlaylistUrlFromMasterPlaylist(streamJsonObject, resolvedPlaylistUrl);
      const audioStream: AudioStream = new AudioStreamBuilder()
        .setId(id + '-' + DeliveryMethod.HLS)
        .setContent(hlsStreamUrl, true)
        .setDeliveryMethod(DeliveryMethod.HLS)
        .setMediaFormat(format)
        .setAverageBitrate(UNKNOWN_BITRATE)
        .setManifestUrl(resolvedPlaylistUrl)
        .build();
      if (!Stream.containSimilarStream(audioStream, this.audioStreams)) {
        this.audioStreams.push(audioStream);
      }
    }

    // Finally, add torrent URLs
    const torrentUrl: string = JsonUtils.getString(streamJsonObject, 'torrentUrl');
    if (!isNullOrEmpty(torrentUrl)) {
      this.audioStreams.push(new AudioStreamBuilder()
        .setId(id + '-' + idSuffix + '-' + DeliveryMethod.TORRENT)
        .setContent(torrentUrl, true)
        .setDeliveryMethod(DeliveryMethod.TORRENT)
        .setMediaFormat(format)
        .setAverageBitrate(UNKNOWN_BITRATE)
        .build());
    }
  }

  private addNewVideoStream(streamJsonObject: JsonObject,
    isInstanceUsingRandomUuidsForHlsStreams: boolean, resolution: string, idSuffix: string,
    url: string, playlistUrl: string | null): void {
    const extension: string = url.substring(url.lastIndexOf('.') + 1);
    const format: MediaFormat | null = MediaFormat.getFromSuffix(extension);
    const id: string = resolution + '-' + extension;

    // Check if the hasAudio property is present to keep compatibility with instances < 6.3.0,
    // otherwise any video stream with an audio track will be marked as video only for these
    // instances
    const isVideoOnly: boolean = streamJsonObject.has('hasAudio')
      && !streamJsonObject.getBoolean('hasAudio');

    // Add progressive HTTP streams first
    this.videoStreams.push(new VideoStreamBuilder()
      .setId(id + '-' + idSuffix + '-' + DeliveryMethod.PROGRESSIVE_HTTP)
      .setContent(url, true)
      .setIsVideoOnly(isVideoOnly)
      .setResolution(resolution)
      .setMediaFormat(format)
      .build());

    // Then add HLS streams
    if (!isNullOrEmpty(playlistUrl)) {
      const resolvedPlaylistUrl: string = playlistUrl as string;
      const hlsStreamUrl: string = isInstanceUsingRandomUuidsForHlsStreams
        ? this.getHlsPlaylistUrlFromFragmentedFileUrl(streamJsonObject, idSuffix, extension, url)
        : this.getHlsPlaylistUrlFromMasterPlaylist(streamJsonObject, resolvedPlaylistUrl);

      const videoStream: VideoStream = new VideoStreamBuilder()
        .setId(id + '-' + DeliveryMethod.HLS)
        .setContent(hlsStreamUrl, true)
        .setIsVideoOnly(isVideoOnly)
        .setDeliveryMethod(DeliveryMethod.HLS)
        .setResolution(resolution)
        .setMediaFormat(format)
        .setManifestUrl(resolvedPlaylistUrl)
        .build();
      if (!Stream.containSimilarStream(videoStream, this.videoStreams)) {
        this.videoStreams.push(videoStream);
      }
    }

    // Add finally torrent URLs
    const torrentUrl: string = JsonUtils.getString(streamJsonObject, 'torrentUrl');
    if (!isNullOrEmpty(torrentUrl)) {
      this.videoStreams.push(new VideoStreamBuilder()
        .setId(id + '-' + idSuffix + '-' + DeliveryMethod.TORRENT)
        .setContent(torrentUrl, true)
        .setIsVideoOnly(isVideoOnly)
        .setDeliveryMethod(DeliveryMethod.TORRENT)
        .setResolution(resolution)
        .setMediaFormat(format)
        .build());
    }
  }

  /**
   * Fetch content from a sub-API of the video, e.g. "storyboards" for
   * `/api/v1/videos/{id}/storyboards`. Returns null when the API does not exist, which is the
   * case if the instance has an outdated PeerTube version.
   */
  private async fetchSubApiContent(subPath: string): Promise<JsonObject | null> {
    const apiUrl: string = this.baseUrl + VIDEO_API_ENDPOINT + this.getId() + '/' + subPath;
    const response: Response = await this.getDownloader().get(apiUrl);
    if (response.responseCode() === 400) {
      // Chapter or segments support was added with PeerTube v6.0.0
      // This instance does not support it yet.
      return null;
    }
    if (response.responseCode() !== 200) {
      throw new ParsingException('Could not get segments from API. Response code: '
        + response.responseCode());
    }
    try {
      return JsonParser.object().from(response.responseBody());
    } catch (e) {
      throw new ParsingException('Could not parse json data for segments', toError(e));
    }
  }

  getName(): string {
    return JsonUtils.getString(this.json, 'name');
  }

  getHost(): string {
    return JsonUtils.getString(this.json, ACCOUNT_HOST);
  }

  getPrivacy(): Privacy {
    switch (this.json.getObject('privacy').getInt('id')) {
      case 1:
        return Privacy.PUBLIC;
      case 2:
        return Privacy.UNLISTED;
      case 3:
        return Privacy.PRIVATE;
      case 4:
        return Privacy.INTERNAL;
      default:
        return Privacy.OTHER;
    }
  }

  getCategory(): string {
    return JsonUtils.getString(this.json, 'category.label');
  }

  getLicence(): string {
    return JsonUtils.getString(this.json, 'licence.label');
  }

  /** A BCP-47 language tag; §9 replaced java.util.Locale with the tag string. */
  getLanguageInfo(): string | null {
    try {
      return JsonUtils.getString(this.json, 'language.id');
    } catch (e) {
      return null;
    }
  }
}
