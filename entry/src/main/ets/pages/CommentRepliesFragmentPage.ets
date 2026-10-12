/**
 * S3 - CommentRepliesFragment (screen_comment_replies), fragment_comments.xml +
 * comment_replies_header.xml + list_comment_item.xml.
 *
 * A top-level PUSHED page (R.id.fragment_holder), not a tab of VideoDetailFragment.
 *
 * Source facts this tree reproduces (CommentRepliesFragment.java, BaseListInfoFragment):
 *  - getListHeaderSupplier() inflates comment_replies_header and binds the PARENT comment into it
 *    IN FULL, never ellipsized. That header is a different component from the reply rows, so it
 *    is built here as the adapter's HFHolder slot, not as a CommentInfoItemHolder.
 *  - loadResult() performs NO network call: it fabricates a CommentRepliesInfo whose nextPage is
 *    commentsInfoItem.getReplies(), so even the FIRST visible page arrives through the pagination
 *    path, ExtractorHelper.getMoreCommentItems(serviceId, commentsInfoItem.getUrl(), nextPage).
 *    S4 wires that call; S3 only builds the structure it fills.
 *  - The fragment's single real constructor takes the parent comment, so this page reads it from
 *    the navigation parameters. With no parent comment there is nothing to show and nothing to
 *    fetch: it renders the error panel. It must never invent a comment, a url or a channel.
 *  - getItemViewMode() is FORCED to ItemViewMode.LIST.
 *  - The action-bar title is Localization.replyCount(parent.getReplyCount()).
 *
 * S5/S6 style this; no colours, spacing or typography are chosen here.
 */
