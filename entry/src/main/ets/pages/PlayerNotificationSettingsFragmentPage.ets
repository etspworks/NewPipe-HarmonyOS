/**
 * S3 - PlayerNotificationSettingsFragment (screen_player_notification_settings): the real view
 * tree, unstyled.
 *
 * res/xml/player_notification_settings.xml: three SwitchPreferenceCompat rows, then a
 * PreferenceCategory (settings_category_header_layout, no title of its own) holding ONE row - the
 * custom NotificationActionsPreference. hostedBy screen_settings_activity, which PUSHES this page.
 * No navOut.
 *
 * The fragment class is a 3-line stub; ALL the substance is in NotificationActionsPreference, which
 * replaces its row layout with res/layout/settings_notification.xml: a `summary` label plus five
 * <include>s of settings_notification_action.xml, ids notificationAction0..4. Each include holds
 * notificationActionIcon / notificationActionTitle / notificationActionSummary, the
 * notificationActionClickableArea that opens the action chooser, and the
 * notificationActionCheckBox (+ its own clickable area). holder.itemView.setClickable(false) - the
 * preference row is a CONTAINER, not a tappable preference - so the tap targets are the five slots
 * and the five checkboxes, never the row.
 *
 * The five slots are built by IntStream.range(0, 5).mapToObj(new NotificationSlot(...)), i.e. a
 * LIST over SLOT_PREF_KEYS with per-slot selectedAction and isInCompactSlots - the bindingContract
 * says so, so they are rendered from a slot array, never as five hand-written rows.
 * notification_slot_compact_checkbox is PER SLOT: five instances of one source id, sharing that
 * slug the way a list row does - see the note on the checkbox row in build() for how Rule 12's
 * list-row shape is applied to it.
 *
 * The source's SDK_INT >= TIRAMISU branch has three effects: (a) swap the summary for
 * notification_actions_summary_android13, (b) hide the compact checkboxes, (c) hide slots 0-2.
 * This port now takes ALL THREE, and goes one further by hiding slots 3-4 as well, because here
 * the system owns every action rather than the first three. See SHOW_ACTION_SLOTS below for the
 * three SDK lines that make these rows undrawable by anybody on this platform.
 *
 * An earlier revision of this header said the pre-33 arm was REQUIRED and that (b) and (c) were
 * deliberately not applied. That was written before the ceiling was measured; offering controls
 * the platform cannot honour is not fidelity, it is a screen that lies.
 *
 * S4 wiring, against the ported common/player/NotificationConstants.ts:
 *  - the three switches read and write their preference through svc_preferences and flush, so a
 *    write survives a relaunch;
 *  - setupActions(): the five slots come from SLOT_PREF_KEYS / SLOT_DEFAULTS, each summary from
 *    getActionName(selectedAction) and each glyph from ACTION_ICONS. ACTION_ICONS holds media BASE
 *    NAMES (a .ts cannot call $r()), so `actionIconOf()` maps a name to its `$r('app.media....')`
 *    literal. REWIND and FORWARD are deliberately '' - their ExoPlayer glyphs were never part of
 *    the source app's own resources - and those slots draw NO icon rather than a lookalike;
 *  - compactSlots = getCompactSlotsFromPreferences(); onToggleCompactSlot refuses a fourth with
 *    Toast(notification_actions_at_most_three) and leaves the checkbox unchecked;
 *  - NOTHING is persisted on change: saveChanges() runs in onDetached(), so its ArkUI home is
 *    aboutToDisappear - three compact keys (-1 for an unused one) and five slot keys, then one
 *    flush, which is the source's single editor.apply();
 *  - svc_notification is read once on load: while the OS has this app's notifications switched
 *    off, no player notification can show these actions, and the preference SUMMARY says so.
 *    DEVIATION, reported: it gates nothing, so no control becomes inert.
 * The source also broadcasts ACTION_RECREATE_NOTIFICATION after saving. There is no consumer in
 * this port - the player notification is AVSession's, not one this app builds - so the constant is
 * referenced by NotificationConstants and no broadcast is faked here.
 * No visual styling here; that is S5.
 */
import { promptAction, router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Localization } from '../common/i18n/Localization';
import { AppPreferences } from '../common/prefs/Preferences';
import { ChoiceIndicator } from '../components/ChoiceIndicator';
import {
  notification_colorize_key,
  scale_to_square_image_in_notifications_key,
  show_thumbnail_key
} from '../common/prefs/SettingsKeys';
import {
  ACTION_ICONS,
  ALL_ACTIONS,
  getActionName,
  getCompactSlotsFromPreferences,
  SLOT_COMPACT_PREF_KEYS,
  SLOT_DEFAULTS,
  SLOT_PREF_KEYS
} from '../common/player/NotificationConstants';
import { DIALOG_MASK_COLOR } from '../common/theme/ServiceTheme';
import { settingsListScroller } from '../common/settings/SettingsScroller';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

