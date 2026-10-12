/*
 * Port of the eight YouTube kiosk extractors (NewPipeExtractor v0.26.5):
 *   YoutubeChartsBaseKioskExtractor (+ its nested YoutubeChartsVideoInfoItemExtractor),
 *   YoutubeDesktopBaseKioskExtractor, YoutubeLiveExtractor, YoutubeTrendingExtractor,
 *   YoutubeTrendingGamingVideosExtractor, YoutubeTrendingMoviesAndShowsTrailersExtractor,
 *   YoutubeTrendingMusicExtractor, YoutubeTrendingPodcastsEpisodesExtractor.
 *
 * Six of them are 15-line subclasses of the two bases, so they share this module rather than
 * eight files of imports. Every browseId, params value and chart type is the source's.
 *
 * `LocalDate.atStartOfDay(ZoneOffset.UTC)` becomes Date.UTC(...) — YouTube Charts returns the
 * release date as year/month/day only, so the DateWrapper is marked approximate as in the source.
 */

import { JsonArray, JsonObject, JsonWriter } from '../../../../json/NanoJson';
import { Downloader, HeaderMap, Request } from '../../../../downloader/Downloader';
import { ContentCountry } from '../../../../localization/ContentCountry';
import { Localization } from '../../../../downloader/Localization';
import { StreamingService } from '../../../../core/StreamingService';
import { JsonUtils } from '../../../../core/JsonUtils';
import { NewPipe } from '../../../../core/NewPipe';
import { KioskExtractor } from '../../../../info/KioskList';
import { StreamInfoItemExtractor } from '../../../../info/StreamInfoItemExtractor';
import { StreamInfoItemsCollector } from '../../../../info/StreamInfoItemsCollector';
import { ListLinkHandler } from '../../../../linkhandler/LinkHandler';
import { TimeAgoParser } from '../../../../localization/TimeAgoParser';
import { DateWrapper } from '../../../../localization/DateWrapper';
import {
  ExtractionException,
  ParsingException,
  UnsupportedContentInCountryException
} from '../../../../exceptions/Exceptions';
import { isNullOrEmpty } from '../../../../core/Utils';
import { Image } from '../../../../../../model/extractor/Image';
import { InfoItemsPage } from '../../../../../../model/extractor/ListExtractorInfoItemsPage';
import { Page } from '../../../../../../model/extractor/Page';
import { StreamInfoItem } from '../../../../../../model/extractor/StreamInfoItem';
import { StreamType } from '../../../../../../model/enums/StreamType';
import { InnertubeClientRequestInfo } from '../../InnertubeClientRequestInfo';
import {
  DISABLE_PRETTY_PRINT_PARAMETER,
  YOUTUBEI_V1_URL,
  getClientHeaders,
  getClientVersion,
  getJsonPostResponse,
  getOriginReferrerHeaders,
  getTextAtKey,
  getThumbnailsFromInfoItem,
  getValidJsonResponseBody,
  prepareDesktopJsonBuilder,
  prepareJsonBuilder
} from '../../YoutubeParsingHelper';
import {
  ChannelResponseData,
  getChannelHeader,
  getChannelName,
  getChannelResponse
} from '../../YoutubeChannelHelper';
import { YoutubeChannelLinkHandlerFactory } from '../../linkHandler/YoutubeChannelLinkHandlerFactory';
import { YoutubeStreamLinkHandlerFactory } from '../../linkHandler/YoutubeStreamLinkHandlerFactory';
import { YoutubeStreamInfoItemExtractor } from '../YoutubeStreamInfoItemExtractor';
import { YoutubeStreamInfoItemLockupExtractor } from '../YoutubeStreamInfoItemLockupExtractor';

function getDownloader(): Downloader {
  const downloader: Downloader | null = NewPipe.getDownloader();
  if (downloader === null) {
    throw new ExtractionException('Downloader is not initialised');
  }
  return downloader;
}

