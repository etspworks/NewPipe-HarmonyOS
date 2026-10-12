/*
 * Port of org.schabi.newpipe.extractor.services.media_ccc.MediaCCCService
 * (NewPipeExtractor v0.26.5).
 *
 * Register it with `NewPipe.registerServices([...])` — never through ServiceList.all(), which is
 * an init-time module cycle here (phase2-logic-contract.md §9).
 *
 * DEVIATIONS, all forced by the ported StreamingService contract, which declares these returns
 * non-null (ArkTS cannot widen a return type in an override):
 *  - getPlaylistExtractor / getCommentsExtractor: the source returns null. Both are unreachable —
 *    getPlaylistLHFactory() and getCommentsLHFactory() return null, so the base class refuses the
 *    call before it gets here — and returning null would only NPE downstream, so they throw.
 *  - getSuggestionExtractor: the source returns null and every caller must null-check it. Here it
 *    returns an extractor that yields no suggestions, which is what a null-checking caller shows.
 *    Same as the source's own PeertubeSuggestionExtractor.
 */

import { MediaCapability, StreamingService } from '../../core/StreamingService';
import { ExtractionException } from '../../exceptions/Exceptions';
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
import { InfoItem } from '../../core/InfoItem';
import { KioskExtractor, KioskExtractorFactory, KioskList } from '../../info/KioskList';
import { PlaylistExtractor } from '../../info/PlaylistExtractor';
import { SearchExtractor } from '../../info/SearchExtractor';
import { StreamExtractor } from '../../info/StreamExtractor';
import { SubscriptionExtractor } from '../../info/SubscriptionExtractor';
import { SuggestionExtractor } from '../../info/SuggestionExtractor';
import { isLiveStreamId } from './MediaCCCParsingHelper';
import {
  MediaCCCConferenceLinkHandlerFactory
} from './linkHandler/MediaCCCConferenceLinkHandlerFactory';
import {
  MediaCCCConferencesListLinkHandlerFactory
} from './linkHandler/MediaCCCConferencesListLinkHandlerFactory';
import {
  MediaCCCLiveListLinkHandlerFactory
} from './linkHandler/MediaCCCLiveListLinkHandlerFactory';
import {
  MediaCCCRecentListLinkHandlerFactory
} from './linkHandler/MediaCCCRecentListLinkHandlerFactory';
import {
  MediaCCCSearchQueryHandlerFactory
} from './linkHandler/MediaCCCSearchQueryHandlerFactory';
import {
  MediaCCCStreamLinkHandlerFactory
} from './linkHandler/MediaCCCStreamLinkHandlerFactory';
import { MediaCCCChannelTabExtractor } from './extractors/MediaCCCChannelTabExtractor';
import { MediaCCCConferenceExtractor } from './extractors/MediaCCCConferenceExtractor';
import {
  KIOSK_ID as CONFERENCES_KIOSK_ID,
  MediaCCCConferenceKiosk
} from './extractors/MediaCCCConferenceKiosk';
import {
  KIOSK_ID as LIVE_KIOSK_ID,
  MediaCCCLiveStreamKiosk
} from './extractors/MediaCCCLiveStreamKiosk';
import { MediaCCCLiveStreamExtractor } from './extractors/MediaCCCLiveStreamExtractor';
import {
  KIOSK_ID as RECENT_KIOSK_ID,
  MediaCCCRecentKiosk
} from './extractors/MediaCCCRecentKiosk';
import { MediaCCCSearchExtractor } from './extractors/MediaCCCSearchExtractor';
import { MediaCCCStreamExtractor } from './extractors/MediaCCCStreamExtractor';

/** media.ccc.de has no suggestion endpoint; see the deviation note in the file header. */
class MediaCCCSuggestionExtractor extends SuggestionExtractor {
  constructor(service: StreamingService) {
    super(service);
  }

  async suggestionList(query: string): Promise<string[]> {
    return [];
  }
}

class MediaCCCConferenceKioskFactory implements KioskExtractorFactory {
  private readonly service: MediaCCCService;

  constructor(service: MediaCCCService) {
    this.service = service;
  }

  async createNewKiosk(streamingService: StreamingService, url: string,
    kioskId: string): Promise<KioskExtractor<InfoItem>> {
    return new MediaCCCConferenceKiosk(this.service,
      MediaCCCConferencesListLinkHandlerFactory.getInstance().fromUrlAsList(url), kioskId);
  }
}

class MediaCCCRecentKioskFactory implements KioskExtractorFactory {
  private readonly service: MediaCCCService;

  constructor(service: MediaCCCService) {
    this.service = service;
  }

