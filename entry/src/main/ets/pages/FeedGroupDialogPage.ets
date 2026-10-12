/**
 * S3 — FeedGroupDialog (screen_feed_group_dialog). presentation: modal.
 *
 * NOT a routed page: it is an OVERLAY mounted by its hostScreen screen_subscription
 * (SubscriptionFragmentPage) through FeedGroupDialogHost, a CustomDialogController - the source is a
 * DialogFragment, so a sheet would be the wrong presentation. Its routeTable row exists for the
 * skeleton contract only and must never be pushed; it is deliberately absent from main_pages.json.
 *
 * ONE dialog that is FOUR screens (FeedGroupDialog.ScreenState: InitialScreen, IconPickerScreen,
 * SubscriptionsPickerScreen, DeleteScreen), switched by showScreen() toggling view visibility -
 * there is no navigation between them, and the SAME confirm and cancel buttons change meaning per
 * screen. showScreen() verbatim (FeedGroupDialog.kt:438-460):
 *   options_root          onlyVisibleIn(InitialScreen)
 *   icon_selector         onlyVisibleIn(IconPickerScreen)
 *   subscriptions_selector onlyVisibleIn(SubscriptionsPickerScreen)
 *   delete_screen_message onlyVisibleIn(DeleteScreen)
 *   separator             onlyVisibleIn(SubscriptionsPickerScreen, IconPickerScreen)
 *   cancel_button         onlyVisibleIn(InitialScreen, DeleteScreen)
 *   confirm_button text   = create iff InitialScreen && groupId == NO_GROUP_SELECTED, else ok
 *   delete_button isGone  = currentScreen != InitialScreen || groupId == NO_GROUP_SELECTED
 * S3 builds that as ONE `if` chain over currentScreen plus the two visibility guards, so the
 * branches are real conditionals and not a flattened layout.
 *
 *   - cancel_button : InitialScreen -> dismiss(); otherwise showScreen(InitialScreen).
 *   - confirm_button: InitialScreen -> handlePositiveButtonInitialScreen() (validate: blank name
 *     -> group_name_input_container error feed_group_dialog_empty_name; empty selection ->
 *     Toast(feed_group_dialog_empty_selection); then createGroup or updateGroup);
 *     DeleteScreen -> viewModel.deleteGroup(); SubscriptionsPickerScreen with the search open ->
 *     hideSearch(); otherwise showScreen(InitialScreen).
 *   - onBackPressed(): search open on the picker screen -> hideSearch(); any non-initial screen ->
 *     showScreen(InitialScreen); only then does Back close the dialog. S4 wires that into the
 *     host's onBackPress.
 *
 * Used for BOTH create (newInstance()) and edit (newInstance(groupId)) from SubscriptionFragment,
 * hence the groupId @Prop: NO_GROUP_SELECTED (-1) means create.
 *
 * S4 binds the two grids to the FeedGroupDialogViewModel equivalent over svc_subscription_manager
 * / svc_database - the subscription grid is filtered by subscriptionsCurrentSearchQuery and
 * subscriptionsShowOnlyUngrouped, never a literal list. S5 owns every colour, size and glyph.
 */
import { common } from '@kit.AbilityKit';
import { display, promptAction } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FeedGroupIcon, feedGroupIconDrawable, feedGroupIconValues } from '../model/enums/FeedGroupIcon';
import { FeedGroupEntity } from '../model/db/entity/FeedGroupEntity';
import { FeedDatabase } from '../common/feed/FeedLoader';
import { SubscriptionManager } from '../common/db/SubscriptionManager';
import { SubscriptionEntity } from '../model/db/entity/SubscriptionEntity';
import { mediaByName } from '../components/SelectedTabsAdapter';
import { PickerIconItem } from '../components/PickerIconItem';
import { PickerSubscriptionItem } from '../components/PickerSubscriptionItem';
import { Localization } from '../common/i18n/Localization';
import {
  ImportSubscriptionsHintPlaceholderItem
} from '../components/ImportSubscriptionsHintPlaceholderItem';

const TAG: string = 'FeedGroupDialogPage';

