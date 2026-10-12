/**
 * S3 — BookmarkFragment (screen_bookmark).
 *
 * ONE reorderable list mixing two row types under the SAME source id (R.id.itemRoot): a local
 * playlist row (PlaylistMetadataEntry) opens LocalPlaylistFragment, a remote/bookmarked one
 * (PlaylistRemoteEntity) opens PlaylistFragment. The shared row id is deliberate — Rule 12's
 * list-row exception; the replay resolves `tap-card-N` by index.
 *
 * The rows come from MergedPlaylistManager.getMergedOrderedPlaylists(), i.e. the LocalPlaylistManager
 * and RemotePlaylistManager queries merged by display_index — never a literal list.
 *
 * Ordering is persisted the way the source does it: the drag handle swaps rows, DebounceSaver
 * (3000 ms) batches the writes, saveImmediate() rewrites every changed display_index together
 * with the batched deletions, and a database emission arriving mid-reorder is IGNORED.
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

import { CompositeDisposable } from '../common/rx/Rx';
import { DebounceSaver } from '../common/util/DebounceSaver';
import { LocalPlaylistManager, RemotePlaylistManager } from '../common/db/PlaylistManager';
import { LocalItemType } from '../model/enums/LocalItemLocalItemType';
import { PlaylistLocalItem } from '../model/db/view/PlaylistLocalItem';
import { PlaylistMetadataEntry } from '../model/db/view/PlaylistMetadataEntry';
import { PlaylistRemoteEntity } from '../model/db/entity/PlaylistRemoteEntity';
import { Localization } from '../common/i18n/Localization';
import { getNameOfServiceById } from '../components/SelectedTabsAdapter';

import { FallbackViewHolder } from '../components/FallbackViewHolder';
import { HeaderFooterHolder } from '../components/HeaderFooterHolder';
import { DialogAction, InfoItemDialog } from '../components/InfoItemDialog';
import { LocalBookmarkPlaylistItemHolder } from '../components/LocalBookmarkPlaylistItemHolder';
import { LocalItemHolder } from '../components/LocalItemHolder';
import { LocalItemDataSource } from '../components/LocalItemListAdapter';
import { LocalPlaylistItemHolder } from '../components/LocalPlaylistItemHolder';
import { LocalPlaylistStreamItemHolder } from '../components/LocalPlaylistStreamItemHolder';
import { LocalStatisticStreamItemHolder } from '../components/LocalStatisticStreamItemHolder';
import { PlaylistItemHolder } from '../components/PlaylistItemHolder';
import { RemoteBookmarkPlaylistItemHolder } from '../components/RemoteBookmarkPlaylistItemHolder';
import { RemotePlaylistItemHolder } from '../components/RemotePlaylistItemHolder';
import { DIALOG_MASK_COLOR } from '../common/theme/ServiceTheme';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

const TAG: string = 'BookmarkFragment';

/** BookmarkFragment.onCreate(): new DebounceSaver(3000, this) — not the 10 s default. */
const SAVE_DEBOUNCE_MILLIS: number = 3000;

/**
 * How far the handle must travel for one position, until a row reports its real height through
 * onRowHeight. ponytail: a fixed fallback; the measured height replaces it on the first layout.
 */
const DEFAULT_ROW_STEP_VP: number = 56;

/* //////////////////////////////////////////////////////////////////////////
// S5 — STYLE TOKENS. The app-level palette/metrics come from
// results/logs/style-baseline-candidate.json (device-observed on screen_main_activity) and are
// reused verbatim; everything else is read off capture S0043 (1080x2340 @3x) or the migrated
// NewPipe resources. Capture: toolbar [0,72][1080,240] = 56vp of colorPrimary with the title
// baseline starting at 216px = 72vp, body over @color/light_background_color.
////////////////////////////////////////////////////////////////////////// */

/** ?attr/colorPrimary = @color/light_youtube_primary_color. Capture: #E53935. */
const COLOR_PRIMARY: Resource = $r('app.color.primary');
/** ?android:attr/windowBackground = @color/light_background_color. Capture: #EEEEEE. */
const COLOR_SURFACE: Resource = $r('app.color.background');
/** ToolbarTheme's on-primary: the title over colorPrimary. */
const COLOR_ON_PRIMARY: Resource = $r('app.color.on_primary');
/** ?android:textColorPrimary (87% black). */
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');
/** ?android:textColorSecondary (54% black). */
const COLOR_SECONDARY_TEXT: Resource = $r('app.color.on_surface_variant');

/** ?attr/actionBarSize — toolbar [0,72][1080,240] = 168px. */
const TOOLBAR_HEIGHT: number = 56;
/** ToolbarTheme title size, and the inset the navigation icon leaves before it (216px = 72vp). */
const TOOLBAR_TITLE_SIZE: number = 20;
const TOOLBAR_TITLE_INSET: number = 72;
/** ActionBar icon inset: the 24vp Up glyph centred in its 56vp touch target ((56-24)/2). */
const TOOLBAR_ICON_INSET: number = 16;
/** list_empty_view: textAppearanceLarge shrug, subtitle 6dp below it inside a 16dp inset. */
const EMPTY_ART_SIZE: number = 22;
const EMPTY_SUBTITLE_GAP: number = 6;
const EMPTY_SUBTITLE_INSET: number = 16;
/** Body2 — the error panel's message and the empty-list subtitle. */
const BODY_TEXT_SIZE: number = 14;
/** Material dialog metrics: 24dp gutters, a 48dp list row, 20sp title. */
const DIALOG_GUTTER: number = 24;
/** The AlertDialog card's own width, now that customStyle leaves sizing to the builder. */
const DIALOG_CARD_WIDTH: number = 294;
const DIALOG_TITLE_SIZE: number = 20;
const DIALOG_BODY_SIZE: number = 16;
const DIALOG_RADIUS: number = 4;

