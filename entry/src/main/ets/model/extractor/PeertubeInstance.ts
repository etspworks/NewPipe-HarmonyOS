/*
 * Port of org.schabi.newpipe.extractor.services.peertube.PeertubeInstance
 * (NewPipeExtractor v0.26.5).
 *
 * PeerTube is instance-relative: the base url is whichever instance the user picked, so this
 * type is what the instance-picker screen edits and what every PeerTube url is built from.
 * fetchInstanceMetaData() does I/O, hence the Promise.
 */

import { NewPipe } from '../../common/extractor/core/NewPipe';
import { JsonUtils } from '../../common/extractor/core/JsonUtils';
import { isBlank } from '../../common/extractor/core/Utils';
import { Downloader, Response } from '../../common/extractor/downloader/Downloader';
import { JsonObject, JsonParser } from '../../common/extractor/json/NanoJson';

export class PeertubeInstance {
  static readonly DEFAULT_INSTANCE: PeertubeInstance =
    new PeertubeInstance('https://framatube.org', 'FramaTube');

  private readonly url: string;
  private name: string;

  constructor(url: string, name: string = 'PeerTube') {
    this.url = url;
    this.name = name;
  }

  getUrl(): string {
    return this.url;
  }

  /** `GET <instance>/api/v1/config` and take `instance.name` off it. */
  async fetchInstanceMetaData(): Promise<void> {
    const downloader: Downloader | null = NewPipe.getDownloader();
    if (downloader === null) {
      throw new Error('unable to configure instance ' + this.url);
    }
    let response: Response;
    try {
      response = await downloader.get(this.url + '/api/v1/config');
    } catch (e) {
      throw new Error('unable to configure instance ' + this.url);
    }
    if (isBlank(response.responseBody())) {
      throw new Error('unable to configure instance ' + this.url);
    }
    try {
      const json: JsonObject = JsonParser.object().from(response.responseBody());
      this.name = JsonUtils.getString(json, 'instance.name');
    } catch (e) {
      throw new Error('unable to parse instance config');
    }
  }

  getName(): string {
    return this.name;
  }
}
