/*
 * Port of org.schabi.newpipe.extractor.comments.CommentsInfoItem (NewPipeExtractor v0.26.5).
 */

import { InfoItem, InfoType } from '../../common/extractor/core/InfoItem';
import { DateWrapper } from '../../common/extractor/localization/DateWrapper';
import { Description } from './Description';
import { Image } from './Image';
import { Page } from './Page';

export const NO_LIKE_COUNT: number = -1;
export const NO_STREAM_POSITION: number = -1;
export const UNKNOWN_REPLY_COUNT: number = -1;

export class CommentsInfoItem extends InfoItem {
  commentId: string = '';
  commentText: Description = Description.EMPTY_DESCRIPTION;
  uploaderName: string = '';
  uploaderAvatars: Image[] = [];
  uploaderUrl: string = '';
  uploaderVerified: boolean = false;
  textualUploadDate: string = '';
  uploadDate: DateWrapper | null = null;
  likeCount: number = 0;
  textualLikeCount: string = '';
  heartedByUploader: boolean = false;
  pinned: boolean = false;
  streamPosition: number = 0;
  replyCount: number = 0;
  replies: Page | null = null;
  channelOwner: boolean = false;
  creatorReply: boolean = false;
  edited: boolean = false;

  constructor(serviceId: number, url: string, name: string) {
    super(InfoType.COMMENT, serviceId, url, name);
  }

  getCommentId(): string {
    return this.commentId;
  }

  setCommentId(commentId: string): void {
    this.commentId = commentId;
  }

  getCommentText(): Description {
    return this.commentText;
  }

  setCommentText(commentText: Description): void {
    this.commentText = commentText;
  }

  getUploaderName(): string {
    return this.uploaderName;
  }

  setUploaderName(uploaderName: string): void {
    this.uploaderName = uploaderName;
  }

  getUploaderAvatars(): Image[] {
    return this.uploaderAvatars;
  }

  setUploaderAvatars(uploaderAvatars: Image[]): void {
    this.uploaderAvatars = uploaderAvatars;
  }

  getUploaderUrl(): string {
    return this.uploaderUrl;
  }

  setUploaderUrl(uploaderUrl: string): void {
    this.uploaderUrl = uploaderUrl;
  }

  getTextualUploadDate(): string {
    return this.textualUploadDate;
  }

  setTextualUploadDate(textualUploadDate: string): void {
    this.textualUploadDate = textualUploadDate;
  }

  getUploadDate(): DateWrapper | null {
    return this.uploadDate;
  }

  setUploadDate(uploadDate: DateWrapper | null): void {
    this.uploadDate = uploadDate;
  }

  getLikeCount(): number {
    return this.likeCount;
  }

  setLikeCount(likeCount: number): void {
    this.likeCount = likeCount;
  }

  getTextualLikeCount(): string {
    return this.textualLikeCount;
  }

  setTextualLikeCount(textualLikeCount: string): void {
    this.textualLikeCount = textualLikeCount;
  }

  setHeartedByUploader(isHeartedByUploader: boolean): void {
    this.heartedByUploader = isHeartedByUploader;
  }

  getIsHeartedByUploader(): boolean {
    return this.heartedByUploader;
  }

  getIsPinned(): boolean {
    return this.pinned;
  }

  setPinned(pinned: boolean): void {
    this.pinned = pinned;
  }

  setUploaderVerified(uploaderVerified: boolean): void {
    this.uploaderVerified = uploaderVerified;
  }

  getIsUploaderVerified(): boolean {
    return this.uploaderVerified;
  }

  setStreamPosition(streamPosition: number): void {
    this.streamPosition = streamPosition;
  }

  getStreamPosition(): number {
    return this.streamPosition;
  }

  setReplyCount(replyCount: number): void {
    this.replyCount = replyCount;
  }

  getReplyCount(): number {
    return this.replyCount;
  }

  setReplies(replies: Page | null): void {
    this.replies = replies;
  }

  getReplies(): Page | null {
    return this.replies;
  }

  setChannelOwner(channelOwner: boolean): void {
    this.channelOwner = channelOwner;
  }

  getIsChannelOwner(): boolean {
    return this.channelOwner;
  }

  setCreatorReply(creatorReply: boolean): void {
    this.creatorReply = creatorReply;
  }

  getHasCreatorReply(): boolean {
    return this.creatorReply;
  }

  setEdited(edited: boolean): void {
    this.edited = edited;
  }

  getIsEdited(): boolean {
    return this.edited;
  }
}
