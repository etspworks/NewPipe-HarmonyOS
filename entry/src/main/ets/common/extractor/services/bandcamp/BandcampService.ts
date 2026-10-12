/*
 * Port of org.schabi.newpipe.extractor.services.bandcamp.BandcampService
 * (NewPipeExtractor v0.26.5). Created by Fynn Godau 2019, GPL v3 or later.
 *
 * Register it with `NewPipe.registerServices([...])` (phase2-logic-contract.md §9) - never via
 * a `ServiceList.all()` style static read, which is an init-time module cycle here.
 */

import { InfoItem } from '../../core/InfoItem';
import { MediaCapability, StreamingService } from '../../core/StreamingService';
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
import { ReadyChannelTabListLinkHandler } from '../../linkhandler/ReadyChannelTabListLinkHandler';
import { ExtractionException } from '../../exceptions/Exceptions';
import { BASE_URL, BandcampExtractorHelper } from './extractors/BandcampExtractorHelper';
import {
  BandcampFeaturedExtractor,
  FEATURED_API_URL,
  KIOSK_FEATURED
} from './extractors/BandcampFeaturedExtractor';
import {
  BandcampRadioExtractor,
  KIOSK_RADIO,
  RADIO_API_URL
} from './extractors/BandcampRadioExtractor';
import { BandcampChannelExtractor } from './extractors/BandcampChannelExtractor';
import { BandcampChannelTabExtractor } from './extractors/BandcampChannelTabExtractor';
import { BandcampCommentsExtractor } from './extractors/BandcampCommentsExtractor';
import { BandcampPlaylistExtractor } from './extractors/BandcampPlaylistExtractor';
import { BandcampRadioStreamExtractor } from './extractors/BandcampRadioStreamExtractor';
import { BandcampSearchExtractor } from './extractors/BandcampSearchExtractor';
import { BandcampStreamExtractor } from './extractors/BandcampStreamExtractor';
import { BandcampSuggestionExtractor } from './extractors/BandcampSuggestionExtractor';
import { BandcampChannelLinkHandlerFactory } from './linkHandler/BandcampChannelLinkHandlerFactory';
import { BandcampChannelTabLinkHandlerFactory } from './linkHandler/BandcampChannelTabLinkHandlerFactory';
import { BandcampCommentsLinkHandlerFactory } from './linkHandler/BandcampCommentsLinkHandlerFactory';
import { BandcampFeaturedLinkHandlerFactory } from './linkHandler/BandcampFeaturedLinkHandlerFactory';
import { BandcampPlaylistLinkHandlerFactory } from './linkHandler/BandcampPlaylistLinkHandlerFactory';
import { BandcampSearchQueryHandlerFactory } from './linkHandler/BandcampSearchQueryHandlerFactory';
import { BandcampStreamLinkHandlerFactory } from './linkHandler/BandcampStreamLinkHandlerFactory';

class BandcampFeaturedKioskFactory implements KioskExtractorFactory {
  private readonly service: BandcampService;

  constructor(service: BandcampService) {
    this.service = service;
  }

  async createNewKiosk(streamingService: StreamingService, url: string,
    kioskId: string): Promise<KioskExtractor<InfoItem>> {
    return new BandcampFeaturedExtractor(this.service,
      BandcampFeaturedLinkHandlerFactory.getInstance().fromUrlAsList(FEATURED_API_URL), kioskId);
  }
}

class BandcampRadioKioskFactory implements KioskExtractorFactory {
  private readonly service: BandcampService;

  constructor(service: BandcampService) {
    this.service = service;
  }

  async createNewKiosk(streamingService: StreamingService, url: string,
    kioskId: string): Promise<KioskExtractor<InfoItem>> {
    return new BandcampRadioExtractor(this.service,
      BandcampFeaturedLinkHandlerFactory.getInstance().fromUrlAsList(RADIO_API_URL), kioskId);
  }
}

export class BandcampService extends StreamingService {
  constructor(id: number) {
    super(id, 'Bandcamp',
      new Set<MediaCapability>([MediaCapability.AUDIO, MediaCapability.COMMENTS]));
  }

  getBaseUrl(): string {
    return BASE_URL;
  }

  getStreamLHFactory(): LinkHandlerFactory {
    return BandcampStreamLinkHandlerFactory.getInstance();
  }

  getChannelLHFactory(): ListLinkHandlerFactory | null {
    return BandcampChannelLinkHandlerFactory.getInstance();
  }

  getChannelTabLHFactory(): ListLinkHandlerFactory | null {
    return BandcampChannelTabLinkHandlerFactory.getInstance();
  }

  getPlaylistLHFactory(): ListLinkHandlerFactory | null {
    return BandcampPlaylistLinkHandlerFactory.getInstance();
  }

  getSearchQHFactory(): SearchQueryHandlerFactory {
    return BandcampSearchQueryHandlerFactory.getInstance();
  }

  getCommentsLHFactory(): ListLinkHandlerFactory | null {
    return BandcampCommentsLinkHandlerFactory.getInstance();
  }

  getSearchExtractor(queryHandler: SearchQueryHandler): SearchExtractor {
    return new BandcampSearchExtractor(this, queryHandler);
  }

  getSuggestionExtractor(): SuggestionExtractor {
    return new BandcampSuggestionExtractor(this);
  }

  getSubscriptionExtractor(): SubscriptionExtractor | null {
    return null;
  }

  getKioskList(): KioskList {
    const kioskList: KioskList = new KioskList(this);
    const h: BandcampFeaturedLinkHandlerFactory =
      BandcampFeaturedLinkHandlerFactory.getInstance();

    try {
      kioskList.addKioskEntry(new BandcampFeaturedKioskFactory(this), h, KIOSK_FEATURED);
      kioskList.addKioskEntry(new BandcampRadioKioskFactory(this), h, KIOSK_RADIO);
      kioskList.setDefaultKiosk(KIOSK_FEATURED);
    } catch (e) {
      throw new ExtractionException('Could not build the Bandcamp kiosk list',
        e instanceof Error ? e as Error : null);
    }

    return kioskList;
  }

  getChannelExtractor(linkHandler: ListLinkHandler): ChannelExtractor {
    return new BandcampChannelExtractor(this, linkHandler);
  }

  getChannelTabExtractor(linkHandler: ListLinkHandler): ChannelTabExtractor {
    if (linkHandler instanceof ReadyChannelTabListLinkHandler) {
      return (linkHandler as ReadyChannelTabListLinkHandler).getChannelTabExtractor(this);
    }
    return new BandcampChannelTabExtractor(this, linkHandler);
  }

  getPlaylistExtractor(linkHandler: ListLinkHandler): PlaylistExtractor {
    return new BandcampPlaylistExtractor(this, linkHandler);
  }

  getStreamExtractor(linkHandler: LinkHandler): StreamExtractor {
    if (BandcampExtractorHelper.isRadioUrl(linkHandler.getUrl())) {
      return new BandcampRadioStreamExtractor(this, linkHandler);
    }
    return new BandcampStreamExtractor(this, linkHandler);
  }

  getCommentsExtractor(linkHandler: ListLinkHandler): CommentsExtractor {
    return new BandcampCommentsExtractor(this, linkHandler);
  }
}
