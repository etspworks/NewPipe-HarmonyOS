/*
 * Port of org.schabi.newpipe.extractor.services.youtube.extractors.YoutubeSuggestionExtractor
 * (NewPipeExtractor v0.26.5).
 *
 * suggestionList() does I/O, so it is a Promise (phase2-logic-contract.md §1). The search screen
 * debounces keystrokes over the ported Observable and awaits this per keystroke.
 */

import { JsonArray, JsonParser, JsonValue } from '../../../json/NanoJson';
import { Downloader, HeaderMap, Response } from '../../../downloader/Downloader';
import { NewPipe } from '../../../core/NewPipe';
import { StreamingService } from '../../../core/StreamingService';
import { SuggestionExtractor } from '../../../info/SuggestionExtractor';
import { ExtractionException, ParsingException } from '../../../exceptions/Exceptions';
import { encodeUrlUtf8, isBlank, isNullOrEmpty } from '../../../core/Utils';

export class YoutubeSuggestionExtractor extends SuggestionExtractor {
  constructor(service: StreamingService) {
    super(service);
  }

  async suggestionList(query: string): Promise<string[]> {
    const url: string = 'https://suggestqueries-clients6.youtube.com/complete/search'
      + '?client=' + 'youtube'
      + '&ds=' + 'yt'
      + '&gl=' + encodeUrlUtf8(this.getExtractorContentCountry().getCountryCode())
      + '&q=' + encodeUrlUtf8(query)
      + '&xhr=t';

    const headers: HeaderMap = new Map<string, string[]>();
    headers.set('Origin', ['https://www.youtube.com']);
    headers.set('Referer', ['https://www.youtube.com']);

    const downloader: Downloader | null = NewPipe.getDownloader();
    if (downloader === null) {
      throw new ExtractionException('Downloader is not initialised');
    }
    const response: Response =
      await downloader.get(url, headers, this.getExtractorLocalization());

    const contentTypeHeader: string | null = response.getHeader('Content-Type');
    if (isNullOrEmpty(contentTypeHeader)
      || !(contentTypeHeader as string).includes('application/json')) {
      throw new ExtractionException('Invalid response type (got \"' + contentTypeHeader
        + '\", excepted a JSON response) (response code ' + response.responseCode() + ')');
    }

    const responseBody: string = response.responseBody();
    if (responseBody.length === 0) {
      throw new ExtractionException('Empty response received');
    }

    try {
      // 0: search query, 1: search suggestions, 2: tracking data?
      const suggestions: JsonArray = JsonParser.array().from(responseBody).getArray(1);
      const result: string[] = [];
      for (let i = 0; i < suggestions.size(); i++) {
        const entry: JsonValue | null = suggestions.get(i);
        if (!(entry instanceof JsonArray)) {
          continue;
        }
        // index 0 of each entry is the search suggestion itself
        const suggestion: string | null = (entry as JsonArray).getString(0);
        if (!isBlank(suggestion)) {
          result.push(suggestion as string);
        }
      }
      return result;
    } catch (e) {
      throw new ParsingException('Could not parse JSON response',
        e instanceof Error ? e as Error : null);
    }
  }
}
