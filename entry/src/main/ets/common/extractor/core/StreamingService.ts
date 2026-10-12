/*
 * Port of org.schabi.newpipe.extractor.StreamingService (NewPipeExtractor v0.26.5).
 *
 * ArkTS has no overloading, so every Java overload that took a url or a query instead of a
 * LinkHandler gets an explicit name. The abstract LinkHandler-taking methods keep the source
 * names, so a wave-C service implements exactly the set below:
 *
 *   getSearchExtractor(SearchQueryHandler)   -> getSearchExtractorFromQuery(query, ...)
 *   getChannelExtractor(ListLinkHandler)     -> getChannelExtractorFromQuery / ...FromUrl
 *   getPlaylistExtractor(ListLinkHandler)    -> getPlaylistExtractorFromQuery / ...FromUrl
 *   getStreamExtractor(LinkHandler)          -> getStreamExtractorFromUrl
 *   getCommentsExtractor(ListLinkHandler)    -> getCommentsExtractorFromUrl
 */

import { ContentCountry } from '../localization/ContentCountry';
import { Localization } from '../downloader/Localization';
import { TimeAgoParser } from '../localization/TimeAgoParser';
import { TimeAgoPatternsManager } from '../localization/TimeAgoPatternsManager';
import { LinkHandler, ListLinkHandler, SearchQueryHandler } from '../linkhandler/LinkHandler';
import {
  LinkHandlerFactory,
  ListLinkHandlerFactory,
  SearchQueryHandlerFactory
} from '../linkhandler/LinkHandlerFactory';
import { ChannelExtractor } from '../info/ChannelExtractor';
import { ChannelTabExtractor } from '../info/ChannelTabExtractor';
import { CommentsExtractor } from '../info/CommentsExtractor';
import { FeedExtractor } from '../info/FeedExtractor';
import { KioskList } from '../info/KioskList';
import { PlaylistExtractor } from '../info/PlaylistExtractor';
import { SearchExtractor } from '../info/SearchExtractor';
import { StreamExtractor } from '../info/StreamExtractor';
import { SubscriptionExtractor } from '../info/SubscriptionExtractor';
import { SuggestionExtractor } from '../info/SuggestionExtractor';
import { followGoogleRedirectIfNeeded } from './Utils';
import { NewPipe } from './NewPipe';

export enum MediaCapability {
  AUDIO,
  VIDEO,
  LIVE,
  COMMENTS
}

/**
 * Which type of URL you are handling, and therefore which part of the app should handle it.
 */
export enum LinkType {
  NONE,
  STREAM,
  CHANNEL,
  PLAYLIST
}

/** Meta information about a service implementation. */
export class ServiceInfo {
  private readonly name: string;
  private readonly mediaCapabilities: Set<MediaCapability>;

  constructor(name: string, mediaCapabilities: Set<MediaCapability>) {
    this.name = name;
    this.mediaCapabilities = mediaCapabilities;
  }

  getName(): string {
    return this.name;
  }

  getMediaCapabilities(): Set<MediaCapability> {
    return this.mediaCapabilities;
  }
}

export abstract class StreamingService {
  private readonly serviceId: number;
  private readonly serviceInfo: ServiceInfo;

  constructor(id: number, name: string, capabilities: Set<MediaCapability>) {
    this.serviceId = id;
    this.serviceInfo = new ServiceInfo(name, capabilities);
  }

  getServiceId(): number {
    return this.serviceId;
  }

  getServiceInfo(): ServiceInfo {
    return this.serviceInfo;
  }

  toString(): string {
    return this.serviceId + ':' + this.serviceInfo.getName();
  }

  abstract getBaseUrl(): string;

  /* //////////////////////////////////////////////////////////////////////////
  // Url Id handler
  ////////////////////////////////////////////////////////////////////////// */

  abstract getStreamLHFactory(): LinkHandlerFactory;

  /** Null when the service does not support channels. */
  abstract getChannelLHFactory(): ListLinkHandlerFactory | null;

