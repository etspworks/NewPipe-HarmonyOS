/**
 * S3 - CommentsFragment (screen_comments), fragment_comments.xml + list_comment_item.xml.
 *
 * Also a registered route, but in practice it is MOUNTED by screen_video_detail as a TabContent
 * (source TabAdapter/ViewPager2): VideoDetailFragmentPage instantiates this struct. The route
 * exists so the deep link resolves; the host does not push it.
 *
 * fragment_comments.xml is a RelativeLayout of four overlapping children, so the root is a Stack:
 *   items_list (a NewPipeRecyclerView, match_parent) - the only thing that scrolls
 *   loading_progress_bar - centerInParent, GONE until showLoading()
 *   empty_state_view     - centerHorizontal, paddingTop 85dp, GONE until the list is empty
 *   error_panel          - centerHorizontal, marginTop 16dp, GONE until an error arrives
 * The three overlays are EXCLUSIVE with each other and with a loaded list, never siblings of it.
 *
 * Source facts this tree reproduces (CommentsFragment.java, BaseListInfoFragment,
 * BaseListFragment):
 *  - Hosted as a pager tab, so setTitle() and onCreateOptionsMenu() are deliberate NO-OPS - this
 *    screen must not touch the action bar.
 *  - ItemViewMode is FORCED to LIST regardless of the user's grid/card preference, so the row
 *    branch below never reaches the GRID/CARD holders - they stay in the switch because
 *    InfoListAdapter's getItemViewType() still routes a non-comment item through them.
 *  - The row has THREE DISTINCT tap targets and collapsing them loses two navigations:
 *      itemRoot                -> toggles the TextEllipsizer (expand/collapse the body); the
 *                                 LONG PRESS copies the comment text to the clipboard.
 *      itemThumbnailView       -> openCommentAuthorIfPresent -> ChannelFragment for
 *                                 item.getUploaderUrl(); a NO-OP when that url is empty, and
 *                                 hidden entirely when ImageStrategy.shouldLoadImages() is false.
 *      replies_button          -> CommentRepliesFragment; GONE (listener null) when
 *                                 item.getReplies() == null.
 *  - itemCommentContentView resolves ClickableSpans first, so in-comment links (timestamps, urls,
 *    channel mentions) fire INSTEAD of the row click. CommentInfoItemHolder owns that.
 *  - Pagination: OnScrollBelowItemsListener -> loadMoreItems() while Page.isValid(currentNextPage);
 *    the pignate_footer is an indeterminate progress row shown by showListFooter(hasMoreItems()).
 *  - The empty-state message is CommentsInfo.isCommentsDisabled() ? comments_are_disabled :
 *    no_comments - a conditional on bound state, not one flattened literal.
 *  - dynamicallyShowErrorPanelOrSnackbar(): the FULL error panel only while the adapter is empty;
 *    with items already visible it degrades to a snackbar, which is why the panel branch below
 *    also tests the item count.
 *  - The host also calls scrollToComment(comment) to jump to a specific row.
 *
 * S4 binds the list to CommentsInfo.relatedItems over svc_extractor / svc_info_cache
 * (youtube_innertube_api) and wires loadMoreItems(); S5/S6 style it - no colours, spacing or
 * typography are chosen here.
 */
