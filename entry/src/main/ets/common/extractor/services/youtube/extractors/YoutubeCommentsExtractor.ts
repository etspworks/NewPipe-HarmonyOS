/*
 * Port of org.schabi.newpipe.extractor.services.youtube.extractors.YoutubeCommentsExtractor
 * (NewPipeExtractor v0.26.5).
 *
 * YouTube returns comments in two shapes per item (commentRenderer / commentViewModel), and the
 * view-model shape carries half its data in a separate `mutations` array keyed by entity key —
 * collectCommentItem reproduces that join exactly.
 *
 * The source copies the continuation array and `remove()`s its last element; the ported JsonArray
 * has no remove(), so the copy is built without that element instead — same result.
 */

import { JsonArray, JsonObject, JsonValue, JsonWriter } from '../../../json/NanoJson';
import { Downloader, Request } from '../../../downloader/Downloader';
import { Localization } from '../../../downloader/Localization';
import { StreamingService } from '../../../core/StreamingService';
import { JsonUtils } from '../../../core/JsonUtils';
import { CommentsExtractor, CommentsInfoItemsCollector } from '../../../info/CommentsExtractor';
import { ListLinkHandler } from '../../../linkhandler/LinkHandler';
import { TimeAgoParser } from '../../../localization/TimeAgoParser';
import { ExtractionException, ParsingException } from '../../../exceptions/Exceptions';
import { isNullOrEmpty, removeNonDigitCharacters } from '../../../core/Utils';
import { CommentsInfoItem } from '../../../../../model/extractor/CommentsInfoItem';
import { InfoItemsPage } from '../../../../../model/extractor/ListExtractorInfoItemsPage';
import { Page } from '../../../../../model/extractor/Page';
import {
  getJsonPostResponse,
  getTextFromObject,
  prepareDesktopJsonBuilder
} from '../YoutubeParsingHelper';
import {
  YoutubeCommentsEUVMInfoItemExtractor,
  YoutubeCommentsInfoItemExtractor
} from './YoutubeCommentsInfoItemExtractor';

const COMMENT_VIEW_MODEL_KEY: string = 'commentViewModel';
const COMMENT_RENDERER_KEY: string = 'commentRenderer';

export class YoutubeCommentsExtractor extends CommentsExtractor {
  /** Whether the video has comments turned off, discovered while fetching the first page. */
  private commentsDisabled: boolean = false;
  private ajaxJson: JsonObject = new JsonObject();

  constructor(service: StreamingService, uiHandler: ListLinkHandler) {
    super(service, uiHandler);
  }

  async getInitialPage(): Promise<InfoItemsPage<CommentsInfoItem>> {
    if (this.commentsDisabled) {
      return YoutubeCommentsExtractor.getInfoItemsPageForDisabledComments();
    }
    return this.extractComments(this.ajaxJson);
  }

  /**
   * The token of the comments section of the `next` response, or null when the video has no
   * comments — which is exactly what sets commentsDisabled.
   */
  private findInitialCommentsToken(nextResponse: JsonObject): string | null {
    const contents: JsonArray | null = YoutubeCommentsExtractor.getJsonContents(nextResponse);
    // null for videos where comments are unavailable
    if (contents === null) {
      this.commentsDisabled = true;
      return null;
    }

    let token: string | null = null;
    for (const jObj of contents.streamAsJsonObjects()) {
      let targetId: string;
      try {
        targetId = JsonUtils.getString(jObj, 'itemSectionRenderer.targetId');
      } catch (ignored) {
        continue;
      }
      if (targetId !== 'comments-section') {
        continue;
      }
      try {
        token = JsonUtils.getString(
          jObj.getObject('itemSectionRenderer').getArray('contents').getObject(0),
          'continuationItemRenderer.continuationEndpoint.continuationCommand.token');
      } catch (ignored) {
        token = null;
      }
      break;
    }

    // The comments are disabled if no token could be obtained
    this.commentsDisabled = token === null;
    return token;
  }

  private static getJsonContents(nextResponse: JsonObject): JsonArray | null {
    try {
      return JsonUtils.getArray(nextResponse,
        'contents.twoColumnWatchNextResults.results.results.contents');
    } catch (e) {
      return null;
    }
  }

  private static getMutationPayloadFromEntityKey(mutations: JsonArray,
    commentKey: string): JsonObject {
    for (const mutation of mutations.streamAsJsonObjects()) {
      if (mutation.getString('entityKey') === commentKey) {
        return mutation.getObject('payload');
      }
    }
    throw new ParsingException('Could not get comment entity payload mutation');
  }

