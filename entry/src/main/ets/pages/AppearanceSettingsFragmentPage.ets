/**
 * S3 - AppearanceSettingsFragment (screen_appearance_settings), structure read verbatim off
 * codegraph (AppearanceSettingsFragment.java + BasePreferenceFragment.java) and
 * res/xml/appearance_settings.xml.
 *
 * 7 rows, no navOut. hostedBy screen_settings_activity, which PUSHES this page (router.pushUrl) -
 * SettingsActivityPage already carries that push and draws the toolbar; this page draws neither.
 * Four of the seven rows are ListPreferences, so tapping one opens the single-choice dialog the
 * AndroidX preference framework shows - the same shape ExoPlayerSettingsFragmentPage uses.
 *
 * Two source facts this page honours:
 *  - BOTH theme listeners RETURN FALSE, so the framework does not persist. applyThemeChange below
 *    writes the value itself (putBoolean(key_theme_change, true) + putString(theme, ...) +
 *    setDayNightMode) - exactly once, never alongside a framework write.
 *  - night_theme is only ENABLED while the theme is auto_device_theme; otherwise it is disabled
 *    with the night_theme_available summary. That is the conditionalVariants entry bound to
 *    `theme`, built as the ArkUI `if` in build().
 *
 * THREE substitutions, all named rather than hidden:
 *  - ThemeHelper.setDayNightMode (AppCompatDelegate.setDefaultNightMode) ->
 *    ApplicationContext.setColorMode(ConfigurationConstant.ColorMode.*), the HarmonyOS equivalent.
 *  - ActivityCompat.recreate(getActivity()): Android recreates the activity because a theme swap
 *    cannot be applied to a live view tree. setColorMode raises the configuration update itself and
 *    ArkUI re-renders, so there is nothing left to recreate - the branch is kept (it is a
 *    conditionalVariant) and does the ArkUI-side equivalent, which is nothing extra.
 *  - Settings.ACTION_CAPTIONING_SETTINGS has no HarmonyOS implicit want. The source's OWN failure
 *    path is ported instead: ActivityNotFoundException -> Toast(general_error). No want is
 *    invented, and the row is not a silent no-op.
 *
 * The four ListPreference option lists are @array/theme_*, @array/night_theme_*,
 * @array/tablet_mode_* and @array/list_view_mode_* from res/values/settings_keys.xml. Those arrays
 * were not carried into resources/base/element/strarray.json, so each is rebuilt at runtime from
 * its VALUE constants (common/prefs/SettingsKeys.ts) and its label string resources - the same
 * items the XML arrays list, in the same order. No option label is transcribed from a screenshot.
 */
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { promptAction, router } from '@kit.ArkUI';
import { Localization } from '../common/i18n/Localization';
import { AppPreferences } from '../common/prefs/Preferences';
import {
  auto_device_theme_key,
  black_theme_key,
  caption_settings_key,
  dark_theme_key,
  light_theme_key,
  list_view_mode_auto_key,
  list_view_mode_card_key,
  list_view_mode_grid_key,
  list_view_mode_key,
  list_view_mode_list_key,
  main_tabs_position_key,
  night_theme_key,
  show_hold_to_append_key,
  tablet_mode_auto_key,
  tablet_mode_key,
  tablet_mode_off_key,
  tablet_mode_on_key,
  theme_key
} from '../common/prefs/SettingsKeys';
import { DIALOG_MASK_COLOR } from '../common/theme/ServiceTheme';
import { settingsListScroller } from '../common/settings/SettingsScroller';
import {
  applyBlackTheme, BLACK_THEME_KEY, isBlackThemeActive, themedBackground
} from '../common/theme/ThemeBackground';

const TAG: string = 'AppearanceSettingsFragmentPage';

/**
 * Constants.kt:17 - `const val KEY_THEME_CHANGE = "key_theme_change"`. It is a Constants key, not
 * one of the settings_keys.xml constants, so it has no SettingsKeys.ts entry to import; MainActivity
 * is the reader on the source side.
 */
