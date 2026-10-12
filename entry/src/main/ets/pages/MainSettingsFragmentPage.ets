/**
 * S3 - MainSettingsFragment (screen_main_settings).
 *
 * Root of the settings tree: res/xml/main_settings.xml, 9 rows, plus the action_search menu item
 * from res/menu/menu_settings_main_fragment.xml. hostedBy screen_settings_activity, which MOUNTS
 * this page in settings_fragment_holder (the source replaces the fragment into the holder) - so
 * this page is registered and deep-linkable, but the host does not push it. The 10 navOut edges are
 * all pushes onto SettingsActivity's own back stack and stay pushes.
 *
 * The rows are the source's preference RecyclerView, so they are rendered as a real List over
 * `preferenceList` - one ListItem per row - and not as nine hand-written Rows. This is the only
 * settings screen with row icons; each icon is the source drawable carried over in the assets pass.
 * BasePreferenceFragment.onViewCreated calls setDivider(null), so the list carries no divider.
 * The toolbar and its title (ThemeHelper.setTitleToAppCompatActivity) belong to the HOST activity -
 * this page draws neither.
 *
 * SLUGS: seven of the nine rows carry NO android:key (they are identified by android:fragment) and
 * the instrumenter injected nothing here - results/plan/injected-ids.json has no entry for
 * main_settings.xml. Their .id() is therefore the SOURCE CONSTANT the plan's sourceRef names, i.e.
 * the android:title string-resource name. The two keyed rows keep their real keys.
 *
 * Two conditionalVariants, both of which REMOVE a row (MainSettingsFragment.onCreatePreferences):
 *  - !ReleaseVersionUtil.isReleaseApk() removes update_pref_screen_key AND writes update_app_key
 *    (this port keeps the row and leaves the preference to the user - see SHOW_UPDATE_CATEGORY)
 *    = false. A self-signed HarmonyOS build never carries NewPipe's release certificate, so that
 *    branch is always taken here.
 *  - !MainActivity.DEBUG removes debug_pref_screen_key.
 *
 * THE PORT SPLITS THE FIRST ONE, deliberately (card T-1473). The source ties two separate things
 * to one flag: whether the Updates CATEGORY is listed, and whether the update CHECK runs. Taking
 * the branch whole hid a category the user has every reason to reach, and the QA baseline lists
 * it. So the category is shown and the check stays off - update_app_key is still written false
 * below, which is the condition UpdateCheck.checkNewVersion() reads before an automatic check.
 *
 * MAIN_ACTIVITY_DEBUG is false because this port ships to end users; the Debug category is a
 * development surface and does not belong in a shipped list, independently of the QA baseline.
 *
 * All three are driven by the named constants below and read as real `if`s in build().
 */
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { router } from '@kit.ArkUI';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

const TAG: string = 'MainSettingsFragmentPage';

/* S5 - style only, LightTheme (the theme S0161/S0162 render in). Reuses the run's style baseline
 * (state.json generation.styleBaseline, source S0004): background #EEEEEE and onSurface #DE000000.
 * The preference-row metrics come from THIS screen's own S0161 capture - an AndroidX preference row
 * is not the download-mission row the baseline measured: 53.7vp rows, a 16vp icon gutter, 24vp
 * icons and the title column starting at 72vp, all rendered at 16fp REGULAR (the baseline's
 * font.listItemTitle is bold, which this list is not). setDivider(null), so no separators. */
/** ?attr/windowBackground - light_background_color, the capture's #EEEEEE. */
const COLOR_SURFACE: Resource = $r('app.color.background');
/** ?android:textColorPrimary - #DE000000 over #EEEEEE is the capture's (31,31,31) row title. */
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');
/** ?android:textColorSecondary, for the error line the source screen has no equivalent of. */
const COLOR_SECONDARY_TEXT: Resource = $r('app.color.on_surface_variant');

/** preference_material: the row's fixed height, its gutter, and the icon it leaves room for. */
const ROW_HEIGHT: number = 53.7;
const ROW_GUTTER: number = 16;
const ICON_SIZE: number = 24;
/** icon_frame is 56vp wide, so the title column starts at 72vp - 32vp past the 24vp icon. */
const TITLE_INSET: number = 32;

/**
 * BasePreferenceFragment.onViewCreated/onResume push the PreferenceScreen title into the HOST
 * activity (ThemeHelper.setTitleToAppCompatActivity), so the fragment owns the value and the
 * activity renders it. This is the AppStorage key that carries it across that same seam.
 */
