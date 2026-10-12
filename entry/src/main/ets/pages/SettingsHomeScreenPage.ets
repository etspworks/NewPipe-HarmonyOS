/**
 * S3 — SettingsHomeScreen (screen_settings_home), structure from SettingsHomeScreen.kt +
 * PreferenceRow.kt + TopAppBar.kt + SettingsViewModel.kt.
 *
 * The in-flight Compose replacement for MainSettingsFragment: a Scaffold whose topBar is the
 * shared TopAppBar (navigate-up + a search action) over a LazyColumn of PreferenceRow, one per
 * visible SettingsCategoryType.
 *
 * NEVER CAPTURED — NavigationHelper.openSettings() still starts the legacy SettingsActivity, so
 * ComposeActivity only ever receives Destination.About. Everything here comes from the source.
 *
 * DELIBERATELY INERT: SettingsHomeScreen builds every SettingsCategory with `onClick = {}` and a
 * TODO, and passes NO onSearchClick, so that parameter keeps its default no-op. The rows and the
 * search action render and do nothing. That is the source's behaviour, not a defect to fix — S4
 * must not invent a destination for them.
 *
 * hostedBy screen_compose_activity: ComposeActivityPage already MOUNTS this struct in its
 * NavDisplay entry slot, so this page never instantiates NavDisplay itself — the destination ->
 * screen mapping is the host's containment, exactly as NavDisplay.ets documents.
 *
 * The bar is the SHARED components/TopAppBar.ets (comp_top_app_bar_compose), the same
 * composable the source imports here, carrying the source's own `topbar_navigate_up` slug; the
 * `settings_search` action is this screen's, passed into the bar's actions slot.
 *
 * S5 — styled from the SOURCE (never captured): Material3 ListItem metrics for the rows and
 * the app's own window background. The shared TopAppBar belongs to another screen and is
 * not restyled here.
 */