  private static getInfoItemsPageForDisabledComments(): InfoItemsPage<CommentsInfoItem> {
    return new InfoItemsPage<CommentsInfoItem>([], null, []);
  }

  private getNextPage(jsonObject: JsonObject): Page | null {
    const onResponseReceivedEndpoints: JsonArray =
      jsonObject.getArray('onResponseReceivedEndpoints');
    if (onResponseReceivedEndpoints.size() === 0) {
      return null;
    }

    let continuationItemsArray: JsonArray;
    try {
      const endpoint: JsonObject =
        onResponseReceivedEndpoints.getObject(onResponseReceivedEndpoints.size() - 1);
      continuationItemsArray = endpoint
        .getObject('reloadContinuationItemsCommand',
          endpoint.getObject('appendContinuationItemsAction'))
        .getArray('continuationItems');
    } catch (e) {
      return null;
    }

    if (continuationItemsArray.size() === 0) {
      return null;
    }

    const continuationItemRenderer: JsonObject = continuationItemsArray
      .getObject(continuationItemsArray.size() - 1)
      .getObject('continuationItemRenderer');

    const jsonPath: string = continuationItemRenderer.has('button')
      ? 'button.buttonRenderer.command.continuationCommand.token'
      : 'continuationEndpoint.continuationCommand.token';

    let continuation: string;
    try {
      continuation = JsonUtils.getString(continuationItemRenderer, jsonPath);
    } catch (e) {
      return null;
    }

    // The url is ignored by getPage(), which reads only the continuation
    return new Page(this.getUrl(), continuation);
  }

  async getPage(page: Page): Promise<InfoItemsPage<CommentsInfoItem>> {
    if (this.commentsDisabled) {
      return YoutubeCommentsExtractor.getInfoItemsPageForDisabledComments();
    }
    if (page === null || isNullOrEmpty(page.getId())) {
      throw new ParsingException('Page doesn\'t have the continuation.');
    }

    const localization: Localization = this.getExtractorLocalization();
    const body: ArrayBuffer = Request.utf8Body(JsonWriter.stringValue(
      (await prepareDesktopJsonBuilder(localization, this.getExtractorContentCountry()))
        .value('continuation', page.getId())
        .done()));

    const jsonObject: JsonObject = await getJsonPostResponse('next', body, localization);
    return this.extractComments(jsonObject);
  }

  private extractComments(jsonObject: JsonObject): InfoItemsPage<CommentsInfoItem> {
    const collector: CommentsInfoItemsCollector =
      new CommentsInfoItemsCollector(this.getServiceId());
    this.collectCommentsFrom(collector, jsonObject);
    return InfoItemsPage.fromCollector(collector, this.getNextPage(jsonObject));
  }

  private collectCommentsFrom(collector: CommentsInfoItemsCollector,
    jsonObject: JsonObject): void {
    const onResponseReceivedEndpoints: JsonArray =
      jsonObject.getArray('onResponseReceivedEndpoints');
    if (onResponseReceivedEndpoints.size() === 0) {
      return;
    }

    const commentsEndpoint: JsonObject =
      onResponseReceivedEndpoints.getObject(onResponseReceivedEndpoints.size() - 1);

    let path: string;
    if (commentsEndpoint.has('reloadContinuationItemsCommand')) {
      path = 'reloadContinuationItemsCommand.continuationItems';
    } else if (commentsEndpoint.has('appendContinuationItemsAction')) {
      path = 'appendContinuationItemsAction.continuationItems';
    } else {
      // No comments
      return;
    }

    let source: JsonArray;
    try {
      source = JsonUtils.getArray(commentsEndpoint, path);
    } catch (e) {
      // No comments
      return;
    }

    // A copy is needed so the continuation item can be dropped without mutating the object the
    // continuation is read from
    const values: Array<JsonValue | null> = source.toArray();
    const lastIndex: number = values.length - 1;
    if (values.length > 0 && source.getObject(lastIndex).has('continuationItemRenderer')) {
      values.length = lastIndex;
    }
    const contents: JsonArray = JsonArray.fromValues(values);

    // The mutations object returned in the comments' continuation; it carries parts of the
    // comment data when comments come back as view models
    const mutations: JsonArray = jsonObject.getObject('frameworkUpdates')
      .getObject('entityBatchUpdate')
      .getArray('mutations');

    const videoUrl: string = this.getUrl();
    const timeAgoParser: TimeAgoParser = this.getTimeAgoParser();

    for (const content of contents.streamAsJsonObjects()) {
      YoutubeCommentsExtractor.collectCommentItem(mutations, content, collector, videoUrl,
        timeAgoParser);
    }
  }

