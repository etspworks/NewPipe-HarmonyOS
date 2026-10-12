/*
 * Port of org.schabi.newpipe.extractor.services.youtube.YoutubeService
 * (NewPipeExtractor v0.26.5).
 *
 * ArkTS has no anonymous classes, so each of getKioskList()'s six lambdas becomes a small named
 * KioskExtractorFactory below. The kiosk factories build their extractor from the ListLinkHandler
 * form (`fromUrlAsList`), which is the wave-B rename of the source's `fromUrl`.
 */

import { ContentCountry } from '../../localization/ContentCountry';
import { Localization } from '../../downloader/Localization';
import { InfoItem } from '../../core/InfoItem';
import {
  MediaCapability,
  StreamingService
} from '../../core/StreamingService';
import { LinkHandler, ListLinkHandler, SearchQueryHandler } from '../../linkhandler/LinkHandler';
import {
  LinkHandlerFactory,
  ListLinkHandlerFactory,
  SearchQueryHandlerFactory
} from '../../linkhandler/LinkHandlerFactory';
import { ReadyChannelTabListLinkHandler } from '../../linkhandler/ReadyChannelTabListLinkHandler';
import { ChannelExtractor } from '../../info/ChannelExtractor';
import { ChannelTabExtractor } from '../../info/ChannelTabExtractor';
import { CommentsExtractor } from '../../info/CommentsExtractor';
import { FeedExtractor } from '../../info/FeedExtractor';
import { KioskExtractor, KioskExtractorFactory, KioskList } from '../../info/KioskList';
import { PlaylistExtractor } from '../../info/PlaylistExtractor';
import { SearchExtractor } from '../../info/SearchExtractor';
import { StreamExtractor } from '../../info/StreamExtractor';
import { SubscriptionExtractor } from '../../info/SubscriptionExtractor';
import { SuggestionExtractor } from '../../info/SuggestionExtractor';
import { isYoutubeMixId } from './YoutubeParsingHelper';
import { YoutubeStreamLinkHandlerFactory } from './linkHandler/YoutubeStreamLinkHandlerFactory';
import {
  YoutubeChannelLinkHandlerFactory,
  YoutubeChannelTabLinkHandlerFactory
} from './linkHandler/YoutubeChannelLinkHandlerFactory';
import { YoutubePlaylistLinkHandlerFactory } from './linkHandler/YoutubePlaylistLinkHandlerFactory';
import { YoutubeSearchQueryHandlerFactory } from './linkHandler/YoutubeSearchQueryHandlerFactory';
import { YoutubeCommentsLinkHandlerFactory } from './linkHandler/YoutubeCommentsLinkHandlerFactory';
import {
  YoutubeLiveLinkHandlerFactory,
  YoutubeTrendingGamingVideosLinkHandlerFactory,
  YoutubeTrendingLinkHandlerFactory,
  YoutubeTrendingMoviesAndShowsTrailersLinkHandlerFactory,
  YoutubeTrendingMusicLinkHandlerFactory,
  YoutubeTrendingPodcastsEpisodesLinkHandlerFactory
} from './linkHandler/YoutubeKioskLinkHandlerFactories';
import { YoutubeStreamExtractor } from './extractors/YoutubeStreamExtractor';
import { YoutubeChannelExtractor } from './extractors/YoutubeChannelExtractor';
import { YoutubeChannelTabExtractor } from './extractors/YoutubeChannelTabExtractor';
import { YoutubePlaylistExtractor } from './extractors/YoutubePlaylistExtractor';
import { YoutubeMixPlaylistExtractor } from './extractors/YoutubeMixPlaylistExtractor';
import { YoutubeSearchExtractor } from './extractors/YoutubeSearchExtractor';
import { YoutubeMusicSearchExtractor } from './extractors/YoutubeMusicSearchExtractor';
import { YoutubeSuggestionExtractor } from './extractors/YoutubeSuggestionExtractor';
import { YoutubeSubscriptionExtractor } from './extractors/YoutubeSubscriptionExtractor';
import { YoutubeFeedExtractor } from './extractors/YoutubeFeedExtractor';
import { YoutubeCommentsExtractor } from './extractors/YoutubeCommentsExtractor';
import {
  YoutubeLiveExtractor,
  YoutubeTrendingExtractor,
  YoutubeTrendingGamingVideosExtractor,
  YoutubeTrendingMoviesAndShowsTrailersExtractor,
  YoutubeTrendingMusicExtractor,
  YoutubeTrendingPodcastsEpisodesExtractor
} from './extractors/kiosk/YoutubeKioskExtractors';

