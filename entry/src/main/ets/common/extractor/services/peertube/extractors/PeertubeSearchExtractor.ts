/*
 * Port of org.schabi.newpipe.extractor.services.peertube.extractors.PeertubeSearchExtractor
 * (NewPipeExtractor v0.26.5).
 *
 * The search url comes from PeertubeSearchQueryHandlerFactory, so a `sepia_` content filter has
 * already sent it to https://sepiasearch.org rather than to the user's own instance.
 */

import { SearchExtractor } from '../../../info/SearchExtractor';
import { StreamingService } from '../../../core/StreamingService';
import { SearchQueryHandler } from '../../../linkhandler/LinkHandler';
import { Downloader, Response } from '../../../downloader/Downloader';
import { JsonObject, JsonParser } from '../../../json/NanoJson';
import { isBlank, isNullOrEmpty } from '../../../core/Utils';
import { toError } from '../../../core/Errors';
import { ExtractionException, ParsingException } from '../../../exceptions/Exceptions';
import { InfoItem } from '../../../core/InfoItem';
import { InfoItemsPage } from '../../../../../model/extractor/ListExtractorInfoItemsPage';
import { MetaInfo } from '../../../../../model/extractor/MetaInfo';
import { Page } from '../../../../../model/extractor/Page';
import { COUNT_KEY, getNextPage, ITEMS_PER_PAGE, START_KEY, validate } from '../PeertubeParsingHelper';
import { collectItemsFrom } from '../PeertubeItemCollector';
import { MultiInfoItemsCollector } from '../../../core/MultiInfoItemsCollector';

export class PeertubeSearchExtractor extends SearchExtractor {
  /** if we should use PeertubeSepiaStreamInfoItemExtractor */
  private readonly sepia: boolean;

  constructor(service: StreamingService, linkHandler: SearchQueryHandler,
    sepia: boolean = false) {
    super(service, linkHandler);
    this.sepia = sepia;
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

  async getInitialPage(): Promise<InfoItemsPage<InfoItem>> {
    return this.getPage(new Page(this.getUrl() + '&' + START_KEY + '=0&'
      + COUNT_KEY + '=' + ITEMS_PER_PAGE));
  }

  async getPage(page: Page): Promise<InfoItemsPage<InfoItem>> {
    const pageUrl: string | null = page === null ? null : page.getUrl();
    if (isNullOrEmpty(pageUrl)) {
      throw new Error("Page doesn't contain an URL");
    }

    const response: Response = await this.getDownloader().get(pageUrl as string);

    let json: JsonObject | null = null;
    if (!isBlank(response.responseBody())) {
      try {
        json = JsonParser.object().from(response.responseBody());
      } catch (e) {
        throw new ParsingException('Could not parse json data for search info', toError(e));
      }
    }

    if (json !== null) {
      validate(json);
      const total: number = json.getLong('total');

      const collector: MultiInfoItemsCollector =
        new MultiInfoItemsCollector(this.getServiceId());
      collectItemsFrom(collector, json, this.getBaseUrl(), this.sepia);

      return InfoItemsPage.fromCollector(collector, getNextPage(pageUrl as string, total));
    }
    throw new ExtractionException('Unable to get PeerTube search info');
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
  }
}
