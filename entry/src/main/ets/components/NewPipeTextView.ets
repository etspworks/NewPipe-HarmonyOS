/*
 * S3 - port of org.schabi.newpipe.views.NewPipeTextView, the AppCompatTextView every NewPipe
 * layout uses in place of a plain TextView.
 *
 * It carries exactly two behaviours over the platform text view, and both survive the port:
 *   1. the floating "Share" action on a text SELECTION goes through ShareUtils.shareText, so the
 *      app's own share sheet opens instead of the vendor one, and
 *   2. the movement method is re-applied after every setText, which is what keeps inline links
 *      clickable when the text itself is not selectable.
 *
 * In ArkUI (2) is intrinsic - a Text with `copyOption` keeps its own selection handling across
 * content changes - so this struct's real job is (1): the selection share, plus the long-press
 * copy the description and metadata rows install on top of it.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { text } from '@kit.ArkGraphics2D';
import { linkifyAll, LinkSpan } from '../common/text/Linkify';

/** setMaxLines is not called at all on most hosts, so the text wraps freely. */
const MAX_LINES_UNBOUNDED: number = 1000;

/** One run of the body: plain text, or one of TextLinkifier's clickable spans. */
class TextSegment {
  readonly text: string;
  readonly link: LinkSpan | null;

  constructor(text: string, link: LinkSpan | null) {
    this.text = text;
    this.link = link;
  }
}

@Component
export struct NewPipeTextView {
  content: ResourceStr = '';
  /**
   * Rule 12: the slug belongs to the CALLER - fragment_description.xml names this widget
   * detail_description_view, item_metadata.xml names it metadata_content_view, and so on. A
   * hardcoded id here would render one screen-foreign slug on every host.
   */
  slug: string = 'newpipe_text_view';
  /** textIsSelectable - the description body turns this on in selection mode. */
  @Prop selectable: boolean = false;
  /** TextLinkifier installs a click on the whole body; null leaves it inert, as in the source. */
  onLinkClick: (() => void) | null = null;
  /**
   * TextLinkifier's per-span ClickableSpan: the host decides what a url, a hashtag or a
   * timestamp does (open the browser, search the tag, seek the player).
   */
  onLinkTapped: ((span: LinkSpan) => void) | null = null;
  /**
   * LongPressClickableSpan.onLongClick: a long press ON a link run hands that span to the host
   * (the description copies the url, the hashtag or the timestamp link). Null leaves the long
   * press to copyOnLongPress exactly as before.
   */
  onLinkLongPressed: ((span: LinkSpan) => void) | null = null;
  /**
   * NewPipeTextViewHelper.shareSelectedTextWithShareUtils(this) - the floating Share action, and
   * the long-press copy the metadata labels bind.
   */
  onShareSelection: () => void = (): void => {
    hilog.debug(0x0000, 'NewPipe', 'NewPipeTextView: share selection not bound');
  };
  /**
   * Whether a LONG PRESS runs onShareSelection. The metadata rows copy their value that way, so
   * true keeps every existing host exactly as it was. The description body passes false: there a
   * long press is what STARTS a selection, and the source copies nothing from it.
   */
  copyOnLongPress: boolean = true;
  /** setMaxLines(): the description body is clamped until it is expanded. */
  @Prop maxTextLines: number = -1;
  /**
   * S5 typography. AppCompatTextView with no textAppearance renders at the platform's ~14sp
   * body size in textColorPrimary, which is what every host that does not override it gets;
   * a host with its own dimen (the description body's 13sp) passes it in.
   */
  textSizeFp: number = 14;
  textColorValue: ResourceColor = $r('app.color.on_surface');
  /**
   * gravity: TextAlign.Start is what an unset gravity renders, so the default leaves every
   * existing host exactly where it was; the centred hosts (the comments empty state) pass Center.
   */
  textAlignment: TextAlign = TextAlign.Start;

  /**
   * TC-PLAYER-814/820: spans supplied by the HOST, for a body Linkify cannot see links in.
   * addImagesMetadataItem() wraps every resolution entry in its own ClickableSpan - "168x94" is a
   * link, the ", " between two of them is not - and no url pattern will ever find those. A host
   * that knows where its links are hands them over; everyone else leaves this empty and gets
   * linkifyAll() exactly as before.
   */
  linkSpans: LinkSpan[] = [];

  /** Maps a long press to the character under it (getGlyphPositionAtCoordinate). */
  private textController: TextController = new TextController();
  /**
   * LongPressLinkMovementMethod: the lift that ends a long press on a link is not also a tap on
   * it. Set when a long press went to onLinkLongPressed, cleared on the next touch down.
   */
  private longPressedLink: boolean = false;

  private hasLink(): boolean {
    return this.onLinkClick !== null;
  }

