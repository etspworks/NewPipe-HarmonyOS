/*
 * Port of org.schabi.newpipe.extractor.services.youtube.extractors.YoutubeSearchExtractor
 * (NewPipeExtractor v0.26.5).
 *
 * A POLYMORPHIC list: one search page mixes video, channel, playlist, show and lockup rows, and
 * collectStreamsFrom branches per renderer exactly as the source does. Dropping a branch here
 * would silently drop that result type from search.
 */

import { JsonArray, JsonObject, JsonBuilder, JsonWriter } from '../../../json/NanoJson';
import { Downloader, Request } from '../../../downloader/Downloader';
import { Localization } from '../../../downloader/Localization';
import { StreamingService } from '../../../core/StreamingService';
import { InfoItem } from '../../../core/InfoItem';
import { JsonUtils } from '../../../core/JsonUtils';
import { NothingFoundException, SearchExtractor } from '../../../info/SearchExtractor';
import { SearchQueryHandler } from '../../../linkhandler/LinkHandler';
import { TimeAgoParser } from '../../../localization/TimeAgoParser';
import { ParsingException } from '../../../exceptions/Exceptions';
import { isNullOrEmpty } from '../../../core/Utils';
import { InfoItemsPage } from '../../../../../model/extractor/ListExtractorInfoItemsPage';
import { MetaInfo } from '../../../../../model/extractor/MetaInfo';
import { Page } from '../../../../../model/extractor/Page';
import { MultiInfoItemsCollector } from '../../../core/MultiInfoItemsCollector';
import {
  DISABLE_PRETTY_PRINT_PARAMETER,
  YOUTUBEI_V1_URL,
  getJsonPostResponse,
  getTextFromObject,
  prepareDesktopJsonBuilder
} from '../YoutubeParsingHelper';
import { getMetaInfo } from '../YoutubeMetaInfoHelper';
import {
  ALL,
  CHANNELS,
  PLAYLISTS,
  VIDEOS,
  getSearchParameter
} from '../linkHandler/YoutubeSearchQueryHandlerFactory';
import { YoutubeStreamInfoItemExtractor } from './YoutubeStreamInfoItemExtractor';
import { YoutubeChannelInfoItemExtractor } from './YoutubeChannelInfoItemExtractor';
import { YoutubePlaylistInfoItemExtractor } from './YoutubePlaylistInfoItemExtractor';
import {
  YoutubeMixOrPlaylistLockupInfoItemExtractor,
  YoutubeShowRendererInfoItemExtractor
} from './YoutubeLockupInfoItemExtractors';
import { YoutubeStreamInfoItemLockupExtractor } from './YoutubeStreamInfoItemLockupExtractor';

export class YoutubeSearchExtractor extends SearchExtractor {
  private readonly searchType: string | null;
  private readonly extractVideoResults: boolean;
  private readonly extractChannelResults: boolean;
  private readonly extractPlaylistResults: boolean;
  private initialData: JsonObject = new JsonObject();

  constructor(service: StreamingService, linkHandler: SearchQueryHandler) {
    super(service, linkHandler);
    const contentFilters: string[] = linkHandler.getContentFilters();
    this.searchType = contentFilters.length === 0 ? null : contentFilters[0];

    // Which result types to extract, since YouTube sometimes returns videos inside channel
    // search results. With no search type, or the ALL filter, everything is extracted.
    this.extractVideoResults = this.searchType === null || this.searchType === ALL
      || this.searchType === VIDEOS;
    this.extractChannelResults = this.searchType === null || this.searchType === ALL
      || this.searchType === CHANNELS;
    this.extractPlaylistResults = this.searchType === null || this.searchType === ALL
      || this.searchType === PLAYLISTS;
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
    const query: string = this.getSearchString();
    const localization: Localization = this.getExtractorLocalization();
    const params: string = getSearchParameter(this.searchType);

    const jsonBody: JsonBuilder =
      (await prepareDesktopJsonBuilder(localization, this.getExtractorContentCountry()))
        .value('query', query);
    if (!isNullOrEmpty(params)) {
      jsonBody.value('params', params);
    }

    const body: ArrayBuffer = Request.utf8Body(JsonWriter.stringValue(jsonBody.done()));
    this.initialData = await getJsonPostResponse('search', body, localization);
  }

  getUrl(): string {
    return super.getUrl() + '&gl=' + this.getExtractorContentCountry().getCountryCode();
  }

  getSearchSuggestion(): string {
    const itemSectionRenderer: JsonObject = this.primaryContents()
      .getArray('contents')
      .getObject(0)
      .getObject('itemSectionRenderer');

    const didYouMeanRenderer: JsonObject = itemSectionRenderer.getArray('contents')
      .getObject(0)
      .getObject('didYouMeanRenderer');
    if (didYouMeanRenderer.size() > 0) {
      return JsonUtils.getString(didYouMeanRenderer,
        'correctedQueryEndpoint.searchEndpoint.query');
    }

    const correctedQuery: string | null = getTextFromObject(itemSectionRenderer
      .getArray('contents')
      .getObject(0)
      .getObject('showingResultsForRenderer')
      .getObject('correctedQuery'));
    return correctedQuery === null ? '' : correctedQuery;
  }

