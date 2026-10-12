/**
 * S3 - NotificationModeConfigFragment (screen_notification_mode_config).
 *
 * NOT a PreferenceFragment: a plain Fragment over fragment_channels_notifications.xml, whose whole
 * body is one RecyclerView (@+id/recycler_view). hostedBy screen_settings_activity, which PUSHES
 * this page - SettingsActivityPage carries that push. No navOut.
 *
 * The row (item_notification_config.xml) is a bare CheckedTextView whose checkmark is
 * android:drawableEnd=?android:listChoiceIndicatorMultiple - the ROW IS THE TOGGLE, there is no
 * separate switch. Its id already ends in itemroot (notification_config_itemroot), so every
 * instance deliberately shares it: Rule 12's list-row exception, resolved by index at replay.
 *
 * The list is fed by SubscriptionManager.subscriptions() (svc_subscription_manager) and rendered
 * with LazyForEach + IDataSource. action_toggle_all reads the FIRST item's mode and flips every
 * row to ENABLED/DISABLED through updateNotificationMode(serviceId, url, mode).
 *
 * ponytail: the source's live re-emit is Room's Flowable, free there and not here. Only this
 * screen writes these rows while it is on top, so a write updates the submitted list in place
 * instead of subscribing to SubscriptionManager.changes and reloading the whole table.
 *
 * There is NO empty state in the source layout: with no subscriptions the screen renders a blank
 * RecyclerView. A correctness gate must not read empty-list here as a defect without first checking
 * the subscription table.
 */

import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

import { SubscriptionManager } from '../common/db/SubscriptionManager';
import { SubscriptionEntity } from '../model/db/entity/SubscriptionEntity';
import { NotificationMode } from '../model/enums/NotificationMode';
import {
  NotificationConfigDataSource,
  NotificationModeConfigAdapter,
  NotificationSubscriptionItem,
  toNotificationItems
} from '../components/NotificationModeConfigAdapter';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

const TAG: string = 'NotificationModeConfigFragment';

/* //////////////////////////////////////////////////////////////////////////
// S5 tokens - the run's frozen style baseline, read off this screen's capture.
// toolbar #E53935 / white content, page #EEEEEE, 56vp bar, 72vp title inset.
////////////////////////////////////////////////////////////////////////// */
const COLOR_PRIMARY: Resource = $r('app.color.primary');
const COLOR_ON_PRIMARY: Resource = $r('app.color.on_primary');
const COLOR_SURFACE: Resource = $r('app.color.background');

@Entry
@Component
export struct NotificationModeConfigFragmentPage {
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
  /** adapter.currentList: SubscriptionEntity rows mapped by update(newData). */
  @State channelList: NotificationSubscriptionItem[] = [];
  /** `itemBinding.root.text = data.title` per row, index-parallel with channelList. */
  @State rowLabel: string[] = [];
  /** `itemBinding.root.isChecked = data.notificationMode != DISABLED` per row. */
  @State rowCheckedState: boolean[] = [];
  /** adapter.currentList.firstOrNull()?.notificationMode - what toggleAll() branches on. */
  @State notificationMode: NotificationMode = NotificationMode.DISABLED;
  /** subscriptionManager.subscriptions() is read off the database before the list exists. */
  @State isLoading: boolean = false;
  /** ErrorPanelHelper/ErrorUtil equivalent: set when a database read or write failed. */
  @State errorInfo: string = '';

  /** getItemCount()/getItem(position): what LazyForEach reads. */
  private dataSource: NotificationConfigDataSource = new NotificationConfigDataSource();
  /** onAttach(): subscriptionManager = SubscriptionManager(context). */
  private subscriptionManager: SubscriptionManager | null = null;

