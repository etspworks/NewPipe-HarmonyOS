/**
 * S3 - PreferenceSearchFragment (screen_preference_search): the real view tree, unstyled.
 *
 * settings_preferencesearch_fragment.xml: a 4dp toolbar shadow, the empty_state_view (a hardcoded
 * kaomoji plus @string/search_no_results) and the searchResults RecyclerView, shown MUTUALLY
 * EXCLUSIVELY by setEmptyViewShown(). The row is settings_preferencesearch_list_item_result.xml and
 * lives in components/PreferenceSearchAdapter.ets (comp_preference_search_adapter).
 *
 * NOT reached by navigation from a preference row: SettingsActivity ADDS this fragment over
 * settings_fragment_holder when the toolbar search is activated, and the query text comes from the
 * ACTIVITY's toolbar EditText via updateSearchResults(String) - this screen owns NO search field and
 * NO toolbar of its own, which is why nothing here draws one. The single navOut edge is kind `pop`
 * back to screen_settings_activity through the HOST's toolbar home control.
 *
 * setEmptyViewShown(shown) is the source's one flag, and it is only ever called from
 * updateSearchResults - so before the first search NEITHER view is swapped: the (empty) result list
 * is what renders, exactly as android:visibility="gone" on empty_state_view says. That is why the
 * branch below is on the FLAG the source keeps, not on `results.length === 0` directly.
 *
 * Both halves S4 first reported blocked are now wired:
 *  1. common/settings/PreferenceSearcher.ts is the port of PreferenceSearcher / the fuzzy search
 *     function / PreferenceParser's index, so `searcher.searchFor(keyword)` is a real call;
 *  2. the keyword comes from the HOST's toolbar - SettingsActivity calls
 *     searchFragment.updateSearchResults(searchText) - so `searchText` is an @Prop the host feeds
 *     and @Watch runs the search on every change, which is what the host's 200 ms debounce feeds.
 *
 * setEmptyViewShown()'s real condition (results.isEmpty(), only after a search has run - before the
 * first one NEITHER view is swapped) and the row click are wired the same way as the source: the
 * click goes UP to the ACTIVITY (onSearchResultClicked resolves the owning settings screen through
 * SettingsResourceRegistry and highlights the preference there), so the page only reports which
 * result was picked.
 *
 * The kaomoji is reproduced verbatim from the layout; it is static chrome, not captured content.
 * S5/S6 styling: the 4dp ?attr/toolbar_shadow strip, the 35sp monospace kaomoji and the 24sp
 * label.
 */
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PreferenceSearchAdapter, PreferenceSearchDataSource }
  from '../components/PreferenceSearchAdapter';
import { PreferenceSearchItem } from '../model/app/PreferenceSearchItem';
import { AppPreferences, PrefValue } from '../common/prefs/Preferences';
import { buildPreferenceSearcher, PreferenceSearcher } from '../common/settings/PreferenceSearcher';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

const TAG: string = 'PreferenceSearchFragmentPage';

/* S5 - style only, LightSettingsTheme. This fragment draws NO toolbar: the capture's red bar and
 * its search field belong to SettingsActivity, which hosts this page. What IS this fragment's own
 * is settings_preferencesearch_fragment.xml, and every value below is taken from it - the
 * ?android:attr/windowBackground surface, and the empty state's 35sp monospace kaomoji 10dp above
 * a 24sp label, both centred. base.png renders the result list with ZERO rows (no query was
 * typed), so nothing here is measured off pixels. */
/** ?android:attr/windowBackground - light_background_color, the capture's #EEEEEE. */
const COLOR_SURFACE: Resource = $r('app.color.background');
/** ?android:textColorPrimary in the light theme. */
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');
/**
 * ?attr/toolbar_shadow = @drawable/toolbar_shadow_light, a shape gradient with
 * android:angle="-90" (top to bottom) from @color/light_shadow_start_color to fully transparent.
 */
const COLOR_SHADOW_START: Resource = $r('app.color.shadow_start');
const COLOR_SHADOW_END: string = '#00000000';

@Entry
@Component
export struct PreferenceSearchFragmentPage {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  /**
   * SettingsActivity.onSearchChanged() -> searchFragment.updateSearchResults(searchText): the
   * keyword is the HOST's toolbar text, already through its 200 ms debounce.
   */
  @Prop @Watch('onSearchTextChanged') searchText: string = '';
  /**
   * onItemClicked(item) casts the activity to PreferenceSearchResultListener and calls
   * onSearchResultClicked(item) - the registry lookup, the fragment swap and the highlight are all
   * host-side, so the page only reports WHICH result was picked.
   */
  onResultPicked: (item: PreferenceSearchItem) => void = (item: PreferenceSearchItem): void => {
    hilog.debug(0x0000, TAG, 'onSearchResultClicked not bound (%{public}s)', item.key);
  };

  /**
   * searcher.searchFor(keyword)'s result list, submitted to the adapter - the plan's
   * `@State resultsList:` under its other name. The three remaining spec'd state vars are
   * per-ROW, not page state, and are realised where the source puts them, in the row binder
   * (components/PreferenceSearchAdapter.ets): `@State summary:` is
   * `binding.summary` (GONE when item.getSummary().isEmpty()) and `@State breadcrumbs:` is
   * `binding.breadcrumbs` (GONE when item.getBreadcrumbs().isEmpty()).
   */
  @State results: PreferenceSearchItem[] = [];
  /**
   * setEmptyViewShown() is only ever called from updateSearchResults, so before the first search
   * NEITHER view is swapped and the (empty) result list is what renders - which is why the empty
   * state is gated on this as well as on results.isEmpty().
   */
  @State searchPerformed: boolean = false;
  @State isLoading: boolean = false;
  @State errorInfo: string = '';

