/*
 * Port of org.schabi.newpipe.extractor.services.peertube.extractors
 * .PeertubePlaylistInfoItemExtractor (NewPipeExtractor v0.26.5).
 */

import { PlaylistInfoItemExtractor } from '../../../info/PlaylistExtractor';
import { JsonObject } from '../../../json/NanoJson';
import { isNullOrEmpty } from '../../../core/Utils';
import { Image } from '../../../../../model/extractor/Image';
import { Description, DESCRIPTION_PLAIN_TEXT } from '../../../../../model/extractor/Description';
import { getThumbnailsFromPlaylistOrVideoItem, nonNullString } from '../PeertubeParsingHelper';

export class PeertubePlaylistInfoItemExtractor extends PlaylistInfoItemExtractor {
  private readonly item: JsonObject;
  private readonly uploader: JsonObject;
  private readonly baseUrl: string;

  constructor(item: JsonObject, baseUrl: string) {
    super();
    this.item = item;
    this.uploader = item.getObject('uploader');
    this.baseUrl = baseUrl;
  }

  getName(): string {
    return nonNullString(this.item.getString('displayName'));
  }

  getUrl(): string {
    return nonNullString(this.item.getString('url'));
  }

  getThumbnails(): Image[] {
    return getThumbnailsFromPlaylistOrVideoItem(this.baseUrl, this.item);
  }

  getUploaderName(): string {
    return nonNullString(this.uploader.getString('displayName'));
  }

  getUploaderUrl(): string {
    return nonNullString(this.uploader.getString('url'));
  }

  isUploaderVerified(): boolean {
    return false;
  }

  getStreamCount(): number {
    return this.item.getInt('videosLength');
  }

  getDescription(): Description {
    const description: string | null = this.item.getString('description');
    if (isNullOrEmpty(description)) {
      return Description.EMPTY_DESCRIPTION;
    }
    return new Description(description, DESCRIPTION_PLAIN_TEXT);
  }
}
