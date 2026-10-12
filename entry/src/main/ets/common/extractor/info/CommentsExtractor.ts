/*
 * Port of org.schabi.newpipe.extractor.comments.{CommentsExtractor, CommentsInfoItemExtractor,
 * CommentsInfoItemsCollector} (NewPipeExtractor v0.26.5).
 */

import { InfoItemExtractor, InfoItemsCollector } from '../core/Collector';
import { toError } from '../core/Errors';
import { ListExtractor } from '../core/ListExtractor';
import { StreamingService } from '../core/StreamingService';
import { ListLinkHandler } from '../linkhandler/LinkHandler';
import { DateWrapper } from '../localization/DateWrapper';
import {
  CommentsInfoItem,
  NO_LIKE_COUNT,
  NO_STREAM_POSITION,
  UNKNOWN_REPLY_COUNT
} from '../../../model/extractor/CommentsInfoItem';
import { Description } from '../../../model/extractor/Description';
import { Image } from '../../../model/extractor/Image';
import { Page } from '../../../model/extractor/Page';

export abstract class CommentsExtractor extends ListExtractor<CommentsInfoItem> {
  constructor(service: StreamingService, uiHandler: ListLinkHandler) {
    super(service, uiHandler);
  }

  isCommentsDisabled(): boolean {
    return false;
  }

  getCommentsCount(): number {
    return -1;
  }

  getName(): string {
    return 'Comments';
  }
}

export abstract class CommentsInfoItemExtractor extends InfoItemExtractor {
  getLikeCount(): number {
    return NO_LIKE_COUNT;
  }

  getTextualLikeCount(): string {
    return '';
  }

  getCommentText(): Description {
    return Description.EMPTY_DESCRIPTION;
  }

  getTextualUploadDate(): string {
    return '';
  }

  getUploadDate(): DateWrapper | null {
    return null;
  }

  getCommentId(): string {
    return '';
  }

  getUploaderUrl(): string {
    return '';
  }

  getUploaderName(): string {
    return '';
  }

  getUploaderAvatars(): Image[] {
    return [];
  }

  isHeartedByUploader(): boolean {
    return false;
  }

  isPinned(): boolean {
    return false;
  }

  isUploaderVerified(): boolean {
    return false;
  }

  getStreamPosition(): number {
    return NO_STREAM_POSITION;
  }

  getReplyCount(): number {
    return UNKNOWN_REPLY_COUNT;
  }

  getReplies(): Page | null {
    return null;
  }

  isChannelOwner(): boolean {
    return false;
  }

  hasCreatorReply(): boolean {
    return false;
  }

  isEdited(): boolean {
    return false;
  }
}

export class CommentsInfoItemsCollector
  extends InfoItemsCollector<CommentsInfoItem, CommentsInfoItemExtractor> {
  constructor(serviceId: number) {
    super(serviceId);
  }

  extract(extractor: CommentsInfoItemExtractor): CommentsInfoItem {
    const resultItem: CommentsInfoItem =
      new CommentsInfoItem(this.getServiceId(), extractor.getUrl(), extractor.getName());

    // optional information
    try {
      resultItem.commentId = extractor.getCommentId();
    } catch (e) {
      this.addError(toError(e));
    }
    try {
      resultItem.commentText = extractor.getCommentText();
    } catch (e) {
      this.addError(toError(e));
    }
    try {
      resultItem.uploaderName = extractor.getUploaderName();
    } catch (e) {
      this.addError(toError(e));
    }
    try {
      resultItem.uploaderAvatars = extractor.getUploaderAvatars();
    } catch (e) {
      this.addError(toError(e));
    }
    try {
      resultItem.uploaderUrl = extractor.getUploaderUrl();
    } catch (e) {
      this.addError(toError(e));
    }
    try {
      resultItem.textualUploadDate = extractor.getTextualUploadDate();
    } catch (e) {
      this.addError(toError(e));
    }
    try {
      resultItem.uploadDate = extractor.getUploadDate();
    } catch (e) {
      this.addError(toError(e));
    }
    try {
      resultItem.likeCount = extractor.getLikeCount();
    } catch (e) {
      this.addError(toError(e));
    }
    try {
      resultItem.textualLikeCount = extractor.getTextualLikeCount();
    } catch (e) {
      this.addError(toError(e));
    }
    try {
      resultItem.thumbnails = extractor.getThumbnails();
    } catch (e) {
      this.addError(toError(e));
    }
    try {
      resultItem.heartedByUploader = extractor.isHeartedByUploader();
    } catch (e) {
      this.addError(toError(e));
    }
    try {
      resultItem.pinned = extractor.isPinned();
    } catch (e) {
      this.addError(toError(e));
    }
    try {
      resultItem.streamPosition = extractor.getStreamPosition();
    } catch (e) {
      this.addError(toError(e));
    }
    try {
      resultItem.replyCount = extractor.getReplyCount();
    } catch (e) {
      this.addError(toError(e));
    }
    try {
      resultItem.replies = extractor.getReplies();
    } catch (e) {
      this.addError(toError(e));
    }
    try {
      resultItem.channelOwner = extractor.isChannelOwner();
    } catch (e) {
      this.addError(toError(e));
    }
    try {
      resultItem.creatorReply = extractor.hasCreatorReply();
    } catch (e) {
      this.addError(toError(e));
    }
    try {
      resultItem.edited = extractor.isEdited();
    } catch (e) {
      this.addError(toError(e));
    }
    // NOTE: uploaderVerified is deliberately NOT set here — the source's extract() does not set
    // it either, so setting it would change behaviour rather than port it.

    return resultItem;
  }

  commit(extractor: CommentsInfoItemExtractor): void {
    try {
      this.addItem(this.extract(extractor));
    } catch (e) {
      this.addError(toError(e));
    }
  }

  getCommentsInfoItemList(): CommentsInfoItem[] {
    return this.getItems();
  }
}
