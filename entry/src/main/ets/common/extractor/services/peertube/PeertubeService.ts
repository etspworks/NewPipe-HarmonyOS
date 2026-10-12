/*
 * Port of org.schabi.newpipe.extractor.services.peertube.PeertubeService
 * (NewPipeExtractor v0.26.5).
 *
 * Register it with `NewPipe.registerServices([...])` — never through ServiceList.all(), which is
 * an init-time module cycle here (phase2-logic-contract.md §9). The link-handler factories read
 * the current instance base url from PeertubeInstanceState, which setInstance() keeps in step.
 *
 * PeerTube is instance-relative: getBaseUrl() is whichever instance the user picked (default
 * https://framatube.org, see model/extractor/PeertubeInstance). Search is the exception — it runs
 * against the global SepiaSearch index; see PeertubeSearchQueryHandlerFactory.
 */

import { MediaCapability, StreamingService } from '../../core/StreamingService';
import { ExtractionException } from '../../exceptions/Exceptions';
import { LinkHandler, ListLinkHandler, SearchQueryHandler } from '../../linkhandler/LinkHandler';
import {
  LinkHandlerFactory,
  ListLinkHandlerFactory,
  SearchQueryHandlerFactory
} from '../../linkhandler/LinkHandlerFactory';
import { ChannelExtractor } from '../../info/ChannelExtractor';
import { ChannelTabExtractor } from '../../info/ChannelTabExtractor';
import { CommentsExtractor } from '../../info/CommentsExtractor';
import { InfoItem } from '../../core/InfoItem';
import { KioskExtractor, KioskExtractorFactory, KioskList } from '../../info/KioskList';
import { PlaylistExtractor } from '../../info/PlaylistExtractor';
import { SearchExtractor } from '../../info/SearchExtractor';
import { StreamExtractor } from '../../info/StreamExtractor';
import { SubscriptionExtractor } from '../../info/SubscriptionExtractor';
import { SuggestionExtractor } from '../../info/SuggestionExtractor';
import { PeertubeInstance } from '../../../../model/extractor/PeertubeInstance';
import { setPeertubeBaseUrl } from './PeertubeInstanceState';
import { PeertubeAccountExtractor } from './extractors/PeertubeAccountExtractor';
import { PeertubeChannelExtractor } from './extractors/PeertubeChannelExtractor';
import { PeertubeChannelTabExtractor } from './extractors/PeertubeChannelTabExtractor';
import { PeertubeCommentsExtractor } from './extractors/PeertubeCommentsExtractor';
import { PeertubePlaylistExtractor } from './extractors/PeertubePlaylistExtractor';
import { PeertubeSearchExtractor } from './extractors/PeertubeSearchExtractor';
import { PeertubeStreamExtractor } from './extractors/PeertubeStreamExtractor';
import { PeertubeSuggestionExtractor } from './extractors/PeertubeSuggestionExtractor';
import { PeertubeTrendingExtractor } from './extractors/PeertubeTrendingExtractor';
import {
  PeertubeChannelLinkHandlerFactory
} from './linkHandler/PeertubeChannelLinkHandlerFactory';
import {
  PeertubeChannelTabLinkHandlerFactory
} from './linkHandler/PeertubeChannelTabLinkHandlerFactory';
import {
  PeertubeCommentsLinkHandlerFactory
} from './linkHandler/PeertubeCommentsLinkHandlerFactory';
import {
  PeertubePlaylistLinkHandlerFactory
} from './linkHandler/PeertubePlaylistLinkHandlerFactory';
import {
  PeertubeSearchQueryHandlerFactory
} from './linkHandler/PeertubeSearchQueryHandlerFactory';
import {
  PeertubeStreamLinkHandlerFactory
} from './linkHandler/PeertubeStreamLinkHandlerFactory';
import {
  KIOSK_LOCAL,
  KIOSK_MOST_LIKED,
  KIOSK_RECENT,
  KIOSK_TRENDING,
  PeertubeTrendingLinkHandlerFactory
} from './linkHandler/PeertubeTrendingLinkHandlerFactory';

/** Port of the KioskList.KioskExtractorFactory lambda in the source's getKioskList(). */
class PeertubeTrendingKioskFactory implements KioskExtractorFactory {
  private readonly service: PeertubeService;
  private readonly handlerFactory: PeertubeTrendingLinkHandlerFactory;

