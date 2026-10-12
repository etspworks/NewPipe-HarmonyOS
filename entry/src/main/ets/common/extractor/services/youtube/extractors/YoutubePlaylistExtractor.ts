/*
 * Port of org.schabi.newpipe.extractor.services.youtube.extractors.YoutubePlaylistExtractor
 * (NewPipeExtractor v0.26.5).
 *
 * YouTube ships two playlist layouts at once, so almost every getter branches on
 * isNewPlaylistInterface; both branches are ported.
 *
 * The initial continuation is a protobuf token — see ../Protobuf.ts, which writes the two
 * generated message classes out by hand.
 */

import { JsonArray, JsonObject, JsonWriter } from '../../../json/NanoJson';
import { Downloader, Request } from '../../../downloader/Downloader';
import { Localization } from '../../../downloader/Localization';
import { StreamingService } from '../../../core/StreamingService';
import { ITEM_COUNT_UNKNOWN } from '../../../core/ListExtractor';
import { PlaylistExtractor } from '../../../info/PlaylistExtractor';
import { StreamInfoItemsCollector } from '../../../info/StreamInfoItemsCollector';
import { ListLinkHandler } from '../../../linkhandler/LinkHandler';
import { TimeAgoParser } from '../../../localization/TimeAgoParser';
import { ParsingException } from '../../../exceptions/Exceptions';
import { encodeUrlUtf8, isNullOrEmpty, removeNonDigitCharacters } from '../../../core/Utils';
import { Description, DESCRIPTION_HTML } from '../../../../../model/extractor/Description';
import { Image } from '../../../../../model/extractor/Image';
import { InfoItemsPage } from '../../../../../model/extractor/ListExtractorInfoItemsPage';
import { Page } from '../../../../../model/extractor/Page';
import { PlaylistType } from '../../../../../model/extractor/PlaylistType';
import { StreamInfoItem } from '../../../../../model/extractor/StreamInfoItem';
import { PlaylistContinuation, base64UrlEncode } from '../Protobuf';
import {
  DISABLE_PRETTY_PRINT_PARAMETER,
  YOUTUBEI_V1_URL,
  defaultAlertsCheck,
  extractPlaylistTypeFromPlaylistUrl,
  getImagesFromThumbnailsArray,
  getJsonPostResponse,
  getJsonPostResponseWithQuery,
  getTextFromObject,
  getTextFromObjectHtml,
  getUrlFromNavigationEndpoint,
  prepareDesktopJsonBuilder
} from '../YoutubeParsingHelper';
import { YoutubeStreamInfoItemExtractor } from './YoutubeStreamInfoItemExtractor';
import { YoutubeReelInfoItemExtractor } from './YoutubeReelInfoItemExtractor';
import { YoutubeStreamInfoItemLockupExtractor } from './YoutubeStreamInfoItemLockupExtractor';

// Names of objects used more than once in this class
const PLAYLIST_VIDEO_RENDERER: string = 'playlistVideoRenderer';
const RICH_ITEM_RENDERER: string = 'richItemRenderer';
const REEL_ITEM_RENDERER: string = 'reelItemRenderer';
const LOCKUP_VIEW_MODEL: string = 'lockupViewModel';
const SIDEBAR: string = 'sidebar';
const HEADER: string = 'header';
const VIDEO_OWNER_RENDERER: string = 'videoOwnerRenderer';
const MICROFORMAT: string = 'microformat';
const COMMAND_EXECUTOR_COMMAND: string = 'commandExecutorCommand';
const THUMBNAIL: string = 'thumbnail';
const THUMBNAILS: string = 'thumbnails';
const ON_RESPONSE_RECEIVED_ACTIONS: string = 'onResponseReceivedActions';
const CONTINUATION_ITEMS: string = 'continuationItems';
const APPEND_CONTINUATION_ITEMS_ACTION: string = 'appendContinuationItemsAction';
const CONTINUATION_COMMAND: string = 'continuationCommand';
const TITLE: string = 'title';
const BROWSE_ENDPOINT: string = 'browse';

/** Continuation properties requesting the first page and showing unavailable videos. */
const PLAYLIST_CONTINUATION_PROPERTIES_BASE64: string = 'CADCBgIIAA%3D%3D';