  isCorrectedSearch(): boolean {
    const showingResultsForRenderer: JsonObject = this.primaryContents()
      .getArray('contents')
      .getObject(0)
      .getObject('itemSectionRenderer')
      .getArray('contents')
      .getObject(0)
      .getObject('showingResultsForRenderer');
    return showingResultsForRenderer.size() > 0;
  }

  getMetaInfo(): MetaInfo[] {
    return getMetaInfo(this.primaryContents().getArray('contents'));
  }

  async getInitialPage(): Promise<InfoItemsPage<InfoItem>> {
    const collector: MultiInfoItemsCollector =
      new MultiInfoItemsCollector(this.getServiceId());
    const sections: JsonArray = this.primaryContents().getArray('contents');

    let nextPage: Page | null = null;
    for (const sectionJsonObject of sections.streamAsJsonObjects()) {
      if (sectionJsonObject.has('itemSectionRenderer')) {
        this.collectStreamsFrom(collector,
          sectionJsonObject.getObject('itemSectionRenderer').getArray('contents'));
      } else if (sectionJsonObject.has('continuationItemRenderer')) {
        nextPage = YoutubeSearchExtractor.getNextPageFrom(
          sectionJsonObject.getObject('continuationItemRenderer'));
      }
    }

    return InfoItemsPage.fromCollector(collector, nextPage);
  }

  async getPage(page: Page): Promise<InfoItemsPage<InfoItem>> {
    if (page === null || isNullOrEmpty(page.getUrl())) {
      throw new ParsingException('Page doesn\'t contain an URL');
    }

    const localization: Localization = this.getExtractorLocalization();
    const collector: MultiInfoItemsCollector =
      new MultiInfoItemsCollector(this.getServiceId());

    const json: ArrayBuffer = Request.utf8Body(JsonWriter.stringValue(
      (await prepareDesktopJsonBuilder(localization, this.getExtractorContentCountry()))
        .value('continuation', page.getId())
        .done()));

    const ajaxJson: JsonObject = await getJsonPostResponse('search', json, localization);

    const continuationItems: JsonArray = ajaxJson.getArray('onResponseReceivedCommands')
      .getObject(0)
      .getObject('appendContinuationItemsAction')
      .getArray('continuationItems');

    const contents: JsonArray = continuationItems.getObject(0)
      .getObject('itemSectionRenderer')
      .getArray('contents');
    this.collectStreamsFrom(collector, contents);

    return InfoItemsPage.fromCollector(collector, YoutubeSearchExtractor.getNextPageFrom(
      continuationItems.getObject(1).getObject('continuationItemRenderer')));
  }

  private primaryContents(): JsonObject {
    return this.initialData.getObject('contents')
      .getObject('twoColumnSearchResultsRenderer')
      .getObject('primaryContents')
      .getObject('sectionListRenderer');
  }

  private collectStreamsFrom(collector: MultiInfoItemsCollector, contents: JsonArray): void {
    const timeAgoParser: TimeAgoParser = this.getTimeAgoParser();

    for (const item of contents.streamAsJsonObjects()) {
      if (item.has('backgroundPromoRenderer')) {
        const bodyText: string | null = getTextFromObject(
          item.getObject('backgroundPromoRenderer').getObject('bodyText'));
        throw new NothingFoundException(bodyText === null ? '' : bodyText);
      } else if (item.has('videoRenderer') && this.extractVideoResults) {
        collector.commit(new YoutubeStreamInfoItemExtractor(item.getObject('videoRenderer'),
          timeAgoParser));
      } else if (item.has('channelRenderer') && this.extractChannelResults) {
        collector.commit(new YoutubeChannelInfoItemExtractor(item.getObject('channelRenderer')));
      } else if (item.has('playlistRenderer') && this.extractPlaylistResults) {
        collector.commit(new YoutubePlaylistInfoItemExtractor(
          item.getObject('playlistRenderer')));
      } else if (item.has('showRenderer') && this.extractPlaylistResults) {
        collector.commit(new YoutubeShowRendererInfoItemExtractor(
          item.getObject('showRenderer')));
      } else if (item.has('lockupViewModel')) {
        const lockupViewModel: JsonObject = item.getObject('lockupViewModel');
        const contentType: string | null = lockupViewModel.getString('contentType');
        if ((contentType === 'LOCKUP_CONTENT_TYPE_PLAYLIST'
          || contentType === 'LOCKUP_CONTENT_TYPE_PODCAST') && this.extractPlaylistResults) {
          collector.commit(new YoutubeMixOrPlaylistLockupInfoItemExtractor(lockupViewModel));
        } else if (contentType === 'LOCKUP_CONTENT_TYPE_VIDEO' && this.extractVideoResults) {
          collector.commit(new YoutubeStreamInfoItemLockupExtractor(lockupViewModel,
            timeAgoParser));
        }
      }
    }
  }

  private static getNextPageFrom(continuationItemRenderer: JsonObject): Page | null {
    if (continuationItemRenderer.size() === 0) {
      return null;
    }
    const token: string | null = continuationItemRenderer.getObject('continuationEndpoint')
      .getObject('continuationCommand')
      .getString('token');
    const url: string = YOUTUBEI_V1_URL + 'search?' + DISABLE_PRETTY_PRINT_PARAMETER;
    return new Page(url, token);
  }
}
