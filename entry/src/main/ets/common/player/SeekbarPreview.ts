/**
 * SeekbarPreview — svc_seekbar_preview, endpoint seekbar_preview_thumbnail_fetch.
 *
 * Ports org.schabi.newpipe.player.seekbarpreview.SeekbarPreviewThumbnailHolder +
 * SeekbarPreviewThumbnailHelper: the storyboard sprite sheets a service publishes are
 * downloaded and one frame is cut out for the position the user is scrubbing to.
 *
 * Two deliberate differences from the source, both simplifications rather than losses:
 *   - The source pre-decodes EVERY frame of EVERY sheet on a background executor and holds
 *     them in a SparseArray. Here the sheet bytes are cached and the frame is cut on demand
 *     via image.DecodingOptions#desiredRegion, which is a native crop.
 *   - The source's UUID request-identifier guards a long pre-generation pass. Nothing here
 *     runs long enough to need it; a new reset() simply replaces the frameset and cache.
 *
 * Frameset and its getFrameBoundsAt() are the canonical extractor port in
 * model/extractor/Frameset.ts; they are imported, not redeclared here.
 */

import { http } from '@kit.NetworkKit';
import { image } from '@kit.ImageKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { USER_AGENT } from '../net/Downloader';
import { FrameBounds, Frameset } from '../../model/extractor/Frameset';
import {
  seekbar_preview_thumbnail_high_quality,
  seekbar_preview_thumbnail_none
} from '../prefs/SettingsKeys';

const TAG: string = 'SeekbarPreview';

/** Port of SeekbarPreviewThumbnailHelper.SeekbarPreviewThumbnailType. */
export enum SeekbarPreviewThumbnailType {
  HIGH_QUALITY = 0,
  LOW_QUALITY = 1,
  NONE = 2
}

/**
 * Port of SeekbarPreviewThumbnailHelper.getSeekbarPreviewThumbnailType(): the stored value
 * of `seekbar_preview_thumbnail_key`. Passing the raw preference string keeps this module
 * free of a preferences dependency owned by another wave.
 */
export function seekbarPreviewTypeOf(storedValue: string): SeekbarPreviewThumbnailType {
  if (storedValue === seekbar_preview_thumbnail_none) {
    return SeekbarPreviewThumbnailType.NONE;
  } else if (storedValue === seekbar_preview_thumbnail_high_quality) {
    return SeekbarPreviewThumbnailType.HIGH_QUALITY;
  }
  return SeekbarPreviewThumbnailType.LOW_QUALITY;
}

export class SeekbarPreview {
  private static instance: SeekbarPreview | null = null;

  /** ponytail: at most 2 sheets are cached; raise if scrubbing across a long video thrashes. */
  private static readonly MAX_CACHED_SHEETS: number = 2;

  private frameset: Frameset | null = null;
  private quality: SeekbarPreviewThumbnailType = SeekbarPreviewThumbnailType.LOW_QUALITY;
  private readonly sheets: Map<number, ArrayBuffer> = new Map<number, ArrayBuffer>();
  private readonly sheetOrder: number[] = [];
  private lastBoundsKey: string = '';
  private lastPixelMap: image.PixelMap | null = null;

  static getInstance(): SeekbarPreview {
    if (SeekbarPreview.instance === null) {
      SeekbarPreview.instance = new SeekbarPreview();
    }
    return SeekbarPreview.instance;
  }

  isEnabled(): boolean {
    return this.frameset !== null && this.quality !== SeekbarPreviewThumbnailType.NONE;
  }

  /** Port of SeekbarPreviewThumbnailHolder.resetFrom(): pick the frameset for the setting. */
  async resetFrom(framesets: Frameset[], quality: SeekbarPreviewThumbnailType): Promise<void> {
    await this.clear();
    this.quality = quality;
    if (quality === SeekbarPreviewThumbnailType.NONE || framesets.length === 0) {
      return;
    }
    this.frameset = SeekbarPreview.pickFrameset(framesets, quality);
  }

  private static pickFrameset(framesets: Frameset[],
    quality: SeekbarPreviewThumbnailType): Frameset | null {
    let chosen: Frameset | null = null;
    for (const candidate of framesets) {
      if (candidate.urls.length === 0 || candidate.frameWidth <= 0
        || candidate.frameHeight <= 0 || candidate.durationPerFrame <= 0) {
        continue;
      }
      if (chosen === null) {
        chosen = candidate;
        continue;
      }
      const area: number = candidate.frameWidth * candidate.frameHeight;
      const chosenArea: number = chosen.frameWidth * chosen.frameHeight;
      const better: boolean = quality === SeekbarPreviewThumbnailType.HIGH_QUALITY
        ? area > chosenArea : area < chosenArea;
      if (better) {
        chosen = candidate;
      }
    }
    return chosen;
  }

