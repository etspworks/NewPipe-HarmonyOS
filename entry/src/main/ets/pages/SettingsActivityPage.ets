/**
 * S3 — SettingsActivity (screen_settings_activity), structure from settings_layout.xml +
 * toolbar_layout.xml + toolbar_search_layout.xml + SettingsActivity.java.
 *
 * This page is the CONTAINER, and nothing else: the activity "owns no preference list". Its two
 * structural parts are
 *   the toolbar        — the Up button plus the preference-search field, which is INCLUDED in the
 *                        toolbar with visibility=gone and toggled by setSearchActive(), never
 *                        navigated to, and
 *   settings_fragment_holder — the single fragment slot. onCreate replaces MainSettingsFragment
 *                        into it; setSearchActive(true) puts PreferenceSearchFragment over it.
 *
 * So the rows the user sees belong to screen_main_settings, which is MOUNTED here (it declares
 * hostedBy: screen_settings_activity) — this page renders none of its own.
 *
 * All 12 captured states show the collapsed toolbar, so the search field only ever appears behind
 * `wasSearchActive`; it stays in the tree because setSearchActive() is a real source branch.
 *
 * Structure only — S5 styles it from the capture.
 */
import { ComponentUtils, componentUtils, router, UIContext } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

import { MainSettingsFragmentPage } from './MainSettingsFragmentPage';
import { PreferenceSearchFragmentPage } from './PreferenceSearchFragmentPage';
import { AppearanceSettingsFragmentPage } from './AppearanceSettingsFragmentPage';
import { BackupRestoreSettingsFragmentPage } from './BackupRestoreSettingsFragmentPage';
import { ChooseTabsFragmentPage } from './ChooseTabsFragmentPage';
import { ContentSettingsFragmentPage } from './ContentSettingsFragmentPage';
import { DebugSettingsFragmentPage } from './DebugSettingsFragmentPage';
import { DownloadSettingsFragmentPage } from './DownloadSettingsFragmentPage';
import { ExoPlayerSettingsFragmentPage } from './ExoPlayerSettingsFragmentPage';
import { HistorySettingsFragmentPage } from './HistorySettingsFragmentPage';
import { NotificationModeConfigFragmentPage } from './NotificationModeConfigFragmentPage';
import { NotificationSettingsFragmentPage } from './NotificationSettingsFragmentPage';
import { NotificationsSettingsFragmentPage } from './NotificationsSettingsFragmentPage';
import { PeertubeInstanceListFragmentPage } from './PeertubeInstanceListFragmentPage';
import { PlayerNotificationSettingsFragmentPage } from './PlayerNotificationSettingsFragmentPage';
import { UpdateSettingsFragmentPage } from './UpdateSettingsFragmentPage';
import { VideoAudioSettingsFragmentPage } from './VideoAudioSettingsFragmentPage';
import { FocusOverlayView } from '../components/FocusOverlayView';

import { PreferenceSearchItem } from '../model/app/PreferenceSearchItem';
import { AppPreferences } from '../common/prefs/Preferences';
import { theme_key, default_theme_value } from '../common/prefs/SettingsKeys';
// RxTextView.textChanges(searchEditText).debounce(200, MILLISECONDS) — one restarting timer,
// disposed with the page so a pending search cannot fire onto a dead holder.
import { DebounceSaver } from '../common/util/DebounceSaver';
import { settingsListScroller } from '../common/settings/SettingsScroller';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

/* S5 — style only, LightTheme (the theme all 12 captured states render in): the toolbar band is
 * ?attr/colorPrimary = light_youtube_primary_color with ?attr/actionColor = @color/white
 * content, the fragment holder is ?attr/windowBackground = light_background_color. */
/** android:textColorHint over a colorPrimary toolbar — the dimmed half of toolbarSearchColor. */
const COLOR_TOOLBAR_HINT: string = '#B3FFFFFF';

const TAG: string = 'SettingsActivityPage';

/** RxTextView.textChanges(...).debounce(200, TimeUnit.MILLISECONDS). */
const SEARCH_DEBOUNCE: number = 200;

/** DeviceUtils.isTv(this) — UI_MODE_TYPE_TELEVISION / LEANBACK, i.e. deviceType 'tv' here. */
const TV_DEVICE_TYPE: string = 'tv';

/** onCreate(): beginTransaction().replace(settings_fragment_holder, new MainSettingsFragment()). */
const MAIN_SETTINGS_FRAGMENT: string = 'MainSettingsFragment';

