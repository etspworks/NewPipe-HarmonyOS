/*
 * S3 - port of NotificationModeConfigAdapter (item_notification_config.xml).
 *
 * ListAdapter<SubscriptionItem, SubscriptionHolder> over the fragment's currentList:
 *   update(newData)                       -> toNotificationItems() + NotificationConfigDataSource,
 *   onCreateViewHolder/onBindViewHolder   -> the row below,
 *   SubscriptionHolder.init { onClick }   -> onModeChange(position, mode), raised to the page.
 *
 * item_notification_config.xml is a BARE CheckedTextView whose checkmark is
 * android:drawableEnd=?android:listChoiceIndicatorMultiple - the ROW IS THE TOGGLE, there is no
 * separate switch view, so the row carries the only .onClick and the indicator is a drawable.
 *
 * The adapter OWNS no state: the fragment owns the list and the database write, so a tap is a
 * callback up to the page (source: listener.onModeChange -> updateNotificationMode -> DB).
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { SubscriptionEntity } from '../model/db/entity/SubscriptionEntity';
import { NotificationMode } from '../model/enums/NotificationMode';

/* //////////////////////////////////////////////////////////////////////////
// S5 tokens - measured off this screen's two captures (density 3.0).
// Row [0,240][1080,384] = 48vp; label #1F1F1F over the #EEEEEE page; the
// ?android:listChoiceIndicatorMultiple box is 18vp at [957,285][1010,338] in
// BOTH states - a 2vp #6D6D6D outline unchecked, filled #E53935 with the tick
// knocked out in the page colour when checked.
////////////////////////////////////////////////////////////////////////// */
const COLOR_PRIMARY: ResourceColor = $r('app.color.primary');
const COLOR_SURFACE: ResourceColor = $r('app.color.background');
/** The unchecked box has no fill; typed alongside COLOR_PRIMARY so the ternary stays one type. */
const COLOR_UNFILLED: ResourceColor = Color.Transparent;
const COLOR_ON_SURFACE: ResourceColor = $r('app.color.on_surface');
/** The framework checkbox's unchecked stroke: #6D6D6D over #EEEEEE in the capture. */
const COLOR_CHECKBOX_OUTLINE: ResourceColor = $r('app.color.on_surface_variant');

/**
 * Port of the adapter file's own `data class SubscriptionItem(id, title, notificationMode,
 * serviceId, url)`. NOT model/app/SubscriptionData's SubscriptionItem - that one is the
 * import/export payload (serviceId, url, name), a different type in the source too.
 */
export class NotificationSubscriptionItem {
  readonly id: number;
  readonly title: string;
  readonly notificationMode: NotificationMode;
  readonly serviceId: number;
  readonly url: string;

  constructor(id: number, title: string, notificationMode: NotificationMode, serviceId: number,
    url: string) {
    this.id = id;
    this.title = title;
    this.notificationMode = notificationMode;
    this.serviceId = serviceId;
    this.url = url;
  }

  /** The row's checked state: `data.notificationMode != NotificationMode.DISABLED`. */
  isChecked(): boolean {
    return this.notificationMode !== NotificationMode.DISABLED;
  }

  /** submitList() replaces items rather than mutating them, exactly as DiffUtil expects. */
  withMode(mode: NotificationMode): NotificationSubscriptionItem {
    return new NotificationSubscriptionItem(this.id, this.title, mode, this.serviceId, this.url);
  }
}

/**
 * Port of update(newData): `newData.map { SubscriptionItem(it.uid, it.name!!,
 * it.notificationMode, it.serviceId, it.url!!) }`. The two non-null asserted fields are nullable
 * columns here, so an empty string stands in rather than crashing the list.
 */
export function toNotificationItems(newData: SubscriptionEntity[]): NotificationSubscriptionItem[] {
  return newData.map((entity: SubscriptionEntity): NotificationSubscriptionItem =>
    new NotificationSubscriptionItem(entity.uid, entity.name ?? '', entity.notificationMode,
      entity.serviceId, entity.url ?? ''));
}

/** getItemCount()/getItem(position) over currentList, as the LazyForEach source. */
export class NotificationConfigDataSource implements IDataSource {
  private items: NotificationSubscriptionItem[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): NotificationSubscriptionItem {
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

  /** submitList(items): the page owns the list and re-submits after every change. */
  submitList(items: NotificationSubscriptionItem[]): void {
    this.items = items;
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataReloaded();
    });
  }
}