/** One entry of BookmarkFragment's `deletedItems` list: Pair<Long, LocalItem.LocalItemType>. */
class DeletedItem {
  readonly uid: number;
  readonly itemType: LocalItemType;

  constructor(uid: number, itemType: LocalItemType) {
    this.uid = uid;
    this.itemType = itemType;
  }
}

/** LocalPlaylistFragment.getInstance(playlistId, name). */
class LocalPlaylistParams {
  readonly playlistId: number;
  readonly name: string;

  constructor(playlistId: number, name: string) {
    this.playlistId = playlistId;
    this.name = name;
  }
}

/** PlaylistFragment.getInstance(serviceId, url, name). */
class RemotePlaylistParams {
  readonly serviceId: number;
  readonly url: string;
  readonly name: string;

  constructor(serviceId: number, url: string, name: string) {
    this.serviceId = serviceId;
    this.url = url;
    this.name = name;
  }
}

function displayIndexOf(item: PlaylistLocalItem): number {
  return item.displayIndex === null ? 0 : item.displayIndex;
}

function streamCountOf(item: PlaylistLocalItem): number {
  if (item instanceof PlaylistMetadataEntry) {
    return item.streamCount;
  }
  if (item instanceof PlaylistRemoteEntity) {
    return item.streamCount === null ? 0 : item.streamCount;
  }
  return 0;
}

/**
 * Only a remote playlist carries an uploader; a local one leaves itemUploaderView INVISIBLE.
 *
 * RemoteBookmarkPlaylistItemHolder.updateFromItem() sets this to
 * concatenateStrings(item.getUploader(), NewPipe.getNameOfService(item.getServiceId())) - the
 * reference row reads "Freak Slug • Bandcamp", not "Freak Slug". The port dropped the
 * service half, so a bookmark list mixing services could not be told apart.
 */
function uploaderOf(item: PlaylistLocalItem): string | null {
  if (!(item instanceof PlaylistRemoteEntity)) {
    return null;
  }
  const remote: PlaylistRemoteEntity = item;
  const name: string = remote.uploader === null ? '' : remote.uploader;
  return Localization.concatenateStrings([name, getNameOfServiceById(remote.serviceId)]);
}

/** Port of MergedPlaylistManager.addItemsWithSameIndex(): CASE_INSENSITIVE_ORDER, nulls last. */
function addItemsWithSameIndex(result: PlaylistLocalItem[], items: PlaylistLocalItem[]): void {
  items.sort((a: PlaylistLocalItem, b: PlaylistLocalItem): number => {
    const an: string | null = a.orderingName;
    const bn: string | null = b.orderingName;
    if (an === null) {
      return bn === null ? 0 : 1;
    }
    if (bn === null) {
      return -1;
    }
    const al: string = an.toLowerCase();
    const bl: string = bn.toLowerCase();
    if (al < bl) {
      return -1;
    }
    return al > bl ? 1 : 0;
  });
  for (const item of items) {
    result.push(item);
  }
}

/** Port of MergedPlaylistManager.addItem(). */
function addMergedItem(result: PlaylistLocalItem[], item: PlaylistLocalItem,
  itemsWithSameIndex: PlaylistLocalItem[]): void {
  if (itemsWithSameIndex.length > 0
    && displayIndexOf(itemsWithSameIndex[0]) !== displayIndexOf(item)) {
    addItemsWithSameIndex(result, itemsWithSameIndex);
    itemsWithSameIndex.splice(0, itemsWithSameIndex.length);
  }
  itemsWithSameIndex.push(item);
}

/**
 * Port of MergedPlaylistManager.merge(): a merge-sort style pass over two lists already ordered by
 * display_index. The data layer has no MergedPlaylistManager module yet (reported as an S1 gap),
 * so the port lives here until it moves to ets/common/.
 */
function mergePlaylists(localPlaylists: PlaylistMetadataEntry[],
  remotePlaylists: PlaylistRemoteEntity[]): PlaylistLocalItem[] {
  const result: PlaylistLocalItem[] = [];
  const itemsWithSameIndex: PlaylistLocalItem[] = [];

  let i: number = 0;
  let j: number = 0;
  while (i < localPlaylists.length) {
    while (j < remotePlaylists.length
      && displayIndexOf(remotePlaylists[j]) <= displayIndexOf(localPlaylists[i])) {
      addMergedItem(result, remotePlaylists[j], itemsWithSameIndex);
      j++;
    }
    addMergedItem(result, localPlaylists[i], itemsWithSameIndex);
    i++;
  }
  while (j < remotePlaylists.length) {
    addMergedItem(result, remotePlaylists[j], itemsWithSameIndex);
    j++;
  }
  addItemsWithSameIndex(result, itemsWithSameIndex);

  return result;
}

