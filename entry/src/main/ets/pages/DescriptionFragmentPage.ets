/**
 * S3 - DescriptionFragment (screen_description), fragment_description.xml + item_metadata.xml +
 * item_metadata_tags.xml + chip.xml.
 *
 * Also a registered route, but in practice it is MOUNTED by screen_video_detail as a TabContent
 * (source TabAdapter/ViewPager2): VideoDetailFragmentPage instantiates this struct. It has NO
 * loader of its own - the StreamInfo arrives through the constructor.
 *
 * It shares fragment_description.xml AND the whole of BaseDescriptionFragment with
 * ChannelAboutFragment, so this tree is the same shape ChannelAboutFragmentPage already builds;
 * only setupMetadata() differs. The plan asks for ONE shared component for the two, but
 * ChannelAboutFragmentPage is owned by another screen and is not in this call's lease, so the
 * shared extraction is reported rather than performed.
 *
 * DescriptionFragment.setupMetadata() verbatim, and the row set follows it EXACTLY - the count
 * and order vary per stream, so nothing here may be transcribed from a capture:
 *   detail_upload_date_view  Localization.localizeUploadDate(...), GONE when uploadDate is null
 *   metadata_category        streamInfo.getCategory()
 *   metadata_licence         streamInfo.getLicence()
 *   metadata_privacy         PUBLIC/UNLISTED/PRIVATE/INTERNAL -> its own string; OTHER adds NOTHING
 *   metadata_age_limit       only when getAgeLimit() != NO_AGE_LIMIT
 *   metadata_language        only when getLanguageInfo() != null
 *   metadata_support         linkified (TextLinkifier.fromPlainText)
 *   metadata_host            linkified
 *   metadata_thumbnails / _uploader_avatars / _subchannel_avatars
 *                            addImagesMetadataItem(): a comma-separated WxH list whose entries
 *                            each open that image url; SKIPPED when choosePreferredImage is null
 * addMetadataItem() also drops any row whose content isBlank(), which is why every row below is
 * inside its own guard - rows are additive, so the list length varies per stream.
 *
 * The other source facts this tree reproduces:
 *  - detail_select_description_button TOGGLES selection mode: it shows
 *    detail_description_note_view, makes the body selectable and swaps its own icon
 *    ic_select_all <-> ic_close. ONE control with two states, not two controls. It is GONE
 *    together with the body when the description is empty.
 *  - detail_description_view is TextLinkifier.fromDescription(..., FROM_HTML_MODE_LEGACY) with
 *    the stream url in context, so a timestamp span seeks the player.
 *  - A metadata LABEL long-press copies the value to the clipboard.
 *  - Tag chips are sorted CASE_INSENSITIVE_ORDER; tap opens SearchFragment, long-press copies.
 *
 * S4 = structure + state + wiring. No colours, no typography, no spacing beyond the two-column
 * metadata row: those are S5/S6.
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { StreamInfo } from '../model/extractor/StreamInfo';
import { ExtractorHelper } from '../common/extractor/ExtractorHelper';
import { Privacy, NO_AGE_LIMIT } from '../common/extractor/info/StreamExtractor';
import { Image as ExtractorImage } from '../model/extractor/Image';
import { DOT_SEPARATOR, Localization } from '../common/i18n/Localization';
import { ShareUtils } from '../common/share/ShareUtils';
import { ServiceLocator } from '../common/di/ServiceLocator';
import { choosePreferredImage } from '../common/image/ImageLoader';
import { NewPipeTextView } from '../components/NewPipeTextView';
import { Description, DESCRIPTION_HTML } from '../model/extractor/Description';
import { unescapeEntities } from '../common/extractor/html/Jsoup';
import { LinkKind, LinkSpan } from '../common/text/Linkify';
import { openStreamAtTimestamp } from '../common/player/TimestampHandler';
import { linkTextToCopy, openUrlLink } from '../common/text/InternalUrlsHandler';
import { MetaInfo } from '../model/extractor/MetaInfo';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

const TAG: string = 'DescriptionFragmentPage';

/**
 * TextLinkifier.fromDescription() hands an HTML description to
 * HtmlCompat.fromHtml(FROM_HTML_MODE_LEGACY); there is no HTML renderer on this platform and a
 * Text renders markup literally, so `<a href="...">12:03</a>` showed up as its own tags.
 *
 * This is the legacy mode's visible result, not a renderer: the two tags that carry a line break
 * become one, every other tag goes away, and the entities are resolved by the Jsoup port the
 * extractors already use - so numeric and hex references resolve too, not just a hand-picked
 * handful. Tags are stripped BEFORE unescaping, so an escaped `&lt;b&gt;` in the text survives.
 *
 * KNOWN CEILING: no block-level spacing beyond <br> and </p>, and no <li> bullets - NewPipe feeds
 * this stream descriptions, which are flat text with links and line breaks.
 */
