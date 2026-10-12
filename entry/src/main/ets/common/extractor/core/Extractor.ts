/*
 * Port of org.schabi.newpipe.extractor.Extractor (NewPipeExtractor v0.26.5).
 *
 * The base of every extractor. fetchPage() is the one method that does I/O, so it is the only one
 * that becomes a Promise (phase2-logic-contract.md §1: one-shot loads are Promises); every getter
 * below it stays synchronous, exactly as in the source.
 */

import { Downloader } from '../downloader/Downloader';
import { Localization } from '../downloader/Localization';
import { ContentCountry } from '../localization/ContentCountry';
import { TimeAgoParser } from '../localization/TimeAgoParser';
import { LinkHandler } from '../linkhandler/LinkHandler';
import { ExtractorLogger } from './ExtractorLogger';
import { NewPipe } from './NewPipe';
import { StreamingService } from './StreamingService';

/** Stands in for Java's identity hash in the per-instance log tag. */
let instanceCounter: number = 0;

export abstract class Extractor {
  private readonly tag: string;

  /**
   * The StreamingService currently related to this extractor. Useful for getting other things
   * from a service (like the url handlers for cleaning/accepting/get id from urls).
   */
  private readonly service: StreamingService;
  private readonly linkHandler: LinkHandler;

  private forcedLocalization: Localization | null = null;
  private forcedContentCountry: ContentCountry | null = null;

  private pageFetched: boolean = false;
  private readonly downloader: Downloader;

  constructor(service: StreamingService, linkHandler: LinkHandler) {
    this.service = service;
    this.linkHandler = linkHandler;
    const downloader: Downloader | null = NewPipe.getDownloader();
    if (downloader === null) {
      throw new Error('downloader is null');
    }
    this.downloader = downloader;
    instanceCounter++;
    this.tag = `${this.constructor.name}@${instanceCounter}`;
  }

  /** The LinkHandler of this extractor (a ChannelExtractor returns a channel url handler). */
  getLinkHandler(): LinkHandler {
    return this.linkHandler;
  }

  /** Fetch the current page. */
  async fetchPage(): Promise<void> {
    ExtractorLogger.d(this.tag, 'base fetchPage called');
    if (this.pageFetched) {
      ExtractorLogger.d(this.tag, 'Page already fetched; returning');
      return;
    }
    await this.onFetchPage(this.downloader);
    this.pageFetched = true;
  }

  protected assertPageFetched(): void {
    if (!this.pageFetched) {
      throw new Error('Page is not fetched. Make sure you call fetchPage()');
    }
  }

  protected isPageFetched(): boolean {
    return this.pageFetched;
  }

  /** Fetch the current page with the given downloader. */
  abstract onFetchPage(downloader: Downloader): Promise<void>;

  getId(): string {
    return this.linkHandler.getId();
  }

  abstract getName(): string;

  getOriginalUrl(): string {
    return this.linkHandler.getOriginalUrl();
  }

  getUrl(): string {
    return this.linkHandler.getUrl();
  }

  getBaseUrl(): string {
    return this.linkHandler.getBaseUrl();
  }

  getService(): StreamingService {
    return this.service;
  }

  getServiceId(): number {
    return this.service.getServiceId();
  }

  getDownloader(): Downloader {
    return this.downloader;
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Localization
  ////////////////////////////////////////////////////////////////////////// */

  forceLocalization(localization: Localization | null): void {
    this.forcedLocalization = localization;
  }

  forceContentCountry(contentCountry: ContentCountry | null): void {
    this.forcedContentCountry = contentCountry;
  }

  getExtractorLocalization(): Localization {
    return this.forcedLocalization === null
      ? this.getService().getLocalization() : this.forcedLocalization;
  }

  getExtractorContentCountry(): ContentCountry {
    return this.forcedContentCountry === null
      ? this.getService().getContentCountry() : this.forcedContentCountry;
  }

  getTimeAgoParser(): TimeAgoParser {
    return this.getService().getTimeAgoParser(this.getExtractorLocalization());
  }

  toString(): string {
    return this.constructor.name;
  }
}
