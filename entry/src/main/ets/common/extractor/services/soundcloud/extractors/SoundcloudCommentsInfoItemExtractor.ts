/*
 * Port of org.schabi.newpipe.extractor.services.soundcloud.extractors
 * .SoundcloudCommentsInfoItemExtractor (NewPipeExtractor v0.26.5).
 */

import { Description, DESCRIPTION_PLAIN_TEXT } from '../../../../../model/extractor/Description';
import { Image } from '../../../../../model/extractor/Image';
import { CommentsInfoItemExtractor } from '../../../info/CommentsExtractor';
import { DateWrapper } from '../../../localization/DateWrapper';
import { JsonObject } from '../../../json/NanoJson';
import { SoundcloudParsingHelper } from '../SoundcloudParsingHelper';

export class SoundcloudCommentsInfoItemExtractor extends CommentsInfoItemExtractor {
  private readonly json: JsonObject;
  private readonly url: string;

  constructor(json: JsonObject, url: string) {
    super();
    this.json = json;
    this.url = url;
  }

  getCommentId(): string {
    return `${this.json.getLong('id')}`;
  }

  getCommentText(): Description {
    return new Description(this.json.getString('body'), DESCRIPTION_PLAIN_TEXT);
  }

  getUploaderName(): string {
    const name: string | null = this.json.getObject('user').getString('username');
    return name === null ? '' : name;
  }

  getUploaderAvatars(): Image[] {
    return SoundcloudParsingHelper.getAllImagesFromArtworkOrAvatarUrl(
      this.json.getObject('user').getString('avatar_url'));
  }

  isUploaderVerified(): boolean {
    return this.json.getObject('user').getBoolean('verified');
  }

  getStreamPosition(): number {
    // convert milliseconds to seconds
    return Math.floor(this.json.getInt('timestamp') / 1000);
  }

  getUploaderUrl(): string {
    const url: string | null = this.json.getObject('user').getString('permalink_url');
    return url === null ? '' : url;
  }

  getTextualUploadDate(): string {
    const date: string | null = this.json.getString('created_at');
    return date === null ? '' : date;
  }

  getUploadDate(): DateWrapper | null {
    return SoundcloudParsingHelper.parseDate(this.json.getString('created_at'));
  }

  getName(): string {
    const name: string | null = this.json.getObject('user').getString('permalink');
    return name === null ? '' : name;
  }

  getUrl(): string {
    return this.url;
  }

  getThumbnails(): Image[] {
    return SoundcloudParsingHelper.getAllImagesFromArtworkOrAvatarUrl(
      this.json.getObject('user').getString('avatar_url'));
  }
}
