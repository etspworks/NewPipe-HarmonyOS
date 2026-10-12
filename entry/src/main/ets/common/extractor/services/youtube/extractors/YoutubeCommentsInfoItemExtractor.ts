/*
 * Port of org.schabi.newpipe.extractor.services.youtube.extractors
 * .{YoutubeCommentsInfoItemExtractor, YoutubeCommentsEUVMInfoItemExtractor}
 * (NewPipeExtractor v0.26.5).
 *
 * YouTube returns comments in two shapes — the older `commentRenderer` and the newer
 * `commentEntityPayload` view model — and YoutubeCommentsExtractor picks between them per item,
 * so both live in one module.
 */

import { JsonObject } from '../../../json/NanoJson';
import { CommentsInfoItemExtractor } from '../../../info/CommentsExtractor';
import { UNKNOWN_REPLY_COUNT } from '../../../../../model/extractor/CommentsInfoItem';
import { JsonUtils } from '../../../core/JsonUtils';
import { ParsingException } from '../../../exceptions/Exceptions';
import { DateWrapper } from '../../../localization/DateWrapper';
import { TimeAgoParser } from '../../../localization/TimeAgoParser';
import {
  isBlank,
  isNullOrEmpty,
  mixedNumberWordToLong,
  removeNonDigitCharacters,
  removeUTF8BOM
} from '../../../core/Utils';
import {
  Description,
  DESCRIPTION_HTML
} from '../../../../../model/extractor/Description';
import { Image } from '../../../../../model/extractor/Image';
import { Page } from '../../../../../model/extractor/Page';
import { getImagesFromThumbnailsArray, getTextFromObject, getTextFromObjectHtml } from '../YoutubeParsingHelper';
import { attributedDescriptionToHtml } from '../YoutubeDescriptionHelper';

const PUBLISHED_TIME_TEXT: string = 'publishedTimeText';

export class YoutubeCommentsInfoItemExtractor extends CommentsInfoItemExtractor {
  private readonly commentRenderer: JsonObject;
  private readonly commentRepliesRenderer: JsonObject | null;
  private readonly url: string;
  private readonly timeAgoParser: TimeAgoParser;

  constructor(commentRenderer: JsonObject, commentRepliesRenderer: JsonObject | null, url: string,
    timeAgoParser: TimeAgoParser) {
    super();
    this.commentRenderer = commentRenderer;
    this.commentRepliesRenderer = commentRepliesRenderer;
    this.url = url;
    this.timeAgoParser = timeAgoParser;
  }

  private getAuthorThumbnails(): Image[] {
    try {
      return getImagesFromThumbnailsArray(
        JsonUtils.getArray(this.commentRenderer, 'authorThumbnail.thumbnails'));
    } catch (e) {
      throw new ParsingException('Could not get author thumbnails',
        e instanceof Error ? e as Error : null);
    }
  }

  getUrl(): string {
    return this.url;
  }

  getThumbnails(): Image[] {
    return this.getAuthorThumbnails();
  }

  getName(): string {
    try {
      const name: string | null =
        getTextFromObject(JsonUtils.getObject(this.commentRenderer, 'authorText'));
      return name === null ? '' : name;
    } catch (e) {
      return '';
    }
  }

  getTextualUploadDate(): string {
    try {
      const date: string | null =
        getTextFromObject(JsonUtils.getObject(this.commentRenderer, PUBLISHED_TIME_TEXT));
      return date === null ? '' : date;
    } catch (e) {
      throw new ParsingException('Could not get publishedTimeText',
        e instanceof Error ? e as Error : null);
    }
  }

  getUploadDate(): DateWrapper | null {
    const textualPublishedTime: string = this.getTextualUploadDate();
    if (textualPublishedTime.length > 0) {
      return this.timeAgoParser.parse(textualPublishedTime);
    }
    return null;
  }

