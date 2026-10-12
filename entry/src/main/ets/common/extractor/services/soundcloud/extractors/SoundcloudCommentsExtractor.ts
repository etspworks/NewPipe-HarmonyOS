/*
 * Port of org.schabi.newpipe.extractor.services.soundcloud.extractors.SoundcloudCommentsExtractor
 * (NewPipeExtractor v0.26.5).
 */

import { CommentsInfoItem } from '../../../../../model/extractor/CommentsInfoItem';
import { InfoItemsPage } from '../../../../../model/extractor/ListExtractorInfoItemsPage';
import { Page } from '../../../../../model/extractor/Page';
import { CommentsExtractor, CommentsInfoItemsCollector } from '../../../info/CommentsExtractor';
import { NewPipe } from '../../../core/NewPipe';
import { StreamingService } from '../../../core/StreamingService';
import { isNullOrEmpty } from '../../../core/Utils';
import { Downloader, Response } from '../../../downloader/Downloader';
import { ExtractionException, ParsingException } from '../../../exceptions/Exceptions';
import { ListLinkHandler } from '../../../linkhandler/LinkHandler';
import { JsonArray, JsonObject, JsonParser } from '../../../json/NanoJson';
import { SoundcloudCommentsInfoItemExtractor } from './SoundcloudCommentsInfoItemExtractor';

export class SoundcloudCommentsExtractor extends CommentsExtractor {
  constructor(service: StreamingService, uiHandler: ListLinkHandler) {
    super(service, uiHandler);
  }

  async getInitialPage(): Promise<InfoItemsPage<CommentsInfoItem>> {
    return this.getPageFromUrl(this.getUrl());
  }

  async getPage(page: Page): Promise<InfoItemsPage<CommentsInfoItem>> {
    if (page === null || isNullOrEmpty(page.getUrl())) {
      return InfoItemsPage.emptyPage<CommentsInfoItem>();
    }
    return this.getPageFromUrl(page.getUrl() as string);
  }

  private async getPageFromUrl(url: string): Promise<InfoItemsPage<CommentsInfoItem>> {
    const downloader: Downloader | null = NewPipe.getDownloader();
    if (downloader === null) {
      throw new ExtractionException('NewPipe was not initialised with a Downloader');
    }
    const response: Response = await downloader.get(url);

    let json: JsonObject;
    try {
      json = JsonParser.object().from(response.responseBody());
    } catch (e) {
      throw new ParsingException('Could not parse json',
        e instanceof Error ? e as Error : null);
    }

    const collector: CommentsInfoItemsCollector =
      new CommentsInfoItemsCollector(this.getServiceId());

    this.collectStreamsFrom(collector, json.getArray('collection'));
    const nextHref: string | null = json.getString('next_href');
    return InfoItemsPage.fromCollector(collector,
      isNullOrEmpty(nextHref) ? null : new Page(nextHref));
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
  }

  private collectStreamsFrom(collector: CommentsInfoItemsCollector, entries: JsonArray): void {
    const url: string = this.getUrl();
    for (const comment of entries.streamAsJsonObjects()) {
      collector.commit(new SoundcloudCommentsInfoItemExtractor(comment, url));
    }
  }
}
