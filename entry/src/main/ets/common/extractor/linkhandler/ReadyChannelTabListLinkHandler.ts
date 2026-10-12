/*
 * Port of org.schabi.newpipe.extractor.linkhandler.ReadyChannelTabListLinkHandler
 * (NewPipeExtractor v0.26.5).
 *
 * A channel tab whose extractor is already decided by the channel page that produced it, so the
 * tab does not have to be resolved from its url again.
 */

import { StreamingService } from '../core/StreamingService';
import { ChannelTabExtractor } from '../info/ChannelTabExtractor';
import { ListLinkHandler } from './LinkHandler';

export interface ChannelTabExtractorBuilder {
  build(service: StreamingService, linkHandler: ListLinkHandler): ChannelTabExtractor;
}

export class ReadyChannelTabListLinkHandler extends ListLinkHandler {
  private readonly extractorBuilder: ChannelTabExtractorBuilder;

  constructor(url: string, channelId: string, channelTab: string,
    extractorBuilder: ChannelTabExtractorBuilder) {
    super(url, url, channelId, [channelTab], '');
    this.extractorBuilder = extractorBuilder;
  }

  getChannelTabExtractor(service: StreamingService): ChannelTabExtractor {
    return this.extractorBuilder.build(service, ListLinkHandler.copyOf(this));
  }
}