const KEY_THEME_CHANGE: string = 'key_theme_change';

/** Toast.LENGTH_LONG. */
const TOAST_LONG_MS: number = 3500;

/**
 * The AppStorage key a changed list_view_mode is published under, so a list screen that is already
 * drawn can re-read the preference instead of waiting to be re-entered. A plain literal key, as
 * every other AppStorage channel in this app is ('mainSelectedServiceId', 'mainShellOwnsToolbar').
 */
const LIST_VIEW_MODE_SIGNAL: string = 'listViewMode';

/* S5 - style only, LightTheme (the theme S0028-S0035 render in). Reuses the run's style baseline
 * (state.json generation.styleBaseline, source S0004) for background / onSurface / secondaryText,
 * and the AndroidX preference-row and AlertDialog metrics already measured for the sibling
 * preference screens (ExoPlayerSettingsFragmentPage, MainSettingsFragmentPage) - this screen's own
 * base.ui.json confirms every one of them at 1080px/360vp: 16vp gutters (title x=48px, switch right
 * edge 1032px), 16vp vertical row padding (48px between a summary bottom and the next title top),
 * a 47x27vp switch (140x81px) and the 294vp/882px white dialog card with its 48vp/144px option
 * rows. setDivider(null) in BasePreferenceFragment, so the list carries no separators. */
/** ?attr/windowBackground - light_background_color, the capture's #EEEEEE. */
const COLOR_SURFACE: Resource = $r('app.color.background');
/** ?attr/colorPrimary - the switch's checked track and the dialog's selected mark. */
const COLOR_PRIMARY: Resource = $r('app.color.primary');
/**
 * ?attr/colorAccent - the AlertDialog's button colour. S5 read it off LightTheme
 * (light_youtube_accent_color, black); the settings screens do not run under LightTheme. Settings
 * runs under LightSettingsTheme (styles.xml:122), whose only override IS colorAccent, and it is
 * @color/light_settings_accent_color = #E53935, which is why the sibling settings captures render
 * CANCEL red rather than the LightTheme black. Do not put the LightTheme value back.
 */
const COLOR_ACCENT: Resource = $r('app.color.settings_accent');
/** ?android:textColorPrimary - #DE000000 over #EEEEEE is the capture's row title. */
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');
/** ?android:textColorSecondary - #8A000000 over #EEEEEE is the capture's summary. */
const COLOR_SECONDARY_TEXT: Resource = $r('app.color.on_surface_variant');
/** The AlertDialog surface: white in the capture, NOT light_dialog_background_color. */
const COLOR_DIALOG_SURFACE: Resource = $r('app.color.dialog_surface');
/**
 * ?attr/disabledAlpha - preference_material puts it on a disabled row's title/summary group. The
 * night_theme row is the only one that ever renders disabled and the capture never shows that
 * state, so the value comes from the theme, not from a screenshot.
 */
const DISABLED_ALPHA: number = 0.5;

/** @array/theme_values_list + @array/theme_description_list, in XML order. */
const THEME_VALUES: string[] = [light_theme_key, dark_theme_key, black_theme_key,
  auto_device_theme_key];
const THEME_LABELS: string[] = ['light_theme_title', 'dark_theme_title', 'black_theme_title',
  'auto_device_theme_title'];

/** @array/night_theme_values_list + @array/night_theme_description_list. */
const NIGHT_THEME_VALUES: string[] = [dark_theme_key, black_theme_key];
const NIGHT_THEME_LABELS: string[] = ['dark_theme_title', 'black_theme_title'];

/** @array/tablet_mode_values + @array/tablet_mode_description. */
const TABLET_MODE_VALUES: string[] = [tablet_mode_auto_key, tablet_mode_on_key, tablet_mode_off_key];
const TABLET_MODE_LABELS: string[] = ['auto', 'on', 'off'];