import { router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

import { InfoItem } from '../common/extractor/core/InfoItem';
import { ExtractorHelper } from '../common/extractor/ExtractorHelper';
import { CommentsInfo } from '../model/extractor/CommentsInfo';
import { InfoItemsPage } from '../model/extractor/ListExtractorInfoItemsPage';
import { Page } from '../model/extractor/Page';
import { ServiceLocator } from '../common/di/ServiceLocator';
import { ShareUtils } from '../common/share/ShareUtils';
import { CommentsInfoItem } from '../model/extractor/CommentsInfoItem';
import { StreamInfoItem } from '../model/extractor/StreamInfoItem';
import { ChannelInfoItem } from '../model/extractor/ChannelInfoItem';
import { PlaylistInfoItem } from '../model/extractor/PlaylistInfoItem';

import { InfoListAdapter, InfoItemDataSource, ItemViewMode } from '../components/InfoListAdapter';
import { paramsForComment } from './CommentRepliesFragmentPage';
import { NewPipeRecyclerView } from '../components/NewPipeRecyclerView';
import { NewPipeTextView } from '../components/NewPipeTextView';
import { InfoItemHolder } from '../components/InfoItemHolder';
import { HFHolder } from '../components/HFHolder';
import { CommentInfoItemHolder } from '../components/CommentInfoItemHolder';
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
import { Localization } from '../common/i18n/Localization';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

const TAG: string = 'CommentsFragmentPage';

@Entry
@Component
export struct CommentsFragmentPage {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  /** getItemViewMode() is overridden to ItemViewMode.LIST on this fragment. */
  private itemViewMode: ItemViewMode = ItemViewMode.LIST;
  /** BaseListFragment.useMiniVariant - false here, so the full list holder is used. */
  private useMiniVariant: boolean = false;

  /**
   * infoListAdapter <- CommentsInfo.relatedItems. The array is the BOUND value; the data source
   * beside it is what LazyForEach reads (an IDataSource cannot be a @Prop - the deep copy would
   * drop its listeners).
   */
  @Watch('onCommentsListChanged') @Prop commentsList: CommentsInfoItem[] = [];
  private commentsSource: InfoItemDataSource = new InfoItemDataSource();
  /**
   * emptyStateDesc's non-disabled string; the disabled one is picked by the condition on
   * isCommentsDisabled at the render site, exactly as setText() does.
   */
  @Prop emptyStateMessage: Resource = $r('app.string.no_comments');
  /**
   * item.getReplies(): the urls of the comments that HAVE a reply page. The source sets
   * repliesButton's listener to null for every other row, which is the branch below.
   */
  @State replies: string[] = [];
  /** How many rows the adapter holds - the empty/error branches read it. */
  @State loadedCount: number = 0;
  /** Page.isValid(currentNextPage): showListFooter(hasMoreItems()). */
  @State hasMoreItems: boolean = false;
  @State isLoading: boolean = false;
  @State errorInfo: string | null = null;
  /** CommentsInfo.isCommentsDisabled() - which empty-state string is shown. */
  @State isCommentsDisabled: boolean = false;
  /** setFocusScrollAllowed(false) while a page load is in flight (NewPipeRecyclerView). */
  @State focusScrollAllowed: boolean = true;
  /** TextEllipsizer state per row: the commentIds of the comments the user has expanded. */
  @State expandedComments: string[] = [];

  /** The fragment's own arguments: the host page carries serviceId + url in its route params. */
  private serviceId: number = 0;
  private url: string = '';
  /** currentInfo, kept so getMoreCommentItemsForInfo() pages through the same extractor. */
  private currentInfo: CommentsInfo | null = null;
  /** currentNextPage - Page.isValid(...) is what showListFooter(hasMoreItems()) reads. */
  private currentNextPage: Page | null = null;

  aboutToAppear(): void {
    this.readArguments();
    this.startLoading(false);
  }

  /** BaseFragment.onCreate(): the arguments of the page this fragment is mounted in. */
  private readArguments(): void {
    const params: Record<string, Object> | undefined =
      router.getParams() as Record<string, Object> | undefined;
    if (params === undefined || params === null) {
      return;
    }
    const sid: Object | undefined = params['serviceId'];
    if (sid !== undefined && sid !== null) {
      this.serviceId = Number(sid.toString());
    }
    const streamUrl: Object | undefined = params['url'];
    if (streamUrl !== undefined && streamUrl !== null) {
      this.url = streamUrl.toString();
    }
  }

  /**
   * BaseListInfoFragment.startLoading(forceLoad) ->
   * ExtractorHelper.getCommentsInfo(serviceId, url, forceLoad) -> handleResult(result).
   */
  private async startLoading(forceLoad: boolean): Promise<void> {
    if (this.url.length === 0) {
      return;
    }
    this.isLoading = true;
    this.errorInfo = null;
    // setFocusScrollAllowed(false) while a load is in flight.
    this.focusScrollAllowed = false;
    try {
      const info: CommentsInfo | null =
        await ExtractorHelper.getCommentsInfo(this.serviceId, this.url, forceLoad);
      this.handleResult(info);
    } catch (err) {
      // dynamicallyShowErrorPanelOrSnackbar(): the panel branch reads loadedCount.
      this.errorInfo = (err as BusinessError).message;
    } finally {
      this.isLoading = false;
      this.focusScrollAllowed = true;
    }
  }

  /** handleResult(result): the adapter, the disabled flag and the next-page pointer. */
  private handleResult(info: CommentsInfo | null): void {
    this.currentInfo = info;
    if (info === null) {
      this.commentsList = [];
      this.commentsSource.clearItems();
      this.loadedCount = 0;
      this.hasMoreItems = false;
      return;
    }
    this.isCommentsDisabled = info.commentsDisabled;
    this.currentNextPage = info.getNextPage();
    this.hasMoreItems = Page.isValid(this.currentNextPage);
    this.commentsSource.clearItems();
    this.commentsList = info.getRelatedItems();
  }

  /** The @Prop is the bound value; the data source mirrors it for LazyForEach. */
  private onCommentsListChanged(): void {
    this.commentsSource.clearItems();
    this.commentsSource.addItems(this.commentsList);
    this.loadedCount = this.commentsList.length;
    this.replies = this.commentsList
      .filter((item: CommentsInfoItem): boolean => item.getReplies() !== null)
      .map((item: CommentsInfoItem): string => item.getCommentId());
  }

  private isExpanded(item: CommentsInfoItem): boolean {
    return this.expandedComments.indexOf(item.getCommentId()) >= 0;
  }

  /** itemView.setOnClickListener: textEllipsizer.toggle() + onCommentsSelectedListener. */
  private onItemSelected(item: InfoItem): void {
    if (!(item instanceof CommentsInfoItem)) {
      return;
    }
    // getUrl() is the STREAM url and is the SAME on every row, so the toggled row is
    // identified by its own commentId (CommentRepliesFragmentPage keys its header the same way).
    const commentId: string = (item as CommentsInfoItem).getCommentId();
    const pos: number = this.expandedComments.indexOf(commentId);
    const next: string[] = this.expandedComments.slice();
    if (pos >= 0) {
      next.splice(pos, 1);
    } else {
      next.push(commentId);
    }
    this.expandedComments = next;
    // LazyForEach keeps the cached child for an unchanged key, so the row only re-reads
    // `expanded` when its own index is notified - without this the tap is a visual no-op.
    this.commentsSource.notifyItemChanged(this.commentsSource.getItemsList().indexOf(item));
  }

  /**
   * itemView.setOnLongClickListener: on TV it opens the comment author, otherwise it copies the
   * comment text to the clipboard. S4 wires both halves through svc_share / svc_clipboard.
   */
  private onItemHeld(item: InfoItem): void {
    if (!(item instanceof CommentsInfoItem)) {
      return;
    }
    // feat_clipboard: ShareUtils.copyToClipboard(context, commentText) + its confirmation toast.
    const share: ShareUtils = ServiceLocator.get().share;
    share.copyToClipboard((item as CommentsInfoItem).getCommentText().getContent())
      .catch((err: BusinessError): void => {
        hilog.error(0x0000, TAG, 'copy comment failed: %{public}s', err.message);
      });
  }

  /** openCommentAuthorIfPresent(): a NO-OP when getUploaderUrl() is empty. */
  private openCommentAuthorOf(item: CommentsInfoItem): void {
    if (item.getUploaderUrl().length === 0) {
      return;
    }
    router.pushUrl({
      url: 'pages/ChannelFragmentPage',
      params: {
        serviceId: item.getServiceId(),
        url: item.getUploaderUrl(),
        name: item.getUploaderName()
      }
    }).catch((err: BusinessError): void => {
      hilog.error(0x0000, TAG, 'channel push failed: %{public}s', err.message);
    });
  }

  /** openCommentReplies(): CommentRepliesFragment for item.getReplies(). */
  private openCommentReplies(item: CommentsInfoItem): void {
    // `new CommentRepliesFragment(commentsInfoItem)` receives the WHOLE item: the header binds
    // its uploader/date/likes/text from it and CommentRepliesInfo takes getReplies() as the
    // first page. A serviceId/url/name push leaves all of that unbound and loads no replies.
    router.pushUrl({
      url: 'pages/CommentRepliesFragmentPage',
      params: paramsForComment(item)
    }).catch((err: BusinessError): void => {
      hilog.error(0x0000, TAG, 'replies push failed: %{public}s', err.message);
    });
  }

  /** OnScrollBelowItemsListener -> onScrollToBottom() -> loadMoreItems(). */
  private async loadMoreItems(): Promise<void> {
    const info: CommentsInfo | null = this.currentInfo;
    const nextPage: Page | null = this.currentNextPage;
    if (!this.hasMoreItems || this.isLoading || info === null || nextPage === null) {
      return;
    }
    this.isLoading = true;
    try {
      const page: InfoItemsPage<CommentsInfoItem> =
        await ExtractorHelper.getMoreCommentItemsForInfo(this.serviceId, info, nextPage);
      this.currentNextPage = page.getNextPage();
      this.hasMoreItems = Page.isValid(this.currentNextPage);
      // addInfoItemList(): a loaded page is APPENDED, never a replacement.
      this.commentsList = this.commentsList.concat(page.getItems());
    } catch (err) {
      // A page that failed is not a page that is still coming.
      this.hasMoreItems = false;
      // With items already on screen the source degrades the panel to a snackbar; the panel
      // branch tests loadedCount, so recording the message here is that same behaviour.
      this.errorInfo = (err as BusinessError).message;
    } finally {
      this.isLoading = false;
    }
  }

  /** showEmptyState(): only while the adapter is empty AND nothing is loading or failing. */
  private showEmptyState(): boolean {
    return this.loadedCount === 0 && !this.isLoading && this.errorInfo === null;
  }

  /**
   * dynamicallyShowErrorPanelOrSnackbar(): the panel is the EMPTY-adapter branch; with items on
   * screen the same error degrades to a snackbar, which leaves the list visible.
   */
  private showErrorPanel(): boolean {
    return this.errorInfo !== null && this.loadedCount === 0;
  }

  /** ErrorPanelHelper's message; the panel only renders while this is non-null. */
  private errorText(): string {
    return this.errorInfo === null ? '' : this.errorInfo;
  }

  /* //////////////////////////////////////////////////////////////////////////
  // InfoListAdapter.getItemViewType() + onCreateViewHolder() + onBindViewHolder()
  ////////////////////////////////////////////////////////////////////////// */

  /** pignate_footer: the indeterminate load-more row showListFooter(hasMoreItems()) toggles. */
  @Builder
  listFooter() {
    // GATED HERE, not only through InfoListAdapter's showFooter: that is an UNDECORATED member of
    // the child struct, so it keeps whatever value it had when the list was first built. The first
    // page is fetched from aboutToAppear, so the list was built with isLoading true and the spinner
    // then sat at the foot of the list for ever. This @Builder runs in the PAGE's context and
    // re-runs on its @State, so the row empties the moment the request finishes.
    if (this.hasMoreItems && this.isLoading) {
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
      // COMMENT_HOLDER_TYPE - the type this screen's list holds.
      CommentInfoItemHolder({
        item: item as CommentsInfoItem,
        expanded: this.isExpanded(item as CommentsInfoItem),
        onAuthor: () => {
          this.openCommentAuthorOf(item as CommentsInfoItem);
        },
        // repliesButton's listener is bound ONLY for a row whose getReplies() is non-null; the
        // source sets it to null for every other row, which is what the else arm stands for.
        onReplies: this.replies.indexOf((item as CommentsInfoItem).getCommentId()) >= 0
          ? (): void => {
            this.openCommentReplies(item as CommentsInfoItem);
          }
          : (): void => {
            hilog.debug(0x0000, TAG, 'no reply page on %{public}s',
              (item as CommentsInfoItem).getUrl());
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

  build() {
    Stack() {
      // <NewPipeRecyclerView android:id="@+id/items_list"> - the subclass contributes the D-pad
      // focus handling; InfoListAdapter's own List is the scroller and keeps the items_list slug.
      NewPipeRecyclerView({ focusScrollAllowed: this.focusScrollAllowed }) {
        InfoListAdapter({
          dataSource: this.commentsSource,
          hasHeader: false,
          // The load-more spinner belongs to a request in flight, not to "there is more" - see
          // CommentRepliesFragmentPage, where gating on hasMoreItems alone left it spinning.
          showFooter: this.hasMoreItems && this.isLoading,
          onReachEnd: () => {
            this.loadMoreItems();
          },
          // A @Builder passed as `this.itemRow` re-binds `this` to the CHILD (InfoListAdapter),
          // so every page member the builder touches reads back undefined. The arrow-function
          // form keeps `this` on this page.
          footer: (): void => {
            this.listFooter();
          },
          row: (item: InfoItem): void => {
            this.itemRow(item);
          }
        })
      }

      if (this.isLoading) {
        // loading_progress_bar: layout_centerInParent - the Stack's own default alignment.
        LoadingProgress()
          .id('loading_progress_bar')
          .width(48)
          .height(48)
          .color($r('app.color.primary'))
      }

      if (this.showEmptyState()) {
        Column() {
          // The kaomoji is a literal in the layout itself, not data.
          Text('(╯°-°)╯')
            .fontFamily('monospace')
            .fontSize(35)
            .fontColor($r('app.color.on_surface_variant'))
            .margin({ bottom: 10 })

          // isCommentsDisabled() picks the string; one capture can only ever show one of them.
          NewPipeTextView({
            slug: 'empty_state_desc',
            content: this.isCommentsDisabled
              ? $r('app.string.comments_are_disabled') : this.emptyStateMessage,
            textSizeFp: 24,
            textColorValue: $r('app.color.on_surface_variant'),
            // list_empty_view.xml: gravity="center" - the message is centred under the kaomoji,
            // not left-aligned beside it.
            textAlignment: TextAlign.Center
          })
        }
        .id('empty_state_view')
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Start)
        .alignItems(HorizontalAlign.Center)
        .padding({ top: 85 })
      }

      if (this.showErrorPanel()) {
        Column() {
          // error_panel.xml: 16sp bold, centred, over a 16dp padded column.
          Text(this.errorText())
            .id('error_message_view')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            // S0213 samples the same error_panel include at #6D6D6D = #8A000000 over #EEEEEE.
            .fontColor($r('app.color.on_surface_variant'))
            .textAlign(TextAlign.Center)

          // @style/ServiceColoredButton: colorButtonNormal = ?attr/colorPrimary with
          // subscribe_text_color (white) text, at 16sp.
          Button(Localization.buttonLabel('retry'))
            .id('error_retry_button')
            .height(36)
            .borderRadius(2)
            .backgroundColor($r('app.color.primary'))
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.on_primary'))
            .padding({ left: 16, right: 16 })
            .margin({ top: 8 })
            .onClick(() => {
              // ErrorPanelHelper -> onRetryButtonClicked() -> reloadContent() -> startLoading(true)
              this.startLoading(true);
            })
        }
        .id('error_panel')
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Start)
        .alignItems(HorizontalAlign.Center)
        .padding(16)
        .margin({ top: 16 })
      }
    }
    .id('CommentsFragmentPage')
    .width('100%')
    .height('100%')
    .backgroundColor(themedBackground(this.blackTheme))
  }
}
