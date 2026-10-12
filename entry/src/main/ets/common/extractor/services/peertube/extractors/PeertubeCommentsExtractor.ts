/*
 * Port of org.schabi.newpipe.extractor.services.peertube.extractors.PeertubeCommentsExtractor
 * (NewPipeExtractor v0.26.5).
 *
 * `CHILDREN` is imported from PeertubeCommentsInfoItemExtractor rather than declared here (the
 * source has it the other way round) so the two modules do not form an ES-module cycle.
 */

import { util } from '@kit.ArkTS';
import { CommentsExtractor, CommentsInfoItemsCollector } from '../../../info/CommentsExtractor';
import { StreamingService } from '../../../core/StreamingService';
import { ListLinkHandler } from '../../../linkhandler/LinkHandler';
import { Downloader, Response } from '../../../downloader/Downloader';
import { JsonArray, JsonObject, JsonParser } from '../../../json/NanoJson';
import { isBlank, isNullOrEmpty } from '../../../core/Utils';
import { toError } from '../../../core/Errors';
import { ExtractionException, ParsingException } from '../../../exceptions/Exceptions';
import { CommentsInfoItem } from '../../../../../model/extractor/CommentsInfoItem';
import { InfoItemsPage } from '../../../../../model/extractor/ListExtractorInfoItemsPage';
import { Page } from '../../../../../model/extractor/Page';
import { COUNT_KEY, getNextPage, ITEMS_PER_PAGE, START_KEY, validate } from '../PeertubeParsingHelper';
import {
  CHILDREN,
  PeertubeCommentsInfoItemExtractor
} from './PeertubeCommentsInfoItemExtractor';

const IS_DELETED: string = 'isDeleted';
const TOTAL: string = 'total';

export class PeertubeCommentsExtractor extends CommentsExtractor {
  /** Use isReply() to access this variable. */
  private isReplyValue: boolean | null = null;

  constructor(service: StreamingService, uiHandler: ListLinkHandler) {
    super(service, uiHandler);
  }

  async getInitialPage(): Promise<InfoItemsPage<CommentsInfoItem>> {
    if (this.isReply()) {
      return this.getPage(new Page(this.getOriginalUrl()));
    }
    return this.getPage(new Page(this.getUrl() + '?' + START_KEY + '=0&'
      + COUNT_KEY + '=' + ITEMS_PER_PAGE));
  }

  private isReply(): boolean {
    if (this.isReplyValue === null) {
      if (this.getOriginalUrl().includes('/videos/watch/')) {
        this.isReplyValue = false;
      } else {
        this.isReplyValue = this.getOriginalUrl().includes('/comment-threads/');
      }
    }
    return this.isReplyValue;
  }

  private collectCommentsFrom(collector: CommentsInfoItemsCollector, json: JsonObject): void {
    const contents: JsonArray = json.getArray('data');

    for (const item of contents.streamAsJsonObjects()) {
      if (!item.getBoolean(IS_DELETED)) {
        collector.commit(new PeertubeCommentsInfoItemExtractor(
          item, null, this.getUrl(), this.getBaseUrl(), this.isReply()));
      }
    }
  }

  private collectRepliesFrom(collector: CommentsInfoItemsCollector, json: JsonObject): void {
    const contents: JsonArray = json.getArray(CHILDREN);

    for (const content of contents.streamAsJsonObjects()) {
      const item: JsonObject = content.getObject('comment');
      const children: JsonArray = content.getArray(CHILDREN);
      if (!item.getBoolean(IS_DELETED)) {
        collector.commit(new PeertubeCommentsInfoItemExtractor(
          item, children, this.getUrl(), this.getBaseUrl(), this.isReply()));
      }
    }
  }

  async getPage(page: Page): Promise<InfoItemsPage<CommentsInfoItem>> {
    const pageUrl: string | null = page === null ? null : page.getUrl();
    if (isNullOrEmpty(pageUrl)) {
      throw new Error("Page doesn't contain an URL");
    }

    let json: JsonObject | null = null;
    const collector: CommentsInfoItemsCollector =
      new CommentsInfoItemsCollector(this.getServiceId());
    let total: number;
    const body: ArrayBuffer | null = page.getBody();

    if (body === null) {
      const response: Response = await this.getDownloader().get(pageUrl as string);
      if (!isBlank(response.responseBody())) {
        try {
          json = JsonParser.object().from(response.responseBody());
        } catch (e) {
          throw new ParsingException('Could not parse json data for comments info', toError(e));
        }
      }
      if (json !== null) {
        validate(json);
        if (this.isReply() || json.has(CHILDREN)) {
          total = json.getArray(CHILDREN).size();
          this.collectRepliesFrom(collector, json);
        } else {
          total = json.getLong(TOTAL);
          this.collectCommentsFrom(collector, json);
        }
      } else {
        throw new ExtractionException('Unable to get PeerTube kiosk info');
      }
    } else {
      try {
        json = JsonParser.object().from(
          util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(body)));
        this.isReplyValue = true;
        total = json.getArray(CHILDREN).size();
        this.collectRepliesFrom(collector, json);
      } catch (e) {
        throw new ParsingException('Could not parse json data for nested comments  info',
          toError(e));
      }
    }

    return InfoItemsPage.fromCollector(collector, getNextPage(pageUrl as string, total));
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
  }
}
