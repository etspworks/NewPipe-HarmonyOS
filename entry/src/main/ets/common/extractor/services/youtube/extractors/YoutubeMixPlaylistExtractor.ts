/*
 * Port of org.schabi.newpipe.extractor.services.youtube.extractors.YoutubeMixPlaylistExtractor
 * (NewPipeExtractor v0.26.5).
 *
 * A mix is an endless auto-generated playlist; its pages are driven by the VISITOR_INFO1_LIVE
 * cookie carried on the Page, and its thumbnails are synthesised from the video id because the
 * response carries none.
 */

import { JsonArray, JsonObject, JsonBuilder, JsonValue, JsonWriter } from '../../../json/NanoJson';
import { Downloader, HeaderMap, Request, Response } from '../../../downloader/Downloader';
import { Localization } from '../../../downloader/Localization';
import { StreamingService } from '../../../core/StreamingService';
import { ITEM_COUNT_INFINITE } from '../../../core/ListExtractor';
import { ImageSuffix } from '../../../core/ImageSuffix';
import { JsonUtils } from '../../../core/JsonUtils';
import { NewPipe } from '../../../core/NewPipe';
import { PlaylistExtractor } from '../../../info/PlaylistExtractor';
import { StreamInfoItemsCollector } from '../../../info/StreamInfoItemsCollector';
import { ListLinkHandler } from '../../../linkhandler/LinkHandler';
import { TimeAgoParser } from '../../../localization/TimeAgoParser';
import {
  ContentNotAvailableException,
  ExtractionException,
  ParsingException
} from '../../../exceptions/Exceptions';
import { getQueryValue, isNullOrEmpty, stringToURL } from '../../../core/Utils';
import { Description } from '../../../../../model/extractor/Description';
import { Image } from '../../../../../model/extractor/Image';
import { InfoItemsPage } from '../../../../../model/extractor/ListExtractorInfoItemsPage';
import { Page } from '../../../../../model/extractor/Page';
import { PlaylistType } from '../../../../../model/extractor/PlaylistType';
import { StreamInfoItem } from '../../../../../model/extractor/StreamInfoItem';
import { ResolutionLevel } from '../../../../../model/enums/ImageResolutionLevel';
import {
  DISABLE_PRETTY_PRINT_PARAMETER,
  YOUTUBEI_V1_URL,
  extractCookieValue,
  extractPlaylistTypeFromPlaylistId,
  extractVideoIdFromMixId,
  getTextAtKey,
  getValidJsonResponseBody,
  getYouTubeHeaders,
  isConsentAccepted,
  prepareDesktopJsonBuilder
} from '../YoutubeParsingHelper';
import { YoutubeStreamInfoItemExtractor } from './YoutubeStreamInfoItemExtractor';
import { url as ohosUrl } from '@kit.ArkTS';

/**
 * sqdefault and maxresdefault are not available on every video, so they are deliberately left out
 * of the available resolutions, exactly as in the source.
 */
const IMAGE_URL_SUFFIXES_AND_RESOLUTIONS: ImageSuffix[] = [
  new ImageSuffix('default.jpg', 90, 120, ResolutionLevel.LOW),
  new ImageSuffix('mqdefault.jpg', 180, 320, ResolutionLevel.MEDIUM),
  new ImageSuffix('hqdefault.jpg', 360, 480, ResolutionLevel.MEDIUM)
];

/** The cookie YouTube needs to continue a mix; carried on every Page. */
export const COOKIE_NAME: string = 'VISITOR_INFO1_LIVE';

function getDownloader(): Downloader {
  const downloader: Downloader | null = NewPipe.getDownloader();
  if (downloader === null) {
    throw new ExtractionException('Downloader is not initialised');
  }
  return downloader;
}

export class YoutubeMixPlaylistExtractor extends PlaylistExtractor {
  private initialData: JsonObject = new JsonObject();
  private playlistData: JsonObject = new JsonObject();
  private cookieValue: string = '';