/* //////////////////////////////////////////////////////////////////////////
// YouTube Charts kiosks
////////////////////////////////////////////////////////////////////////// */

/** Extracted from YouTube Charts' HTML, from the array named LAUNCHED_CHART_COUNTRIES. */
const YT_CHARTS_SUPPORTED_COUNTRY_CODES: string[] = ['AE', 'AR', 'AT', 'AU', 'BE', 'BO', 'BR',
  'CA', 'CH', 'CL', 'CO', 'CR', 'CZ', 'DE', 'DK', 'DO', 'EC', 'EE', 'EG', 'ES', 'FI', 'FR', 'GB',
  'GT', 'HN', 'HU', 'ID', 'IE', 'IL', 'IN', 'IS', 'IT', 'JP', 'KE', 'KR', 'LU', 'MX', 'NG', 'NI',
  'NL', 'NO', 'NZ', 'PA', 'PE', 'PL', 'PT', 'PY', 'RO', 'RS', 'RU', 'SA', 'SE', 'SV', 'TR', 'TZ',
  'UA', 'UG', 'US', 'UY', 'ZA', 'ZW'];

const YT_CHARTS_ENDPOINT: string =
  'https://charts.youtube.com/youtubei/v1/browse?alt=json&' + DISABLE_PRETTY_PRINT_PARAMETER;

/** One video row of a YouTube Charts response; a much thinner shape than a videoRenderer. */
class YoutubeChartsVideoInfoItemExtractor extends StreamInfoItemExtractor {
  private readonly videoObject: JsonObject;

  constructor(videoObject: JsonObject) {
    super();
    this.videoObject = videoObject;
  }

  getStreamType(): StreamType {
    // YouTube Charts carries only video streams, at least for now
    return StreamType.VIDEO_STREAM;
  }

  isAd(): boolean {
    return false;
  }

  getDuration(): number {
    return this.videoObject.getInt('videoDuration', -1);
  }

  getViewCount(): number {
    // View counts are not returned, at least for now
    return -1;
  }

  getUploaderName(): string {
    const name: string | null = this.videoObject.getString('channelName');
    return name === null ? '' : name;
  }

  getUploaderUrl(): string {
    const channelId: string | null = this.videoObject.getString('externalChannelId');
    if (isNullOrEmpty(channelId)) {
      throw new ParsingException('Could not get channel ID');
    }
    return YoutubeChannelLinkHandlerFactory.getInstance().getUrl('channel/' + channelId);
  }

  isUploaderVerified(): boolean {
    // No information about this is returned, at least for now
    return false;
  }

  getTextualUploadDate(): string | null {
    return null;
  }

  getUploadDate(): DateWrapper | null {
    const releaseDate: JsonObject = this.videoObject.getObject('releaseDate');
    // The JSON body asks for times at a 0 offset to UTC, but YouTube Charts only honours that in
    // its HTTP headers, so the date is built at UTC explicitly
    const instant: Date = new Date(Date.UTC(releaseDate.getInt('year'),
      releaseDate.getInt('month') - 1, releaseDate.getInt('day'), 0, 0, 0));
    // Nothing finer than the release day is available, hence isApproximation = true
    return new DateWrapper(instant, true);
  }

  getName(): string {
    const title: string | null = this.videoObject.getString('title');
    return title === null ? '' : title;
  }

  getUrl(): string {
    return YoutubeStreamLinkHandlerFactory.getInstance()
      .getUrl(this.videoObject.getString('id', '') as string);
  }

  getThumbnails(): Image[] {
    return getThumbnailsFromInfoItem(this.videoObject);
  }
}

export abstract class YoutubeChartsBaseKioskExtractor extends KioskExtractor<StreamInfoItem> {
  protected readonly chartType: string;
  protected browseResponse: JsonObject = new JsonObject();

  constructor(streamingService: StreamingService, linkHandler: ListLinkHandler, kioskId: string,
    chartType: string) {
    super(streamingService, linkHandler, kioskId);
    this.chartType = chartType;
  }

