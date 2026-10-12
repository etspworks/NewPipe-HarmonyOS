/*
 * Port of org.schabi.newpipe.extractor.kiosk.KioskInfo (NewPipeExtractor v0.26.5).
 *
 * A kiosk is a service's own ready-made list (Trending, Charts); its items are stream rows.
 */

import { ExtractorHelper } from '../../common/extractor/core/ExtractorHelper';
import { ListInfo } from '../../common/extractor/core/ListInfo';
import { NewPipe } from '../../common/extractor/core/NewPipe';
import { StreamingService } from '../../common/extractor/core/StreamingService';
import { KioskExtractor } from '../../common/extractor/info/KioskList';
import { ListLinkHandler } from '../../common/extractor/linkhandler/LinkHandler';
import { InfoItemsPage } from './ListExtractorInfoItemsPage';
import { Page } from './Page';
import { StreamInfoItem } from './StreamInfoItem';

export class KioskInfo extends ListInfo<StreamInfoItem> {
  constructor(serviceId: number, id: string, url: string, originalUrl: string, name: string,
    contentFilter: string[], sortFilter: string) {
    super(serviceId, id, url, originalUrl, name, contentFilter, sortFilter);
  }

  static async getMoreItems(service: StreamingService, url: string,
    page: Page): Promise<InfoItemsPage<StreamInfoItem>> {
    const extractor: KioskExtractor<StreamInfoItem> =
      await service.getKioskList().getExtractorByUrl(url, page) as KioskExtractor<StreamInfoItem>;
    return extractor.getPage(page);
  }

  static async getInfoFromUrl(url: string): Promise<KioskInfo> {
    return KioskInfo.getInfoFromService(NewPipe.getServiceByUrl(url), url);
  }

  static async getInfoFromService(service: StreamingService, url: string): Promise<KioskInfo> {
    const extractor: KioskExtractor<StreamInfoItem> =
      await service.getKioskList().getExtractorByUrl(url, null) as KioskExtractor<StreamInfoItem>;
    await extractor.fetchPage();
    return KioskInfo.getInfo(extractor);
  }

  static async getInfo(extractor: KioskExtractor<StreamInfoItem>): Promise<KioskInfo> {
    const linkHandler: ListLinkHandler = extractor.getLinkHandler();
    const info: KioskInfo = new KioskInfo(extractor.getServiceId(), extractor.getId(),
      linkHandler.getUrl(), linkHandler.getOriginalUrl(), extractor.getName(),
      linkHandler.getContentFilters(), linkHandler.getSortFilter());

    const itemsPage: InfoItemsPage<StreamInfoItem> =
      await ExtractorHelper.getItemsPageOrLogError(info, extractor);
    info.setRelatedItems(itemsPage.getItems());
    info.setNextPage(itemsPage.getNextPage());

    return info;
  }
}
