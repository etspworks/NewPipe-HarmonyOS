/*
 * Port of org.schabi.newpipe.extractor.services.peertube.linkHandler
 * .PeertubeChannelTabLinkHandlerFactory (NewPipeExtractor v0.26.5).
 */

import { ListLinkHandlerFactory } from '../../../linkhandler/LinkHandlerFactory';
import { ChannelTabs } from '../../../info/ChannelTabExtractor';
import { UnsupportedTabException } from '../../../exceptions/Exceptions';
import { PeertubeChannelLinkHandlerFactory } from './PeertubeChannelLinkHandlerFactory';

export function getUrlSuffix(tab: string): string {
  if (tab === ChannelTabs.VIDEOS) {
    return '/videos';
  }
  if (tab === ChannelTabs.CHANNELS) {
    // only available on accounts
    return '/video-channels';
  }
  if (tab === ChannelTabs.PLAYLISTS) {
    // only available on channels
    return '/video-playlists';
  }
  throw new UnsupportedTabException(tab);
}

export class PeertubeChannelTabLinkHandlerFactory extends ListLinkHandlerFactory {
  private static readonly INSTANCE: PeertubeChannelTabLinkHandlerFactory =
    new PeertubeChannelTabLinkHandlerFactory();

  private constructor() {
    super();
  }

  static getInstance(): PeertubeChannelTabLinkHandlerFactory {
    return PeertubeChannelTabLinkHandlerFactory.INSTANCE;
  }

  getId(channelTabUrl: string): string {
    return PeertubeChannelLinkHandlerFactory.getInstance().getId(channelTabUrl);
  }

  getUrlWithFilters(id: string, contentFilter: string[], sortFilter: string,
    baseUrl: string | null): string {
    return PeertubeChannelLinkHandlerFactory.getInstance().getUrl(id, baseUrl)
      + getUrlSuffix(contentFilter[0]);
  }

  onAcceptUrl(channelTabUrl: string): boolean {
    return PeertubeChannelLinkHandlerFactory.getInstance().onAcceptUrl(channelTabUrl);
  }

  getAvailableContentFilter(): string[] {
    return [ChannelTabs.VIDEOS, ChannelTabs.CHANNELS, ChannelTabs.PLAYLISTS];
  }
}
