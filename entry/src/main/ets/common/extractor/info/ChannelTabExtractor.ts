/*
 * Port of org.schabi.newpipe.extractor.channel.tabs.{ChannelTabExtractor, ChannelTabs}
 * (NewPipeExtractor v0.26.5).
 */

import { InfoItem } from '../core/InfoItem';
import { ListExtractor } from '../core/ListExtractor';
import { StreamingService } from '../core/StreamingService';
import { ListLinkHandler } from '../linkhandler/LinkHandler';

/** The tab ids a channel can offer; the content filter of a channel-tab link handler. */
export class ChannelTabs {
  static readonly VIDEOS: string = 'videos';
  static readonly TRACKS: string = 'tracks';
  static readonly SHORTS: string = 'shorts';
  static readonly LIVESTREAMS: string = 'livestreams';
  static readonly CHANNELS: string = 'channels';
  static readonly PLAYLISTS: string = 'playlists';
  static readonly ALBUMS: string = 'albums';
  static readonly LIKES: string = 'likes';
}

export abstract class ChannelTabExtractor extends ListExtractor<InfoItem> {
  constructor(service: StreamingService, linkHandler: ListLinkHandler) {
    super(service, linkHandler);
  }

  getName(): string {
    return this.getLinkHandler().getContentFilters()[0];
  }
}