/**
 * ThemeHelper.setTitleToAppCompatActivity(getActivity(), getPreferenceScreen().getTitle()) —
 * BasePreferenceFragment does this in onViewCreated AND onResume, so the ONE toolbar shows the
 * title of whichever fragment is in the holder, never a fixed "Settings". Each value is that
 * fragment's own PreferenceScreen android:title (res/xml/*.xml); the two non-preference fragments
 * set theirs by hand — ChooseTabsFragment.onResume -> R.string.main_page_content,
 * PeertubeInstanceListFragment.onResume -> R.string.peertube_instance_url_title.
 * NotificationModeConfigFragment sets no title, so it keeps its parent's (Notifications).
 */
const FRAGMENT_TITLES: Map<string, Resource> = new Map<string, Resource>([
  ['MainSettingsFragment', $r('app.string.settings')],
  ['AppearanceSettingsFragment', $r('app.string.settings_category_appearance_title')],
  ['BackupRestoreSettingsFragment', $r('app.string.settings_category_backup_restore_title')],
  ['ContentSettingsFragment', $r('app.string.content')],
  ['DebugSettingsFragment', $r('app.string.settings_category_debug_title')],
  ['DownloadSettingsFragment', $r('app.string.settings_category_downloads_title')],
  ['ExoPlayerSettingsFragment', $r('app.string.settings_category_exoplayer_title')],
  ['HistorySettingsFragment', $r('app.string.settings_category_history_title')],
  ['NotificationModeConfigFragment', $r('app.string.notifications')],
  ['NotificationSettingsFragment', $r('app.string.notifications')],
  ['NotificationsSettingsFragment', $r('app.string.notifications')],
  ['PlayerNotificationSettingsFragment', $r('app.string.settings_category_player_notification_title')],
  ['UpdateSettingsFragment', $r('app.string.settings_category_updates_title')],
  ['VideoAudioSettingsFragment', $r('app.string.settings_category_video_audio_title')],
  ['ChooseTabsFragment', $r('app.string.main_page_content')],
  ['PeertubeInstanceListFragment', $r('app.string.peertube_instance_url_title')]
]);

@Entry
@Component
export struct SettingsActivityPage {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  /** wasSearchActive — the @State the whole search half hangs off. */
  @State wasSearchActive: boolean = false;
  /** searchContainer.setVisibility(active ? View.VISIBLE : View.GONE). */
  @State toolbarSearchContainerVisibility: Visibility = Visibility.None;
  /** onSearchChanged(): the text handed to searchFragment.updateSearchResults(searchText). */
  @State searchText: string = '';
  /** DeviceUtils.isTv(this) -> FocusOverlayView.setupFocusObserver(this). */
  @State isTv: boolean = false;
  /**
   * The fragment currently REPLACED into settings_fragment_holder, by the simple class name the
   * preference's `android:fragment` names — onCreate() puts MainSettingsFragment there and
   * onPreferenceStartFragment() swaps in whichever fragment the tapped row declares.
   */
  @State settingsFragmentHolder: string = MAIN_SETTINGS_FRAGMENT;
  /** setTheme(ThemeHelper.getSettingsThemeStyle(this)) runs before the layout is inflated. */
  @State isLoading: boolean = true;
  @State errorInfo: string | null = null;
  /** PreferenceSearchResultHighlighter: the found row's rect (vp, page-local) while it flashes. */
  @State highlightRect: number[] = [];
  @State highlightOpacity: number = 0;

  /** addToBackStack(null): every showSettingsFragment() push, so Back can pop one at a time. */
  private fragmentBackStack: string[] = [];
  private searchDebounce: DebounceSaver | null = null;
  /** The text waiting on the debounce window. */
  private pendingSearchText: string = '';

  aboutToAppear(): void {
    this.searchDebounce = new DebounceSaver(SEARCH_DEBOUNCE, (): void => {
      this.onSearchChanged();
    });
    this.isTv = deviceInfo.deviceType === TV_DEVICE_TYPE;
    this.loadSettingsTheme();
    this.readArguments();
  }

  aboutToDisappear(): void {
    const debounce: DebounceSaver | null = this.searchDebounce;
    if (debounce !== null) {
      debounce.dispose();
    }
  }