export function htmlToPlainText(html: string): string {
  const text: string = unescapeEntities(html
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/p\s*>/gi, '\n\n')
    .replace(/<[^>]*>/g, ''), false);
  // HTML collapses runs of whitespace and ignores indentation; a Text does not. Bandcamp's
  // album description carries the page's own indentation, so without this the lines it wraps
  // ("released September 4, 2026", "all rights reserved") arrive pushed in from the margin
  // while every other line is flush - the "not left-aligned" in TC-NAV-473. The line breaks
  // <br> and </p> produced above are kept; only horizontal runs collapse.
  return text
    .replace(/[^\S\r\n]+/g, ' ')
    .replace(/[^\S\r\n]*(\r?\n)[^\S\r\n]*/g, '$1');
}

/** ExtractorHelper.showMetaInfoInTextView()'s body, and the one link span per meta-info url. */
export class MetaInfoText {
  readonly text: string;
  readonly spans: LinkSpan[];

  constructor(text: string, spans: LinkSpan[]) {
    this.text = text;
    this.spans = spans;
  }
}

/** ExtractorHelper.capitalizeIfAllUppercase(): "LEARN MORE" reads "Learn more". */
function capitalizeIfAllUppercase(text: string): string {
  if (text.length === 0 || text !== text.toUpperCase()) {
    return text;
  }
  return text.substring(0, 1).toUpperCase() + text.substring(1).toLowerCase();
}

/**
 * ExtractorHelper.showMetaInfoInTextView(): every meta info as `title • content • link`, further
 * links of the same info two lines down, each link a span to its own url. The bold title is
 * styling and is not carried. An empty text means the view and its separator are GONE.
 */
export function buildMetaInfoText(metaInfos: MetaInfo[]): MetaInfoText {
  let text: string = '';
  const spans: LinkSpan[] = [];
  for (const metaInfo of metaInfos) {
    if (metaInfo.getTitle().length > 0) {
      text += metaInfo.getTitle() + DOT_SEPARATOR;
    }
    let content: string = htmlToPlainText(metaInfo.getContent().getContent()).trim();
    if (content.endsWith('.')) {
      content = content.substring(0, content.length - 1); // remove . at end
    }
    text += content;
    const urls: string[] = metaInfo.getUrls();
    for (let i = 0; i < urls.length; i++) {
      text += i === 0 ? DOT_SEPARATOR : '\n\n'; // <br/><br/>
      const urlText: string = i < metaInfo.getUrlTexts().length ? metaInfo.getUrlTexts()[i] : urls[i];
      const linkText: string = capitalizeIfAllUppercase(urlText.trim());
      spans.push(new LinkSpan(LinkKind.WEB_URL, text.length, text.length + linkText.length, linkText,
        urls[i], null));
      text += linkText;
    }
  }
  return new MetaInfoText(text, spans);
}

/** Image.ResolutionLevel.toString(), by ordinal: HIGH, MEDIUM, LOW, UNKNOWN. */
const RESOLUTION_LEVEL_NAMES: string[] = ['HIGH', 'MEDIUM', 'LOW', 'UNKNOWN'];

/** NavigationHelper.openSearchFragment(serviceId, query) - the tag chip's destination. */
class SearchParams {
  serviceId: number;
  searchString: string;

  constructor(serviceId: number, searchString: string) {
    this.serviceId = serviceId;
    this.searchString = searchString;
  }
}

