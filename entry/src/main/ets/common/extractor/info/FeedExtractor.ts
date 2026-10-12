/*
 * Port of org.schabi.newpipe.extractor.feed.FeedExtractor (NewPipeExtractor v0.26.5).
 *
 * A lighter, feed-shaped way of listing a channel's streams where the service offers one
 * (YouTube's channel RSS).
 */

import { ListExtractor } from '../core/ListExtractor';
import { StreamingService } from '../core/StreamingService';
import { ListLinkHandler } from '../linkhandler/LinkHandler';
import { StreamInfoItem } from '../../../model/extractor/StreamInfoItem';

export abstract class FeedExtractor extends ListExtractor<StreamInfoItem> {
  constructor(service: StreamingService, listLinkHandler: ListLinkHandler) {
    super(service, listLinkHandler);
  }
}
