/*
 * S3 - ChannelAboutFragment (screen_channel_about), the trailing "About" page of ChannelFragment's
 * pager. hostedBy screen_channel, so ChannelFragmentPage instantiates this struct; the route
 * exists only so a deep link resolves.
 *
 * STRUCTURE from the source view tree. It shares fragment_description.xml and the whole of
 * BaseDescriptionFragment with DescriptionFragment, and differs only in what setupMetadata()
 * supplies:
 *   - detail_upload_date_view is explicitly GONE (a channel has no upload date) and the root
 *     gains an 8dp top padding - the ONLY layout difference between the two fragments,
 *   - a subscribers row, then the avatars and banners image rows,
 *   - the description is PLAIN_TEXT, and getStreamUrl() is null so there is no stream context.
 *
 * The metadata block is BUILT ROW BY ROW at runtime (addMetadataItem / addImagesMetadataItem):
 * fragment_description.xml holds only an empty LinearLayout, so the row COUNT and ORDER follow
 * the ChannelInfo, never a capture. Each row is an inflated item_metadata.xml, which is why
 * metadata_type_view / metadata_content_view repeat - the source repeats them too.
 *
 * S3 = structure + wiring. No colours, no typography, no spacing: those are S5/S6.
 */
import { router } from '@kit.ArkUI';
import { ChannelInfo } from '../model/extractor/ChannelInfo';
import { Image as ExtractorImage } from '../model/extractor/Image';
import { ShareUtils } from '../common/share/ShareUtils';
import { ServiceLocator } from '../common/di/ServiceLocator';
import { choosePreferredImage } from '../common/image/ImageLoader';
import { NewPipeTextView } from '../components/NewPipeTextView';
import { LinkKind, LinkSpan } from '../common/text/Linkify';
import { Localization } from '../common/i18n/Localization';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

/** ChannelInfo.UNKNOWN_SUBSCRIBER_COUNT. */
const UNKNOWN_SUBSCRIBER_COUNT: number = -1;

/** Image.ResolutionLevel.toString(), by ordinal: HIGH, MEDIUM, LOW, UNKNOWN. */
const RESOLUTION_LEVEL_NAMES: string[] = ['HIGH', 'MEDIUM', 'LOW', 'UNKNOWN'];

/**
 * addImagesMetadataItem()'s per-image label: `WxH`, with a `?` for whichever dimension the
 * extractor reported as UNKNOWN (which is -1, and was being printed as '-1x90'), and the
 * estimated resolution level when neither is known.
 *
 * The twin of DescriptionFragmentPage's imageSize(). This file's header already records that
 * the shared BaseDescriptionFragment extraction was reported rather than performed; this is
 * one more row on that bill, not a new one.
 */
function imageSizeText(image: ExtractorImage): string {
  const width: number = image.getWidth();
  const height: number = image.getHeight();
  if (width <= 0 && height <= 0) {
    return RESOLUTION_LEVEL_NAMES[image.getEstimatedResolutionLevel()];
  }
  const w: string = width > 0 ? `${width}` : '?';
  const h: string = height > 0 ? `${height}` : '?';
  return `${w}x${h}`;
}

/** NavigationHelper.openSearchFragment(serviceId, query) - the tag chip's destination. */
class SearchParams {
  serviceId: number;
  searchString: string;

  constructor(serviceId: number, searchString: string) {
    this.serviceId = serviceId;
    this.searchString = searchString;
  }
}

/** addImagesMetadataItem(): one metadata row built from a list of Images. */
class ImageMetadataRow {
  readonly label: ResourceStr;
  readonly resolutions: string;
  readonly preferredUrl: string;
  /** One span per resolution entry, each opening ITS OWN image url. */
  readonly linkSpans: LinkSpan[];

  constructor(label: ResourceStr, resolutions: string, preferredUrl: string, linkSpans: LinkSpan[]) {
    this.label = label;
    this.resolutions = resolutions;
    this.preferredUrl = preferredUrl;
    this.linkSpans = linkSpans;
  }
}

