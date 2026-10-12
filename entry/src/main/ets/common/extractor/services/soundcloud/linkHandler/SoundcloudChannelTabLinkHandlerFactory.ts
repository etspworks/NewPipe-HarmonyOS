/*
 * Port of org.schabi.newpipe.extractor.services.soundcloud.linkHandler
 * .SoundcloudChannelTabLinkHandlerFactory (NewPipeExtractor v0.26.5).
 */

import { ListLinkHandlerFactory } from '../../../linkhandler/LinkHandlerFactory';
import { ListLinkHandler } from '../../../linkhandler/LinkHandler';
import { ChannelTabs } from '../../../info/ChannelTabExtractor';
import { UnsupportedTabException } from '../../../exceptions/Exceptions';
import { SoundcloudChannelLinkHandlerFactory } from './SoundcloudChannelLinkHandlerFactory';

export class SoundcloudChannelTabLinkHandlerFactory extends ListLinkHandlerFactory {
  private static readonly INSTANCE: SoundcloudChannelTabLinkHandlerFactory =
    new SoundcloudChannelTabLinkHandlerFactory();

  static getInstance(): SoundcloudChannelTabLinkHandlerFactory {
    return SoundcloudChannelTabLinkHandlerFactory.INSTANCE;
  }

  static getUrlSuffix(tab: string): string {
    if (tab === ChannelTabs.TRACKS) {
      return '/tracks';
    }
    if (tab === ChannelTabs.PLAYLISTS) {
      return '/sets';
    }
    if (tab === ChannelTabs.ALBUMS) {
      return '/albums';
    }
    if (tab === ChannelTabs.LIKES) {
      return '/likes';
    }
    throw new UnsupportedTabException(tab);
  }

  getId(url: string): string {
    return SoundcloudChannelLinkHandlerFactory.getInstance().getId(url);
  }

  getUrlWithFilters(id: string, contentFilter: string[], sortFilter: string,
    baseUrl: string | null = null): string {
    return SoundcloudChannelLinkHandlerFactory.getInstance().getUrl(id, baseUrl)
      + SoundcloudChannelTabLinkHandlerFactory.getUrlSuffix(contentFilter[0]);
  }

  onAcceptUrl(url: string): boolean {
    return SoundcloudChannelLinkHandlerFactory.getInstance().onAcceptUrl(url);
  }

  getAvailableContentFilter(): string[] {
    return [
      ChannelTabs.TRACKS,
      ChannelTabs.PLAYLISTS,
      ChannelTabs.ALBUMS,
      ChannelTabs.LIKES
    ];
  }

  /** Resolves the channel id/url first, then builds the tab handler. */
  async fromQueryAsync(id: string, contentFilters: string[], sortFilter: string,
    baseUrl: string | null = null): Promise<ListLinkHandler> {
    await SoundcloudChannelLinkHandlerFactory.resolveUrl(id);
    return this.fromQuery(id, contentFilters, sortFilter, baseUrl);
  }
}