  /**
   * The preview frame for a scrub position, or null when previews are off, the frameset is
   * missing, or the sheet could not be fetched. A null answer means "show no preview" and is
   * always logged with its cause — it is never a swallowed failure.
   */
  async previewAt(positionMs: number): Promise<image.PixelMap | null> {
    const frameset: Frameset | null = this.frameset;
    if (frameset === null || this.quality === SeekbarPreviewThumbnailType.NONE) {
      return null;
    }
    const bounds: FrameBounds = frameset.getFrameBoundsAt(positionMs);
    if (bounds.storyboardIndex >= frameset.urls.length) {
      return null;
    }
    const key: string = bounds.storyboardIndex + ':' + bounds.left + ':' + bounds.top;
    if (key === this.lastBoundsKey && this.lastPixelMap !== null) {
      return this.lastPixelMap;
    }
    const sheet: ArrayBuffer | null =
      await this.sheetBytes(frameset.urls[bounds.storyboardIndex], bounds.storyboardIndex);
    if (sheet === null) {
      return null;
    }
    const cropped: image.PixelMap | null = await SeekbarPreview.crop(sheet, bounds);
    if (cropped === null) {
      return null;
    }
    await this.releaseLast();
    this.lastBoundsKey = key;
    this.lastPixelMap = cropped;
    return cropped;
  }

  /** endpoint seekbar_preview_thumbnail_fetch — one storyboard sprite sheet. */
  private async sheetBytes(url: string, index: number): Promise<ArrayBuffer | null> {
    const cached: ArrayBuffer | undefined = this.sheets.get(index);
    if (cached !== undefined) {
      return cached;
    }
    const httpRequest: http.HttpRequest = http.createHttp();
    try {
      const headers: Record<string, string> = { 'User-Agent': USER_AGENT };
      const response: http.HttpResponse = await httpRequest.request(url, {
        method: http.RequestMethod.GET,
        header: headers,
        expectDataType: http.HttpDataType.ARRAY_BUFFER
      });
      if (response.responseCode !== http.ResponseCode.OK
        || !(response.result instanceof ArrayBuffer)) {
        console.warn(TAG + ': storyboard fetch returned ' + response.responseCode
          + ' for ' + url);
        return null;
      }
      const bytes: ArrayBuffer = response.result as ArrayBuffer;
      this.cacheSheet(index, bytes);
      return bytes;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      console.warn(TAG + ': storyboard fetch failed: ' + err.message);
      return null;
    } finally {
      httpRequest.destroy();
    }
  }

  private cacheSheet(index: number, bytes: ArrayBuffer): void {
    this.sheets.set(index, bytes);
    this.sheetOrder.push(index);
    while (this.sheetOrder.length > SeekbarPreview.MAX_CACHED_SHEETS) {
      const evicted: number | undefined = this.sheetOrder.shift();
      if (evicted !== undefined) {
        this.sheets.delete(evicted);
      }
    }
  }

  /** Cut one frame out of the sheet natively; the ImageSource is released in finally. */
  private static async crop(sheet: ArrayBuffer,
    bounds: FrameBounds): Promise<image.PixelMap | null> {
    const source: image.ImageSource = image.createImageSource(sheet);
    try {
      const size: image.Size = {
        width: bounds.right - bounds.left,
        height: bounds.bottom - bounds.top
      };
      const region: image.Region = { size: size, x: bounds.left, y: bounds.top };
      const options: image.DecodingOptions = { desiredRegion: region };
      return await source.createPixelMap(options);
    } catch (e) {
      // The source guards against slightly-too-small storyboards the same way; a bad crop
      // means no preview for this position, not a crash.
      const err: BusinessError = e as BusinessError;
      console.warn(TAG + ': frame crop failed: ' + err.message);
      return null;
    } finally {
      await source.release();
    }
  }

  private async releaseLast(): Promise<void> {
    const previous: image.PixelMap | null = this.lastPixelMap;
    if (previous === null) {
      return;
    }
    try {
      await previous.release();
    } catch (e) {
      console.warn(TAG + ': pixel map release failed');
    } finally {
      this.lastPixelMap = null;
      this.lastBoundsKey = '';
    }
  }

  /** Called when the stream changes or the player is torn down. */
  async clear(): Promise<void> {
    await this.releaseLast();
    this.frameset = null;
    this.sheets.clear();
    this.sheetOrder.length = 0;
  }
}