  async createNewKiosk(streamingService: StreamingService, url: string,
    kioskId: string): Promise<KioskExtractor<InfoItem>> {
    return new MediaCCCRecentKiosk(this.service,
      MediaCCCRecentListLinkHandlerFactory.getInstance().fromUrlAsList(url), kioskId);
  }
}

class MediaCCCLiveKioskFactory implements KioskExtractorFactory {
  private readonly service: MediaCCCService;

  constructor(service: MediaCCCService) {
    this.service = service;
  }

  async createNewKiosk(streamingService: StreamingService, url: string,
    kioskId: string): Promise<KioskExtractor<InfoItem>> {
    return new MediaCCCLiveStreamKiosk(this.service,
      MediaCCCLiveListLinkHandlerFactory.getInstance().fromUrlAsList(url), kioskId);
  }
}

export class MediaCCCService extends StreamingService {
  constructor(id: number) {
    super(id, 'media.ccc.de', new Set<MediaCapability>([MediaCapability.AUDIO,
      MediaCapability.VIDEO]));
  }

  getSearchExtractor(query: SearchQueryHandler): SearchExtractor {
    return new MediaCCCSearchExtractor(this, query);
  }

  getStreamLHFactory(): LinkHandlerFactory {
    return MediaCCCStreamLinkHandlerFactory.getInstance();
  }

  getChannelLHFactory(): ListLinkHandlerFactory | null {
    return MediaCCCConferenceLinkHandlerFactory.getInstance();
  }

  getChannelTabLHFactory(): ListLinkHandlerFactory | null {
    // there is just one channel tab in MediaCCC, the one containing conferences, so there is
    // no need for a specific channel tab link handler, but we can just use the channel one
    return MediaCCCConferenceLinkHandlerFactory.getInstance();
  }

  getPlaylistLHFactory(): ListLinkHandlerFactory | null {
    return null;
  }

  getSearchQHFactory(): SearchQueryHandlerFactory {
    return MediaCCCSearchQueryHandlerFactory.getInstance();
  }

  getStreamExtractor(linkHandler: LinkHandler): StreamExtractor {
    if (isLiveStreamId(linkHandler.getId())) {
      return new MediaCCCLiveStreamExtractor(this, linkHandler);
    }
    return new MediaCCCStreamExtractor(this, linkHandler);
  }

  getChannelExtractor(linkHandler: ListLinkHandler): ChannelExtractor {
    return new MediaCCCConferenceExtractor(this, linkHandler);
  }

  getChannelTabExtractor(linkHandler: ListLinkHandler): ChannelTabExtractor {
    if (linkHandler instanceof ReadyChannelTabListLinkHandler) {
      // conference data has already been fetched, let the ReadyChannelTabListLinkHandler
      // create a MediaCCCChannelTabExtractor with that data
      return (linkHandler as ReadyChannelTabListLinkHandler).getChannelTabExtractor(this);
    }
    // conference data has not been fetched yet, so pass null instead
    return new MediaCCCChannelTabExtractor(this, linkHandler, null);
  }

  getPlaylistExtractor(linkHandler: ListLinkHandler): PlaylistExtractor {
    throw new ExtractionException('media.ccc.de does not support playlists');
  }

  getSuggestionExtractor(): SuggestionExtractor {
    return new MediaCCCSuggestionExtractor(this);
  }

  getKioskList(): KioskList {
    const list: KioskList = new KioskList(this);
    const conferencesLHF: MediaCCCConferencesListLinkHandlerFactory =
      MediaCCCConferencesListLinkHandlerFactory.getInstance();
    const recentLHF: MediaCCCRecentListLinkHandlerFactory =
      MediaCCCRecentListLinkHandlerFactory.getInstance();
    const liveLHF: MediaCCCLiveListLinkHandlerFactory =
      MediaCCCLiveListLinkHandlerFactory.getInstance();

    try {
      list.addKioskEntry(new MediaCCCConferenceKioskFactory(this), conferencesLHF,
        CONFERENCES_KIOSK_ID);
      list.addKioskEntry(new MediaCCCRecentKioskFactory(this), recentLHF, RECENT_KIOSK_ID);
      list.addKioskEntry(new MediaCCCLiveKioskFactory(this), liveLHF, LIVE_KIOSK_ID);
      list.setDefaultKiosk(RECENT_KIOSK_ID);
    } catch (e) {
      throw new ExtractionException('Could not build the media.ccc.de kiosk list');
    }

    return list;
  }

  getSubscriptionExtractor(): SubscriptionExtractor | null {
    return null;
  }

  getCommentsLHFactory(): ListLinkHandlerFactory | null {
    return null;
  }

  getCommentsExtractor(linkHandler: ListLinkHandler): CommentsExtractor {
    throw new ExtractionException('media.ccc.de does not support comments');
  }

  getBaseUrl(): string {
    return 'https://media.ccc.de';
  }
}
