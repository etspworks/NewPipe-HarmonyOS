/*
 * Port of org.schabi.newpipe.extractor.services.youtube.extractors.YoutubeChannelInfoItemExtractor
 * (NewPipeExtractor v0.26.5).
 */

import { JsonObject } from '../../../json/NanoJson';
import { ChannelInfoItemExtractor } from '../../../info/ChannelExtractor';
import { ITEM_COUNT_UNKNOWN } from '../../../core/ListExtractor';
import { ParsingException } from '../../../exceptions/Exceptions';
import { mixedNumberWordToLong, removeNonDigitCharacters } from '../../../core/Utils';
import { Image } from '../../../../../model/extractor/Image';
import { getTextFromObject, getThumbnailsFromInfoItem, isVerified } from '../YoutubeParsingHelper';
import { YoutubeChannelLinkHandlerFactory } from '../linkHandler/YoutubeChannelLinkHandlerFactory';

export class YoutubeChannelInfoItemExtractor extends ChannelInfoItemExtractor {
  private readonly channelInfoItem: JsonObject;
  /**
   * YouTube shows the channel handle in the `subscriberCountText` slot for some items; when it
   * does, the subscriber count is genuinely absent and `videoCountText` holds the subscribers.
   */
  private readonly withHandle: boolean;

  constructor(channelInfoItem: JsonObject) {
    super();
    this.channelInfoItem = channelInfoItem;
    const subscriberCountText: string | null =
      getTextFromObject(channelInfoItem.getObject('subscriberCountText'));
    this.withHandle = subscriberCountText !== null && subscriberCountText.startsWith('@');
  }

  getThumbnails(): Image[] {
    try {
      return getThumbnailsFromInfoItem(this.channelInfoItem);
    } catch (e) {
      throw new ParsingException('Could not get thumbnails',
        e instanceof Error ? e as Error : null);
    }
  }

  getName(): string {
    const name: string | null = getTextFromObject(this.channelInfoItem.getObject('title'));
    if (name === null) {
      throw new ParsingException('Could not get name');
    }
    return name;
  }

  getUrl(): string {
    try {
      const id: string = 'channel/' + this.channelInfoItem.getString('channelId', '');
      return YoutubeChannelLinkHandlerFactory.getInstance().getUrl(id);
    } catch (e) {
      throw new ParsingException('Could not get url', e instanceof Error ? e as Error : null);
    }
  }

  getSubscriberCount(): number {
    try {
      if (!this.channelInfoItem.has('subscriberCountText')) {
        // The subscription count is not available for this channel item
        return -1;
      }
      if (this.withHandle) {
        if (this.channelInfoItem.has('videoCountText')) {
          return mixedNumberWordToLong(
            getTextFromObject(this.channelInfoItem.getObject('videoCountText')) as string);
        }
        return -1;
      }
      return mixedNumberWordToLong(
        getTextFromObject(this.channelInfoItem.getObject('subscriberCountText')) as string);
    } catch (e) {
      throw new ParsingException('Could not get subscriber count',
        e instanceof Error ? e as Error : null);
    }
  }

  getStreamCount(): number {
    try {
      if (this.withHandle || !this.channelInfoItem.has('videoCountText')) {
        // Either the channel has no public uploads, or YouTube shows the handle instead
        return ITEM_COUNT_UNKNOWN;
      }
      const parsed: number = Number.parseInt(removeNonDigitCharacters(
        getTextFromObject(this.channelInfoItem.getObject('videoCountText')) as string), 10);
      if (Number.isNaN(parsed)) {
        throw new ParsingException('Could not get stream count');
      }
      return parsed;
    } catch (e) {
      throw new ParsingException('Could not get stream count',
        e instanceof Error ? e as Error : null);
    }
  }

  isVerified(): boolean {
    return isVerified(this.channelInfoItem.getArray('ownerBadges'));
  }

  getDescription(): string {
    try {
      if (!this.channelInfoItem.has('descriptionSnippet')) {
        // The channel has no description
        return '';
      }
      const description: string | null =
        getTextFromObject(this.channelInfoItem.getObject('descriptionSnippet'));
      return description === null ? '' : description;
    } catch (e) {
      throw new ParsingException('Could not get description',
        e instanceof Error ? e as Error : null);
    }
  }
}
