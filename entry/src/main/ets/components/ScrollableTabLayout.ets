/**
 * S3 - fragment_channel's TabLayout (app:tabMode="scrollable", app:tabGravity="fill"), the strip
 * that ChannelFragment.updateTabs() titles from the TabAdapter and that setupWithViewPager binds
 * to the pager.
 *
 * The tab SET is dynamic, so the strip renders whatever titles it is handed - never a fixed bar.
 * Selection is a @Link: the pager and the strip share one index, which is what setupWithViewPager
 * does in both directions.
 */

import { servicePrimaryColor } from '../common/theme/ServiceTheme';

/** TabLayout's own metrics, read off the S0047 capture (1 vp = 3 px on that 1080-wide screen). */
const TAB_HEIGHT: number = 48;
const TAB_PADDING_H: number = 12;
const TAB_TEXT_SIZE: number = 14;
const TAB_LETTER_SPACING: number = 1.25;
const TAB_INDICATOR_HEIGHT: number = 3;
/** How long a ripple stays lit after the finger lifts, then how long it takes to fade. */
const RIPPLE_HOLD_MS: number = 70;
const RIPPLE_FADE_MS: number = 105;
/** The icon strip's cells are 144px tall on the S0157 capture with a 24vp glyph centred in them. */
const TAB_ICON_PADDING_V: number = 12;

@Component
export struct ScrollableTabLayout {
  /** tabAdapter.getItemTitle(i) for every i - already localised by the host. */
  /** ?attr/colorPrimary follows the service the drawer selected; see servicePrimaryColor(). */
  @StorageProp('mainSelectedServiceId') activeServiceId: number = 0;

  @Prop titles: string[] = [];
  /**
   * MainFragment.updateTabsIconAndDescription(): `tab.setIcon(...)` +
   * `tab.setContentDescription(...)` renders an ICON-ONLY cell whose label survives only as the
   * content description. ChannelFragment.updateTabs() calls `setText` instead and passes nothing
   * here, so an empty array keeps the text strip exactly as it was.
   * One Resource per title, in the same order; any other length falls back to the text cell.
   */
  @Prop icons: Resource[] = [];
  /**
   * app:tabBackground. ChannelFragment and MainFragment both leave it at ?attr/colorPrimary,
   * which is what an empty value below still resolves to, so neither host changes behaviour;
   * the video detail strip is the one that sits somewhere other than a service-coloured bar.
   */
  @Prop tabBackground: ResourceColor = '';
  /**
   * app:tabIconTint. The service-coloured app bars carry white glyphs (@color/white), which is
   * what this still defaults to; the video detail strip is the one that is NOT a coloured bar -
   * on ?attr/windowBackground a white glyph is invisible, so that host names its own tint.
   */
  @Prop tabIconTint: ResourceColor = $r('app.color.on_primary');
  /** The selected tab; shared with the pager, as setupWithViewPager wires it. */
  @Link selectedIndex: number;
  /**
   * Which edge of the strip carries the selection indicator. A TabLayout under an app bar draws
   * it along its BOTTOM, which is what ChannelFragment and MainFragment want and what this
   * component always did. The video detail screen's strip is the page's BOTTOM bar, and there the
   * reference draws the indicator along its TOP - measured at y=2166, the first row of a strip
   * spanning 2166..2208, where the port drew it at the strip's foot. Same control, opposite edge,
   * because the bar is on the opposite side of its content.
   */
  @Prop indicatorOnTop: boolean = false;

  /**
   * TabLayout.OnTabSelectedListener.onTabReselected(tab) — a tap on the tab that is ALREADY
   * selected. select() returns early for it, so without this the second tap dispatched nothing
   * at all; the hosts that care use it to send their list back to the top.
   */
  onTabReselected: (index: number) => void = (): void => {
  };

  /** The cell whose ripple is showing; -1 for none. */
  @State private pressedIndex: number = -1;
  /** Measured strip width, for mapping a tap on the strip itself to a tab. */
  @State private stripWidth: number = 0;

  /**
   * TabLayout's bounded ripple, measured on the reference: a pressed cell on the service-coloured
   * bar reads ~25% white over colorPrimary. On a host-coloured strip it is the light theme's
   * @color/light_ripple_color instead.
   */
  private pressedBackground(): ResourceColor {
    return typeof this.tabBackground === 'string' && this.tabBackground.length === 0
      ? '#40FFFFFF' : $r('app.color.ripple');
  }

  private stripBackground(): ResourceColor {
    return typeof this.tabBackground === 'string' && this.tabBackground.length === 0
      ? servicePrimaryColor(this.activeServiceId) : this.tabBackground;
  }

  private select(index: number): void {
    if (index < 0 || index >= this.titles.length) {
      return;
    }
    if (index === this.selectedIndex) {
      this.onTabReselected(index);
      return;
    }
    this.selectedIndex = index;
  }

  /**
   * TabLayout selects the tab under the pointer. A tap on a tab hits that tab's own handler
   * (ArkUI gives the touch to the topmost target); this only runs for the gaps between them.
   * ponytail: equal-width mapping, which is what tabGravity="fill" lays out; if a channel ever
   * ships enough tabs to make the strip genuinely scroll, measure the cells instead.
   */
  private selectAtX(x: number): void {
    const count: number = this.titles.length;
    if (count === 0 || this.stripWidth <= 0) {
      return;
    }
    this.select(Math.min(count - 1, Math.max(0, Math.floor(x / (this.stripWidth / count)))));
  }

