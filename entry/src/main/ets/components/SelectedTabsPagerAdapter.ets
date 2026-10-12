/**
 * S3 — port of MainFragment.SelectedTabsPagerAdapter (MainFragment.java:278), the
 * FragmentStatePagerAdapterMenuWorkaround behind fragment_main's `pager`.
 *
 * The source adapter holds the live tab list and answers getItem(position) with
 * `tabsList.get(position).getFragment(context)`, applying useAsFrontPage(true) to the fragment it
 * builds and falling back to `new BlankFragment(new ErrorInfo(t, GETTING_MAIN_SCREEN_TAB, ...))`
 * when getFragment throws. A Fragment cannot be held in ArkUI, so the tab -> page mapping is the
 * HOST's containment: MainFragmentPage supplies it through the `pages` builder, and this component
 * is the pager itself — in ArkUI the children ARE the adapter.
 *
 * sameTabs() stays here because it is the adapter's own identity check: setupTabs() only builds a
 * new adapter when the persisted tab set actually changed.
 *
 * S5: the pager itself has no chrome of its own — it only carries ?attr/windowBackground so a
 * page that does not paint its own background does not show through to black.
 */
import { Tab } from '../model/app/Tab';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

/**
 * Port of SelectedTabsPagerAdapter.sameTabs(List<Tab>): same length, and Tab.equals() at every
 * position. `pagerAdapter == null || !sameTabs(tabsList)` is what forces a rebuild.
 */
export function sameTabs(current: Tab[], other: Tab[]): boolean {
  if (current.length !== other.length) {
    return false;
  }
  for (let i: number = 0; i < current.length; i++) {
    if (!current[i].equalsTab(other[i])) {
      return false;
    }
  }
  return true;
}

@Component
export struct SelectedTabsPagerAdapter {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  /** getCount(): with no tabs the pager has nothing to show. */
  @Prop count: number = 0;
  /** The shown tab; shared with main_tab_layout, as setupWithViewPager wires it both ways. */
  @Link selectedIndex: number;
  /** The host's ForEach over its Tab list — getItem(position) is the host's containment. */
  @BuilderParam pages: () => void = this.noPages;

  private pagerController: SwiperController = new SwiperController();

  @Builder
  noPages() {
    Column() {
    }
  }

  build() {
    Column() {
      if (this.count > 0) {
        Swiper(this.pagerController) {
          this.pages()
        }
        .index(this.selectedIndex)
        .loop(false)
        .indicator(false)
        .width('100%')
        .height('100%')
        .onChange((index: number) => {
          this.selectedIndex = index;
        })
      }
    }
    .id('pager')
    .width('100%')
    .height('100%')
    .backgroundColor(themedBackground(this.blackTheme))
  }
}