  /** True when YouTube Charts covers the extractor's content country. */
  protected isCountrySupported(): boolean {
    return YT_CHARTS_SUPPORTED_COUNTRY_CODES.includes(
      this.getExtractorContentCountry().getCountryCode());
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
    const localization: Localization = this.getExtractorLocalization();
    const contentCountry: ContentCountry = this.getExtractorContentCountry();
    const innertubeClientRequestInfo: InnertubeClientRequestInfo =
      InnertubeClientRequestInfo.ofWebMusicAnalyticsChartsClient();

    const body: ArrayBuffer = Request.utf8Body(JsonWriter.stringValue(
      prepareJsonBuilder(localization, contentCountry, innertubeClientRequestInfo, null)
        .value('browseId', 'FEmusic_analytics_charts_home')
        .value('query', 'perspective=CHART_DETAILS&chart_params_country_code='
          + contentCountry.getCountryCode() + '&chart_params_chart_type=' + this.chartType)
        .done()));

    const headers: HeaderMap = getOriginReferrerHeaders('https://charts.youtube.com');
    getClientHeaders(innertubeClientRequestInfo.clientInfo.clientId,
      innertubeClientRequestInfo.clientInfo.clientVersion)
      .forEach((value: string[], key: string): void => {
        headers.set(key, value);
      });

    this.browseResponse = JsonUtils.toJsonObject(getValidJsonResponseBody(
      await getDownloader().postWithContentTypeJson(YT_CHARTS_ENDPOINT, headers, body,
        localization)));
  }

  abstract getName(): string;

  async getInitialPage(): Promise<InfoItemsPage<StreamInfoItem>> {
    const videos: JsonArray = this.browseResponse.getObject('contents')
      .getObject('sectionListRenderer')
      .getArray('contents')
      .getObject(0)
      .getObject('musicAnalyticsSectionRenderer')
      .getObject('content')
      .getArray('videos')
      .getObject(0)
      .getArray('videoViews');

    const collector: StreamInfoItemsCollector =
      new StreamInfoItemsCollector(this.getServiceId());
    for (const video of videos.streamAsJsonObjects()) {
      collector.commit(new YoutubeChartsVideoInfoItemExtractor(video));
    }
    return InfoItemsPage.fromCollector(collector, null);
  }

  async getPage(page: Page): Promise<InfoItemsPage<StreamInfoItem>> {
    // Charts have no continuation
    return InfoItemsPage.emptyPage<StreamInfoItem>();
  }
}

export class YoutubeTrendingMusicExtractor extends YoutubeChartsBaseKioskExtractor {
  constructor(streamingService: StreamingService, linkHandler: ListLinkHandler, kioskId: string) {
    super(streamingService, linkHandler, kioskId, 'TRENDING_VIDEOS');
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
    if (!this.isCountrySupported()) {
      throw new UnsupportedContentInCountryException(
        'YouTube Charts doesn\'t support this country for trending music videos charts');
    }
    await super.onFetchPage(downloader);
  }

  getName(): string {
    // The official YouTube Charts name, even though auto-generated tracks and unofficial content
    // are returned too
    return 'Trending Music Videos';
  }
}

export class YoutubeTrendingMoviesAndShowsTrailersExtractor
  extends YoutubeChartsBaseKioskExtractor {
  constructor(streamingService: StreamingService, linkHandler: ListLinkHandler, kioskId: string) {
    super(streamingService, linkHandler, kioskId, 'TRENDING_MOVIES');
  }

  getName(): string {
    // The official YouTube Charts name, even though shows' trailers are returned too
    return 'Trending Movie Trailers';
  }
}

/* //////////////////////////////////////////////////////////////////////////
// Desktop browse kiosks
////////////////////////////////////////////////////////////////////////// */

export class YoutubeDesktopBaseKioskExtractor extends KioskExtractor<StreamInfoItem> {
  protected readonly browseId: string;
  protected readonly params: string;
  protected responseData: ChannelResponseData | null = null;

