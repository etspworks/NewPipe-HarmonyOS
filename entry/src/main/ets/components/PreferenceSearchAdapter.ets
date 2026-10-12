/*
 * S3 - port of PreferenceSearchAdapter (settings_preferencesearch_list_item_result.xml).
 *
 * ListAdapter<PreferenceSearchItem, PreferenceViewHolder> over the searcher's results:
 *   submitList(results)     -> PreferenceSearchDataSource.submitList,
 *   onBindViewHolder        -> the row below (title always, summary and breadcrumbs only when the
 *                              item carries them - the source sets those TextViews GONE otherwise),
 *   holder.itemView.onClick -> onItemClicked, which the fragment forwards to the ACTIVITY's
 *                              onSearchResultClicked (it resolves the owning settings screen from
 *                              searchIndexItemResId, pushes it and highlights the preference).
 *
 * The adapter owns no state and performs no navigation: the row click is a callback up to the page,
 * exactly as `Consumer<PreferenceSearchItem> onItemClickListener` is in the source.
 *
 * 🟥 SLUG: the row layout has no root id of its own - the source wires the click on
 * holder.itemView - so the plan's slug is the LAYOUT name, settings_preferencesearch_list_item
 * _result, and that is what the capture recorded. It does not end in `itemroot` even though the
 * row repeats; it is used verbatim rather than renamed, and reported to the orchestrator.
 *
 * No visual styling in this pass (S3); the row's 16dp padding and text sizes are S5.
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { PreferenceSearchItem } from '../model/app/PreferenceSearchItem';

/* S5 - style only. Every value is settings_preferencesearch_list_item_result.xml's own: a 16dp
 * horizontal / 12dp vertical padding, title 16sp, summary and breadcrumbs 14sp, and the
 * breadcrumbs line at android:alpha="0.6". All three take ?android:attr/editTextColor, which
 * NewPipe's light theme leaves at the platform's #DE000000. This screen's capture renders zero
 * rows (no query was typed), so the row is styled from the layout, not from pixels. */
/** ?android:attr/editTextColor in the light theme. */
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');
/** android:alpha="0.6" on the breadcrumbs line only. */
const BREADCRUMBS_ALPHA: number = 0.6;

/** getItemCount()/getItem(position) over the submitted result list. */
export class PreferenceSearchDataSource implements IDataSource {
  private items: PreferenceSearchItem[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): PreferenceSearchItem {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos: number = this.listeners.indexOf(listener);
    if (pos >= 0) {
      this.listeners.splice(pos, 1);
    }
  }

  /** adapter.submitList(searcher.searchFor(keyword)). */
  submitList(items: PreferenceSearchItem[]): void {
    this.items = items;
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataReloaded();
    });
  }
}

@Component
export struct PreferenceSearchAdapter {
  dataSource: PreferenceSearchDataSource = new PreferenceSearchDataSource();
  /** onItemClickListener.accept(item) -> PreferenceSearchFragment::onItemClicked. */
  onItemClicked: (index: number) => void = (index: number): void => {
    hilog.debug(0x0000, 'NewPipe', 'PreferenceSearchAdapter: onItemClicked not bound (%{public}d)',
      index);
  };

  build() {
    List() {
      LazyForEach(this.dataSource, (item: PreferenceSearchItem, index: number) => {
        ListItem() {
          Column() {
            // binding.title.setText(item.getTitle()) - always present.
            Text(item.title)
              .id('title')
              .width('100%')
              .fontSize(16)
              .lineHeight(22)
              .fontColor(COLOR_ON_SURFACE)

            // binding.summary: GONE when item.getSummary().isEmpty(), else VISIBLE with setText.
            if (item.summary.length > 0) {
              Text(item.summary)
                .id('summary')
                .width('100%')
                .fontSize(14)
                .lineHeight(19)
                .fontColor(COLOR_ON_SURFACE)
            }

            // binding.breadcrumbs: GONE when item.getBreadcrumbs().isEmpty().
            if (item.breadcrumbs.length > 0) {
              Text(item.breadcrumbs)
                .id('breadcrumbs')
                .width('100%')
                .fontSize(14)
                .lineHeight(19)
                .fontColor(COLOR_ON_SURFACE)
                .opacity(BREADCRUMBS_ALPHA)
            }
          }
          // holder.itemView's own click, on the row root. Every row shares this slug and the
          // replay resolves it by index (rule 12's list-row exception).
          .id('settings_preferencesearch_list_item_result')
          .width('100%')
          // android:padding="16dp" with android:paddingTop/Bottom="12dp" overriding it.
          .padding({ left: 16, right: 16, top: 12, bottom: 12 })
          .alignItems(HorizontalAlign.Start)
          .onClick(() => {
            this.onItemClicked(index);
          })
        }
      }, (item: PreferenceSearchItem) => item.key)
    }
    .width('100%')
    .height('100%')
  }
}
