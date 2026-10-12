/*
 * Port of org.schabi.newpipe.extractor.services.bandcamp.linkHandler
 * .BandcampFeaturedLinkHandlerFactory (NewPipeExtractor v0.26.5).
 * Created by Fynn Godau 2019, GPL v3 or later.
 */

import { ListLinkHandlerFactory } from '../../../linkhandler/LinkHandlerFactory';
import { replaceHttpWithHttps } from '../../../core/Utils';
import { ParsingException } from '../../../exceptions/Exceptions';
import { BandcampExtractorHelper } from '../extractors/BandcampExtractorHelper';
import { FEATURED_API_URL, KIOSK_FEATURED } from '../extractors/BandcampFeaturedExtractor';
import { KIOSK_RADIO, RADIO_API_URL } from '../extractors/BandcampRadioExtractor';

export class BandcampFeaturedLinkHandlerFactory extends ListLinkHandlerFactory {
  private static readonly INSTANCE: BandcampFeaturedLinkHandlerFactory =
    new BandcampFeaturedLinkHandlerFactory();

  static getInstance(): BandcampFeaturedLinkHandlerFactory {
    return BandcampFeaturedLinkHandlerFactory.INSTANCE;
  }

  getUrlWithFilters(id: string, contentFilter: string[], sortFilter: string,
    baseUrl: string | null = null): string {
    if (id === KIOSK_FEATURED) {
      return FEATURED_API_URL; // doesn't have a website
    }
    if (id === KIOSK_RADIO) {
      return RADIO_API_URL; // doesn't have its own website
    }
    // The source returns null; the ported signature is non-nullable, so this raises instead.
    throw new ParsingException('Not a Bandcamp kiosk id: ' + id);
  }

  getId(url: string): string {
    const https: string | null = replaceHttpWithHttps(url);
    const fixedUrl: string = https === null ? url : https;
    if (BandcampExtractorHelper.isRadioUrl(fixedUrl) || fixedUrl === RADIO_API_URL) {
      return KIOSK_RADIO;
    }
    if (fixedUrl === FEATURED_API_URL) {
      return KIOSK_FEATURED;
    }
    // The source returns null; the ported signature is non-nullable, so this raises instead.
    throw new ParsingException('Not a Bandcamp kiosk url: ' + url);
  }

  onAcceptUrl(url: string): boolean {
    const https: string | null = replaceHttpWithHttps(url);
    const fixedUrl: string = https === null ? url : https;
    return fixedUrl === FEATURED_API_URL
      || fixedUrl === RADIO_API_URL
      || BandcampExtractorHelper.isRadioUrl(fixedUrl);
  }
}