import { router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

import { InfoItem } from '../common/extractor/core/InfoItem';
import { CommentsInfoItem } from '../model/extractor/CommentsInfoItem';
import { StreamInfoItem } from '../model/extractor/StreamInfoItem';
import { ChannelInfoItem } from '../model/extractor/ChannelInfoItem';
import { PlaylistInfoItem } from '../model/extractor/PlaylistInfoItem';
import { Description, DESCRIPTION_HTML } from '../model/extractor/Description';
import { Image as ExtractorImage } from '../model/extractor/Image';
import { Page } from '../model/extractor/Page';
import { ResolutionLevel } from '../model/enums/ImageResolutionLevel';
import { Localization } from '../common/i18n/Localization';
import { DateWrapper } from '../common/extractor/localization/DateWrapper';
import { ShareUtils } from '../common/share/ShareUtils';
import { ServiceLocator } from '../common/di/ServiceLocator';
import { choosePreferredImage, shouldLoadImages } from '../common/image/ImageLoader';
import { ExtractorHelper } from '../common/extractor/ExtractorHelper';
import { InfoCache } from '../common/extractor/InfoCache';
import { InfoItemsPage } from '../model/extractor/ListExtractorInfoItemsPage';
import { ErrorInfo } from '../model/app/ErrorInfo';
import { UserAction } from '../model/enums/UserAction';

import { InfoListAdapter, InfoItemDataSource, ItemViewMode } from '../components/InfoListAdapter';
import { InfoItemHolder } from '../components/InfoItemHolder';
import { HFHolder } from '../components/HFHolder';
import { CommentInfoItemHolder, LinkifiedCommentText } from '../components/CommentInfoItemHolder';
import { FallbackViewHolder } from '../components/FallbackViewHolder';
import { StreamMiniInfoItemHolder } from '../components/StreamMiniInfoItemHolder';
import { StreamInfoItemHolder } from '../components/StreamInfoItemHolder';
import { StreamGridInfoItemHolder } from '../components/StreamGridInfoItemHolder';
import { StreamCardInfoItemHolder } from '../components/StreamCardInfoItemHolder';
import { ChannelMiniInfoItemHolder } from '../components/ChannelMiniInfoItemHolder';
import { ChannelInfoItemHolder } from '../components/ChannelInfoItemHolder';
import { ChannelGridInfoItemHolder } from '../components/ChannelGridInfoItemHolder';
import { ChannelCardInfoItemHolder } from '../components/ChannelCardInfoItemHolder';
import { PlaylistMiniInfoItemHolder } from '../components/PlaylistMiniInfoItemHolder';
import { PlaylistInfoItemHolder } from '../components/PlaylistInfoItemHolder';
import { PlaylistGridInfoItemHolder } from '../components/PlaylistGridInfoItemHolder';
import { PlaylistCardInfoItemHolder } from '../components/PlaylistCardInfoItemHolder';
import { MiniPlayerBar } from '../components/MiniPlayerBar';
import { TopAppBar } from '../components/TopAppBar';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

const TAG: string = 'CommentRepliesFragmentPage';

/* //////////////////////////////////////////////////////////////////////////
// S5 - style tokens. The APP's own migrated resources wherever the source has
// one; a literal only where the value lives in the platform theme and has no
// resource of its own (the two textColor alphas), each with its measured
// rendering over the #EEEEEE surface. Same tokens as MainActivityPage.
////////////////////////////////////////////////////////////////////////// */

/** ?android:attr/windowBackground = @color/light_background_color (#EEEEEE). */
const COLOR_SURFACE: Resource = $r('app.color.background');
/** ?android:textColorPrimary, 87% black - measured #1F1F1F over the surface. */
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');
/** ?android:textColorSecondary, 54% black - measured #6D6D6D over the surface. */
const COLOR_ON_SURFACE_SECONDARY: Resource = $r('app.color.on_surface_variant');
/** ?attr/separator_color = @color/light_separator_color - measured #BFBFBF. */
const COLOR_DIVIDER: Resource = $r('app.color.separator');
/** @color/placeholder_background - the avatar circle before the image arrives. */
const COLOR_AVATAR_BG: Resource = $r('app.color.placeholder_background');

/** comment_replies_header: authorAvatar is 42dp square, CircularImageView. */
const AVATAR_SIZE: number = 42;
/** thumbsUpImage / heartImage / pinnedImage are 21sp in the header. */
const HEADER_ICON_SIZE: number = 21;
/** authorAvatar / commentContent marginStart|End. */
const SCREEN_PADDING: number = 16;
/** authorName marginStart, thumbsUpCount marginEnd when a badge follows it. */
const SPACE_M: number = 8;
/** heartImage marginEnd. */
const SPACE_XS: number = 4;
/** thumbsUpImage marginEnd = @dimen/video_item_detail_like_margin. */
const SPACE_LIKE: number = 5;

/** authorName: textAppearanceLarge, 16sp. */
const FONT_AUTHOR: number = 16;
/** uploadDate / thumbsUpCount / commentContent: 14sp. */
const FONT_BODY: number = 14;

/* //////////////////////////////////////////////////////////////////////////
// S6 - the empty / loading / error visuals, from the same token set.
////////////////////////////////////////////////////////////////////////// */

/** ?attr/colorAccent = @color/light_youtube_accent_color - the indeterminate spinner's tint. */
const COLOR_ACCENT: Resource = $r('app.color.accent');
/**
 * MINI_PLAYER_HEIGHT from components/MiniPlayerBar.ets, which keeps it private. Needed here
 * because the bar overlays this page's list rather than shortening it.
 */
const MINI_PLAYER_BAR_HEIGHT: number = 54;
/** ?attr/colorPrimary = @color/light_youtube_primary_color - ServiceColoredButton's fill. */
const COLOR_PRIMARY: Resource = $r('app.color.primary');
/** @color/subscribe_text_color (#FFFFFF) - ServiceColoredButton's android:textColor. */
const COLOR_ON_PRIMARY: Resource = $r('app.color.subscribe_text_color');

/** empty_state_view paddingTop, measured from the list's top edge. */
const EMPTY_TOP_PADDING: number = 85;
/** The kaomoji: monospace, 35sp, marginBottom 10dp. */
const FONT_KAOMOJI: number = 35;
const SPACE_KAOMOJI: number = 10;
/** empty_state_desc: 24sp. */
const FONT_EMPTY_DESC: number = 24;

/** error_message_view and every error button: 16sp. */
const FONT_ERROR: number = 16;
/** The include's layout_marginTop (16dp) plus error_panel's own 16dp padding. */
const ERROR_PANEL_TOP: number = SCREEN_PADDING * 2;
/** error_action_button marginTop. */
const SPACE_ERROR_ACTION: number = SPACE_M;
/** error_retry_button / error_open_in_browser marginTop. */
const SPACE_ERROR_BUTTON: number = SPACE_XS;
/** Widget.AppCompat.Button.Colored's corner radius and horizontal content inset. */
const BUTTON_RADIUS: number = 2;
const BUTTON_PADDING: number = SCREEN_PADDING;

/**
 * The navigation parameters that stand in for `new CommentRepliesFragment(commentsInfoItem)`.
 * ArkUI router parameters are deep-copied, so a CommentsInfoItem instance would arrive without
 * its prototype: the pushing screen passes the parent comment's fields and this page rebuilds
 * the model. Every field comes from the pushing screen's own item - nothing here is a literal.
 */
class CommentRepliesParams {
  serviceId: number = 0;
  /** commentsInfoItem.getUrl(): the STREAM url the replies are paged against. */
  url: string = '';
  name: string = '';
  commentId: string = '';
  uploaderName: string = '';
  uploaderUrl: string = '';
  uploaderAvatarUrl: string = '';
  textualUploadDate: string = '';
  uploadDateMillis: number = -1;
  commentText: string = '';
  likeCount: number = -1;
  replyCount: number = -1;
  pinned: boolean = false;
  hearted: boolean = false;
  /** commentsInfoItem.getReplies(), the Page CommentRepliesInfo sets as its nextPage. */
  repliesPageUrl: string = '';
  repliesPageId: string = '';
}

/** Reads a string parameter without ever fabricating a value for a missing one. */
function paramString(params: Record<string, Object>, key: string): string {
  const raw: Object | undefined = params[key];
  return raw === undefined || raw === null ? '' : raw.toString();
}

function paramNumber(params: Record<string, Object>, key: string, fallback: number): number {
  const raw: Object | undefined = params[key];
  if (raw === undefined || raw === null) {
    return fallback;
  }
  const value: number = Number(raw.toString());
  return Number.isNaN(value) ? fallback : value;
}

function paramBoolean(params: Record<string, Object>, key: string): boolean {
  const raw: Object | undefined = params[key];
  return raw !== undefined && raw !== null && raw.toString() === 'true';
}

function readParams(params: Record<string, Object>): CommentRepliesParams {
  const parsed: CommentRepliesParams = new CommentRepliesParams();
  parsed.serviceId = paramNumber(params, 'serviceId', 0);
  parsed.url = paramString(params, 'url');
  parsed.name = paramString(params, 'name');
  parsed.commentId = paramString(params, 'commentId');
  parsed.uploaderName = paramString(params, 'uploaderName');
  parsed.uploaderUrl = paramString(params, 'uploaderUrl');
  parsed.uploaderAvatarUrl = paramString(params, 'uploaderAvatarUrl');
  parsed.textualUploadDate = paramString(params, 'textualUploadDate');
  parsed.uploadDateMillis = paramNumber(params, 'uploadDateMillis', -1);
  parsed.commentText = paramString(params, 'commentText');
  parsed.likeCount = paramNumber(params, 'likeCount', -1);
  parsed.replyCount = paramNumber(params, 'replyCount', -1);
  parsed.pinned = paramBoolean(params, 'pinned');
  parsed.hearted = paramBoolean(params, 'hearted');
  parsed.repliesPageUrl = paramString(params, 'repliesPageUrl');
  parsed.repliesPageId = paramString(params, 'repliesPageId');
  return parsed;
}

/** Rebuilds the parent CommentsInfoItem the source's constructor received. */
function toCommentsInfoItem(parsed: CommentRepliesParams): CommentsInfoItem {
  const item: CommentsInfoItem =
    new CommentsInfoItem(parsed.serviceId, parsed.url, parsed.name);
  item.commentId = parsed.commentId;
  item.uploaderName = parsed.uploaderName;
  item.uploaderUrl = parsed.uploaderUrl;
  if (parsed.uploaderAvatarUrl.length > 0) {
    item.uploaderAvatars = [
      new ExtractorImage(parsed.uploaderAvatarUrl, ExtractorImage.HEIGHT_UNKNOWN, ExtractorImage.WIDTH_UNKNOWN,
        ResolutionLevel.UNKNOWN)
    ];
  }
  item.textualUploadDate = parsed.textualUploadDate;
  if (parsed.uploadDateMillis >= 0) {
    item.uploadDate = new DateWrapper(new Date(parsed.uploadDateMillis));
  }
  item.commentText = new Description(parsed.commentText, DESCRIPTION_HTML);
  item.likeCount = parsed.likeCount;
  item.replyCount = parsed.replyCount;
  item.pinned = parsed.pinned;
  item.heartedByUploader = parsed.hearted;
  if (parsed.repliesPageUrl.length > 0 || parsed.repliesPageId.length > 0) {
    item.replies = new Page(parsed.repliesPageUrl.length === 0 ? null : parsed.repliesPageUrl,
      parsed.repliesPageId.length === 0 ? null : parsed.repliesPageId);
  }
  return item;
}

/**
 * The parameters a replies push carries, built from the parent comment's own item. Exported
 * because CommentsFragmentPage pushes this page too and must send the SAME 16-field payload
 * `CommentRepliesParams` reads - the source hands the whole CommentsInfoItem to the fragment's
 * constructor, so a partial push leaves the header unbound and getReplies() null.
 */
export function paramsForComment(item: CommentsInfoItem): Record<string, Object> {
  const avatar: string | null = choosePreferredImage(item.getUploaderAvatars());
  const replies: Page | null = item.getReplies();
  const uploadDate: DateWrapper | null = item.getUploadDate();
  const params: Record<string, Object> = {
    'serviceId': `${item.getServiceId()}`,
    'url': item.getUrl(),
    'name': item.getName(),
    'commentId': item.getCommentId(),
    'uploaderName': item.getUploaderName(),
    'uploaderUrl': item.getUploaderUrl(),
    'uploaderAvatarUrl': avatar === null ? '' : avatar,
    'textualUploadDate': item.getTextualUploadDate(),
    'uploadDateMillis': uploadDate === null ? '-1' : `${uploadDate.getInstant().getTime()}`,
    'commentText': item.getCommentText().getContent(),
    'likeCount': `${item.getLikeCount()}`,
    'replyCount': `${item.getReplyCount()}`,
    'pinned': `${item.getIsPinned()}`,
    'hearted': `${item.getIsHeartedByUploader()}`,
    'repliesPageUrl': replies === null || replies.getUrl() === null ? '' : `${replies.getUrl()}`,
    'repliesPageId': replies === null || replies.getId() === null ? '' : `${replies.getId()}`
  };
  return params;
}

@Entry
@Component
export struct CommentRepliesFragmentPage {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  /** Whether the docked bar is showing, reported by MiniPlayerBar - the list's bottom inset. */
  @State playerBarVisible: boolean = false;

  /** The parent comment - `@State CommentsInfoItem commentsInfoItem`, the fragment's argument. */
  @State header: CommentsInfoItem | null = null;
  /** InfoListAdapter.infoItemList: the loaded reply pages, appended page by page. */
  @State repliesList: InfoItemDataSource = new InfoItemDataSource();
  /** BaseListInfoFragment.handleResult() -> setTitle(Localization.replyCount(...)). */
  @State screenTitle: string = '';
  /** CoilHelper.loadAvatar(binding.authorAvatar, ...); '' when there is no avatar to load. */
  @State authorAvatar: string = '';
  /** showLoading() / hideLoading(): the indeterminate loading_progress_bar. */
  @State isLoading: boolean = false;
  /** ErrorPanelHelper: null while there is no error to show. */
  @State errorInfo: string | null = null;
  /** How many replies the adapter holds - what showEmptyState() tests. */
  @State loadedCount: number = 0;
  /** showListFooter(hasMoreItems()): Page.isValid(currentNextPage). */
  @State hasMoreItems: boolean = false;
  /** ErrorPanelHelper's openInBrowserUrl: the button is GONE while it is null. */
  @State openInBrowserUrl: string | null = null;
  /** ErrorPanelHelper's recaptcha / report action; GONE while it is empty. */
  @State errorActionLabel: string = '';
  /** errorRetryButton.isVisible = retryShouldBeShown, and only when errorInfo.isRetryable. */
  @State errorRetryable: boolean = false;
  /** One TextEllipsizer per row: the comment ids currently toggled open. */
  @State expandedComments: string[] = [];

  /** getItemViewMode() is overridden to LIST on this screen, whatever the user's preference. */
  private itemViewMode: ItemViewMode = ItemViewMode.LIST;
  /** BaseListFragment.useMiniVariant - false here, as on every non-related-items list. */
  private useMiniVariant: boolean = false;
  /** currentNextPage: the parent comment's replies Page, then each page's own nextPage. */
  private currentNextPage: Page | null = null;
  /** BaseStateFragment.lastPanelError: the ErrorInfo the panel shows, for its action button. */
  private lastPanelError: ErrorInfo | null = null;
  /** onDestroyView() -> disposables.clear(): a result arriving after this is dropped. */
  private disposed: boolean = false;

  aboutToAppear(): void {
    const raw: Record<string, Object> | undefined =
      router.getParams() as Record<string, Object> | undefined;
    if (raw === undefined || raw === null) {
      // No parent comment: the source cannot construct the fragment at all. Show the error
      // panel rather than an empty screen, and never fabricate a comment to fill it. There is
      // nothing to reload either, so this ErrorInfo is not retryable and no retry button shows.
      hilog.warn(0x0000, TAG, 'opened without a parent comment');
      this.showError(ErrorInfo.fromMessage([], UserAction.REQUESTED_COMMENT_REPLIES,
        'CommentRepliesFragment without a parent comment', null, 'general_error'));
      return;
    }
    const parsed: CommentRepliesParams = readParams(raw);
    const item: CommentsInfoItem = toCommentsInfoItem(parsed);
    this.header = item;
    this.authorAvatar = parsed.uploaderAvatarUrl;
    this.screenTitle = Localization.replyCount(item.getReplyCount());
    // loadResult(): CommentRepliesInfo's nextPage IS the parent comment's replies page.
    this.currentNextPage = item.getReplies();
    this.hasMoreItems = Page.isValid(this.currentNextPage);
    // handleResult(): the adapter is empty and CommentRepliesInfo carries no related items, so
    // the first visible page is fetched through loadMoreItems() - the only load path there is.
    this.loadMoreItems();
  }

  /** onDestroyView(): disposables.clear(). */
  aboutToDisappear(): void {
    this.disposed = true;
  }

  /*//////////////////////////////////////////////////////////////////////////
  // comment_replies_header - the parent comment, in full
  //////////////////////////////////////////////////////////////////////////*/

  private headerUploaderName(): string {
    return this.header === null ? ''
      : Localization.localizeUserName(this.header.getUploaderName());
  }

  /** Localization.relativeTimeOrTextual(ctx, item.getUploadDate(), item.getTextualUploadDate()). */
  private headerUploadDate(): string {
    if (this.header === null) {
      return '';
    }
    const parsed: DateWrapper | null = this.header.getUploadDate();
    const when: string | null = Localization.relativeTimeOrTextual(
      parsed === null ? null : parsed.getInstant().getTime(),
      this.header.getTextualUploadDate());
    return when === null ? '' : when;
  }

  private headerLikeCount(): string {
    return this.header === null ? '' : Localization.likeCount(this.header.getLikeCount());
  }

  /**
   * TextLinkifier.fromDescription(binding.commentContent, item.getCommentText(), ...): the parent
   * comment is shown in FULL - the header has no TextEllipsizer.
   */
  private headerCommentText(): string {
    return this.header === null ? '' : this.header.getCommentText().getContent();
  }

  /** getServiceById(item.getServiceId()), TextLinkifier's relatedInfoService. */
  private headerServiceId(): number {
    return this.header === null ? 0 : this.header.getServiceId();
  }

  /** item.getUrl(), TextLinkifier's relatedStreamUrl. */
  private headerStreamUrl(): string {
    return this.header === null ? '' : this.header.getUrl();
  }

  private headerIsHearted(): boolean {
    return this.header !== null && this.header.getIsHeartedByUploader();
  }

  private headerIsPinned(): boolean {
    return this.header !== null && this.header.getIsPinned();
  }

  /** thumbsUpCount marginEnd: 8dp with a badge after it, else layout_goneMarginEnd 16dp. */
  private headerLikeMarginEnd(): number {
    return this.headerIsHearted() || this.headerIsPinned() ? SPACE_M : SCREEN_PADDING;
  }

  @Builder
  listHeader() {
    // onCreateViewHolder(HEADER_TYPE): new HFHolder(headerSupplier.get()).
    HFHolder() {
      Column() {
        Row() {
          Row() {
            // ImageStrategy.shouldLoadImages() ? VISIBLE : GONE
            if (shouldLoadImages()) {
              Image(this.authorAvatar)
                .id('authorAvatar')
                .width(AVATAR_SIZE)
                .height(AVATAR_SIZE)
                // shapeAppearance="@style/CircularImageView" over placeholder_person.
                .borderRadius(AVATAR_SIZE / 2)
                .backgroundColor(COLOR_AVATAR_BG)
                .alt($r('app.media.placeholder_person'))
                .objectFit(ImageFit.Cover)
                .margin({ right: SPACE_M })
            }
            Column() {
              Text(this.headerUploaderName())
                .id('authorName')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .fontSize(FONT_AUTHOR)
                .fontColor(COLOR_ON_SURFACE)
              Text(this.headerUploadDate())
                .id('uploadDate')
                .maxLines(1)
                .fontSize(FONT_BODY)
                .fontColor(COLOR_ON_SURFACE_SECONDARY)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          // R.id.authorTouchArea spans avatar + name + date, stopping at thumbsUpImage.
          .id('authorTouchArea')
          .layoutWeight(1)
          .onClick(() => {
            this.openCommentAuthor();
          })

          Image($r('app.media.ic_thumb_up'))
            .id('thumbsUpImage')
            .accessibilityText($r('app.string.detail_likes_img_view_description'))
            .width(HEADER_ICON_SIZE)
            .height(HEADER_ICON_SIZE)
            .margin({ right: SPACE_LIKE })
          Text(this.headerLikeCount())
            .id('thumbsUpCount')
            .fontSize(FONT_BODY)
            .fontColor(COLOR_ON_SURFACE_SECONDARY)
            .margin({ right: this.headerLikeMarginEnd() })
          if (this.headerIsHearted()) {
            Image($r('app.media.ic_heart'))
              .id('heartImage')
              .accessibilityText($r('app.string.detail_heart_img_view_description'))
              .width(HEADER_ICON_SIZE)
              .height(HEADER_ICON_SIZE)
              .margin({ right: SPACE_XS })
          }
          if (this.headerIsPinned()) {
            Image($r('app.media.ic_pin'))
              .id('pinnedImage')
              .accessibilityText($r('app.string.detail_pinned_comment_view_description'))
              .width(HEADER_ICON_SIZE)
              .height(HEADER_ICON_SIZE)
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        // The parent comment is shown in FULL: the header has no TextEllipsizer, so no clamp.
        LinkifiedCommentText({
          textId: 'commentContent',
          content: this.headerCommentText(),
          serviceId: this.headerServiceId(),
          relatedStreamUrl: this.headerStreamUrl(),
          fontSizeFp: FONT_BODY,
          // commentContent layout_marginTop="16dp", measured from uploadDate's baseline box.
          marginTopVp: SCREEN_PADDING
        })
      }
      .width('100%')
      // 16dp inset all round, then the 1px separator_color rule the header ends on and the
      // 8dp that follows it - the XML's trailing View, drawn as this block's bottom border.
      .padding({
        left: SCREEN_PADDING,
        right: SCREEN_PADDING,
        top: SCREEN_PADDING,
        bottom: SCREEN_PADDING
      })
      .border({ width: { bottom: 1 }, color: { bottom: COLOR_DIVIDER } })
      .margin({ bottom: SPACE_M })
    }
  }

  /** pignate_footer: the indeterminate load-more row showListFooter(hasMoreItems()) toggles. */
  @Builder
  listFooter() {
    // GATED HERE, not only through InfoListAdapter's showFooter: that is an UNDECORATED member of
    // the child struct, so it keeps whatever value it had when the list was first built. The first
    // page is fetched from aboutToAppear, so it was built with isLoading true and the spinner sat
    // at the foot of the list for ever after the page had arrived - which is the "loader that never
    // disappears". This @Builder runs in the PAGE's context and re-runs on its @State, so the row
    // empties the moment the request finishes.
    if (this.hasMoreItems && this.isLoading) {
      // onCreateViewHolder(FOOTER_TYPE): new HFHolder(pignate_footer).
      HFHolder() {
        Row() {
          LoadingProgress()
            .id('pignate_footer')
            .width(32)
            .height(32)
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
      }
    }
  }

  /*//////////////////////////////////////////////////////////////////////////
  // InfoListAdapter.getItemViewType() + onCreateViewHolder() + onBindViewHolder()
  //////////////////////////////////////////////////////////////////////////*/

  @Builder
  itemRow(item: InfoItem) {
    InfoItemHolder({
      onSelected: () => {
        this.onItemSelected(item);
      },
      onHeld: () => {
        this.onItemHeld(item);
      }
    }) {
      this.holderFor(item)
    }
  }

  @Builder
  holderFor(item: InfoItem) {
    if (item instanceof CommentsInfoItem) {
      // COMMENT_HOLDER_TYPE - the only type this screen's list ever holds.
      CommentInfoItemHolder({
        item: item as CommentsInfoItem,
        expanded: this.isExpanded(item as CommentsInfoItem),
        onAuthor: () => {
          this.openCommentAuthorOf(item as CommentsInfoItem);
        },
        onReplies: () => {
          this.openCommentReplies(item as CommentsInfoItem);
        }
      })
    } else if (item instanceof StreamInfoItem) {
      if (this.itemViewMode === ItemViewMode.CARD) {
        StreamCardInfoItemHolder({ item: item as StreamInfoItem })
      } else if (this.itemViewMode === ItemViewMode.GRID) {
        StreamGridInfoItemHolder({ item: item as StreamInfoItem })
      } else if (this.useMiniVariant) {
        StreamMiniInfoItemHolder({ item: item as StreamInfoItem })
      } else {
        StreamInfoItemHolder({ item: item as StreamInfoItem })
      }
    } else if (item instanceof ChannelInfoItem) {
      if (this.itemViewMode === ItemViewMode.CARD) {
        ChannelCardInfoItemHolder({ item: item as ChannelInfoItem })
      } else if (this.itemViewMode === ItemViewMode.GRID) {
        ChannelGridInfoItemHolder({ item: item as ChannelInfoItem })
      } else if (this.useMiniVariant) {
        ChannelMiniInfoItemHolder({ item: item as ChannelInfoItem })
      } else {
        ChannelInfoItemHolder({ item: item as ChannelInfoItem })
      }
    } else if (item instanceof PlaylistInfoItem) {
      if (this.itemViewMode === ItemViewMode.CARD) {
        PlaylistCardInfoItemHolder({ item: item as PlaylistInfoItem })
      } else if (this.itemViewMode === ItemViewMode.GRID) {
        PlaylistGridInfoItemHolder({ item: item as PlaylistInfoItem })
      } else if (this.useMiniVariant) {
        PlaylistMiniInfoItemHolder({ item: item as PlaylistInfoItem })
      } else {
        PlaylistInfoItemHolder({ item: item as PlaylistInfoItem })
      }
    } else {
      // onCreateViewHolder()'s default: an item type no holder claims.
      FallbackViewHolder()
    }
  }

  /*//////////////////////////////////////////////////////////////////////////
  // Row gestures
  //////////////////////////////////////////////////////////////////////////*/

  private isExpanded(item: CommentsInfoItem): boolean {
    return this.expandedComments.indexOf(item.getCommentId()) >= 0;
  }

  /** itemView.setOnClickListener -> textEllipsizer.toggle(). */
  private onItemSelected(item: InfoItem): void {
    if (!(item instanceof CommentsInfoItem)) {
      hilog.debug(0x0000, TAG, 'row selected for a non-comment item on a replies list');
      return;
    }
    const id: string = (item as CommentsInfoItem).getCommentId();
    const at: number = this.expandedComments.indexOf(id);
    const next: string[] = this.expandedComments.slice();
    if (at >= 0) {
      next.splice(at, 1);
    } else {
      next.push(id);
    }
    this.expandedComments = next;
    // LazyForEach keeps the cached child for an unchanged key, so the row only re-reads
    // `expanded` when its own index is notified - without this the tap is a visual no-op.
    this.repliesList.notifyItemChanged(this.repliesList.getItemsList().indexOf(item));
  }

  /** itemView.setOnLongClickListener -> ShareUtils.copyToClipboard(commentText). */
  private onItemHeld(item: InfoItem): void {
    if (!(item instanceof CommentsInfoItem)) {
      hilog.debug(0x0000, TAG, 'long press on a non-comment item on a replies list');
      return;
    }
    const share: ShareUtils = ServiceLocator.get().share;
    share.copyToClipboard((item as CommentsInfoItem).getCommentText().getContent());
  }

  /** NavigationHelper.openCommentAuthorIfPresent(activity, item): a NO-OP with no uploader url. */
  private openCommentAuthorOf(item: CommentsInfoItem): void {
    const uploaderUrl: string = item.getUploaderUrl();
    if (uploaderUrl.length === 0) {
      hilog.debug(0x0000, TAG, 'comment author has no channel url');
      return;
    }
    const params: Record<string, Object> = {
      'serviceId': `${item.getServiceId()}`,
      'url': uploaderUrl,
      'name': item.getUploaderName()
    };
    router.pushUrl({ url: 'pages/ChannelFragmentPage', params: params });
  }

  /** binding.authorTouchArea.setOnClickListener on the parent comment. */
  private openCommentAuthor(): void {
    if (this.header === null) {
      hilog.debug(0x0000, TAG, 'no parent comment to open the author of');
      return;
    }
    this.openCommentAuthorOf(this.header);
  }

  /**
   * NavigationHelper.openCommentRepliesFragment(): closeCommentRepliesFragments() pops every
   * replies fragment already on the stack first, so at most one is ever open - router.replaceUrl
   * on THIS page is that pop plus the push.
   */
  private openCommentReplies(item: CommentsInfoItem): void {
    router.replaceUrl({
      url: 'pages/CommentRepliesFragmentPage',
      params: paramsForComment(item)
    });
  }

  /*//////////////////////////////////////////////////////////////////////////
  // Data loading - S4 wires ExtractorHelper.getMoreCommentItems() onto these
  //////////////////////////////////////////////////////////////////////////*/

  /** OnScrollBelowItemsListener -> loadMoreItems(), and the first page arrives this way too. */
  private async loadMoreItems(): Promise<void> {
    const parent: CommentsInfoItem | null = this.header;
    const page: Page | null = this.currentNextPage;
    if (this.isLoading || parent === null || page === null || !Page.isValid(page)) {
      return;
    }
    // showLoading(): the spinner replaces the empty state and the error panel goes away.
    this.isLoading = true;
    this.hideErrorPanel();
    try {
      // loadMoreItemsLogic(), verbatim: commentsInfoItem.getUrl() is the STREAM url the replies
      // are paged against, and currentNextPage starts as the parent comment's replies Page.
      const result: InfoItemsPage<CommentsInfoItem> = await ExtractorHelper.getMoreCommentItems(
        parent.getServiceId(), parent.getUrl(), page);
      if (this.disposed) {
        return;
      }
      // handleNextItems(result): next page, append, footer, then the page's own gather errors.
      this.currentNextPage = result.getNextPage();
      this.repliesList.addItems(result.getItems());
      this.loadedCount = this.repliesList.totalCount();
      this.hasMoreItems = Page.isValid(this.currentNextPage);
      const errors: Error[] = result.getErrors();
      if (errors.length > 0) {
        this.showErrorPanelOrSnackbar(ErrorInfo.fromThrowables(errors,
          UserAction.REQUESTED_COMMENT_REPLIES, 'Get next items of: ' + parent.getUrl(),
          parent.getServiceId(), parent.getUrl()));
      }
    } catch (err) {
      if (!this.disposed) {
        // A page that failed is not a page that is still coming: leave hasMoreItems set and the
        // footer keeps spinning for a request that will never be retried on its own.
        this.hasMoreItems = false;
        this.showErrorPanelOrSnackbar(ErrorInfo.fromThrowable(err as Error,
          UserAction.REQUESTED_COMMENT_REPLIES, 'Loading more items: ' + parent.getUrl(),
          parent.getServiceId(), parent.getUrl()));
      }
    } finally {
      // hideLoading(): the request is finished either way - Rule 8's release point.
      this.isLoading = false;
    }
  }

  /**
   * BaseListInfoFragment.dynamicallyShowErrorPanelOrSnackbar(): the panel covers only an EMPTY
   * list; once replies are showing a failure is a snackbar, so loaded content is never hidden.
   */
  private showErrorPanelOrSnackbar(info: ErrorInfo): void {
    if (this.repliesList.isEmpty()) {
      this.showError(info);
    } else {
      this.isLoading = false;
      ServiceLocator.get().errorReporter.showSnackbar(info);
    }
  }

  /** BaseStateFragment.showError() + ErrorPanelHelper.showError(): what each button shows. */
  private showError(info: ErrorInfo): void {
    // handleError(): the cache is dropped so a retry re-fetches instead of replaying the failure.
    InfoCache.getInstance().clearCache();
    this.isLoading = false;
    this.lastPanelError = info;
    this.errorInfo = this.errorMessageOf(info);
    // The retry button shows only for a retryable error; the action button is the recaptcha
    // challenge, else the report action, else nothing; open-in-browser only with a url to open.
    this.errorRetryable = info.isRetryable;
    this.errorActionLabel = info.recaptchaUrl !== null
      ? Localization.getString('recaptcha_solve')
      : (info.isReportable ? Localization.getString('error_snackbar_action') : '');
    this.openInBrowserUrl = info.openInBrowserUrl;
  }

  /** ErrorPanelHelper.hide() + BaseStateFragment.hideErrorPanel(): lastPanelError = null. */
  private hideErrorPanel(): void {
    this.lastPanelError = null;
    this.errorInfo = null;
    this.errorRetryable = false;
    this.errorActionLabel = '';
    this.openInBrowserUrl = null;
  }

  /** ErrorInfo.getMessage(context): the migrated string name plus its format arguments. */
  private errorMessageOf(info: ErrorInfo): string {
    return info.message.formatArgs.length === 0
      ? Localization.getString(info.message.stringName)
      : Localization.getStringArgs(info.message.stringName, info.message.formatArgs);
  }

  /** ErrorPanelHelper's retry button -> reloadContent(). */
  private reloadContent(): void {
    if (this.header === null) {
      hilog.debug(0x0000, TAG, 'nothing to reload without a parent comment');
      return;
    }
    this.hideErrorPanel();
    this.repliesList.clearItems();
    this.loadedCount = 0;
    this.currentNextPage = this.header.getReplies();
    this.hasMoreItems = Page.isValid(this.currentNextPage);
    this.loadMoreItems();
  }

  /** ErrorPanelHelper:88-91 ShareUtils.openUrlInBrowser(ctx, errorInfo.openInBrowserUrl). */
  private openErrorInBrowser(): void {
    const url: string | null = this.openInBrowserUrl;
    if (url === null) {
      return;
    }
    const share: ShareUtils = ServiceLocator.get().share;
    share.openUrlInBrowser(url);
  }

  /** ErrorPanelHelper:101-107 showAndSetErrorButtonAction (recaptcha / report). */
  private runErrorAction(): void {
    const info: ErrorInfo | null = this.lastPanelError;
    if (info === null) {
      return;
    }
    const recaptchaUrl: string | null = info.recaptchaUrl;
    if (recaptchaUrl !== null) {
      // startActivityForResult(ReCaptchaActivity, RECAPTCHA_URL_EXTRA).
      const params: Record<string, Object> = { 'recaptcha_url': recaptchaUrl };
      router.pushUrl({ url: 'pages/ReCaptchaActivityPage', params: params });
      return;
    }
    if (info.isReportable) {
      // ErrorUtil.openActivity(context, errorInfo).
      ServiceLocator.get().errorReporter.openActivity(info);
    }
  }

  /** ErrorPanelHelper:57 errorTextView - '' while there is no error panel showing. */
  private errorText(): string {
    return this.errorInfo === null ? '' : this.errorInfo;
  }

  /**
   * showEmptyState(): the kaomoji panel is shown only when the adapter is empty AND nothing is
   * loading or failing - it never renders beside loaded replies.
   */
  private showEmptyState(): boolean {
    return this.loadedCount === 0 && !this.isLoading && this.errorInfo === null;
  }

  build() {
    Column() {
      // MainActivity's toolbar, which this fragment sits under in fragment_holder: Up runs
      // onBackPressed() back to the comments, and the title is setTitle(replyCount(...)).
      TopAppBar({
        title: this.screenTitle,
        hasTitle: this.screenTitle.length > 0,
        hasNavigateUp: true,
        onNavigateUp: (): void => {
          router.back();
        }
      })

      Stack() {
        // fragment_comments: items_list fills the fragment; everything else overlays it.
        InfoListAdapter({
          dataSource: this.repliesList,
          hasHeader: true,
          // showListFooter() is the LOAD-MORE spinner, not a "there is more" badge: it belongs to
          // a request that is in flight. Gated on hasMoreItems alone it sat at the bottom of a
          // short replies list forever, because nothing was ever going to fetch the next page.
          showFooter: this.hasMoreItems && this.isLoading,
          onReachEnd: () => {
            this.loadMoreItems();
          },
          // A @Builder passed as `this.listHeader` re-binds `this` to the CHILD (InfoListAdapter),
          // so every page member the builder touches reads back undefined. The arrow-function form
          // keeps `this` on this page - see the @BuilderParam doc, "this in the function body must
          // point to the correct object".
          header: (): void => {
            this.listHeader();
          },
          footer: (): void => {
            this.listFooter();
          },
          row: (item: InfoItem): void => {
            this.itemRow(item);
          }
        })
          // The bar overlays this list instead of shortening it - the root here is a Stack, not a
          // Column - so the list gives back the bar's height while the bar is up, or its last reply
          // would sit underneath it.
          .padding({ bottom: this.playerBarVisible ? MINI_PLAYER_BAR_HEIGHT : 0 })

        if (this.isLoading) {
          // layout_centerInParent - the Stack's own default alignment puts it there.
          LoadingProgress()
            .id('loading_progress_bar')
            .width(48)
            .height(48)
            .color(COLOR_ACCENT)
        }

        if (this.showEmptyState()) {
          Column() {
            // fontFamily="monospace", textSize 35sp, layout_marginBottom 10dp.
            Text('(╯°-°)╯')
              .fontFamily('monospace')
              .fontSize(FONT_KAOMOJI)
              .fontColor(COLOR_ON_SURFACE)
              .margin({ bottom: SPACE_KAOMOJI })
            Text($r('app.string.empty_view_no_comments'))
              .id('empty_state_desc')
              .fontSize(FONT_EMPTY_DESC)
              .fontColor(COLOR_ON_SURFACE)
              .textAlign(TextAlign.Center)
          }
          .id('empty_state_view')
          // layout_centerHorizontal + paddingTop 85dp: the panel hangs from the TOP of the list,
          // it is not centred in it. Transparent hit-testing so it never swallows a list touch.
          .width('100%')
          .height('100%')
          .padding({ top: EMPTY_TOP_PADDING })
          .justifyContent(FlexAlign.Start)
          .alignItems(HorizontalAlign.Center)
          .hitTestBehavior(HitTestMode.Transparent)
        }

        if (this.errorInfo !== null) {
          Column() {
            Text(this.errorText())
              .id('error_message_view')
              .fontSize(FONT_ERROR)
              .fontWeight(FontWeight.Bold)
              .fontColor(COLOR_ON_SURFACE)
              .textAlign(TextAlign.Center)
            // The three buttons carry @style/ServiceColoredButton: colorButtonNormal is
            // ?attr/colorPrimary and the label is @color/subscribe_text_color, all-caps.
            if (this.errorActionLabel.length > 0) {
              Button(this.errorActionLabel.toUpperCase())
                .id('error_action_button')
                .type(ButtonType.Normal)
                .borderRadius(BUTTON_RADIUS)
                .backgroundColor(COLOR_PRIMARY)
                .fontColor(COLOR_ON_PRIMARY)
                .fontSize(FONT_ERROR)
                .padding({ left: BUTTON_PADDING, right: BUTTON_PADDING })
                .margin({ top: SPACE_ERROR_ACTION })
                .onClick(() => {
                  this.runErrorAction();
                })
            }
            if (this.errorRetryable) {
              Button(Localization.buttonLabel('retry'))
                .id('error_retry_button')
                .type(ButtonType.Normal)
                .borderRadius(BUTTON_RADIUS)
                .backgroundColor(COLOR_PRIMARY)
                .fontColor(COLOR_ON_PRIMARY)
                .fontSize(FONT_ERROR)
                .padding({ left: BUTTON_PADDING, right: BUTTON_PADDING })
                .margin({ top: SPACE_ERROR_BUTTON })
                .onClick(() => {
                  this.reloadContent();
                })
            }
            if (this.openInBrowserUrl !== null) {
              Button(Localization.buttonLabel('open_in_browser'))
                .id('error_open_in_browser')
                .type(ButtonType.Normal)
                .borderRadius(BUTTON_RADIUS)
                .backgroundColor(COLOR_PRIMARY)
                .fontColor(COLOR_ON_PRIMARY)
                .fontSize(FONT_ERROR)
                .padding({ left: BUTTON_PADDING, right: BUTTON_PADDING })
                .margin({ top: SPACE_ERROR_BUTTON, bottom: SPACE_M })
                .onClick(() => {
                  this.openErrorInBrowser();
                })
            }
          }
          .id('error_panel')
          // The include is layout_centerHorizontal with layout_marginTop 16dp, and error_panel
          // pads itself 16dp all round with gravity="center_horizontal".
          .width('100%')
          .height('100%')
          .padding({
            top: ERROR_PANEL_TOP,
            left: SCREEN_PADDING,
            right: SCREEN_PADDING,
            bottom: SCREEN_PADDING
          })
          .justifyContent(FlexAlign.Start)
          .alignItems(HorizontalAlign.Center)
        }

        // fragment_player_holder, docked. This screen is only ever a pushUrl target, so the shell is
        // underneath it and its bar cannot draw here. The root Stack centres its children - the
        // loading spinner relies on that - so the bar gets a full-size column of its own to sit at
        // the bottom of, transparent to touches so the replies underneath stay tappable.
        Column() {
          MiniPlayerBar({
            idPrefix: 'comment_replies_',
            onVisibilityChange: (visible: boolean): void => {
              this.playerBarVisible = visible;
            }
          })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
        .hitTestBehavior(HitTestMode.Transparent)
      }
      .width('100%')
      .layoutWeight(1)
    }
    .id('CommentRepliesFragmentPage')
    .width('100%')
    .height('100%')
    .backgroundColor(themedBackground(this.blackTheme))
  }
}
