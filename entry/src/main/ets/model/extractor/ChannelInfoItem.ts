/*
 * Port of org.schabi.newpipe.extractor.channel.ChannelInfoItem (NewPipeExtractor v0.26.5).
 */

import { InfoItem, InfoType } from '../../common/extractor/core/InfoItem';

export class ChannelInfoItem extends InfoItem {
  description: string = '';
  subscriberCount: number = -1;
  streamCount: number = -1;
  verified: boolean = false;

  constructor(serviceId: number, url: string, name: string) {
    super(InfoType.CHANNEL, serviceId, url, name);
  }

  getDescription(): string {
    return this.description;
  }

  setDescription(description: string): void {
    this.description = description;
  }

  getSubscriberCount(): number {
    return this.subscriberCount;
  }

  setSubscriberCount(subscriberCount: number): void {
    this.subscriberCount = subscriberCount;
  }

  getStreamCount(): number {
    return this.streamCount;
  }

  setStreamCount(streamCount: number): void {
    this.streamCount = streamCount;
  }

  getIsVerified(): boolean {
    return this.verified;
  }

  setVerified(verified: boolean): void {
    this.verified = verified;
  }
}
