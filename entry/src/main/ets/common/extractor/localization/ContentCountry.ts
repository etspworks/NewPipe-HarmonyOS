/*
 * Port of org.schabi.newpipe.extractor.localization.ContentCountry (NewPipeExtractor v0.26.5).
 *
 * Localization itself is NOT re-ported here: wave A wrote it at
 * common/extractor/downloader/Localization.ts (Request builds its Accept-Language header from it)
 * and this package imports it from there.
 */

import { Localization } from '../downloader/Localization';

export class ContentCountry {
  static readonly DEFAULT: ContentCountry = new ContentCountry(Localization.DEFAULT.getCountryCode());

  private readonly countryCode: string;

  constructor(countryCode: string) {
    this.countryCode = countryCode;
  }

  static listFrom(countryCodeList: string[]): ContentCountry[] {
    const toReturn: ContentCountry[] = [];
    for (const countryCode of countryCodeList) {
      toReturn.push(new ContentCountry(countryCode));
    }
    return toReturn;
  }

  getCountryCode(): string {
    return this.countryCode;
  }

  toString(): string {
    return this.getCountryCode();
  }

  equals(other: ContentCountry | null): boolean {
    return other !== null && this.countryCode === other.getCountryCode();
  }
}