  /**
   * setTheme(ThemeHelper.getSettingsThemeStyle(this)): the settings theme comes out of the
   * preference store, and a store that will not open is what the error panel reports.
   */
  private loadSettingsTheme(): void {
    this.isLoading = true;
    try {
      const theme: string = AppPreferences.instance()
        .getStringResolvedSync(theme_key, default_theme_value);
      hilog.info(0x0000, TAG, 'settings theme: %{public}s', theme);
      this.errorInfo = null;
    } catch (err) {
      const failure: Error = err as Error;
      this.errorInfo = failure.message;
      hilog.error(0x0000, TAG, 'preferences unavailable: %{public}s', failure.message);
    }
    this.isLoading = false;
  }

  /** A launch that names a settings fragment opens straight into it. */
  private readArguments(): void {
    const params: Record<string, Object> | undefined =
      router.getParams() as Record<string, Object> | undefined;
    if (params === undefined || params === null) {
      return;
    }
    const fragment: Object | undefined = params['fragment'];
    if (fragment !== undefined && fragment !== null) {
      this.showSettingsFragment(fragment.toString());
    }
  }

  /**
   * onPreferenceStartFragment(caller, preference) ->
   * showSettingsFragment(instantiateFragment(preference.getFragment())): the ACTIVITY replaces
   * the named fragment into its holder — the rows themselves belong to MainSettingsFragment.
   */
  private showSettingsFragment(fragmentName: string): void {
    // .addToBackStack(null): the fragment on screen now becomes what Back returns to.
    this.fragmentBackStack.push(this.settingsFragmentHolder);
    this.settingsFragmentHolder = fragmentName;
  }

  /**
   * The title BasePreferenceFragment hands to this activity for whatever is in the holder now.
   * A fragment with no entry keeps the root title, which is what the source's setTitle-less
   * fragments effectively show.
   */
  private currentFragmentTitle(): Resource {
    const title: Resource | undefined = FRAGMENT_TITLES.get(this.settingsFragmentHolder);
    return title === undefined ? $r('app.string.settings') : title;
  }

  /** popBackStack(): the holder goes back to the fragment underneath. */
  private popSettingsFragment(): boolean {
    const previous: string | undefined = this.fragmentBackStack.pop();
    if (previous === undefined) {
      return false;
    }
    this.settingsFragmentHolder = previous;
    return true;
  }

  /**
   * setSearchActive(active): ignored when the search is already in that state; otherwise it
   * shows/hides the toolbar's search container, adds or pops PreferenceSearchFragment over the
   * holder, moves the keyboard — and ALWAYS ends with resetSearchText().
   */
  private setSearchActive(active: boolean): void {
    if (this.wasSearchActive === active) {
      return;
    }
    this.wasSearchActive = active;
    this.toolbarSearchContainerVisibility = active ? Visibility.Visible : Visibility.None;
    if (active) {
      // .add(FRAGMENT_HOLDER_ID, searchFragment, NAME).addToBackStack(NAME) — the results are
      // ADDED over the current fragment, so leaving the search restores it.
      this.fragmentBackStack.push(this.settingsFragmentHolder);
    } else {
      // hideSearchFragment() + popBackStack(NAME, POP_BACK_STACK_INCLUSIVE).
      this.popSettingsFragment();
    }
    // resetSearchText(): searchEditText.setText("").
    this.resetSearchText();
  }

  /** resetSearchText(). */
  private resetSearchText(): void {
    this.searchText = '';
    this.pendingSearchText = '';
  }

  /**
   * onOptionsItemSelected(android.R.id.home): close the search first; otherwise pop the
   * activity's own back stack, and finish() only when that stack is empty.
   */
  private onUpPressed(): void {
    if (this.wasSearchActive) {
      this.setSearchActive(false);
      return;
    }
    if (this.popSettingsFragment()) {
      return;
    }
    // finish(): back to whichever screen pushed this one.
    router.back();
  }

  /** onBackPressed(): isSearchActive() first, then the fragment stack, then super. */
  onBackPress(): boolean {
    if (this.wasSearchActive) {
      this.setSearchActive(false);
      return true;
    }
    if (this.popSettingsFragment()) {
      return true;
    }
    // Nothing of ours left to close — let the router pop back to the pushing screen.
    return false;
  }

  /** The TextWatcher half: push the text in, debounced by 200 ms before it is searched. */
  private publishSearchText(value: string): void {
    this.pendingSearchText = value;
    const debounce: DebounceSaver | null = this.searchDebounce;
    if (debounce === null) {
      this.onSearchChanged();
      return;
    }
    debounce.setHasChangesToSave();
  }

