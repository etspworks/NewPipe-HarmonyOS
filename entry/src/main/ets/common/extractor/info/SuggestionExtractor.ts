/*
 * Port of org.schabi.newpipe.extractor.suggestion.SuggestionExtractor
 * (NewPipeExtractor v0.26.5).
 *
 * suggestionList() does I/O, so it is a Promise (phase2-logic-contract.md §1). The search screen
 * debounces keystrokes over the ported Observable and awaits this per keystroke.
 */

import { StreamingService } from '../core/StreamingService';
import { ContentCountry } from '../localization/ContentCountry';
import { Localization } from '../downloader/Localization';

export abstract class SuggestionExtractor {
  private readonly service: StreamingService;
  private forcedLocalization: Localization | null = null;
  private forcedContentCountry: ContentCountry | null = null;

  constructor(service: StreamingService) {
    this.service = service;
  }

  abstract suggestionList(query: string): Promise<string[]>;

  getServiceId(): number {
    return this.service.getServiceId();
  }

  getService(): StreamingService {
    return this.service;
  }

  forceLocalization(localization: Localization | null): void {
    this.forcedLocalization = localization;
  }

  forceContentCountry(contentCountry: ContentCountry | null): void {
    this.forcedContentCountry = contentCountry;
  }

  getExtractorLocalization(): Localization {
    return this.forcedLocalization === null
      ? this.getService().getLocalization() : this.forcedLocalization;
  }

  getExtractorContentCountry(): ContentCountry {
    return this.forcedContentCountry === null
      ? this.getService().getContentCountry() : this.forcedContentCountry;
  }
}