/** A course playlist attributes every row to the playlist's own uploader. */
class CoursePlaylistVideoExtractor extends YoutubeStreamInfoItemExtractor {
  private readonly owner: YoutubePlaylistExtractor;
  private readonly coursePlaylist: boolean;

  constructor(videoInfoItem: JsonObject, timeAgoParser: TimeAgoParser | null,
    owner: YoutubePlaylistExtractor, coursePlaylist: boolean) {
    super(videoInfoItem, timeAgoParser);
    this.owner = owner;
    this.coursePlaylist = coursePlaylist;
  }

  getUploaderName(): string {
    return this.coursePlaylist ? this.owner.getUploaderName() : super.getUploaderName();
  }

  getUploaderUrl(): string {
    return this.coursePlaylist ? this.owner.getUploaderUrl() : super.getUploaderUrl();
  }
}

/** The lockup-shaped equivalent of the above. */
class CoursePlaylistLockupExtractor extends YoutubeStreamInfoItemLockupExtractor {
  private readonly owner: YoutubePlaylistExtractor;
  private readonly coursePlaylist: boolean;

  constructor(lockupViewModel: JsonObject, timeAgoParser: TimeAgoParser | null,
    owner: YoutubePlaylistExtractor, coursePlaylist: boolean) {
    super(lockupViewModel, timeAgoParser);
    this.owner = owner;
    this.coursePlaylist = coursePlaylist;
  }

  protected isChannelOrCoursePlaylistLockupItem(): boolean {
    return this.coursePlaylist;
  }

  getUploaderName(): string {
    return this.coursePlaylist ? this.owner.getUploaderName() : super.getUploaderName();
  }

  getUploaderUrl(): string {
    return this.coursePlaylist ? this.owner.getUploaderUrl() : super.getUploaderUrl();
  }
}

export class YoutubePlaylistExtractor extends PlaylistExtractor {
  private browseMetadataResponse: JsonObject = new JsonObject();
  private initialBrowseContinuationResponse: JsonObject = new JsonObject();
  private playlistInfo: JsonObject | null = null;
  private uploaderInfo: JsonObject | null = null;
  private playlistHeader: JsonObject | null = null;
  private isNewPlaylistInterface: boolean = false;

  constructor(service: StreamingService, linkHandler: ListLinkHandler) {
    super(service, linkHandler);
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
    const playlistId: string = this.getId();
    const localization: Localization = this.getExtractorLocalization();

    const body: ArrayBuffer = Request.utf8Body(JsonWriter.stringValue(
      (await prepareDesktopJsonBuilder(localization, this.getExtractorContentCountry()))
        .value('browseId', 'VL' + playlistId)
        .value('params', 'wgYCCAA%3D') // Show unavailable videos
        .done()));

    this.browseMetadataResponse = await getJsonPostResponseWithQuery(BROWSE_ENDPOINT,
      ['$fields=' + SIDEBAR + ',' + HEADER + ',' + MICROFORMAT + ',alerts'], body, localization);
    defaultAlertsCheck(this.browseMetadataResponse);

    this.isNewPlaylistInterface = this.checkIfResponseIsNewPlaylistInterface();

    const playlistContinuation: PlaylistContinuation = new PlaylistContinuation();
    playlistContinuation.parameters.browseId = 'VL' + playlistId;
    playlistContinuation.parameters.playlistId = playlistId;
    playlistContinuation.parameters.continuationProperties =
      PLAYLIST_CONTINUATION_PROPERTIES_BASE64;

    this.initialBrowseContinuationResponse = await getJsonPostResponse(BROWSE_ENDPOINT,
      Request.utf8Body(JsonWriter.stringValue(
        (await prepareDesktopJsonBuilder(localization, this.getExtractorContentCountry()))
          .value('continuation',
            encodeUrlUtf8(base64UrlEncode(playlistContinuation.toByteArray())))
          .done())),
      localization);
  }

  /** The old playlist UI can be returned alongside the new one, so both keys are checked. */
  private checkIfResponseIsNewPlaylistInterface(): boolean {
    return this.browseMetadataResponse.has(HEADER)
      && !this.browseMetadataResponse.has(SIDEBAR);
  }