@Component
export struct NotificationModeConfigAdapter {
  dataSource: NotificationConfigDataSource = new NotificationConfigDataSource();
  /** `itemBinding.root.text = data.title` per row, index-parallel with the submitted list. */
  @Prop rowLabel: string[] = [];
  /** `itemBinding.root.isChecked = data.notificationMode != DISABLED` per row. */
  @Prop rowCheckedState: boolean[] = [];
  /** ModeToggleListener.onModeChange(position, mode) -> the page's updateNotificationMode(). */
  onModeChange: (position: number, mode: NotificationMode) => void =
    (position: number, mode: NotificationMode): void => {
      hilog.debug(0x0000, 'NewPipe',
        'NotificationModeConfigAdapter: onModeChange not bound (%{public}d)', position);
    };

  build() {
    List() {
      LazyForEach(this.dataSource, (item: NotificationSubscriptionItem, index: number) => {
        ListItem() {
          Row() {
            // The CheckedTextView's own text: maxLines 2, ellipsize end.
            // textAppearanceListItemSmall - 16sp regular at the primary text alpha.
            Text(index < this.rowLabel.length ? this.rowLabel[index] : item.title)
              .fontSize(16)
              .fontColor(COLOR_ON_SURFACE)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)

            // android:drawableEnd=?android:listChoiceIndicatorMultiple - a DRAWABLE on the row,
            // never a second tap target, so it takes no .onClick and no .id(). The framework
            // draws it as a box in BOTH states, so it is drawn here rather than hidden: an 18vp
            // 2vp-stroke outline unchecked, filled colorAccent with a knocked-out tick when
            // checked (the tick reads as the page colour because the drawable masks it out).
            Stack() {
              Image($r('app.media.ic_done'))
                .width(14)
                .height(14)
                .objectFit(ImageFit.Contain)
                .fillColor(COLOR_SURFACE)
                // bind(data): `root.isChecked = data.notificationMode != DISABLED`.
                .visibility(item.notificationMode !== NotificationMode.DISABLED
                  ? Visibility.Visible
                  : Visibility.Hidden)
            }
            .width(18)
            .height(18)
            .borderRadius(2)
            .borderWidth(item.notificationMode !== NotificationMode.DISABLED ? 0 : 2)
            .borderColor(COLOR_CHECKBOX_OUTLINE)
            .backgroundColor(item.notificationMode !== NotificationMode.DISABLED
              ? COLOR_PRIMARY
              : COLOR_UNFILLED)
          }
          // Rule 12 list-row exception: every instance shares one id, resolved by index at replay.
          .id('notification_config_itemroot')
          // The source row IS a CheckedTextView, so its dump node carries checkable/checked and
          // the two captures of this screen differ by exactly that (chk=false in base, chk=true
          // in menu_action_toggle_all). A plain ArkUI Row carries neither, which left the flip
          // invisible to every reader of the element tree - the tick above is a colour change and
          // colour is in no dump. That is the whole evidence a tap has an effect: the sweep builds
          // its before/after signature from text/id/checked/selected/enabled only, so a working
          // toggle would have read as a dead control. This mirrors the source attribute, and is
          // NOT a second tap target: no .onClick and no id of its own (it sets checkable on THIS
          // row root, which already carries both). Multi-select is the right one of the pair -
          // ?android:listChoiceIndicatorMultiple - so accessibilitySelected stays unset.
          .accessibilityChecked(item.notificationMode !== NotificationMode.DISABLED)
          .width('100%')
          // ?listPreferredItemHeightSmall, ?listPreferredItemPaddingStart/End, center_vertical.
          // paddingEnd is 20dp here plus the 3dp the 24dp indicator drawable insets its own 18dp
          // box: the capture puts that box's right edge at 1010 of 1080, i.e. 336.7vp.
          .height(48)
          .padding({ left: 16, right: 23 })
          .alignItems(VerticalAlign.Center)
          // SubscriptionHolder.init: mode = if (root.isChecked) DISABLED else ENABLED.
          .onClick((): void => {
            // `val mode = if (itemBinding.root.isChecked) DISABLED else ENABLED` - root.isChecked
            // is the page's index-parallel projection of the same bound mode bind() renders.
            this.onModeChange(index,
              index < this.rowCheckedState.length && this.rowCheckedState[index]
                ? NotificationMode.DISABLED
                : NotificationMode.ENABLED);
          })
        }
      }, (item: NotificationSubscriptionItem) => `${item.id}-${item.notificationMode}`)
    }
    .id('recycler_view')
    .scrollBar(BarState.Auto)
    .width('100%')
    .height('100%')
  }
}
