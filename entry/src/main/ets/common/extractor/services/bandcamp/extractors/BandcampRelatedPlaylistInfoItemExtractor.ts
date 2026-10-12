/*
 * Port of org.schabi.newpipe.extractor.services.bandcamp.extractors
 * .BandcampRelatedPlaylistInfoItemExtractor (NewPipeExtractor v0.26.5).
 *
 * Extracts recommended albums from tracks' website.
 */

import { Image } from '../../../../../model/extractor/Image';
import { PlaylistInfoItemExtractor } from '../../../info/PlaylistExtractor';
import { Element } from '../../../html/Jsoup';
import { BandcampExtractorHelper } from './BandcampExtractorHelper';

export class BandcampRelatedPlaylistInfoItemExtractor extends PlaylistInfoItemExtractor {
  private readonly relatedAlbum: Element;

  constructor(relatedAlbum: Element) {
    super();
    this.relatedAlbum = relatedAlbum;
  }

  getName(): string {
    return this.relatedAlbum.getElementsByClass('release-title').text();
  }

  getUrl(): string {
    const link: Element | null = this.relatedAlbum.getElementsByClass('album-link').first();
    return link === null ? '' : link.absUrl('href');
  }

  getThumbnails(): Image[] {
    return BandcampExtractorHelper.getImagesFromImageUrl(
      this.relatedAlbum.getElementsByClass('album-art').attr('src'));
  }

  getUploaderName(): string {
    return this.relatedAlbum.getElementsByClass('by-artist').text().replace('by ', '');
  }

  getUploaderUrl(): string {
    return '';
  }

  isUploaderVerified(): boolean {
    return false;
  }

  getStreamCount(): number {
    return -1;
  }
}
