/**
 * S3 — SubscriptionFragment (screen_subscription), structure from fragment_subscription.xml +
 * subscription_groups_header.xml + feed_item_carousel.xml + subscription_header.xml +
 * list_channel_mini_item.xml + SubscriptionFragment.kt.
 *
 * hostedBy screen_main: MainFragment mounts this struct as a tab, so it renders no toolbar of its
 * own — only the fragment's options menu (the Import / Export submenus, which have no menu XML at
 * all: buildImportExportMenu() builds them at runtime from the services that expose a
 * subscriptionExtractor).
 *
 * Groupie-based, and structurally TWO stacked sections in ONE vertical adapter:
 *   1. the groups header (title + view-mode toggle + a sort button that exists only while
 *      groups.size > 1) followed by the HORIZONTAL feed-group carousel, whose first entry is
 *      always "add new",
 *   2. a plain text section header followed by the subscribed-channel list, which shows the
 *      import-hint placeholder INSTEAD of rows while it is empty.
 *
 * Both overlays this screen hosts stay mounted here: FeedGroupDialog (a full-screen
 * DialogFragment) and FeedGroupReorderDialog, both CustomDialogControllers.
 *
 * Structure only — S5 styles it from the capture.
 */
import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

import { FeedGroupDialogHost, NO_GROUP_SELECTED } from './FeedGroupDialogPage';
import { FeedGroupReorderDialogHost } from './FeedGroupReorderDialogPage';

import { ChannelItem, ChannelItemVersion } from '../components/ChannelItem';
import { ItemViewMode } from '../components/InfoListAdapter';
import { resolveItemViewMode } from '../common/settings/ViewModeResolver';
import { FeedGroupAddNewItem } from '../components/FeedGroupAddNewItem';
import { FeedGroupCardItem } from '../components/FeedGroupCardItem';
import { FeedGroupCarouselItem } from '../components/FeedGroupCarouselItem';
import {
  ImportSubscriptionsHintPlaceholderItem
} from '../components/ImportSubscriptionsHintPlaceholderItem';
import { DialogAction, InfoItemDialog } from '../components/InfoItemDialog';

import { FeedGroupEntity } from '../model/db/entity/FeedGroupEntity';
import { FeedGroupIcon } from '../model/enums/FeedGroupIcon';
import { SubscriptionEntity } from '../model/db/entity/SubscriptionEntity';
import { SubscriptionItem } from '../model/app/SubscriptionData';

import { FeedDatabase } from '../common/feed/FeedLoader';
import { SubscriptionManager } from '../common/db/SubscriptionManager';
import { NewPipe } from '../common/extractor/core/NewPipe';
import { StreamingService } from '../common/extractor/core/StreamingService';
import { ServiceLocator } from '../common/di/ServiceLocator';
import { FileAccess, StoredFile } from '../common/file/FileAccess';
import { ImportConfirmationDialogPage, SubscriptionImportInput }
  from './ImportConfirmationDialogPage';
import { enqueueSubscriptionImport } from '../common/subscription/SubscriptionImportWork';
// stateLiveData / feedGroupsLiveData are Rx subscriptions the ViewModel disposes in onCleared().
import { Disposable, Observable } from '../common/rx/Rx';
import { AppPreferences } from '../common/prefs/Preferences';
import {
  list_view_mode_key,
  list_view_mode_value,
} from '../common/prefs/SettingsKeys';
import { servicePrimaryColor, DIALOG_MASK_COLOR } from '../common/theme/ServiceTheme';
import { Localization } from '../common/i18n/Localization';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

/* S5 - style only, LightTheme (both captured states are light). This page renders no toolbar of
 * its own (it is a MainFragment tab, per the header above), so the capture's red band belongs to
 * screen_main and is not restyled here. */
/** AppCompat android:textColorPrimary - no migrated resource carries it. */
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');

const TAG: string = 'SubscriptionFragmentPage';

/** ImportExportJsonHelper's own name for the file SubscriptionsExportService writes. */
const EXPORT_FILE_NAME: string = 'newpipe_subscriptions.json';
const EXPORT_MIME_TYPE: string = 'application/json';

/**
 * The list/grid toggle the header owns. The source keeps it in a BehaviorProcessor seeded with
 * `!shouldUseGridForSubscription(app)`, so it starts from the list_view_mode preference; this
 * key remembers a toggle the user made, and its DEFAULT is that same source expression.
 */
const GROUP_LIST_VIEW_MODE_KEY: string = 'subscription_group_list_view_mode';

/** ThemeHelper.getGridSpanCountChannels(ctx) — > 1 is what makes a ChannelItem a GRID one. */
const GRID_SPAN_COUNT_CHANNELS: number = 3;

/** NavigationHelper.openChannelFragment(serviceId, url, name). */
class ItemParams {
  serviceId: number;
  url: string;
  name: string;

  constructor(serviceId: number, url: string, name: string) {
    this.serviceId = serviceId;
    this.url = url;
    this.name = name;
  }
}

/**
 * NavigationHelper.openFeedFragment(fm, groupId, name) -> FeedFragment.newInstance(), whose
 * arguments are KEY_GROUP_ID and KEY_GROUP_NAME. The name field MUST be called `groupName`:
 * FeedFragmentPage.readArguments() reads params['groupName'], so a field called `name` arrives
 * as undefined and the toolbar subtitle that says WHICH group was opened never renders.
 */
class FeedParams {
  groupId: number;
  groupName: string;