  constructor(service: StreamingService, linkHandler: ListLinkHandler) {
    super(service, linkHandler);
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
    const localization: Localization = this.getExtractorLocalization();
    const url: ohosUrl.URL = stringToURL(this.getUrl());
    const mixPlaylistId: string = this.getId();
    const videoId: string | null = getQueryValue(url, 'v');
    const playlistIndexString: string | null = getQueryValue(url, 'index');

    const jsonBody: JsonBuilder =
      (await prepareDesktopJsonBuilder(localization, this.getExtractorContentCountry()))
        .value('playlistId', mixPlaylistId);
    if (videoId !== null) {
      jsonBody.value('videoId', videoId);
    }
    if (playlistIndexString !== null) {
      jsonBody.value('playlistIndex', Number.parseInt(playlistIndexString, 10));
    }

    const body: ArrayBuffer = Request.utf8Body(JsonWriter.stringValue(jsonBody.done()));

    // The consent cookie is required here
    const headers: HeaderMap = await getYouTubeHeaders();
    const response: Response = await getDownloader().postWithContentTypeJson(
      YOUTUBEI_V1_URL + 'next?' + DISABLE_PRETTY_PRINT_PARAMETER, headers, body, localization);

    this.initialData = JsonUtils.toJsonObject(getValidJsonResponseBody(response));
    this.playlistData = this.initialData
      .getObject('contents')
      .getObject('twoColumnWatchNextResults')
      .getObject('playlist')
      .getObject('playlist');

    if (this.playlistData.size() === 0) {
      const ex: ExtractionException = new ExtractionException('Could not get playlistData');
      if (!isConsentAccepted()) {
        throw new ContentNotAvailableException(
          'Consent is required in some countries to view Mix playlists', ex);
      }
      throw ex;
    }

    this.cookieValue = extractCookieValue(COOKIE_NAME, response);
  }

  getName(): string {
    const name: string | null = getTextAtKey(this.playlistData, 'title');
    if (isNullOrEmpty(name)) {
      throw new ParsingException('Could not get playlist name');
    }
    return name as string;
  }

  getThumbnails(): Image[] {
    try {
      return YoutubeMixPlaylistExtractor.getThumbnailsFromPlaylistId(
        this.playlistData.getString('playlistId', '') as string);
    } catch (e) {
      try {
        // Fall back to the current video's thumbnail; always the case for channel mixes
        return YoutubeMixPlaylistExtractor.getThumbnailsFromVideoId(
          this.initialData.getObject('currentVideoEndpoint')
            .getObject('watchEndpoint')
            .getString('videoId', '') as string);
      } catch (ignored) {
        // fall through to the original error
      }
      throw new ParsingException('Could not get playlist thumbnails',
        e instanceof Error ? e as Error : null);
    }
  }

  getUploaderUrl(): string {
    // YouTube mixes are auto-generated by YouTube
    return '';
  }

  getUploaderName(): string {
    // YouTube mixes are auto-generated by YouTube
    return 'YouTube';
  }

  getUploaderAvatars(): Image[] {
    // YouTube mixes are auto-generated by YouTube
    return [];
  }

  isUploaderVerified(): boolean {
    return false;
  }

  getStreamCount(): number {
    // Auto-generated playlists always start with 25 videos and are endless
    return ITEM_COUNT_INFINITE;
  }

  getDescription(): Description {
    return Description.EMPTY_DESCRIPTION;
  }

  async getInitialPage(): Promise<InfoItemsPage<StreamInfoItem>> {
    const collector: StreamInfoItemsCollector =
      new StreamInfoItemsCollector(this.getServiceId());
    this.collectStreamsFrom(collector, this.playlistData.getArray('contents').toArray());

    const cookies: Map<string, string> = new Map<string, string>();
    cookies.set(COOKIE_NAME, this.cookieValue);

    return InfoItemsPage.fromCollector(collector,
      await this.getNextPageFrom(this.playlistData, cookies));
  }

