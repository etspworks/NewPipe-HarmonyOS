/*
 * Port of org.schabi.newpipe.extractor.services.media_ccc.extractors.MediaCCCSearchExtractor
 * (NewPipeExtractor v0.26.5).
 *
 * ArkTS has no anonymous classes, so the source's inline ChannelInfoItemExtractor over an
 * already-built ChannelInfoItem becomes the named ConferenceChannelInfoItemExtractor below.
 */

import { SearchExtractor } from '../../../info/SearchExtractor';
import { ChannelInfoItemExtractor } from '../../../info/ChannelExtractor';
import { StreamingService } from '../../../core/StreamingService';
import { SearchQueryHandler } from '../../../linkhandler/LinkHandler';
import { InfoItem } from '../../../core/InfoItem';
import { Downloader } from '../../../downloader/Downloader';
import { JsonArray, JsonObject, JsonParser } from '../../../json/NanoJson';
import { ExtractorLogger } from '../../../core/ExtractorLogger';
import { toError } from '../../../core/Errors';
import { ExtractionException } from '../../../exceptions/Exceptions';
import { ChannelInfoItem } from '../../../../../model/extractor/ChannelInfoItem';
import { Image } from '../../../../../model/extractor/Image';
import { InfoItemsPage } from '../../../../../model/extractor/ListExtractorInfoItemsPage';
import { MetaInfo } from '../../../../../model/extractor/MetaInfo';
import { Page } from '../../../../../model/extractor/Page';
import { MultiInfoItemsCollector } from '../../../core/MultiInfoItemsCollector';
import {
  MediaCCCConferencesListLinkHandlerFactory
} from '../linkHandler/MediaCCCConferencesListLinkHandlerFactory';
import {
  ALL,
  CONFERENCES,
  EVENTS
} from '../linkHandler/MediaCCCSearchQueryHandlerFactory';
import { KIOSK_ID, MediaCCCConferenceKiosk } from './MediaCCCConferenceKiosk';
import { MediaCCCStreamInfoItemExtractor } from './infoItems/MediaCCCStreamInfoItemExtractor';

const TAG: string = 'MediaCCCSearchExtractor';

/** The source's anonymous ChannelInfoItemExtractor: it just re-reads an existing item. */
class ConferenceChannelInfoItemExtractor extends ChannelInfoItemExtractor {
  private readonly item: ChannelInfoItem;

  constructor(item: ChannelInfoItem) {
    super();
    this.item = item;
  }

  getDescription(): string {
    return this.item.getDescription();
  }

  getSubscriberCount(): number {
    return this.item.getSubscriberCount();
  }

  getStreamCount(): number {
    return this.item.getStreamCount();
  }

  isVerified(): boolean {
    return false;
  }

  getName(): string {
    return this.item.getName();
  }

  getUrl(): string {
    return this.item.getUrl();
  }

  getThumbnails(): Image[] {
    return this.item.getThumbnails();
  }
}

export class MediaCCCSearchExtractor extends SearchExtractor {
  private doc: JsonObject = new JsonObject();
  private conferenceKiosk: MediaCCCConferenceKiosk | null = null;

  constructor(service: StreamingService, linkHandler: SearchQueryHandler) {
    super(service, linkHandler);
    try {
      this.conferenceKiosk = new MediaCCCConferenceKiosk(service,
        MediaCCCConferencesListLinkHandlerFactory.getInstance().fromIdAsList(KIOSK_ID),
        KIOSK_ID);
    } catch (e) {
      // the source prints the stack trace and leaves the field null
      ExtractorLogger.e(TAG, 'Could not build the conference kiosk', [], toError(e));
    }
  }

  getSearchSuggestion(): string {
    return '';
  }

  isCorrectedSearch(): boolean {
    return false;
  }

  getMetaInfo(): MetaInfo[] {
    return [];
  }

  private wantsConferences(): boolean {
    const filters: string[] = this.getLinkHandler().getContentFilters();
    return filters.includes(CONFERENCES) || filters.includes(ALL) || filters.length === 0;
  }

  private wantsEvents(): boolean {
    const filters: string[] = this.getLinkHandler().getContentFilters();
    return filters.includes(EVENTS) || filters.includes(ALL) || filters.length === 0;
  }

  async getInitialPage(): Promise<InfoItemsPage<InfoItem>> {
    const searchItems: MultiInfoItemsCollector =
      new MultiInfoItemsCollector(this.getServiceId());

    if (this.wantsConferences() && this.conferenceKiosk !== null) {
      const conferencePage: InfoItemsPage<ChannelInfoItem> =
        await this.conferenceKiosk.getInitialPage();
      this.searchConferences(this.getSearchString(), conferencePage.getItems(), searchItems);
    }

    if (this.wantsEvents()) {
      const events: JsonArray = this.doc.getArray('events');
      for (let i = 0; i < events.size(); i++) {
        // Ensure only uploaded talks are shown in the search results.
        // If the release date is null, the talk has not been held or uploaded yet
        // and no streams are going to be available anyway.
        if (events.getObject(i).getString('release_date') !== null) {
          searchItems.commit(new MediaCCCStreamInfoItemExtractor(events.getObject(i)));
        }
      }
    }
    return InfoItemsPage.fromCollector(searchItems, null);
  }

  async getPage(page: Page): Promise<InfoItemsPage<InfoItem>> {
    return InfoItemsPage.emptyPage();
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
    if (this.wantsEvents()) {
      const site: string =
        (await downloader.get(this.getUrl(), null, this.getExtractorLocalization()))
          .responseBody();
      try {
        this.doc = JsonParser.object().from(site);
      } catch (e) {
        throw new ExtractionException('Could not parse JSON.', toError(e));
      }
    }
    if (this.wantsConferences() && this.conferenceKiosk !== null) {
      await this.conferenceKiosk.fetchPage();
    }
  }

  private searchConferences(searchString: string, channelItems: ChannelInfoItem[],
    collector: MultiInfoItemsCollector): void {
    for (const item of channelItems) {
      if (item.getName().toUpperCase().includes(searchString.toUpperCase())) {
        collector.commit(new ConferenceChannelInfoItemExtractor(item));
      }
    }
  }
}