  /** Null when the service does not support channel tabs. */
  abstract getChannelTabLHFactory(): ListLinkHandlerFactory | null;

  /** Null when the service does not support playlists. */
  abstract getPlaylistLHFactory(): ListLinkHandlerFactory | null;

  abstract getSearchQHFactory(): SearchQueryHandlerFactory;

  /** Null when the service does not support comments. */
  abstract getCommentsLHFactory(): ListLinkHandlerFactory | null;

  /* //////////////////////////////////////////////////////////////////////////
  // Extractors
  ////////////////////////////////////////////////////////////////////////// */

  abstract getSearchExtractor(queryHandler: SearchQueryHandler): SearchExtractor;

  abstract getSuggestionExtractor(): SuggestionExtractor;

  /** Outdated or obsolete; null may be returned. */
  abstract getSubscriptionExtractor(): SubscriptionExtractor | null;

  /**
   * Which strategy fetches the feed. In YouTube a separate lightweight feed exists; in services
   * where there is no other way to retrieve it, null is returned.
   */
  getFeedExtractor(url: string): FeedExtractor | null {
    return null;
  }

  abstract getKioskList(): KioskList;

  abstract getChannelExtractor(linkHandler: ListLinkHandler): ChannelExtractor;

  abstract getChannelTabExtractor(linkHandler: ListLinkHandler): ChannelTabExtractor;

  abstract getPlaylistExtractor(linkHandler: ListLinkHandler): PlaylistExtractor;

  abstract getStreamExtractor(linkHandler: LinkHandler): StreamExtractor;

  abstract getCommentsExtractor(linkHandler: ListLinkHandler): CommentsExtractor;

  /* //////////////////////////////////////////////////////////////////////////
  // Extractors without link handler
  ////////////////////////////////////////////////////////////////////////// */

  getSearchExtractorFromQuery(query: string, contentFilter: string[] = [],
    sortFilter: string = ''): SearchExtractor {
    return this.getSearchExtractor(
      this.getSearchQHFactory().fromSearchQuery(query, contentFilter, sortFilter));
  }

  getChannelExtractorFromQuery(id: string, contentFilter: string[],
    sortFilter: string): ChannelExtractor {
    const factory: ListLinkHandlerFactory | null = this.getChannelLHFactory();
    if (factory === null) {
      throw new Error('This service does not support channels');
    }
    return this.getChannelExtractor(factory.fromQuery(id, contentFilter, sortFilter, null));
  }

  getChannelExtractorFromUrl(url: string): ChannelExtractor {
    const factory: ListLinkHandlerFactory | null = this.getChannelLHFactory();
    if (factory === null) {
      throw new Error('This service does not support channels');
    }
    return this.getChannelExtractor(factory.fromUrlAsList(url));
  }

  getChannelTabExtractorFromId(id: string, tab: string): ChannelTabExtractor {
    const factory: ListLinkHandlerFactory | null = this.getChannelTabLHFactory();
    if (factory === null) {
      throw new Error('This service does not support channel tabs');
    }
    return this.getChannelTabExtractor(factory.fromQuery(id, [tab], '', null));
  }

  getChannelTabExtractorFromIdAndBaseUrl(id: string, tab: string,
    baseUrl: string): ChannelTabExtractor {
    const factory: ListLinkHandlerFactory | null = this.getChannelTabLHFactory();
    if (factory === null) {
      throw new Error('This service does not support channel tabs');
    }
    return this.getChannelTabExtractor(factory.fromQuery(id, [tab], '', baseUrl));
  }

  getPlaylistExtractorFromQuery(id: string, contentFilter: string[],
    sortFilter: string): PlaylistExtractor {
    const factory: ListLinkHandlerFactory | null = this.getPlaylistLHFactory();
    if (factory === null) {
      throw new Error('This service does not support playlists');
    }
    return this.getPlaylistExtractor(factory.fromQuery(id, contentFilter, sortFilter, null));
  }