  /**
   * onSearchChanged(): a search that is no longer active is dropped, otherwise the text is
   * stored and handed to the mounted PreferenceSearchFragment.
   */
  private onSearchChanged(): void {
    if (!this.wasSearchActive) {
      return;
    }
    this.searchText = this.pendingSearchText;
    hilog.debug(0x0000, TAG, 'updateSearchResults for the settings search');
  }

  /**
   * onSearchResultClicked(result): hide the search, then show the settings screen that owns the
   * result unless it is already the one in the holder. `searchIndexItemResId` carries that screen's
   * fragment name here (the migrated screens are ArkUI pages, not XML resources).
   *
   * Then PreferenceSearchResultHighlighter.highlight(result): the row is scrolled into view and
   * flashed. Every settings row carries its preference key as its id, so the row is found by
   * that key without a hook in each settings page.
   */
  private onSearchResultClicked(result: PreferenceSearchItem): void {
    hilog.debug(0x0000, TAG, 'onSearchResultClicked result=%{public}s', result.key);
    // Hide the search — this also pops the holder back to the fragment underneath.
    this.setSearchActive(false);
    if (this.settingsFragmentHolder !== result.searchIndexItemResId) {
      this.showSettingsFragment(result.searchIndexItemResId);
    }
    this.highlightPreference(result.key).catch((err: Error): void => {
      hilog.warn(0x0000, TAG, 'highlight: %{public}s', err.message);
    });
  }

