/*
 * Port of org.schabi.newpipe.extractor.services.soundcloud.extractors.SoundcloudSearchExtractor
 * (NewPipeExtractor v0.26.5).
 */

import { InfoItemsPage } from '../../../../../model/extractor/ListExtractorInfoItemsPage';
import { MetaInfo } from '../../../../../model/extractor/MetaInfo';
import { Page } from '../../../../../model/extractor/Page';
import { InfoItem } from '../../../core/InfoItem';
import { StreamingService } from '../../../core/StreamingService';
import { getQueryValue, isNullOrEmpty, stringToURL } from '../../../core/Utils';
import { Downloader } from '../../../downloader/Downloader';
import { ParsingException } from '../../../exceptions/Exceptions';
import { SearchQueryHandler } from '../../../linkhandler/LinkHandler';
import { NothingFoundException, SearchExtractor } from '../../../info/SearchExtractor';
import { JsonArray, JsonObject, JsonParser } from '../../../json/NanoJson';
import { MultiInfoItemsCollector } from '../../../core/MultiInfoItemsCollector';
import { ITEMS_PER_PAGE } from '../linkHandler/SoundcloudSearchQueryHandlerFactory';
import { SoundcloudChannelInfoItemExtractor } from './SoundcloudChannelInfoItemExtractor';
import { SoundcloudPlaylistInfoItemExtractor } from './SoundcloudPlaylistInfoItemExtractor';
import { SoundcloudStreamInfoItemExtractor } from './SoundcloudStreamInfoItemExtractor';

const COLLECTION: string = 'collection';
const TOTAL_RESULTS: string = 'total_results';

export class SoundcloudSearchExtractor extends SearchExtractor {
  private initialSearchObject: JsonObject | null = null;

  constructor(service: StreamingService, linkHandler: SearchQueryHandler) {
    super(service, linkHandler);
  }

  getSearchSuggestion(): string {
    return '';
  }

  isCorrectedSearch(): boolean {
    return false;
  }

  getMetaInfo(): MetaInfo[] {
    return [];
  }

  private requireInitialSearchObject(): JsonObject {
    if (this.initialSearchObject === null) {
      throw new ParsingException('Page is not fetched. Make sure you call fetchPage()');
    }
    return this.initialSearchObject;
  }

  async getInitialPage(): Promise<InfoItemsPage<InfoItem>> {
    const initial: JsonObject = this.requireInitialSearchObject();
    if (initial.getInt(TOTAL_RESULTS) > ITEMS_PER_PAGE) {
      return InfoItemsPage.fromCollector(this.collectItems(initial.getArray(COLLECTION)),
        this.getNextPageFromCurrentUrl(this.getUrl(), ITEMS_PER_PAGE, false));
    }
    return InfoItemsPage.fromCollector(this.collectItems(initial.getArray(COLLECTION)), null);
  }

  async getPage(page: Page): Promise<InfoItemsPage<InfoItem>> {
    if (page === null || isNullOrEmpty(page.getUrl())) {
      throw new Error('Page doesn\'t contain an URL');
    }
    const pageUrl: string = page.getUrl() as string;

    const dl: Downloader = this.getDownloader();
    // Only the parse is wrapped, as in the source, which catches JsonParserException alone: the
    // IOException of the download has to reach the caller as a network error.
    const response: string =
      (await dl.get(pageUrl, null, this.getExtractorLocalization())).responseBody();
    let result: JsonObject = new JsonObject();
    try {
      result = JsonParser.object().from(response);
    } catch (e) {
      throw new ParsingException('Could not parse json response',
        e instanceof Error ? e as Error : null);
    }
    const searchCollection: JsonArray = result.getArray(COLLECTION);
    const totalResults: number = result.getInt(TOTAL_RESULTS);

    if (this.getOffsetFromUrl(pageUrl) + ITEMS_PER_PAGE < totalResults) {
      return InfoItemsPage.fromCollector(this.collectItems(searchCollection),
        this.getNextPageFromCurrentUrl(pageUrl, ITEMS_PER_PAGE, true));
    }
    return InfoItemsPage.fromCollector(this.collectItems(searchCollection), null);
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
    const dl: Downloader = this.getDownloader();
    const url: string = this.getUrl();
    // Only the parse is wrapped, as in the source, which catches JsonParserException alone: the
    // IOException of the download has to reach the caller as a network error.
    const response: string =
      (await dl.get(url, null, this.getExtractorLocalization())).responseBody();
    try {
      this.initialSearchObject = JsonParser.object().from(response);
    } catch (e) {
      throw new ParsingException('Could not parse json response',
        e instanceof Error ? e as Error : null);
    }

    if (this.requireInitialSearchObject().getArray(COLLECTION).size() === 0) {
      throw new NothingFoundException('Nothing found');
    }
  }

  private collectItems(searchCollection: JsonArray): MultiInfoItemsCollector {
    const collector: MultiInfoItemsCollector =
      new MultiInfoItemsCollector(this.getServiceId());

    for (const searchResult of searchCollection.streamAsJsonObjects()) {
      const kind: string | null = searchResult.getString('kind', '');
      if (kind === 'user') {
        collector.commit(new SoundcloudChannelInfoItemExtractor(searchResult));
      } else if (kind === 'track') {
        collector.commit(new SoundcloudStreamInfoItemExtractor(searchResult));
      } else if (kind === 'playlist') {
        collector.commit(new SoundcloudPlaylistInfoItemExtractor(searchResult));
      }
    }

    return collector;
  }

  /**
   * The source passes an IntUnaryOperator: the initial page jumps straight to ITEMS_PER_PAGE,
   * a later page adds ITEMS_PER_PAGE to its own offset. `addToCurrent` picks between the two.
   */
  private getNextPageFromCurrentUrl(currentUrl: string, step: number,
    addToCurrent: boolean): Page {
    const currentPageOffset: number = this.getOffsetFromUrl(currentUrl);
    const newOffset: number = addToCurrent ? currentPageOffset + step : step;

    return new Page(currentUrl.replace('&offset=' + currentPageOffset, '&offset=' + newOffset));
  }

  private getOffsetFromUrl(url: string): number {
    const offset: string | null = getQueryValue(stringToURL(url), 'offset');
    if (offset === null) {
      throw new ParsingException('Could not get offset from page URL');
    }
    return Number.parseInt(offset, 10);
  }
}