/** FeedGroupDialog.ScreenState. */
export enum FeedGroupDialogScreen {
  INITIAL,
  ICON_PICKER,
  SUBSCRIPTIONS_PICKER,
  DELETE
}

/** NO_GROUP_SELECTED: the dialog is creating a new group rather than editing one. */
export const NO_GROUP_SELECTED: number = -1;

/**
 * subscriptionMainSection: the picker cells. tools:itemCount is 200 and a real account has more,
 * so Rule 7 applies - LazyForEach over an IDataSource, not ForEach.
 */
class PickerSubscriptionDataSource implements IDataSource {
  private items: SubscriptionEntity[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): SubscriptionEntity {
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

  isEmpty(): boolean {
    return this.items.length === 0;
  }

  /** subscriptionMainSection.update(subscriptions, false). */
  setItems(items: SubscriptionEntity[]): void {
    this.items = items;
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataReloaded();
    });
  }
}

/** The reference's popup menus are flat square rectangles, not ArkUI bubbles. */
const SQUARE_MENU_CORNERS: MenuOptions = { borderRadius: 0 };

/**
 * A share of the window's height in vp. The card is a CustomDialogController's content, and a
 * dialog has no parent height for a percentage to resolve against.
 */
function windowHeightVp(context: UIContext, fraction: number): string {
  return (context.px2vp(display.getDefaultDisplaySync().height) * fraction).toString() + 'vp';
}

@Component
export struct FeedGroupDialogPage {
  /** Two-way with the host's visibility flag so cancel/confirm can dismiss the cover. */
  @Link isShown: boolean;
  /** newInstance(groupId) from the host; mirrored into the mutable groupId below. */
  @Prop @Watch('onIncomingGroupId') incomingGroupId: number = NO_GROUP_SELECTED;
  /**
   * subscriptionsLiveData: SubscriptionManager.getSubscriptions(groupId, query,
   * showOnlyUngrouped). Loaded from the DB, never a literal.
   */
  @Prop subscriptionPickerGrid: SubscriptionEntity[] = [];
  /** groupAdapter.addAll(FeedGroupIcon.entries.map { PickerIconItem(it) }) - static. */
  @Prop iconPickerGrid: FeedGroupIcon[] = feedGroupIconValues();
  /** viewModel.groupLiveData; null while creating (handleGroup(null)). */
  @Prop groupNameAndIcon: FeedGroupEntity | null = null;
  /** feed_group_dialog_selection_count: selectedSubscriptions.size. */
  @Prop selectionCount: number = 0;
  /** FeedGroupDialog.currentScreen (ScreenState). */
  @State groupId: number = NO_GROUP_SELECTED;
  @State currentScreen: FeedGroupDialogScreen = FeedGroupDialogScreen.INITIAL;
  /** Bound to viewModel.groupLiveData; empty here, never a captured literal. */
  @State groupName: string = '';
  /** selectedIcon, defaulting to FeedGroupIcon.ALL for a new group (setupIconPicker()). */
  @State selectedIcon: FeedGroupIcon = FeedGroupIcon.ALL;
  /** selectedSubscriptions: the uid set the two grids and the count label all read. */
  @State selectedUids: number[] = [];
  @State searchVisible: boolean = false;
  @State searchQuery: string = '';
  @State showOnlyUngrouped: boolean = false;
  /** group_name_input_container.error - set only by handlePositiveButtonInitialScreen(). */
  @State nameError: string = '';
  @State isLoading: boolean = true;
  @State errorInfo: string | null = null;
  /** DialogEvent.ProcessingEvent -> disableInput(): the three buttons go disabled. */
  @State isProcessing: boolean = false;

  private subscriptionSource: PickerSubscriptionDataSource = new PickerSubscriptionDataSource();
  private subscriptionManager: SubscriptionManager | null = null;
  private feedDatabase: FeedDatabase | null = null;
  /** groupSortOrder, carried into updateGroup() so the row keeps its place. */
  private groupSortOrder: number = -1;
  /**
   * wasSubscriptionSelectionChanged: once a tile has been touched, a later DB emission must not
   * overwrite the selection (FeedGroupDialog.kt subscriptionsLiveData observer).
   */
  private wasSubscriptionSelectionChanged: boolean = false;