  constructor(groupId: number, groupName: string) {
    this.groupId = groupId;
    this.groupName = groupName;
  }
}

/** One runtime-built entry of the Import submenu. */
export class ImportSource {
  /** -1 = "previous export"; otherwise the service whose extractor does the import. */
  serviceId: number;
  label: ResourceStr;
  idSlug: string;

  constructor(serviceId: number, label: ResourceStr, idSlug: string) {
    this.serviceId = serviceId;
    this.label = label;
    this.idSlug = idSlug;
  }
}

/**
 * buildImportExportMenu()'s source list, as a free function so the host activity can draw the
 * same submenu when this fragment is used as a front page and owns no toolbar of its own.
 */
/** The "previous export" entry's service id: not a service, the file the user exported. */
export const PREVIOUS_EXPORT_SERVICE_ID: number = -1;

export function subscriptionImportSources(): ImportSource[] {
  const sources: ImportSource[] = [];
  sources.push(new ImportSource(PREVIOUS_EXPORT_SERVICE_ID, $r('app.string.previous_export'),
    'previous_export'));
  NewPipe.getServices().forEach((service: StreamingService) => {
    if (service.getSubscriptionExtractor() !== null) {
      const name: string = service.getServiceInfo().getName();
      sources.push(new ImportSource(service.getServiceId(), name, name));
    }
  });
  return sources;
}

/** NavigationHelper.openSubscriptionsImportFragment(fm, serviceId) — pure navigation. */
export function openSubscriptionsImport(source: ImportSource): void {
  router.pushUrl({
    url: 'pages/SubscriptionsImportFragmentPage',
    params: new ItemParams(source.serviceId, '', source.idSlug)
  });
}

/**
 * carouselAdapter's item TYPES. The source keeps ONE heterogeneous GroupAdapter — the add-new
 * item, the built-in All card, then one card per group — and its listener dispatches on the item
 * type: `setOnItemClickListener { when (item) { is FeedGroupCardItem ->
 * NavigationHelper.openFeedFragment(fm, item.groupId, item.name); is FeedGroupAddNewItem ->
 * FeedGroupDialog.newInstance().show(fm, null) } }`.
 */
enum CarouselItemType {
  ADD_NEW = 'add-new-group',
  ALL_GROUP = 'all-group',
  FEED_GROUP = 'feed-group'
}

/** One carousel entry as the adapter holds it: its type plus what its row was built from. */
interface CarouselItem {
  type: CarouselItemType;
  groupId: number;
  name: string;
}

/** subscriptionsSection: the channel rows, unbounded, so LazyForEach over an IDataSource. */
class SubscriptionDataSource implements IDataSource {
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

  getItemsList(): SubscriptionEntity[] {
    return this.items;
  }

  /** subscriptionsSection.update(result.subscriptions). */
  setItems(items: SubscriptionEntity[]): void {
    this.items = items;
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataReloaded();
    });
  }
}

/**
 * The reference's toolbar overflows are flat white rectangles with square corners, anchored at
 * the icon - measured on three of its screens (Play queue, Subscriptions, History), all at
 * x 528..1020 of 1080. ArkUI's default menu is a rounded pale-gradient bubble with a tail.
 */
const SQUARE_MENU_CORNERS: MenuOptions = { borderRadius: 0 };

@Entry
@Component
export struct SubscriptionFragmentPage {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  /** ?attr/colorPrimary follows the service the drawer selected; see servicePrimaryColor(). */
  @StorageProp('mainSelectedServiceId') activeServiceId: number = 0;

  /** carouselAdapter <- viewModel.feedGroupsLiveData. */
  @Prop feedGroupsCarousel: FeedGroupEntity[] = [];
  /** subscriptionsSection <- viewModel.stateLiveData (SubscriptionState.LoadedState). */
  /** SubscriptionManager.changes, so a subscribe made on another screen reloads this list. */
  private changesWorker: Disposable | null = null;
  @Prop subscriptionsList: SubscriptionEntity[] = [];
  /** How many rows the section holds — the import-hint placeholder is driven by this. */
  @State subscriptions: number = 0;
  /** viewModel.getListViewMode(): the carousel renders card vs grid items. */
  @State listViewMode: boolean = true;
  /** headerToggleViewMode.setImageResource(listViewMode ? ic_apps : ic_list). */
  @Prop groupViewModeIcon: Resource = $r('app.media.ic_apps');
  /** shouldUseGridForSubscription(ctx) -> getGridSpanCountChannels(ctx); 1 means the list mode. */
  @State spanCount: number = 1;
  /**
   * AppearanceSettingsFragmentPage publishes the chosen list_view_mode here right after it writes
   * the preference, so a page that is ALREADY drawn re-reads it instead of keeping the template it
   * was built with. @Watch never fires on init, so aboutToAppear's own read still stands.
   */
  @StorageProp('listViewMode') @Watch('readListViewMode')
  private listViewModeSignal: string = '';
  /**
   * setUseAsFrontPage(true): mounted as a tab of MainFragment, the activity's toolbar carries the
   * title and this fragment's menu, so drawing our own bar stacked a second one under the shell's
   * - and the shell's had no overflow, which is what "the popup menu cannot be displayed" was.
   * False on the drawer route, which is a pushed page and does own its bar.
   */
  @Prop useAsFrontPage: boolean = false;
  /** Export needs this page's SubscriptionManager, so the host dispatches instead of doing it. */
  @StorageLink('mainSubscriptionsExportRequest') @Watch('onExportRequested')
  exportRequest: number = 0;
  /**
   * "Import from > Previous export" raises the picker and the confirmation dialog on THIS screen,
   * so when the host toolbar draws the menu it dispatches here the same way Export does.
   */
  @StorageLink('mainSubscriptionsImportPreviousRequest') @Watch('onImportPreviousRequested')
  importPreviousRequest: number = 0;
  /**
   * The input ImportConfirmationDialog.show(fragment, input) carries. @State, because the
   * controller below is built once and the @Prop copies THIS press's input on the way in.
   */
  @State pendingImportInput: SubscriptionImportInput = SubscriptionImportInput.channelUrl(0, '');