/**
 * Which of setupMetadata()'s rows this is. Only two of them are decided by stream DATA rather
 * than by a blank check, and both are decided at the render site so the branch is visible there:
 * addPrivacyMetadataItem() contributes nothing for Privacy.OTHER, and the age-limit row exists
 * only while getAgeLimit() != NO_AGE_LIMIT.
 */
enum MetadataKind {
  PLAIN,
  PRIVACY,
  AGE_LIMIT
}

/** addMetadataItem(inflater, layout, linkify, labelId, content): one item_metadata.xml row. */
/** addImagesMetadataItem() joins its resolution entries with ", ". */
const SIZE_SEPARATOR: string = ', ';

class MetadataRowData {
  readonly label: ResourceStr;
  readonly value: string;
  /** The `linkify` flag - support and host are the linkified rows. */
  readonly linkified: boolean;
  /** addImagesMetadataItem(): the preferred image url each resolution entry opens. */
  readonly imageUrl: string;
  readonly kind: MetadataKind;
  /**
   * TC-PLAYER-814/820: one span per resolution entry, so `168x94` is underlined and the `, `
   * between two of them is not. Empty for every other row, which keeps its own behaviour.
   */
  readonly linkSpans: LinkSpan[];

  constructor(label: ResourceStr, value: string, linkified: boolean, imageUrl: string = '',
    kind: MetadataKind = MetadataKind.PLAIN, linkSpans: LinkSpan[] = []) {
    this.label = label;
    this.value = value;
    this.linkified = linkified;
    this.imageUrl = imageUrl;
    this.kind = kind;
    this.linkSpans = linkSpans;
  }
}

@Entry
@Component
export struct DescriptionFragmentPage {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  /**
   * The StreamInfo the host hands over. BaseDescriptionFragment takes it through the constructor
   * and never loads anything itself, so there is no fetch on this screen.
   */
  streamInfo: StreamInfo | null = null;

  /** TextLinkifier.fromDescription(...) <- streamInfo.getDescription(): the rendered body. */
  @Prop descriptionBody: string = '';
  /** The same content as the branch value: blank means body AND toggle are both GONE. */
  @State description: string = '';
  /** Localization.localizeUploadDate(...); empty means detail_upload_date_view is GONE. */
  @Prop uploadDate: string = '';
  /** setupMetadata()'s rows, in its own order. Built at runtime, never from a capture. */
  @Prop metadataRows: MetadataRowData[] = [];
  /** getTags().stream().sorted(CASE_INSENSITIVE_ORDER) - the chips that are rendered. */
  @Prop tagChips: string[] = [];
  /** The same tags as the branch value: empty means item_metadata_tags is never inflated. */
  @State tags: string[] = [];
  /** streamInfo.getAgeLimit(); NO_AGE_LIMIT means no age-limit row at all. */
  @State ageLimit: number = NO_AGE_LIMIT;
  /** streamInfo.getPrivacy(); OTHER adds nothing. */
  @State privacy: Privacy = Privacy.PUBLIC;
  @State isLoading: boolean = false;
  @State errorInfo: string | null = null;

  /** detail_select_description_button: ONE control with two states, not two controls. */
  @State descriptionSelectionEnabled: boolean = false;

  /**
   * pageAdapter.updateItem(DESCRIPTION_TAB_TAG, new DescriptionFragment(info)): the host hands the
   * tab the StreamInfo it already loaded, plus that stream's identifying arguments.
   */
  @Prop hostServiceId: number = -1;
  @Watch('onHostStreamChanged') @Prop hostUrl: string = '';

  /** The host page's route arguments; the pager mounts this tab inside the same page. */
  private serviceId: number = 0;
  private url: string = '';

  aboutToAppear(): void {
    this.readArguments();
    this.loadStreamInfo();
  }

  /**
   * loadItem() can swap the host's stream while this tab stays mounted, where the source would
   * have built a fresh DescriptionFragment(info). Dropping the old StreamInfo and re-reading the
   * arguments is that rebuild; ExtractorHelper then returns the host's newly cached instance.
   */
  private onHostStreamChanged(): void {
    this.streamInfo = null;
    this.readArguments();
    this.loadStreamInfo();
  }