  /**
   * The exact like count from the accessibility data when available, otherwise the approximate,
   * language-dependent `voteCount` (e.g. "3,3 Mio" in German).
   */
  getLikeCount(): number {
    let likeCount: string;
    try {
      likeCount = removeNonDigitCharacters(JsonUtils.getString(this.commentRenderer,
        'actionButtons.commentActionButtonsRenderer.likeButton.toggleButtonRenderer'
        + '.accessibilityData.accessibilityData.label'));
    } catch (e) {
      const textualLikeCount: string = this.getTextualLikeCount();
      try {
        if (isBlank(textualLikeCount)) {
          return 0;
        }
        return Math.trunc(mixedNumberWordToLong(textualLikeCount));
      } catch (i) {
        throw new ParsingException(
          'Unexpected error while converting textual like count to like count',
          i instanceof Error ? i as Error : null);
      }
    }

    if (isBlank(likeCount)) {
      return 0;
    }
    const parsed: number = Number.parseInt(likeCount, 10);
    if (Number.isNaN(parsed)) {
      throw new ParsingException('Unexpected error while parsing like count as Integer');
    }
    return parsed;
  }

  getTextualLikeCount(): string {
    try {
      // A comment with no likes carries no voteCount
      if (!this.commentRenderer.has('voteCount')) {
        return '';
      }
      const voteCountObj: JsonObject = JsonUtils.getObject(this.commentRenderer, 'voteCount');
      if (voteCountObj.size() === 0) {
        return '';
      }
      const text: string | null = getTextFromObject(voteCountObj);
      return text === null ? '' : text;
    } catch (e) {
      throw new ParsingException('Could not get the vote count',
        e instanceof Error ? e as Error : null);
    }
  }

  getCommentText(): Description {
    try {
      const contentText: JsonObject = JsonUtils.getObject(this.commentRenderer, 'contentText');
      if (contentText.size() === 0) {
        // completely empty comments, see NewPipeExtractor issue #380
        return Description.EMPTY_DESCRIPTION;
      }
      const commentText: string | null = getTextFromObjectHtml(contentText, true);
      // YouTube adds U+FEFF to some comments, e.g. https://www.youtube.com/watch?v=Nj4F63E59io
      const commentTextBomRemoved: string =
        removeUTF8BOM(commentText === null ? '' : commentText);
      return new Description(commentTextBomRemoved, DESCRIPTION_HTML);
    } catch (e) {
      throw new ParsingException('Could not get comment text',
        e instanceof Error ? e as Error : null);
    }
  }

  getCommentId(): string {
    try {
      return JsonUtils.getString(this.commentRenderer, 'commentId');
    } catch (e) {
      throw new ParsingException('Could not get comment id',
        e instanceof Error ? e as Error : null);
    }
  }

  getUploaderAvatars(): Image[] {
    return this.getAuthorThumbnails();
  }

  isHeartedByUploader(): boolean {
    return this.commentRenderer.getObject('actionButtons')
      .getObject('commentActionButtonsRenderer')
      .has('creatorHeart');
  }

  isPinned(): boolean {
    return this.commentRenderer.has('pinnedCommentBadge');
  }

  isUploaderVerified(): boolean {
    return this.commentRenderer.has('authorCommentBadge');
  }

  getUploaderName(): string {
    try {
      const name: string | null =
        getTextFromObject(JsonUtils.getObject(this.commentRenderer, 'authorText'));
      return name === null ? '' : name;
    } catch (e) {
      return '';
    }
  }

  getUploaderUrl(): string {
    try {
      return 'https://www.youtube.com/channel/'
        + JsonUtils.getString(this.commentRenderer, 'authorEndpoint.browseEndpoint.browseId');
    } catch (e) {
      return '';
    }
  }

  getReplyCount(): number {
    if (this.commentRenderer.has('replyCount')) {
      return this.commentRenderer.getInt('replyCount');
    }
    return UNKNOWN_REPLY_COUNT;
  }