/** One kiosk factory per kiosk; ArkTS has no lambdas implementing an interface. */
class LiveKioskFactory implements KioskExtractorFactory {
  async createNewKiosk(streamingService: StreamingService, url: string,
    kioskId: string): Promise<KioskExtractor<InfoItem>> {
    return new YoutubeLiveExtractor(streamingService,
      YoutubeLiveLinkHandlerFactory.getInstance().fromUrlAsList(url), kioskId);
  }
}

class TrendingPodcastsEpisodesKioskFactory implements KioskExtractorFactory {
  async createNewKiosk(streamingService: StreamingService, url: string,
    kioskId: string): Promise<KioskExtractor<InfoItem>> {
    return new YoutubeTrendingPodcastsEpisodesExtractor(streamingService,
      YoutubeTrendingPodcastsEpisodesLinkHandlerFactory.getInstance().fromUrlAsList(url),
      kioskId);
  }
}

class TrendingGamingVideosKioskFactory implements KioskExtractorFactory {
  async createNewKiosk(streamingService: StreamingService, url: string,
    kioskId: string): Promise<KioskExtractor<InfoItem>> {
    return new YoutubeTrendingGamingVideosExtractor(streamingService,
      YoutubeTrendingGamingVideosLinkHandlerFactory.getInstance().fromUrlAsList(url), kioskId);
  }
}

class TrendingMoviesAndShowsKioskFactory implements KioskExtractorFactory {
  async createNewKiosk(streamingService: StreamingService, url: string,
    kioskId: string): Promise<KioskExtractor<InfoItem>> {
    return new YoutubeTrendingMoviesAndShowsTrailersExtractor(streamingService,
      YoutubeTrendingMoviesAndShowsTrailersLinkHandlerFactory.getInstance().fromUrlAsList(url),
      kioskId);
  }
}

class TrendingMusicKioskFactory implements KioskExtractorFactory {
  async createNewKiosk(streamingService: StreamingService, url: string,
    kioskId: string): Promise<KioskExtractor<InfoItem>> {
    return new YoutubeTrendingMusicExtractor(streamingService,
      YoutubeTrendingMusicLinkHandlerFactory.getInstance().fromUrlAsList(url), kioskId);
  }
}

class TrendingKioskFactory implements KioskExtractorFactory {
  async createNewKiosk(streamingService: StreamingService, url: string,
    kioskId: string): Promise<KioskExtractor<InfoItem>> {
    return new YoutubeTrendingExtractor(streamingService,
      YoutubeTrendingLinkHandlerFactory.getInstance().fromUrlAsList(url), kioskId);
  }
}

// https://www.youtube.com/picker_ajax?action_language_json=1
// The source ships only en-GB uncommented; the rest of its list stays commented out there too.
const SUPPORTED_LANGUAGES: Localization[] = [new Localization('en', 'GB')];

// https://www.youtube.com/picker_ajax?action_country_json=1
const SUPPORTED_COUNTRIES: ContentCountry[] = ContentCountry.listFrom(['DZ', 'AR', 'AU', 'AT',
  'AZ', 'BH', 'BD', 'BY', 'BE', 'BO', 'BA', 'BR', 'BG', 'KH', 'CA', 'CL', 'CO', 'CR', 'HR', 'CY',
  'CZ', 'DK', 'DO', 'EC', 'EG', 'SV', 'EE', 'FI', 'FR', 'GE', 'DE', 'GH', 'GR', 'GT', 'HN', 'HK',
  'HU', 'IS', 'IN', 'ID', 'IQ', 'IE', 'IL', 'IT', 'JM', 'JP', 'JO', 'KZ', 'KE', 'KW', 'LA', 'LV',
  'LB', 'LY', 'LI', 'LT', 'LU', 'MY', 'MT', 'MX', 'ME', 'MA', 'NP', 'NL', 'NZ', 'NI', 'NG', 'MK',
  'NO', 'OM', 'PK', 'PA', 'PG', 'PY', 'PE', 'PH', 'PL', 'PT', 'PR', 'QA', 'RO', 'RU', 'SA', 'SN',
  'RS', 'SG', 'SK', 'SI', 'ZA', 'KR', 'ES', 'LK', 'SE', 'CH', 'TW', 'TZ', 'TH', 'TN', 'TR', 'UG',
  'UA', 'AE', 'GB', 'US', 'UY', 'VE', 'VN', 'YE', 'ZW']);

export class YoutubeService extends StreamingService {
  constructor(id: number) {
    super(id, 'YouTube', new Set<MediaCapability>([MediaCapability.AUDIO,
      MediaCapability.VIDEO, MediaCapability.LIVE, MediaCapability.COMMENTS]));
  }

