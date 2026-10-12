/*
 * Port of org.schabi.newpipe.extractor.services.peertube.extractors
 * .PeertubeSuggestionExtractor (NewPipeExtractor v0.26.5).
 *
 * PeerTube has no search-suggestion endpoint; the source returns an empty list.
 */

import { SuggestionExtractor } from '../../../info/SuggestionExtractor';
import { StreamingService } from '../../../core/StreamingService';

export class PeertubeSuggestionExtractor extends SuggestionExtractor {
  constructor(service: StreamingService) {
    super(service);
  }

  async suggestionList(query: string): Promise<string[]> {
    return [];
  }
}
