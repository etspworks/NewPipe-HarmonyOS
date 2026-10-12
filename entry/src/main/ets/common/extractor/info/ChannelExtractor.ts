/*
 * Port of org.schabi.newpipe.extractor.channel.{ChannelExtractor, ChannelInfoItemExtractor,
 * ChannelInfoItemsCollector} (NewPipeExtractor v0.26.5).
 */

import { Extractor } from '../core/Extractor';
import { InfoItemExtractor, InfoItemsCollector } from '../core/Collector';
import { toError } from '../core/Errors';
import { StreamingService } from '../core/StreamingService';
import { ListLinkHandler } from '../linkhandler/LinkHandler';
import { ChannelInfoItem } from '../../../model/extractor/ChannelInfoItem';
import { Image } from '../../../model/extractor/Image';

export const UNKNOWN_SUBSCRIBER_COUNT: number = -1;

export abstract class ChannelExtractor extends Extractor {
  constructor(service: StreamingService, linkHandler: ListLinkHandler) {
    super(service, linkHandler);
  }

  abstract getAvatars(): Image[];

  abstract getBanners(): Image[];

  abstract getFeedUrl(): string | null;

  abstract getSubscriberCount(): number;

  abstract getDescription(): string;

  abstract getParentChannelName(): string;

  abstract getParentChannelUrl(): string;

  abstract getParentChannelAvatars(): Image[];

  abstract isVerified(): boolean;

  /** The tabs this channel offers, each one a ready ListLinkHandler. */
  abstract getTabs(): ListLinkHandler[];

  getTags(): string[] {
    return [];
  }
}

export abstract class ChannelInfoItemExtractor extends InfoItemExtractor {
  abstract getDescription(): string;

  abstract getSubscriberCount(): number;

  abstract getStreamCount(): number;

  abstract isVerified(): boolean;
}

export class ChannelInfoItemsCollector
  extends InfoItemsCollector<ChannelInfoItem, ChannelInfoItemExtractor> {
  constructor(serviceId: number) {
    super(serviceId);
  }

  extract(extractor: ChannelInfoItemExtractor): ChannelInfoItem {
    const resultItem: ChannelInfoItem =
      new ChannelInfoItem(this.getServiceId(), extractor.getUrl(), extractor.getName());

    // optional information
    try {
      resultItem.subscriberCount = extractor.getSubscriberCount();
    } catch (e) {
      this.addError(toError(e));
    }
    try {
      resultItem.streamCount = extractor.getStreamCount();
    } catch (e) {
      this.addError(toError(e));
    }
    try {
      resultItem.thumbnails = extractor.getThumbnails();
    } catch (e) {
      this.addError(toError(e));
    }
    try {
      resultItem.description = extractor.getDescription();
    } catch (e) {
      this.addError(toError(e));
    }
    try {
      resultItem.verified = extractor.isVerified();
    } catch (e) {
      this.addError(toError(e));
    }

    return resultItem;
  }
}
