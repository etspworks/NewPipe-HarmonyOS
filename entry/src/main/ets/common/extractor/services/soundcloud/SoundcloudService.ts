/*
 * Port of org.schabi.newpipe.extractor.services.soundcloud.SoundcloudService
 * (NewPipeExtractor v0.26.5).
 *
 * Register it with `NewPipe.registerServices([...])` (phase2-logic-contract.md §9) - never via
 * a `ServiceList.all()` style static read, which is an init-time module cycle here. The
 * constructor registers this instance with SoundcloudParsingHelper so the helper can read the
 * service localization without importing ServiceList.
 */

import { InfoItem } from '../../core/InfoItem';
import {
  MediaCapability,
  StreamingService
} from '../../core/StreamingService';
import { ChannelExtractor } from '../../info/ChannelExtractor';
import { ChannelTabExtractor } from '../../info/ChannelTabExtractor';
import { CommentsExtractor } from '../../info/CommentsExtractor';
import { KioskExtractor, KioskExtractorFactory, KioskList } from '../../info/KioskList';
import { PlaylistExtractor } from '../../info/PlaylistExtractor';
import { SearchExtractor } from '../../info/SearchExtractor';
import { StreamExtractor } from '../../info/StreamExtractor';
import { SubscriptionExtractor } from '../../info/SubscriptionExtractor';
import { SuggestionExtractor } from '../../info/SuggestionExtractor';
import { LinkHandler, ListLinkHandler, SearchQueryHandler } from '../../linkhandler/LinkHandler';
import {
  LinkHandlerFactory,
  ListLinkHandlerFactory,
  SearchQueryHandlerFactory
} from '../../linkhandler/LinkHandlerFactory';
import { ContentCountry } from '../../localization/ContentCountry';
import { ExtractionException } from '../../exceptions/Exceptions';
import { SoundcloudParsingHelper } from './SoundcloudParsingHelper';
import { SoundcloudChannelLinkHandlerFactory } from './linkHandler/SoundcloudChannelLinkHandlerFactory';
import { SoundcloudChannelTabLinkHandlerFactory } from './linkHandler/SoundcloudChannelTabLinkHandlerFactory';
import { SoundcloudChartsLinkHandlerFactory } from './linkHandler/SoundcloudChartsLinkHandlerFactory';
import { SoundcloudCommentsLinkHandlerFactory } from './linkHandler/SoundcloudCommentsLinkHandlerFactory';
import { SoundcloudPlaylistLinkHandlerFactory } from './linkHandler/SoundcloudPlaylistLinkHandlerFactory';
import { SoundcloudSearchQueryHandlerFactory } from './linkHandler/SoundcloudSearchQueryHandlerFactory';
import { SoundcloudStreamLinkHandlerFactory } from './linkHandler/SoundcloudStreamLinkHandlerFactory';
import { SoundcloudChannelExtractor } from './extractors/SoundcloudChannelExtractor';
import { SoundcloudChannelTabExtractor } from './extractors/SoundcloudChannelTabExtractor';
import { SoundcloudChartsExtractor } from './extractors/SoundcloudChartsExtractor';
import { SoundcloudCommentsExtractor } from './extractors/SoundcloudCommentsExtractor';
import { SoundcloudPlaylistExtractor } from './extractors/SoundcloudPlaylistExtractor';
import { SoundcloudSearchExtractor } from './extractors/SoundcloudSearchExtractor';
import { SoundcloudStreamExtractor } from './extractors/SoundcloudStreamExtractor';
import { SoundcloudSubscriptionExtractor } from './extractors/SoundcloudSubscriptionExtractor';
import { SoundcloudSuggestionExtractor } from './extractors/SoundcloudSuggestionExtractor';

/** The kiosk id the source uses for the SoundCloud charts. */
export const SOUNDCLOUD_CHARTS_KIOSK: string = 'New & hot';