  getPlaylistExtractorFromUrl(url: string): PlaylistExtractor {
    const factory: ListLinkHandlerFactory | null = this.getPlaylistLHFactory();
    if (factory === null) {
      throw new Error('This service does not support playlists');
    }
    return this.getPlaylistExtractor(factory.fromUrlAsList(url));
  }

  getStreamExtractorFromUrl(url: string): StreamExtractor {
    return this.getStreamExtractor(this.getStreamLHFactory().fromUrl(url));
  }

  getCommentsExtractorFromUrl(url: string): CommentsExtractor | null {
    const listLinkHandlerFactory: ListLinkHandlerFactory | null = this.getCommentsLHFactory();
    if (listLinkHandlerFactory === null) {
      return null;
    }
    return this.getCommentsExtractor(listLinkHandlerFactory.fromUrlAsList(url));
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Utils
  ////////////////////////////////////////////////////////////////////////// */

  /** Figures out where the link is pointing to (a channel, a video, a playlist, etc.). */
  getLinkTypeByUrl(url: string): LinkType {
    const polishedUrl: string = followGoogleRedirectIfNeeded(url);

    const sH: LinkHandlerFactory | null = this.getStreamLHFactory();
    const cH: LinkHandlerFactory | null = this.getChannelLHFactory();
    const pH: LinkHandlerFactory | null = this.getPlaylistLHFactory();

    if (sH !== null && sH.acceptUrl(polishedUrl)) {
      return LinkType.STREAM;
    } else if (cH !== null && cH.acceptUrl(polishedUrl)) {
      return LinkType.CHANNEL;
    } else if (pH !== null && pH.acceptUrl(polishedUrl)) {
      return LinkType.PLAYLIST;
    }
    return LinkType.NONE;
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Localization
  ////////////////////////////////////////////////////////////////////////// */

  getSupportedLocalizations(): Localization[] {
    return [Localization.DEFAULT];
  }

  getSupportedCountries(): ContentCountry[] {
    return [ContentCountry.DEFAULT];
  }

  /**
   * The localization to use in this service: the user's preferred one when supported, else the
   * first supported localization with the same language, else Localization.DEFAULT.
   */
  getLocalization(): Localization {
    const preferredLocalization: Localization = NewPipe.getPreferredLocalization();

    for (const supported of this.getSupportedLocalizations()) {
      if (supported.equals(preferredLocalization)) {
        return preferredLocalization;
      }
    }
    for (const supportedLanguage of this.getSupportedLocalizations()) {
      if (supportedLanguage.getLanguageCode() === preferredLocalization.getLanguageCode()) {
        return supportedLanguage;
      }
    }
    return Localization.DEFAULT;
  }

  /** The user's preferred country when this service supports it, else ContentCountry.DEFAULT. */
  getContentCountry(): ContentCountry {
    const preferredContentCountry: ContentCountry = NewPipe.getPreferredContentCountry();
    for (const supported of this.getSupportedCountries()) {
      if (supported.equals(preferredContentCountry)) {
        return preferredContentCountry;
      }
    }
    return ContentCountry.DEFAULT;
  }

  /**
   * A time ago parser for the given localization, falling back to the language-only localization
   * exactly as getLocalization() falls back.
   */
  getTimeAgoParser(localization: Localization): TimeAgoParser {
    const targetParser: TimeAgoParser | null =
      TimeAgoPatternsManager.getTimeAgoParserFor(localization);
    if (targetParser !== null) {
      return targetParser;
    }

    if (localization.getCountryCode().length > 0) {
      const lessSpecificLocalization: Localization =
        new Localization(localization.getLanguageCode());
      const lessSpecificParser: TimeAgoParser | null =
        TimeAgoPatternsManager.getTimeAgoParserFor(lessSpecificLocalization);
      if (lessSpecificParser !== null) {
        return lessSpecificParser;
      }
    }

    throw new Error('Localization is not supported ("' + localization.toString() + '")');
  }
}