@Entry
@Component
export struct ChannelAboutFragmentPage {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  /**
   * The ChannelInfo the host hands over. BaseDescriptionFragment takes it through the
   * constructor and never loads anything itself, so there is no fetch on this screen.
   */
  channelInfo: ChannelInfo | null = null;

  /** setupDescription(): the linkified body, GONE when the description is blank. */
  @Prop descriptionBody: string = '';
  /** Localization.localizeNumber(channelInfo.getSubscriberCount()). */
  @Prop subscriberCountRow: string = '';
  /** addImagesMetadataItem() for getAvatars() and getBanners(). */
  @Prop imageMetadataRows: ImageMetadataRow[] = [];
  /** getTags(), sorted CASE_INSENSITIVE_ORDER. */
  @Prop tagChips: string[] = [];

  /** channelInfo.getSubscriberCount(); UNKNOWN means the row is not added at all. */
  @State subscriberCount: number = UNKNOWN_SUBSCRIBER_COUNT;
  /** channelInfo.getDescription(); blank means body AND selection button are both GONE. */
  @State description: string = '';
  /** channelInfo.getTags(); empty means the tags block is never inflated. */
  @State tags: string[] = [];
  @State isLoading: boolean = false;
  @State errorInfo: string | null = null;

  /** detail_select_description_button: ONE control with two states, not two controls. */
  @State descriptionSelectionEnabled: boolean = false;

  aboutToAppear(): void {
    this.applyInfo();
  }

  /** setupMetadata(inflater, layout) - everything this screen renders comes off the ChannelInfo. */
  private applyInfo(): void {
    const info: ChannelInfo | null = this.channelInfo;
    if (info === null) {
      return;
    }
    this.description = info.getDescription();
    this.descriptionBody = this.description;
    this.subscriberCount = info.getSubscriberCount();
    // addMetadataItem(..., Localization.localizeNumber(subscriberCount)) - the grouped form,
    // "1,234,567". Interpolating the number prints it ungrouped.
    this.subscriberCountRow = this.subscriberCount === UNKNOWN_SUBSCRIBER_COUNT
      ? '' : Localization.localizeNumber(this.subscriberCount);
    this.tags = info.getTags().slice().sort();
    this.tagChips = this.tags;
    this.imageMetadataRows = this.buildImageRows(info);
  }

  /**
   * addImagesMetadataItem(images, labelId): a comma-separated WxH list where each entry opens
   * that image url. The row is SKIPPED when choosePreferredImage returns null.
   */
  private buildImageRows(info: ChannelInfo): ImageMetadataRow[] {
    const rows: ImageMetadataRow[] = [];
    const avatars: ImageMetadataRow | null =
      this.imageRow($r('app.string.metadata_avatars'), info.getAvatars());
    if (avatars !== null) {
      rows.push(avatars);
    }
    const banners: ImageMetadataRow | null =
      this.imageRow($r('app.string.metadata_banners'), info.getBanners());
    if (banners !== null) {
      rows.push(banners);
    }
    return rows;
  }

  private imageRow(label: ResourceStr, images: ExtractorImage[]): ImageMetadataRow | null {
    const preferred: string | null = choosePreferredImage(images);
    if (preferred === null) {
      return null;
    }
    // addImagesMetadataItem() wraps EVERY entry in its own ClickableSpan on image.getUrl(); the
    // ", " between two of them stays plain.
    let resolutions: string = '';
    const spans: LinkSpan[] = [];
    for (const img of images) {
      if (resolutions.length > 0) {
        resolutions += ', ';
      }
      const size: string = imageSizeText(img);
      spans.push(new LinkSpan(LinkKind.WEB_URL, resolutions.length, resolutions.length + size.length,
        size, img.getUrl(), null));
      resolutions += size;
    }
    return new ImageMetadataRow(label, resolutions, preferred, spans);
  }

  private share(): ShareUtils {
    return ServiceLocator.get().share;
  }

