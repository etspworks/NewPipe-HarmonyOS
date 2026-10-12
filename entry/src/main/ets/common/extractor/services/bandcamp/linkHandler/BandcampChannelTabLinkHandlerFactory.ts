/*
 * Port of org.schabi.newpipe.extractor.services.bandcamp.linkHandler
 * .BandcampChannelTabLinkHandlerFactory (NewPipeExtractor v0.26.5).
 */

import { ListLinkHandlerFactory } from '../../../linkhandler/LinkHandlerFactory';
import { ListLinkHandler } from '../../../linkhandler/LinkHandler';
import { ChannelTabs } from '../../../info/ChannelTabExtractor';
import { UnsupportedTabException } from '../../../exceptions/Exceptions';
import { BandcampChannelLinkHandlerFactory } from './BandcampChannelLinkHandlerFactory';

export class BandcampChannelTabLinkHandlerFactory extends ListLinkHandlerFactory {
  private static readonly INSTANCE: BandcampChannelTabLinkHandlerFactory =
    new BandcampChannelTabLinkHandlerFactory();

  static getInstance(): BandcampChannelTabLinkHandlerFactory {
    return BandcampChannelTabLinkHandlerFactory.INSTANCE;
  }

  /**
   * A tab's URL suffix. These URLs don't actually exist on the Bandcamp website, as both albums
   * and tracks are listed on the main page, but they redirect to it - which is perfect for us as
   * we need a unique URL for each tab.
   */
  static getUrlSuffix(tab: string): string {
    if (tab === ChannelTabs.TRACKS) {
      return '/track';
    }
    if (tab === ChannelTabs.ALBUMS) {
      return '/album';
    }
    throw new UnsupportedTabException(tab);
  }

  getId(url: string): string {
    return BandcampChannelLinkHandlerFactory.getInstance().getId(url);
  }

  getUrlWithFilters(id: string, contentFilter: string[], sortFilter: string,
    baseUrl: string | null = null): string {
    return BandcampChannelLinkHandlerFactory.getInstance().getUrl(id, baseUrl)
      + BandcampChannelTabLinkHandlerFactory.getUrlSuffix(contentFilter[0]);
  }

  onAcceptUrl(url: string): boolean {
    return BandcampChannelLinkHandlerFactory.getInstance().onAcceptUrl(url);
  }

  getAvailableContentFilter(): string[] {
    return [ChannelTabs.TRACKS, ChannelTabs.ALBUMS];
  }

  /** Primes the channel id -> url translation, then builds the tab handler. */
  async fromQueryAsync(id: string, contentFilters: string[], sortFilter: string,
    baseUrl: string | null = null): Promise<ListLinkHandler> {
    await BandcampChannelLinkHandlerFactory.resolveUrl(id);
    return this.fromQuery(id, contentFilters, sortFilter, baseUrl);
  }
}