  getReplies(): Page | null {
    const repliesRenderer: JsonObject | null = this.commentRepliesRenderer;
    if (repliesRenderer === null) {
      return null;
    }
    try {
      const id: string = JsonUtils.getString(
        JsonUtils.getArray(repliesRenderer, 'contents').getObject(0),
        'continuationItemRenderer.continuationEndpoint.continuationCommand.token');
      return new Page(this.url, id);
    } catch (e) {
      return null;
    }
  }

  isChannelOwner(): boolean {
    return this.commentRenderer.getBoolean('authorIsChannelOwner');
  }

  isEdited(): boolean {
    try {
      if (!this.commentRenderer.has(PUBLISHED_TIME_TEXT)) {
        return false;
      }
      const publishedTimeText: JsonObject =
        JsonUtils.getObject(this.commentRenderer, PUBLISHED_TIME_TEXT);
      if (publishedTimeText.has('runs')) {
        return publishedTimeText.getArray('runs').size() > 1;
      }
      return false;
    } catch (e) {
      throw new ParsingException('Could not check whether the comment is edited',
        e instanceof Error ? e as Error : null);
    }
  }

  hasCreatorReply(): boolean {
    const repliesRenderer: JsonObject | null = this.commentRepliesRenderer;
    return repliesRenderer !== null && repliesRenderer.has('viewRepliesCreatorThumbnail');
  }
}

const AUTHOR: string = 'author';
const PROPERTIES: string = 'properties';
const PUBLISHED_TIME: string = 'publishedTime';

/** The newer entity-payload comment shape (EUVM = engagement / update view model). */
export class YoutubeCommentsEUVMInfoItemExtractor extends CommentsInfoItemExtractor {
  private readonly commentViewModel: JsonObject;
  private readonly commentRepliesRenderer: JsonObject | null;
  private readonly commentEntityPayload: JsonObject;
  private readonly engagementToolbarStateEntityPayload: JsonObject;
  private readonly videoUrl: string;
  private readonly timeAgoParser: TimeAgoParser;

  constructor(commentViewModel: JsonObject, commentRepliesRenderer: JsonObject | null,
    commentEntityPayload: JsonObject, engagementToolbarStateEntityPayload: JsonObject,
    videoUrl: string, timeAgoParser: TimeAgoParser) {
    super();
    this.commentViewModel = commentViewModel;
    this.commentRepliesRenderer = commentRepliesRenderer;
    this.commentEntityPayload = commentEntityPayload;
    this.engagementToolbarStateEntityPayload = engagementToolbarStateEntityPayload;
    this.videoUrl = videoUrl;
    this.timeAgoParser = timeAgoParser;
  }

  getName(): string {
    return this.getUploaderName();
  }

  getUrl(): string {
    return this.videoUrl;
  }

  getThumbnails(): Image[] {
    return this.getUploaderAvatars();
  }

  getLikeCount(): number {
    const textualLikeCount: string = this.getTextualLikeCount();
    try {
      if (isBlank(textualLikeCount)) {
        return 0;
      }
      return Math.trunc(mixedNumberWordToLong(textualLikeCount));
    } catch (e) {
      throw new ParsingException(
        'Unexpected error while converting textual like count to like count',
        e instanceof Error ? e as Error : null);
    }
  }

  getTextualLikeCount(): string {
    const count: string | null =
      this.commentEntityPayload.getObject('toolbar').getString('likeCountNotliked');
    return count === null ? '' : count;
  }

  getCommentText(): Description {
    // A comment's text works like an attributed video description
    const html: string | null = attributedDescriptionToHtml(
      this.commentEntityPayload.getObject(PROPERTIES).getObject('content'));
    return new Description(html, DESCRIPTION_HTML);
  }

  getTextualUploadDate(): string {
    const date: string | null =
      this.commentEntityPayload.getObject(PROPERTIES).getString(PUBLISHED_TIME);
    return date === null ? '' : date;
  }

  getUploadDate(): DateWrapper | null {
    const textualPublishedTime: string = this.getTextualUploadDate();
    if (isNullOrEmpty(textualPublishedTime)) {
      return null;
    }
    return this.timeAgoParser.parse(textualPublishedTime);
  }