  /** A metadata LABEL long-press copies the value to the clipboard. */
  private copyValue(value: string): void {
    this.share().copyToClipboard(value);
  }

  /** Each resolution entry is a ClickableSpan opening its own image url in a browser. */
  private openImageUrl(span: LinkSpan): void {
    const url: string | null = span.url;
    if (url !== null) {
      this.share().openUrlInBrowser(url);
    }
  }

  /**
   * TextLinkifier's ClickableSpans inside the description: a url or an e-mail opens externally,
   * a hashtag searches for it. There is no player behind this screen, so a timestamp - which
   * TextLinkifier only makes clickable when a stream is in context - has nothing to seek.
   */
  private openLink(span: LinkSpan): void {
    if (span.kind === LinkKind.HASHTAG) {
      this.openTagSearch(span.text);
      return;
    }
    const url: string | null = span.url;
    if (url !== null) {
      this.share().openUrlInBrowser(url);
    }
  }

  /** Tap on a chip opens SearchFragment for that tag; long-press copies it. */
  private openTagSearch(tag: string): void {
    const info: ChannelInfo | null = this.channelInfo;
    router.pushUrl({
      url: 'pages/SearchFragmentPage',
      params: new SearchParams(info === null ? 0 : info.getServiceId(), tag)
    });
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Builders
  ////////////////////////////////////////////////////////////////////////// */

  /** item_metadata.xml: a label plus a NewPipeTextView value. */
  @Builder
  metadataRow(label: ResourceStr, value: string, linked: boolean, row: ImageMetadataRow | null) {
    // item_metadata.xml: a 96dp end-aligned ALL-CAPS bold label, then the value 16dp after it.
    Row() {
      Text(label)
        .id('metadata_type_view')
        .width(96)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.on_surface'))
        .textCase(TextCase.UpperCase)
        .textAlign(TextAlign.End)
        .onClick(() => {
          this.copyValue(value);
        })
        .gesture(LongPressGesture().onAction(() => {
          this.copyValue(value);
        }))

      Column() {
        NewPipeTextView({
          slug: 'metadata_content_view',
          content: value,
          linkSpans: row === null ? [] : row.linkSpans,
          onLinkTapped: linked && row !== null ? ((span: LinkSpan): void => {
            this.openImageUrl(span);
          }) : null,
          onShareSelection: (): void => {
            this.copyValue(value);
          }
        })
      }
      .layoutWeight(1)
      .margin({ left: 16 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
    .alignItems(VerticalAlign.Center)
  }

  build() {
    Scroll() {
      Column() {
        Row() {
          // setupMetadata() sets this GONE on a channel - it is never rendered here.
          Text('')
            .id('detail_upload_date_view')
            .visibility(Visibility.None)
            .layoutWeight(1)
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.on_surface'))
            .margin({ left: 16, top: 6, right: 8 })

          // ONE control with two states: ic_select_all <-> ic_close, 5dp padding, 16dp end inset.
          if (this.description.length > 0) {
            Image(this.descriptionSelectionEnabled
              ? $r('app.media.ic_close') : $r('app.media.ic_select_all'))
              .id('detail_select_description_button')
              .width(34)
              .height(34)
              .padding(5)
              .objectFit(ImageFit.Contain)
              .fillColor($r('app.color.on_surface'))
              .margin({ right: 16, bottom: 2 })
              .onClick(() => {
                this.descriptionSelectionEnabled = !this.descriptionSelectionEnabled;
              })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
        // fragment_description.xml pins this button with layout_constraintEnd_toEndOf="parent",
        // so it sits at the END of the row whatever its siblings do. Here the only sibling is
        // detail_upload_date_view, which setupMetadata() makes GONE on a channel - and
        // Visibility.None takes the node OUT of the layout, so its layoutWeight(1) reserves
        // nothing and the button fell to the left edge of the screen on its own line. A lone
        // square at the top-left is what this screen's card reports as "a square-shaped button
        // that should not normally be visible".
        .justifyContent(FlexAlign.End)

        // detail_description_note_view is VISIBLE only while selection mode is on: 12sp italic,
        // centred, 16dp side margins.
        if (this.descriptionSelectionEnabled) {
          Text($r('app.string.description_select_note'))
            .id('detail_description_note_view')
            .width('100%')
            .fontSize(12)
            .fontStyle(FontStyle.Italic)
            .fontColor($r('app.color.on_surface_variant'))
            .textAlign(TextAlign.Center)
            .padding({ left: 16, right: 16 })
            .margin({ top: 8 })
        }

        // TextLinkifier.fromDescription(..., PLAIN_TEXT); GONE when the description is blank.
        // video_item_detail_description_text_size = 13sp, 16dp side margins, 8dp above.
        if (this.description.length > 0) {
          Column() {
            NewPipeTextView({
              slug: 'detail_description_view',
              content: this.description,
              selectable: this.descriptionSelectionEnabled,
              textSizeFp: 13,
              // A long press here is what STARTS a selection once the toggle is on; the source
              // copies nothing from the body, whichever state the toggle is in.
              copyOnLongPress: false,
              onLinkTapped: (span: LinkSpan): void => {
                this.openLink(span);
              }
            })
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
          .margin({ top: 8 })
        }

        // detail_metadata_layout: rows added one by one, in setupMetadata()'s order.
        Column() {
          // The subscribers row is not added at all for an UNKNOWN count.
          if (this.subscriberCount !== UNKNOWN_SUBSCRIBER_COUNT) {
            this.metadataRow($r('app.string.metadata_subscribers'), this.subscriberCountRow, false, null)
          }

          ForEach(this.imageMetadataRows, (row: ImageMetadataRow) => {
            this.metadataRow(row.label, row.resolutions, true, row)
          }, (row: ImageMetadataRow) => row.preferredUrl)

          // item_metadata_tags.xml - inflated only when there is at least one tag.
          if (this.tags.length > 0) {
            Column() {
              // item_metadata_tags.xml: a centred ALL-CAPS bold heading, 8dp above the group.
              Text($r('app.string.metadata_tags'))
                .id('metadata_type_view')
                .width('100%')
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.on_surface'))
                .textCase(TextCase.UpperCase)
                .textAlign(TextAlign.Center)
                .margin({ top: 8 })

              Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center }) {
                ForEach(this.tags, (tag: string) => {
                  // chip.xml repeats @+id/description_tag_itemroot per chip (Rule 12's
                  // list-row exception: the replay resolves a chip by index).
                  // A Material chip: 32dp tall, fully rounded, on the contrast surface.
                  Text(tag)
                    .id('description_tag_itemroot')
                    .height(32)
                    .fontSize(14)
                    .fontColor($r('app.color.on_surface'))
                    .maxLines(1)
                    .textAlign(TextAlign.Center)
                    .padding({ left: 12, right: 12 })
                    .margin({ right: 8, top: 4, bottom: 4 })
                    .borderRadius(16)
                    .backgroundColor($r('app.color.surface_variant'))
                    .onClick(() => {
                      this.openTagSearch(tag);
                    })
                    .gesture(LongPressGesture().onAction(() => {
                      this.copyValue(tag);
                    }))
                }, (tag: string) => tag)
              }
              .id('metadata_tags_chips')
              .width('100%')
              .margin({ top: 8 })
            }
            .width('100%')
          }
        }
        .id('detail_metadata_layout')
        .width('100%')
        // layout_margin 16dp / 10dp / 16dp / 10dp around the metadata block.
        .padding({ left: 16, right: 16 })
        .margin({ top: 10, bottom: 10 })
        .alignItems(HorizontalAlign.Start)
      }
      .id('constraint_layout')
      .width('100%')
      // DeviceUtils.dpToPx(8): the one layout difference from DescriptionFragment.
      .padding({ top: 8 })
      .alignItems(HorizontalAlign.Start)
    }
    .id('ChannelAboutFragmentPage')
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .backgroundColor(themedBackground(this.blackTheme))
  }
}