  @Builder
  tabCell(title: string, index: number) {
    if (this.icons.length === this.titles.length && this.titles.length > 0) {
      // setIcon() + setContentDescription(): the glyph IS the cell, the name is only the
      // description. tabGravity="fill" makes every cell an equal share of the strip.
      // An icon-only cell renders NO text, and `.accessibilityText()` does not surface in the
      // uitest dump — so the shared row id left every one of these cells indistinguishable and
      // the drivers fell back to a blind coordinate tap. The capture identified each cell by
      // its contentDescription (`tap_subscriptions`, `tap_live`, …), so Rule 12's slug for
      // this cell is that description; the row-root convention only applies where the replay
      // resolves a row BY INDEX, which a named tab never is.
      Stack({ alignContent: this.indicatorOnTop ? Alignment.Top : Alignment.Bottom }) {
        Image(this.icons[index])
          .width('100%')
          .height('100%')
          .padding({ top: TAB_ICON_PADDING_V, bottom: TAB_ICON_PADDING_V })
          .objectFit(ImageFit.Contain)
          // app:tabIconTint — @color/white on a coloured bar, the host's own colour otherwise.
          .fillColor(this.tabIconTint)
        this.indicator(index, this.tabIconTint)
      }
      .id(title.toLowerCase().replace(/[^a-z0-9]+/g, '_'))
      .accessibilityText(title)
      .height(TAB_HEIGHT)
      .layoutWeight(1)
      .backgroundColor(this.pressedIndex === index ? this.pressedBackground() : Color.Transparent)
      .clickEffect(null)
      .onTouch((event: TouchEvent) => {
        this.onCellTouch(event, index);
      })
      .onClick(() => {
        this.select(index);
      })
    } else {
      this.textTabCell(title, index);
    }
  }

  @Builder
  textTabCell(title: string, index: number) {
    // tabMode="scrollable": a cell is as wide as its label plus the tab's own padding. The
    // indicator is the cell's own edge border, not a Stack sibling: inside the horizontal Scroll a
    // sibling's width('100%') resolved against the whole viewport, so the selected cell grew to
    // the full screen width and pushed every other tab off to the right. The border eats into the
    // content box, so the opposite edge gets the same padding and the label stays centred.
    Text(title)
      .height('100%')
      .padding({
        left: TAB_PADDING_H,
        right: TAB_PADDING_H,
        top: this.textIndicatorInset(index, true),
        bottom: this.textIndicatorInset(index, false)
      })
      .border({
        width: {
          top: this.selectedIndex === index && this.indicatorOnTop ? TAB_INDICATOR_HEIGHT : 0,
          bottom: this.selectedIndex === index && !this.indicatorOnTop ? TAB_INDICATOR_HEIGHT : 0
        },
        // app:tabIndicatorColor="@color/white" under the selected tab only.
        color: $r('app.color.on_primary')
      })
      .textAlign(TextAlign.Center)
      .maxLines(1)
      .textCase(TextCase.UpperCase)
      .fontSize(TAB_TEXT_SIZE)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.on_primary'))
      .letterSpacing(TAB_LETTER_SPACING)
    // Rule 12's list-row exception: one shared id, the replay resolves a tab by index.
    .id('tab_layout_itemroot')
    .height(TAB_HEIGHT)
    .backgroundColor(this.pressedIndex === index ? this.pressedBackground() : Color.Transparent)
    .clickEffect(null)
    .onTouch((event: TouchEvent) => {
      this.onCellTouch(event, index);
    })
    .onClick(() => {
      this.select(index);
    })
  }

  /**
   * The selection indicator, laid OVER the cell. It used to be a border, and a border eats into
   * the content box: the selected glyph shrank by the indicator's height every time a tab was
   * tapped - the "shrink" the reference never shows.
   */
  @Builder
  indicator(index: number, color: ResourceColor) {
    if (this.selectedIndex === index) {
      Row()
        .width('100%')
        .height(TAB_INDICATOR_HEIGHT)
        .backgroundColor(color)
    }
  }

  /** Padding on the edge OPPOSITE the selected text cell's indicator border, so it stays centred. */
  private textIndicatorInset(index: number, top: boolean): number {
    if (this.selectedIndex !== index) {
      return 0;
    }
    return top !== this.indicatorOnTop ? TAB_INDICATOR_HEIGHT : 0;
  }

  /**
   * TabLayout's ripple: the cell lights up on touch-down and, after the finger lifts, stays lit
   * just long enough to be seen before it fades - a quick tap still flashes, where a pressed
   * stateStyle was gone before the frame that would have shown it.
   */
  private onCellTouch(event: TouchEvent, index: number): void {
    if (event.type === TouchType.Down) {
      this.pressedIndex = index;
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      setTimeout(() => {
        if (this.pressedIndex !== index) {
          return;
        }
        this.getUIContext().animateTo({ duration: RIPPLE_FADE_MS, curve: Curve.EaseOut }, () => {
          this.pressedIndex = -1;
        });
      }, RIPPLE_HOLD_MS);
    }
  }

  build() {
    Scroll() {
      Row() {
        ForEach(this.titles, (title: string, index: number) => {
          this.tabCell(title, index);
        }, (title: string, index: number) => `${index}:${title}`)
      }
      .height(TAB_HEIGHT)
    }
    // No hardcoded .id() here: fragment_main.xml names this widget `main_tab_layout` and
    // fragment_video_detail.xml names it `tab_layout`, so the id is the CALLER's to set.
    // Carrying one here rendered a second, screen-foreign slug on every host.
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .height(TAB_HEIGHT)
    // android:background="?attr/colorPrimary", unless the host names its own.
    .backgroundColor(this.stripBackground())
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.stripWidth = Number(newValue.width);
    })
    .clickEffect(null)
    .onClick((event: ClickEvent) => {
      this.selectAtX(event.x);
    })
  }
}
