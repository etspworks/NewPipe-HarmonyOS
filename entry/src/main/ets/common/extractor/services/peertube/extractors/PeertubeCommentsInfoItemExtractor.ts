/*
 * Port of org.schabi.newpipe.extractor.services.peertube.extractors
 * .PeertubeCommentsInfoItemExtractor (NewPipeExtractor v0.26.5).
 *
 * DEVIATION: the source reads `CHILDREN` off PeertubeCommentsExtractor. That extractor imports
 * THIS module to build its items, so keeping the constant there would be an ES-module cycle; it
 * is declared here and PeertubeCommentsExtractor imports it (phase2-logic-contract.md §9).
 */

import { CommentsInfoItemExtractor } from '../../../info/CommentsExtractor';
import { JsonArray, JsonObject, JsonWriter } from '../../../json/NanoJson';
import { JsonUtils } from '../../../core/JsonUtils';
import { DateWrapper } from '../../../localization/DateWrapper';
import { Document, Jsoup } from '../../../html/Jsoup';
import { Request } from '../../../downloader/Downloader';
import { Image } from '../../../../../model/extractor/Image';
import { Page } from '../../../../../model/extractor/Page';
import { Description, DESCRIPTION_PLAIN_TEXT } from '../../../../../model/extractor/Description';
import { getAvatarsFromOwnerAccountOrVideoChannelObject } from '../PeertubeParsingHelper';
import {
  PeertubeChannelLinkHandlerFactory
} from '../linkHandler/PeertubeChannelLinkHandlerFactory';

export const CHILDREN: string = 'children';

const HTML_TAG_PATTERN: RegExp = new RegExp('<[^>]*>(\\s*<[^>]*>)*', 'gs');

export class PeertubeCommentsInfoItemExtractor extends CommentsInfoItemExtractor {
  private readonly item: JsonObject;
  private readonly children: JsonArray | null;
  private readonly url: string;
  private readonly baseUrl: string;
  private readonly isReply: boolean;

  private replyCount: number | null = null;

  constructor(item: JsonObject, children: JsonArray | null, url: string, baseUrl: string,
    isReply: boolean) {
    super();
    this.item = item;
    this.children = children;
    this.url = url;
    this.baseUrl = baseUrl;
    this.isReply = isReply;
  }

  getUrl(): string {
    return this.url + '/' + this.getCommentId();
  }

  getThumbnails(): Image[] {
    return this.getUploaderAvatars();
  }

  getName(): string {
    return JsonUtils.getString(this.item, 'account.displayName');
  }

  getTextualUploadDate(): string {
    return JsonUtils.getString(this.item, 'createdAt');
  }

  getUploadDate(): DateWrapper | null {
    return DateWrapper.fromInstant(this.getTextualUploadDate());
  }

  getCommentText(): Description {
    const htmlText: string = JsonUtils.getString(this.item, 'text');
    try {
      const doc: Document = Jsoup.parse(htmlText);
      return new Description(doc.body().text(), DESCRIPTION_PLAIN_TEXT);
    } catch (e) {
      HTML_TAG_PATTERN.lastIndex = 0;
      return new Description(htmlText.replace(HTML_TAG_PATTERN, ''), DESCRIPTION_PLAIN_TEXT);
    }
  }

  getCommentId(): string {
    return this.item.getLong('id').toString();
  }

  getUploaderAvatars(): Image[] {
    return getAvatarsFromOwnerAccountOrVideoChannelObject(this.baseUrl,
      this.item.getObject('account'));
  }

  getUploaderName(): string {
    return JsonUtils.getString(this.item, 'account.name') + '@'
      + JsonUtils.getString(this.item, 'account.host');
  }

  getUploaderUrl(): string {
    const name: string = JsonUtils.getString(this.item, 'account.name');
    const host: string = JsonUtils.getString(this.item, 'account.host');
    return PeertubeChannelLinkHandlerFactory.getInstance()
      .fromId('accounts/' + name + '@' + host, this.baseUrl).getUrl();
  }

  getReplies(): Page | null {
    if (this.getReplyCount() === 0) {
      return null;
    }
    const threadId: string = JsonUtils.getNumber(this.item, 'threadId').toString();
    const repliesUrl: string = this.url + '/' + threadId;
    if (this.isReply && this.children !== null && this.children.size() > 0) {
      // Nested replies are already included in the original thread's request.
      // Wrap the replies into a JsonObject, because the original thread's request body
      // is also structured like a JsonObject.
      const pageContent: JsonObject = new JsonObject();
      pageContent.put(CHILDREN, this.children);
      return new Page(repliesUrl, threadId, null, null,
        Request.utf8Body(JsonWriter.stringValue(pageContent)));
    }
    return new Page(repliesUrl, threadId);
  }

  getReplyCount(): number {
    if (this.replyCount === null) {
      if (this.children !== null && this.children.size() > 0) {
        // The totalReplies field is inaccurate for nested replies and sometimes returns 0
        // although there are replies to that reply stored in children.
        this.replyCount = this.children.size();
      } else {
        this.replyCount = Math.trunc(JsonUtils.getNumber(this.item, 'totalReplies'));
      }
    }
    return this.replyCount;
  }

  hasCreatorReply(): boolean {
    return this.item.has('totalRepliesFromVideoAuthor')
      && this.item.getInt('totalRepliesFromVideoAuthor') > 0;
  }
}