const TAG: string = 'PlayerNotificationSettingsFragmentPage';

/** Toast.LENGTH_SHORT. */
const TOAST_SHORT_MS: number = 2000;
/** A row with no HarmonyOS counterpart is shown disabled with the reason, like the caption row. */
const DISABLED_ALPHA: number = 0.5;

/* S5 - style only, LightSettingsTheme (the theme every captured state of this screen renders in).
 * Reuses the run's style baseline (state.json generation.styleBaseline, source S0004): primary /
 * onPrimary / background / onSurface / secondaryText and the 56vp toolbar with its 72vp title
 * inset and 20fp Medium bar title. The preference-row metrics come from THIS screen's own
 * base.ui.json; the slot-row metrics are settings_notification_action.xml's own (a 48dp icon at
 * 12dp with 8dp above and below, the title 8dp past it at 14sp, the checkbox in a square tap area
 * at the end), which base.ui.json confirms at density 3.0. Colours are sampled from base.png. */
/** ?attr/colorPrimary - the toolbar, the switches and the checked checkbox all sample (229,57,53). */
const COLOR_PRIMARY: Resource = $r('app.color.primary');
/** ?attr/actionColor - the Up glyph and the bar title. */
const COLOR_ON_PRIMARY: Resource = $r('app.color.on_primary');
/** ?attr/windowBackground - light_background_color, the capture's #EEEEEE. */
const COLOR_SURFACE: Resource = $r('app.color.background');
/**
 * ?android:textColorPrimary - #DE000000 over #EEEEEE is the capture's (31,31,31), which is also
 * what app:tint="?android:textColorPrimary" paints each slot's action glyph.
 */
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');
/** ?android:textColorSecondary - #8A000000 over #EEEEEE is the capture's (109,109,109). */
const COLOR_SECONDARY_TEXT: Resource = $r('app.color.on_surface_variant');
/** The unchecked checkbox outline samples (109,109,109), the same secondary ink. */
const COLOR_CHECKBOX_UNSELECTED: Resource = $r('app.color.on_surface_variant');
/** The AlertDialog surface: white, per the one dialog this app's captures record. */
const COLOR_DIALOG_SURFACE: Resource = $r('app.color.dialog_surface');
/** The unchecked single-choice indicator, per that same dialog capture. */
/**
 * settings_category_header_layout.xml: a 14dp ?attr/contrast_background_color band
 * (light_contrast_background_color) carrying a 5dp ?attr/toolbar_shadow gradient at its top
 * (@drawable/toolbar_shadow_light: android:angle="-90", light_shadow_start_color to transparent),
 * closed by a 1dp ?attr/separator_color rule (light_separator_color).
 */
const COLOR_CATEGORY_BAND: Resource = $r('app.color.contrast_background');
const COLOR_SEPARATOR: Resource = $r('app.color.separator');
const COLOR_SHADOW_START: Resource = $r('app.color.shadow_start');
const COLOR_SHADOW_END: string = '#00000000';

/** saveChanges(): a compact slot the user did not fill is written as -1. */
const COMPACT_SLOT_UNUSED: number = -1;

/** NotificationSlot.SLOT_TITLES - one title resource per slot index. */
const SLOT_TITLE_NAMES: string[] = ['notification_action_0_title', 'notification_action_1_title',
  'notification_action_2_title', 'notification_action_3_title', 'notification_action_4_title'];

/** The <include> ids of settings_notification.xml, one per slot - the replay's control slugs. */
const SLOT_IDS: string[] = ['notificationAction0', 'notificationAction1', 'notificationAction2',
  'notificationAction3', 'notificationAction4'];

/** NotificationConstants.NOTHING - the action a slot shows until its value is read (S4). */
const ACTION_NOTHING: number = 0;