  getBaseUrl(): string {
    return 'https://youtube.com';
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Link handler factories
  ////////////////////////////////////////////////////////////////////////// */

  getStreamLHFactory(): LinkHandlerFactory {
    return YoutubeStreamLinkHandlerFactory.getInstance();
  }

  getChannelLHFactory(): ListLinkHandlerFactory {
    return YoutubeChannelLinkHandlerFactory.getInstance();
  }

  getChannelTabLHFactory(): ListLinkHandlerFactory {
    return YoutubeChannelTabLinkHandlerFactory.getInstance();
  }

  getPlaylistLHFactory(): ListLinkHandlerFactory {
    return YoutubePlaylistLinkHandlerFactory.getInstance();
  }

  getSearchQHFactory(): SearchQueryHandlerFactory {
    return YoutubeSearchQueryHandlerFactory.getInstance();
  }

  getCommentsLHFactory(): ListLinkHandlerFactory {
    return YoutubeCommentsLinkHandlerFactory.getInstance();
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Extractors
  ////////////////////////////////////////////////////////////////////////// */

  getStreamExtractor(linkHandler: LinkHandler): StreamExtractor {
    return new YoutubeStreamExtractor(this, linkHandler);
  }

  getChannelExtractor(linkHandler: ListLinkHandler): ChannelExtractor {
    return new YoutubeChannelExtractor(this, linkHandler);
  }

  getChannelTabExtractor(linkHandler: ListLinkHandler): ChannelTabExtractor {
    if (linkHandler instanceof ReadyChannelTabListLinkHandler) {
      return (linkHandler as ReadyChannelTabListLinkHandler).getChannelTabExtractor(this);
    }
    return new YoutubeChannelTabExtractor(this, linkHandler);
  }

  getPlaylistExtractor(linkHandler: ListLinkHandler): PlaylistExtractor {
    if (isYoutubeMixId(linkHandler.getId())) {
      return new YoutubeMixPlaylistExtractor(this, linkHandler);
    }
    return new YoutubePlaylistExtractor(this, linkHandler);
  }

  getSearchExtractor(query: SearchQueryHandler): SearchExtractor {
    const contentFilters: string[] = query.getContentFilters();
    if (contentFilters.length > 0 && contentFilters[0].startsWith('music_')) {
      return new YoutubeMusicSearchExtractor(this, query);
    }
    return new YoutubeSearchExtractor(this, query);
  }

  getSuggestionExtractor(): SuggestionExtractor {
    return new YoutubeSuggestionExtractor(this);
  }

  getSubscriptionExtractor(): SubscriptionExtractor {
    return new YoutubeSubscriptionExtractor(this);
  }

  getFeedExtractor(channelUrl: string): FeedExtractor | null {
    const factory: ListLinkHandlerFactory | null = this.getChannelLHFactory();
    if (factory === null) {
      return null;
    }
    return new YoutubeFeedExtractor(this, factory.fromUrlAsList(channelUrl));
  }

  getCommentsExtractor(urlIdHandler: ListLinkHandler): CommentsExtractor {
    return new YoutubeCommentsExtractor(this, urlIdHandler);
  }

  getKioskList(): KioskList {
    const list: KioskList = new KioskList(this);

    list.addKioskEntry(new LiveKioskFactory(), YoutubeLiveLinkHandlerFactory.getInstance(),
      YoutubeLiveLinkHandlerFactory.KIOSK_ID);
    list.addKioskEntry(new TrendingPodcastsEpisodesKioskFactory(),
      YoutubeTrendingPodcastsEpisodesLinkHandlerFactory.getInstance(),
      YoutubeTrendingPodcastsEpisodesLinkHandlerFactory.KIOSK_ID);
    list.addKioskEntry(new TrendingGamingVideosKioskFactory(),
      YoutubeTrendingGamingVideosLinkHandlerFactory.getInstance(),
      YoutubeTrendingGamingVideosLinkHandlerFactory.KIOSK_ID);
    list.addKioskEntry(new TrendingMoviesAndShowsKioskFactory(),
      YoutubeTrendingMoviesAndShowsTrailersLinkHandlerFactory.getInstance(),
      YoutubeTrendingMoviesAndShowsTrailersLinkHandlerFactory.KIOSK_ID);
    list.addKioskEntry(new TrendingMusicKioskFactory(),
      YoutubeTrendingMusicLinkHandlerFactory.getInstance(),
      YoutubeTrendingMusicLinkHandlerFactory.KIOSK_ID);
    // Deprecated (removed from YouTube's own interface) since July 21, 2025
    list.addKioskEntry(new TrendingKioskFactory(),
      YoutubeTrendingLinkHandlerFactory.getInstance(), YoutubeTrendingExtractor.KIOSK_ID);

    list.setDefaultKiosk(YoutubeLiveLinkHandlerFactory.KIOSK_ID);
    return list;
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Localization
  ////////////////////////////////////////////////////////////////////////// */

  getSupportedLocalizations(): Localization[] {
    return SUPPORTED_LANGUAGES;
  }

  getSupportedCountries(): ContentCountry[] {
    return SUPPORTED_COUNTRIES;
  }
}