  aboutToAppear(): void {
    this.loadSubscriptions();
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Data: subscriptionManager.subscriptions() -> adapter.update(newData)
  ////////////////////////////////////////////////////////////////////////// */

  private async ensureManager(): Promise<SubscriptionManager | null> {
    const existing: SubscriptionManager | null = this.subscriptionManager;
    if (existing !== null) {
      return existing;
    }
    try {
      const context: common.Context = getContext(this) as common.Context;
      const manager: SubscriptionManager = await SubscriptionManager.of(context);
      this.subscriptionManager = manager;
      return manager;
    } catch (err) {
      this.showError(err as BusinessError);
      return null;
    }
  }

  /** loader = subscriptionManager.subscriptions().observeOn(main).subscribe(adapter::update). */
  private async loadSubscriptions(): Promise<void> {
    this.isLoading = true;
    this.errorInfo = '';
    try {
      const manager: SubscriptionManager | null = await this.ensureManager();
      if (manager === null) {
        return;
      }
      const entities: SubscriptionEntity[] = await manager.subscriptions();
      if (entities.length === 0) {
        // fragment_channels_notifications.xml has NO empty state: with no subscriptions the
        // source renders a blank RecyclerView. INFO, never error - an empty table is not a
        // failure and must not read as a crash.
        hilog.info(0x0000, 'NewPipe', '%{public}s: no subscribed channels to configure', TAG);
      }
      this.submitList(toNotificationItems(entities));
    } catch (err) {
      this.showError(err as BusinessError);
    } finally {
      this.isLoading = false;
    }
  }

  /** adapter.submitList(items): the list and its two index-parallel projections. */
  private submitList(items: NotificationSubscriptionItem[]): void {
    this.channelList = items;
    this.rowLabel = items.map((item: NotificationSubscriptionItem): string => item.title);
    this.rowCheckedState =
      items.map((item: NotificationSubscriptionItem): boolean => item.isChecked());
    // firstOrNull()?.notificationMode - the value toggleAll() reads.
    this.notificationMode =
      items.length === 0 ? NotificationMode.DISABLED : items[0].notificationMode;
    this.dataSource.submitList(items);
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Writes: subscriptionManager.updateNotificationMode(serviceId, url, mode)
  ////////////////////////////////////////////////////////////////////////// */

  /**
   * `disposables.add(subscriptionManager.updateNotificationMode(item.serviceId, item.url, mode)
   * .subscribeOn(Schedulers.io()).subscribe())` - for the tapped row, or for every row of
   * toggleAll().
   *
   * The rows flip FIRST because that is what the source does: its checked state comes from Room
   * re-emitting after `subscriptionTable().update(entity)`, which lands BEFORE the
   * rememberAllStreams() network work the enable path then does. Waiting on the write would
   * leave the tap looking dead for as long as that runs. A failed write re-reads the database
   * rather than guessing; the database stays the truth across a force-stop, since
   * aboutToAppear() re-reads it.
   */
  private async persist(items: NotificationSubscriptionItem[],
    mode: NotificationMode): Promise<void> {
    const previous: NotificationSubscriptionItem[] = this.channelList;
    this.applyMode(items, mode);
    const manager: SubscriptionManager | null = await this.ensureManager();
    if (manager === null) {
      this.submitList(previous);
      return;
    }
    try {
      for (const item of items) {
        await manager.updateNotificationMode(item.serviceId, item.url, mode);
      }
    } catch (err) {
      // Re-read the database rather than reverting to `previous`: the DATABASE is what survives
      // the force-stop the contract is checked across, so it is the only thing that can say what
      // the tap actually did. A blind revert threw away rows that HAD committed - enabling
      // writes the row FIRST and only then does the rememberAllStreams() network work, so one
      // offline channel put every already-written channel back to its old checkmark, leaving the
      // screen disagreeing with the row that comes back on relaunch. Reverting is also more than
      // the source does: its `.subscribe()` has no error arm and never repaints.
      hilog.error(0x0000, 'NewPipe', '%{public}s: updateNotificationMode failed: %{public}s',
        TAG, (err as BusinessError).message);
      this.loadSubscriptions();
    }
  }

  /** What Room's re-emit does for the source: every written row rebinds with its new mode. */
  private applyMode(items: NotificationSubscriptionItem[], mode: NotificationMode): void {
    const ids: number[] = items.map((item: NotificationSubscriptionItem): number => item.id);
    this.submitList(this.channelList.map(
      (item: NotificationSubscriptionItem): NotificationSubscriptionItem =>
      ids.indexOf(item.id) >= 0 ? item.withMode(mode) : item));
  }

  /**
   * toggleAll(): `val mode = currentList.firstOrNull()?.notificationMode ?: return`, then every
   * channel to ENABLED if that first mode is DISABLED and to DISABLED for any other mode.
   */
  private toggleAll(): void {
    // firstOrNull() is null on an empty list, and the elvis `?: return` stops there.
    if (this.channelList.length === 0) {
      return;
    }
    const newMode: NotificationMode = this.notificationMode === NotificationMode.DISABLED
      ? NotificationMode.ENABLED
      : NotificationMode.DISABLED;
    this.persist(this.channelList.slice(), newMode);
  }

  private showError(err: BusinessError): void {
    this.errorInfo = err.message;
    hilog.error(0x0000, 'NewPipe', '%{public}s: %{public}s', TAG, err.message);
  }

  build() {
    Column() {
      if (!this.hostDrawsToolbar) {
        // The activity toolbar: navigate-up, the title, and the menu action.
        Row() {
          // The 24dp glyph centred in a 56dp (?attr/actionBarSize) target; the SVG ships with a
          // black fill, so the toolbar's ?attr/actionColor tint is applied here.
          Image($r('app.media.ic_arrow_back'))
            .id('navigate_up')
            .accessibilityText($r('app.string.navigate_back'))
            .width(56)
            .height(56)
            .padding(16)
            .objectFit(ImageFit.Contain)
            .fillColor(COLOR_ON_PRIMARY)
            .onClick((): void => {
              router.back();
            })

          // The pushing Preference's android:title=@string/channels.
          // Widget.AppCompat.Toolbar.Title: 20sp medium, 16dp past the navigation button
          // (base.ui.json puts the title at x=216 of 1080 - 72vp at density 3.0).
          Text($r('app.string.channels'))
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_ON_PRIMARY)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ left: 16 })
            .layoutWeight(1)

          // menu_notifications_channels.xml: action_toggle_all, ic_checklist, showAsAction ifRoom.
          // A 48dp action item, flush to the bar's end (capture: [936,84][1080,228] at density 3.0).
          Image($r('app.media.ic_checklist'))
            .id('action_toggle_all')
            .accessibilityText($r('app.string.toggle_all'))
            .width(48)
            .height(48)
            .padding(12)
            .objectFit(ImageFit.Contain)
            .fillColor(COLOR_ON_PRIMARY)
            .onClick((): void => {
              this.toggleAll();
            })
        }
        .width('100%')
        .height(56)
        .alignItems(VerticalAlign.Center)
        .backgroundColor(COLOR_PRIMARY)
      }

      // The error panel's state: set when a database read or write failed, empty otherwise.
      if (this.errorInfo.length > 0) {
        Text(this.errorInfo)
          .fontSize(14)
          .fontColor(COLOR_PRIMARY)
          .textAlign(TextAlign.Center)
          .width('100%')
          .padding({ left: 16, right: 16 })
          .margin({ top: 8 })
      }

      // fragment_channels_notifications.xml: the RecyclerView fills the FrameLayout.
      Column() {
        if (this.isLoading) {
          LoadingProgress()
            .width(48)
            .height(48)
            .color(COLOR_PRIMARY)
            .margin({ top: 24 })
        } else {
          NotificationModeConfigAdapter({
            dataSource: this.dataSource,
            rowLabel: this.rowLabel,
            rowCheckedState: this.rowCheckedState,
            onModeChange: (position: number, mode: NotificationMode): void => {
              // updateNotificationMode(adapter.currentList[position], mode)
              if (position >= 0 && position < this.channelList.length) {
                this.persist([this.channelList[position]], mode);
              }
            }
          })
        }
      }
      .width('100%')
      .layoutWeight(1)
    }
    .id('NotificationModeConfigFragmentPage')
    .width('100%')
    .height('100%')
    .backgroundColor(themedBackground(this.blackTheme))
  }
}
