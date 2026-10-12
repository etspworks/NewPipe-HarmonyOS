/*
 * Port of org.schabi.newpipe.util.ExtractorHelper (the plan's svc_extractor).
 *
 * The APP's façade over the extractor: every screen loads its data through here, so the cache
 * check, the service-id guard and the "which extractor call does this screen need" mapping live
 * in exactly one place. This is NOT the extractor's own core/ExtractorHelper.ts — that one is
 * `getItemsPageOrLogError`, an internal of the Info classes (phase2-logic-contract.md §9/§10.2).
 *
 * DEVIATIONS, each forced and each narrow:
 *  - RxJava `Single<T>` -> `Promise<T>` (§1). Every method here is a one-shot load, so none is an
 *    Observable. checkCache()'s `Maybe.concat(cache, network).firstElement()` is just "return the
 *    cached value if there is one, else load" once the Rx wrapper is gone.
 *  - Java overloads getMoreCommentItems(info, page) / (url, page) become two names; ArkTS has no
 *    overloading (§9).
 *  - SoundCloud and Bandcamp resolve ids and the client_id over the network, so their link-handler
 *    factories expose async variants that prime a memo the synchronous factory then serves. The
 *    priming happens here because this is where a bare url first meets a service.
 *    ponytail: primeX() dispatches on the concrete factory class — ArkTS has no structural check
 *    for "does this object have fromUrlAsync". A NEW service with an async factory must be added
 *    to these branches; the alternative is an async hook on the wave-B base factory, which is a
 *    wider change than this pass owns.
 *  - showMetaInfoInTextView() is not ported: it builds a TextView, which is a Phase-3 concern.
 *    The data it renders (MetaInfo) is already on the Info objects.
 */

import { Info } from './core/Info';
import { InfoItem } from './core/InfoItem';
import { NewPipe } from './core/NewPipe';
import { StreamingService } from './core/StreamingService';
import { InfoCache, InfoCacheType } from './InfoCache';
import { FeedExtractor } from './info/FeedExtractor';
import { FeedInfo } from './info/FeedInfo';
import { SuggestionExtractor } from './info/SuggestionExtractor';
import {
  SubscriptionExtractor,
  SubscriptionItem as ExtractorSubscriptionItem
} from './info/SubscriptionExtractor';
import { LinkHandlerFactory, ListLinkHandlerFactory, SearchQueryHandlerFactory }
  from './linkhandler/LinkHandlerFactory';
import { ListLinkHandler, SearchQueryHandler } from './linkhandler/LinkHandler';
import { ChannelInfo } from '../../model/extractor/ChannelInfo';
import { ChannelTabInfo } from '../../model/extractor/ChannelTabInfo';
import { CommentsInfo } from '../../model/extractor/CommentsInfo';
import { CommentsInfoItem } from '../../model/extractor/CommentsInfoItem';
import { InfoItemsPage } from '../../model/extractor/ListExtractorInfoItemsPage';
import { KioskInfo } from '../../model/extractor/KioskInfo';
import { Page } from '../../model/extractor/Page';
import { PlaylistInfo } from '../../model/extractor/PlaylistInfo';
import { SearchInfo } from '../../model/extractor/SearchInfo';
import { StreamInfo } from '../../model/extractor/StreamInfo';
import { StreamInfoItem } from '../../model/extractor/StreamInfoItem';
import { SubscriptionItem } from '../../model/app/SubscriptionData';
import { fileIo } from '@kit.CoreFileKit';
import { SoundcloudStreamLinkHandlerFactory }
  from './services/soundcloud/linkHandler/SoundcloudStreamLinkHandlerFactory';
import { SoundcloudChannelLinkHandlerFactory }
  from './services/soundcloud/linkHandler/SoundcloudChannelLinkHandlerFactory';
import { SoundcloudPlaylistLinkHandlerFactory }
  from './services/soundcloud/linkHandler/SoundcloudPlaylistLinkHandlerFactory';
