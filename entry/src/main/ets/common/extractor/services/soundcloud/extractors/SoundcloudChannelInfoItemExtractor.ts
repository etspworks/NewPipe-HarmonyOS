/*
 * Port of org.schabi.newpipe.extractor.services.soundcloud.extractors
 * .SoundcloudChannelInfoItemExtractor (NewPipeExtractor v0.26.5).
 */

import { Image } from '../../../../../model/extractor/Image';
import { ChannelInfoItemExtractor } from '../../../info/ChannelExtractor';
import { replaceHttpWithHttps } from '../../../core/Utils';
import { JsonObject } from '../../../json/NanoJson';
import { SoundcloudParsingHelper } from '../SoundcloudParsingHelper';

export class SoundcloudChannelInfoItemExtractor extends ChannelInfoItemExtractor {
  private readonly itemObject: JsonObject;

  constructor(itemObject: JsonObject) {
    super();
    this.itemObject = itemObject;
  }

  getName(): string {
    const name: string | null = this.itemObject.getString('username');
    return name === null ? '' : name;
  }

  getUrl(): string {
    const url: string | null = replaceHttpWithHttps(this.itemObject.getString('permalink_url'));
    return url === null ? '' : url;
  }

  getThumbnails(): Image[] {
    return SoundcloudParsingHelper.getAllImagesFromArtworkOrAvatarUrl(
      this.itemObject.getString('avatar_url'));
  }

  getSubscriberCount(): number {
    return this.itemObject.getLong('followers_count');
  }

  getStreamCount(): number {
    return this.itemObject.getLong('track_count');
  }

  isVerified(): boolean {
    return this.itemObject.getBoolean('verified');
  }

  getDescription(): string {
    const description: string | null = this.itemObject.getString('description', '');
    return description === null ? '' : description;
  }
}
