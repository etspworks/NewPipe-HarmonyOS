/*
 * Port of org.schabi.newpipe.extractor.feed.FeedInfo (NewPipeExtractor v0.26.5).
 *
 * Lives beside FeedExtractor rather than in model/extractor/: the plan's models[] has no entry
 * for it, and it is the feed extractor's own result type.
 */

import { ExtractorHelper } from '../core/ExtractorHelper';
import { ListInfo } from '../core/ListInfo';
import { NewPipe } from '../core/NewPipe';
import { StreamingService } from '../core/StreamingService';
import { InfoItemsPage } from '../../../model/extractor/ListExtractorInfoItemsPage';
import { StreamInfoItem } from '../../../model/extractor/StreamInfoItem';
import { FeedExtractor } from './FeedExtractor';

export class FeedInfo extends ListInfo<StreamInfoItem> {
  constructor(serviceId: number, id: string, url: string, originalUrl: string, name: string,
    contentFilter: string[], sortFilter: string) {
    super(serviceId, id, url, originalUrl, name, contentFilter, sortFilter);
  }

  static async getInfoFromUrl(url: string): Promise<FeedInfo> {
    return FeedInfo.getInfoFromService(NewPipe.getServiceByUrl(url), url);
  }

  static async getInfoFromService(service: StreamingService, url: string): Promise<FeedInfo> {
    const extractor: FeedExtractor | null = service.getFeedExtractor(url);
    if (extractor === null) {
      throw new Error('Service "' + service.getServiceInfo().getName()
        + '" doesn\'t support FeedExtractor.');
    }
    await extractor.fetchPage();
    return FeedInfo.getInfo(extractor);
  }

  static async getInfo(extractor: FeedExtractor): Promise<FeedInfo> {
    await extractor.fetchPage();
    const info: FeedInfo = new FeedInfo(extractor.getServiceId(), extractor.getId(),
      extractor.getUrl(), extractor.getOriginalUrl(), extractor.getName(), [], '');

    const itemsPage: InfoItemsPage<StreamInfoItem> =
      await ExtractorHelper.getItemsPageOrLogError(info, extractor);
    info.setRelatedItems(itemsPage.getItems());
    info.setNextPage(itemsPage.getNextPage());

    return info;
  }
}