  private dataSource: PreferenceSearchDataSource = new PreferenceSearchDataSource();
  /** searchFragment.setSearcher(searcher) - SettingsActivity.initSearch() builds it once. */
  private searcher: PreferenceSearcher | null = null;

  /**
   * initSearch(): the configuration, the parsed index and the searcher are built once, before any
   * keyword arrives. Only the string-ARRAY lookup needs a context (svc_localization owns the rest).
   */
  aboutToAppear(): void {
    this.isLoading = true;
    try {
      const context: common.Context = getContext(this) as common.Context;
      this.searcher = buildPreferenceSearcher(this.readPreferenceValues(),
        (name: string): string[] => {
          return context.resourceManager.getStringArrayByNameSync(name);
        });
      this.errorInfo = '';
    } catch (err) {
      const failure: Error = err as Error;
      this.errorInfo = failure.message;
      hilog.error(0x0000, TAG, 'settings search index unavailable: %{public}s', failure.message);
    }
    this.isLoading = false;
  }

  /**
   * `new PreferenceParser(searchContext, config)`:
   * PreferenceManager.getDefaultSharedPreferences(context).getAll(), the snapshot whose values get
   * substituted into a summary carrying a format specifier. A store that will not open costs only
   * that substitution, so the search is still built.
   */
  private readPreferenceValues(): Map<string, PrefValue> {
    try {
      return AppPreferences.instance().getAll();
    } catch (err) {
      const failure: Error = err as Error;
      hilog.warn(0x0000, TAG, 'preference values unavailable: %{public}s', failure.message);
      return new Map<string, PrefValue>();
    }
  }

  /**
   * onItemClicked(item): the fragment casts the host activity to PreferenceSearchResultListener and
   * calls onSearchResultClicked(item). Both the registry lookup and the highlight are host-side.
   */
  private onItemClicked(index: number): void {
    if (index < 0 || index >= this.results.length) {
      return;
    }
    const item: PreferenceSearchItem = this.results[index];
    hilog.info(0x0000, TAG, 'onSearchResultClicked(%{public}s) on %{public}s', item.key,
      item.searchIndexItemResId);
    this.onResultPicked(item);
  }

  /** RxTextView's debounced text, handed straight to updateSearchResults. */
  private onSearchTextChanged(): void {
    this.updateSearchResults(this.searchText);
  }

  /**
   * updateSearchResults(keyword): `if (adapter == null || searcher == null) return;` then
   * adapter.submitList(searcher.searchFor(keyword)) and setEmptyViewShown(results.isEmpty()).
   */
  updateSearchResults(keyword: string): void {
    const searcher: PreferenceSearcher | null = this.searcher;
    if (searcher === null) {
      return;
    }
    const results: PreferenceSearchItem[] = searcher.searchFor(keyword);
    this.results = results;
    this.dataSource.submitList(results);
    this.searchPerformed = true;
  }

  build() {
    Column() {
      // The layout's first child: a 4dp ?attr/toolbar_shadow strip closing the host toolbar off
      // from the results. Purely decorative - no id, no handler, no bound value - so it is not a
      // control and adds nothing to this screen's contract.
      Column()
        .width('100%')
        .height(4)
        .linearGradient({
          angle: 180,
          colors: [[COLOR_SHADOW_START, 0.0], [COLOR_SHADOW_END, 1.0]]
        })

      // One of the two, never both: setEmptyViewShown(shown) sets the other GONE.
      if (this.emptyStateVisible()) {
        // empty_state_view: the layout's own hardcoded kaomoji over @string/search_no_results.
        Column() {
          // android:fontFamily="monospace", android:textSize="35sp", 10dp above the label.
          Text('╰(°●°╰)')
            .fontSize(35)
            .fontFamily('monospace')
            .fontColor(COLOR_ON_SURFACE)
            .margin({ bottom: 10 })
          Text($r('app.string.search_no_results'))
            .fontSize(24)
            .fontColor(COLOR_ON_SURFACE)
        }
        .id('empty_state_view')
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else {
        // searchResults: the RecyclerView with its LinearLayoutManager.
        Column() {
          PreferenceSearchAdapter({
            dataSource: this.dataSource,
            onItemClicked: (index: number): void => {
              this.onItemClicked(index);
            }
          })
        }
        .id('searchResults')
        .width('100%')
        .layoutWeight(1)
      }
    }
    .id('PreferenceSearchFragmentPage')
    .width('100%')
    .height('100%')
    .backgroundColor(themedBackground(this.blackTheme))
  }

  /**
   * setEmptyViewShown(results.isEmpty()). The flag is only ever set from updateSearchResults, so
   * before the first search the empty state stays GONE (its XML visibility) and the empty list
   * renders instead.
   */
  private emptyStateVisible(): boolean {
    if (!this.searchPerformed) {
      return false;
    }
    if (this.results.length === 0) {
      return true;
    }
    return false;
  }
}
