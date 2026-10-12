/*
 * Port of org.schabi.newpipe.extractor.services.bandcamp.extractors.streaminfoitem
 * .BandcampDiscographStreamInfoItemExtractor (NewPipeExtractor v0.26.5).
 */

import { Image } from '../../../../../../model/extractor/Image';
import { JsonObject } from '../../../../json/NanoJson';
import { BandcampExtractorHelper } from '../BandcampExtractorHelper';
import { BandcampStreamInfoItemExtractor } from './BandcampStreamInfoItemExtractor';

export class BandcampDiscographStreamInfoItemExtractor extends BandcampStreamInfoItemExtractor {
  private readonly discograph: JsonObject;

  constructor(discograph: JsonObject, uploaderUrl: string) {
    super(uploaderUrl);
    this.discograph = discograph;
  }

  /** Primes the memo getUrl() reads: the mobile API translates the ids into a URL. */
  async resolveUrl(): Promise<void> {
    await BandcampExtractorHelper.resolveStreamUrlFromIds(this.discograph.getLong('band_id'),
      this.discograph.getLong('item_id'), this.itemType());
  }

  private itemType(): string {
    const itemType: string | null = this.discograph.getString('item_type');
    return itemType === null ? '' : itemType;
  }

  getUploaderName(): string {
    const name: string | null = this.discograph.getString('band_name');
    return name === null ? '' : name;
  }

  getName(): string {
    const name: string | null = this.discograph.getString('title');
    return name === null ? '' : name;
  }

  getUrl(): string {
    return BandcampExtractorHelper.getStreamUrlFromIds(this.discograph.getLong('band_id'),
      this.discograph.getLong('item_id'), this.itemType());
  }

  getThumbnails(): Image[] {
    return BandcampExtractorHelper.getImagesFromImageId(this.discograph.getLong('art_id'), true);
  }

  getDuration(): number {
    return -1;
  }
}