/** @array/list_view_mode_values + @array/list_view_mode_description. */
const LIST_VIEW_MODE_VALUES: string[] = [list_view_mode_auto_key, list_view_mode_list_key,
  list_view_mode_grid_key, list_view_mode_card_key];
const LIST_VIEW_MODE_LABELS: string[] = ['auto', 'list', 'grid', 'card'];

/** One entry of a ListPreference: the persisted value and the description shown for it. */
interface PrefOption {
  value: string;
  label: string;
}

/**
 * The ListPreference dialog - single choice over the preference's entries, plus CANCEL. One struct
 * serves all four rows; each instance is given its own `...itemroot` id, and its option rows are
 * instantiated per entry so they deliberately SHARE that id (CLAUDE.md rule 12, list-row exception).
 */
@CustomDialog
struct PreferenceChoiceDialog {
  controller?: CustomDialogController;
  title: ResourceStr = '';
  options: PrefOption[] = [];
  selected: string = '';
  itemId: string = 'preference_choice_itemroot';
  onSelect: (value: string) => void = (value: string): void => {
    hilog.debug(0x0000, TAG, 'PreferenceChoiceDialog: select %{public}s not bound', value);
  };

  build() {
    Column() {
      // alertTitle: 20sp at the dialog's 24vp gutter, 18vp above / 8vp below (titleDivider).
      Text(this.title)
        .width('100%')
        .fontSize(20)
        .fontColor(COLOR_ON_SURFACE)
        .padding({ left: 24, right: 24, top: 18, bottom: 8 })

      ForEach(this.options, (option: PrefOption) => {
        // select_dialog_listview: 48vp rows, 16sp text at the same 24vp gutter.
        Row() {
          // ?attr/listChoiceIndicatorSingle: the capture's row LEADS with a 20vp radio at
          // the 24vp gutter, 32vp from its label (label x = 24+20+32), and marks the
          // current entry by filling that radio in ?attr/colorPrimary - there is no tick
          // at the row's end.
          Stack() {
            if (option.value === this.selected) {
              Column()
                .width(10)
                .height(10)
                .borderRadius(5)
                .backgroundColor(COLOR_PRIMARY)
            }
          }
          .width(20)
          .height(20)
          .borderRadius(10)
          .borderWidth(2)
          .borderColor(option.value === this.selected ? COLOR_PRIMARY : COLOR_SECONDARY_TEXT)
          .margin({ right: 32 })

          Text(option.label)
            .layoutWeight(1)
            .fontSize(16)
            .fontColor(COLOR_ON_SURFACE)
        }
        .width('100%')
        .height(48)
        .padding({ left: 24, right: 24 })
        .alignItems(VerticalAlign.Center)
        .id(this.itemId)
        .onClick(() => {
          this.controller?.close();
          this.onSelect(option.value);
        })
      }, (option: PrefOption) => option.value)

      // buttonPanel: a borderless accent-coloured button, flush with the card's bottom-right.
      // Widget.AppCompat.Button carries android:textAllCaps, which ArkUI has no equivalent for, so
      // the label goes through Localization.buttonLabel() like every other ported button.
      Button(Localization.buttonLabel('cancel'))
        .id('button2')
        .height(42)
        .backgroundColor(Color.Transparent)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(COLOR_ACCENT)
        .alignSelf(ItemAlign.End)
        .margin({ top: 4 })
        .onClick(() => {
          this.controller?.close();
        })
    }
    // The capture's card: 294vp wide, white, a 4vp radius - not the platform's rounded sheet.
    .width(294)
    .backgroundColor(COLOR_DIALOG_SURFACE)
    .borderRadius(4)
    .alignItems(HorizontalAlign.Start)
  }
}

