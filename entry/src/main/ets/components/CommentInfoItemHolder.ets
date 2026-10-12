/*
 * S3 - port of org.schabi.newpipe.info_list.holder.CommentInfoItemHolder (list_comment_item.xml).
 *
 * The row root and its click/long-click live in InfoItemHolder (the base class), so this struct is
 * the BODY the base wraps. THREE distinct tap targets, and collapsing them loses two navigations:
 *   itemRoot          -> textEllipsizer.toggle() (owned by the wrapper; `expanded` below)
 *   itemThumbnailView -> openCommentAuthor(item) -> ChannelFragment; GONE when
 *                        !ImageStrategy.shouldLoadImages()
 *   replies_button    -> openCommentReplies(item); GONE when item.getReplies() == null
 *
 * COMMENT_DEFAULT_LINES = 2 is the ellipsized height; the row shows the text in full once toggled.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { router } from '@kit.ArkUI';
import { CommentsInfoItem } from '../model/extractor/CommentsInfoItem';
import { choosePreferredImage, shouldLoadImages } from '../common/image/ImageLoader';
import { Localization } from '../common/i18n/Localization';
import { DateWrapper } from '../common/extractor/localization/DateWrapper';
import { LinkKind, LinkSpan, linkifyAll } from '../common/text/Linkify';
import { ServiceLocator } from '../common/di/ServiceLocator';
import { openStreamAtTimestamp } from '../common/player/TimestampHandler';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

/* //////////////////////////////////////////////////////////////////////////
// S5 - the app-wide style tokens (same set as CommentRepliesFragmentPage /
// MainActivityPage). The two text alphas are ?android:textColorPrimary and
// ?android:textColorSecondary, which live in the platform theme and have no
// migrated resource; everything else IS a migrated resource.
////////////////////////////////////////////////////////////////////////// */

/** ?android:attr/windowBackground = @color/light_background_color (#EEEEEE). */
const COLOR_SURFACE: Resource = $r('app.color.background');
/** ?android:textColorPrimary, 87% black - measured #1F1F1F over the surface. */
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');
/** ?android:textColorSecondary, 54% black - measured #6D6D6D over the surface. */
const COLOR_ON_SURFACE_SECONDARY: Resource = $r('app.color.on_surface_variant');
/** @color/placeholder_background - the avatar circle before the image arrives. */
const COLOR_AVATAR_BG: Resource = $r('app.color.placeholder_background');

/** list_comment_item: itemThumbnailView is 42dp square, CircularImageView. */
const AVATAR_SIZE: number = 42;
/** ic_pin / ic_thumb_up / ic_heart in a row: 18sp (@dimen/video_item_detail_*). */
const ROW_ICON_SIZE: number = 18;
/** itemCommentContentView layout_marginTop, and the same gap above the like row. */
const CONTENT_GAP: number = 6;
/** borderlessButtonStyle's horizontal inset on replies_button. */
const BUTTON_PADDING: number = 16;
/** replies_button: the borderless button's own text size. */
const FONT_BUTTON: number = 14;

/** CommentInfoItemHolder.COMMENT_DEFAULT_LINES. */
const COMMENT_DEFAULT_LINES: number = 2;
/** TextEllipsizer's expanded state: Integer.MAX_VALUE lines in the source. */
const EXPANDED_LINES: number = 1000;

/** One run of the comment body: plain text, or the link span covering it. */
class CommentTextSegment {
  readonly text: string;
  readonly link: LinkSpan | null;

  constructor(text: string, link: LinkSpan | null) {
    this.text = text;
    this.link = link;
  }
}

/**
 * TextLinkifier.fromDescription(textView, item.getCommentText(), FROM_HTML_MODE_LEGACY,
 * getServiceById(serviceId), item.getUrl(), disposables, null) + LongPressLinkMovementMethod.
 *
 * There is no spannable TextView here, so the body is a Text of Spans and changeLinkIntents()
 * becomes an onClick per link span - the three kinds NewPipe adds on top of Linkify, doing what
 * the source's LongPressClickableSpans do: a url opens externally, a hashtag searches the
 * comment's own service, a timestamp opens the related stream at that position. Plain runs carry
 * NO handler, so a tap on them still reaches the row and toggles the ellipsizer.
 */
@Component
export struct LinkifiedCommentText {
  /** The source view's own id: commentContent in the header, itemCommentContentView in a row. */
  textId: string = '';
  @Prop content: string = '';
  /** relatedInfoService.getServiceId(): the service a hashtag is searched on. */
  @Prop serviceId: number = 0;
  /** relatedStreamUrl: the stream a timestamp opens. */
  @Prop relatedStreamUrl: string = '';
  /** ellipsize() clamps a row; the parent comment is shown in full. */
  @Prop maxTextLines: number = EXPANDED_LINES;
  /** The source TextView's textSize: 14sp in the header, 12sp (@dimen) in a row. */
  @Prop fontSizeFp: number = 14;
  /** The source TextView's layout_marginTop within its parent. */
  @Prop marginTopVp: number = 0;

