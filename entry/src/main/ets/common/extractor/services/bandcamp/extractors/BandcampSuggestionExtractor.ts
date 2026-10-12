/*
 * Port of org.schabi.newpipe.extractor.services.bandcamp.extractors.BandcampSuggestionExtractor
 * (NewPipeExtractor v0.26.5). Created by Fynn Godau 2019, GPL v3 or later.
 */

import { NewPipe } from '../../../core/NewPipe';
import { StreamingService } from '../../../core/StreamingService';
import { Downloader, Request } from '../../../downloader/Downloader';
import { ExtractionException } from '../../../exceptions/Exceptions';
import { SuggestionExtractor } from '../../../info/SuggestionExtractor';
import { JsonObject, JsonParser, JsonWriter } from '../../../json/NanoJson';
import { BASE_API_URL } from './BandcampExtractorHelper';

const AUTOCOMPLETE_URL: string = BASE_API_URL + '/bcsearch_public_api/1/autocomplete_elastic';

export class BandcampSuggestionExtractor extends SuggestionExtractor {
  constructor(service: StreamingService) {
    super(service);
  }

  async suggestionList(query: string): Promise<string[]> {
    const downloader: Downloader | null = NewPipe.getDownloader();
    if (downloader === null) {
      throw new ExtractionException('NewPipe was not initialised with a Downloader');
    }

    try {
      const body: ArrayBuffer = Request.utf8Body(JsonWriter.string()
        .object()
        .nul('fan_id')
        .value('full_page', false)
        .value('search_filter', '')
        .value('search_text', query)
        .end()
        .done());
      const fuzzyResults: JsonObject = JsonParser.object().from(
        (await downloader.postWithContentTypeJson(AUTOCOMPLETE_URL,
          new Map<string, string[]>(), body)).responseBody());

      const names: string[] = [];
      for (const result of fuzzyResults.getObject('auto').getArray('results')
        .streamAsJsonObjects()) {
        const name: string | null = result.getString('name');
        if (name !== null && !names.includes(name)) {
          // distinct(), as in the source
          names.push(name);
        }
      }
      return names;
    } catch (e) {
      return [];
    }
  }
}
