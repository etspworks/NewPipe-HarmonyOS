/*
 * Port of org.schabi.newpipe.extractor.services.soundcloud.extractors
 * .SoundcloudSubscriptionExtractor (NewPipeExtractor v0.26.5).
 *
 * Extract the "followings" from a user in SoundCloud.
 */

import { ChannelInfoItem } from '../../../../../model/extractor/ChannelInfoItem';
import { ChannelInfoItemsCollector } from '../../../info/ChannelExtractor';
import {
  ContentSource,
  InvalidSourceException,
  SubscriptionExtractor,
  SubscriptionItem
} from '../../../info/SubscriptionExtractor';
import { StreamingService } from '../../../core/StreamingService';
import { HTTPS, replaceHttpWithHttps } from '../../../core/Utils';
import { SOUNDCLOUD_API_V2_URL, SoundcloudParsingHelper } from '../SoundcloudParsingHelper';
import { SoundcloudChannelLinkHandlerFactory } from '../linkHandler/SoundcloudChannelLinkHandlerFactory';

export class SoundcloudSubscriptionExtractor extends SubscriptionExtractor {
  constructor(service: StreamingService) {
    super(service, [ContentSource.CHANNEL_URL]);
  }

  getRelatedUrl(): string | null {
    return 'https://soundcloud.com/you';
  }

  async fromChannelUrl(channelUrl: string): Promise<SubscriptionItem[]> {
    if (channelUrl === null) {
      throw new InvalidSourceException('Channel url is null');
    }

    let id: string;
    try {
      id = await SoundcloudChannelLinkHandlerFactory.resolveId(
        SoundcloudSubscriptionExtractor.getUrlFrom(channelUrl));
    } catch (e) {
      throw new InvalidSourceException(null, e instanceof Error ? e as Error : null);
    }

    const apiUrl: string = SOUNDCLOUD_API_V2_URL + 'users/' + id + '/followings' + '?client_id='
      + await SoundcloudParsingHelper.clientId() + '&limit=200';
    const collector: ChannelInfoItemsCollector =
      new ChannelInfoItemsCollector(this.service.getServiceId());
    // +/- 2000 is the limit of followings on SoundCloud, so this minimum should be enough
    await SoundcloudParsingHelper.getUsersFromApiMinItems(2500, collector, apiUrl);

    return SoundcloudSubscriptionExtractor.toSubscriptionItems(collector.getItems());
  }

  private static getUrlFrom(channelUrl: string): string {
    const fixedUrl: string | null = replaceHttpWithHttps(channelUrl);
    const safeUrl: string = fixedUrl === null ? channelUrl : fixedUrl;
    if (safeUrl.startsWith(HTTPS)) {
      return channelUrl;
    }
    if (!safeUrl.includes('soundcloud.com/')) {
      return 'https://soundcloud.com/' + safeUrl;
    }
    return HTTPS + safeUrl;
  }

  private static toSubscriptionItems(items: ChannelInfoItem[]): SubscriptionItem[] {
    const result: SubscriptionItem[] = [];
    for (const item of items) {
      result.push(new SubscriptionItem(item.getServiceId(), item.getUrl(), item.getName()));
    }
    return result;
  }
}
