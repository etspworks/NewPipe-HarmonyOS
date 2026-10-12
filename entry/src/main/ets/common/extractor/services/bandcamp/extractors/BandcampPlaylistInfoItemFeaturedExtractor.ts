/*
 * Port of org.schabi.newpipe.extractor.services.bandcamp.extractors
 * .BandcampPlaylistInfoItemFeaturedExtractor (NewPipeExtractor v0.26.5).
 */

import { Image } from '../../../../../model/extractor/Image';
import { PlaylistInfoItemExtractor } from '../../../info/PlaylistExtractor';
import { replaceHttpWithHttps } from '../../../core/Utils';
import { JsonObject } from '../../../json/NanoJson';
import { BandcampExtractorHelper } from './BandcampExtractorHelper';

export class BandcampPlaylistInfoItemFeaturedExtractor extends PlaylistInfoItemExtractor {
  private readonly featuredStory: JsonObject;

  constructor(featuredStory: JsonObject) {
    super();
    this.featuredStory = featuredStory;
  }

  getUploaderName(): string {
    const name: string | null = this.featuredStory.getString('band_name');
    return name === null ? '' : name;
  }

  getUploaderUrl(): string {
    return '';
  }

  isUploaderVerified(): boolean {
    return false;
  }

  getStreamCount(): number {
    return this.featuredStory.getInt('num_streamable_tracks');
  }

  getName(): string {
    const name: string | null = this.featuredStory.getString('album_title');
    return name === null ? '' : name;
  }

  getUrl(): string {
    const url: string | null = replaceHttpWithHttps(this.featuredStory.getString('item_url'));
    return url === null ? '' : url;
  }

  getThumbnails(): Image[] {
    return this.featuredStory.has('art_id')
      ? BandcampExtractorHelper.getImagesFromImageId(this.featuredStory.getLong('art_id'), true)
      : BandcampExtractorHelper.getImagesFromImageId(
        this.featuredStory.getLong('item_art_id'), true);
  }
}