  /** The body split into runs, so each link gets its own Span to be clicked. */
  private segments(): CommentTextSegment[] {
    const text: string = this.content;
    const links: LinkSpan[] = linkifyAll(text, []);
    // linkifyAll returns the kinds in priority order; the runs have to be in text order.
    links.sort((a: LinkSpan, b: LinkSpan) => a.start - b.start);
    const out: CommentTextSegment[] = [];
    let at: number = 0;
    for (const link of links) {
      if (link.start > at) {
        out.push(new CommentTextSegment(text.substring(at, link.start), null));
      }
      out.push(new CommentTextSegment(text.substring(link.start, link.end), link));
      at = link.end;
    }
    if (at < text.length) {
      out.push(new CommentTextSegment(text.substring(at), null));
    }
    return out;
  }

  /** changeLinkIntents(): what a tapped span does, by kind. */
  private openLink(segment: CommentTextSegment): void {
    const link: LinkSpan | null = segment.link;
    if (link === null) {
      return;
    }
    const url: string | null = link.url;
    if (url !== null) {
      // UrlLongPressClickableSpan -> ShareUtils.openUrlInApp(), which falls back to the browser.
      ServiceLocator.get().share.openUrlInBrowser(url);
      return;
    }
    if (link.kind === LinkKind.HASHTAG) {
      // HashtagLongPressClickableSpan -> NavigationHelper.openSearch(serviceId, hashtag).
      const params: Record<string, Object> = {
        'serviceId': `${this.serviceId}`,
        'searchString': link.text
      };
      router.pushUrl({ url: 'pages/SearchFragmentPage', params: params });
      return;
    }
    const seconds: number | null = link.seconds;
    if (seconds !== null && this.relatedStreamUrl.length > 0) {
      // TimestampLongPressClickableSpan -> the player's TimestampChange: the playing stream seeks,
      // any other one opens at that second.
      openStreamAtTimestamp(this.serviceId, this.relatedStreamUrl, seconds);
    }
  }

  build() {
    Text() {
      ForEach(this.segments(), (segment: CommentTextSegment) => {
        if (segment.link === null) {
          Span(segment.text)
        } else {
          Span(segment.text)
            .onClick(() => {
              this.openLink(segment);
            })
        }
      }, (segment: CommentTextSegment, index: number) => `${index}-${segment.text}`)
    }
    .id(this.textId)
    .maxLines(this.maxTextLines)
    .textOverflow({ overflow: TextOverflow.Ellipsis })
    .width('100%')
    .fontSize(this.fontSizeFp)
    .fontColor(COLOR_ON_SURFACE)
    .margin({ top: this.marginTopVp })
  }
}

@Component
export struct CommentInfoItemHolder {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  item: CommentsInfoItem | null = null;
  /** textEllipsizer state: false = ellipsized to COMMENT_DEFAULT_LINES. */
  @Prop expanded: boolean = false;
  /** itemThumbnailView.setOnClickListener -> openCommentAuthor(item). */
  onAuthor: () => void = (): void => {
    hilog.debug(0x0000, 'NewPipe', 'CommentInfoItemHolder: onAuthor not bound');
  };
  /** repliesButton.setOnClickListener -> openCommentReplies(item). */
  onReplies: () => void = (): void => {
    hilog.debug(0x0000, 'NewPipe', 'CommentInfoItemHolder: onReplies not bound');
  };

  /** CoilHelper.loadAvatar(itemThumbnailView, item.getUploaderAvatars()). */
  private avatarUrl(): string {
    const url: string | null =
      this.item === null ? null : choosePreferredImage(this.item.getUploaderAvatars());
    return url === null ? '' : url;
  }

  /** Localization.concatenateStrings(localizeUserName(uploaderName), relativeTimeOrTextual(...)). */
  private titleText(): string {
    if (this.item === null) {
      return '';
    }
    const parsed: DateWrapper | null = this.item.getUploadDate();
    const when: string | null = Localization.relativeTimeOrTextual(
      parsed === null ? null : parsed.getInstant().getTime(),
      this.item.getTextualUploadDate());
    return Localization.concatenateStrings([
      Localization.localizeUserName(this.item.getUploaderName()),
      when === null ? '' : when
    ]);
  }

  private commentText(): string {
    return this.item === null ? '' : this.item.getCommentText().getContent();
  }

  private likeCountText(): string {
    return this.item === null ? '' : Localization.likeCount(this.item.getLikeCount());
  }

