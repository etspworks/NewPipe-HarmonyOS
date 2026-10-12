/*
 * Port of org.schabi.newpipe.extractor.services.peertube.extractors.PeertubeAccountExtractor
 * (NewPipeExtractor v0.26.5).
 *
 * DEVIATION, forced by the async model (phase2-logic-contract.md §1): the source computes the
 * subscriber count inside getSubscriberCount(), which does a second HTTP request. Only
 * Extractor.onFetchPage() is a Promise here — every getter below it is synchronous — so that
 * request moves into onFetchPage and the result is cached. Same requests, same value; the only
 * change is that it is fetched eagerly, and StreamInfo/ChannelInfo read the count on every
 * channel load anyway.
 */

import { ChannelExtractor } from '../../../info/ChannelExtractor';
import { ChannelTabs } from '../../../info/ChannelTabExtractor';
import { StreamingService } from '../../../core/StreamingService';
import { ListLinkHandler } from '../../../linkhandler/LinkHandler';
import { Downloader, Response } from '../../../downloader/Downloader';
import { JsonArray, JsonObject, JsonParser } from '../../../json/NanoJson';
import { JsonUtils } from '../../../core/JsonUtils';
import { toError } from '../../../core/Errors';
import { ExtractionException } from '../../../exceptions/Exceptions';
import { Image } from '../../../../../model/extractor/Image';
import {
  getAvatarsFromOwnerAccountOrVideoChannelObject,
  getBannersFromAccountOrVideoChannelObject,
  nonNullString
} from '../PeertubeParsingHelper';
import { API_ENDPOINT } from '../linkHandler/PeertubeChannelLinkHandlerFactory';
import {
  PeertubeChannelTabLinkHandlerFactory
} from '../linkHandler/PeertubeChannelTabLinkHandlerFactory';

const ACCOUNTS: string = 'accounts/';
/** The source builds this from API_ENDPOINT + ACCOUNTS; it is one instance-relative path. */
const ACCOUNTS_API_ENDPOINT: string = '/api/v1/accounts/';

export class PeertubeAccountExtractor extends ChannelExtractor {
  private json: JsonObject = new JsonObject();
  private readonly baseUrl: string;
  private subscriberCount: number = 0;

  constructor(service: StreamingService, linkHandler: ListLinkHandler) {
    super(service, linkHandler);
    this.baseUrl = this.getBaseUrl();
  }

  getAvatars(): Image[] {
    return getAvatarsFromOwnerAccountOrVideoChannelObject(this.baseUrl, this.json);
  }

  getBanners(): Image[] {
    return getBannersFromAccountOrVideoChannelObject(this.baseUrl, this.json);
  }

  /** The source concatenates the raw `id` value; PeerTube account ids are numeric. */
  getFeedUrl(): string | null {
    return this.getBaseUrl() + '/feeds/videos.xml?accountId=' + this.json.getLong('id');
  }

  getSubscriberCount(): number {
    return this.subscriberCount;
  }

  /**
   * The subscriber count cannot be retrieved directly. It needs to be calculated.
   * An account's subscriber count is the number of the channel owner's subscriptions
   * plus the sum of all sub channels subscriptions.
   */
  private async fetchSubscriberCount(): Promise<number> {
    let subscribersCount: number = this.json.getLong('followersCount');
    // ACCOUNTS_API_ENDPOINT is API_ENDPOINT + ACCOUNTS; an id that already carries "accounts/"
    // must not get it twice.
    let accountVideoChannelUrl: string = this.getId().includes(ACCOUNTS)
      ? this.baseUrl + API_ENDPOINT + this.getId()
      : this.baseUrl + ACCOUNTS_API_ENDPOINT + this.getId();
    accountVideoChannelUrl += '/video-channels';

    try {
      const responseBody: string = (await this.getDownloader().get(accountVideoChannelUrl))
        .responseBody();
      const jsonResponse: JsonObject = JsonParser.object().from(responseBody);
      const videoChannels: JsonArray = jsonResponse.getArray('data');
      for (const videoChannel of videoChannels.streamAsJsonObjects()) {
        subscribersCount += videoChannel.getInt('followersCount');
      }
    } catch (e) {
      // something went wrong during video channels extraction,
      // only return subscribers of ownerAccount
    }
    return subscribersCount;
  }

  getDescription(): string {
    return nonNullString(this.json.getString('description'));
  }

  getParentChannelName(): string {
    return '';
  }

  getParentChannelUrl(): string {
    return '';
  }

  getParentChannelAvatars(): Image[] {
    return [];
  }

  isVerified(): boolean {
    return false;
  }

  getTabs(): ListLinkHandler[] {
    return [
      PeertubeChannelTabLinkHandlerFactory.getInstance().fromQuery(this.getId(),
        [ChannelTabs.VIDEOS], '', this.getBaseUrl()),
      PeertubeChannelTabLinkHandlerFactory.getInstance().fromQuery(this.getId(),
        [ChannelTabs.CHANNELS], '', this.getBaseUrl())
    ];
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
    const response: Response = await downloader.get(this.baseUrl + API_ENDPOINT + this.getId());
    this.setInitialData(response.responseBody());
    this.subscriberCount = await this.fetchSubscriberCount();
  }

  private setInitialData(responseBody: string): void {
    try {
      this.json = JsonParser.object().from(responseBody);
    } catch (e) {
      throw new ExtractionException('Unable to extract PeerTube account data', toError(e));
    }
  }

  getName(): string {
    return JsonUtils.getString(this.json, 'displayName');
  }
}
