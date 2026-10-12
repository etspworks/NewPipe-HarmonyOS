/*
 * Port of org.schabi.newpipe.extractor.services.soundcloud.linkHandler
 * .SoundcloudCommentsLinkHandlerFactory (NewPipeExtractor v0.26.5).
 *
 * getUrl() needs the bootstrapped client_id, which is an async scrape the first time round, so
 * the url building is split into a synchronous override (serving the memoized client_id) and
 * getUrlAsync() / fromIdAsListAsync() which bootstrap it first.
 */

import { ListLinkHandlerFactory } from '../../../linkhandler/LinkHandlerFactory';
import { ListLinkHandler } from '../../../linkhandler/LinkHandler';
import { ParsingException } from '../../../exceptions/Exceptions';
import { SoundcloudParsingHelper } from '../SoundcloudParsingHelper';
import { SoundcloudStreamLinkHandlerFactory } from './SoundcloudStreamLinkHandlerFactory';

export class SoundcloudCommentsLinkHandlerFactory extends ListLinkHandlerFactory {
  private static readonly INSTANCE: SoundcloudCommentsLinkHandlerFactory =
    new SoundcloudCommentsLinkHandlerFactory();

  static getInstance(): SoundcloudCommentsLinkHandlerFactory {
    return SoundcloudCommentsLinkHandlerFactory.INSTANCE;
  }

  private static buildUrl(id: string, clientId: string): string {
    // Anything but 1 = sort by new
    // + "&limit=NUMBER_OF_ITEMS_PER_REQUEST". We let the API control (default = 10)
    // + "&offset=OFFSET". We let the API control (default = 0, then we use nextPageUrl)
    return 'https://api-v2.soundcloud.com/tracks/' + id + '/comments' + '?client_id='
      + clientId + '&threaded=0' + '&filter_replies=1';
  }

  getUrlWithFilters(id: string, contentFilter: string[], sortFilter: string,
    baseUrl: string | null = null): string {
    const clientId: string | null = SoundcloudParsingHelper.cachedClientId();
    if (clientId === null) {
      throw new ParsingException('Could not get comments: client_id is not bootstrapped yet'
        + ' - use getUrlAsync(id)');
    }
    return SoundcloudCommentsLinkHandlerFactory.buildUrl(id, clientId);
  }

  async getUrlAsync(id: string): Promise<string> {
    try {
      return SoundcloudCommentsLinkHandlerFactory.buildUrl(id,
        await SoundcloudParsingHelper.clientId());
    } catch (e) {
      throw new ParsingException('Could not get comments',
        e instanceof Error ? e as Error : null);
    }
  }

  getId(url: string): string {
    // Delegation to avoid duplicate code, as we need the same id
    return SoundcloudStreamLinkHandlerFactory.getInstance().getId(url);
  }

  onAcceptUrl(url: string): boolean {
    try {
      this.getId(url);
      return true;
    } catch (e) {
      if (e instanceof ParsingException) {
        return false;
      }
      throw e;
    }
  }

  async fromIdAsListAsync(id: string, baseUrl: string | null = null): Promise<ListLinkHandler> {
    await SoundcloudParsingHelper.clientId();
    return this.fromIdAsList(id, baseUrl);
  }
}