  aboutToAppear(): void {
    this.groupId = this.incomingGroupId;
    this.load();
  }

  /** A reopen with a different groupId while the struct is still alive. */
  private onIncomingGroupId(): void {
    this.groupId = this.incomingGroupId;
    this.wasSubscriptionSelectionChanged = false;
    this.load();
  }

  /* //////////////////////////////////////////////////////////////////////////
  // FeedGroupDialogViewModel — the two flowables and the three actions
  ////////////////////////////////////////////////////////////////////////// */

  private context(): common.Context {
    return getContext(this) as common.Context;
  }

  private async ensureServices(): Promise<SubscriptionManager | null> {
    const existing: SubscriptionManager | null = this.subscriptionManager;
    if (existing !== null) {
      return existing;
    }
    try {
      const context: common.Context = this.context();
      const manager: SubscriptionManager = await SubscriptionManager.of(context);
      this.feedDatabase = await FeedDatabase.of(context);
      this.subscriptionManager = manager;
      return manager;
    } catch (err) {
      this.errorInfo = (err as BusinessError).message;
      this.isLoading = false;
      return null;
    }
  }

  /** feedGroupDisposable + subscriptionsDisposable: the group row, then the picker grid. */
  private async load(): Promise<void> {
    this.isLoading = true;
    if (await this.ensureServices() === null) {
      return;
    }
    await this.loadGroup();
    await this.loadSubscriptions();
    this.isLoading = false;
  }

  /** handleGroup(feedGroupEntity): icon preview, and the name only while the field is blank. */
  private async loadGroup(): Promise<void> {
    const database: FeedDatabase | null = this.feedDatabase;
    if (database === null || this.groupId === NO_GROUP_SELECTED) {
      this.groupNameAndIcon = null;
      this.groupSortOrder = -1;
      return;
    }
    try {
      const group: FeedGroupEntity | null = await database.getGroup(this.groupId);
      this.groupNameAndIcon = group;
      if (group !== null) {
        this.groupSortOrder = group.sortOrder;
        this.selectedIcon = group.icon;
        if (this.groupName.trim().length === 0) {
          this.groupName = group.name;
        }
      }
      // subscriptionIdsForGroup(groupId) seeds the selection, but only while the user has not
      // touched a tile yet.
      if (!this.wasSubscriptionSelectionChanged) {
        this.selectedUids = await database.subscriptionIdsForGroup(this.groupId);
        this.selectionCount = this.selectedUids.length;
      }
    } catch (err) {
      this.errorInfo = (err as BusinessError).message;
    }
  }

  /** getSubscriptions(groupId, subscriptionsCurrentSearchQuery, subscriptionsShowOnlyUngrouped). */
  private async loadSubscriptions(): Promise<void> {
    const manager: SubscriptionManager | null = this.subscriptionManager;
    if (manager === null) {
      return;
    }
    try {
      const items: SubscriptionEntity[] =
        await manager.getSubscriptions(this.groupId, this.searchQuery, this.showOnlyUngrouped);
      this.subscriptionPickerGrid = items;
      this.subscriptionSource.setItems(items);
    } catch (err) {
      this.errorInfo = (err as BusinessError).message;
    }
  }

  /** doAction(): ProcessingEvent while it runs, SuccessEvent -> dismiss(). */
  private async doAction(action: Promise<void>): Promise<void> {
    if (this.isProcessing) {
      return;
    }
    this.isProcessing = true;
    try {
      await action;
      this.isShown = false;
    } catch (err) {
      this.errorInfo = (err as BusinessError).message;
      hilog.error(0x0000, TAG, 'dialog action failed: %{public}s', (err as BusinessError).message);
    } finally {
      this.isProcessing = false;
    }
  }

  /** viewModel.createGroup(name, icon, selectedSubscriptions). */
  private async createGroup(name: string, icon: FeedGroupIcon): Promise<void> {
    const database: FeedDatabase | null = this.feedDatabase;
    if (database === null) {
      return;
    }
    const newId: number = await database.createGroup(name, icon);
    await database.updateSubscriptionsForGroup(newId, this.selectedUids);
  }

