/*
 * S3 - AboutScreen (screen_about_screen), the shared Compose About screen
 * (shared/.../screen/about/AboutScreen.kt), hosted by ComposeActivity.
 *
 * STRUCTURE from AboutScreenContent(): a Scaffold whose topBar is the SHARED TopAppBar
 * (title = title_activity_about, onNavigateUp = navigator.navigateUp()), over a Column of a
 * SecondaryTabRow and a HorizontalPager. `pages` is Page.entries - [ABOUT, LICENSE] - so both the
 * tab strip and the pager are driven by that one list, and `onPageContent` maps
 * Page.ABOUT -> AboutPage() and Page.LICENSE -> LicensePage().
 *
 * Both tabs carry the SAME testTag("about_tab_itemroot"): a repeated row root, so Rule 12's
 * list-row exception applies and the replay resolves them by index.
 *
 * S3 MOUNTS the two pager children - AboutPage.ets and LicensePage.ets already exist and were
 * only waiting for a host. Neither is rewritten here.
 *
 * The tab strip's colours come from the SELECTED SERVICE's scheme (currentServiceScheme()), so
 * the About screen changes colour with the drawer's service switcher - that is S5's job, not
 * this pass's.
 */
import { router } from '@kit.ArkUI';

import { AppPreferences } from '../common/prefs/Preferences';
import { current_service_key } from '../common/prefs/SettingsKeys';
import { TopAppBar } from '../components/TopAppBar';
import { AboutPage } from './AboutPage';
import { LicensePage } from './LicensePage';
import { servicePrimaryColor } from '../common/theme/ServiceTheme';

/** Page.entries, in order: the tab titles AND the pager pages come from this one list. */
const PAGE_TITLES: Resource[] = [$r('app.string.tab_about'), $r('app.string.tab_licenses')];

/** currentService()'s default - Service.YOUTUBE.serviceName. */
const DEFAULT_SERVICE_NAME: string = 'YouTube';

@Entry
@Component
export struct AboutScreenPage {
  /** ?attr/colorPrimary follows the service the drawer selected; see servicePrimaryColor(). */
  @StorageProp('mainSelectedServiceId') activeServiceId: number = 0;

  /** pages.fastForEachIndexed { Tab(text = { Text(stringResource(page.localizedTitle)) }) }. */
  @State tabTitles: Resource[] = PAGE_TITLES;
  /**
   * currentServiceScheme(): the tab row's containerColor and its indicator colour both come from
   * the SELECTED streaming service's scheme, which is why the About screen changes colour with
   * the drawer's service switcher. This holds the service that scheme belongs to - the binding;
   * S5 maps it to the actual colours.
   */
  @State tabAndIndicatorColours: string = DEFAULT_SERVICE_NAME;
  /** stringResource(Res.string.title_activity_about). */
  @State screenTitle: Resource = $r('app.string.title_activity_about');
  /** pagerState.currentPage: 0 = Page.ABOUT, 1 = Page.LICENSE. */
  @State currentPage: number = 0;

  /** rememberPagerState { pages.size } - animateScrollToPage() drives it from a tab tap. */
  private pagerController: SwiperController = new SwiperController();

  aboutToAppear(): void {
    this.tabAndIndicatorColours = AboutScreenPage.currentServiceName();
  }

  /** currentService(): the preference holds the service NAME, YouTube when it matches nothing. */
  private static currentServiceName(): string {
    try {
      return AppPreferences.instance().getStringSync(current_service_key, DEFAULT_SERVICE_NAME);
    } catch (err) {
      return DEFAULT_SERVICE_NAME;
    }
  }

  /** onNavigateUp = { navigator.navigateUp() }; an empty back stack finishes ComposeActivity. */
  private onNavigateUp(): void {
    router.back();
  }

  /** Tab(onClick = { coroutineScope.launch { pagerState.animateScrollToPage(index) } }). */
  private selectPage(index: number): void {
    if (index === this.currentPage) {
      return;
    }
    this.currentPage = index;
    this.pagerController.changeIndex(index, true);
  }

  build() {
    Column() {
      // Scaffold(topBar = { TopAppBar(title = ..., onNavigateUp = ...) }).
      TopAppBar({
        title: this.screenTitle,
        hasTitle: true,
        hasNavigateUp: true,
        onNavigateUp: (): void => {
          this.onNavigateUp();
        }
      })

      // SecondaryTabRow: one Tab per Page, both tagged about_tab_itemroot.
      // S0001/S0003: the tab strip carries the bar's own colour, so both tabs sit on
      // color.primary with white labels and a white indicator under the selected one.
      Row() {
        ForEach(this.tabTitles, (title: Resource, index: number) => {
          Column() {
            Text(title)
              .textAlign(TextAlign.Center)
              .width('100%')
              .layoutWeight(1)
              .align(Alignment.Center)
              .fontSize(16)
              .fontColor($r('app.color.white'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })

            // SecondaryTabRow's indicator exists under the SELECTED tab only, and moves with
            // pagerState.currentPage.
            if (index === this.currentPage) {
              Divider()
                .id('about_tab_indicator')
                .width('100%')
                .strokeWidth(3)
                .color($r('app.color.white'))
            }
          }
          .id('about_tab_itemroot')
          .layoutWeight(1)
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .onClick(() => {
            this.selectPage(index);
          })
        }, (title: Resource, index: number) => `${index}`)
      }
      .width('100%')
      .height(48)
      .alignItems(VerticalAlign.Center)
      // ?attr/colorPrimary follows the service the drawer selected, and the toolbar above this
      // strip already does (TopAppBar.ets:90). Hardcoding app.color.primary left the strip
      // YouTube-red under a grey media.ccc.de or blue SoundCloud bar - T-0188.
      .backgroundColor(servicePrimaryColor(this.activeServiceId))

      // HorizontalPager(state = pagerState) { onPageContent(pages[page]) }.
      Column() {
        Swiper(this.pagerController) {
          AboutPage()
          LicensePage()
        }
        .index(this.currentPage)
        .loop(false)
        .indicator(false)
        .width('100%')
        .height('100%')
        .onChange((index: number) => {
          this.currentPage = index;
        })
      }
      .id('about_pager')
      .width('100%')
      .layoutWeight(1)
      // This screen keeps its own Material3 surface, not the app-wide grey: S0001/S0003 both
      // sample #FFF8F7 behind the pager content.
      .backgroundColor($r('app.color.about_surface_color'))
    }
    .id('AboutScreenPage')
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.about_surface_color'))
  }
}
