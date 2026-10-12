/*
 * Port of org.schabi.newpipe.extractor.services.soundcloud.extractors
 * .SoundcloudSuggestionExtractor (NewPipeExtractor v0.26.5).
 */

import { NewPipe } from '../../../core/NewPipe';
import { StreamingService } from '../../../core/StreamingService';
import { encodeUrlUtf8 } from '../../../core/Utils';
import { Downloader } from '../../../downloader/Downloader';
import { ExtractionException, ParsingException } from '../../../exceptions/Exceptions';
import { SuggestionExtractor } from '../../../info/SuggestionExtractor';
import { JsonArray, JsonParser } from '../../../json/NanoJson';
import { SOUNDCLOUD_API_V2_URL, SoundcloudParsingHelper } from '../SoundcloudParsingHelper';

export class SoundcloudSuggestionExtractor extends SuggestionExtractor {
  constructor(service: StreamingService) {
    super(service);
  }

  async suggestionList(query: string): Promise<string[]> {
    const suggestions: string[] = [];
    const dl: Downloader | null = NewPipe.getDownloader();
    if (dl === null) {
      throw new ExtractionException('NewPipe was not initialised with a Downloader');
    }
    const url: string = SOUNDCLOUD_API_V2_URL + 'search/queries?q='
      + encodeUrlUtf8(query) + '&client_id=' + await SoundcloudParsingHelper.clientId()
      + '&limit=10';
    const response: string =
      (await dl.get(url, null, this.getExtractorLocalization())).responseBody();

    try {
      const collection: JsonArray = JsonParser.object().from(response).getArray('collection');
      for (const suggestion of collection.streamAsJsonObjects()) {
        const value: string | null = suggestion.getString('query');
        if (value !== null) {
          suggestions.push(value);
        }
      }

      return suggestions;
    } catch (e) {
      throw new ParsingException('Could not parse json response',
        e instanceof Error ? e as Error : null);
    }
  }
}
