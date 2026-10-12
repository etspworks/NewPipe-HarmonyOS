/*
 * Port of org.schabi.newpipe.extractor.services.bandcamp.extractors.streaminfoitem
 * .BandcampSearchStreamInfoItemExtractor (NewPipeExtractor v0.26.5).
 */

import { Image } from '../../../../../../model/extractor/Image';
import { ParsingException } from '../../../../exceptions/Exceptions';
import { Element } from '../../../../html/Jsoup';
import { BandcampExtractorHelper } from '../BandcampExtractorHelper';
import { BandcampStreamInfoItemExtractor } from './BandcampStreamInfoItemExtractor';

export class BandcampSearchStreamInfoItemExtractor extends BandcampStreamInfoItemExtractor {
  private readonly searchResult: Element;
  private readonly resultInfo: Element;

  constructor(searchResult: Element, uploaderUrl: string) {
    super(uploaderUrl);
    this.searchResult = searchResult;
    const info: Element | null = searchResult.getElementsByClass('result-info').first();
    if (info === null) {
      throw new ParsingException('Search result has no result-info element');
    }
    this.resultInfo = info;
  }

  getUploaderName(): string {
    const subhead: string = this.resultInfo.getElementsByClass('subhead').text();
    const splitBy: string[] = subhead.split('by ');
    if (splitBy.length > 1) {
      return splitBy[1];
    }
    return splitBy[0];
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

  getDuration(): number {
    return -1;
  }
}
