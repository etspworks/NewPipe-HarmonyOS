/*
 * Port of org.schabi.newpipe.extractor.services.youtube.extractors.YoutubeSubscriptionExtractor
 * (NewPipeExtractor v0.26.5).
 *
 * Imports a Google Takeout subscription export. The ported SubscriptionExtractor base takes the
 * picked file's CONTENT (text, or raw bytes for a binary export) plus its content type instead of
 * an InputStream, so all three source paths are ported:
 *  - JSON and CSV read the text directly;
 *  - ZIP (java.util.zip.ZipInputStream in the source) has no in-memory analogue on HarmonyOS:
 *    `@ohos.zlib` only decompresses FILE to DIRECTORY. The bytes are therefore written to a
 *    scratch file under the caller's temp dir, decompressed there, and every extracted *.csv is
 *    tried in turn exactly as the source's loop does. The scratch files are removed in `finally`.
 */

import { fileIo } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import { JsonArray, JsonObject, JsonParser, JsonValue } from '../../../json/NanoJson';
import {
  ContentSource,
  InvalidSourceException,
  SubscriptionExtractor,
  SubscriptionItem,
  subscriptionContentAsText
} from '../../../info/SubscriptionExtractor';
import { StreamingService } from '../../../core/StreamingService';

const BASE_CHANNEL_URL: string = 'https://www.youtube.com/channel/';

export class YoutubeSubscriptionExtractor extends SubscriptionExtractor {
  constructor(youtubeService: StreamingService) {
    super(youtubeService, [ContentSource.INPUT_STREAM]);
  }

  getRelatedUrl(): string {
    return 'https://takeout.google.com/takeout/custom/youtube';
  }

  /** Port of the two fromInputStream overloads; an empty content type means JSON, as there. */
  async fromFileContent(content: string | ArrayBuffer, contentType: string = '',
    tempDir: string = ''): Promise<SubscriptionItem[]> {
    if (contentType === 'zip' || contentType === 'application/zip') {
      return this.fromZipContent(content, tempDir);
    }
    const text: string = subscriptionContentAsText(content);
    if (contentType.length === 0 || contentType === 'json'
      || contentType === 'application/json') {
      return this.fromJsonContent(text);
    }
    if (contentType === 'csv' || contentType === 'text/csv'
      || contentType === 'text/comma-separated-values') {
      return this.fromCsvContent(text);
    }
    throw new InvalidSourceException('Unsupported content type: ' + contentType);
  }