/**
 * Whether this screen offers the five action slots and the compact-view checkboxes.
 *
 * It does not, and cannot. The media card the user sees is published by AVSession, not by this
 * app, and nothing on this platform can draw NewPipe's five-action notification:
 *   - notification/notificationRequest.d.ts:351 - "A notification can contain a maximum of two
 *     buttons by default";
 *   - @ohos.notificationManager.d.ts:1264 - NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW: "A third-party
 *     application cannot directly create a notification of this type";
 *   - :1292 - NOTIFICATION_CONTENT_LIVE_VIEW: "Only system applications are supported";
 *   - and there is no API for button ORDER or for a compact-view subset at all.
 *
 * The reference has its own answer for exactly this situation. On Android 13+ the system owns the
 * first three actions, so NewPipe hides those rows and swaps the summary for
 * notification_actions_summary_android13. Here the system owns ALL of them, so that arm is taken
 * in full - with the reference's own string, already translated into 91 locales and until now
 * referenced by nothing.
 *
 * The rows and their preference keys are KEPT, not deleted: a later platform that can draw them
 * would want them back, and deleting is a decision nobody made. Flip this to true to see them.
 */
const SHOW_ACTION_SLOTS: boolean = false;

/** How many slots the compact notification can carry (onToggleCompactSlot's `< 3`). */
const MAX_COMPACT_SLOTS: number = 3;

/** One `new NotificationSlot(context, prefs, i, view, compactSlots.contains(i), ...)`. */
class NotificationSlotState {
  /** The slot index, i.e. which SLOT_PREF_KEYS entry it reads and writes. */
  readonly index: number;
  /** SLOT_TITLES[i], resolved once. */
  readonly title: string;
  /** prefs.getInt(SLOT_PREF_KEYS[i], SLOT_DEFAULTS[i]) - bound in S4. */
  selectedAction: number;
  /** getActionName(context, selectedAction) - the row's summary line. */
  actionName: string;
  /**
   * ACTION_ICONS[selectedAction], or null where that entry is 0 - the source then calls
   * setImageDrawable(null), i.e. the slot draws no glyph at all. Bound in S4 with the rest of
   * NotificationConstants; nothing stands in for it here.
   */
  actionIcon: Resource | null;
  /** compactSlots.contains(i). */
  isInCompactSlots: boolean;

  constructor(index: number, title: string, selectedAction: number, actionName: string,
    actionIcon: Resource | null, isInCompactSlots: boolean) {
    this.index = index;
    this.title = title;
    this.selectedAction = selectedAction;
    this.actionName = actionName;
    this.actionIcon = actionIcon;
    this.isInCompactSlots = isInCompactSlots;
  }
}

/** One entry of NotificationConstants.ALL_ACTIONS, as the chooser renders it. */
interface ActionOption {
  action: number;
  name: string;
}

/**
 * openActionChooserDialog(): single_choice_dialog_view with one list_radio_icon_item per
 * ALL_ACTIONS entry, titled SLOT_TITLES[i] and cancelable, dismissed by picking a radio. The
 * option list sits in a HEIGHT-BOUNDED Scroll so a long action list cannot push the dialog's
 * bottom out of the frame.
 */
@CustomDialog
struct NotificationActionChooserDialog {
  controller?: CustomDialogController;
  title: string = '';
  options: ActionOption[] = [];
  selectedAction: number = ACTION_NOTHING;
  onSelect: (action: number) => void = (action: number): void => {
    hilog.debug(0x0000, TAG, 'ActionChooser: onSelect(%{public}d) not bound', action);
  };

  build() {
    Column() {
      // alertTitle: 20sp at the dialog's 24vp gutter, 18vp above and 8vp below (titleDivider).
      Text(this.title)
        .width('100%')
        .fontSize(20)
        .fontColor(COLOR_ON_SURFACE)
        .padding({ left: 24, right: 24, top: 18, bottom: 8 })

      Scroll() {
        Column() {
          ForEach(this.options, (option: ActionOption) => {
            // list_radio_icon_item: a 48vp row, the indicator then 16sp at the 24vp gutter.
            Row() {
              // The reference's hollow ring, not ArkUI's filled disc - see ChoiceIndicator.
              ChoiceIndicator({ checked: option.action === this.selectedAction })
                .margin({ right: 20 })
              Text(option.name)
                .layoutWeight(1)
                .fontSize(16)
                .fontColor(COLOR_ON_SURFACE)
            }
            .width('100%')
            .height(48)
            .padding({ left: 24, right: 24 })
            .alignItems(VerticalAlign.Center)
            .id('notification_action_choice_itemroot')
            .onClick(() => {
              this.controller?.close();
              this.onSelect(option.action);
            })
          }, (option: ActionOption) => `${option.action}`)
        }
        .width('100%')
      }
      .constraintSize({ maxHeight: 320 })
      .margin({ bottom: 8 })
    }
    // The AlertDialog card: 294vp wide, white, a 4vp radius - not the platform's rounded sheet.
    // openActionChooserDialog() sets no buttons, so the card ends with the option list.
    .width(294)
    .backgroundColor(COLOR_DIALOG_SURFACE)
    .borderRadius(4)
    .alignItems(HorizontalAlign.Start)
  }
}