import { SoundcloudCommentsLinkHandlerFactory }
  from './services/soundcloud/linkHandler/SoundcloudCommentsLinkHandlerFactory';
import { SoundcloudSearchQueryHandlerFactory }
  from './services/soundcloud/linkHandler/SoundcloudSearchQueryHandlerFactory';
import { BandcampStreamLinkHandlerFactory }
  from './services/bandcamp/linkHandler/BandcampStreamLinkHandlerFactory';
import { BandcampChannelLinkHandlerFactory }
  from './services/bandcamp/linkHandler/BandcampChannelLinkHandlerFactory';
import { BandcampPlaylistLinkHandlerFactory }
  from './services/bandcamp/linkHandler/BandcampPlaylistLinkHandlerFactory';
import { BandcampCommentsLinkHandlerFactory }
  from './services/bandcamp/linkHandler/BandcampCommentsLinkHandlerFactory';

/** Constants.NO_SERVICE_ID. */
export const NO_SERVICE_ID: number = -1;

export class ExtractorHelper {
  /**
   * The app cache, where an imported archive is unpacked. Set by ServiceLocator.init(): this
   * module may not import the locator, because the new-streams worker loads it in a process
   * where the locator's continuous-task module is blocked.
   */
  static cacheDir: string = '';

  private static readonly CACHE: InfoCache = InfoCache.getInstance();

  private constructor() {
    // no instance
  }

  private static checkServiceId(serviceId: number): void {
    if (serviceId === NO_SERVICE_ID) {
      throw new Error('serviceId is NO_SERVICE_ID');
    }
  }

