/*
 * Port of org.schabi.newpipe.extractor.comments.CommentsInfo (NewPipeExtractor v0.26.5).
 */

import { ExtractorHelper } from '../../common/extractor/core/ExtractorHelper';
import { ListInfo } from '../../common/extractor/core/ListInfo';
import { toError } from '../../common/extractor/core/Errors';
import { NewPipe } from '../../common/extractor/core/NewPipe';
import { StreamingService } from '../../common/extractor/core/StreamingService';
import { CommentsExtractor } from '../../common/extractor/info/CommentsExtractor';
import { ListLinkHandler } from '../../common/extractor/linkhandler/LinkHandler';
import { CommentsInfoItem } from './CommentsInfoItem';
import { InfoItemsPage } from './ListExtractorInfoItemsPage';
import { Page } from './Page';

export class CommentsInfo extends ListInfo<CommentsInfoItem> {
  /** Kept alive so getMoreItems can page through the same extractor, as in the source. */
  commentsExtractor: CommentsExtractor | null = null;
  commentsDisabled: boolean = false;
  commentsCount: number = 0;

  constructor(serviceId: number, id: string, url: string, originalUrl: string, name: string,
    contentFilter: string[], sortFilter: string) {
    super(serviceId, id, url, originalUrl, name, contentFilter, sortFilter);
  }

  static async getInfoFromUrl(url: string): Promise<CommentsInfo | null> {
    return CommentsInfo.getInfoFromService(NewPipe.getServiceByUrl(url), url);
  }

  static async getInfoFromService(service: StreamingService,
    url: string): Promise<CommentsInfo | null> {
    return CommentsInfo.getInfo(service.getCommentsExtractorFromUrl(url));
  }

  static async getInfo(commentsExtractor: CommentsExtractor | null): Promise<CommentsInfo | null> {
    // for services which do not have a comments extractor
    if (commentsExtractor === null) {
      return null;
    }

    await commentsExtractor.fetchPage();

    const linkHandler: ListLinkHandler = commentsExtractor.getLinkHandler();
    const commentsInfo: CommentsInfo = new CommentsInfo(commentsExtractor.getServiceId(),
      linkHandler.getId(), linkHandler.getUrl(), linkHandler.getOriginalUrl(),
      commentsExtractor.getName(), linkHandler.getContentFilters(), linkHandler.getSortFilter());
    commentsInfo.commentsExtractor = commentsExtractor;

    const initialCommentsPage: InfoItemsPage<CommentsInfoItem> =
      await ExtractorHelper.getItemsPageOrLogError(commentsInfo, commentsExtractor);
    commentsInfo.commentsDisabled = commentsExtractor.isCommentsDisabled();
    commentsInfo.setRelatedItems(initialCommentsPage.getItems());

    try {
      commentsInfo.commentsCount = commentsExtractor.getCommentsCount();
    } catch (e) {
      commentsInfo.addError(toError(e));
    }
    commentsInfo.setNextPage(initialCommentsPage.getNextPage());

    return commentsInfo;
  }

  static async getMoreItems(service: StreamingService, url: string,
    page: Page): Promise<InfoItemsPage<CommentsInfoItem>> {
    const extractor: CommentsExtractor | null = service.getCommentsExtractorFromUrl(url);
    if (extractor === null) {
      return InfoItemsPage.emptyPage<CommentsInfoItem>();
    }
    return extractor.getPage(page);
  }

  static async getMoreItemsForInfo(commentsInfo: CommentsInfo,
    page: Page): Promise<InfoItemsPage<CommentsInfoItem>> {
    return CommentsInfo.getMoreItems(NewPipe.getService(commentsInfo.getServiceId()),
      commentsInfo.getUrl(), page);
  }

  getCommentsExtractor(): CommentsExtractor | null {
    return this.commentsExtractor;
  }

  getIsCommentsDisabled(): boolean {
    return this.commentsDisabled;
  }

  setCommentsDisabled(commentsDisabled: boolean): void {
    this.commentsDisabled = commentsDisabled;
  }

  getCommentsCount(): number {
    return this.commentsCount;
  }

  setCommentsCount(commentsCount: number): void {
    this.commentsCount = commentsCount;
  }
}