  private static collectCommentItem(mutations: JsonArray, content: JsonObject,
    collector: CommentsInfoItemsCollector, videoUrl: string,
    timeAgoParser: TimeAgoParser): void {
    if (content.has('commentThreadRenderer')) {
      const commentThreadRenderer: JsonObject = content.getObject('commentThreadRenderer');

      if (commentThreadRenderer.has(COMMENT_VIEW_MODEL_KEY)) {
        const commentViewModel: JsonObject =
          commentThreadRenderer.getObject(COMMENT_VIEW_MODEL_KEY)
            .getObject(COMMENT_VIEW_MODEL_KEY);
        collector.commit(new YoutubeCommentsEUVMInfoItemExtractor(
          commentViewModel,
          commentThreadRenderer.getObject('replies').getObject('commentRepliesRenderer'),
          YoutubeCommentsExtractor.getMutationPayloadFromEntityKey(mutations,
            commentViewModel.getString('commentKey', '') as string)
            .getObject('commentEntityPayload'),
          YoutubeCommentsExtractor.getMutationPayloadFromEntityKey(mutations,
            commentViewModel.getString('toolbarStateKey', '') as string)
            .getObject('engagementToolbarStateEntityPayload'),
          videoUrl,
          timeAgoParser));
      } else if (commentThreadRenderer.has('comment')) {
        collector.commit(new YoutubeCommentsInfoItemExtractor(
          commentThreadRenderer.getObject('comment').getObject(COMMENT_RENDERER_KEY),
          commentThreadRenderer.getObject('replies').getObject('commentRepliesRenderer'),
          videoUrl,
          timeAgoParser));
      }
    } else if (content.has(COMMENT_VIEW_MODEL_KEY)) {
      const commentViewModel: JsonObject = content.getObject(COMMENT_VIEW_MODEL_KEY);
      collector.commit(new YoutubeCommentsEUVMInfoItemExtractor(
        commentViewModel,
        null,
        YoutubeCommentsExtractor.getMutationPayloadFromEntityKey(mutations,
          commentViewModel.getString('commentKey', '') as string)
          .getObject('commentEntityPayload'),
        YoutubeCommentsExtractor.getMutationPayloadFromEntityKey(mutations,
          commentViewModel.getString('toolbarStateKey', '') as string)
          .getObject('engagementToolbarStateEntityPayload'),
        videoUrl,
        timeAgoParser));
    } else if (content.has(COMMENT_RENDERER_KEY)) {
      // commentRenderers come back directly for comment replies, so there is no
      // commentRepliesRenderer to pass; YouTube has only one reply level
      collector.commit(new YoutubeCommentsInfoItemExtractor(
        content.getObject(COMMENT_RENDERER_KEY), null, videoUrl, timeAgoParser));
    }
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
    const localization: Localization = this.getExtractorLocalization();

    const body: ArrayBuffer = Request.utf8Body(JsonWriter.stringValue(
      (await prepareDesktopJsonBuilder(localization, this.getExtractorContentCountry()))
        .value('videoId', this.getId())
        .done()));

    const initialToken: string | null = this.findInitialCommentsToken(
      await getJsonPostResponse('next', body, localization));
    if (initialToken === null) {
      return;
    }

    const ajaxBody: ArrayBuffer = Request.utf8Body(JsonWriter.stringValue(
      (await prepareDesktopJsonBuilder(localization, this.getExtractorContentCountry()))
        .value('continuation', initialToken)
        .done()));

    this.ajaxJson = await getJsonPostResponse('next', ajaxBody, localization);
  }

  isCommentsDisabled(): boolean {
    return this.commentsDisabled;
  }

  getCommentsCount(): number {
    this.assertPageFetched();
    if (this.commentsDisabled) {
      return -1;
    }

    const countText: JsonObject = this.ajaxJson.getArray('onResponseReceivedEndpoints')
      .getObject(0)
      .getObject('reloadContinuationItemsCommand')
      .getArray('continuationItems')
      .getObject(0)
      .getObject('commentsHeaderRenderer')
      .getObject('countText');

    const text: string | null = getTextFromObject(countText);
    const parsed: number =
      Number.parseInt(removeNonDigitCharacters(text === null ? '' : text), 10);
    if (Number.isNaN(parsed)) {
      throw new ExtractionException('Unable to get comments count');
    }
    return parsed;
  }
}