  private getUploaderInfo(): JsonObject {
    let info: JsonObject | null = this.uploaderInfo;
    if (info !== null) {
      return info;
    }
    for (const item of this.browseMetadataResponse.getObject(SIDEBAR)
      .getObject('playlistSidebarRenderer')
      .getArray('items')
      .streamAsJsonObjects()) {
      const videoOwner: JsonObject = item.getObject('playlistSidebarSecondaryInfoRenderer')
        .getObject('videoOwner');
      if (videoOwner.has(VIDEO_OWNER_RENDERER)) {
        info = videoOwner.getObject(VIDEO_OWNER_RENDERER);
        this.uploaderInfo = info;
        return info;
      }
    }
    throw new ParsingException('Could not get uploader info');
  }

  private getPlaylistInfo(): JsonObject {
    let info: JsonObject | null = this.playlistInfo;
    if (info !== null) {
      return info;
    }
    for (const item of this.browseMetadataResponse.getObject(SIDEBAR)
      .getObject('playlistSidebarRenderer')
      .getArray('items')
      .streamAsJsonObjects()) {
      if (item.has('playlistSidebarPrimaryInfoRenderer')) {
        info = item.getObject('playlistSidebarPrimaryInfoRenderer');
        this.playlistInfo = info;
        return info;
      }
    }
    throw new ParsingException('Could not get playlist info');
  }

  private getPlaylistHeader(): JsonObject {
    let header: JsonObject | null = this.playlistHeader;
    if (header === null) {
      header = this.browseMetadataResponse.getObject(HEADER)
        .getObject('playlistHeaderRenderer');
      this.playlistHeader = header;
    }
    return header;
  }

  getName(): string {
    const name: string | null = getTextFromObject(this.getPlaylistInfo().getObject(TITLE));
    if (!isNullOrEmpty(name)) {
      return name as string;
    }
    const microformatTitle: string | null = this.browseMetadataResponse.getObject(MICROFORMAT)
      .getObject('microformatDataRenderer')
      .getString(TITLE);
    return microformatTitle === null ? '' : microformatTitle;
  }

  getThumbnails(): Image[] {
    let playlistMetadataThumbnailsArray: JsonArray;
    if (this.isNewPlaylistInterface) {
      playlistMetadataThumbnailsArray = this.getPlaylistHeader()
        .getObject('playlistHeaderBanner')
        .getObject('heroPlaylistThumbnailRenderer')
        .getObject(THUMBNAIL)
        .getArray(THUMBNAILS);
    } else {
      playlistMetadataThumbnailsArray = this.getPlaylistInfo().getObject('thumbnailRenderer')
        .getObject('playlistVideoThumbnailRenderer')
        .getObject(THUMBNAIL)
        .getArray(THUMBNAILS);
    }

    if (playlistMetadataThumbnailsArray.size() > 0) {
      return getImagesFromThumbnailsArray(playlistMetadataThumbnailsArray);
    }

    // This structure comes back in both layouts
    const microFormatThumbnailsArray: JsonArray = this.browseMetadataResponse
      .getObject(MICROFORMAT)
      .getObject('microformatDataRenderer')
      .getObject(THUMBNAIL)
      .getArray(THUMBNAILS);
    if (microFormatThumbnailsArray.size() > 0) {
      return getImagesFromThumbnailsArray(microFormatThumbnailsArray);
    }

    throw new ParsingException('Could not get playlist thumbnails');
  }

  getUploaderUrl(): string {
    try {
      const endpoint: JsonObject = this.isNewPlaylistInterface
        ? this.getPlaylistHeader().getObject('ownerText')
          .getArray('runs')
          .getObject(0)
          .getObject('navigationEndpoint')
        : this.getUploaderInfo().getObject('navigationEndpoint');
      const url: string | null = getUrlFromNavigationEndpoint(endpoint);
      return url === null ? '' : url;
    } catch (e) {
      throw new ParsingException('Could not get playlist uploader url',
        e instanceof Error ? e as Error : null);
    }
  }

  getUploaderName(): string {
    try {
      const name: string | null = getTextFromObject(this.isNewPlaylistInterface
        ? this.getPlaylistHeader().getObject('ownerText')
        : this.getUploaderInfo().getObject(TITLE));
      return name === null ? '' : name;
    } catch (e) {
      throw new ParsingException('Could not get playlist uploader name',
        e instanceof Error ? e as Error : null);
    }
  }