  private static service(serviceId: number): StreamingService {
    ExtractorHelper.checkServiceId(serviceId);
    return NewPipe.getService(serviceId);
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Search
  ////////////////////////////////////////////////////////////////////////// */

  static async searchFor(serviceId: number, searchString: string, contentFilter: string[],
    sortFilter: string): Promise<SearchInfo> {
    const service: StreamingService = ExtractorHelper.service(serviceId);
    const query: SearchQueryHandler =
      await ExtractorHelper.searchQuery(service, searchString, contentFilter, sortFilter);
    return SearchInfo.getInfoFromService(service, query);
  }

  static async getMoreSearchItems(serviceId: number, searchString: string, contentFilter: string[],
    sortFilter: string, page: Page): Promise<InfoItemsPage<InfoItem>> {
    const service: StreamingService = ExtractorHelper.service(serviceId);
    const query: SearchQueryHandler =
      await ExtractorHelper.searchQuery(service, searchString, contentFilter, sortFilter);
    return SearchInfo.getMoreItems(service, query, page);
  }

  static async suggestionsFor(serviceId: number, query: string): Promise<string[]> {
    // Java null-checks the extractor; wave B declared it non-nullable, so the guard is the type.
    const extractor: SuggestionExtractor =
      ExtractorHelper.service(serviceId).getSuggestionExtractor();
    return extractor.suggestionList(query);
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Streams, channels, playlists, comments, kiosks
  ////////////////////////////////////////////////////////////////////////// */

  static async getStreamInfo(serviceId: number, url: string,
    forceLoad: boolean = false): Promise<StreamInfo> {
    const service: StreamingService = ExtractorHelper.service(serviceId);
    const info: Info = await ExtractorHelper.checkCache(forceLoad, serviceId, url,
      InfoCacheType.STREAM, async (): Promise<Info> => {
        await ExtractorHelper.primeStream(service, url);
        return StreamInfo.getInfoFromService(service, url);
      });
    return info as StreamInfo;
  }

  static async getChannelInfo(serviceId: number, url: string,
    forceLoad: boolean = false): Promise<ChannelInfo> {
    const service: StreamingService = ExtractorHelper.service(serviceId);
    const info: Info = await ExtractorHelper.checkCache(forceLoad, serviceId, url,
      InfoCacheType.CHANNEL, async (): Promise<Info> => {
        await ExtractorHelper.primeChannel(service, url);
        return ChannelInfo.getInfoFromService(service, url);
      });
    return info as ChannelInfo;
  }

  static async getChannelTab(serviceId: number, listLinkHandler: ListLinkHandler,
    forceLoad: boolean = false): Promise<ChannelTabInfo> {
    const service: StreamingService = ExtractorHelper.service(serviceId);
    const info: Info = await ExtractorHelper.checkCache(forceLoad, serviceId,
      listLinkHandler.getUrl(), InfoCacheType.CHANNEL_TAB,
      (): Promise<Info> => ChannelTabInfo.getInfoFromService(service, listLinkHandler));
    return info as ChannelTabInfo;
  }

  static async getMoreChannelTabItems(serviceId: number, listLinkHandler: ListLinkHandler,
    nextPage: Page): Promise<InfoItemsPage<InfoItem>> {
    return ChannelTabInfo.getMoreItems(ExtractorHelper.service(serviceId), listLinkHandler,
      nextPage);
  }

  static async getCommentsInfo(serviceId: number, url: string,
    forceLoad: boolean = false): Promise<CommentsInfo | null> {
    const service: StreamingService = ExtractorHelper.service(serviceId);
    await ExtractorHelper.primeComments(service, url);
    const cached: Info | null = forceLoad
      ? null
      : ExtractorHelper.CACHE.getFromKey(serviceId, url, InfoCacheType.COMMENTS);
    if (cached !== null) {
      return cached as CommentsInfo;
    }
    const loaded: CommentsInfo | null = await CommentsInfo.getInfoFromService(service, url);
    if (loaded !== null) {
      ExtractorHelper.CACHE.putInfo(serviceId, url, loaded, InfoCacheType.COMMENTS);
    }
    return loaded;
  }

  /** Java's getMoreCommentItems(serviceId, CommentsInfo, Page). */
  static async getMoreCommentItemsForInfo(serviceId: number, info: CommentsInfo,
    nextPage: Page): Promise<InfoItemsPage<CommentsInfoItem>> {
    ExtractorHelper.checkServiceId(serviceId);
    return CommentsInfo.getMoreItemsForInfo(info, nextPage);
  }

  /** Java's getMoreCommentItems(serviceId, String, Page). */
  static async getMoreCommentItems(serviceId: number, url: string,
    nextPage: Page): Promise<InfoItemsPage<CommentsInfoItem>> {
    const service: StreamingService = ExtractorHelper.service(serviceId);
    await ExtractorHelper.primeComments(service, url);
    return CommentsInfo.getMoreItems(service, url, nextPage);
  }

  static async getPlaylistInfo(serviceId: number, url: string,
    forceLoad: boolean = false): Promise<PlaylistInfo> {
    const service: StreamingService = ExtractorHelper.service(serviceId);
    const info: Info = await ExtractorHelper.checkCache(forceLoad, serviceId, url,
      InfoCacheType.PLAYLIST, async (): Promise<Info> => {
        await ExtractorHelper.primePlaylist(service, url);
        return PlaylistInfo.getInfoFromService(service, url);
      });
    return info as PlaylistInfo;
  }

  static async getMorePlaylistItems(serviceId: number, url: string,
    nextPage: Page): Promise<InfoItemsPage<StreamInfoItem>> {
    const service: StreamingService = ExtractorHelper.service(serviceId);
    await ExtractorHelper.primePlaylist(service, url);
    return PlaylistInfo.getMoreItems(service, url, nextPage);
  }

  static async getKioskInfo(serviceId: number, url: string,
    forceLoad: boolean = false): Promise<KioskInfo> {
    const service: StreamingService = ExtractorHelper.service(serviceId);
    const info: Info = await ExtractorHelper.checkCache(forceLoad, serviceId, url,
      InfoCacheType.KIOSK, (): Promise<Info> => KioskInfo.getInfoFromService(service, url));
    return info as KioskInfo;
  }

  static async getMoreKioskItems(serviceId: number, url: string,
    nextPage: Page): Promise<InfoItemsPage<StreamInfoItem>> {
    return KioskInfo.getMoreItems(ExtractorHelper.service(serviceId), url, nextPage);
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Feed - FeedLoadManager's fast path
  ////////////////////////////////////////////////////////////////////////// */

  /**
   * Port of the feed-extractor branch of FeedLoadManager.loadStreams(): the service's own fast
   * feed (for YouTube the channel RSS, endpoint youtube_feed_rss). Returns null when the service
   * has no feed extractor, which is the caller's signal to fall back to the channel tabs.
   *
   * Not cached: the source loads the feed to find out what is NEW, so a cache hit would defeat it.
   */
  static async getFeedInfo(serviceId: number, url: string): Promise<FeedInfo | null> {
    const extractor: FeedExtractor | null =
      ExtractorHelper.service(serviceId).getFeedExtractor(url);
    if (extractor === null) {
      return null;
    }
    return FeedInfo.getInfo(extractor);
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Subscription import - SubscriptionImportWorker's three input modes
  ////////////////////////////////////////////////////////////////////////// */

  /** Endpoint subscription_import_channel_url. */
  static async getSubscriptionsFromChannelUrl(serviceId: number,
    url: string): Promise<SubscriptionItem[]> {
    const extractor: SubscriptionExtractor = ExtractorHelper.subscriptionExtractor(serviceId);
    return ExtractorHelper.toAppItems(await extractor.fromChannelUrl(url));
  }

  /**
   * Endpoint subscription_import_file, text form: a service's own JSON/CSV export.
   * A ZIP export has no text form — use getSubscriptionsFromFileUri().
   */
  static async getSubscriptionsFromFile(serviceId: number, content: string,
    contentType: string): Promise<SubscriptionItem[]> {
    const extractor: SubscriptionExtractor = ExtractorHelper.subscriptionExtractor(serviceId);
    return ExtractorHelper.toAppItems(await extractor.fromFileContent(content, contentType));
  }

  /**
   * Endpoint subscription_import_file, file form. A Google Takeout export is a ZIP, which is
   * binary: the picked file is read as BYTES and handed to the extractor, which unzips it with
   * `@ohos.zlib` (see YoutubeSubscriptionExtractor). Text formats take the same path — the
   * extractor decodes them — so one entry point covers every picked file.
   */
  static async getSubscriptionsFromFileUri(serviceId: number, fileUri: string,
    contentType: string): Promise<SubscriptionItem[]> {
    const extractor: SubscriptionExtractor = ExtractorHelper.subscriptionExtractor(serviceId);
    const bytes: ArrayBuffer = await ExtractorHelper.readFileBytes(fileUri);
    return ExtractorHelper.toAppItems(await extractor.fromFileContent(bytes, contentType,
      ExtractorHelper.cacheDir));
  }

  /** Reads a picked file (a DocumentViewPicker uri) whole. Rule 8: closed in `finally`. */
  private static async readFileBytes(fileUri: string): Promise<ArrayBuffer> {
    const file: fileIo.File = await fileIo.open(fileUri, fileIo.OpenMode.READ_ONLY);
    try {
      const stat: fileIo.Stat = await fileIo.stat(file.fd);
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      const read: number = await fileIo.read(file.fd, buffer);
      return read === stat.size ? buffer : buffer.slice(0, read);
    } finally {
      await fileIo.close(file);
    }
  }

  private static subscriptionExtractor(serviceId: number): SubscriptionExtractor {
    const service: StreamingService = ExtractorHelper.service(serviceId);
    const extractor: SubscriptionExtractor | null = service.getSubscriptionExtractor();
    if (extractor === null) {
      throw new Error('Service ' + service.getServiceInfo().getName()
        + ' does not support importing subscriptions');
    }
    return extractor;
  }

  /**
   * The extractor's SubscriptionItem and the app's (model/app/SubscriptionData, the JSON export
   * shape) are different types — ArkTS is nominal, so the boundary converts rather than casts.
   */
  private static toAppItems(items: ExtractorSubscriptionItem[]): SubscriptionItem[] {
    const out: SubscriptionItem[] = [];
    for (const item of items) {
      out.push(new SubscriptionItem(item.getServiceId(), item.getUrl(), item.getName()));
    }
    return out;
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Cache
  ////////////////////////////////////////////////////////////////////////// */

  /**
   * Port of checkCache(): serve the cached Info unless forceLoad, otherwise load and cache.
   * Non-generic so the downcast happens at each call site, where the concrete type is known.
   */
  private static async checkCache(forceLoad: boolean, serviceId: number, url: string,
    cacheType: InfoCacheType, loadFromNetwork: () => Promise<Info>): Promise<Info> {
    ExtractorHelper.checkServiceId(serviceId);
    if (forceLoad) {
      ExtractorHelper.CACHE.removeInfo(serviceId, url, cacheType);
    } else {
      const cached: Info | null = ExtractorHelper.CACHE.getFromKey(serviceId, url, cacheType);
      if (cached !== null) {
        return cached;
      }
    }
    const loaded: Info = await loadFromNetwork();
    ExtractorHelper.CACHE.putInfo(serviceId, url, loaded, cacheType);
    return loaded;
  }

  static isCached(serviceId: number, url: string, cacheType: InfoCacheType): boolean {
    ExtractorHelper.checkServiceId(serviceId);
    return ExtractorHelper.CACHE.getFromKey(serviceId, url, cacheType) !== null;
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Async link-handler priming - see the header note
  ////////////////////////////////////////////////////////////////////////// */

  private static async searchQuery(service: StreamingService, searchString: string,
    contentFilter: string[], sortFilter: string): Promise<SearchQueryHandler> {
    const factory: SearchQueryHandlerFactory = service.getSearchQHFactory();
    if (factory instanceof SoundcloudSearchQueryHandlerFactory) {
      return factory.fromSearchQueryAsync(searchString, contentFilter, sortFilter);
    }
    return factory.fromSearchQuery(searchString, contentFilter, sortFilter);
  }

  private static async primeStream(service: StreamingService, url: string): Promise<void> {
    const factory: LinkHandlerFactory = service.getStreamLHFactory();
    if (factory instanceof SoundcloudStreamLinkHandlerFactory) {
      await factory.fromUrlAsync(url);
    } else if (factory instanceof BandcampStreamLinkHandlerFactory) {
      await factory.fromUrlAsync(url);
    }
  }

  private static async primeChannel(service: StreamingService, url: string): Promise<void> {
    const factory: ListLinkHandlerFactory | null = service.getChannelLHFactory();
    if (factory instanceof SoundcloudChannelLinkHandlerFactory) {
      await factory.fromUrlAsListAsync(url);
    } else if (factory instanceof BandcampChannelLinkHandlerFactory) {
      await factory.fromUrlAsListAsync(url);
    }
  }

  private static async primePlaylist(service: StreamingService, url: string): Promise<void> {
    const factory: ListLinkHandlerFactory | null = service.getPlaylistLHFactory();
    if (factory instanceof SoundcloudPlaylistLinkHandlerFactory) {
      await factory.fromUrlAsListAsync(url);
    } else if (factory instanceof BandcampPlaylistLinkHandlerFactory) {
      await factory.fromUrlAsListAsync(url);
    }
  }

  /**
   * SoundCloud comments need two things resolved: the track id (owned by the STREAM factory, which
   * the comments factory delegates getId() to) and the bootstrapped client_id.
   */
  private static async primeComments(service: StreamingService, url: string): Promise<void> {
    const factory: ListLinkHandlerFactory | null = service.getCommentsLHFactory();
    if (factory instanceof SoundcloudCommentsLinkHandlerFactory) {
      await ExtractorHelper.primeStream(service, url);
      await factory.fromIdAsListAsync(factory.getId(url));
    } else if (factory instanceof BandcampCommentsLinkHandlerFactory) {
      await factory.fromUrlAsListAsync(url);
    }
  }
}