  getCommentId(): string {
    let commentId: string | null =
      this.commentEntityPayload.getObject(PROPERTIES).getString('commentId');
    if (isNullOrEmpty(commentId)) {
      commentId = this.commentViewModel.getString('commentId');
      if (isNullOrEmpty(commentId)) {
        throw new ParsingException('Could not get comment ID');
      }
    }
    return commentId as string;
  }

  getUploaderUrl(): string {
    const author: JsonObject = this.commentEntityPayload.getObject(AUTHOR);
    let channelId: string | null = author.getString('channelId');
    if (isNullOrEmpty(channelId)) {
      channelId = author.getObject('channelCommand')
        .getObject('innertubeCommand')
        .getObject('browseEndpoint')
        .getString('browseId');
      if (isNullOrEmpty(channelId)) {
        channelId = author.getObject('avatar')
          .getObject('endpoint')
          .getObject('innertubeCommand')
          .getObject('browseEndpoint')
          .getString('browseId');
        if (isNullOrEmpty(channelId)) {
          throw new ParsingException('Could not get channel ID');
        }
      }
    }
    return 'https://www.youtube.com/channel/' + channelId;
  }

  getUploaderName(): string {
    const name: string | null =
      this.commentEntityPayload.getObject(AUTHOR).getString('displayName');
    return name === null ? '' : name;
  }

  getUploaderAvatars(): Image[] {
    return getImagesFromThumbnailsArray(this.commentEntityPayload.getObject('avatar')
      .getObject('image')
      .getArray('sources'));
  }

  isHeartedByUploader(): boolean {
    return this.engagementToolbarStateEntityPayload.getString('heartState')
      === 'TOOLBAR_HEART_STATE_HEARTED';
  }

  isPinned(): boolean {
    return this.commentViewModel.has('pinnedText');
  }

  isUploaderVerified(): boolean {
    const author: JsonObject = this.commentEntityPayload.getObject(AUTHOR);
    return author.getBoolean('isVerified') || author.getBoolean('isArtist');
  }

  getReplyCount(): number {
    // YouTube allows up to 750 replies, so a returned count cannot be told apart from a mixed
    // number; assume mixed, which is how most counts come back
    const replyCountString: string | null =
      this.commentEntityPayload.getObject('toolbar').getString('replyCount');
    if (isNullOrEmpty(replyCountString)) {
      return 0;
    }
    return Math.trunc(mixedNumberWordToLong(replyCountString as string));
  }

  getReplies(): Page | null {
    const repliesRenderer: JsonObject | null = this.commentRepliesRenderer;
    if (repliesRenderer === null || repliesRenderer.size() === 0) {
      return null;
    }
    for (const content of repliesRenderer.getArray('contents').streamAsJsonObjects()) {
      if (!content.has('continuationItemRenderer')) {
        continue;
      }
      const continuation: string | null = content.getObject('continuationItemRenderer')
        .getObject('continuationEndpoint')
        .getObject('continuationCommand')
        .getString('token');
      if (continuation !== null) {
        return new Page(this.videoUrl, continuation);
      }
    }
    throw new ParsingException('Could not get comment replies continuation');
  }

  isChannelOwner(): boolean {
    return this.commentEntityPayload.getObject(AUTHOR).getBoolean('isCreator');
  }

  hasCreatorReply(): boolean {
    const repliesRenderer: JsonObject | null = this.commentRepliesRenderer;
    return repliesRenderer !== null && repliesRenderer.has('viewRepliesCreatorThumbnail');
  }

  isEdited(): boolean {
    try {
      const obj: JsonObject = this.commentEntityPayload.getObject(PROPERTIES);
      if (!obj.has(PUBLISHED_TIME)) {
        return false;
      }
      const str: string = obj.getString(PUBLISHED_TIME, '') as string;
      return str.includes('(') && str.includes(')');
    } catch (e) {
      throw new ParsingException('Could not check whether the comment is edited',
        e instanceof Error ? e as Error : null);
    }
  }
}