  getUploaderAvatars(): Image[] {
    if (this.isNewPlaylistInterface) {
      // The new playlist interface provides no uploader avatar
      return [];
    }
    try {
      return getImagesFromThumbnailsArray(
        this.getUploaderInfo().getObject(THUMBNAIL).getArray(THUMBNAILS));
    } catch (e) {
      throw new ParsingException('Could not get playlist uploader avatars',
        e instanceof Error ? e as Error : null);
    }
  }

  isUploaderVerified(): boolean {
    // YouTube does not provide this information for playlists
    return false;
  }

  getStreamCount(): number {
    if (this.isNewPlaylistInterface) {
      const numVideosText: string | null =
        getTextFromObject(this.getPlaylistHeader().getObject('numVideosText'));
      if (numVideosText !== null) {
        const parsed: number = Number.parseInt(removeNonDigitCharacters(numVideosText), 10);
        if (!Number.isNaN(parsed)) {
          return parsed;
        }
      }

      const firstByLineRendererText: string | null = getTextFromObject(
        this.getPlaylistHeader().getArray('byline').getObject(0).getObject('text'));
      if (firstByLineRendererText !== null) {
        const parsed: number =
          Number.parseInt(removeNonDigitCharacters(firstByLineRendererText), 10);
        if (!Number.isNaN(parsed)) {
          return parsed;
        }
      }
    }

    // These structures come back in both layouts
    const holder: JsonObject =
      this.isNewPlaylistInterface ? this.getPlaylistHeader() : this.getPlaylistInfo();

    const briefStats: JsonArray = holder.getArray('briefStats');
    if (briefStats.size() > 0) {
      const briefsStatsText: string | null = getTextFromObject(briefStats.getObject(0));
      if (briefsStatsText !== null) {
        return Number.parseInt(removeNonDigitCharacters(briefsStatsText), 10);
      }
    }

    const stats: JsonArray = holder.getArray('stats');
    if (stats.size() > 0) {
      const statsText: string | null = getTextFromObject(stats.getObject(0));
      if (statsText !== null) {
        return Number.parseInt(removeNonDigitCharacters(statsText), 10);
      }
    }

    return ITEM_COUNT_UNKNOWN;
  }

  getDescription(): Description {
    const description: string | null =
      getTextFromObjectHtml(this.getPlaylistInfo().getObject('description'), true);
    return new Description(description, DESCRIPTION_HTML);
  }

  async getInitialPage(): Promise<InfoItemsPage<StreamInfoItem>> {
    const collector: StreamInfoItemsCollector =
      new StreamInfoItemsCollector(this.getServiceId());

    let initialItems: JsonArray = this.initialBrowseContinuationResponse
      .getArray(ON_RESPONSE_RECEIVED_ACTIONS)
      .getObject(0)
      .getObject('reloadContinuationItemsCommand')
      .getArray(CONTINUATION_ITEMS);

    if (initialItems.size() === 0) {
      // The lockup-view-model structure uses appendContinuationItemsAction for the initial
      // continuation too
      initialItems = this.initialBrowseContinuationResponse
        .getArray(ON_RESPONSE_RECEIVED_ACTIONS)
        .getObject(0)
        .getObject(APPEND_CONTINUATION_ITEMS_ACTION)
        .getArray(CONTINUATION_ITEMS);
    }

    let isCoursePlaylist: boolean = false;
    for (const command of this.getPlaylistHeader().getObject('onDescriptionTap')
      .getObject(COMMAND_EXECUTOR_COMMAND)
      .getArray('commands')
      .streamAsJsonObjects()) {
      if (command.getObject('showEngagementPanelEndpoint')
        .getObject('identifier')
        .getString('tag') === 'engagement-panel-course-metadata') {
        isCoursePlaylist = true;
        break;
      }
    }

    this.collectStreamsFrom(collector, initialItems, isCoursePlaylist);
    return InfoItemsPage.fromCollector(collector,
      await this.getNextPageFrom(initialItems, isCoursePlaylist));
  }

