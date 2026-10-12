/*
 * Port of org.schabi.newpipe.extractor.channel.tabs.ChannelTabInfo (NewPipeExtractor v0.26.5).
 */

import { ExtractorHelper } from '../../common/extractor/core/ExtractorHelper';
import { InfoItem } from '../../common/extractor/core/InfoItem';
import { ListInfo } from '../../common/extractor/core/ListInfo';
import { toError } from '../../common/extractor/core/Errors';
import { StreamingService } from '../../common/extractor/core/StreamingService';
import { ChannelTabExtractor } from '../../common/extractor/info/ChannelTabExtractor';
import { ListLinkHandler } from '../../common/extractor/linkhandler/LinkHandler';
import { InfoItemsPage } from './ListExtractorInfoItemsPage';
import { Page } from './Page';

export class ChannelTabInfo extends ListInfo<InfoItem> {
  constructor(serviceId: number, linkHandler: ListLinkHandler) {
    super(serviceId, linkHandler.getId(), linkHandler.getUrl(), linkHandler.getOriginalUrl(),
      linkHandler.getContentFilters()[0], linkHandler.getContentFilters(),
      linkHandler.getSortFilter());
  }

  static async getInfoFromService(service: StreamingService,
    linkHandler: ListLinkHandler): Promise<ChannelTabInfo> {
    const extractor: ChannelTabExtractor = service.getChannelTabExtractor(linkHandler);
    await extractor.fetchPage();
    return ChannelTabInfo.getInfo(extractor);
  }

  static async getInfo(extractor: ChannelTabExtractor): Promise<ChannelTabInfo> {
    const info: ChannelTabInfo =
      new ChannelTabInfo(extractor.getServiceId(), extractor.getLinkHandler());

    try {
      info.setOriginalUrl(extractor.getOriginalUrl());
    } catch (e) {
      info.addError(toError(e));
    }

    const page: InfoItemsPage<InfoItem> =
      await ExtractorHelper.getItemsPageOrLogError(info, extractor);
    info.setRelatedItems(page.getItems());
    info.setNextPage(page.getNextPage());

    return info;
  }

  static async getMoreItems(service: StreamingService, linkHandler: ListLinkHandler,
    page: Page): Promise<InfoItemsPage<InfoItem>> {
    return service.getChannelTabExtractor(linkHandler).getPage(page);
  }
}