@Entry
@Component
export struct BookmarkFragmentPage {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  /** The adapter's backing list — LocalItemListAdapter.localItems. */
  @State bookmarksList: LocalItemDataSource = new LocalItemDataSource();
  /** The display_index each row is saved back with (saveImmediate -> setDisplayIndex(i)). */
  @State rowOrder: number[] = [];
  /** handleResult(result): empty means showEmptyState(), otherwise the adapter gets the items. */
  @State result: PlaylistLocalItem[] = [];
  @State isLoading: boolean = true;
  /** ErrorInfo(exception, REQUESTED_BOOKMARK, "Loading playlists") from the Subscriber onError. */
  @State errorInfo: string | null = null;

  @State private menuTitle: string = '';
  @State private menuActions: DialogAction[] = [];
  @State private renameName: string = '';
  @State private deleteTitle: string = '';

  /** BaseLocalListFragment.getListHeaderSupplier() is null here — hasHeader() is false. */
  private hasHeader: boolean = false;
  /**
   * !useAsFrontPage -> setTitle(R.string.tab_bookmarks); when the host owns the bar it draws the
   * title itself and this screen must not draw a second one. Set by MainActivityPage through
   * AppStorage: this is an @Entry component, and ArkTS refuses @Prop on those.
   *
   */
  @StorageProp('mainShellOwnsToolbar') useAsFrontPage: boolean = false;

  /**
   * Whether the rows carry the reorder handle. A method, not a field: ArkTS refuses to hand an
   * @StorageProp straight to a child's regular property.
   *
   * Both of this screen's entry points draw it. This used to be gated so that the drawer's
   * back-arrow state drew no handle, on the reading that the handle belongs to the tab-strip
   * entry point - but the reference contradicts that: on Android 0.29.1 the drawer's
   * "Bookmarked Playlists" shows the handle on every row, exactly as the bookmarks tab does
   * (TC-NAV-156, captured on both entry points). BookmarkFragment reorders the same list in
   * either state, so suppressing the handle also removed the only way to reorder from the
   * drawer.
   */
  private useItemHandle(): boolean {
    return true;
  }

  private localPlaylistManager: LocalPlaylistManager | null = null;
  private remotePlaylistManager: RemotePlaylistManager | null = null;
  private renameTarget: PlaylistMetadataEntry | null = null;
  private deleteTarget: PlaylistLocalItem | null = null;

  /** isLoadingComplete: saveImmediate() refuses to write a list that never finished loading. */
  private isLoadingComplete: boolean = false;
  /** deletedItems: uids removed from the adapter, flushed by the next saveImmediate(). */
  private deletedItems: DeletedItem[] = [];
  private debounceSaver: DebounceSaver = new DebounceSaver(SAVE_DEBOUNCE_MILLIS, (): void => {
    this.saveImmediate();
  });
  /** BookmarkFragment.disposables — everything this page must tear down (Rule 8). */
  private disposables: CompositeDisposable = new CompositeDisposable();

  /** The row the handle is dragging (-1 = none), and where the pointer last crossed a row. */
  /** A drag handle is under a finger: the List must not scroll while it is (see itemsList()). */
  @State private handleHeld: boolean = false;
  private draggingIndex: number = -1;
  private dragBaselineY: number = 0;
  private rowStep: number = DEFAULT_ROW_STEP_VP;

