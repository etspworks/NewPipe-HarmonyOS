/*
 * Port of org.schabi.newpipe.extractor.services.youtube.extractors.YoutubeReelInfoItemExtractor
 * (NewPipeExtractor v0.26.5).
 *
 * A Shorts row from a `reelItemRenderer`, which carries far fewer fields than a normal video row.
 * The source's `null` returns for uploader name/url are '' here, because the ported
 * StreamInfoItemExtractor declares those non-null and StreamInfoItem.uploaderName is a string.
 */

import { JsonObject } from '../../../json/NanoJson';
import { StreamInfoItemExtractor } from '../../../info/StreamInfoItemExtractor';
import { ParsingException } from '../../../exceptions/Exceptions';
import { DateWrapper } from '../../../localization/DateWrapper';
import { isNullOrEmpty, mixedNumberWordToLong } from '../../../core/Utils';
import { Image } from '../../../../../model/extractor/Image';
import { StreamType } from '../../../../../model/enums/StreamType';
import { getTextFromObject, getThumbnailsFromInfoItem } from '../YoutubeParsingHelper';
import { YoutubeStreamLinkHandlerFactory } from '../linkHandler/YoutubeStreamLinkHandlerFactory';

export class YoutubeReelInfoItemExtractor extends StreamInfoItemExtractor {
  private readonly reelInfo: JsonObject;

  constructor(reelInfo: JsonObject) {
    super();
    this.reelInfo = reelInfo;
  }

  getName(): string {
    const name: string | null = getTextFromObject(this.reelInfo.getObject('headline'));
    return name === null ? '' : name;
  }

  getUrl(): string {
    try {
      const videoId: string = this.reelInfo.getString('videoId', '') as string;
      return YoutubeStreamLinkHandlerFactory.getInstance().getUrl(videoId);
    } catch (e) {
      throw new ParsingException('Could not get URL', e instanceof Error ? e as Error : null);
    }
  }

  getThumbnails(): Image[] {
    return getThumbnailsFromInfoItem(this.reelInfo);
  }

  getStreamType(): StreamType {
    return StreamType.VIDEO_STREAM;
  }

  getViewCount(): number {
    const viewCountText: string | null =
      getTextFromObject(this.reelInfo.getObject('viewCountText'));
    if (!isNullOrEmpty(viewCountText)) {
      // This approach is language dependent
      if ((viewCountText as string).toLowerCase().includes('no views')) {
        return 0;
      }
      return mixedNumberWordToLong(viewCountText as string);
    }
    throw new ParsingException('Could not get short view count');
  }

  isShortFormContent(): boolean {
    return true;
  }

  // Everything below cannot be obtained from a reelItemRenderer

  isAd(): boolean {
    return false;
  }

  getDuration(): number {
    return -1;
  }

  getUploaderName(): string {
    return '';
  }

  getUploaderUrl(): string {
    return '';
  }

  isUploaderVerified(): boolean {
    return false;
  }

  getTextualUploadDate(): string | null {
    return null;
  }

  getUploadDate(): DateWrapper | null {
    return null;
  }
}