  /**
   * TextLinkifier.changeIntentsOfDescriptionLinks(): the body is split into plain runs and the
   * spans Linkify found. Empty for a Resource body or a body with no links, and an empty list
   * leaves the Text rendering its own content - a Text shows its children only when it has any.
   */
  private segments(): TextSegment[] {
    const raw: ResourceStr = this.content;
    if (typeof raw !== 'string') {
      return [];
    }
    const text: string = raw as string;
    const spans: LinkSpan[] = this.linkSpans.length > 0 ? this.linkSpans : linkifyAll(text);
    if (spans.length === 0) {
      return [];
    }
    const parts: TextSegment[] = [];
    let cursor: number = 0;
    for (const span of spans) {
      if (span.start > cursor) {
        parts.push(new TextSegment(text.substring(cursor, span.start), null));
      }
      parts.push(new TextSegment(text.substring(span.start, span.end), span));
      cursor = span.end;
    }
    if (cursor < text.length) {
      parts.push(new TextSegment(text.substring(cursor), null));
    }
    return parts;
  }

  /** The link run under a long press, or null over plain text. */
  private linkAt(event: GestureEvent): LinkSpan | null {
    const raw: ResourceStr = this.content;
    if (typeof raw !== 'string' || event.fingerList.length === 0) {
      return null;
    }
    const finger: FingerInfo = event.fingerList[0];
    // The layout manager works in px; the finger is reported in vp.
    const glyph: PositionWithAffinity = this.textController.getLayoutManager()
      .getGlyphPositionAtCoordinate(this.getUIContext().vp2px(finger.localX),
        this.getUIContext().vp2px(finger.localY));
    // UPSTREAM: the position sits AFTER the character that was pressed.
    const index: number = glyph.affinity === text.Affinity.UPSTREAM ? glyph.position - 1 : glyph.position;
    const spans: LinkSpan[] = this.linkSpans.length > 0 ? this.linkSpans : linkifyAll(raw as string);
    for (const span of spans) {
      if (index >= span.start && index < span.end) {
        return span;
      }
    }
    return null;
  }

  /** A tap on a link run; a plain run has nothing to open, exactly as in the source. */
  private tapSegment(segment: TextSegment): void {
    const link: LinkSpan | null = segment.link;
    if (link === null || this.longPressedLink) {
      return;
    }
    const handler: ((span: LinkSpan) => void) | null = this.onLinkTapped;
    if (handler !== null) {
      handler(link);
      return;
    }
    this.fireLink();
  }

  /**
   * addImagesMetadataItem() wraps EVERY resolution entry in its own ClickableSpan, so that row
   * renders underlined in the accent colour. Linkify finds no url in "1200x?, 168x94", so the
   * span list is empty there and the runs below never fire: a body whose host bound a whole-body
   * click IS the link, and is drawn as one.
   */
  private wholeBodyIsLink(): boolean {
    return this.hasLink() && this.segments().length === 0;
  }

  private fireLink(): void {
    const handler: (() => void) | null = this.onLinkClick;
    if (handler !== null) {
      handler();
    }
  }

  build() {
    Text(this.content, { controller: this.textController }) {
      ForEach(this.segments(), (segment: TextSegment, index: number) => {
        // TextLinkifier's ClickableSpans render as underlined accent runs; a plain run keeps
        // the body colour.
        Span(segment.text)
          .fontColor(segment.link === null
            ? this.textColorValue : $r('app.color.accent'))
          .decoration({
            type: segment.link === null ? TextDecorationType.None : TextDecorationType.Underline
          })
          .onClick(() => {
            this.tapSegment(segment);
          })
      }, (segment: TextSegment, index: number) => `${index}-${segment.text}`)
    }
      .id(this.slug)
      // NO width here: '100%' resolves against the AVAILABLE space, so a host that also carries
      // side margins measured 100% + those margins and clipped off the right edge. A Text with
      // no width wraps inside whatever box the host gives it, margins included.
      .textAlign(this.textAlignment)
      // A TextView breaks a word that cannot fit a line of its own; ArkUI's default WordBreak
      // .NORMAL wraps non-CJK text at SPACES ONLY, so an unusually long metadata value with no
      // space in it - a resolution list, a url - ran past the row instead of wrapping inside it.
      // BREAK_WORD is the TextView rule: keep whole words wherever they fit, break only the word
      // that cannot, so every host whose text already fits renders exactly as before.
      .wordBreak(WordBreak.BREAK_WORD)
      .fontSize(this.textSizeFp)
      .fontColor(this.wholeBodyIsLink()
        ? $r('app.color.accent') : this.textColorValue)
      .decoration({
        type: this.wholeBodyIsLink() ? TextDecorationType.Underline : TextDecorationType.None
      })
      // textIsSelectable; a selectable Text is what makes the floating actions reachable.
      .copyOption(this.selectable ? CopyOptions.LocalDevice : CopyOptions.None)
      .maxLines(this.maxTextLines > 0 ? this.maxTextLines : MAX_LINES_UNBOUNDED)
      .onClick(() => {
        if (this.hasLink() && !this.longPressedLink) {
          this.fireLink();
        }
      })
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.longPressedLink = false;
        }
      })
      // parallelGesture, not gesture: an exclusive long press wins over the Text's own, which is
      // the one that has to start a selection once copyOption is on.
      .parallelGesture(LongPressGesture().onAction((event: GestureEvent) => {
        const handler: ((span: LinkSpan) => void) | null = this.onLinkLongPressed;
        const link: LinkSpan | null = handler === null ? null : this.linkAt(event);
        if (handler !== null && link !== null) {
          this.longPressedLink = true;
          handler(link);
          return;
        }
        if (this.copyOnLongPress) {
          this.onShareSelection();
        }
      }))
  }
}