  /** likes are hidden together with their icon when the service reports no like count. */
  private hasLikeCount(): boolean {
    return this.item !== null && this.item.getLikeCount() >= 0;
  }

  private isPinned(): boolean {
    return this.item !== null && this.item.getIsPinned();
  }

  private isHearted(): boolean {
    return this.item !== null && this.item.getIsHeartedByUploader();
  }

  /** hasReplies = item.getReplies() != null: the button is GONE, not just inert, without it. */
  private hasReplies(): boolean {
    return this.item !== null && this.item.getReplies() !== null;
  }

  /** ellipsize() clamps to COMMENT_DEFAULT_LINES; toggle() shows the whole comment. */
  private contentMaxLines(): number {
    return this.expanded ? EXPANDED_LINES : COMMENT_DEFAULT_LINES;
  }

  /** getServiceById(item.getServiceId()): the service a hashtag in this comment searches. */
  private serviceIdOf(): number {
    return this.item === null ? 0 : this.item.getServiceId();
  }

  /** item.getUrl(): the stream this comment belongs to, which a timestamp opens. */
  private streamUrlOf(): string {
    return this.item === null ? '' : this.item.getUrl();
  }

  private repliesText(): string {
    return this.item === null ? '' : Localization.replyCount(this.item.getReplyCount());
  }

  build() {
    Row() {
      if (shouldLoadImages()) {
        Image(this.avatarUrl())
          .id('itemThumbnailView')
          .width(AVATAR_SIZE)
          .height(AVATAR_SIZE)
          // shapeAppearance="@style/CircularImageView" over placeholder_person.
          .borderRadius(AVATAR_SIZE / 2)
          .backgroundColor(COLOR_AVATAR_BG)
          .alt($r('app.media.placeholder_person'))
          .objectFit(ImageFit.Cover)
          .margin({ right: $r('app.float.comment_item_avatar_right_margin') })
          .onClick(() => {
            this.onAuthor();
          })
      }

      Column() {
        Row() {
          if (this.isPinned()) {
            Image($r('app.media.ic_pin'))
              .id('detail_pinned_view')
              .accessibilityText($r('app.string.detail_pinned_comment_view_description'))
              .width(ROW_ICON_SIZE)
              .height(ROW_ICON_SIZE)
              .margin({ right: $r('app.float.video_item_detail_pinned_right_margin') })
          }
          Text(this.titleText())
            .id('itemTitleView')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
            // textAppearanceSmall: the author + date line is the secondary colour.
            .fontSize($r('app.float.comment_item_title_text_size'))
            .fontColor(COLOR_ON_SURFACE_SECONDARY)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        LinkifiedCommentText({
          textId: 'itemCommentContentView',
          content: this.commentText(),
          serviceId: this.serviceIdOf(),
          relatedStreamUrl: this.streamUrlOf(),
          maxTextLines: this.contentMaxLines(),
          // @dimen/comment_item_content_text_size (12sp), layout_marginTop 6dp.
          fontSizeFp: 12,
          marginTopVp: CONTENT_GAP
        })

        Row() {
          if (this.hasLikeCount()) {
            Image($r('app.media.ic_thumb_up'))
              .id('detail_thumbs_up_img_view')
              .accessibilityText($r('app.string.detail_likes_img_view_description'))
              .width(ROW_ICON_SIZE)
              .height(ROW_ICON_SIZE)
              .margin({ right: $r('app.float.video_item_detail_like_margin') })
            Text(this.likeCountText())
              .id('detail_thumbs_up_count_view')
              .fontSize($r('app.float.video_item_detail_likes_text_size'))
              .fontColor(COLOR_ON_SURFACE_SECONDARY)
          }
          if (this.isHearted()) {
            Image($r('app.media.ic_heart'))
              .id('detail_heart_image_view')
              .accessibilityText($r('app.string.detail_heart_img_view_description'))
              .width(ROW_ICON_SIZE)
              .height(ROW_ICON_SIZE)
              .margin({ left: $r('app.float.video_item_detail_heart_margin') })
          }
          if (this.hasReplies()) {
            Text(this.repliesText())
              .id('replies_button')
              // borderlessButtonStyle: alignParentEnd, all-caps, primary text colour.
              .layoutWeight(1)
              .textAlign(TextAlign.End)
              .textCase(TextCase.UpperCase)
              .fontSize(FONT_BUTTON)
              .fontColor(COLOR_ON_SURFACE)
              .padding({ left: BUTTON_PADDING, right: BUTTON_PADDING })
              .onClick(() => {
                this.onReplies();
              })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ top: CONTENT_GAP })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .backgroundColor(themedBackground(this.blackTheme))
    // android:padding="@dimen/comments_vertical_padding" on itemRoot.
    .padding($r('app.float.comments_vertical_padding'))
  }
}