class SoundcloudChartsKioskFactory implements KioskExtractorFactory {
  private readonly service: SoundcloudService;

  constructor(service: SoundcloudService) {
    this.service = service;
  }

  async createNewKiosk(streamingService: StreamingService, url: string,
    kioskId: string): Promise<KioskExtractor<InfoItem>> {
    return new SoundcloudChartsExtractor(this.service,
      SoundcloudChartsLinkHandlerFactory.getInstance().fromUrlAsList(url), kioskId);
  }
}

export class SoundcloudService extends StreamingService {
  constructor(id: number) {
    super(id, 'SoundCloud',
      new Set<MediaCapability>([MediaCapability.AUDIO, MediaCapability.COMMENTS]));
    SoundcloudParsingHelper.setService(this);
  }

  getBaseUrl(): string {
    return 'https://soundcloud.com';
  }

  getSearchQHFactory(): SearchQueryHandlerFactory {
    return SoundcloudSearchQueryHandlerFactory.getInstance();
  }

  getStreamLHFactory(): LinkHandlerFactory {
    return SoundcloudStreamLinkHandlerFactory.getInstance();
  }

  getChannelLHFactory(): ListLinkHandlerFactory | null {
    return SoundcloudChannelLinkHandlerFactory.getInstance();
  }

  getChannelTabLHFactory(): ListLinkHandlerFactory | null {
    return SoundcloudChannelTabLinkHandlerFactory.getInstance();
  }

  getPlaylistLHFactory(): ListLinkHandlerFactory | null {
    return SoundcloudPlaylistLinkHandlerFactory.getInstance();
  }

  getSupportedCountries(): ContentCountry[] {
    // Country selector here: https://soundcloud.com/charts/top?genre=all-music
    return ContentCountry.listFrom(['AU', 'CA', 'DE', 'FR', 'GB', 'IE', 'NL', 'NZ', 'US']);
  }

  getStreamExtractor(linkHandler: LinkHandler): StreamExtractor {
    return new SoundcloudStreamExtractor(this, linkHandler);
  }

  getChannelExtractor(linkHandler: ListLinkHandler): ChannelExtractor {
    return new SoundcloudChannelExtractor(this, linkHandler);
  }

  getChannelTabExtractor(linkHandler: ListLinkHandler): ChannelTabExtractor {
    return new SoundcloudChannelTabExtractor(this, linkHandler);
  }

  getPlaylistExtractor(linkHandler: ListLinkHandler): PlaylistExtractor {
    return new SoundcloudPlaylistExtractor(this, linkHandler);
  }

  getSearchExtractor(queryHandler: SearchQueryHandler): SearchExtractor {
    return new SoundcloudSearchExtractor(this, queryHandler);
  }

  getSuggestionExtractor(): SuggestionExtractor {
    return new SoundcloudSuggestionExtractor(this);
  }

  getKioskList(): KioskList {
    const list: KioskList = new KioskList(this);

    const h: SoundcloudChartsLinkHandlerFactory =
      SoundcloudChartsLinkHandlerFactory.getInstance();

    try {
      list.addKioskEntry(new SoundcloudChartsKioskFactory(this), h, SOUNDCLOUD_CHARTS_KIOSK);
      list.setDefaultKiosk(SOUNDCLOUD_CHARTS_KIOSK);
    } catch (e) {
      throw new ExtractionException('Could not build the SoundCloud kiosk list',
        e instanceof Error ? e as Error : null);
    }

    return list;
  }

  getSubscriptionExtractor(): SubscriptionExtractor | null {
    return new SoundcloudSubscriptionExtractor(this);
  }

  getCommentsLHFactory(): ListLinkHandlerFactory | null {
    return SoundcloudCommentsLinkHandlerFactory.getInstance();
  }

  getCommentsExtractor(linkHandler: ListLinkHandler): CommentsExtractor {
    return new SoundcloudCommentsExtractor(this, linkHandler);
  }
}