@Entry
@Component
export struct PlayerNotificationSettingsFragmentPage {
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
  /** SwitchPreferenceCompat scale_to_square_image_in_notifications_key, defaultValue false. */
  @State scaleToSquareImage: boolean = false;
  /** SwitchPreferenceCompat notification_colorize_key, defaultValue true. */
  @State colorizeNotification: boolean = true;
  /** SwitchPreferenceCompat show_thumbnail_key, defaultValue true. */
  @State showThumbnail: boolean = true;

  /**
   * @+id/summary. The source's conditionalVariant here is
   * `Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU` in onBindViewHolder, which swaps in
   * notification_actions_summary_android13 and hides the rows the system owns. HarmonyOS has no
   * SDK_INT, but it has the same situation permanently and MORE of it, so that arm is the one
   * taken, gated on SHOW_ACTION_SLOTS.
   *
   * The reference's own android13 string is not used verbatim, and that is deliberate: it reads
   * "Edit each notification action below by tapping on it. The first three actions ... are set by
   * the system", which is true on Android 13 where slots 3-4 remain. Here the system owns ALL of
   * them and no row is left to edit, so that sentence would point at nothing - a new small lie in
   * the place of the old one. notification_actions_summary_platform says what is actually true.
   *
   * T-0163: it used to be swapped for @string/notifications_disabled whenever the OS would not
   * let this app post a notification, which is a swap the source makes on the OTHER screen - the
   * master row of NotificationSettingsFragment - and not here. The effect was that the one line
   * telling the user how to use this screen ("Edit each notification action below by tapping on
   * it. Select up to three...") was never shown on a handset with notifications off, which is how
   * both test devices are set up. The reference shows the instruction unconditionally; the
   * disabled warning is already carried by the parent Notifications screen, with its Settings
   * action (NotificationsSettingsFragmentPage.ets:546).
   */
  private notificationActionsPreferenceSummary: ResourceStr =
    SHOW_ACTION_SLOTS
      ? $r('app.string.notification_actions_summary')
      : $r('app.string.notification_actions_summary_platform');

  /**
   * setupActions(): `IntStream.range(0, 5).mapToObj(i -> new NotificationSlot(...))`.
   *
   * PLAN DEFECT, reported to the orchestrator: the spec names this state var
   * `@State 5ActionSlotSelectors:` - not a legal ArkTS identifier, since no identifier may start
   * with a digit - so the five slot selectors it describes are this `slots` array.
   */
  @State slots: NotificationSlotState[] = [];
  /** getCompactSlotsFromPreferences() - at most three slot indices. */
  @State compactSlots: number[] = [];
  /** compactSlots.contains(i) per slot: what each notificationActionCheckBox is checked against. */
  @State compactSlotCheckboxes: boolean[] = [false, false, false, false, false];
  /** ALL_ACTIONS, as the chooser lists them. */
  @State actionOptions: ActionOption[] = [];
  /** Which slot the chooser is currently opened for, and what it shows for it. */
  @State chooserSlotIndex: number = 0;
  @State chooserTitle: string = '';
  @State chooserSelectedAction: number = ACTION_NOTHING;
  @State isLoading: boolean = false;
  @State errorInfo: string = '';