import { router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { bundleManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

import {
  SettingsCategoryType,
  SettingsCategoryResource,
  SETTINGS_CATEGORY_RESOURCES
} from '../model/enums/SettingsCategoryType';
import { PreferenceRow } from '../components/PreferenceRow';
import { TopAppBar } from '../components/TopAppBar';
import { Localization } from '../common/i18n/Localization';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

/* Icon(painter = painterResource(category.icon)): a Material3 24dp leading icon. */
const ICON_SIZE: number = 24;

@Entry
@Component
export struct SettingsHomeScreenPage {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  /** viewModel.categories.collectAsStateWithLifecycle() — SettingsViewModel.computeVisible(). */
  @State categoryList: SettingsCategoryResource[] = [];
  /** stringResource(Res.string.settings). */
  @State screenTitle: string = '';
  /** BuildInfo.isReleaseApk — computeVisible KEEPS the UPDATES row only on a release build. */
  @State isReleaseApk: boolean = false;
  /** BuildInfo.isDebug — computeVisible KEEPS the DEBUG row only on a debug build. */
  @State isDebug: boolean = false;
  /** computeVisible() is a pure function over the build info; nothing here awaits a service. */
  @State isLoading: boolean = false;
  /** SettingsHomeScreen has no error path of its own — the categories cannot fail to compute. */
  @State errorInfo: string | null = null;

  aboutToAppear(): void {
    this.isLoading = true;
    // The category SET is data (SettingsCategoryType.entries), never a literal list in the view.
    this.categoryList = SETTINGS_CATEGORY_RESOURCES;
    this.screenTitle = Localization.getString('settings');
    this.readBuildInfo();
    this.isLoading = false;
  }

  /**
   * SettingsViewModel(buildInfo): the source injects BuildInfo, whose isDebug is the build type
   * and whose isReleaseApk is ReleaseVersionUtil's signing-certificate check. The bundle's own
   * application info is the equivalent here; a build that is not a debug build is the release
   * one, which is what gates the UPDATES row.
   */
  private readBuildInfo(): void {
    try {
      const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      this.isDebug = info.appInfo.debug;
      this.isReleaseApk = !info.appInfo.debug;
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      hilog.warn(0x0000, 'SettingsHomeScreenPage', 'build info unreadable: %{public}s',
        failure.message);
    }
  }

  /** onNavigateUp = { navigator.navigateUp() } — pops the Compose back stack. */
  private onNavigateUp(): void {
    router.back();
  }

  /**
   * Icon(painter = painterResource(category.icon)). The migrated model carries the resource NAME,
   * and $r() needs a literal, so the mapping is this switch — one branch per SettingsCategoryType,
   * in SETTINGS_CATEGORY_RESOURCES order.
   */
  @Builder
  categoryIcon(type: SettingsCategoryType) {
    if (type === SettingsCategoryType.VIDEO_AUDIO) {
      Image($r('app.media.ic_headset'))
        .width(ICON_SIZE)
        .height(ICON_SIZE)
        .objectFit(ImageFit.Contain)
        .fillColor($r('app.color.defaultIconTint'))
    } else if (type === SettingsCategoryType.DOWNLOADS) {
      Image($r('app.media.ic_file_download'))
        .width(ICON_SIZE)
        .height(ICON_SIZE)
        .objectFit(ImageFit.Contain)
        .fillColor($r('app.color.defaultIconTint'))
    } else if (type === SettingsCategoryType.APPEARANCE) {
      Image($r('app.media.ic_palette'))
        .width(ICON_SIZE)
        .height(ICON_SIZE)
        .objectFit(ImageFit.Contain)
        .fillColor($r('app.color.defaultIconTint'))
    } else if (type === SettingsCategoryType.HISTORY) {
      Image($r('app.media.ic_history'))
        .width(ICON_SIZE)
        .height(ICON_SIZE)
        .objectFit(ImageFit.Contain)
        .fillColor($r('app.color.defaultIconTint'))
    } else if (type === SettingsCategoryType.CONTENT) {
      Image($r('app.media.ic_language'))
        .width(ICON_SIZE)
        .height(ICON_SIZE)
        .objectFit(ImageFit.Contain)
        .fillColor($r('app.color.defaultIconTint'))
    } else if (type === SettingsCategoryType.NOTIFICATIONS) {
      Image($r('app.media.ic_notifications'))
        .width(ICON_SIZE)
        .height(ICON_SIZE)
        .objectFit(ImageFit.Contain)
        .fillColor($r('app.color.defaultIconTint'))
    } else if (type === SettingsCategoryType.UPDATES) {
      Image($r('app.media.ic_cloud_download'))
        .width(ICON_SIZE)
        .height(ICON_SIZE)
        .objectFit(ImageFit.Contain)
        .fillColor($r('app.color.defaultIconTint'))
    } else if (type === SettingsCategoryType.BACKUP_RESTORE) {
      Image($r('app.media.ic_settings_backup_restore'))
        .width(ICON_SIZE)
        .height(ICON_SIZE)
        .objectFit(ImageFit.Contain)
        .fillColor($r('app.color.defaultIconTint'))
    } else {
      Image($r('app.media.ic_bug_report'))
        .width(ICON_SIZE)
        .height(ICON_SIZE)
        .objectFit(ImageFit.Contain)
        .fillColor($r('app.color.defaultIconTint'))
    }
  }

  /**
   * items(items = categories) { PreferenceRow(...) }, with computeVisible()'s two filters kept
   * as real conditions: UPDATES survives only on a release build, DEBUG only on a debug build.
   */
  @Builder
  categoryRow(entry: SettingsCategoryResource) {
    if (entry.type !== SettingsCategoryType.UPDATES || this.isReleaseApk) {
      if (entry.type !== SettingsCategoryType.DEBUG || this.isDebug) {
        PreferenceRow({
          // stringResource(category.title): the model carries the migrated resource NAME, and
          // $r() needs a literal, so the name is resolved through the resource manager.
          title: Localization.getString(entry.title),
          hasIcon: true,
          // An arrow keeps `this` on this page; `this.categoryIcon` would re-bind it to the row.
          leading: (): void => {
            this.categoryIcon(entry.type);
          }
          // onRowClick is deliberately NOT passed: the source's category.onClick is a TODO no-op.
        })
      }
    }
  }

  /**
   * actions = { IconButton(Modifier.testTag("settings_search"), onClick = onSearchClick) }.
   * Nothing passes onSearchClick, so it keeps its DEFAULT NO-OP - the source's own behaviour.
   */
  @Builder
  barActions() {
    Image($r('app.media.ic_search'))
      .id('settings_search')
      .width(48)
      .height(48)
      .padding(12)
      .objectFit(ImageFit.Contain)
      // The action sits IN the TopAppBar, which paints color.primary — the same white every
      // other glyph on that bar uses, not the list's dark icon tint.
      .fillColor($r('app.color.on_primary'))
      .accessibilityText('Search')
      .onClick((): void => {
        hilog.debug(0x0000, 'NewPipe', 'SettingsHomeScreen: onSearchClick is a source no-op');
      })
  }

  build() {
    Column() {
      // TopAppBar(title = stringResource(Res.string.settings), onNavigateUp, actions = { ... }):
      // the SHARED composable, so it is the shared component here too, not an inline copy.
      TopAppBar({
        title: $r('app.string.settings'),
        hasTitle: true,
        hasNavigateUp: true,
        onNavigateUp: (): void => {
          this.onNavigateUp();
        },
        // An arrow keeps `this` on this page; a bare `this.barActions` would re-bind it to the
        // TopAppBar child and kill the update function before the first frame.
        actions: (): void => {
          this.barActions();
        }
      })
      .width('100%')

      List() {
        ForEach(this.categoryList, (entry: SettingsCategoryResource) => {
          ListItem() {
            this.categoryRow(entry)
          }
        }, (entry: SettingsCategoryResource) => entry.title)
      }
      .id('settings_category_list')
      .width('100%')
      .layoutWeight(1)
      .backgroundColor(themedBackground(this.blackTheme))
    }
    .id('SettingsHomeScreenPage')
    .width('100%')
    .height('100%')
    // ?attr/windowBackground = @color/light_background_color in the light theme.
    .backgroundColor(themedBackground(this.blackTheme))
  }
}