  /** viewModel.updateGroup(name, icon, selectedSubscriptions, groupSortOrder). */
  private async updateGroup(name: string, icon: FeedGroupIcon): Promise<void> {
    const database: FeedDatabase | null = this.feedDatabase;
    if (database === null) {
      return;
    }
    await database.updateSubscriptionsForGroup(this.groupId, this.selectedUids);
    const entity: FeedGroupEntity = new FeedGroupEntity(this.groupId, name, icon);
    entity.sortOrder = this.groupSortOrder;
    await database.updateGroup(entity);
  }

  /** handlePositiveButtonInitialScreen() verbatim, including both validation exits. */
  private handlePositiveButtonInitialScreen(): void {
    const name: string = this.groupName.trim();
    const icon: FeedGroupIcon = this.selectedIcon;

    if (name.length === 0) {
      // groupNameInputContainer.error; the field is cleared and re-focused; NOTHING is saved.
      this.nameError = this.stringOf($r('app.string.feed_group_dialog_empty_name'));
      this.groupName = '';
      return;
    }
    this.nameError = '';

    if (this.selectedUids.length === 0) {
      this.toast($r('app.string.feed_group_dialog_empty_selection'));
      return;
    }

    if (this.groupId === NO_GROUP_SELECTED) {
      this.doAction(this.createGroup(name, icon));
    } else {
      this.doAction(this.updateGroup(name, icon));
    }
  }

  /** handlePositiveButton(): the same button means four different things. */
  private handlePositiveButton(): void {
    if (this.currentScreen === FeedGroupDialogScreen.INITIAL) {
      this.handlePositiveButtonInitialScreen();
    } else if (this.currentScreen === FeedGroupDialogScreen.DELETE) {
      this.doAction(this.deleteGroup());
    } else if (this.currentScreen === FeedGroupDialogScreen.SUBSCRIPTIONS_PICKER
      && this.searchVisible) {
      this.hideSearch();
    } else {
      this.currentScreen = FeedGroupDialogScreen.INITIAL;
    }
  }

  /** viewModel.deleteGroup(). */
  private async deleteGroup(): Promise<void> {
    const database: FeedDatabase | null = this.feedDatabase;
    if (database === null) {
      return;
    }
    await database.deleteGroup(this.groupId);
  }

  /** hideSearch(): the query is cleared and the grid re-queried without a filter. */
  private hideSearch(): void {
    this.searchVisible = false;
    this.searchQuery = '';
    this.loadSubscriptions();
  }

  private toast(message: Resource): void {
    promptAction.showToast({ message: message, duration: 2000 });
  }

  private stringOf(resource: Resource): string {
    try {
      return this.context().resourceManager.getStringSync(resource);
    } catch (err) {
      hilog.warn(0x0000, TAG, 'string lookup: %{public}s', (err as BusinessError).message);
      return '';
    }
  }

  /** resources.getQuantityString(R.plurals.feed_group_dialog_selection_count, n, n). */
  private selectionCountText(): string {
    const count: number = this.selectionCount;
    try {
      const context: common.Context = getContext(this) as common.Context;
      const template: string = context.resourceManager
        .getPluralStringValueSync($r('app.plural.feed_group_dialog_selection_count'), count);
      return template.replace('%d', count.toString());
    } catch (err) {
      hilog.warn(0x0000, TAG, 'selection count plural: %{public}s', (err as Error).message);
      return count.toString();
    }
  }

  private isSelected(entity: SubscriptionEntity): boolean {
    return this.selectedUids.indexOf(entity.uid) >= 0;
  }

