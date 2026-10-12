/*
 * Port of org.schabi.newpipe.extractor.channel.ChannelInfo (NewPipeExtractor v0.26.5).
 *
 * The channel mapper: getInfo() sets every field the source sets, each one guarded so a failure
 * lands in errors[] rather than losing the channel.
 */

import { Info } from '../../common/extractor/core/Info';
import { toError } from '../../common/extractor/core/Errors';
import { NewPipe } from '../../common/extractor/core/NewPipe';
import { StreamingService } from '../../common/extractor/core/StreamingService';
import { ChannelExtractor } from '../../common/extractor/info/ChannelExtractor';
import { ListLinkHandler } from '../../common/extractor/linkhandler/LinkHandler';
import { Image } from './Image';

export class ChannelInfo extends Info {
  parentChannelName: string = '';
  parentChannelUrl: string = '';
  feedUrl: string | null = null;
  subscriberCount: number = -1;
  description: string = '';
  donationLinks: string[] = [];
  avatars: Image[] = [];
  banners: Image[] = [];
  parentChannelAvatars: Image[] = [];
  verified: boolean = false;
  tabs: ListLinkHandler[] = [];
  tags: string[] = [];

  constructor(serviceId: number, id: string, url: string, originalUrl: string, name: string) {
    super(serviceId, id, url, originalUrl, name);
  }

  static async getInfoFromUrl(url: string): Promise<ChannelInfo> {
    return ChannelInfo.getInfoFromService(NewPipe.getServiceByUrl(url), url);
  }

  static async getInfoFromService(service: StreamingService, url: string): Promise<ChannelInfo> {
    const extractor: ChannelExtractor = service.getChannelExtractorFromUrl(url);
    await extractor.fetchPage();
    return ChannelInfo.getInfo(extractor);
  }

  static getInfo(extractor: ChannelExtractor): ChannelInfo {
    const info: ChannelInfo = new ChannelInfo(extractor.getServiceId(), extractor.getId(),
      extractor.getUrl(), extractor.getOriginalUrl(), extractor.getName());

    try {
      info.avatars = extractor.getAvatars();
    } catch (e) {
      info.addError(toError(e));
    }
    try {
      info.banners = extractor.getBanners();
    } catch (e) {
      info.addError(toError(e));
    }
    try {
      info.feedUrl = extractor.getFeedUrl();
    } catch (e) {
      info.addError(toError(e));
    }
    try {
      info.subscriberCount = extractor.getSubscriberCount();
    } catch (e) {
      info.addError(toError(e));
    }
    try {
      info.description = extractor.getDescription();
    } catch (e) {
      info.addError(toError(e));
    }
    try {
      info.parentChannelName = extractor.getParentChannelName();
    } catch (e) {
      info.addError(toError(e));
    }
    try {
      info.parentChannelUrl = extractor.getParentChannelUrl();
    } catch (e) {
      info.addError(toError(e));
    }
    try {
      info.parentChannelAvatars = extractor.getParentChannelAvatars();
    } catch (e) {
      info.addError(toError(e));
    }
    try {
      info.verified = extractor.isVerified();
    } catch (e) {
      info.addError(toError(e));
    }
    try {
      info.tabs = extractor.getTabs();
    } catch (e) {
      info.addError(toError(e));
    }
    try {
      info.tags = extractor.getTags();
    } catch (e) {
      info.addError(toError(e));
    }

    return info;
  }

  getParentChannelName(): string {
    return this.parentChannelName;
  }

  getParentChannelUrl(): string {
    return this.parentChannelUrl;
  }

  getParentChannelAvatars(): Image[] {
    return this.parentChannelAvatars;
  }

  getAvatars(): Image[] {
    return this.avatars;
  }

  getBanners(): Image[] {
    return this.banners;
  }

  getFeedUrl(): string | null {
    return this.feedUrl;
  }

  getSubscriberCount(): number {
    return this.subscriberCount;
  }

  getDescription(): string {
    return this.description;
  }

  getDonationLinks(): string[] {
    return this.donationLinks;
  }

  getIsVerified(): boolean {
    return this.verified;
  }

  getTabs(): ListLinkHandler[] {
    return this.tabs;
  }

  getTags(): string[] {
    return this.tags;
  }
}