  /** GroupsHeader.showSortButton = groups.size > 1 (SubscriptionFragment.kt:383). */
  @State showSortButton: boolean = false;
  /** The group a long-press is acting on; GROUP_ALL_ID can be neither edited nor deleted. */
  @State groupId: number = NO_GROUP_SELECTED;

  @State isLoading: boolean = true;
  @State errorInfo: string | null = null;

  /** showLongTapDialog(selectedItem): Share / Open in browser / Unsubscribe. */
  @State menuTitle: string = '';
  @State menuActions: DialogAction[] = [];

  /** buildImportExportMenu(): built at runtime, so it is state, not a fixed menu resource. */
  @State importSources: ImportSource[] = [];
  /** The toolbar overflow the menu hangs off: closed until the 3-dot is tapped. */

  /**
   * screen_feed_group_dialog and screen_feed_group_reorder_dialog are AlertDialogs. Each is a
   * CustomDialogController, which fades the 0.6 dim in over the whole window; the transparent
   * bindSheets they used before slid a hand-drawn scrim in that stopped at the status bar.
   * The flags drive the controllers; an outside tap or back gesture clears them.
   */
  @State @Watch('onFeedGroupDialogVisibility') showFeedGroupDialog: boolean = false;
  @State feedGroupDialogGroupId: number = NO_GROUP_SELECTED;
  @State @Watch('onFeedGroupReorderVisibility') showFeedGroupReorder: boolean = false;
  private feedGroupDialog: CustomDialogController = new CustomDialogController({
    customStyle: true,
    maskColor: DIALOG_MASK_COLOR,
    cancel: (): void => {
      this.showFeedGroupDialog = false;
    },
    builder: FeedGroupDialogHost({
      isShown: this.showFeedGroupDialog,
      incomingGroupId: this.feedGroupDialogGroupId
    })
  });
  private feedGroupReorderDialog: CustomDialogController = new CustomDialogController({
    customStyle: true,
    maskColor: DIALOG_MASK_COLOR,
    cancel: (): void => {
      this.showFeedGroupReorder = false;
    },
    builder: FeedGroupReorderDialogHost({ isShown: this.showFeedGroupReorder })
  });

  /**
   * The rows LazyForEach reads. It is fed from `subscriptionsList` on every load: an IDataSource
   * is an identity the list registers listeners on, so it stays a plain field — the BOUND value
   * is the array above.
   */
  private channelRows: SubscriptionDataSource = new SubscriptionDataSource();
  private stateWorker: Disposable | null = null;
  private feedGroupsWorker: Disposable | null = null;
  private feedDatabase: FeedDatabase | null = null;
  private subscriptionManager: SubscriptionManager | null = null;
  /** The channel row the long-tap dialog is acting on. */
  private selectedItem: SubscriptionEntity | null = null;

