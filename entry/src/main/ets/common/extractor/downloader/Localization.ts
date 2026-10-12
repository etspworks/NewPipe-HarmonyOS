/*
 * Port of org.schabi.newpipe.extractor.localization.Localization (NewPipeExtractor v0.26.5).
 *
 * It lives beside the Downloader because Request builds the Accept-Language header from it and
 * the downloader layer is ported first. Later extractor waves must IMPORT it from here rather
 * than porting a second copy.
 */

export class Localization {
  static readonly DEFAULT: Localization = new Localization('en', 'GB');

  private readonly languageCode: string;
  private readonly countryCode: string | null;

  constructor(languageCode: string, countryCode: string | null = null) {
    this.languageCode = languageCode;
    this.countryCode = countryCode;
  }

  getLanguageCode(): string {
    return this.languageCode;
  }

  /** Empty string when the localization carries no country, as in the source. */
  getCountryCode(): string {
    return this.countryCode === null ? '' : this.countryCode;
  }

  /** `language` or `language-COUNTRY`. */
  getLocalizationCode(): string {
    return this.languageCode + (this.countryCode === null ? '' : '-' + this.countryCode);
  }

  toString(): string {
    return `Localization[${this.getLocalizationCode()}]`;
  }

  equals(other: Localization): boolean {
    return this.languageCode === other.languageCode && this.getCountryCode() === other.getCountryCode();
  }

  /**
   * Port of fromLocalizationCode() via LocaleCompat.forLanguageTag(): accepts BCP-47 (`en-GB`)
   * and the underscore spelling HarmonyOS resource qualifiers use (`en_GB`). Returns null for a
   * code that has no language part, matching the empty Optional the source returns.
   */
  static fromLocalizationCode(localizationCode: string): Localization | null {
    const normalized: string = localizationCode.replace('_', '-').trim();
    if (normalized.length === 0) {
      return null;
    }
    const parts: string[] = normalized.split('-');
    const language: string = parts[0].toLowerCase();
    if (language.length === 0) {
      return null;
    }
    if (parts.length < 2 || parts[1].length === 0) {
      return new Localization(language);
    }
    return new Localization(language, parts[1].toUpperCase());
  }
}