  private readArguments(): void {
    // new DescriptionFragment(info) — the host's values win whenever it supplied them;
    // router.getParams() only serves the registered-route entry.
    if (this.hostUrl.length !== 0) {
      this.serviceId = this.hostServiceId;
      this.url = this.hostUrl;
      return;
    }
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
   * BaseDescriptionFragment takes the StreamInfo through the constructor. The pager mounts this
   * tab with no parameters, so the same StreamInfo is fetched back through svc_info_cache -
   * ExtractorHelper.getStreamInfo() returns the host's cached instance, not a second network
   * round-trip.
   */
  private async loadStreamInfo(): Promise<void> {
    const existing: StreamInfo | null = this.streamInfo;
    if (existing !== null) {
      this.applyInfo();
      return;
    }
    if (this.url.length === 0) {
      return;
    }
    this.isLoading = true;
    try {
      this.streamInfo = await ExtractorHelper.getStreamInfo(this.serviceId, this.url, false);
      this.applyInfo();
    } catch (err) {
      this.errorInfo = (err as BusinessError).message;
    } finally {
      this.isLoading = false;
    }
  }

  private share(): ShareUtils {
    return ServiceLocator.get().share;
  }

  /** Everything this screen renders comes off the StreamInfo the host passed in. */
  private applyInfo(): void {
    const info: StreamInfo | null = this.streamInfo;
    if (info === null) {
      return;
    }
    // Description.getType() decides how the body is rendered, and DESCRIPTION_HTML was being
    // dropped on the floor - the markup went straight into a Text.
    const description: Description = info.getDescription();
    this.descriptionBody = description.getType() === DESCRIPTION_HTML
      ? htmlToPlainText(description.getContent()) : description.getContent();
    this.description = this.descriptionBody;
    // Localization.localizeUploadDate(activity, uploadDate.offsetDateTime()); the port's
    // relativeTimeOrTextual falls back to the service's own text when nothing parsed.
    const localized: string | null = Localization.relativeTimeOrTextual(
      info.getUploadDate(), info.getTextualUploadDate());
    this.uploadDate = localized === null ? '' : localized;
    this.ageLimit = info.getAgeLimit();
    this.privacy = info.getPrivacy();
    this.tagChips = info.getTags().slice().sort();
    this.tags = this.tagChips;
    this.metadataRows = this.buildMetadataRows(info);
  }

  /** setupMetadata(inflater, layout) - the row set and its order, verbatim. */
  private buildMetadataRows(info: StreamInfo): MetadataRowData[] {
    const rows: MetadataRowData[] = [];
    this.addRow(rows, $r('app.string.metadata_category'), info.getCategory(), false);
    this.addRow(rows, $r('app.string.metadata_licence'), info.getLicence(), false);

    // addPrivacyMetadataItem() and the age-limit row are the two rows stream DATA decides, and
    // both decisions are made at the render site (see metadataRow) rather than here - so the
    // branch lives where the row is drawn instead of being baked into the list.
    rows.push(new MetadataRowData($r('app.string.metadata_privacy'),
      this.privacyLabel(info.getPrivacy()), false, '', MetadataKind.PRIVACY));
    rows.push(new MetadataRowData($r('app.string.metadata_age_limit'),
      `${info.getAgeLimit()}`, false, '', MetadataKind.AGE_LIMIT));
    const language: string | null = info.getLanguageInfo();
    if (language !== null) {
      this.addRow(rows, $r('app.string.metadata_language'), language, false);
    }
    this.addRow(rows, $r('app.string.metadata_support'), info.getSupportInfo(), true);
    this.addRow(rows, $r('app.string.metadata_host'), info.getHost(), true);

    this.addImageRow(rows, $r('app.string.metadata_thumbnails'), info.getThumbnails());
    this.addImageRow(rows, $r('app.string.metadata_uploader_avatars'), info.getUploaderAvatars());
    this.addImageRow(rows, $r('app.string.metadata_subchannel_avatars'),
      info.getSubChannelAvatars());
    return rows;
  }

  /** addMetadataItem(): isBlank(content) means the row is not inflated at all. */
  private addRow(rows: MetadataRowData[], label: ResourceStr, value: string,
    linkified: boolean): void {
    if (value.trim().length === 0) {
      return;
    }
    rows.push(new MetadataRowData(label, value, linkified));
  }

  /**
   * addImagesMetadataItem(): a comma-separated WxH list (or low/medium/high when the size is
   * unknown); the row is SKIPPED entirely when choosePreferredImage returns null.
   */
  private addImageRow(rows: MetadataRowData[], label: ResourceStr,
    images: ExtractorImage[]): void {
    const preferred: string | null = choosePreferredImage(images);
    if (preferred === null) {
      return;
    }
    const parts: string[] = [];
    images.forEach((image: ExtractorImage) => {
      parts.push(this.imageSize(image));
    });
    // addImagesMetadataItem() wraps EVERY entry in its own ClickableSpan. Linkify finds no url in
    // "168x94, 196x110", so without these the whole row was one link and the whole line was
    // underlined - TC-PLAYER-814's "it is not all the lines that need to be underlined, but the
    // links separately". The separators sit between the spans and stay plain.
    // Each span opens ITS OWN image (image.getUrl()), not the preferred one.
    const value: string = parts.join(SIZE_SEPARATOR);
    const spans: LinkSpan[] = [];
    let at: number = 0;
    parts.forEach((part: string, index: number) => {
      spans.push(new LinkSpan(LinkKind.WEB_URL, at, at + part.length, part, images[index].getUrl(),
        null));
      at = at + part.length + SIZE_SEPARATOR.length;
    });
    rows.push(new MetadataRowData(label, value, true, preferred, MetadataKind.PLAIN, spans));
  }

  /**
   * addImagesMetadataItem()'s per-image label: `WxH`, with a `?` for whichever of the two the
   * extractor reported as UNKNOWN, and the estimated resolution level when NEITHER is known. The
   * url is never a size and was never meant to be printed here.
   */
  private imageSize(image: ExtractorImage): string {
    const width: number = image.getWidth();
    const height: number = image.getHeight();
    if (width <= 0 && height <= 0) {
      return RESOLUTION_LEVEL_NAMES[image.getEstimatedResolutionLevel()];
    }
    const w: string = width > 0 ? `${width}` : '?';
    const h: string = height > 0 ? `${height}` : '?';
    return `${w}x${h}`;
  }

  /** addPrivacyMetadataItem()'s switch; OTHER (and the default) map to no row. */
  private privacyString(privacy: Privacy): Resource | null {
    if (privacy === Privacy.PUBLIC) {
      return $r('app.string.metadata_privacy_public');
    }
    if (privacy === Privacy.UNLISTED) {
      return $r('app.string.metadata_privacy_unlisted');
    }
    if (privacy === Privacy.PRIVATE) {
      return $r('app.string.metadata_privacy_private');
    }
    if (privacy === Privacy.INTERNAL) {
      return $r('app.string.metadata_privacy_internal');
    }
    return null;
  }

  /** The same switch as a plain string, so every row shares one value type. */
  private privacyLabel(privacy: Privacy): string {
    const res: Resource | null = this.privacyString(privacy);
    if (res === null) {
      return '';
    }
    try {
      const context: common.Context = getContext(this) as common.Context;
      return context.resourceManager.getStringSync(res.id);
    } catch (err) {
      // A missing translation is not a reason to render a wrong row: drop it, as OTHER does.
      hilog.warn(0x0000, TAG, 'privacy string: %{public}s', (err as Error).message);
      return '';
    }
  }

  /** A metadata LABEL long-press copies the value to the clipboard. */
  private copyValue(value: string): void {
    this.share().copyToClipboard(value);
  }

  /**
   * A tap on a link of a metadata value: each resolution entry is a ClickableSpan opening ITS
   * image in the browser; the linkified support / host rows are TextLinkifier.fromPlainText url
   * spans.
   */
  private openMetadataLink(row: MetadataRowData, span: LinkSpan): void {
    const url: string | null = span.url;
    if (url === null) {
      return;
    }
    if (row.imageUrl.length > 0) {
      this.share().openUrlInBrowser(url);
    } else {
      openUrlLink(url);
    }
  }

  /** LongPressClickableSpan.onLongClick(): copy the url, the hashtag or the timestamp link. */
  private copyLink(span: LinkSpan): void {
    const info: StreamInfo | null = this.streamInfo;
    this.copyValue(linkTextToCopy(span, info === null ? this.serviceId : info.getServiceId(),
      info === null ? this.url : info.getUrl()));
  }

  /**
   * TextLinkifier's ClickableSpans inside the description. A hashtag searches for it; a url or an
   * e-mail opens externally. A timestamp is only clickable because getStreamUrl() puts a stream in
   * context - S4 seeks the player for it.
   */
  private openLink(span: LinkSpan): void {
    if (span.kind === LinkKind.HASHTAG) {
      this.openTagSearch(span.text);
      return;
    }
    // handleUrlDescriptionTimestamp(): a timestamp in the description is a position in THIS
    // stream. The span carries no url, which is why the tap used to do nothing at all.
    const seconds: number | null = span.seconds;
    if (span.kind === LinkKind.TIMESTAMP && seconds !== null) {
      const info: StreamInfo | null = this.streamInfo;
      openStreamAtTimestamp(info === null ? this.serviceId : info.getServiceId(),
        info === null ? this.url : info.getUrl(), seconds);
      return;
    }
    // UrlLongPressClickableSpan: a `&t=` link to a stream starts it there, anything else opens.
    const url: string | null = span.url;
    if (url !== null) {
      openUrlLink(url);
    }
  }

  /** Tap on a chip opens SearchFragment for that tag; long-press copies it. */
  private openTagSearch(tag: string): void {
    const info: StreamInfo | null = this.streamInfo;
    router.pushUrl({
      url: 'pages/SearchFragmentPage',
      params: new SearchParams(info === null ? 0 : info.getServiceId(), tag)
    });
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Builders
  ////////////////////////////////////////////////////////////////////////// */

  /** item_metadata.xml: a 96dp end-aligned label column, then the value 16dp after it. */
  @Builder
  metadataRow(row: MetadataRowData) {
    // The two data-conditional rows of setupMetadata(): OTHER contributes no privacy row, and
    // NO_AGE_LIMIT contributes no age-limit row. Every other row is dropped by addMetadataItem()
    // when its content is blank, which is the value guard below.
    if (row.kind === MetadataKind.PRIVACY ? this.privacy !== Privacy.OTHER
      : (row.kind === MetadataKind.AGE_LIMIT ? this.ageLimit !== NO_AGE_LIMIT
        : row.value.length > 0)) {
      Row() {
      Text(row.label)
        .id('metadata_type_view')
        .width(96)
        .textAlign(TextAlign.End)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        // android:textAllCaps="true" on metadata_type_view (item_metadata.xml).
        .textCase(TextCase.UpperCase)
        .fontColor($r('app.color.on_surface'))
        .onClick(() => {
          this.copyValue(row.value);
        })
        .gesture(LongPressGesture().onAction(() => {
          this.copyValue(row.value);
        }))

      Column() {
        NewPipeTextView({
          slug: 'metadata_content_view',
          content: row.value,
          linkSpans: row.linkSpans,
          onLinkTapped: row.linkified ? ((span: LinkSpan): void => {
            this.openMetadataLink(row, span);
          }) : null,
          onShareSelection: (): void => {
            this.copyValue(row.value);
          }
        })
      }
        .layoutWeight(1)
        .margin({ left: 16 })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      // item_metadata.xml: android:paddingVertical="6dp".
      .padding({ top: 6, bottom: 6 })
      .alignItems(VerticalAlign.Center)
    }
  }

  build() {
    // NestedScrollView > ConstraintLayout: the whole tab scrolls as one column.
    Scroll() {
      Column() {
        Row() {
          // GONE when streamInfo.getUploadDate() == null.
          if (this.uploadDate.length > 0) {
            Text(this.uploadDate)
              .id('detail_upload_date_view')
              .layoutWeight(1)
              .fontSize(13)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.on_surface_variant'))
              .margin({ left: 16, top: 6, right: 8 })
          } else {
            Blank()
          }

          // ONE control with two states: ic_select_all <-> ic_close. GONE together with the body
          // when the description is empty - no selection toggle is wired at all then.
          if (this.description.length > 0) {
            Image(this.descriptionSelectionEnabled
              ? $r('app.media.ic_close') : $r('app.media.ic_select_all'))
              .id('detail_select_description_button')
              .width(34)
              .height(34)
              .padding(5)
              .margin({ right: 16, top: 6, bottom: 2 })
              .objectFit(ImageFit.Contain)
              .onClick(() => {
                this.descriptionSelectionEnabled = !this.descriptionSelectionEnabled;
              })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)

        // detail_description_note_view: VISIBLE only while selection mode is on.
        if (this.descriptionSelectionEnabled) {
          Text($r('app.string.description_select_note'))
            .id('detail_description_note_view')
            .width('100%')
            .textAlign(TextAlign.Center)
            .fontSize(12)
            .fontStyle(FontStyle.Italic)
            .fontColor($r('app.color.on_surface_variant'))
            // PADDING, not margin: a 100%-wide box plus 16vp side margins measures 100% + 32vp
            // and clips off the right edge. Padding takes the 16vp out of the box instead.
            .padding({ left: 16, right: 16 })
            .margin({ top: 8 })
        }

        // TextLinkifier.fromDescription(...); the whole view is GONE when the body is blank.
        if (this.description.length > 0) {
          Column() {
            NewPipeTextView({
              slug: 'detail_description_view',
              content: this.descriptionBody,
              // @dimen/video_item_detail_description_text_size = 13sp, textAppearanceMedium.
              textSizeFp: 13,
              textColorValue: $r('app.color.on_surface_variant'),
              selectable: this.descriptionSelectionEnabled,
              // A long press here is what STARTS a selection once the toggle is on; the source
              // copies nothing from the body, whichever state the toggle is in.
              copyOnLongPress: false,
              onLinkTapped: (span: LinkSpan): void => {
                this.openLink(span);
              },
              onLinkLongPressed: (span: LinkSpan): void => {
                this.copyLink(span);
              }
            })
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
          .margin({ top: 8 })
        }

        // detail_metadata_layout: an EMPTY LinearLayout in the XML - the rows are added one by
        // one in setupMetadata()'s order, so the count varies per stream.
        Column() {
          ForEach(this.metadataRows, (row: MetadataRowData) => {
            this.metadataRow(row)
          }, (row: MetadataRowData, index: number) => `${index}-${row.value}`)

          // item_metadata_tags.xml - inflated only when getTags() is non-empty.
          if (this.tags.length > 0) {
            Column() {
              Text($r('app.string.metadata_tags'))
                .id('metadata_type_view')
                .width('100%')
                .textAlign(TextAlign.Center)
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                // android:textAllCaps="true" (item_metadata_tags.xml).
                .textCase(TextCase.UpperCase)
                .fontColor($r('app.color.on_surface'))
                .margin({ top: 8 })

              Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center }) {
                ForEach(this.tagChips, (tag: string) => {
                  // chip.xml repeats @+id/description_tag_itemroot per chip (Rule 12's list-row
                  // exception: the replay resolves a chip by index).
                  Text(tag)
                    .id('description_tag_itemroot')
                    .maxLines(1)
                    .height(32)
                    .padding({ left: 12, right: 12 })
                    .backgroundColor($r('app.color.contrast_background'))
                    .borderRadius(16)
                    .fontSize(14)
                    .fontColor($r('app.color.on_surface'))
                    .textAlign(TextAlign.Center)
                    .margin(4)
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
        .padding({ left: 16, right: 16 })
        .margin({ top: 10, bottom: 10 })
        .alignItems(HorizontalAlign.Start)
      }
      .id('constraint_layout')
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .id('DescriptionFragmentPage')
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .backgroundColor(themedBackground(this.blackTheme))
    // NestedScrollingChild, same contract as the item lists: the detail header above this pager
    // collapses before this tab scrolls, and comes back only once this tab is at its top.
    .nestedScroll({
      scrollForward: NestedScrollMode.PARENT_FIRST,
      scrollBackward: NestedScrollMode.SELF_FIRST
    })
  }
}