  private longTapDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    builder: InfoItemDialog({ title: this.menuTitle, actions: this.menuActions })
  });

  /**
   * screen_import_confirmation_dialog. The source shows it over THIS screen for a previous
   * export - onImportPreviousSelected() launches the picker from the Subscriptions overflow and
   * never opens a screen of its own - so the controller lives here as well as on the import
   * screen the service entries push. Its geometry matches that one: an AlertDialog card, 86% of
   * the width, centred, with the container's 32vp default corners squared off.
   */
  private importConfirmationDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    builder: ImportConfirmationDialogPage({
      importInput: this.pendingImportInput,
      onConfirm: (confirmed: SubscriptionImportInput): void => {
        enqueueSubscriptionImport(getContext(this) as common.Context, confirmed);
      }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    cornerRadius: 2,
    width: '86%'
  });

  /* //////////////////////////////////////////////////////////////////////////
  // Lifecycle
  ////////////////////////////////////////////////////////////////////////// */

  aboutToAppear(): void {
    // doInitialLoadLogic() and startLoading() are deliberate no-ops in the source: everything
    // comes from LiveData over the local database, which is what these two reads are.
    this.readListViewMode();
    this.buildImportExportMenu();
    this.loadFeedGroups();
    this.loadSubscriptions();
    this.monitorSubscriptionChanges();
  }

  /**
   * feedGroupsLiveData is a Room Flowable in the source, so creating, editing, deleting or
   * REORDERING a group in either sheet repaints the carousel by itself. The port reads the groups
   * once, and loadFeedGroups() ran only from aboutToAppear on a tab that is created once - so a
   * group created in FeedGroupDialog never appeared, and with it the sort button (groups.size > 1)
   * could never turn up either. Both sheets close by setting their flag false; that is the
   * dismissal this re-read hangs off.
   */
  /** The host's Export entry, dispatched here because only this page holds the manager. */
  private onExportRequested(): void {
    if (this.exportRequest > 0) {
      this.onExportSelected();
    }
  }

  /** The host's "Previous export" entry: the same dispatch, for the same reason. */
  private onImportPreviousRequested(): void {
    if (this.importPreviousRequest > 0) {
      this.importPreviousExport();
    }
  }

  private onFeedGroupDialogVisibility(): void {
    if (this.showFeedGroupDialog) {
      this.feedGroupDialog.open();
    } else {
      this.feedGroupDialog.close();
    }
    this.onGroupSheetDismissed();
  }

  private onFeedGroupReorderVisibility(): void {
    if (this.showFeedGroupReorder) {
      this.feedGroupReorderDialog.open();
    } else {
      this.feedGroupReorderDialog.close();
    }
    this.onGroupSheetDismissed();
  }

  private onGroupSheetDismissed(): void {
    if (!this.showFeedGroupDialog && !this.showFeedGroupReorder) {
      this.loadFeedGroups();
    }
  }

  /**
   * The source's SubscriptionFragment reads its list from a Room Flowable, so a subscribe made on
   * any other screen repaints it. The port has the same channel - SubscriptionManager.changes,
   * whose own file header says it exists so "the subscription list subscribes to it so it
   * refreshes" - and this screen was the one place that never did. loadSubscriptions() ran only
   * from aboutToAppear, and this page is a hosted tab created once, so coming back from a channel
   * screen after subscribing showed the old list until the app was restarted.
   */
  private monitorSubscriptionChanges(): void {
    this.ensureServices()
      .then((manager: SubscriptionManager | null): void => {
        if (manager === null) {
          return;
        }
        this.changesWorker = manager.changes.subscribeCallbacks((revision: number): void => {
          this.loadSubscriptions();
        }, (error: Error): void => {
          this.showError(error.message);
        });
      })
      .catch((err: BusinessError): void => {
        this.showError(err.message);
      });
  }

  /** onCleared(): stateItemsDisposable.dispose() + feedGroupItemsDisposable.dispose(). */
  aboutToDisappear(): void {
    const changes: Disposable | null = this.changesWorker;
    if (changes !== null) {
      changes.dispose();
      this.changesWorker = null;
    }
    const state: Disposable | null = this.stateWorker;
    if (state !== null) {
      state.dispose();
      this.stateWorker = null;
    }
    const groups: Disposable | null = this.feedGroupsWorker;
    if (groups !== null) {
      groups.dispose();
      this.feedGroupsWorker = null;
    }
  }

  /**
   * BehaviorProcessor.createDefault(!shouldUseGridForSubscription(app)) — the list_view_mode
   * preference decides the starting mode, and a toggle the user made outranks it.
   */
  private readListViewMode(): void {
    const store: AppPreferences = AppPreferences.instance();
    const mode: string = store.getStringSync(list_view_mode_key,
      store.resolveDefault(list_view_mode_value));
    // shouldUseGridForSubscription(): itemViewMode == GRID || itemViewMode == CARD - over the
    // same resolved mode every other list screen uses.
    const resolved: ItemViewMode = resolveItemViewMode(mode);
    const useGrid: boolean = resolved === ItemViewMode.GRID || resolved === ItemViewMode.CARD;
    this.listViewMode = store.getBooleanSync(GROUP_LIST_VIEW_MODE_KEY, !useGrid);
    this.applyListViewMode();
  }

  /** The three values the mode drives: the header icon, the span count and the item version. */
  private applyListViewMode(): void {
    this.groupViewModeIcon =
      this.listViewMode ? $r('app.media.ic_apps') : $r('app.media.ic_list');
    this.spanCount = this.listViewMode ? 1 : GRID_SPAN_COUNT_CHANNELS;
  }

  private async ensureServices(): Promise<SubscriptionManager | null> {
    const existing: SubscriptionManager | null = this.subscriptionManager;
    if (existing !== null) {
      return existing;
    }
    try {
      const context: common.Context = getContext(this) as common.Context;
      const manager: SubscriptionManager = await SubscriptionManager.of(context);
      this.subscriptionManager = manager;
      this.feedDatabase = await FeedDatabase.of(context);
      return manager;
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.showError(failure.message);
      return null;
    }
  }

  /** feedGroupsLiveData: the groups, in sort order. */
  private async loadFeedGroups(): Promise<void> {
    if (await this.ensureServices() === null) {
      return;
    }
    const feed: FeedDatabase | null = this.feedDatabase;
    if (feed === null) {
      return;
    }
    const previous: Disposable | null = this.feedGroupsWorker;
    if (previous !== null) {
      previous.dispose();
    }
    this.feedGroupsWorker = Observable
      .fromPromise(feed.groups())
      .subscribeCallbacks((groups: FeedGroupEntity[]): void => {
        this.feedGroupsCarousel = groups;
        // showSortButton = groups.size > 1 — the built-in All card is not one of these rows.
        this.showSortButton = groups.length > 1;
      }, (error: Error): void => {
        this.showError(error.message);
      });
  }

  /** stateLiveData -> SubscriptionState.LoadedState(subscriptions). */
  private async loadSubscriptions(): Promise<void> {
    const manager: SubscriptionManager | null = await this.ensureServices();
    if (manager === null) {
      return;
    }
    const previous: Disposable | null = this.stateWorker;
    if (previous !== null) {
      previous.dispose();
    }
    this.isLoading = true;
    this.stateWorker = Observable
      .fromPromise(manager.subscriptions())
      .subscribeCallbacks((subs: SubscriptionEntity[]): void => {
        // LoadedState(subscriptions): the bound array first, then the rows it feeds.
        this.subscriptionsList = subs;
        this.channelRows.setItems(subs);
        this.subscriptions = subs.length;
        this.isLoading = false;
        this.errorInfo = null;
      }, (error: Error): void => {
        // ErrorState(error) -> showError(ErrorInfo(error, SOMETHING_ELSE, "Subscriptions")).
        this.showError(error.message);
      });
  }

  /** showError(ErrorInfo(error, UserAction.SOMETHING_ELSE, "Subscriptions")). */
  private showError(message: string): void {
    hilog.error(0x0000, TAG, 'Subscriptions: %{public}s', message);
    this.isLoading = false;
    this.errorInfo = message;
  }

  /* //////////////////////////////////////////////////////////////////////////
  // The runtime-built Import / Export menu (SubscriptionFragment.kt:125-148)
  ////////////////////////////////////////////////////////////////////////// */

  /**
   * menu.addSubMenu(R.string.import_from): "previous export" plus ONE entry per service that
   * actually exposes a subscriptionExtractor — a service without one gets no entry at all.
   */
  private buildImportExportMenu(): void {
    this.importSources = subscriptionImportSources();
  }

  /**
   * NavigationHelper.openSubscriptionsImportFragment(fm, serviceId) for a SERVICE entry only.
   *
   * "Previous export" is not a screen in the source: onImportPreviousSelected() launches
   * StoredFileHelper's picker straight from this overflow and hands the result to
   * ImportConfirmationDialog, which is why the reference goes from the submenu to the system file
   * picker in one step. The port pushed the import screen for it too, so the user met an empty
   * page with a second "Import file" button before any file could be chosen.
   */
  private onImportSelected(source: ImportSource): void {
    if (source.serviceId === PREVIOUS_EXPORT_SERVICE_ID) {
      this.importPreviousExport();
      return;
    }
    openSubscriptionsImport(source);
  }

  /**
   * onImportPreviousSelected(): the picker, then ImportConfirmationDialog in PreviousExportMode.
   * The mode comes from the menu entry the user came in through, never from the picked file's
   * MIME - DocumentViewPicker hands back a hard-coded default type.
   */
  private async importPreviousExport(): Promise<void> {
    const access: FileAccess = ServiceLocator.get().fileAccess;
    let picked: StoredFile | null = null;
    try {
      picked = await access.pickFileToOpen();
    } catch (err) {
      hilog.warn(0x0000, TAG, 'DocumentViewPicker unavailable: %{public}s',
        (err as BusinessError).message);
      router.pushUrl({ url: 'pages/CustomFilePickerFragmentPage' })
        .catch((pushErr: BusinessError): void => {
          hilog.error(0x0000, TAG, 'file picker push failed: %{public}s', pushErr.message);
        });
      return;
    }
    if (picked === null) {
      // RESULT_CANCELED with a null dataString: onActivityResult does nothing at all.
      return;
    }
    this.pendingImportInput =
      SubscriptionImportInput.previousExport(PREVIOUS_EXPORT_SERVICE_ID, picked.getUri());
    this.importConfirmationDialog.open();
  }

  /**
   * importExportHelper.onExportSelected(): the JSON is built from the subscriptions in the local
   * database. S4 hands it to the document picker that writes the file.
   */
  private async onExportSelected(): Promise<void> {
    const manager: SubscriptionManager | null = await this.ensureServices();
    if (manager === null) {
      return;
    }
    let json: string = '';
    try {
      const subs: SubscriptionEntity[] = await manager.subscriptions();
      const items: SubscriptionItem[] = [];
      subs.forEach((entity: SubscriptionEntity) => {
        const item: SubscriptionItem = new SubscriptionItem();
        item.serviceId = entity.serviceId;
        item.url = entity.url === null ? '' : entity.url;
        item.name = entity.name === null ? '' : entity.name;
        items.push(item);
      });
      json = SubscriptionManager.writePreviousExport(items, '', 0);
      hilog.info(0x0000, TAG, 'export prepared: %{public}d subscriptions, %{public}d bytes',
        items.length, json.length);
    } catch (err) {
      hilog.error(0x0000, TAG, 'export failed: %{public}s', (err as BusinessError).message);
      SubscriptionFragmentPage.reportExportFailure();
      return;
    }

    // requestExportPath(): StoredFileHelper.getNewPicker(ctx, EXPORT_FILE_NAME, JSON, null) -
    // the user names the destination, and SubscriptionsExportService only runs once they have.
    //
    // OUTSIDE the try above on purpose. requestExportPath() is a startActivityForResult, not part
    // of the export: a picker that refuses to open, or a DocumentViewPicker that REJECTS on cancel
    // rather than returning an empty list, is not an unsuccessful export and must not be reported
    // as one. It used to be, which is the only thing this screen can produce that looks like a
    // warning raised the instant "File" is tapped. The reason now reaches the log intact.
    const files: FileAccess = ServiceLocator.get().fileAccess;
    let target: StoredFile | null = null;
    try {
      target = await files.pickFileToSave(EXPORT_FILE_NAME, EXPORT_MIME_TYPE);
    } catch (err) {
      hilog.error(0x0000, TAG, 'export destination picker: %{public}s',
        (err as BusinessError).message);
      return;
    }
    if (target === null) {
      // RESULT_CANCELED: nothing is written and nothing is reported.
      return;
    }

    if (!files.writeText(target.getUri(), json)) {
      SubscriptionFragmentPage.reportExportFailure();
      return;
    }
    promptAction.showToast({ message: $r('app.string.export_complete_toast'), duration: 2000 });
  }

  /**
   * SubscriptionExportWorker's catch, which is the ONLY place the source reports a failed export:
   *
   *     Toast.makeText(applicationContext, R.string.subscriptions_export_unsuccessful,
   *                    Toast.LENGTH_SHORT).show()
   *
   * A toast, and the subscription list stays on screen. This called showError() instead, and
   * since 8892112 made the list render only while errorInfo is null - which is right, it is what
   * ErrorPanelHelper.showError() does - a failed export took the user's whole subscription list
   * away and left a Retry button that retries nothing. The error panel belongs to a failed LOAD.
   */
  private static reportExportFailure(): void {
    promptAction.showToast({
      message: $r('app.string.subscriptions_export_unsuccessful'), duration: 2000
    });
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Header, carousel and row gestures
  ////////////////////////////////////////////////////////////////////////// */

  /** onToggleListViewModeClicked -> viewModel.setListViewMode(!viewModel.getListViewMode()). */
  private async onToggleListViewModeClicked(): Promise<void> {
    this.listViewMode = !this.listViewMode;
    this.applyListViewMode();
    // The flushing write: the mode has to survive a relaunch, so never the unflushed putSync.
    try {
      await AppPreferences.putBoolean(GROUP_LIST_VIEW_MODE_KEY, this.listViewMode);
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      hilog.warn(0x0000, TAG, 'view mode not stored: %{public}s', failure.message);
    }
  }

  /** onSortClicked -> openReorderDialog() -> FeedGroupReorderDialog. */
  private onSortClicked(): void {
    this.showFeedGroupReorder = true;
  }

  /** carouselAdapter's add-new entry -> FeedGroupDialog.newInstance(). */
  private onAddNewGroupClicked(): void {
    this.feedGroupDialogGroupId = NO_GROUP_SELECTED;
    this.showFeedGroupDialog = true;
    hilog.info(0x0000, TAG, 'add-new group tapped — opening FeedGroupDialog (create)');
  }

  /** The carousel entry a row hands its listener, exactly as the adapter holds it. */
  private carouselEntry(type: CarouselItemType, groupId: number, name: string): CarouselItem {
    const entry: CarouselItem = { type: type, groupId: groupId, name: name };
    return entry;
  }

  /**
   * carouselAdapter.setOnItemClickListener { item, _ -> when (item) { ... } }: ONE listener over
   * the whole carousel, routing BY ITEM TYPE — the add-new item opens the create dialog, either
   * card kind opens that group's feed.
   */
  private onCarouselItemSelected(item: CarouselItem): void {
    if (item.type === CarouselItemType.ADD_NEW) {
      this.onAddNewGroupClicked();
      return;
    }
    this.onGroupSelected(item.groupId, item.name);
  }

  /** tap -> NavigationHelper.openFeedFragment(fm, groupId, name). */
  private onGroupSelected(groupId: number, name: string): void {
    router.pushUrl({
      url: 'pages/FeedFragmentPage',
      params: new FeedParams(groupId, name)
    });
  }

  /** long-press -> FeedGroupDialog.newInstance(groupId), except for the built-in All group. */
  private onGroupHeld(groupId: number): void {
    if (groupId === FeedGroupEntity.GROUP_ALL_ID) {
      // the listener returns false: All can be neither edited nor deleted
      hilog.info(0x0000, TAG, 'the All group cannot be edited');
      return;
    }
    this.groupId = groupId;
    this.feedGroupDialogGroupId = groupId;
    this.showFeedGroupDialog = true;
  }

  /** root.setOnClickListener { selected(infoItem) } -> ChannelFragment. */
  private onChannelSelected(item: SubscriptionEntity): void {
    router.pushUrl({
      url: 'pages/ChannelFragmentPage',
      params: new ItemParams(item.serviceId, item.url === null ? '' : item.url,
        item.name === null ? '' : item.name)
    });
  }

  /** root.setOnLongClickListener { held(infoItem) } -> showLongTapDialog(selectedItem). */
  private onChannelHeld(item: SubscriptionEntity): void {
    this.selectedItem = item;
    this.menuTitle = item.name === null ? '' : item.name;
    const url: string = item.url === null ? '' : item.url;
    const actions: DialogAction[] = [];
    actions.push(new DialogAction($r('app.string.share'), 'Share', (): void => {
      ServiceLocator.get().share.shareText(this.menuTitle, url);
    }));
    actions.push(new DialogAction($r('app.string.open_in_browser'), 'open_in_browser',
      (): void => {
        ServiceLocator.get().share.openUrlInBrowser(url);
      }));
    actions.push(new DialogAction($r('app.string.unsubscribe'), 'Unsubscribe', (): void => {
      this.deleteChannel(item);
    }));
    this.menuActions = actions;
    this.longTapDialog.open();
  }

  /** deleteChannel(selectedItem) -> subscriptionManager.deleteSubscription(serviceId, url). */
  private async deleteChannel(item: SubscriptionEntity): Promise<void> {
    const manager: SubscriptionManager | null = await this.ensureServices();
    if (manager === null || item.url === null) {
      return;
    }
    try {
      await manager.deleteSubscription(item.serviceId, item.url);
      promptAction.showToast({ message: $r('app.string.channel_unsubscribed'), duration: 2000 });
      this.loadSubscriptions();
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.showError(failure.message);
    }
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Builders
  ////////////////////////////////////////////////////////////////////////// */

  /** subscription_groups_header.xml. */
  @Builder
  groupsHeader() {
    Row() {
      // header_title: 16sp bold on textColorPrimary, 16dp horizontal / 12dp vertical padding,
      // two lines then ellipsis, over a 24dp minimum height.
      Text($r('app.string.feed_groups_header_title'))
        .id('header_title')
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(COLOR_ON_SURFACE)
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .constraintSize({ minHeight: 24 })

      // Both header buttons are 48dp ImageButtons with 8dp padding - but an ImageButton's default
      // scaleType is `center`, so the reference draws the 24dp vector at its own size inside that
      // 48dp target and never scales it. ImageFit.Contain does scale it, which blew the glyph up to
      // the 32dp the padding left over - a third bigger than the reference's, and visible side by
      // side. 12vp of padding leaves exactly the drawable's own 24vp and keeps the 48vp touch area.
      Image(this.groupViewModeIcon)
        .id('header_toggle_view_mode')
        .accessibilityText($r('app.string.list_view_mode'))
        .width(48)
        .height(48)
        .padding(12)
        .objectFit(ImageFit.Contain)
        .onClick(() => {
          this.onToggleListViewModeClicked();
        })

      // showSortButton = groups.size > 1: with one group there is nothing to reorder.
      if (this.showSortButton) {
        Image($r('app.media.ic_sort'))
          .id('header_sort')
          .accessibilityText($r('app.string.sort'))
          .width(48)
          .height(48)
          // Same 24vp drawable in the same 48vp target as the toggle beside it.
          .padding(12)
          .margin({ right: 4 })
          .objectFit(ImageFit.Contain)
          .onClick(() => {
            this.onSortClicked();
          })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /**
   * The carousel's entries, in the adapter's own order: add-new FIRST, then the built-in All
   * card (GROUP_ALL_ID, WHATS_NEW icon, @string/all), then one card per group.
   */
  @Builder
  groupsCarousel() {
    FeedGroupCarouselItem() {
      // add(if (listViewMode) FeedGroupAddNewItem() else FeedGroupAddNewGridItem()) — two
      // distinct items in the source, one component with the mode as its parameter here.
      if (this.listViewMode) {
        FeedGroupAddNewItem({
          gridMode: false,
          onSelected: (): void => {
            this.onCarouselItemSelected(
              this.carouselEntry(CarouselItemType.ADD_NEW, NO_GROUP_SELECTED, ''));
          }
        })
      } else {
        FeedGroupAddNewItem({
          gridMode: true,
          onSelected: (): void => {
            this.onCarouselItemSelected(
              this.carouselEntry(CarouselItemType.ADD_NEW, NO_GROUP_SELECTED, ''));
          }
        })
      }

      FeedGroupCardItem({
        groupId: FeedGroupEntity.GROUP_ALL_ID,
        name: this.allGroupName(),
        icon: FeedGroupIcon.WHATS_NEW,
        gridMode: !this.listViewMode,
        onSelected: (): void => {
          this.onCarouselItemSelected(this.carouselEntry(CarouselItemType.ALL_GROUP,
            FeedGroupEntity.GROUP_ALL_ID, this.allGroupName()));
        },
        onHeld: (): void => {
          this.onGroupHeld(FeedGroupEntity.GROUP_ALL_ID);
        }
      })

      ForEach(this.feedGroupsCarousel, (group: FeedGroupEntity) => {
        FeedGroupCardItem({
          groupId: group.uid,
          name: group.name,
          icon: group.icon,
          gridMode: !this.listViewMode,
          onSelected: (): void => {
            this.onCarouselItemSelected(
              this.carouselEntry(CarouselItemType.FEED_GROUP, group.uid, group.name));
          },
          onHeld: (): void => {
            this.onGroupHeld(group.uid);
          }
        })
      }, (group: FeedGroupEntity) => `${group.uid}`)
    }
  }

  /** getString(R.string.all) — the built-in group's name. */
  private allGroupName(): string {
    const context: common.Context = getContext(this) as common.Context;
    return context.resourceManager.getStringSync($r('app.string.all').id);
  }

  /**
   * onCreateOptionsMenu's two submenus: menu.addSubMenu(R.string.import_from) and
   * menu.addSubMenu(R.string.export_to). They live INSIDE the ActionBar overflow popup, anchored
   * to the More button - the port had been rendering them into the page body instead, as a
   * full-width strip with the two titles side by side in a Row, which pushed the list down and
   * looked nothing like a menu. ArkUI's MenuItem carries a builder for its submenu, so the
   * expand/collapse state this screen used to keep by hand is gone with it.
   */
  @Builder
  importSourcesMenu() {
    Menu() {
      ForEach(this.importSources, (source: ImportSource) => {
        MenuItem({ content: source.label })
          .id(source.idSlug)
          .onClick(() => {
            this.onImportSelected(source);
          })
      }, (source: ImportSource) => source.idSlug)
    }
  }

  /** addSubMenu(R.string.export_to) holds a single entry, @string/file. */
  @Builder
  exportTargetsMenu() {
    Menu() {
      MenuItem({ content: $r('app.string.file') })
        .id('file')
        .onClick(() => {
          this.onExportSelected();
        })
    }
  }

  @Builder
  importExportMenu() {
    Menu() {
      MenuItem({ content: $r('app.string.import_from'), builder: this.importSourcesMenu })
        .id('import_from')
      MenuItem({ content: $r('app.string.export_to'), builder: this.exportTargetsMenu })
        .id('export_to')
    }
    // The reference opens its submenu STACKED OVER the parent, in the same column. ArkUI's
    // default is SIDE_EXPAND, which anchors the child to the side of its parent - and with this
    // overflow already right-aligned there is no room on the right, so "File" flipped to the far
    // left of the screen, which is the misplaced button this case reports.
    //
    // The mode is a MENU ATTRIBUTE, `subMenuExpandingMode`, not a MenuOptions field; the earlier
    // attempt put it in MenuOptions, which is why it would not compile and the API was recorded
    // as missing from this SDK. It is present - API 12 and up - and this build is API 24.
    .subMenuExpandingMode(SubMenuExpandingMode.STACK_EXPAND)
  }

  build() {
    Column() {
      // toolbar_layout.xml, the host activity's bar: the Up arrow, the title
      // onCreateOptionsMenu sets (setTitle(R.string.tab_subscriptions),
      // SubscriptionFragment.kt:120) and the overflow that buildImportExportMenu() fills.
      if (!this.useAsFrontPage) {
      Row() {
        Image($r('app.media.ic_arrow_back'))
          .id('navigate_back')
          .accessibilityText($r('app.string.navigate_back'))
          .width(56)
          .height(56)
          .padding(16)
          .objectFit(ImageFit.Contain)
          .fillColor($r('app.color.on_primary'))
          .onClick(() => {
            router.back();
          })

        Text($r('app.string.tab_subscriptions'))
          .id('subscriptions_title')
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_primary'))
          .margin({ left: 16 })

        // The capture's "More options" icon — the slug is its content-desc, the source
        // toolbar carries no resource-id here.
        Image($r('app.media.ic_more_vert'))
          .id('more_options')
          .accessibilityText($r('app.string.more_options'))
          .width(56)
          .height(56)
          .padding(16)
          .objectFit(ImageFit.Contain)
          .fillColor($r('app.color.on_primary'))
          .bindMenu(this.importExportMenu, SQUARE_MENU_CORNERS)
      }
      .width('100%')
      .height(56)
      .alignItems(VerticalAlign.Center)
      .backgroundColor(servicePrimaryColor(this.activeServiceId))
      }

      Stack() {
        // ErrorPanelHelper.showError() hides the content view and shows the panel INSTEAD;
        // the panel used to be stacked ON TOP of a live list, with no background of its own,
        // so the rows read straight through it and there was nothing that looked like a panel.
        if (this.errorInfo === null) {
          List() {
            ListItem() {
              this.groupsHeader()
            }

            ListItem() {
              this.groupsCarousel()
            }

            // R.layout.subscription_header — a bold text row, @string/tab_subscriptions.
            ListItem() {
              // subscription_header.xml: 16sp bold on textColorPrimary, 16dp horizontal and
              // 12dp vertical padding, two lines then ellipsis.
              Text($r('app.string.tab_subscriptions'))
                .id('subscription_header')
                .width('100%')
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor(COLOR_ON_SURFACE)
                .padding({ left: 16, right: 16, top: 12, bottom: 12 })
            }

            // setPlaceholder(ImportSubscriptionsHintPlaceholderItem): the placeholder replaces the
            // rows while the section is empty — the two are never rendered together.
            if (this.subscriptions === 0) {
              ListItem() {
                ImportSubscriptionsHintPlaceholderItem()
              }
            } else {
              LazyForEach(this.channelRows, (item: SubscriptionEntity) => {
                ListItem() {
                  ChannelItem({
                    item: item,
                    itemVersion: this.spanCount > 1
                      ? ChannelItemVersion.GRID : ChannelItemVersion.MINI,
                    onSelected: (): void => {
                      this.onChannelSelected(item);
                    },
                    onHeld: (): void => {
                      this.onChannelHeld(item);
                    }
                  })
                }
              }, (item: SubscriptionEntity) => `${item.uid}-${item.url}`)
            }
          }
          .id('items_list')
          .width('100%')
          .height('100%')
          .cachedCount(5)
        }

        if (this.isLoading) {
          LoadingProgress()
            .id('loading_progress_bar')
            .width(48)
            .height(48)
            .color($r('app.color.accent'))
        }

        // ErrorPanelHelper: startLoading is a no-op here, so retry re-reads the database.
        if (this.errorInfo !== null) {
          Column() {
            Text(this.errorInfo)
              .id('error_message_view')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor(COLOR_ON_SURFACE)
              .textAlign(TextAlign.Center)
            Button(Localization.buttonLabel('retry'))
              .id('error_retry_button')
              .fontSize(16)
              .fontColor($r('app.color.on_primary'))
              .backgroundColor(servicePrimaryColor(this.activeServiceId))
              .margin({ top: 4 })
              .onClick(() => {
                this.loadSubscriptions();
              })
          }
          .id('error_panel')
          .padding(16)
          .alignItems(HorizontalAlign.Center)
        }
      }
      .width('100%')
      .layoutWeight(1)
    }
    .id('SubscriptionFragmentPage')
    .width('100%')
    .height('100%')
    .backgroundColor(themedBackground(this.blackTheme))
  }
}