  /**
   * highlight(): posted once the fragment is in place, then scrollToPosition(position) - the
   * settings list is paged through the shared settingsListScroller until the row (whose id is
   * its preference key) is inside the holder, nudged fully into view - and the 200 ms
   * postDelayed() before the ripple.
   */
  private async highlightPreference(key: string): Promise<void> {
    await SettingsActivityPage.sleep(150);
    const utils: ComponentUtils = this.getUIContext().getComponentUtils();
    for (let page: number = 0; page < 40; page++) {
      const holder: componentUtils.ComponentInfo =
        utils.getRectangleById('settings_fragment_holder');
      const row: componentUtils.ComponentInfo = utils.getRectangleById(key);
      const top: number = holder.windowOffset.y;
      const bottom: number = top + holder.size.height;
      if (row.size.height > 0 && row.windowOffset.y + row.size.height > top
        && row.windowOffset.y < bottom) {
        if (row.windowOffset.y + row.size.height > bottom) {
          settingsListScroller.scrollBy(0, this.getUIContext().px2vp(
            row.windowOffset.y + row.size.height - bottom));
        } else if (row.windowOffset.y < top) {
          settingsListScroller.scrollBy(0, this.getUIContext().px2vp(row.windowOffset.y - top));
        }
        await SettingsActivityPage.sleep(200);
        this.flashRow(key);
        return;
      }
      if (settingsListScroller.isAtEnd()) {
        break;
      }
      settingsListScroller.scrollPage({ next: true });
      await SettingsActivityPage.sleep(60);
    }
    hilog.warn(0x0000, TAG, 'Preference %{public}s not found on screen', key);
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, ms);
    });
  }

  /** showRippleAnimation(): the pressed state for 1000 ms, as a fading overlay on the row. */
  private flashRow(key: string): void {
    const utils: ComponentUtils = this.getUIContext().getComponentUtils();
    const row: componentUtils.ComponentInfo = utils.getRectangleById(key);
    const page: componentUtils.ComponentInfo = utils.getRectangleById('SettingsActivityPage');
    if (row.size.width <= 0 || row.size.height <= 0) {
      return;
    }
    const ui: UIContext = this.getUIContext();
    this.highlightRect = [
      ui.px2vp(row.windowOffset.x - page.windowOffset.x),
      ui.px2vp(row.windowOffset.y - page.windowOffset.y),
      ui.px2vp(row.size.width),
      ui.px2vp(row.size.height)
    ];
    this.highlightOpacity = 1;
    ui.animateTo({ duration: 1000, curve: Curve.EaseIn, onFinish: (): void => {
      this.highlightRect = [];
    } }, (): void => {
      this.highlightOpacity = 0;
    });
  }

  build() {
    Stack() {
      Column() {
        // toolbar_layout.xml: the Up button, the title, and the search field it INCLUDES.
        Row() {
          // The Up affordance: a 24dp glyph centred in the ?attr/actionBarSize touch target,
          // tinted ?attr/actionColor = @color/white by ToolbarTheme.
          Image($r('app.media.ic_arrow_back'))
            .id('home')
            .accessibilityText($r('app.string.navigate_back'))
            .width(56)
            .height(56)
            .padding(16)
            .objectFit(ImageFit.Contain)
            .fillColor($r('app.color.on_primary'))
            .onClick(() => {
              this.onUpPressed();
            })

          if (this.wasSearchActive) {
            // toolbar_search_layout.xml, visibility=gone until setSearchActive(true).
            TextInput({ text: this.searchText, placeholder: $r('app.string.search') })
              .id('toolbar_search_edit_text')
              .visibility(this.toolbarSearchContainerVisibility)
              .layoutWeight(1)
              // toolbar_search_layout: 4dp top/bottom margins, android:background="@null",
              // textColor ?attr/toolbarSearchColor = @color/white, AppCompat's default 18sp.
              .height(48)
              .margin({ top: 4, bottom: 4 })
              .padding({ left: 0, right: 0, top: 0, bottom: 0 })
              .backgroundColor(Color.Transparent)
              .borderRadius(0)
              .fontSize(18)
              .fontColor($r('app.color.on_primary'))
              .caretColor($r('app.color.on_primary'))
              .placeholderFont({ size: 18 })
              .placeholderColor(COLOR_TOOLBAR_HINT)
              .maxLines(1)
              .onChange((value: string) => {
                this.publishSearchText(value);
              })

            Row() {
              Image($r('app.media.ic_close'))
                .width(24)
                .height(24)
                .objectFit(ImageFit.Contain)
                // app:tint="?attr/toolbarSearchColor"
                .fillColor($r('app.color.on_primary'))
            }
            .id('toolbar_search_clear')
            .width(48)
            .height(48)
            .justifyContent(FlexAlign.Center)
            .alignItems(VerticalAlign.Center)
            .visibility(this.toolbarSearchContainerVisibility)
            .onClick(() => {
              // setOnClickListener(ev -> resetSearchText())
              this.resetSearchText();
            })
          } else {
            // Widget.AppCompat.Toolbar.Title: 20sp medium on ?attr/actionColor, inset 16dp
            // past the navigation button — the capture's 72dp title start.
            Text(this.currentFragmentTitle())
              .id('settings_title')
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontSize(20)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.on_primary'))
              .margin({ left: 16 })

            // menu_settings_main_fragment.xml, inflated by MainSettingsFragment. A fragment's
            // options menu is drawn by the HOST activity's toolbar, so it belongs here and not in
            // the fragment's own body, and only while that fragment is the one in the holder -
            // no other settings screen declares a menu.
            if (this.settingsFragmentHolder === MAIN_SETTINGS_FRAGMENT) {
              Row() {
                Image($r('app.media.ic_search'))
                  .width(24)
                  .height(24)
                  .objectFit(ImageFit.Contain)
                  // app:tint via ToolbarTheme's ?attr/actionColor.
                  .fillColor($r('app.color.on_primary'))
              }
              .id('action_search')
              .accessibilityText($r('app.string.search'))
              // ?attr/actionBarSize touch target, flush against the toolbar's right edge.
              .width(56)
              .height(56)
              .justifyContent(FlexAlign.Center)
              .alignItems(VerticalAlign.Center)
              .onClick(() => {
                // onOptionsItemSelected: settingsActivity.setSearchActive(true). The search field
                // is INCLUDED in this toolbar and the results fragment goes into this holder, so
                // there is nothing to navigate to.
                this.setSearchActive(true);
              })
            }
          }
        }
        .width('100%')
        // Toolbar: ?attr/actionBarSize tall on ?attr/colorPrimary.
        .height(56)
        .alignItems(VerticalAlign.Center)
        .backgroundColor($r('app.color.primary'))

        // settings_fragment_holder — ONE fragment at a time: MainSettingsFragment, or the
        // preference-search results while the search is active.
        //
        // Every screen below is ALSO a pushed route: MainSettingsFragmentPage opens them with
        // router.pushUrl, and there they are the only thing on screen and must draw their own
        // toolbar. Here the bar above is already theirs, so `hostDrawsToolbar: true` tells each
        // one to skip its own — otherwise two bars stack and the INNER Up arrow calls
        // router.back(), which pops this whole activity and drops the user outside Settings. The
        // host's own Up is onUpPressed(), which pops the holder back to the settings root.
        // The flag is PASSED, not read from AppStorage: MainSettingsFragmentPage pushes those
        // routes from inside this very page, so a host-set flag would still read true underneath
        // them and the pushed screen would draw NO bar at all. It defaults to false, so the
        // failure mode is a bar that was not needed, never a screen with no way back.
        // Download/History/ExoPlayer/MainSettings draw no bar of their own and take no flag.
        Column() {
          if (this.wasSearchActive) {
            // searchFragment.updateSearchResults(searchText), and the listener half of
            // onSearchResultClicked(result).
            PreferenceSearchFragmentPage({
              searchText: this.searchText,
              onResultPicked: (item: PreferenceSearchItem): void => {
                this.onSearchResultClicked(item);
              }
            })
              .layoutWeight(1)
          } else if (this.settingsFragmentHolder === 'VideoAudioSettingsFragment') {
            VideoAudioSettingsFragmentPage({ hostDrawsToolbar: true })
              .layoutWeight(1)
          } else if (this.settingsFragmentHolder === 'DownloadSettingsFragment') {
            DownloadSettingsFragmentPage({ hostDrawsToolbar: true })
              .layoutWeight(1)
          } else if (this.settingsFragmentHolder === 'AppearanceSettingsFragment') {
            AppearanceSettingsFragmentPage({ hostDrawsToolbar: true })
              .layoutWeight(1)
          } else if (this.settingsFragmentHolder === 'HistorySettingsFragment') {
            HistorySettingsFragmentPage({ hostDrawsToolbar: true })
              .layoutWeight(1)
          } else if (this.settingsFragmentHolder === 'ContentSettingsFragment') {
            ContentSettingsFragmentPage({ hostDrawsToolbar: true })
              .layoutWeight(1)
          } else if (this.settingsFragmentHolder === 'NotificationsSettingsFragment') {
            NotificationsSettingsFragmentPage({ hostDrawsToolbar: true })
              .layoutWeight(1)
          } else if (this.settingsFragmentHolder === 'NotificationSettingsFragment') {
            NotificationSettingsFragmentPage({ hostDrawsToolbar: true })
              .layoutWeight(1)
          } else if (this.settingsFragmentHolder === 'NotificationModeConfigFragment') {
            NotificationModeConfigFragmentPage({ hostDrawsToolbar: true })
              .layoutWeight(1)
          } else if (this.settingsFragmentHolder === 'PlayerNotificationSettingsFragment') {
            PlayerNotificationSettingsFragmentPage({ hostDrawsToolbar: true })
              .layoutWeight(1)
          } else if (this.settingsFragmentHolder === 'UpdateSettingsFragment') {
            UpdateSettingsFragmentPage({ hostDrawsToolbar: true })
              .layoutWeight(1)
          } else if (this.settingsFragmentHolder === 'BackupRestoreSettingsFragment') {
            BackupRestoreSettingsFragmentPage({ hostDrawsToolbar: true })
              .layoutWeight(1)
          } else if (this.settingsFragmentHolder === 'DebugSettingsFragment') {
            DebugSettingsFragmentPage({ hostDrawsToolbar: true })
              .layoutWeight(1)
          } else if (this.settingsFragmentHolder === 'ExoPlayerSettingsFragment') {
            ExoPlayerSettingsFragmentPage({ hostDrawsToolbar: true })
              .layoutWeight(1)
          } else if (this.settingsFragmentHolder === 'ChooseTabsFragment') {
            ChooseTabsFragmentPage({ hostDrawsToolbar: true })
              .layoutWeight(1)
          } else if (this.settingsFragmentHolder === 'PeertubeInstanceListFragment') {
            PeertubeInstanceListFragmentPage({ hostDrawsToolbar: true })
              .layoutWeight(1)
          } else {
            MainSettingsFragmentPage()
              .layoutWeight(1)
          }
        }
        .id('settings_fragment_holder')
        .width('100%')
        .layoutWeight(1)
        .backgroundColor(themedBackground(this.blackTheme))

      }
      .width('100%')
      .height('100%')

      FocusOverlayView({ isTv: this.isTv })

      if (this.highlightRect.length === 4) {
        Column()
          .position({ x: this.highlightRect[0], y: this.highlightRect[1] })
          .width(this.highlightRect[2])
          .height(this.highlightRect[3])
          .backgroundColor($r('app.color.ripple'))
          .opacity(this.highlightOpacity)
          .hitTestBehavior(HitTestMode.Transparent)
      }
    }
    .id('SettingsActivityPage')
    .width('100%')
    .height('100%')
    .backgroundColor(themedBackground(this.blackTheme))
  }
}