  constructor(streamingService: StreamingService, linkHandler: ListLinkHandler, kioskId: string,
    browseId: string, params: string) {
    super(streamingService, linkHandler, kioskId);
    this.browseId = browseId;
    this.params = params;
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
    this.responseData = await getChannelResponse(this.browseId, this.params,
      this.getExtractorLocalization(), this.getExtractorContentCountry());
  }

  private requireResponseData(): ChannelResponseData {
    const data: ChannelResponseData | null = this.responseData;
    if (data === null) {
      throw new ExtractionException('Page is not fetched. Make sure you call fetchPage()');
    }
    return data;
  }

  getName(): string {
    const jsonResponse: JsonObject = this.requireResponseData().jsonResponse;
    return getChannelName(getChannelHeader(jsonResponse), null, jsonResponse);
  }

  async getInitialPage(): Promise<InfoItemsPage<StreamInfoItem>> {
    const jsonResponse: JsonObject = this.requireResponseData().jsonResponse;
    const tabRendererContent: JsonObject = jsonResponse.getObject('contents')
      .getObject('twoColumnBrowseResultsRenderer')
      .getArray('tabs')
      .getObject(0)
      .getObject('tabRenderer')
      .getObject('content');

    let tabContents: JsonArray;
    if (tabRendererContent.has('sectionListRenderer')) {
      tabContents = tabRendererContent.getObject('sectionListRenderer')
        .getArray('contents')
        .getObject(0)
        .getObject('itemSectionRenderer')
        .getArray('contents')
        .getObject(0)
        .getObject('shelfRenderer')
        .getObject('content')
        .getObject('gridRenderer')
        .getArray('items');
    } else if (tabRendererContent.has('richGridRenderer')) {
      tabContents = tabRendererContent.getObject('richGridRenderer').getArray('contents');
    } else {
      tabContents = new JsonArray();
    }

    return this.collectStreamItems(tabContents,
      jsonResponse.getObject('responseContext').getString('visitorData'));
  }

  async getPage(page: Page): Promise<InfoItemsPage<StreamInfoItem>> {
    if (page === null || page.getBody() === null) {
      throw new ParsingException('Page is null or doesn\'t contain a body');
    }

    const continuationResponse: JsonObject = await getJsonPostResponse('browse',
      page.getBody() as ArrayBuffer, this.getExtractorLocalization());

    let appendAction: JsonObject = new JsonObject();
    for (const jsonObject of continuationResponse.getArray('onResponseReceivedActions')
      .streamAsJsonObjects()) {
      if (jsonObject.has('appendContinuationItemsAction')) {
        appendAction = jsonObject.getObject('appendContinuationItemsAction');
        break;
      }
    }

    // The page ID is the visitor data
    return this.collectStreamItems(appendAction.getArray('continuationItems'), page.getId());
  }

  private async collectStreamItems(items: JsonArray,
    visitorData: string | null): Promise<InfoItemsPage<StreamInfoItem>> {
    const collector: StreamInfoItemsCollector =
      new StreamInfoItemsCollector(this.getServiceId());

    if (items.size() === 0) {
      return InfoItemsPage.fromCollector(collector, null);
    }

    const timeAgoParser: TimeAgoParser = this.getTimeAgoParser();
    for (const content of items.streamAsJsonObjects()) {
      if (content.has('richItemRenderer')) {
        const richItem: JsonObject = content.getObject('richItemRenderer').getObject('content');
        if (richItem.has('videoRenderer')) {
          collector.commit(new YoutubeStreamInfoItemExtractor(
            richItem.getObject('videoRenderer'), timeAgoParser));
        }
      } else if (content.has('gridVideoRenderer')) {
        collector.commit(new YoutubeStreamInfoItemExtractor(
          content.getObject('gridVideoRenderer'), timeAgoParser));
      } else if (content.has('lockupViewModel')) {
        // lockupViewModels are not used here yet, but may be in the future
        const lockupViewModel: JsonObject = content.getObject('lockupViewModel');
        if (lockupViewModel.getString('contentType') === 'LOCKUP_CONTENT_TYPE_VIDEO') {
          collector.commit(new YoutubeStreamInfoItemLockupExtractor(lockupViewModel,
            timeAgoParser));
        }
      }
    }

    const lastContent: JsonObject = items.getObject(items.size() - 1);
    const nextPage: Page | null = lastContent.has('continuationItemRenderer')
      ? await this.getNextPageFrom(lastContent.getObject('continuationItemRenderer'), visitorData)
      : null;

    return InfoItemsPage.fromCollector(collector, nextPage);
  }

