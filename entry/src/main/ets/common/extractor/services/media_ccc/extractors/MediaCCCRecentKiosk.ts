/*
 * Port of org.schabi.newpipe.extractor.services.media_ccc.extractors.MediaCCCRecentKiosk
 * (NewPipeExtractor v0.26.5).
 */

import { KioskExtractor } from '../../../info/KioskList';
import { StreamingService } from '../../../core/StreamingService';
import { ListLinkHandler } from '../../../linkhandler/LinkHandler';
import { StreamInfoItemsCollector } from '../../../info/StreamInfoItemsCollector';
import { Downloader } from '../../../downloader/Downloader';
import { JsonArray, JsonObject, JsonParser } from '../../../json/NanoJson';
import { toError } from '../../../core/Errors';
import { ExtractionException } from '../../../exceptions/Exceptions';
import { InfoItemsPage } from '../../../../../model/extractor/ListExtractorInfoItemsPage';
import { Page } from '../../../../../model/extractor/Page';
import { StreamInfoItem } from '../../../../../model/extractor/StreamInfoItem';
import { MediaCCCRecentKioskExtractor } from './MediaCCCRecentKioskExtractor';

export const KIOSK_ID: string = 'recent';

/**
 * Port of `Comparator.comparing(StreamInfoItem::getUploadDate,
 * Comparator.nullsLast(Comparator.comparing(DateWrapper::getInstant))).reversed()`.
 *
 * `reversed()` flips nullsLast into nulls-FIRST — that is what the source does, so it is what
 * this does. Wave B flattened DateWrapper into an epoch-millisecond number (§9), so the inner
 * comparison is numeric.
 */
function byNewestUploadDateFirst(a: StreamInfoItem, b: StreamInfoItem): number {
  const ua: number | null = a.getUploadDate();
  const ub: number | null = b.getUploadDate();
  let base: number;
  if (ua === null && ub === null) {
    base = 0;
  } else if (ua === null) {
    base = 1;
  } else if (ub === null) {
    base = -1;
  } else {
    base = ua < ub ? -1 : (ua > ub ? 1 : 0);
  }
  return -base;
}

export class MediaCCCRecentKiosk extends KioskExtractor<StreamInfoItem> {
  private doc: JsonObject = new JsonObject();

  constructor(streamingService: StreamingService, linkHandler: ListLinkHandler,
    kioskId: string) {
    super(streamingService, linkHandler, kioskId);
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
    const site: string = (await downloader.get('https://api.media.ccc.de/public/events/recent',
      null, this.getExtractorLocalization())).responseBody();
    try {
      this.doc = JsonParser.object().from(site);
    } catch (e) {
      throw new ExtractionException('Could not parse json.', toError(e));
    }
  }

  async getInitialPage(): Promise<InfoItemsPage<StreamInfoItem>> {
    const events: JsonArray = this.doc.getArray('events');

    // Streams in the recent kiosk are not ordered by the release date.
    // Sort them to have the latest stream at the beginning of the list.
    const collector: StreamInfoItemsCollector =
      new StreamInfoItemsCollector(this.getServiceId(), byNewestUploadDateFirst);

    for (const event of events.streamAsJsonObjects()) {
      const extractor: MediaCCCRecentKioskExtractor = new MediaCCCRecentKioskExtractor(event);
      // #813 / voc/voctoweb#609 -> returns faulty data -> filter it out
      if (extractor.getDuration() > 0) {
        collector.commit(extractor);
      }
    }

    return InfoItemsPage.fromCollector(collector, null);
  }

  async getPage(page: Page): Promise<InfoItemsPage<StreamInfoItem>> {
    return InfoItemsPage.emptyPage();
  }

  getName(): string {
    return KIOSK_ID;
  }
}