  /** The long-press menu: AlertDialog.Builder().setItems(rename / delete / unset thumbnail). */
  private menuDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    builder: InfoItemDialog({ title: this.menuTitle, actions: this.menuActions })
  });

  private renameDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    // customStyle: the builder draws its own square card. Without it the system dialog
    // container draws a rounded surface UNDER the builder's content, so borderRadius(0)
    // on the inner Column changes nothing that is visible.
    customStyle: true,
    builder: RenameDialog({
      name: this.renameName,
      onRename: (name: string): void => {
        this.changeLocalPlaylistName(name);
      }
    })
  });

  private deleteDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    // customStyle: the builder draws its own square card. Without it the system dialog
    // container draws a rounded surface UNDER the builder's content, so borderRadius(0)
    // on the inner Column changes nothing that is visible.
    customStyle: true,
    builder: DeleteConfirmDialog({
      title: $deleteTitle,
      onDelete: (): void => {
        this.deleteItem();
      }
    })
  });

  aboutToAppear(): void {
    // disposables.add(debounceSaver.getDebouncedSaver()) — the timer dies with the page.
    this.disposables.add(this.debounceSaver);
    this.loadPlaylists();
  }

  /** onPause(): save on exit — the pending reorder must not die with the page. */
  onPageHide(): void {
    this.saveImmediate();
  }

  /** onDestroy(): flush, then complete the debounce signal and drop its timer (Rule 8). */
  aboutToDisappear(): void {
    this.saveImmediate();
    this.disposables.dispose();
  }

  /** startLoading() -> getMergedOrderedPlaylists(...).subscribe(getPlaylistsSubscriber()). */
  private loadPlaylists(): void {
    const context: common.Context = getContext(this) as common.Context;
    this.isLoading = true;
    this.errorInfo = null;
    // startLoading(): arm the debounced saver and start from a clean, not-yet-loaded slate.
    this.debounceSaver.setNoChangesToSave();
    this.isLoadingComplete = false;

    LocalPlaylistManager.of(context)
      .then((local: LocalPlaylistManager) => {
        this.localPlaylistManager = local;
        return RemotePlaylistManager.of(context);
      })
      .then((remote: RemotePlaylistManager) => {
        this.remotePlaylistManager = remote;
        return this.queryMerged();
      })
      .catch((err: BusinessError) => {
        // Subscriber.onError -> showError(ErrorInfo(exception, REQUESTED_BOOKMARK, ...)).
        this.isLoading = false;
        this.errorInfo = err.message;
        hilog.error(0x0000, TAG, 'Loading playlists failed: %{public}s', err.message);
      });
  }

  private async queryMerged(): Promise<void> {
    const local: LocalPlaylistManager | null = this.localPlaylistManager;
    const remote: RemotePlaylistManager | null = this.remotePlaylistManager;
    if (local === null || remote === null) {
      return;
    }
    const localPlaylists: PlaylistMetadataEntry[] = await local.getPlaylists();
    const remotePlaylists: PlaylistRemoteEntity[] = await remote.getPlaylists();
    this.handleResult(mergePlaylists(localPlaylists, remotePlaylists));
  }

  /**
   * Port of Subscriber.onNext() + handleResult(): clear, then either showEmptyState() or
   * addItems(). A database emission arriving while the user is mid-reorder is DROPPED — the
   * source's `!debounceSaver.getIsModified()` guard — so the pending order is never clobbered.
   */
  private handleResult(merged: PlaylistLocalItem[]): void {
    // A load finishing after teardown must not touch @State — the disposal the source's
    // CompositeDisposable does by unsubscribing the Flowable.
    if (this.disposables.isDisposed() || this.debounceSaver.getIsModified()) {
      return;
    }
    this.result = merged;
    this.rowOrder = merged.map((item: PlaylistLocalItem): number => displayIndexOf(item));
    this.bookmarksList.setItems(merged);
    this.isLoading = false;
    this.isLoadingComplete = true;
  }

  /** Re-read the @State mirrors of the adapter's list after an in-place mutation. */
  private syncFromAdapter(): void {
    const items: PlaylistLocalItem[] = this.bookmarksList.getItemsList();
    this.result = items.slice();
    this.rowOrder = items.map((item: PlaylistLocalItem): number => displayIndexOf(item));
  }

  /** OnClickGesture.selected. */
  private onItemSelected(item: PlaylistLocalItem): void {
    const name: string = item.orderingName === null ? '' : item.orderingName;
    if (item instanceof PlaylistMetadataEntry) {
      router.pushUrl({
        url: 'pages/LocalPlaylistFragmentPage',
        params: new LocalPlaylistParams(item.uid, name)
      }).catch((err: BusinessError) => {
        hilog.error(0x0000, TAG, 'pushUrl LocalPlaylistFragment: %{public}s', err.message);
      });
    } else if (item instanceof PlaylistRemoteEntity) {
      router.pushUrl({
        url: 'pages/PlaylistFragmentPage',
        params: new RemotePlaylistParams(item.serviceId, item.url === null ? '' : item.url, name)
      }).catch((err: BusinessError) => {
        hilog.error(0x0000, TAG, 'pushUrl PlaylistFragment: %{public}s', err.message);
      });
    }
  }

  /** OnClickGesture.held: local -> showLocalDialog(), remote -> showRemoteDeleteDialog(). */
  private onItemHeld(item: PlaylistLocalItem): void {
    if (item instanceof PlaylistRemoteEntity) {
      this.showDeleteDialog(item);
      return;
    }
    if (item instanceof PlaylistMetadataEntry) {
      this.showLocalDialog(item);
    }
  }

  private showLocalDialog(entry: PlaylistMetadataEntry): void {
    const actions: DialogAction[] = [];
    actions.push(new DialogAction($r('app.string.rename'), 'Rename', (): void => {
      this.showRenameDialog(entry);
    }));
    actions.push(new DialogAction($r('app.string.delete'), 'Delete', (): void => {
      this.showDeleteDialog(entry);
    }));

    const manager: LocalPlaylistManager | null = this.localPlaylistManager;
    if (manager === null) {
      this.openLocalMenu(entry, actions);
      return;
    }
    // The unset entry exists ONLY when the thumbnail is permanent.
    manager.getIsPlaylistThumbnailPermanent(entry.uid)
      .then((isPermanent: boolean) => {
        if (isPermanent) {
          actions.push(new DialogAction($r('app.string.unset_playlist_thumbnail'),
            'Unset permanent thumbnail', (): void => {
              this.unsetThumbnail(entry);
            }));
        }
        this.openLocalMenu(entry, actions);
      })
      .catch((err: BusinessError) => {
        hilog.error(0x0000, TAG, 'getIsPlaylistThumbnailPermanent: %{public}s', err.message);
        this.openLocalMenu(entry, actions);
      });
  }

  private openLocalMenu(entry: PlaylistMetadataEntry, actions: DialogAction[]): void {
    this.menuTitle = entry.orderingName === null ? '' : entry.orderingName;
    this.menuActions = actions;
    this.menuDialog.open();
  }

  private showRenameDialog(entry: PlaylistMetadataEntry): void {
    this.renameTarget = entry;
    this.renameName = entry.orderingName === null ? '' : entry.orderingName;
    this.renameDialog.open();
  }

  private showDeleteDialog(item: PlaylistLocalItem): void {
    this.deleteTarget = item;
    this.deleteTitle = item.orderingName === null ? '' : item.orderingName;
    this.deleteDialog.open();
  }

  /** changeLocalPlaylistName(uid, name). */
  private changeLocalPlaylistName(name: string): void {
    const manager: LocalPlaylistManager | null = this.localPlaylistManager;
    const target: PlaylistMetadataEntry | null = this.renameTarget;
    if (manager === null || target === null) {
      return;
    }
    manager.renamePlaylist(target.uid, name)
      .then(() => {
        return this.queryMerged();
      })
      .catch((err: BusinessError) => {
        hilog.error(0x0000, TAG, 'Changing playlist name: %{public}s', err.message);
      });
  }

  /** changePlaylistThumbnail(uid, getAutomaticPlaylistThumbnailStreamId(uid), false). */
  private unsetThumbnail(entry: PlaylistMetadataEntry): void {
    const manager: LocalPlaylistManager | null = this.localPlaylistManager;
    if (manager === null) {
      return;
    }
    manager.getAutomaticPlaylistThumbnailStreamId(entry.uid)
      .then((streamId: number) => {
        return manager.changePlaylistThumbnail(entry.uid, streamId, false);
      })
      .then(() => {
        return this.queryMerged();
      })
      .catch((err: BusinessError) => {
        hilog.error(0x0000, TAG, 'Unsetting playlist thumbnail: %{public}s', err.message);
      });
  }

  /**
   * Port of deleteItem(item): drop the row, record its uid in `deletedItems`, flag the saver and
   * flush immediately. The row is NOT deleted straight through — the delete rides the same
   * saveImmediate() batch as the reordered display indexes, so one transaction carries both.
   */
  private deleteItem(): void {
    const item: PlaylistLocalItem | null = this.deleteTarget;
    if (item === null) {
      return;
    }
    this.bookmarksList.removeItem(item);

    if (item instanceof PlaylistMetadataEntry) {
      this.deletedItems.push(new DeletedItem(item.uid, LocalItemType.PLAYLIST_LOCAL_ITEM));
    } else if (item instanceof PlaylistRemoteEntity) {
      this.deletedItems.push(new DeletedItem(item.uid, LocalItemType.PLAYLIST_REMOTE_ITEM));
    }
    this.deleteTarget = null;
    this.syncFromAdapter();

    this.debounceSaver.setHasChangesToSave();
    this.saveImmediate();
  }

  /**
   * Port of saveImmediate(): renumber every changed display_index from the row's position,
   * collect the batched deletions, and commit both managers in one go. Nothing is written unless
   * the list finished loading AND something actually changed.
   */
  private saveImmediate(): void {
    const local: LocalPlaylistManager | null = this.localPlaylistManager;
    const remote: RemotePlaylistManager | null = this.remotePlaylistManager;
    if (local === null || remote === null) {
      return;
    }
    if (!this.isLoadingComplete || !this.debounceSaver.getIsModified()) {
      return;
    }
    this.debounceSaver.cancel();

    const items: PlaylistLocalItem[] = this.bookmarksList.getItemsList();
    const localItemsUpdate: PlaylistMetadataEntry[] = [];
    const localItemsDeleteUid: number[] = [];
    const remoteItemsUpdate: PlaylistRemoteEntity[] = [];
    const remoteItemsDeleteUid: number[] = [];

    // Calculate display index — the row's position IS its new display_index.
    for (let i = 0; i < items.length; i++) {
      const item: PlaylistLocalItem = items[i];
      if (item instanceof PlaylistMetadataEntry && item.displayIndex !== i) {
        item.displayIndex = i;
        localItemsUpdate.push(item);
      } else if (item instanceof PlaylistRemoteEntity && item.displayIndex !== i) {
        item.displayIndex = i;
        remoteItemsUpdate.push(item);
      }
    }

    // Find deleted items.
    for (const deleted of this.deletedItems) {
      if (deleted.itemType === LocalItemType.PLAYLIST_LOCAL_ITEM) {
        localItemsDeleteUid.push(deleted.uid);
      } else if (deleted.itemType === LocalItemType.PLAYLIST_REMOTE_ITEM) {
        remoteItemsDeleteUid.push(deleted.uid);
      }
    }
    this.deletedItems = [];
    this.rowOrder = items.map((item: PlaylistLocalItem): number => displayIndexOf(item));

    // 1. update local playlists  2. update remote playlists  3. setNoChangesToSave
    local.updatePlaylists(localItemsUpdate, localItemsDeleteUid)
      .then((): Promise<void> => {
        return remote.updatePlaylists(remoteItemsUpdate, remoteItemsDeleteUid);
      })
      .then((): Promise<void> => {
        this.debounceSaver.setNoChangesToSave();
        // No Room Flowable here: re-reading the merged query IS the live pipeline.
        return this.queryMerged();
      })
      .catch((err: BusinessError) => {
        this.errorInfo = err.message;
        hilog.error(0x0000, TAG, 'Saving playlist: %{public}s', err.message);
      });
  }

  /**
   * itemHandle pan start: OnClickGesture.drag -> itemTouchHelper.startDrag(). There is no
   * long-press drag and no swipe (isLongPressDragEnabled/isItemViewSwipeEnabled are both false).
   * The baseline is the travel already SPENT on swaps, and a PanGesture reports its offset
   * cumulatively from the pickup, so it starts at zero rather than at a screen coordinate.
   */
  private onRowDragStart(item: PlaylistLocalItem): void {
    // By uid, not by identity: after a save the list is re-read into NEW objects while
    // LazyForEach keeps the row nodes (same keys), so a holder's `item` is stale and
    // indexOf() answered -1 - every drag after the first did nothing.
    this.draggingIndex = this.bookmarksList.getItemsList().findIndex(
      (candidate: PlaylistLocalItem): boolean =>
        candidate.uid === item.uid && candidate.localItemType === item.localItemType);
    this.dragBaselineY = 0;
  }

  /**
   * The ItemTouchHelper's onMove(): each full row of travel swaps this row with its neighbour
   * and flags the saver, exactly as the source callback does.
   */
  private onRowDragUpdate(offsetY: number): void {
    if (this.draggingIndex < 0) {
      return;
    }
    const delta: number = offsetY - this.dragBaselineY;
    if (delta >= this.rowStep) {
      this.moveRow(this.draggingIndex + 1);
      this.dragBaselineY = this.dragBaselineY + this.rowStep;
    } else if (delta <= -this.rowStep) {
      this.moveRow(this.draggingIndex - 1);
      this.dragBaselineY = this.dragBaselineY - this.rowStep;
    }
  }

  /** The drop. BookmarkFragment leaves the write to the 3000 ms debounce (onMove only flags). */
  private onRowDragEnd(): void {
    this.draggingIndex = -1;
  }

  /** onMove(): swapItems(source, target) and, when it took, setHasChangesToSave(). */
  private moveRow(targetIndex: number): void {
    if (!this.bookmarksList.swapItems(this.draggingIndex, targetIndex)) {
      return;
    }
    this.draggingIndex = targetIndex;
    this.syncFromAdapter();
    this.debounceSaver.setHasChangesToSave();
  }

  /** A row reports its measured height, so one drag step is one real row. */
  private onRowHeight(height: number): void {
    this.rowStep = height;
  }

  /**
   * LocalItemListAdapter's List, drawn here rather than through that component because this
   * list reorders by handle and the shared List cannot: (1) its inner scrollbar's touch zone
   * covers the handle at the right edge, so a finger on the handle grabbed the scrollbar
   * (hilog 'AceScrollBar: inner scrollBar drag start'); (2) the List's scroll recognizer wins
   * the vertical move against the handle's PanGesture, so the list scrolled instead of the
   * row. Scrollbar off, and no scroll interaction for as long as a handle is held - then the
   * handle's pan is the only vertical recognizer left and the existing swap maths runs.
   * ponytail: the same two lines belong on LocalItemListAdapter as an option once its owner
   * can take them; then this goes back to the shared component.
   */
  @Builder
  itemsList() {
    List() {
      LazyForEach(this.bookmarksList, (item: PlaylistLocalItem) => {
        ListItem() {
          this.itemRow(item)
        }
        // One drag step is one ListItem. The holder's own Row is 50vp of a ~74vp item, and a
        // step measured from it swapped every two-thirds of a row - the overshoot.
        .onAreaChange((oldValue: Area, newValue: Area) => {
          const measured: number =
            typeof newValue.height === 'number' ? newValue.height as number : 0;
          if (measured > 0) {
            this.onRowHeight(measured);
          }
        })
      }, (item: PlaylistLocalItem) => `${item.localItemType}-${item.uid}`)
    }
    .id('items_list')
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .enableScrollInteraction(!this.handleHeld)
  }

  /** LocalItemListAdapter.onBindViewHolder(): every row is wrapped in the shared row root. */
  @Builder
  itemRow(item: PlaylistLocalItem) {
    LocalItemHolder({
      item: item,
      onSelected: (selected: PlaylistLocalItem): void => {
        this.onItemSelected(selected);
      },
      onHeld: (held: PlaylistLocalItem): void => {
        this.onItemHeld(held);
      },
      // `this.itemBody` would re-bind `this` to LocalItemHolder and lose this page's members.
      body: (row: PlaylistLocalItem): void => {
        this.itemBody(row);
      }
    })
  }

  /**
   * LocalItemListAdapter.getItemViewType() + onCreateViewHolder(): the holder is chosen by the
   * item's LocalItemType, and — for a playlist — by whether the list uses the drag handle.
   * BookmarkFragment sets useItemHandle = useAsFrontPage, so the two BOOKMARK branches are the
   * tab-strip entry point's; the plain branches are the drawer's, and every other local list's.
   */
  @Builder
  itemBody(item: PlaylistLocalItem) {
    if (item.localItemType === LocalItemType.PLAYLIST_LOCAL_ITEM) {
      if (this.useItemHandle()) {
        LocalBookmarkPlaylistItemHolder({
          item: item,
          onRowDragStart: (dragged: PlaylistLocalItem): void => {
            this.onRowDragStart(dragged);
          },
          onRowDragUpdate: (offsetY: number): void => {
            this.onRowDragUpdate(offsetY);
          },
          onRowDragEnd: (): void => {
            this.onRowDragEnd();
          },
          onHandleTouch: (held: boolean): void => {
            this.handleHeld = held;
          },
          body: this.playlistBody
        })
      } else {
        LocalPlaylistItemHolder({ item: item, body: this.playlistBody })
      }
    } else if (item.localItemType === LocalItemType.PLAYLIST_REMOTE_ITEM) {
      if (this.useItemHandle()) {
        RemoteBookmarkPlaylistItemHolder({
          item: item,
          onRowDragStart: (dragged: PlaylistLocalItem): void => {
            this.onRowDragStart(dragged);
          },
          onRowDragUpdate: (offsetY: number): void => {
            this.onRowDragUpdate(offsetY);
          },
          onRowDragEnd: (): void => {
            this.onRowDragEnd();
          },
          onHandleTouch: (held: boolean): void => {
            this.handleHeld = held;
          },
          body: this.playlistBody
        })
      } else {
        RemotePlaylistItemHolder({ item: item, body: this.playlistBody })
      }
    } else if (item.localItemType === LocalItemType.PLAYLIST_STREAM_ITEM) {
      LocalPlaylistStreamItemHolder({
        thumbnailUrl: item.thumbnailUrl,
        title: item.orderingName,
        showItemHandle: this.useItemHandle()
      })
    } else if (item.localItemType === LocalItemType.STATISTIC_STREAM_ITEM) {
      LocalStatisticStreamItemHolder({
        thumbnailUrl: item.thumbnailUrl,
        title: item.orderingName
      })
    } else {
      // LocalItemListAdapter's `default:` branch.
      FallbackViewHolder()
    }
  }

  /** PlaylistItemHolder: the four views a playlist row shares (super.updateFromItem()). */
  @Builder
  playlistBody(item: PlaylistLocalItem) {
    PlaylistItemHolder({
      thumbnailUrl: item.thumbnailUrl,
      title: item.orderingName,
      streamCount: streamCountOf(item),
      uploader: uploaderOf(item),
      showUploader: item.localItemType === LocalItemType.PLAYLIST_REMOTE_ITEM
    })
  }

  build() {
    Column() {
      if (!this.useAsFrontPage) {
        // setTitle(R.string.tab_bookmarks) lands in the host's colorPrimary toolbar. Capture
        // S0043: the Up arrow fills [0,72][168,240] = a 56vp box and the title starts at
        // 216px = 72vp, i.e. that box plus a 16vp gap.
        Row() {
          // S6 — the back affordance the capture shows. MainActivity's ActionBarDrawerToggle
          // draws Up (not the hamburger) while BookmarkFragment is in fragment_holder, and
          // onHomeButtonPressed() pops the stack; pushed as its own page here, that pop is
          // router.back(). Same source asset MainActivityPage loads for the same affordance.
          Image($r('app.media.ic_arrow_back'))
            .id('navigate_back')
            .width(TOOLBAR_HEIGHT)
            .height(TOOLBAR_HEIGHT)
            .padding(TOOLBAR_ICON_INSET)
            .objectFit(ImageFit.Contain)
            .fillColor(COLOR_ON_PRIMARY)
            // ?attr/actionBarItemBackground — the borderless ripple an ActionBar item carries.
            .clickEffect({ level: ClickEffectLevel.LIGHT })
            // The Up button's contentDescription, which is what the capture matched it by.
            // It does NOT replace .id(): accessibilityText never surfaces in a uitest dump.
            .accessibilityText('Navigate up')
            .onClick(() => {
              router.back();
            })

          Text($r('app.string.tab_bookmarks'))
            .id('bookmark_title')
            .layoutWeight(1)
            .height(TOOLBAR_HEIGHT)
            .fontColor(COLOR_ON_PRIMARY)
            .fontSize(TOOLBAR_TITLE_SIZE)
            .fontWeight(FontWeight.Medium)
            .padding({ left: TOOLBAR_TITLE_INSET - TOOLBAR_HEIGHT, right: 16 })
            .align(Alignment.Start)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .height(TOOLBAR_HEIGHT)
        .backgroundColor(COLOR_PRIMARY)
        .alignItems(VerticalAlign.Center)
      }

      if (this.hasHeader) {
        HeaderFooterHolder()
      }

      if (this.isLoading) {
        LoadingProgress()
          .id('loading_progress_bar')
          .width(48)
          .height(48)
          .color(COLOR_PRIMARY)
          .margin({ top: 24 })
      } else if (this.errorInfo !== null) {
        Column() {
          Text(this.errorInfo)
            .fontSize(BODY_TEXT_SIZE)
            .fontColor(COLOR_SECONDARY_TEXT)
            .textAlign(TextAlign.Center)
        }
        .id('error_panel')
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .padding(EMPTY_SUBTITLE_INSET)
      } else if (this.result.length === 0) {
        // showEmptyState(): list_empty_view — the shrug plus @string/empty_list_subtitle,
        // gravity=center over a 128dp minimum, subtitle 6dp under the art in a 16dp inset.
        Column() {
          Text('¯\\_(ツ)_/¯')
            .fontSize(EMPTY_ART_SIZE)
            .fontColor(COLOR_ON_SURFACE)
          Text($r('app.string.empty_list_subtitle'))
            .fontSize(BODY_TEXT_SIZE)
            .fontColor(COLOR_SECONDARY_TEXT)
            .textAlign(TextAlign.Center)
            .margin({ top: EMPTY_SUBTITLE_GAP })
            .padding({ left: EMPTY_SUBTITLE_INSET, right: EMPTY_SUBTITLE_INSET })
        }
        .id('empty_state_view')
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Column() {
          this.itemsList()
        }
        .width('100%')
        .layoutWeight(1)
      }
    }
    .id('BookmarkFragmentPage')
    .width('100%')
    .height('100%')
    .backgroundColor(themedBackground(this.blackTheme))
  }
}

