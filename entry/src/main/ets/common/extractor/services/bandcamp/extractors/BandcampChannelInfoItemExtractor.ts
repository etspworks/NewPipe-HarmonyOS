/*
 * Port of org.schabi.newpipe.extractor.services.bandcamp.extractors
 * .BandcampChannelInfoItemExtractor (NewPipeExtractor v0.26.5).
 */

import { Image } from '../../../../../model/extractor/Image';
import { ChannelInfoItemExtractor } from '../../../info/ChannelExtractor';
import { ParsingException } from '../../../exceptions/Exceptions';
import { Element } from '../../../html/Jsoup';
import { BandcampExtractorHelper } from './BandcampExtractorHelper';

export class BandcampChannelInfoItemExtractor extends ChannelInfoItemExtractor {
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

  getName(): string {
    return this.resultInfo.getElementsByClass('heading').text();
  }

  getUrl(): string {
    return this.resultInfo.getElementsByClass('itemurl').text();
  }

  getThumbnails(): Image[] {
    return BandcampExtractorHelper.getImagesFromSearchResult(this.searchResult);
  }

  getDescription(): string {
    return this.resultInfo.getElementsByClass('subhead').text();
  }

  getSubscriberCount(): number {
    return -1;
  }

  getStreamCount(): number {
    return -1;
  }

  isVerified(): boolean {
    return false;
  }
}