  /**
   * OnItemClickListener on subscriptionMainSection: add or remove the uid, set
   * wasSubscriptionSelectionChanged, then updateSubscriptionSelectedCount(). S4 owns the
   * wasSubscriptionSelectionChanged half (it stops DB emissions overwriting the selection).
   */
  private toggleSubscription(entity: SubscriptionEntity): void {
    const pos: number = this.selectedUids.indexOf(entity.uid);
    const next: number[] = this.selectedUids.slice();
    if (pos >= 0) {
      next.splice(pos, 1);
    } else {
      next.push(entity.uid);
    }
    this.selectedUids = next;
    this.selectionCount = next.length;
    this.wasSubscriptionSelectionChanged = true;
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Builders — one per ScreenState, exactly as showScreen() toggles them
  ////////////////////////////////////////////////////////////////////////// */

  /** options_root: the icon preview, the name field, the count label and the picker button. */
  @Builder
  optionsRoot() {
    Column() {
      Row() {
        // ImageButton icon_preview, 64dp, centerInside: getDrawableRes() is a NAME, so it is
        // resolved at runtime rather than with the $r literal sugar.
        Image(mediaByName(feedGroupIconDrawable(this.selectedIcon)))
          .id('icon_preview')
          .width(64)
          .height(64)
          .padding(22)
          .backgroundColor('#D6D7D7')
          .borderRadius(2)
          .objectFit(ImageFit.Contain)
          .onClick(() => {
            // iconSelector.scrollToPosition(0); showScreen(IconPickerScreen)
            this.currentScreen = FeedGroupDialogScreen.ICON_PICKER;
          })

        // TextInputLayout group_name_input_container + NewPipeEditText group_name_input.
        Column() {
          TextInput({ text: this.groupName, placeholder: $r('app.string.name') })
            .id('group_name_input')
            .maxLines(1)
            .width('100%')
            .height(45)
            .fontSize(16)
            .fontColor($r('app.color.on_surface'))
            .placeholderColor($r('app.color.on_surface_variant'))
            .placeholderFont({ size: 16 })
            .backgroundColor(Color.Transparent)
            .borderRadius(0)
            .padding({ left: 0, right: 0 })
            .showUnderline(true)
            .onChange((value: string) => {
              // doOnTextChanged clears the container error once the text is non-blank.
              this.groupName = value;
              if (value.trim().length > 0) {
                this.nameError = '';
              }
            })

          if (this.nameError.length > 0) {
            Text(this.nameError)
              .id('group_name_input_error')
              .fontSize(12)
              .fontColor('#F44336')
              .margin({ top: 4 })
          }
        }
        .id('group_name_input_container')
        .layoutWeight(1)
        .margin({ left: 8 })
        .padding({ top: 6, bottom: 6 })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      // selected_subscription_count_view - the same quantity string as subscriptions_header_info.
      Text(this.selectionCountText())
        .id('selected_subscription_count_view')
        .width('100%')
        .textAlign(TextAlign.Center)
        .fontSize(12)
        .fontColor($r('app.color.on_surface_variant'))
        .margin({ top: 6 })

      // layout_constraintBottom_toBottomOf=parent: the borderless button sits on the bottom edge.
      Blank()

      // Widget.AppCompat.Button uppercases its label through the theme; ArkUI has no such
      // attribute, so the dialog's three buttons take theirs from Localization.buttonLabel().
      Button(Localization.buttonLabel('feed_group_dialog_select_subscriptions'))
        .id('select_channel_button')
        .type(ButtonType.Normal)
        .width('100%')
        .height(48)
        .borderRadius(2)
        .backgroundColor(Color.Transparent)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.on_surface'))
        .margin({ bottom: 4 })
        .onClick(() => {
          // subscriptionsSelectorList.scrollToPosition(0); showScreen(SubscriptionsPickerScreen)
          this.currentScreen = FeedGroupDialogScreen.SUBSCRIPTIONS_PICKER;
        })
    }
    .id('options_root')
    .width('100%')
    .height('100%')
    .padding(8)
  }

  /** icon_selector: GridLayoutManager(7) over FeedGroupIcon.entries.map { PickerIconItem(it) }. */
  @Builder
  iconSelector() {
    Grid() {
      ForEach(this.iconPickerGrid, (icon: FeedGroupIcon) => {
        GridItem() {
          PickerIconItem({
            icon: icon,
            onSelected: (): void => {
              // selectedIcon = item.icon; iconPreview.setImageResource(item.iconRes);
              // showScreen(InitialScreen)
              this.selectedIcon = icon;
              this.currentScreen = FeedGroupDialogScreen.INITIAL;
            }
          })
        }
      }, (icon: FeedGroupIcon) => `${icon as number}`)
    }
    .id('icon_selector')
    .columnsTemplate('1fr 1fr 1fr 1fr 1fr 1fr 1fr')
    .width('100%')
    // ArkTS honours layoutWeight only inside Row/Column/Flex; this Grid is a direct child of the
    // screen Stack below, where a weight measures to zero height and the icons never draw.
    .height('100%')
    .padding({ left: 4, right: 4, top: 16, bottom: 16 })
  }

  /** subscriptions_header_toolbar: the info container OR the search field, never both. */
  @Builder
  subscriptionsHeader() {
    Row() {
      if (this.searchVisible) {
        // toolbar_search_layout, included with visibility GONE until showSearch().
        Row() {
          TextInput({ text: this.searchQuery, placeholder: $r('app.string.search') })
            .id('toolbar_search_edit_text')
            .maxLines(1)
            .layoutWeight(1)
            .height(48)
            .fontSize(16)
            .fontColor($r('app.color.accent'))
            .placeholderColor($r('app.color.on_surface_variant'))
            .backgroundColor(Color.Transparent)
            .borderRadius(0)
            .padding({ left: 0, right: 0 })
            .showUnderline(true)
            .onChange((value: string) => {
              // subscriptionsCurrentSearchQuery = text; viewModel.filterSubscriptionsBy(text)
              this.searchQuery = value;
              this.loadSubscriptions();
            })

          // toolbar_search_clear: a 48dp box around toolbar_search_clear_icon (ic_close).
          Image($r('app.media.ic_close'))
            .id('toolbar_search_clear')
            .width(24)
            .height(24)
            .margin({ left: 12 })
            .fillColor($r('app.color.accent'))
            .objectFit(ImageFit.Contain)
            .onClick(() => {
              // Already empty -> hideSearch(); otherwise resetSearch().
              if (this.searchQuery.length === 0) {
                this.hideSearch();
              } else {
                this.searchQuery = '';
                this.loadSubscriptions();
              }
            })
        }
        .id('subscriptions_header_search_container')
        .layoutWeight(1)
      } else {
        Column() {
          Text($r('app.string.tab_subscriptions'))
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.accent'))
          Text(this.selectionCountText())
            .id('subscriptions_header_info')
            .fontSize(12)
            .fontColor($r('app.color.accent'))
        }
        .id('subscriptions_header_info_container')
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        // menu_feed_group_dialog: action_search (showAsAction always) is hidden while the search
        // layout is up, which is exactly this else-branch.
        Image($r('app.media.ic_search'))
          .id('action_search')
          .accessibilityText($r('app.string.search'))
          .width(24)
          .height(24)
          .margin({ left: 8 })
          .fillColor($r('app.color.accent'))
          .objectFit(ImageFit.Contain)
          .onClick(() => {
            this.searchVisible = true;
          })

        // feed_group_toggle_show_only_ungrouped_subscriptions is an OVERFLOW item on the
        // reference, not a toolbar control: its picker's bar carries Search and a three-dot
        // More options, and the entry only appears after that is tapped - measured on 0.29.1,
        // the entry at [129,962][897,1027] and absent until then. The port drew it inline in the
        // bar, which is what this case reports.
        Image($r('app.media.ic_more_vert'))
          .id('action_overflow')
          // the toolbar overflow button's own contentDescription
          .accessibilityText($r('app.string.more_options'))
          .width(48)
          .height(48)
          .padding(12)
          .fillColor($r('app.color.accent'))
          .objectFit(ImageFit.Contain)
          .margin({ left: 8 })
          .bindMenu(this.pickerOverflowMenu, SQUARE_MENU_CORNERS)

      }
    }
    .id('subscriptions_header_toolbar')
    .width('100%')
    .height(56)
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
  }

  /** subscriptions_selector: the toolbar plus the 4-column picker grid. */
  @Builder
  subscriptionsSelector() {
    Column() {
      this.subscriptionsHeader()

      // subscriptionEmptyFooter: ImportSubscriptionsHintPlaceholderItem is added ONLY when the
      // list came back empty, and cleared otherwise - so it is exclusive with the grid.
      if (this.subscriptionSource.isEmpty()) {
        ImportSubscriptionsHintPlaceholderItem()
      } else {
        Grid() {
          LazyForEach(this.subscriptionSource, (entity: SubscriptionEntity) => {
            GridItem() {
              PickerSubscriptionItem({
                item: entity,
                isSelected: this.isSelected(entity),
                onSelected: (): void => {
                  this.toggleSubscription(entity);
                }
              })
            }
          }, (entity: SubscriptionEntity) => `${entity.uid}`)
        }
        .id('subscriptions_selector_list')
        .columnsTemplate('1fr 1fr 1fr 1fr')
        .width('100%')
        .layoutWeight(1)
        .cachedCount(8)
        .padding(2)
      }
    }
    .id('subscriptions_selector')
    .width('100%')
    // Same rule as icon_selector: a direct child of the screen Stack must be sized, not weighted.
    // The grid's own layoutWeight(1) above is legal because THIS Column is now height-bounded.
    .height('100%')
  }

  /**
   * The dialog window's height. base.png: options_root is a fixed 180dp plus the 30dp button
   * bar = 210vp; the two pickers are RecyclerViews that grow to the window maximum.
   */
  private cardHeight(): string {
    if (this.currentScreen === FeedGroupDialogScreen.INITIAL) {
      return '210vp';
    }
    if (this.currentScreen === FeedGroupDialogScreen.DELETE) {
      return '160vp';
    }
    // The picker screens WRAP their content on the reference - the icon grid's dialog ends just
    // below the last row. A flat 72% left a tall empty band under the icons before the button bar.
    if (this.currentScreen === FeedGroupDialogScreen.ICON_PICKER) {
      return windowHeightVp(this.getUIContext(), 0.52);
    }
    return windowHeightVp(this.getUIContext(), 0.72);
  }

  /** The picker's overflow: one CHECKABLE entry, as menu_feed_group_dialog declares it. */
  @Builder
  pickerOverflowMenu() {
    Menu() {
      MenuItem(this.showOnlyUngroupedItem)
        .id('feed_group_toggle_show_only_ungrouped_subscriptions')
        .onClick(() => {
          // viewModel.toggleShowOnlyUngrouped(showOnlyUngrouped)
          this.showOnlyUngrouped = !this.showOnlyUngrouped;
          this.loadSubscriptions();
        })
    }
    // the reference's popup spans most of the dialog; the title still ellipsizes there too
    .width(280)
    .backgroundColor($r('app.color.surface'))
  }

  /**
   * android:checkable="true": a PopupMenu draws a checkable item as its title followed by a real
   * CheckBox (ListMenuItemView.insertCheckBox), ticked or empty - not a tick that appears only
   * once it is on. The row owns the click, so the box takes no touch of its own.
   */
  @Builder
  showOnlyUngroupedItem() {
    Row() {
      Text($r('app.string.feed_group_show_only_ungrouped_subscriptions'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontSize(16)
        .fontColor($r('app.color.on_surface'))
      Checkbox()
        .width(20)
        .height(20)
        .margin({ left: 16 })
        .shape(CheckBoxShape.ROUNDED_SQUARE)
        .selectedColor($r('app.color.accent'))
        .select(this.showOnlyUngrouped)
        .hitTestBehavior(HitTestMode.None)
        .accessibilityLevel('no')
    }
    .width('100%')
    .height(48)
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
  }

  build() {
    // The host opens this through FeedGroupDialogHost, a CustomDialogController that draws the
    // AlertDialog's 0.6 dim itself; this is only the card.
    Stack() {
      Column() {
      // The FrameLayout that holds all four screens, layout_weight=1.
      Stack() {
        if (this.currentScreen === FeedGroupDialogScreen.INITIAL) {
          this.optionsRoot()
        } else if (this.currentScreen === FeedGroupDialogScreen.ICON_PICKER) {
          this.iconSelector()
        } else if (this.currentScreen === FeedGroupDialogScreen.SUBSCRIPTIONS_PICKER) {
          this.subscriptionsSelector()
        } else {
          Text($r('app.string.feed_group_dialog_delete_message'))
            .id('delete_screen_message')
            .width('100%')
            .fontSize(16)
            .fontColor($r('app.color.on_surface'))
            .textAlign(TextAlign.Start)
            .padding({ left: 24, right: 24, top: 16, bottom: 16 })
        }
      }
      .width('100%')
      .layoutWeight(1)
      .alignContent(Alignment.TopStart)

      // separator.onlyVisibleIn(SubscriptionsPickerScreen, IconPickerScreen)
      if (this.currentScreen === FeedGroupDialogScreen.SUBSCRIPTIONS_PICKER
        || this.currentScreen === FeedGroupDialogScreen.ICON_PICKER) {
        Divider()
          .id('separator')
          .strokeWidth(1)
          .color($r('app.color.separator'))
      }

      // The RelativeLayout button bar: delete on the start edge, cancel then confirm on the end.
      Row() {
        // isGone unless InitialScreen AND an existing group.
        if (this.currentScreen === FeedGroupDialogScreen.INITIAL
          && this.groupId !== NO_GROUP_SELECTED) {
          Image($r('app.media.ic_delete'))
            .id('delete_button')
            .accessibilityText($r('app.string.delete'))
            .width(24)
            .height(24)
            .fillColor($r('app.color.on_surface'))
            .objectFit(ImageFit.Contain)
            .enabled(!this.isProcessing)
            .onClick(() => {
              this.currentScreen = FeedGroupDialogScreen.DELETE;
            })
        }

        Blank()

        // cancel_button.onlyVisibleIn(InitialScreen, DeleteScreen)
        if (this.currentScreen === FeedGroupDialogScreen.INITIAL
          || this.currentScreen === FeedGroupDialogScreen.DELETE) {
          Button(Localization.buttonLabel('cancel'))
            .id('cancel_button')
            .type(ButtonType.Normal)
            .height(30)
            .borderRadius(2)
            .backgroundColor(Color.Transparent)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.on_surface'))
            .padding({ left: 8, right: 8 })
            .enabled(!this.isProcessing)
            .onClick(() => {
              if (this.currentScreen === FeedGroupDialogScreen.INITIAL) {
                this.isShown = false;
              } else {
                this.currentScreen = FeedGroupDialogScreen.INITIAL;
              }
            })
        }

        // R.string.create only on the InitialScreen of a NEW group, else R.string.ok.
        Button(Localization.buttonLabel(this.currentScreen === FeedGroupDialogScreen.INITIAL
          && this.groupId === NO_GROUP_SELECTED ? 'create' : 'ok'))
          .id('confirm_button')
          .type(ButtonType.Normal)
          .height(30)
          .borderRadius(2)
          .backgroundColor(Color.Transparent)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_surface'))
          .padding({ left: 8, right: 8 })
          .enabled(!this.isProcessing)
          .onClick(() => {
            this.handlePositiveButton();
          })
      }
      .id('feed_group_dialog_button_bar')
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 12, right: 12, top: 4, bottom: 4 })
      }
      // The source's AlertDialog is nearly the screen's width; 310vp left wide grey margins the
      // reference does not have, and made the icon grid look cramped against them.
      .width('94%')
      .height(this.cardHeight())
      .backgroundColor($r('app.color.dialog_background'))
      .borderRadius(2)
      .clip(true)
    }
    .id('FeedGroupDialogPage')
    .width('100%')
  }
}

/** The @CustomDialog a CustomDialogController's builder has to be; forwards everything. */
@CustomDialog
export struct FeedGroupDialogHost {
  @Link isShown: boolean;
  @Prop incomingGroupId: number = NO_GROUP_SELECTED;
  controller?: CustomDialogController;

  build() {
    FeedGroupDialogPage({ isShown: this.isShown, incomingGroupId: this.incomingGroupId })
  }
}