  private async getNextPageFrom(playlistJson: JsonObject,
    cookies: Map<string, string>): Promise<Page> {
    const contents: JsonArray = playlistJson.getArray('contents');
    const lastStream: JsonObject = contents.getObject(contents.size() - 1);
    if (contents.size() === 0 || lastStream.getObject('playlistPanelVideoRenderer').size() === 0) {
      throw new ExtractionException('Could not extract next page url');
    }

    const watchEndpoint: JsonObject = lastStream.getObject('playlistPanelVideoRenderer')
      .getObject('navigationEndpoint')
      .getObject('watchEndpoint');
    const playlistId: string | null = watchEndpoint.getString('playlistId');
    const videoId: string | null = watchEndpoint.getString('videoId');
    const index: number = watchEndpoint.getInt('index');
    const params: string | null = watchEndpoint.getString('params');

    const body: ArrayBuffer = Request.utf8Body(JsonWriter.stringValue(
      (await prepareDesktopJsonBuilder(this.getExtractorLocalization(),
        this.getExtractorContentCountry()))
        .value('videoId', videoId)
        .value('playlistId', playlistId)
        .value('playlistIndex', index)
        .value('params', params)
        .done()));

    return new Page(YOUTUBEI_V1_URL + 'next?' + DISABLE_PRETTY_PRINT_PARAMETER, null, null,
      cookies, body);
  }

  async getPage(page: Page): Promise<InfoItemsPage<StreamInfoItem>> {
    if (page === null || isNullOrEmpty(page.getUrl())) {
      throw new ParsingException('Page doesn\'t contain an URL');
    }
    const pageCookies: Map<string, string> | null = page.getCookies();
    if (pageCookies === null || !pageCookies.has(COOKIE_NAME)) {
      throw new ParsingException('Cookie \'' + COOKIE_NAME + '\' is missing');
    }

    const collector: StreamInfoItemsCollector =
      new StreamInfoItemsCollector(this.getServiceId());

    // The consent cookie is required here
    const headers: HeaderMap = await getYouTubeHeaders();
    const response: Response = await getDownloader().postWithContentTypeJson(
      page.getUrl() as string, headers, page.getBody(), this.getExtractorLocalization());

    const ajaxJson: JsonObject = JsonUtils.toJsonObject(getValidJsonResponseBody(response));
    const playlistJson: JsonObject = ajaxJson.getObject('contents')
      .getObject('twoColumnWatchNextResults')
      .getObject('playlist')
      .getObject('playlist');

    const allStreams: JsonArray = playlistJson.getArray('contents');
    // A sublist, because YouTube returns up to 24 previous streams in the mix; +1 because the
    // stream at currentIndex was already extracted by the previous request
    const newStreams: Array<JsonValue | null> =
      allStreams.toArray().slice(playlistJson.getInt('currentIndex') + 1, allStreams.size());

    this.collectStreamsFrom(collector, newStreams);
    return InfoItemsPage.fromCollector(collector,
      await this.getNextPageFrom(playlistJson, pageCookies));
  }

  private collectStreamsFrom(collector: StreamInfoItemsCollector,
    streams: Array<JsonValue | null>): void {
    const timeAgoParser: TimeAgoParser = this.getTimeAgoParser();
    for (const stream of JsonArray.fromValues(streams).streamAsJsonObjects()) {
      collector.commit(new YoutubeStreamInfoItemExtractor(
        stream.getObject('playlistPanelVideoRenderer'), timeAgoParser));
    }
  }

  private static getThumbnailsFromPlaylistId(playlistId: string): Image[] {
    return YoutubeMixPlaylistExtractor.getThumbnailsFromVideoId(
      extractVideoIdFromMixId(playlistId));
  }

  private static getThumbnailsFromVideoId(videoId: string): Image[] {
    const baseUrl: string = 'https://i.ytimg.com/vi/' + videoId + '/';
    const images: Image[] = [];
    for (const imageSuffix of IMAGE_URL_SUFFIXES_AND_RESOLUTIONS) {
      images.push(new Image(baseUrl + imageSuffix.getSuffix(), imageSuffix.getHeight(),
        imageSuffix.getWidth(), imageSuffix.getResolutionLevel()));
    }
    return images;
  }

  getPlaylistType(): PlaylistType {
    return extractPlaylistTypeFromPlaylistId(this.playlistData.getString('playlistId'));
  }
}
