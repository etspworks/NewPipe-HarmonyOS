/*
 * Port of org.schabi.newpipe.extractor.services.peertube.extractors
 * .PeertubeChannelInfoItemExtractor (NewPipeExtractor v0.26.5).
 */

import { ChannelInfoItemExtractor } from '../../../info/ChannelExtractor';
import { ITEM_COUNT_UNKNOWN } from '../../../core/ListExtractor';
import { JsonObject } from '../../../json/NanoJson';
import { Image } from '../../../../../model/extractor/Image';
import {
  getAvatarsFromOwnerAccountOrVideoChannelObject,
  nonNullString
} from '../PeertubeParsingHelper';

export class PeertubeChannelInfoItemExtractor extends ChannelInfoItemExtractor {
  private readonly item: JsonObject;
  private readonly baseUrl: string;

  constructor(item: JsonObject, baseUrl: string) {
    super();
    this.item = item;
    this.baseUrl = baseUrl;
  }

  getName(): string {
    return nonNullString(this.item.getString('displayName'));
  }

  getUrl(): string {
    return nonNullString(this.item.getString('url'));
  }

  getThumbnails(): Image[] {
    return getAvatarsFromOwnerAccountOrVideoChannelObject(this.baseUrl, this.item);
  }

  getDescription(): string {
    return nonNullString(this.item.getString('description'));
  }

  getSubscriberCount(): number {
    return this.item.getInt('followersCount');
  }

  getStreamCount(): number {
    return ITEM_COUNT_UNKNOWN;
  }

  isVerified(): boolean {
    return false;
  }
}