@Entry
@Component
export struct AppearanceSettingsFragmentPage {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  /**
   * TRUE when this screen sits in SettingsActivityPage's settings_fragment_holder, which draws the
   * one toolbar for whatever it holds; FALSE when this page is the pushed route and nothing above
   * it carries a bar. The host passes it explicitly, the way ChannelFragmentPage takes
   * `hostedInMainShell`: a host-set AppStorage flag still reads true underneath a page the host
   * pushed, and MainSettingsFragmentPage pushes this very screen from inside that host. The
   * default is FALSE, so an unset value falls through to DRAWING the bar rather than to none.
   */
  @Prop hostDrawsToolbar: boolean = false;
  /** The stored ListPreference values. */
  @State theme: string = auto_device_theme_key;
  @State nightThemeValue: string = dark_theme_key;
  @State tabletModeValue: string = tablet_mode_auto_key;
  @State listViewModeValue: string = list_view_mode_auto_key;
  /** Summaries, each the entry description of the value above (useSimpleSummaryProvider). */
  @State themeRowSummary: string = '';
  @State nightThemeSummary: string = '';
  @State tabletModeSummary: string = '';
  @State listViewModeSummary: string = '';
  /** SwitchPreferenceCompat rows, with the XML android:defaultValue. */
  @State showHoldToAppend: boolean = true;
  @State mainTabsPosition: boolean = false;
  /** The dialog entries, rebuilt from the source arrays in aboutToAppear. */
  @State themeOptions: PrefOption[] = [];
  @State nightThemeOptions: PrefOption[] = [];
  @State tabletModeOptions: PrefOption[] = [];
  @State listViewModeOptions: PrefOption[] = [];
  /**
   * applyThemeChange's `beginningThemeKey` - the source's `startThemeKey`, read once in
   * onCreatePreferences. It is re-read when the theme actually changes, because Android gets there
   * by recreating the fragment (see applyThemeChange) and onCreatePreferences then reads the new
   * value; without that, a second change would compare against a stale beginning value and skip the
   * recreate branch.
   */
  @State themeAtOpen: string = auto_device_theme_key;
  /** applyThemeChange's `beginningThemeKey` for the night row, `startNightThemeKey`. */
  @State nightThemeAtOpen: string = dark_theme_key;
  /** @string/auto_device_theme_title, the night_theme_available placeholder. */
  @State autoDeviceThemeTitle: string = '';
  /** Held back only so the error line cannot flash before the first preference read finishes. */
  @State isLoading: boolean = true;
  /**
   * ErrorPanelHelper equivalent. The source fragment has no error path (SharedPreferences reads
   * cannot fail), but AppPreferences.instance() throws when the store was never initialised, so on
   * this side a failed read or write is real and must not vanish.
   */
  @State errorInfo: string = '';

