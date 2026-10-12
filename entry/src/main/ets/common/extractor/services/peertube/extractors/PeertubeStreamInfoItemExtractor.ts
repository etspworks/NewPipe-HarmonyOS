/*
 * Port of org.schabi.newpipe.extractor.services.peertube.extractors
 * .PeertubeStreamInfoItemExtractor (NewPipeExtractor v0.26.5).
 */

import { StreamInfoItemExtractor } from '../../../info/StreamInfoItemExtractor';
import { JsonObject } from '../../../json/NanoJson';
import { JsonUtils } from '../../../core/JsonUtils';
import { DateWrapper } from '../../../localization/DateWrapper';
import { Image } from '../../../../../model/extractor/Image';
import { StreamType } from '../../../../../model/enums/StreamType';
import {
  getAvatarsFromOwnerAccountOrVideoChannelObject,
  getThumbnailsFromPlaylistOrVideoItem
} from '../PeertubeParsingHelper';
import {
  PeertubeChannelLinkHandlerFactory
} from '../linkHandler/PeertubeChannelLinkHandlerFactory';
import { PeertubeStreamLinkHandlerFactory } from '../linkHandler/PeertubeStreamLinkHandlerFactory';

export class PeertubeStreamInfoItemExtractor extends StreamInfoItemExtractor {
  protected readonly item: JsonObject;
  private baseUrl: string;

  constructor(item: JsonObject, baseUrl: string) {
    super();
    this.item = item;
    this.baseUrl = baseUrl;
  }

  getUrl(): string {
    const uuid: string = JsonUtils.getString(this.item, 'uuid');
    return PeertubeStreamLinkHandlerFactory.getInstance().fromId(uuid, this.baseUrl).getUrl();
  }

  getThumbnails(): Image[] {
    return getThumbnailsFromPlaylistOrVideoItem(this.baseUrl, this.item);
  }

  getName(): string {
    return JsonUtils.getString(this.item, 'name');
  }

  isAd(): boolean {
    return false;
  }

  getViewCount(): number {
    return this.item.getLong('views');
  }

  getUploaderUrl(): string {
    const name: string = JsonUtils.getString(this.item, 'account.name');
    const host: string = JsonUtils.getString(this.item, 'account.host');

    return PeertubeChannelLinkHandlerFactory.getInstance()
      .fromId('accounts/' + name + '@' + host, this.baseUrl).getUrl();
  }

  getUploaderAvatars(): Image[] {
    return getAvatarsFromOwnerAccountOrVideoChannelObject(this.baseUrl,
      this.item.getObject('account'));
  }

  isUploaderVerified(): boolean {
    return false;
  }

  getUploaderName(): string {
    return JsonUtils.getString(this.item, 'account.displayName');
  }

  getTextualUploadDate(): string | null {
    return JsonUtils.getString(this.item, 'publishedAt');
  }

  getUploadDate(): DateWrapper | null {
    return DateWrapper.fromInstant(this.getTextualUploadDate());
  }

  getStreamType(): StreamType {
    return this.item.getBoolean('isLive') ? StreamType.LIVE_STREAM : StreamType.VIDEO_STREAM;
  }

  getDuration(): number {
    return this.item.getLong('duration');
  }

  protected setBaseUrl(baseUrl: string): void {
    this.baseUrl = baseUrl;
  }
}