  private actionChooserDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    customStyle: true,
    builder: NotificationActionChooserDialog({
      title: this.chooserTitle,
      options: this.actionOptions,
      selectedAction: this.chooserSelectedAction,
      onSelect: (action: number): void => {
        this.onActionPicked(action);
      }
    })
  });

  aboutToAppear(): void {
    this.loadState();
  }

  /**
   * onBindViewHolder -> setupActions(view), plus the three SwitchPreferenceCompat values the
   * fragment's own XML carries. Every value comes from svc_preferences; nothing is invented.
   */
  private loadState(): void {
    this.isLoading = true;
    const prefs: AppPreferences = AppPreferences.instance();
    // android:defaultValue - false, true, true, in XML order.
    this.scaleToSquareImage =
      prefs.getBooleanSync(scale_to_square_image_in_notifications_key, false);
    this.colorizeNotification = prefs.getBooleanSync(notification_colorize_key, true);
    this.showThumbnail = prefs.getBooleanSync(show_thumbnail_key, true);

    this.actionOptions = this.buildActionOptions();
    this.compactSlots = getCompactSlotsFromPreferences();
    this.slots = this.buildSlots();

    this.errorInfo = '';
    this.isLoading = false;
  }

  /** ALL_ACTIONS, each labelled by getActionName(context, action). */
  private buildActionOptions(): ActionOption[] {
    const options: ActionOption[] = [];
    for (const action of ALL_ACTIONS) {
      const option: ActionOption = { action: action, name: getActionName(action) };
      options.push(option);
    }
    return options;
  }

  /**
   * IntStream.range(0, 5).mapToObj(i -> new NotificationSlot(context, prefs, i, view,
   * compactSlots.contains(i), this::onToggleCompactSlot)) - the per-slot value is
   * prefs.getInt(SLOT_PREF_KEYS[i], SLOT_DEFAULTS[i]).
   */
  private buildSlots(): NotificationSlotState[] {
    const prefs: AppPreferences = AppPreferences.instance();
    const slots: NotificationSlotState[] = [];
    const checkboxes: boolean[] = [];
    for (let i = 0; i < SLOT_TITLE_NAMES.length; i++) {
      const action: number = prefs.getIntSync(SLOT_PREF_KEYS[i], SLOT_DEFAULTS[i]);
      const inCompact: boolean = this.compactSlots.indexOf(i) >= 0;
      checkboxes.push(inCompact);
      slots.push(new NotificationSlotState(i, Localization.getString(SLOT_TITLE_NAMES[i]),
        action, getActionName(action), this.actionIconOf(action), inCompact));
    }
    this.compactSlotCheckboxes = checkboxes;
    return slots;
  }

  /**
   * updateInfo(): `ACTION_ICONS[selectedAction] == 0` -> setImageDrawable(null). ACTION_ICONS
   * carries migrated media BASE NAMES because a `.ts` cannot call `$r()`, so the name is mapped to
   * its literal here. '' means the slot draws no glyph - REWIND and FORWARD are '' on purpose.
   */
  private actionIconOf(action: number): Resource | null {
    const name: string = action >= 0 && action < ACTION_ICONS.length ? ACTION_ICONS[action] : '';
    if (name === 'ic_previous') {
      return $r('app.media.ic_previous');
    }
    if (name === 'ic_next') {
      return $r('app.media.ic_next');
    }
    if (name === 'ic_pause') {
      return $r('app.media.ic_pause');
    }
    if (name === 'ic_hourglass_top') {
      return $r('app.media.ic_hourglass_top');
    }
    if (name === 'ic_repeat') {
      return $r('app.media.ic_repeat');
    }
    if (name === 'ic_shuffle') {
      return $r('app.media.ic_shuffle');
    }
    if (name === 'ic_close') {
      return $r('app.media.ic_close');
    }
    return null;
  }

  /** editor.putBoolean(key, value).apply() on one of the three switches, flushed. */
  private persistBoolean(key: string, value: boolean): void {
    AppPreferences.putBoolean(key, value).catch((err: Error): void => {
      this.errorInfo = err.message;
      hilog.error(0x0000, TAG, 'putBoolean(%{public}s): %{public}s', key, err.message);
    });
  }

  /**
   * onDetached() -> saveChanges(): the three compact keys (an unfilled one is -1) and the five
   * slot keys, written together and flushed once - the source's single editor.apply().
   */
  aboutToDisappear(): void {
    const prefs: AppPreferences = AppPreferences.instance();
    for (let i = 0; i < SLOT_COMPACT_PREF_KEYS.length; i++) {
      prefs.putInt(SLOT_COMPACT_PREF_KEYS[i],
        i < this.compactSlots.length ? this.compactSlots[i] : COMPACT_SLOT_UNUSED);
    }
    for (let i = 0; i < SLOT_PREF_KEYS.length; i++) {
      prefs.putInt(SLOT_PREF_KEYS[i],
        i < this.slots.length ? this.slots[i].selectedAction : SLOT_DEFAULTS[i]);
    }
    prefs.flush().catch((err: Error): void => {
      hilog.error(0x0000, TAG, 'saveChanges flush: %{public}s', err.message);
    });
  }

  /** notificationActionClickableArea.setOnClickListener { openActionChooserDialog() }. */
  private openActionChooser(index: number): void {
    if (index < 0 || index >= this.slots.length) {
      return;
    }
    this.chooserSlotIndex = index;
    this.chooserTitle = this.slots[index].title;
    this.chooserSelectedAction = this.slots[index].selectedAction;
    this.actionChooserDialog.open();
  }

  /** radioButtonsClickListener: selectedAction = ALL_ACTIONS[id]; updateInfo(); dismiss(). */
  private onActionPicked(action: number): void {
    const slots: NotificationSlotState[] = this.slots.slice();
    if (this.chooserSlotIndex < slots.length) {
      const slot: NotificationSlotState = slots[this.chooserSlotIndex];
      // updateInfo(): the glyph and the summary follow the new action immediately; the WRITE
      // happens in onDetached(), never here.
      slots[this.chooserSlotIndex] = new NotificationSlotState(slot.index, slot.title, action,
        getActionName(action), this.actionIconOf(action), slot.isInCompactSlots);
      this.slots = slots;
    }
  }

  build() {
    Column() {
      if (!this.hostDrawsToolbar) {
        // toolbar_layout.xml: the Up affordance and the PreferenceScreen title
        // BasePreferenceFragment.onViewCreated pushes into the host toolbar.
        Row() {
          // The 24vp glyph centred in a 56vp (?attr/actionBarSize) target - base.ui.json puts the
          // Up button at [0,72][168,240]. The SVG ships black, so the bar's tint is applied here.
          Image($r('app.media.ic_arrow_back'))
            .id('home')
            .accessibilityText($r('app.string.navigate_back'))
            .width(56)
            .height(56)
            .padding(16)
            .objectFit(ImageFit.Contain)
            .fillColor(COLOR_ON_PRIMARY)
            .onClick(() => {
              router.back();
            })

          // Widget.AppCompat.Toolbar.Title: 20sp medium, 16vp past the navigation button (the
          // capture puts the title at x=216 of 1080 - 72vp at density 3.0).
          Text($r('app.string.settings_category_player_notification_title'))
            .layoutWeight(1)
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_ON_PRIMARY)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ left: 16 })
        }
        .width('100%')
        .height(56)
        .alignItems(VerticalAlign.Center)
        .backgroundColor(COLOR_PRIMARY)
      }

      // The preference RecyclerView (id/recycler_view in the capture); setDivider(null).
      List({ scroller: settingsListScroller }) {
        // -- SwitchPreferenceCompat: scale_to_square_image_in_notifications_key ---------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.notification_scale_to_square_image_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.notification_scale_to_square_image_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            // widget_frame: a 47x27vp switch against the row's 16vp right gutter (base.ui.json's
            // [892,333][1032,414] at density 3.0). The whole row is the one tappable control, so
            // the switch takes no touch.
            Toggle({ type: ToggleType.Switch, isOn: this.scaleToSquareImage })
              .hitTestBehavior(HitTestMode.None)
              .width(47)
              .height(27)
              .margin({ left: 16 })
              .selectedColor(COLOR_PRIMARY)
          }
          .id('scale_to_square_image_in_notifications')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.scaleToSquareImage = !this.scaleToSquareImage;
            this.persistBoolean(scale_to_square_image_in_notifications_key,
              this.scaleToSquareImage);
          })
        }

        // -- SwitchPreferenceCompat: notification_colorize_key -------------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.notification_colorize_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.notification_colorize_unavailable_note'))
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            // widget_frame: a 47x27vp switch against the row's 16vp right gutter (base.ui.json's
            // [892,333][1032,414] at density 3.0). The whole row is the one tappable control, so
            // the switch takes no touch.
            Toggle({ type: ToggleType.Switch, isOn: this.colorizeNotification })
              .hitTestBehavior(HitTestMode.None)
              .width(47)
              .height(27)
              .margin({ left: 16 })
              .selectedColor(COLOR_PRIMARY)
          }
          .id('notification_colorize_key')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.colorizeNotification = !this.colorizeNotification;
            this.persistBoolean(notification_colorize_key, this.colorizeNotification);
          })
          // The source asks Android to tint the notification from the thumbnail; the HarmonyOS
          // media controls take no colour from the app, so the row is shown disabled with why.
          .opacity(DISABLED_ALPHA)
          .enabled(false)
        }

        // -- SwitchPreferenceCompat: show_thumbnail_key --------------------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.show_thumbnail_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.show_thumbnail_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            // widget_frame: a 47x27vp switch against the row's 16vp right gutter (base.ui.json's
            // [892,333][1032,414] at density 3.0). The whole row is the one tappable control, so
            // the switch takes no touch.
            Toggle({ type: ToggleType.Switch, isOn: this.showThumbnail })
              .hitTestBehavior(HitTestMode.None)
              .width(47)
              .height(27)
              .margin({ left: 16 })
              .selectedColor(COLOR_PRIMARY)
          }
          .id('show_thumbnail_key')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.showThumbnail = !this.showThumbnail;
            this.persistBoolean(show_thumbnail_key, this.showThumbnail);
          })
        }

        // -- PreferenceCategory > NotificationActionsPreference ------------------------------
        // settings_notification.xml. One non-clickable container row, so the ListItem carries no
        // id and no handler; its five slots and their checkboxes are the tap targets.
        ListItem() {
          Column() {
            // The PreferenceCategory's own row layout, settings_category_header_layout. It carries
            // no android:title here, so androidx leaves its header TextView GONE and only the band
            // renders: decorative, no id, no handler, no bound value.
            Stack({ alignContent: Alignment.Top }) {
              Column()
                .width('100%')
                .height(5)
                .linearGradient({
                  angle: 180,
                  colors: [[COLOR_SHADOW_START, 0.0], [COLOR_SHADOW_END, 1.0]]
                })
            }
            .width('100%')
            .height(14)
            .backgroundColor(COLOR_CATEGORY_BAND)

            Divider()
              .strokeWidth(1)
              .color(COLOR_SEPARATOR)

            // @+id/summary - the source's own arm for "the system owns these actions", with the
            // wording corrected for a platform that owns all five. See SHOW_ACTION_SLOTS.
            // The capture centres it at 14sp on ?android:textColorSecondary, at the list's 16vp
            // gutter ([48,1232][1032,1436] at density 3.0).
            Text(this.notificationActionsPreferenceSummary)
              .id('summary')
              .width('100%')
              .fontSize(14)
              .lineHeight(17)
              .fontColor(COLOR_SECONDARY_TEXT)
              .textAlign(TextAlign.Center)
              .padding({ left: 16, right: 16, top: 16, bottom: 8 })

            // The five slots and their compact checkboxes - see SHOW_ACTION_SLOTS for why
            // nothing on this platform can draw them.
            if (SHOW_ACTION_SLOTS) {
              ForEach(this.slots, (slot: NotificationSlotState, index: number) => {
                // settings_notification_action.xml, included as notificationAction<i>.
                Row() {
                  // notificationActionIcon: setImageDrawable(ACTION_ICONS[selectedAction]), and
                  // setImageDrawable(null) where that entry is 0 - so the glyph is absent, not a
                  // stand-in. It stays bound until NotificationConstants is ported.
                  if (slot.actionIcon !== null) {
                    // android:layout_width="48dp", marginStart 12dp, 8dp above and below, and
                    // app:tint="?android:textColorPrimary" - the capture samples the glyph (31,31,31).
                    Image(slot.actionIcon as Resource)
                      .width(48)
                      .height(48)
                      .margin({ left: 12, top: 8, bottom: 8 })
                      .objectFit(ImageFit.Contain)
                      .fillColor(COLOR_ON_SURFACE)
                  }

                  Column() {
                    // notificationActionTitle: SLOT_TITLES[i], android:textSize="14sp", maxLines 1.
                    Text(slot.title)
                      .width('100%')
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .fontSize(14)
                      .lineHeight(19)
                      .fontColor(COLOR_ON_SURFACE)
                    // notificationActionSummary: getActionName(context, selectedAction), maxLines 1.
                    Text(slot.actionName)
                      .width('100%')
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .fontSize(14)
                      .lineHeight(19)
                      .fontColor(COLOR_SECONDARY_TEXT)
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                  // android:layout_marginStart="8dp" from notificationActionIcon. A slot whose glyph
                  // is absent keeps the 68vp text inset the capture measures, so the five titles
                  // stay aligned.
                  .margin({ left: slot.actionIcon !== null ? 8 : 68 })

                  // notificationActionCheckBox + notificationActionCheckBoxClickableArea: one tap
                  // target of its own, which is why it sits inside the slot row and takes the touch
                  // before it.
                  //
                  // The source includes ONE checkbox layout five times, so this slug is repeated by
                  // construction. Rule 12 forbids a repeated `.id()` in a page - the matcher scores
                  // every node and keeps one of the tied best, so a repeated id silently mis-taps -
                  // and its list-row exception asks for a shared id ending in `itemroot`. Both apply:
                  // every instance carries the shared `…_itemroot` id, and slot 0's tap target alone
                  // keeps the bare source slug, so the control action-contracts.json names resolves
                  // to exactly ONE node. Slot 0 is one of the three NotificationConstants ships in
                  // the compact view, so tapping it is the visible uncheck
                  // NotificationActionsPreference.java:79-91 performs, not the "at most three" toast
                  // that only a FOURTH slot raises.
                  Row() {
                    // The capture measures the box at [936,1508][1032,1604] - 32x32vp - inside a
                    // square 64vp tap area whose end sits on the list's 16vp gutter.
                    // The box itself is presentational - HitTestMode.None hands the touch to the
                    // row above - so it carries NO identity of its own: no `.id()`, and no
                    // `name`/`group` (a Checkbox `name` surfaces in the uitest dump AS TEXT, which
                    // put five more copies of the slug on screen, and one `group` shared by five
                    // same-named boxes is a collision of its own). Identity-less is REQUIRED, not
                    // just tidy: `evidence_collect.tree_signature` emits one string per node and
                    // keeps them in a SET, so five boxes sharing one id collapse to two entries
                    // (`checked=true|…`, `checked=false|…`) and BOTH survive one of them flipping -
                    // a working checkbox reads as a dead control. With no identity the box inherits
                    // its row's, and slot 0's flip registers as its own change. Its docstring
                    // prescribes exactly this shape for a Rule-12 row control.
                    Checkbox()
                      .select(index < this.compactSlotCheckboxes.length
                        ? this.compactSlotCheckboxes[index] : slot.isInCompactSlots)
                      .hitTestBehavior(HitTestMode.None)
                      .width(24)
                      .height(24)
                      .shape(CheckBoxShape.ROUNDED_SQUARE)
                      .selectedColor(COLOR_PRIMARY)
                      .unselectedColor(COLOR_CHECKBOX_UNSELECTED)
                  }
                  .id(index === 0 ? 'notification_slot_compact_checkbox'
                    : 'notification_slot_compact_checkbox_itemroot')
                  .width(64)
                  .height(64)
                  .justifyContent(FlexAlign.Center)
                  .alignItems(VerticalAlign.Center)
                  .onClick(() => {
                    this.onToggleCompactSlot(index);
                  })
                }
                // The <include>'s own id: notificationAction0..4. notificationActionClickableArea
                // covers everything but the checkbox, so the slot row carries the chooser click.
                .id(SLOT_IDS[index])
                .width('100%')
                // The icon's 48dp + 8dp above and below is the row's height; the capture measures
                // each slot at 192px = 64vp.
                .constraintSize({ minHeight: 64 })
                .alignItems(VerticalAlign.Center)
                .onClick(() => {
                  this.openActionChooser(index);
                })
              }, (slot: NotificationSlotState) => `${slot.index}-${slot.selectedAction}-${slot.isInCompactSlots}`)
            }
          }
          .width('100%')
        }
      }
      .width('100%')
      .layoutWeight(1)
      // setDivider(null): the list carries no separators and no surface of its own.
      .divider(null)
      .backgroundColor(themedBackground(this.blackTheme))
    }
    .id('PlayerNotificationSettingsFragmentPage')
    .width('100%')
    .height('100%')
    .backgroundColor(themedBackground(this.blackTheme))
  }

  /**
   * onToggleCompactSlot(i, checkBox): unchecking removes the index; checking adds it only while
   * compactSlots.size() < 3, otherwise Toast(notification_actions_at_most_three) and the checkbox
   * is NOT toggled. That refusal is the plan's conditionalVariant bound to `compactSlots`.
   */
  private onToggleCompactSlot(index: number): void {
    const compact: number[] = this.compactSlots.slice();
    const at: number = compact.indexOf(index);
    if (at >= 0) {
      compact.splice(at, 1);
    } else if (this.compactSlots.length < MAX_COMPACT_SLOTS) {
      compact.push(index);
    } else {
      this.toast($r('app.string.notification_actions_at_most_three'));
      return;
    }
    this.compactSlots = compact;
    const checkboxes: boolean[] = [];
    const slots: NotificationSlotState[] = this.slots.slice();
    for (let i = 0; i < slots.length; i++) {
      const inCompact: boolean = compact.indexOf(slots[i].index) >= 0;
      checkboxes.push(inCompact);
      slots[i] = new NotificationSlotState(slots[i].index, slots[i].title, slots[i].selectedAction,
        slots[i].actionName, slots[i].actionIcon, inCompact);
    }
    this.compactSlotCheckboxes = checkboxes;
    this.slots = slots;
  }

  /** Toast.makeText(getContext(), resId, Toast.LENGTH_SHORT).show(). */
  private toast(message: Resource): void {
    promptAction.showToast({ message: message, duration: TOAST_SHORT_MS });
  }
}
