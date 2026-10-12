/*
 * Port of org.schabi.newpipe.extractor.services.peertube.extractors.PeertubeChannelTabExtractor
 * (NewPipeExtractor v0.26.5).
 */

import { ChannelTabExtractor } from '../../../info/ChannelTabExtractor';
import { StreamingService } from '../../../core/StreamingService';
import { ListLinkHandler } from '../../../linkhandler/LinkHandler';
import { Downloader, Response } from '../../../downloader/Downloader';
import { JsonObject, JsonParser } from '../../../json/NanoJson';
import { isBlank, isNullOrEmpty } from '../../../core/Utils';
import { toError } from '../../../core/Errors';
import { ExtractionException, ParsingException } from '../../../exceptions/Exceptions';
import { InfoItem } from '../../../core/InfoItem';
import { InfoItemsPage } from '../../../../../model/extractor/ListExtractorInfoItemsPage';
import { Page } from '../../../../../model/extractor/Page';
import { COUNT_KEY, getNextPage, ITEMS_PER_PAGE, START_KEY, validate } from '../PeertubeParsingHelper';
import { collectItemsFrom } from '../PeertubeItemCollector';
import { MultiInfoItemsCollector } from '../../../core/MultiInfoItemsCollector';
import { API_ENDPOINT } from '../linkHandler/PeertubeChannelLinkHandlerFactory';
import { getUrlSuffix } from '../linkHandler/PeertubeChannelTabLinkHandlerFactory';

export class PeertubeChannelTabExtractor extends ChannelTabExtractor {
  private readonly baseUrl: string;

  constructor(service: StreamingService, linkHandler: ListLinkHandler) {
    super(service, linkHandler);
    this.baseUrl = this.getBaseUrl();
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
  }

  async getInitialPage(): Promise<InfoItemsPage<InfoItem>> {
    return this.getPage(new Page(this.baseUrl + API_ENDPOINT + this.getId()
      + getUrlSuffix(this.getName()) + '?' + START_KEY + '=0&' + COUNT_KEY + '='
      + ITEMS_PER_PAGE));
  }

  async getPage(page: Page): Promise<InfoItemsPage<InfoItem>> {
    const pageUrl: string | null = page === null ? null : page.getUrl();
    if (isNullOrEmpty(pageUrl)) {
      throw new Error("Page doesn't contain an URL");
    }

    const response: Response = await this.getDownloader().get(pageUrl as string);

    let pageJson: JsonObject | null = null;
    if (!isBlank(response.responseBody())) {
      try {
        pageJson = JsonParser.object().from(response.responseBody());
      } catch (e) {
        throw new ParsingException('Could not parse json data for account info', toError(e));
      }
    }

    if (pageJson === null) {
      throw new ExtractionException('Unable to get account channel list');
    }
    validate(pageJson);

    const collector: MultiInfoItemsCollector = new MultiInfoItemsCollector(this.getServiceId());
    collectItemsFrom(collector, pageJson, this.getBaseUrl());

    return InfoItemsPage.fromCollector(collector,
      getNextPage(pageUrl as string, pageJson.getLong('total')));
  }
}