  private themeDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    customStyle: true,
    builder: PreferenceChoiceDialog({
      title: $r('app.string.theme_title'),
      options: this.themeOptions,
      selected: this.theme,
      itemId: 'theme_itemroot',
      onSelect: (value: string): void => {
        this.onThemePicked(value);
      }
    })
  });

  private nightThemeDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    customStyle: true,
    builder: PreferenceChoiceDialog({
      title: $r('app.string.night_theme_title'),
      options: this.nightThemeOptions,
      selected: this.nightThemeValue,
      itemId: 'night_theme_itemroot',
      onSelect: (value: string): void => {
        this.onNightThemePicked(value);
      }
    })
  });

  private tabletModeDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    customStyle: true,
    builder: PreferenceChoiceDialog({
      title: $r('app.string.tablet_mode_title'),
      options: this.tabletModeOptions,
      selected: this.tabletModeValue,
      itemId: 'tablet_mode_itemroot',
      onSelect: (value: string): void => {
        this.onTabletModePicked(value);
      }
    })
  });

  private listViewModeDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    customStyle: true,
    builder: PreferenceChoiceDialog({
      title: $r('app.string.list_view_mode'),
      options: this.listViewModeOptions,
      selected: this.listViewModeValue,
      itemId: 'list_view_mode_itemroot',
      onSelect: (value: string): void => {
        this.onListViewModePicked(value);
      }
    })
  });

  /** Rule 8: a dialog still on screen when the page pops would outlive it. */
  aboutToDisappear(): void {
    this.themeDialog.close();
    this.nightThemeDialog.close();
    this.tabletModeDialog.close();
    this.listViewModeDialog.close();
  }

  async aboutToAppear(): Promise<void> {
    try {
      await this.loadPreferences();
    } catch (err) {
      this.report(err as BusinessError);
    } finally {
      this.isLoading = false;
    }
  }

  /** onCreatePreferences: inflate the rows, then read the values they show. */
  private async loadPreferences(): Promise<void> {
    const context: common.Context = getContext(this) as common.Context;
    this.themeOptions = this.buildOptions(THEME_VALUES, THEME_LABELS, context);
    this.nightThemeOptions = this.buildOptions(NIGHT_THEME_VALUES, NIGHT_THEME_LABELS, context);
    this.tabletModeOptions = this.buildOptions(TABLET_MODE_VALUES, TABLET_MODE_LABELS, context);
    this.listViewModeOptions =
      this.buildOptions(LIST_VIEW_MODE_VALUES, LIST_VIEW_MODE_LABELS, context);
    this.autoDeviceThemeTitle = context.resourceManager.getStringByNameSync('auto_device_theme_title');

    // @string/default_theme_value is @string/auto_device_theme_key, i.e. the constant below.
    this.theme = await AppPreferences.getString(theme_key, auto_device_theme_key);
    this.themeAtOpen = this.theme;
    // @string/default_night_theme_value is @string/dark_theme_key.
    this.nightThemeValue = await AppPreferences.getString(night_theme_key, dark_theme_key);
    this.nightThemeAtOpen = this.nightThemeValue;
    this.tabletModeValue = await AppPreferences.getString(tablet_mode_key, tablet_mode_auto_key);
    this.listViewModeValue =
      await AppPreferences.getString(list_view_mode_key, list_view_mode_auto_key);
    this.showHoldToAppend = await AppPreferences.getBoolean(show_hold_to_append_key, true);
    this.mainTabsPosition = await AppPreferences.getBoolean(main_tabs_position_key, false);

    this.themeRowSummary = this.describe(this.themeOptions, this.theme);
    this.nightThemeSummary = this.describe(this.nightThemeOptions, this.nightThemeValue);
    this.tabletModeSummary = this.describe(this.tabletModeOptions, this.tabletModeValue);
    this.listViewModeSummary = this.describe(this.listViewModeOptions, this.listViewModeValue);
  }

  /** One <string-array> pair rebuilt as entries: the value constants with their label resources. */
  private buildOptions(values: string[], labels: string[], context: common.Context): PrefOption[] {
    const options: PrefOption[] = [];
    for (let i = 0; i < values.length && i < labels.length; i++) {
      const option: PrefOption = {
        value: values[i],
        label: context.resourceManager.getStringByNameSync(labels[i])
      };
      options.push(option);
    }
    return options;
  }

  /** The entry description for a stored value; the raw value if the entries do not carry it. */
  private describe(options: PrefOption[], value: string): string {
    for (const option of options) {
      if (option.value === value) {
        return option.label;
      }
    }
    return value;
  }

  private report(err: BusinessError): void {
    this.errorInfo = err.message;
    hilog.error(0x0000, TAG, 'preference access failed: %{public}s', this.errorInfo);
  }

  /**
   * AppearanceSettingsFragment.java:29-38. The listener returns false, so the value is NOT persisted
   * by the framework - applyThemeChange below is the only writer.
   */
  private async onThemePicked(value: string): Promise<void> {
    if (value === auto_device_theme_key) {
      promptAction.showToast({
        message: $r('app.string.select_night_theme_toast'),
        duration: TOAST_LONG_MS
      });
    }
    this.theme = value;
    this.themeRowSummary = this.describe(this.themeOptions, value);
    await this.applyThemeChange(this.themeAtOpen, theme_key, value);
  }

  /** AppearanceSettingsFragment.java:45-47, the enabled branch only. */
  private async onNightThemePicked(value: string): Promise<void> {
    this.nightThemeValue = value;
    this.nightThemeSummary = this.describe(this.nightThemeOptions, value);
    await this.applyThemeChange(this.nightThemeAtOpen, night_theme_key, value);
  }

  /**
   * applyThemeChange, verbatim: the theme-change flag, then the value itself, then the day/night
   * mode. Both writes go through the flushing statics, so neither is lost on relaunch.
   *
   * The source's trailing ActivityCompat.recreate(getActivity()) exists because an Android activity
   * cannot re-theme a live view tree; setColorMode raises the configuration change itself and ArkUI
   * re-renders, so the branch stays (it is a conditionalVariant) with nothing further to do.
   */
  private async applyThemeChange(beginningThemeKey: string, key: string,
    newValue: string): Promise<void> {
    try {
      await AppPreferences.putBoolean(KEY_THEME_CHANGE, true);
      await AppPreferences.putString(key, newValue);
      this.setDayNightMode(newValue);
      if (newValue !== beginningThemeKey) {
        // ActivityCompat.recreate(getActivity()): the view tree is rebuilt and onCreatePreferences
        // runs again, re-reading startThemeKey/startNightThemeKey. setColorMode already re-renders
        // ArkUI, so the recreate itself has nothing left to do - but the re-read is behaviour, and
        // without it a second change would still be measured against the first screen-open value.
        hilog.info(0x0000, TAG, 'theme changed from %{public}s to %{public}s',
          beginningThemeKey, newValue);
        this.themeAtOpen = this.theme;
        this.nightThemeAtOpen = this.nightThemeValue;
      }
    } catch (err) {
      this.report(err as BusinessError);
    }
  }

  /** ThemeHelper.setDayNightMode - AppCompatDelegate.setDefaultNightMode's HarmonyOS equivalent. */
  private setDayNightMode(selectedThemeKey: string): void {
    const context: common.Context = getContext(this) as common.Context;
    let mode: ConfigurationConstant.ColorMode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    if (selectedThemeKey === light_theme_key) {
      mode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    } else if (selectedThemeKey === dark_theme_key || selectedThemeKey === black_theme_key) {
      mode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    }
    context.getApplicationContext().setColorMode(mode);
    // The black theme's window background follows at once; a device-driven change of colour mode
    // reaches EntryAbility.onConfigurationUpdate.
    applyBlackTheme(isBlackThemeActive(AppPreferences.instance(),
      mode === ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET
        ? DeviceColorMode.of(getContext(this) as common.UIAbilityContext) : mode));
  }

  private async onTabletModePicked(value: string): Promise<void> {
    this.tabletModeValue = value;
    this.tabletModeSummary = this.describe(this.tabletModeOptions, value);
    try {
      await AppPreferences.putString(tablet_mode_key, value);
    } catch (err) {
      this.report(err as BusinessError);
    }
  }

  private async onListViewModePicked(value: string): Promise<void> {
    this.listViewModeValue = value;
    this.listViewModeSummary = this.describe(this.listViewModeOptions, value);
    try {
      await AppPreferences.putString(list_view_mode_key, value);
      // Every list screen reads this preference ONCE, in its aboutToAppear, so one that is already
      // drawn keeps the old item template until it is left and re-entered. Publishing the new value
      // is the signal they can observe, in the same AppStorage + @StorageProp/@Watch shape the
      // shell already uses for `mainSelectedServiceId`.
      AppStorage.setOrCreate<string>(LIST_VIEW_MODE_SIGNAL, value);
    } catch (err) {
      this.report(err as BusinessError);
    }
  }

  private async onShowHoldToAppendChanged(enabled: boolean): Promise<void> {
    this.showHoldToAppend = enabled;
    try {
      await AppPreferences.putBoolean(show_hold_to_append_key, enabled);
    } catch (err) {
      this.report(err as BusinessError);
    }
  }

  private async onMainTabsPositionChanged(enabled: boolean): Promise<void> {
    this.mainTabsPosition = enabled;
    try {
      await AppPreferences.putBoolean(main_tabs_position_key, enabled);
      // The hosted MainFragmentPage gets no onPageShow (it is a child of MainActivityPage, not a
      // route), so it observes this signal instead of re-reading the preference on resume.
      AppStorage.setOrCreate<boolean>('mainTabsPositionBottom', enabled);
    } catch (err) {
      this.report(err as BusinessError);
    }
  }

  build() {
    Column() {
      if (!this.hostDrawsToolbar) {
        // toolbar_layout.xml: the Up affordance and the PreferenceScreen title that
        // BasePreferenceFragment.onViewCreated pushes into the host toolbar. android.R.id.home is
        // the slug. This page is reached by MainSettingsFragmentPage's router.pushUrl(row.route)
        // (MainSettingsFragmentPage line 222) and by nothing else - SettingsActivityPage's
        // settingsFragmentHolder branch for it is unreachable (openSettingsFragment has no caller),
        // so no host draws a bar above this page and the Up affordance has to live here.
        Row() {
          // The Up affordance: a 24vp glyph centred in the ?attr/actionBarSize touch target,
          // tinted ?attr/actionColor = @color/white by ToolbarTheme.
          Image($r('app.media.ic_arrow_back'))
            .id('home')
            .accessibilityText($r('app.string.navigate_back'))
            .objectFit(ImageFit.Contain)
            .width(56)
            .height(56)
            .padding(16)
            .fillColor($r('app.color.on_primary'))
            .onClick(() => {
              router.back();
            })

          // Widget.AppCompat.Toolbar.Title: 20sp medium on ?attr/actionColor, inset 16vp past the
          // navigation button - the capture's 72vp title start.
          Text($r('app.string.settings_category_appearance_title'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.on_primary'))
            .margin({ left: 16 })
        }
        .width('100%')
        // Toolbar: ?attr/actionBarSize tall on ?attr/colorPrimary.
        .height(56)
        .alignItems(VerticalAlign.Center)
        .backgroundColor(COLOR_PRIMARY)
      }

      // The rows are the source's preference RecyclerView (BasePreferenceFragment inflates
      // res/xml/appearance_settings.xml into one), and the capture renders them in
      // id/recycler_view - so they are a real List with one ListItem per row, not a plain Column.
      List({ scroller: settingsListScroller }) {
        // -- ListPreference: theme -----------------------------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.theme_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
              Text(this.themeRowSummary)
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('theme')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.themeDialog.open();
          })
        }

        // -- ListPreference: night_theme -----------------------------------------
        // conditionalVariants (boundTo `theme`): startThemeKey.equals(autoDeviceThemeKey) - the row
        // is selectable only while the theme is auto_device_theme, otherwise it is disabled and says
        // why. The source reads that value once per fragment creation, and reaches every later value
        // by RECREATING the fragment (applyThemeChange), so what it renders is always the current
        // `theme`. Nothing recreates here, so the branch reads it directly - same states, no stale
        // window.
        if (this.theme === auto_device_theme_key) {
          ListItem() {
            Row() {
              Column() {
                Text($r('app.string.night_theme_title'))
                  .width('100%')
                  .fontSize(16)
                  .lineHeight(20)
                  .fontColor(COLOR_ON_SURFACE)
                // android:summary="@string/night_theme_summary" - a ListPreference substitutes the
                // current entry for its %s.
                Text($r('app.string.night_theme_summary', this.nightThemeSummary))
                  .width('100%')
                  .fontSize(14)
                  .lineHeight(17)
                  .fontColor(COLOR_SECONDARY_TEXT)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .id('night_theme')
            .width('100%')
            .padding({ left: 16, right: 16, top: 16, bottom: 16 })
            .alignItems(VerticalAlign.Center)
            .onClick(() => {
              this.nightThemeDialog.open();
            })
          }
        } else {
          ListItem() {
            Row() {
              Column() {
                Text($r('app.string.night_theme_title'))
                  .width('100%')
                  .fontSize(16)
                  .lineHeight(20)
                  .fontColor(COLOR_ON_SURFACE)
                Text($r('app.string.night_theme_available', this.autoDeviceThemeTitle))
                  .width('100%')
                  .fontSize(14)
                  .lineHeight(17)
                  .fontColor(COLOR_SECONDARY_TEXT)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .id('night_theme')
            .width('100%')
            .padding({ left: 16, right: 16, top: 16, bottom: 16 })
            .alignItems(VerticalAlign.Center)
            // preference_material dims a disabled row's title/summary by ?attr/disabledAlpha.
            .opacity(DISABLED_ALPHA)
            .enabled(false)
          }
        }

        // -- SwitchPreferenceCompat: show_hold_to_append --------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.show_hold_to_append_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.show_hold_to_append_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            // The whole row is the one tappable control, so the switch itself takes no touch.
            // widget_frame: a 47x27vp switch sitting against the row's 16vp right gutter.
            Toggle({ type: ToggleType.Switch, isOn: this.showHoldToAppend })
              .hitTestBehavior(HitTestMode.None)
              .width(47)
              .height(27)
              .margin({ left: 16 })
              .selectedColor(COLOR_PRIMARY)
          }
          .id('show_hold_to_append')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.onShowHoldToAppendChanged(!this.showHoldToAppend);
          })
        }

        // -- ListPreference: tablet_mode -----------------------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.tablet_mode_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
              Text(this.tabletModeSummary)
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('tablet_mode')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.tabletModeDialog.open();
          })
        }

        // -- ListPreference: list_view_mode --------------------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.list_view_mode'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
              Text(this.listViewModeSummary)
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('list_view_mode')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.listViewModeDialog.open();
          })
        }

        // -- Preference: caption_settings_key -------------------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.caption_setting_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.caption_setting_description'))
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(COLOR_SECONDARY_TEXT)
              Text($r('app.string.caption_setting_unavailable_note'))
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('caption_settings_key')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          // The source opens Settings.ACTION_CAPTIONING_SETTINGS, the system-wide caption style
          // every player follows. HarmonyOS gives an app no such style to open or follow, and an
          // in-app screen that styled only this app's cues was a different feature passed off as
          // that one - so the row is shown, disabled, with the reason, like the download folders.
          .opacity(DISABLED_ALPHA)
          .enabled(false)
        }

        // -- SwitchPreferenceCompat: main_tabs_position ---------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.main_tabs_position_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.main_tabs_position_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            // widget_frame: a 47x27vp switch sitting against the row's 16vp right gutter.
            Toggle({ type: ToggleType.Switch, isOn: this.mainTabsPosition })
              .hitTestBehavior(HitTestMode.None)
              .width(47)
              .height(27)
              .margin({ left: 16 })
              .selectedColor(COLOR_PRIMARY)
          }
          .id('main_tabs_position')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.onMainTabsPositionChanged(!this.mainTabsPosition);
          })
        }
      }
      .width('100%')
      .layoutWeight(1)

      // ErrorPanelHelper equivalent: only once the first read has finished and failed.
      if (!this.isLoading && this.errorInfo.length > 0) {
        Text(this.errorInfo)
          .width('100%')
          .fontSize(14)
          .lineHeight(17)
          .fontColor(COLOR_SECONDARY_TEXT)
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
      }
    }
    .id('AppearanceSettingsFragmentPage')
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(themedBackground(this.blackTheme))
  }
}

/** The colour mode the ability's configuration reports (the device's while the theme follows it). */
class DeviceColorMode {
  static of(context: common.UIAbilityContext): ConfigurationConstant.ColorMode {
    const mode: ConfigurationConstant.ColorMode | undefined = context.config.colorMode;
    return mode === undefined ? ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET : mode;
  }
}
