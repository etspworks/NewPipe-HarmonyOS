/*
 * Port of org.schabi.newpipe.extractor.services.peertube.extractors.PeertubeTrendingExtractor
 * (NewPipeExtractor v0.26.5).
 */

import { KioskExtractor } from '../../../info/KioskList';
import { StreamingService } from '../../../core/StreamingService';
import { ListLinkHandler } from '../../../linkhandler/LinkHandler';
import { Downloader, Response } from '../../../downloader/Downloader';
import { JsonObject, JsonParser } from '../../../json/NanoJson';
import { isBlank, isNullOrEmpty } from '../../../core/Utils';
import { toError } from '../../../core/Errors';
import { ExtractionException, ParsingException } from '../../../exceptions/Exceptions';
import { StreamInfoItemsCollector } from '../../../info/StreamInfoItemsCollector';
import { StreamInfoItem } from '../../../../../model/extractor/StreamInfoItem';
import { InfoItemsPage } from '../../../../../model/extractor/ListExtractorInfoItemsPage';
import { Page } from '../../../../../model/extractor/Page';
import { COUNT_KEY, getNextPage, ITEMS_PER_PAGE, START_KEY, validate } from '../PeertubeParsingHelper';
import { collectStreamItemsFrom } from '../PeertubeItemCollector';

export class PeertubeTrendingExtractor extends KioskExtractor<StreamInfoItem> {
  constructor(streamingService: StreamingService, linkHandler: ListLinkHandler, kioskId: string) {
    super(streamingService, linkHandler, kioskId);
  }

  getName(): string {
    return this.getId();
  }

  async getInitialPage(): Promise<InfoItemsPage<StreamInfoItem>> {
    return this.getPage(new Page(this.getUrl() + '&' + START_KEY + '=0&'
      + COUNT_KEY + '=' + ITEMS_PER_PAGE));
  }

  async getPage(page: Page): Promise<InfoItemsPage<StreamInfoItem>> {
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
        throw new ParsingException('Could not parse json data for kiosk info', toError(e));
      }
    }

    if (json !== null) {
      validate(json);
      const total: number = json.getLong('total');

      const collector: StreamInfoItemsCollector =
        new StreamInfoItemsCollector(this.getServiceId());
      collectStreamItemsFrom(collector, json, this.getBaseUrl());

      return InfoItemsPage.fromCollector(collector, getNextPage(pageUrl as string, total));
    }
    throw new ExtractionException('Unable to get PeerTube kiosk info');
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
  }
}
