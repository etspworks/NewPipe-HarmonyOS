/*
 * Port of org.schabi.newpipe.extractor.services.bandcamp.extractors
 * .BandcampCommentsInfoItemExtractor (NewPipeExtractor v0.26.5).
 */

import { Description, DESCRIPTION_PLAIN_TEXT } from '../../../../../model/extractor/Description';
import { Image } from '../../../../../model/extractor/Image';
import { CommentsInfoItemExtractor } from '../../../info/CommentsExtractor';
import { JsonObject } from '../../../json/NanoJson';
import { BandcampExtractorHelper } from './BandcampExtractorHelper';

export class BandcampCommentsInfoItemExtractor extends CommentsInfoItemExtractor {
  private readonly review: JsonObject;
  private readonly url: string;

  constructor(review: JsonObject, url: string) {
    super();
    this.review = review;
    this.url = url;
  }

  getName(): string {
    return this.getCommentText().getContent();
  }

  getUrl(): string {
    return this.url;
  }

  getThumbnails(): Image[] {
    return this.getUploaderAvatars();
  }

  getCommentText(): Description {
    return new Description(this.review.getString('why'), DESCRIPTION_PLAIN_TEXT);
  }

  getUploaderName(): string {
    const name: string | null = this.review.getString('name');
    return name === null ? '' : name;
  }

  getUploaderAvatars(): Image[] {
    return BandcampExtractorHelper.getImagesFromImageId(this.review.getLong('image_id'), false);
  }
}