/** showRenameDialog(): dialog_edit_text prefilled with the current name. */
@CustomDialog
struct RenameDialog {
  controller?: CustomDialogController;
  name: string = '';
  onRename: (name: string) => void = (name: string): void => {
    hilog.debug(0x0000, TAG, 'RenameDialog: rename to %{public}s not bound', name);
  };

  build() {
    Column() {
      TextInput({ text: this.name, placeholder: $r('app.string.name') })
        .id('dialog_edit_text')
        .fontSize(DIALOG_BODY_SIZE)
        .fontColor(COLOR_ON_SURFACE)
        .margin({ top: DIALOG_GUTTER })
        .onChange((value: string) => {
          this.name = value;
        })

      Row() {
        Button($r('app.string.cancel'))
          .id('Cancel')
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .fontColor(COLOR_PRIMARY)
          .fontSize(BODY_TEXT_SIZE)
          .onClick(() => {
            this.controller?.close();
          })
        Button($r('app.string.rename_playlist'))
          .id('Rename')
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .fontColor(COLOR_PRIMARY)
          .fontSize(BODY_TEXT_SIZE)
          .onClick(() => {
            this.controller?.close();
            this.onRename(this.name);
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .margin({ top: DIALOG_GUTTER / 2 })
    }
    // customStyle hands the sizing to the builder too, so the card sets its own width rather
    // than filling the screen edge to edge. 294vp is the width the other AlertDialogs use.
    .width(DIALOG_CARD_WIDTH)
    .padding({ left: DIALOG_GUTTER, right: DIALOG_GUTTER, top: 8, bottom: 8 })
    .backgroundColor($r('app.color.dialog_background'))
    // Theme.AppCompat.Dialog's window background is a square nine-patch: no corner rounding.
    .borderRadius(0)
  }
}

/** showDeleteDialog(name, item): title = the playlist name, message = delete_playlist_prompt. */
@CustomDialog
struct DeleteConfirmDialog {
  controller?: CustomDialogController;
  /**
   * @Link, not a plain field. A CustomDialogController binds its builder's parameters ONCE, when
   * the controller is constructed - which happens while the page is being built, long before a
   * row is held - so a plain field kept the empty string it was constructed with and the dialog
   * asked about a playlist without naming it. A @Link tracks the page's @State instead.
   */
  @Link title: string;
  onDelete: () => void = (): void => {
    hilog.debug(0x0000, TAG, 'DeleteConfirmDialog: delete not bound');
  };

  build() {
    Column() {
      Text(this.title)
        .id('delete_dialog_title')
        .width('100%')
        .fontSize(DIALOG_TITLE_SIZE)
        .fontColor(COLOR_ON_SURFACE)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 12 })
      Text($r('app.string.delete_playlist_prompt'))
        .width('100%')
        .fontSize(DIALOG_BODY_SIZE)
        .fontColor(COLOR_SECONDARY_TEXT)
        .margin({ top: 12 })

      Row() {
        Button($r('app.string.cancel'))
          .id('Cancel')
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .fontColor(COLOR_PRIMARY)
          .fontSize(BODY_TEXT_SIZE)
          .onClick(() => {
            this.controller?.close();
          })
        Button($r('app.string.delete'))
          .id('Delete')
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .fontColor(COLOR_PRIMARY)
          .fontSize(BODY_TEXT_SIZE)
          .onClick(() => {
            this.controller?.close();
            this.onDelete();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .margin({ top: DIALOG_GUTTER / 2 })
    }
    // customStyle hands the sizing to the builder too, so the card sets its own width rather
    // than filling the screen edge to edge. 294vp is the width the other AlertDialogs use.
    .width(DIALOG_CARD_WIDTH)
    .padding({ left: DIALOG_GUTTER, right: DIALOG_GUTTER, top: 8, bottom: 8 })
    .backgroundColor($r('app.color.dialog_background'))
    // Theme.AppCompat.Dialog's window background is a square nine-patch: no corner rounding.
    .borderRadius(0)
  }
}
