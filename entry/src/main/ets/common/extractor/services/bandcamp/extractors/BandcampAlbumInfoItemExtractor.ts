/*
 * Port of org.schabi.newpipe.extractor.services.bandcamp.extractors
 * .BandcampAlbumInfoItemExtractor (NewPipeExtractor v0.26.5).
 */

import { Image } from '../../../../../model/extractor/Image';
import { ITEM_COUNT_UNKNOWN } from '../../../core/ListExtractor';
import { PlaylistInfoItemExtractor } from '../../../info/PlaylistExtractor';
import { JsonObject } from '../../../json/NanoJson';
import { BandcampExtractorHelper } from './BandcampExtractorHelper';

export class BandcampAlbumInfoItemExtractor extends PlaylistInfoItemExtractor {
  private readonly albumInfoItem: JsonObject;
  private readonly uploaderUrl: string;

  constructor(albumInfoItem: JsonObject, uploaderUrl: string) {
    super();
    this.albumInfoItem = albumInfoItem;
    this.uploaderUrl = uploaderUrl;
  }

  private itemType(): string {
    const itemType: string | null = this.albumInfoItem.getString('item_type');
    return itemType === null ? '' : itemType;
  }

  /** Primes the memo getUrl() reads; see BandcampExtractorHelper's header. */
  async resolveUrl(): Promise<void> {
    await BandcampExtractorHelper.resolveStreamUrlFromIds(this.albumInfoItem.getLong('band_id'),
      this.albumInfoItem.getLong('item_id'), this.itemType());
  }

  getName(): string {
    const name: string | null = this.albumInfoItem.getString('title');
    return name === null ? '' : name;
  }

  getUrl(): string {
    return BandcampExtractorHelper.getStreamUrlFromIds(this.albumInfoItem.getLong('band_id'),
      this.albumInfoItem.getLong('item_id'), this.itemType());
  }

  getThumbnails(): Image[] {
    return BandcampExtractorHelper.getImagesFromImageId(this.albumInfoItem.getLong('art_id'),
      true);
  }

  getUploaderName(): string {
    const name: string | null = this.albumInfoItem.getString('band_name');
    return name === null ? '' : name;
  }

  getUploaderUrl(): string {
    return this.uploaderUrl;
  }

  isUploaderVerified(): boolean {
    return false;
  }

  getStreamCount(): number {
    return ITEM_COUNT_UNKNOWN;
  }
}
