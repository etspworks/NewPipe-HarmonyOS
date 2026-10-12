/*
 * Port of org.schabi.newpipe.extractor.services.soundcloud.extractors
 * .SoundcloudStreamInfoItemExtractor (NewPipeExtractor v0.26.5).
 */

import { Image } from '../../../../../model/extractor/Image';
import { StreamType } from '../../../../../model/enums/StreamType';
import { StreamInfoItemExtractor } from '../../../info/StreamInfoItemExtractor';
import { replaceHttpWithHttps } from '../../../core/Utils';
import { DateWrapper } from '../../../localization/DateWrapper';
import { JsonObject } from '../../../json/NanoJson';
import { SoundcloudParsingHelper } from '../SoundcloudParsingHelper';

export class SoundcloudStreamInfoItemExtractor extends StreamInfoItemExtractor {
  protected readonly itemObject: JsonObject;

  constructor(itemObject: JsonObject) {
    super();
    this.itemObject = itemObject;
  }

  getUrl(): string {
    const url: string | null = replaceHttpWithHttps(this.itemObject.getString('permalink_url'));
    return url === null ? '' : url;
  }

  getName(): string {
    const name: string | null = this.itemObject.getString('title');
    return name === null ? '' : name;
  }

  getDuration(): number {
    return Math.floor(this.itemObject.getLong('duration') / 1000);
  }

  getUploaderName(): string {
    const name: string | null = this.itemObject.getObject('user').getString('username');
    return name === null ? '' : name;
  }

  getUploaderUrl(): string {
    const url: string | null =
      replaceHttpWithHttps(this.itemObject.getObject('user').getString('permalink_url'));
    return url === null ? '' : url;
  }

  getUploaderAvatars(): Image[] {
    return SoundcloudParsingHelper.getAllImagesFromArtworkOrAvatarUrl(
      this.itemObject.getObject('user').getString('avatar_url'));
  }

  isUploaderVerified(): boolean {
    return this.itemObject.getObject('user').getBoolean('verified');
  }

  getTextualUploadDate(): string | null {
    return this.itemObject.getString('created_at');
  }

  getUploadDate(): DateWrapper | null {
    return SoundcloudParsingHelper.parseDate(this.getTextualUploadDate());
  }

  getViewCount(): number {
    return this.itemObject.getLong('playback_count');
  }

  getThumbnails(): Image[] {
    return SoundcloudParsingHelper.getAllImagesFromTrackObject(this.itemObject);
  }

  getStreamType(): StreamType {
    return StreamType.AUDIO_STREAM;
  }

  isAd(): boolean {
    return false;
  }
}
