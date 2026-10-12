/*
 * Port of org.schabi.newpipe.extractor.ListExtractor (NewPipeExtractor v0.26.5).
 *
 * Base of the extractors that produce a list (playlists, channels, search, kiosks). Both page
 * getters do I/O, so both are Promises (phase2-logic-contract.md §1).
 */

import { InfoItemsPage } from '../../../model/extractor/ListExtractorInfoItemsPage';
import { Page } from '../../../model/extractor/Page';
import { ListLinkHandler } from '../linkhandler/LinkHandler';
import { Extractor } from './Extractor';
import { InfoItem } from './InfoItem';
import { StreamingService } from './StreamingService';

/** A list has an unknown number of items. */
export const ITEM_COUNT_UNKNOWN: number = -1;
/** A list has an infinite number of items, for example a YouTube mix. */
export const ITEM_COUNT_INFINITE: number = -2;
/** A list has an unknown number of items bigger than 100. */
export const ITEM_COUNT_MORE_THAN_100: number = -3;

export abstract class ListExtractor<R extends InfoItem> extends Extractor {
  constructor(service: StreamingService, linkHandler: ListLinkHandler) {
    super(service, linkHandler);
  }

  /** The initial page: the items of the first request plus the nextPage relative to it. */
  abstract getInitialPage(): Promise<InfoItemsPage<R>>;

  /** The items of one specific page, got from a previous InfoItemsPage.getNextPage(). */
  abstract getPage(page: Page): Promise<InfoItemsPage<R>>;

  getLinkHandler(): ListLinkHandler {
    return super.getLinkHandler() as ListLinkHandler;
  }
}