  constructor(service: PeertubeService, handlerFactory: PeertubeTrendingLinkHandlerFactory) {
    this.service = service;
    this.handlerFactory = handlerFactory;
  }

  async createNewKiosk(streamingService: StreamingService, url: string,
    kioskId: string): Promise<KioskExtractor<InfoItem>> {
    return new PeertubeTrendingExtractor(this.service,
      this.handlerFactory.fromIdAsList(kioskId), kioskId);
  }
}

export class PeertubeService extends StreamingService {
  private instance: PeertubeInstance;

  constructor(id: number, instance: PeertubeInstance = PeertubeInstance.DEFAULT_INSTANCE) {
    super(id, 'PeerTube', new Set<MediaCapability>([MediaCapability.VIDEO,
      MediaCapability.COMMENTS]));
    this.instance = instance;
    setPeertubeBaseUrl(instance.getUrl());
  }

  getStreamLHFactory(): LinkHandlerFactory {
    return PeertubeStreamLinkHandlerFactory.getInstance();
  }

  getChannelLHFactory(): ListLinkHandlerFactory | null {
    return PeertubeChannelLinkHandlerFactory.getInstance();
  }

  getChannelTabLHFactory(): ListLinkHandlerFactory | null {
    return PeertubeChannelTabLinkHandlerFactory.getInstance();
  }

  getPlaylistLHFactory(): ListLinkHandlerFactory | null {
    return PeertubePlaylistLinkHandlerFactory.getInstance();
  }

  getSearchQHFactory(): SearchQueryHandlerFactory {
    return PeertubeSearchQueryHandlerFactory.getInstance();
  }

  getCommentsLHFactory(): ListLinkHandlerFactory | null {
    return PeertubeCommentsLinkHandlerFactory.getInstance();
  }

  getSearchExtractor(queryHandler: SearchQueryHandler): SearchExtractor {
    const contentFilters: string[] = queryHandler.getContentFilters();
    return new PeertubeSearchExtractor(this, queryHandler,
      contentFilters.length > 0 && contentFilters[0].startsWith('sepia_'));
  }

  getSuggestionExtractor(): SuggestionExtractor {
    return new PeertubeSuggestionExtractor(this);
  }

  getSubscriptionExtractor(): SubscriptionExtractor | null {
    return null;
  }

  getChannelExtractor(linkHandler: ListLinkHandler): ChannelExtractor {
    if (linkHandler.getUrl().includes('/video-channels/')) {
      return new PeertubeChannelExtractor(this, linkHandler);
    }
    return new PeertubeAccountExtractor(this, linkHandler);
  }

  getChannelTabExtractor(linkHandler: ListLinkHandler): ChannelTabExtractor {
    return new PeertubeChannelTabExtractor(this, linkHandler);
  }

  getPlaylistExtractor(linkHandler: ListLinkHandler): PlaylistExtractor {
    return new PeertubePlaylistExtractor(this, linkHandler);
  }

  getStreamExtractor(linkHandler: LinkHandler): StreamExtractor {
    return new PeertubeStreamExtractor(this, linkHandler);
  }

  getCommentsExtractor(linkHandler: ListLinkHandler): CommentsExtractor {
    return new PeertubeCommentsExtractor(this, linkHandler);
  }

  getBaseUrl(): string {
    return this.instance.getUrl();
  }

  getInstance(): PeertubeInstance {
    return this.instance;
  }

  setInstance(instance: PeertubeInstance): void {
    this.instance = instance;
    setPeertubeBaseUrl(instance.getUrl());
  }

  getKioskList(): KioskList {
    const h: PeertubeTrendingLinkHandlerFactory =
      PeertubeTrendingLinkHandlerFactory.getInstance();
    const kioskFactory: KioskExtractorFactory = new PeertubeTrendingKioskFactory(this, h);

    const list: KioskList = new KioskList(this);

    try {
      list.addKioskEntry(kioskFactory, h, KIOSK_TRENDING);
      list.addKioskEntry(kioskFactory, h, KIOSK_MOST_LIKED);
      list.addKioskEntry(kioskFactory, h, KIOSK_RECENT);
      list.addKioskEntry(kioskFactory, h, KIOSK_LOCAL);
      list.setDefaultKiosk(KIOSK_TRENDING);
    } catch (e) {
      throw new ExtractionException('Could not build the PeerTube kiosk list');
    }

    return list;
  }
}
