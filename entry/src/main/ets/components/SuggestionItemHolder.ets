/*
 * S3 — port of SuggestionListAdapter.SuggestionItemHolder (item_search_suggestion.xml).
 *
 * The row is TWO independent touch targets, exactly as the RelativeLayout has them:
 *   suggestion_search  — the icon + query block; tap runs the search, long-press opens the
 *                        delete-from-history dialog (only for fromHistory items),
 *   suggestion_insert  — the ic_search_add arrow; copies the query into the field WITHOUT
 *                        searching.
 * updateFrom(item) is the icon switch: ic_history for a history row, ic_search for a remote one —
 * the ONLY visual difference between the two suggestion subtypes.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SuggestionItem } from '../model/app/SuggestionItem';

/** S5 — AppCompat textColorPrimary in the LightTheme; no migrated resource carries it. */
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');

/** A gesture the owning page has not bound yet — never a silent no-op. */
function unwiredGesture(which: string): void {
  hilog.debug(0x0000, 'NewPipe', 'SuggestionItemHolder: %{public}s not bound', which);
}

@Component
export struct SuggestionItemHolder {
  item: SuggestionItem | null = null;
  /** listener.onSuggestionItemSelected(item). */
  onSelected: () => void = (): void => {
    unwiredGesture('onSelected');
  };
  /** listener.onSuggestionItemInserted(item). */
  onInserted: () => void = (): void => {
    unwiredGesture('onInserted');
  };
  /** listener.onSuggestionItemLongClick(item). */
  onLongClick: () => void = (): void => {
    unwiredGesture('onLongClick');
  };

  /** updateFrom(): setImageResource(item.fromHistory ? ic_history : ic_search). */
  private icon(): Resource {
    return this.item !== null && this.item.fromHistory
      ? $r('app.media.ic_history')
      : $r('app.media.ic_search');
  }

  private query(): string {
    return this.item === null ? '' : this.item.query;
  }

  build() {
    Row() {
      Row() {
        // 24dp glyph with a 16dp margin either side. ic_history / ic_search are already
        // filled @color/defaultIconTint (#000000), the light theme's icon color, so no tint.
        Image(this.icon())
          .id('item_suggestion_icon')
          .width(24)
          .height(24)
          .objectFit(ImageFit.Contain)
          .margin({ left: 16, right: 16 })

        // TextAppearance.AppCompat.Body1 overridden to 14sp, two lines then ellipsis.
        Text(this.query())
          .id('item_suggestion_query')
          .layoutWeight(1)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontSize(14)
          .fontColor(COLOR_ON_SURFACE)
      }
      .id('suggestion_search')
      .layoutWeight(1)
      .alignItems(VerticalAlign.Center)
      // suggestion_search: paddingTop/paddingBottom 8dp, nothing horizontal.
      .padding({ top: 8, bottom: 8 })
      .onClick(() => {
        this.onSelected();
      })
      .gesture(LongPressGesture().onAction(() => {
        this.onLongClick();
      }))

      Row() {
        Image($r('app.media.ic_search_add'))
          .width(20)
          .height(20)
          .objectFit(ImageFit.Contain)
      }
      .id('suggestion_insert')
      // suggestion_insert: paddingLeft/Right 16dp, paddingTop 10dp, paddingBottom 8dp.
      .padding({ left: 16, right: 16, top: 10, bottom: 8 })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.onInserted();
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }
}