  private async getNextPageFrom(continuation: JsonObject,
    visitorData: string | null): Promise<Page | null> {
    if (continuation.size() === 0) {
      return null;
    }

    const continuationToken: string | null = continuation.getObject('continuationEndpoint')
      .getObject('continuationCommand')
      .getString('token');

    // Visitor data is required to get videos in continuations, so it is applied to the next page
    // and kept as its ID so future continuations can reuse it
    const webClientRequestInfo: InnertubeClientRequestInfo =
      InnertubeClientRequestInfo.ofWebClient();
    webClientRequestInfo.clientInfo.clientVersion = await getClientVersion();
    webClientRequestInfo.clientInfo.visitorData = visitorData;

    const body: ArrayBuffer = Request.utf8Body(JsonWriter.stringValue(
      prepareJsonBuilder(this.getExtractorLocalization(), this.getExtractorContentCountry(),
        webClientRequestInfo, null)
        .value('continuation', continuationToken)
        .done()));

    // The URL is neither needed nor used; it is only there so Page.isValid returns true
    return new Page(YOUTUBEI_V1_URL + 'browse?' + DISABLE_PRETTY_PRINT_PARAMETER, visitorData,
      null, null, body);
  }
}

export class YoutubeLiveExtractor extends YoutubeDesktopBaseKioskExtractor {
  constructor(streamingService: StreamingService, linkHandler: ListLinkHandler, kioskId: string) {
    super(streamingService, linkHandler, kioskId, 'UC4R8DWoMoI7CAwX8_LjQHig',
      'EgdsaXZldGFikgEDCKEK');
  }
}

export class YoutubeTrendingGamingVideosExtractor extends YoutubeDesktopBaseKioskExtractor {
  constructor(streamingService: StreamingService, linkHandler: ListLinkHandler, kioskId: string) {
    super(streamingService, linkHandler, kioskId, 'UCOpNcN46UbXVtpKMrmU4Abg',
      'Egh0cmVuZGluZw%3D%3D');
  }
}

export class YoutubeTrendingPodcastsEpisodesExtractor extends YoutubeDesktopBaseKioskExtractor {
  constructor(streamingService: StreamingService, linkHandler: ListLinkHandler, kioskId: string) {
    super(streamingService, linkHandler, kioskId, 'FEpodcasts_destination', 'qgcCCAM%3D');
  }
}

/* //////////////////////////////////////////////////////////////////////////
// The (deprecated) Trending kiosk
////////////////////////////////////////////////////////////////////////// */

const VIDEOS_TAB_PARAMS: string = '4gIOGgxtb3N0X3BvcHVsYXI%3D';

export class YoutubeTrendingExtractor extends KioskExtractor<StreamInfoItem> {
  static readonly KIOSK_ID: string = 'Trending';
  private initialData: JsonObject = new JsonObject();

  constructor(service: StreamingService, linkHandler: ListLinkHandler, kioskId: string) {
    super(service, linkHandler, kioskId);
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
    const body: ArrayBuffer = Request.utf8Body(JsonWriter.stringValue(
      (await prepareDesktopJsonBuilder(this.getExtractorLocalization(),
        this.getExtractorContentCountry()))
        .value('browseId', 'FEtrending')
        .value('params', VIDEOS_TAB_PARAMS)
        .done()));

    this.initialData =
      await getJsonPostResponse('browse', body, this.getExtractorLocalization());
  }

