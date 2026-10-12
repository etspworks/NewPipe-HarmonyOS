/*
 * Port of org.schabi.newpipe.extractor.services.bandcamp.extractors
 * .BandcampPlaylistInfoItemExtractor (NewPipeExtractor v0.26.5).
 */

import { Image } from '../../../../../model/extractor/Image';
import { PlaylistInfoItemExtractor } from '../../../info/PlaylistExtractor';
import { ParsingException } from '../../../exceptions/Exceptions';
import { Element } from '../../../html/Jsoup';
import { BandcampExtractorHelper } from './BandcampExtractorHelper';

export class BandcampPlaylistInfoItemExtractor extends PlaylistInfoItemExtractor {
  private readonly searchResult: Element;
  private readonly resultInfo: Element;

  constructor(searchResult: Element) {
    super();
    this.searchResult = searchResult;
    const info: Element | null = searchResult.getElementsByClass('result-info').first();
    if (info === null) {
      throw new ParsingException('Search result has no result-info element');
    }
    this.resultInfo = info;
  }

  getUploaderName(): string {
    return this.resultInfo.getElementsByClass('subhead').text().split(' by')[0];
  }

  getUploaderUrl(): string {
    return '';
  }

  isUploaderVerified(): boolean {
    return false;
  }

  getStreamCount(): number {
    const length: string = this.resultInfo.getElementsByClass('length').text();
    return Number.parseInt(length.split(' track')[0], 10);
  }

  getName(): string {
    return this.resultInfo.getElementsByClass('heading').text();
  }

  getUrl(): string {
    return this.resultInfo.getElementsByClass('itemurl').text();
  }

  getThumbnails(): Image[] {
    return BandcampExtractorHelper.getImagesFromSearchResult(this.searchResult);
  }
}