  async getPage(page: Page): Promise<InfoItemsPage<StreamInfoItem>> {
    if (page === null || isNullOrEmpty(page.getUrl())) {
      throw new ParsingException('Page doesn\'t contain an URL');
    }

    const collector: StreamInfoItemsCollector =
      new StreamInfoItemsCollector(this.getServiceId());

    const ajaxJson: JsonObject = await getJsonPostResponse(BROWSE_ENDPOINT,
      page.getBody() as ArrayBuffer, this.getExtractorLocalization());

    const continuation: JsonArray = ajaxJson.getArray(ON_RESPONSE_RECEIVED_ACTIONS)
      .getObject(0)
      .getObject(APPEND_CONTINUATION_ITEMS_ACTION)
      .getArray(CONTINUATION_ITEMS);

    const isCoursePlaylist: boolean = page.getId() === 'true';
    this.collectStreamsFrom(collector, continuation, isCoursePlaylist);

    return InfoItemsPage.fromCollector(collector,
      await this.getNextPageFrom(continuation, isCoursePlaylist));
  }

  private async getNextPageFrom(contents: JsonArray | null,
    isCoursePlaylist: boolean): Promise<Page | null> {
    if (contents === null || contents.size() === 0) {
      return null;
    }

    let continuation: string | null;
    const lastElement: JsonObject = contents.getObject(contents.size() - 1);

    if (lastElement.has('continuationItemRenderer')) {
      const continuationEndpoint: JsonObject = lastElement
        .getObject('continuationItemRenderer')
        .getObject('continuationEndpoint');

      let continuationObject: JsonObject = new JsonObject();
      if (continuationEndpoint.has(COMMAND_EXECUTOR_COMMAND)) {
        // At the time the source was written this shape only appears in initial playlist
        // responses: continuationItemRenderer returns several commands, one carrying the
        // continuation and one a playlistVotingRefreshPopupCommand
        for (const command of continuationEndpoint.getObject(COMMAND_EXECUTOR_COMMAND)
          .getArray('commands')
          .streamAsJsonObjects()) {
          if (command.has(CONTINUATION_COMMAND)) {
            continuationObject = command;
            break;
          }
        }
      } else {
        // The "classic" continuation shape, returned in browse responses of continuations
        continuationObject = continuationEndpoint;
      }

      continuation = continuationObject.getObject(CONTINUATION_COMMAND).getString('token');
    } else if (lastElement.has('continuationItemViewModel')) {
      continuation = lastElement.getObject('continuationItemViewModel')
        .getObject(CONTINUATION_COMMAND)
        .getObject('innertubeCommand')
        .getObject(CONTINUATION_COMMAND)
        .getString('token');
    } else {
      return null;
    }

    if (isNullOrEmpty(continuation)) {
      // Invalid continuation, or none found
      return null;
    }

    const body: ArrayBuffer = Request.utf8Body(JsonWriter.stringValue(
      (await prepareDesktopJsonBuilder(this.getExtractorLocalization(),
        this.getExtractorContentCountry()))
        .value('continuation', continuation)
        .done()));

    return new Page(YOUTUBEI_V1_URL + 'browse?' + DISABLE_PRETTY_PRINT_PARAMETER,
      isCoursePlaylist ? 'true' : 'false', null, null, body);
  }

  private collectStreamsFrom(collector: StreamInfoItemsCollector, videos: JsonArray,
    isCoursePlaylist: boolean): void {
    const timeAgoParser: TimeAgoParser = this.getTimeAgoParser();

    for (const video of videos.streamAsJsonObjects()) {
      if (video.has(PLAYLIST_VIDEO_RENDERER)) {
        collector.commit(new CoursePlaylistVideoExtractor(
          video.getObject(PLAYLIST_VIDEO_RENDERER), timeAgoParser, this, isCoursePlaylist));
      } else if (video.has(RICH_ITEM_RENDERER)) {
        const richItemRenderer: JsonObject = video.getObject(RICH_ITEM_RENDERER);
        if (richItemRenderer.has('content')) {
          const richItemRendererContent: JsonObject = richItemRenderer.getObject('content');
          if (richItemRendererContent.has(REEL_ITEM_RENDERER)) {
            collector.commit(new YoutubeReelInfoItemExtractor(
              richItemRendererContent.getObject(REEL_ITEM_RENDERER)));
          }
        }
      } else if (video.has(LOCKUP_VIEW_MODEL)) {
        collector.commit(new CoursePlaylistLockupExtractor(video.getObject(LOCKUP_VIEW_MODEL),
          timeAgoParser, this, isCoursePlaylist));
      }
    }
  }

  getPlaylistType(): PlaylistType {
    return extractPlaylistTypeFromPlaylistUrl(this.getUrl());
  }
}