  async getPage(page: Page): Promise<InfoItemsPage<StreamInfoItem>> {
    return InfoItemsPage.emptyPage<StreamInfoItem>();
  }

  getName(): string {
    const header: JsonObject = this.initialData.getObject('header');
    let name: string | null = null;
    if (header.has('feedTabbedHeaderRenderer')) {
      name = getTextAtKey(header.getObject('feedTabbedHeaderRenderer'), 'title');
    } else if (header.has('c4TabbedHeaderRenderer')) {
      name = getTextAtKey(header.getObject('c4TabbedHeaderRenderer'), 'title');
    } else if (header.has('pageHeaderRenderer')) {
      name = getTextAtKey(header.getObject('pageHeaderRenderer'), 'pageTitle');
    }
    if (isNullOrEmpty(name)) {
      throw new ParsingException('Could not get Trending name');
    }
    return name as string;
  }

  async getInitialPage(): Promise<InfoItemsPage<StreamInfoItem>> {
    const collector: StreamInfoItemsCollector =
      new StreamInfoItemsCollector(this.getServiceId());
    const timeAgoParser: TimeAgoParser = this.getTimeAgoParser();

    const tab: JsonObject = this.getTrendingTab();
    const tabContent: JsonObject = tab.getObject('content');
    const isVideoTab: boolean = tab.getObject('endpoint')
      .getObject('browseEndpoint')
      .getString('params', '') === VIDEOS_TAB_PARAMS;

    if (tabContent.has('richGridRenderer')) {
      for (const content of tabContent.getObject('richGridRenderer').getArray('contents')
        .streamAsJsonObjects()) {
        // Filters out the Trending shorts and Recently trending sections
        if (!content.has('richItemRenderer')) {
          continue;
        }
        collector.commit(new YoutubeStreamInfoItemExtractor(
          content.getObject('richItemRenderer').getObject('content').getObject('videoRenderer'),
          timeAgoParser));
      }
    } else if (tabContent.has('sectionListRenderer')) {
      const shelves: JsonObject[] = [];
      for (const content of tabContent.getObject('sectionListRenderer').getArray('contents')
        .streamAsJsonObjects()) {
        for (const sectionContent of content.getObject('itemSectionRenderer')
          .getArray('contents').streamAsJsonObjects()) {
          shelves.push(sectionContent.getObject('shelfRenderer'));
        }
      }

      let items: JsonObject[];
      if (isVideoTab) {
        // The first shelf of the Videos tab holds the normal trends
        items = shelves.length === 0 ? [] : [shelves[0]];
      } else {
        // Filter out the Trending shorts and Recently trending sections, which carry a title
        // unlike the normal trends
        items = [];
        for (const shelfRenderer of shelves) {
          if (!shelfRenderer.has('title')) {
            items.push(shelfRenderer);
          }
        }
      }

      for (const shelfRenderer of items) {
        for (const item of shelfRenderer.getObject('content')
          .getObject('expandedShelfContentsRenderer')
          .getArray('items')
          .streamAsJsonObjects()) {
          collector.commit(new YoutubeStreamInfoItemExtractor(item.getObject('videoRenderer'),
            timeAgoParser));
        }
      }
    }

    return InfoItemsPage.fromCollector(collector, null);
  }

  private getTrendingTab(): JsonObject {
    for (const tab of this.initialData.getObject('contents')
      .getObject('twoColumnBrowseResultsRenderer')
      .getArray('tabs')
      .streamAsJsonObjects()) {
      const tabRenderer: JsonObject = tab.getObject('tabRenderer');
      // There should be at most one selected tab
      if (tabRenderer.getBoolean('selected') && tabRenderer.has('content')) {
        return tabRenderer;
      }
    }
    throw new ParsingException('Could not get \"Now\" or \"Videos\" trending tab');
  }
}