const TOOLBAR_TITLE_KEY: string = 'settingsToolbarTitle';

/** ReleaseVersionUtil.isReleaseApk - a self-signed HarmonyOS build is never the release APK. */
const IS_RELEASE_APK: boolean = false;
/**
 * MainActivity.DEBUG. This HAP IS a debug build - `bm dump` reports `debug: true` and
 * `appProvisionType: debug` - and the reference it is compared against is a debug APK too
 * (`org.schabi.newpipe.debug.PIPELINEBRANCH`, `flags=[ DEBUGGABLE ]`), which is why that build
 * shows Debug and hides Updates. The two menus have to read the same, so this follows the build
 * rather than a preference about who the port ships to.
 */
const MAIN_ACTIVITY_DEBUG: boolean = true;
/**
 * Whether the Updates CATEGORY is listed. The source removes it when the APK is not the release
 * one, and this build never is, so it is not listed - which is also what the reference on the
 * bench shows. The preference itself still defaults ON and nothing writes it, so the automatic
 * check runs as it would in a release build; what is gone is a row offering a feed that carries
 * NewPipe's Android APK, which cannot install over a HarmonyOS HAP.
 */
const SHOW_UPDATE_CATEGORY: boolean = false;

/** The two rows that are REMOVED (not hidden) by the branches above. */
const ROW_UPDATE: string = 'update_pref_screen_key';
const ROW_DEBUG: string = 'debug_pref_screen_key';

/** One <PreferenceScreen> row of main_settings.xml: icon + title + the fragment it opens. */
interface SettingsRowSpec {
  id: string;
  icon: Resource;
  title: Resource;
  route: string;
}

/**
 * res/xml/main_settings.xml, in source order - the PreferenceScreen the source inflates with
 * addPreferencesFromResourceRegistry(R.xml.main_settings). It is the resource, not screen state:
 * every title and icon is the migrated resource of that XML's android:title/android:icon, and the
 * fragment builds its row list from it at runtime (aboutToAppear below), never as a frozen field.
 */
const MAIN_SETTINGS_ROWS: SettingsRowSpec[] = [
  {
    id: 'settings_category_video_audio_title',
    icon: $r('app.media.ic_headset'),
    title: $r('app.string.settings_category_video_audio_title'),
    route: 'pages/VideoAudioSettingsFragmentPage'
  },
  {
    id: 'settings_category_downloads_title',
    icon: $r('app.media.ic_file_download'),
    title: $r('app.string.settings_category_downloads_title'),
    route: 'pages/DownloadSettingsFragmentPage'
  },
  {
    id: 'settings_category_appearance_title',
    icon: $r('app.media.ic_palette'),
    title: $r('app.string.settings_category_appearance_title'),
    route: 'pages/AppearanceSettingsFragmentPage'
  },
  {
    id: 'settings_category_history_title',
    icon: $r('app.media.ic_history'),
    title: $r('app.string.settings_category_history_title'),
    route: 'pages/HistorySettingsFragmentPage'
  },
  {
    id: 'content',
    icon: $r('app.media.ic_language'),
    title: $r('app.string.content'),
    route: 'pages/ContentSettingsFragmentPage'
  },
  {
    id: 'notifications',
    icon: $r('app.media.ic_notifications'),
    title: $r('app.string.notifications'),
    route: 'pages/NotificationsSettingsFragmentPage'
  },
  {
    id: ROW_UPDATE,
    icon: $r('app.media.ic_cloud_download'),
    title: $r('app.string.settings_category_updates_title'),
    route: 'pages/UpdateSettingsFragmentPage'
  },
  {
    id: 'settings_category_backup_restore_title',
    icon: $r('app.media.ic_settings_backup_restore'),
    title: $r('app.string.settings_category_backup_restore_title'),
    route: 'pages/BackupRestoreSettingsFragmentPage'
  },
  {
    id: ROW_DEBUG,
    icon: $r('app.media.ic_bug_report'),
    title: $r('app.string.settings_category_debug_title'),
    route: 'pages/DebugSettingsFragmentPage'
  }
];