  /**
   * Port of fromZipInputStream(): walk the archive's *.csv entries and return the first that
   * yields items, ignoring the ones that do not — a Takeout ZIP carries several CSVs, only one of
   * which is the subscription list.
   */
  async fromZipContent(content: string | ArrayBuffer,
    tempDir: string): Promise<SubscriptionItem[]> {
    if (typeof content === 'string' || tempDir.length === 0) {
      // A zip read as text is already corrupt, and unzipping needs somewhere to write.
      throw new InvalidSourceException('Unable to read a zip subscriptions export'
        + ' (try extracting and selecting the csv file)');
    }

    const stamp: string = `${Date.now()}`;
    const archivePath: string = `${tempDir}/subscriptions-${stamp}.zip`;
    const outDir: string = `${tempDir}/subscriptions-${stamp}`;
    try {
      const file: fileIo.File = fileIo.openSync(archivePath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, content as ArrayBuffer);
      } finally {
        fileIo.closeSync(file);
      }

      fileIo.mkdirSync(outDir, true);
      try {
        await zlib.decompressFile(archivePath, outDir);
      } catch (e) {
        throw new InvalidSourceException('Unable to read a zip subscriptions export'
          + ' (try extracting and selecting the csv file)',
          e instanceof Error ? e as Error : null);
      }

      for (const csvPath of YoutubeSubscriptionExtractor.csvFilesIn(outDir)) {
        try {
          const csvItems: SubscriptionItem[] =
            this.fromCsvContent(fileIo.readTextSync(csvPath));
          // Return it only if it has items (fromCsvContent exits early if it is the wrong file
          // format), otherwise try the next file
          if (csvItems.length !== 0) {
            return csvItems;
          }
        } catch (e) {
          // Ignore error and go to next file
        }
      }
      throw new InvalidSourceException('Unable to read the zip subscriptions export');
    } finally {
      YoutubeSubscriptionExtractor.deleteQuietly(archivePath);
      YoutubeSubscriptionExtractor.deleteTreeQuietly(outDir);
    }
  }

  /** Every *.csv in the extracted tree, at any depth - Takeout nests them under folders. */
  private static csvFilesIn(dir: string): string[] {
    const found: string[] = [];
    const pending: string[] = [dir];
    while (pending.length !== 0) {
      const current: string = pending.pop() as string;
      let names: string[] = [];
      try {
        names = fileIo.listFileSync(current);
      } catch (e) {
        continue;
      }
      for (const name of names) {
        const path: string = `${current}/${name}`;
        if (fileIo.statSync(path).isDirectory()) {
          pending.push(path);
        } else if (name.toLowerCase().endsWith('.csv')) {
          found.push(path);
        }
      }
    }
    return found;
  }

  private static deleteQuietly(path: string): void {
    try {
      fileIo.unlinkSync(path);
    } catch (e) {
      // scratch file; nothing to do if it is already gone
    }
  }

  private static deleteTreeQuietly(dir: string): void {
    try {
      fileIo.rmdirSync(dir);
    } catch (e) {
      // scratch directory; nothing to do if it is already gone
    }
  }

  fromJsonContent(content: string): SubscriptionItem[] {
    let subscriptions: JsonArray;
    try {
      subscriptions = JsonParser.array().from(content);
    } catch (e) {
      throw new InvalidSourceException('Invalid json input stream',
        e instanceof Error ? e as Error : null);
    }

    let foundInvalidSubscription: boolean = false;
    const subscriptionItems: SubscriptionItem[] = [];

    for (let i = 0; i < subscriptions.size(); i++) {
      const subscriptionObject: JsonValue | null = subscriptions.get(i);
      if (!(subscriptionObject instanceof JsonObject)) {
        foundInvalidSubscription = true;
        continue;
      }
      const subscription: JsonObject =
        (subscriptionObject as JsonObject).getObject('snippet');
      const id: string = subscription.getObject('resourceId')
        .getString('channelId', '') as string;
      if (id.length !== 24) { // e.g. UCsXVk37bltHxD1rDPwtNM8Q
        foundInvalidSubscription = true;
        continue;
      }
      subscriptionItems.push(new SubscriptionItem(this.service.getServiceId(),
        BASE_CHANNEL_URL + id, subscription.getString('title', '') as string));
    }

    if (foundInvalidSubscription && subscriptionItems.length === 0) {
      throw new InvalidSourceException('Found only invalid channel ids');
    }
    return subscriptionItems;
  }

  /**
   * Port of fromCsvInputStream. The export is always three columns in a fixed order — the header
   * names are localized but the data order never changes — so the header line is skipped and the
   * url and title are read positionally.
   *
   *   Channel Id,Channel Url,Channel Title
   *   UC1JTQBa5QxZCpXrFSkMxmPw,http://www.youtube.com/channel/UC1JTQBa5QxZCpXrFSkMxmPw,Raycevick
   */
  fromCsvContent(content: string): SubscriptionItem[] {
    const items: SubscriptionItem[] = [];
    const lines: string[] = content.split('\n');

    // skip the header line
    for (let i = 1; i < lines.length; i++) {
      const line: string = lines[i].replace(new RegExp('\r$'), '');
      const values: string[] = line.split(',');
      if (values.length < 3) {
        continue;
      }
      // The channel URL is the second entry, the title the third
      const channelUrl: string = values[1].replace('http://', 'https://');
      if (channelUrl.startsWith(BASE_CHANNEL_URL)) {
        items.push(new SubscriptionItem(this.service.getServiceId(), channelUrl, values[2]));
      }
    }

    return items;
  }
}