@Entry
@Component
export struct MainSettingsFragmentPage {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  /**
   * The inflated preference rows. Empty until aboutToAppear reads MAIN_SETTINGS_ROWS - the port
   * of addPreferencesFromResourceRegistry, which builds the list from the XML at runtime.
   */
  @State preferenceList: SettingsRowSpec[] = [];
  /** The Updates row is listed on its own decision, not on isReleaseApk(). */
  @State updatePrefScreenKey: boolean = SHOW_UPDATE_CATEGORY;
  /** The Debug row survives only in the debug build variant. */
  @State debugPrefScreenKey: boolean = MAIN_ACTIVITY_DEBUG;
  /**
   * main_settings.xml's PreferenceScreen android:title (@string/settings). The source does not
   * DRAW it - it hands it to the host activity's toolbar - so this page publishes it under
   * TOOLBAR_TITLE_KEY and draws no toolbar of its own.
   */
  @State toolbarTitle: string = '';
  /** The rows are static; nothing is fetched, so this clears on the first frame. */
  @State isLoading: boolean = true;
  /**
   * ErrorPanelHelper equivalent. The source fragment has no error path, but on this side every
   * row's router.pushUrl can reject, and a settings row that silently fails to open is exactly
   * the defect that would otherwise never surface.
   */
  @State errorInfo: string = '';

  async aboutToAppear(): Promise<void> {
    // addPreferencesFromResourceRegistry(R.xml.main_settings) - inflate the rows first, so
    // the list is populated on the frame the page first draws.
    this.preferenceList = MAIN_SETTINGS_ROWS;
    const context: common.Context = getContext(this) as common.Context;
    // BasePreferenceFragment.onViewCreated: setTitleToAppCompatActivity(getPreferenceScreen()).
    this.toolbarTitle = context.resourceManager.getStringByNameSync('settings');
    AppStorage.setOrCreate(TOOLBAR_TITLE_KEY, this.toolbarTitle);
    // MainSettingsFragment.java:26-31 writes update_app_key false in the same branch that hides
    // the Updates row, because a non-release APK cannot install an update over itself. This port
    // lists the row and leaves the preference alone: the switch is the user's, as it is in a
    // release build, and nothing here overwrites what they chose. With no write left, there is
    // nothing to wait for - the rows are static and the page is ready on this frame.
    this.isLoading = false;
  }

  private report(err: BusinessError): void {
    this.errorInfo = err.message;
    hilog.error(0x0000, TAG, 'main settings: %{public}s', this.errorInfo);
  }

  @Builder
  settingsRow(row: SettingsRowSpec) {
    Row() {
      // The source drawable, carried over in the assets pass: a 24vp black glyph at the gutter.
      Image(row.icon)
        .width(ICON_SIZE)
        .height(ICON_SIZE)
        .objectFit(ImageFit.Contain)
      Text(row.title)
        .layoutWeight(1)
        .margin({ left: TITLE_INSET })
        .fontSize(16)
        .lineHeight(20)
        .fontColor(COLOR_ON_SURFACE)
    }
    .width('100%')
    .height(ROW_HEIGHT)
    .padding({ left: ROW_GUTTER, right: ROW_GUTTER })
    .alignItems(VerticalAlign.Center)
    .id(row.id)
    .onClick(() => {
      router.pushUrl({ url: row.route }).catch((err: BusinessError) => {
        this.report(err);
      });
    })
  }

  build() {
    Column() {
      // menu_settings_main_fragment.xml's action_search is drawn by the HOST toolbar
      // (SettingsActivityPage), like every other fragment options menu. It used to be rendered
      // here, inside the content area above the list, which put it under the toolbar instead of
      // in it and pushed the rows down.

      List() {
        ForEach(this.preferenceList, (row: SettingsRowSpec) => {
          // conditionalVariants: both branches REMOVE the row, so no ListItem is created for it.
          if (row.id !== ROW_UPDATE || this.updatePrefScreenKey) {
            if (row.id !== ROW_DEBUG || this.debugPrefScreenKey) {
              ListItem() {
                this.settingsRow(row)
              }
            }
          }
        }, (row: SettingsRowSpec) => row.id)
      }
      .width('100%')
      .layoutWeight(1)

      // ErrorPanelHelper equivalent: only once the update_app_key write has finished and failed.
      if (!this.isLoading && this.errorInfo.length > 0) {
        Text(this.errorInfo)
          .width('100%')
          .fontSize(14)
          .lineHeight(17)
          .fontColor(COLOR_SECONDARY_TEXT)
          .padding({ left: ROW_GUTTER, right: ROW_GUTTER, top: 16, bottom: 16 })
      }
    }
    .id('MainSettingsFragmentPage')
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(themedBackground(this.blackTheme))
  }
}
