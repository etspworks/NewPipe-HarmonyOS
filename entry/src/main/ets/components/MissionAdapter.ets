/*
 * S3 - port of us.shandian.giga.ui.adapter.MissionAdapter (missions.xml @+id/mission_recycler).
 *
 * ArkUI has no adapter object, so it splits the way InfoListAdapter's did:
 *   - the iterator MissionAdapter walks (the pending section, then the finished section) and its
 *     applyChanges()/notify* mutations -> MissionDataSource below,
 *   - getItemViewType() + onCreateViewHolder() -> the `cell` builder the owning screen passes in,
 *     because it is the screen that knows the row's popup menu and its tap,
 *   - updateList()'s LinearLayoutManager / GridLayoutManager(2) switch -> the `linear` prop, with
 *     MissionsFragment's SpanSizeLookup giving a section header the full span.
 *
 * Rule 7: the mission list is unbounded, so it renders through LazyForEach over IDataSource.
 */
import { Mission } from '../model/app/Mission';
import { DownloadMission } from '../model/app/DownloadMission';

/** MissionAdapter.getItemViewType(): a section header, or a pending / finished mission row. */
export enum MissionRowKind {
  PendingHeader,
  FinishedHeader,
  Pending,
  Finished
}

/** Port of DownloadManager.MissionItem - what the adapter's iterator yields per position. */
export class MissionItem {
  rowKind: MissionRowKind;
  /** The Mission this row renders, or null for a section header. */
  mission: Mission | null;

  constructor(rowKind: MissionRowKind, mission: Mission | null) {
    this.rowKind = rowKind;
    this.mission = mission;
  }
}

/** SPECIAL_PENDING / SPECIAL_FINISHED both render missions_header.xml. */
export function isMissionHeader(item: MissionItem): boolean {
  return item.rowKind === MissionRowKind.PendingHeader
    || item.rowKind === MissionRowKind.FinishedHeader;
}

/**
 * The LazyForEach key for a row.
 *
 * It used to be `${index}-${item.rowKind}`. A key built from the POSITION is not an identity: the
 * moment anything above a row is inserted or removed, every row below it gets a new key, so the
 * loader treats them all as different rows and tears the list down instead of moving what it
 * already has. That is the opposite of what a key is for.
 *
 * A mission's timestamp is unique by construction - startMission() bumps it until the metadata
 * file name is free - so it identifies the row across any reordering. Headers have no mission and
 * there is at most one of each, so their kind is identity enough.
 */
export function missionRowKey(item: MissionItem): string {
  const mission: Mission | null = item.mission;
  if (mission === null) {
    return `header-${item.rowKind}`;
  }
  // The key must also move when the row's CONTENT moves. LazyForEach compares keys on every
  // change notification and reuses the child it already has when the key is unchanged, so a
  // running mission's percentage was announced and then thrown away - the row sat frozen at
  // whatever it read when its key last changed (TC-LIBRARY-169/170/171). `done` is exactly the
  // number the row renders, so it belongs in the identity of what is on screen.
  const done: number = mission instanceof DownloadMission ? (mission as DownloadMission).done : 0;
  // `enqueued` belongs here for the same reason `done` does, and the review of TC-LIBRARY-177
  // found the gap: ticking Enqueue on a PAUSED mission changes no byte count, so the key held
  // still and the row kept its old label. The menu's own tick cleared - the handler had run - and
  // the row underneath went on reading "(queued)" after enqueued was already false. The label is
  // drawn from this flag, so the flag is part of the identity of what is on screen.
  const enqueued: boolean =
    mission instanceof DownloadMission ? (mission as DownloadMission).enqueued : false;
  return `${item.rowKind}-${mission.timestamp}-${done}-${enqueued ? 'q' : 'p'}`;
}

/** The adapter's backing list; applyChanges() rebuilds it from the DownloadManager. */
export class MissionDataSource implements IDataSource {
  private items: MissionItem[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): MissionItem {
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

  /**
   * MissionAdapter.applyChanges(): the whole list is rebuilt from the manager.
   *
   * A row's key is its mission timestamp (missionRowKey above), so a rebuild that changed only a
   * mission's CONTENT reaches LazyForEach with every key unchanged, and onDataReloaded() then
   * reuses the child it already has - repainting nothing. That is why a running row's percentage
   * never moved. When the membership is the same, each row is announced individually instead,
   * which is what tells LazyForEach to rebuild it.
   */
  setItems(items: MissionItem[]): void {
    const sameMembership: boolean = this.items.length === items.length;
    this.items = items;
    for (const listener of this.listeners) {
      if (sameMembership) {
        for (let i: number = 0; i < items.length; i++) {
          listener.onDataChange(i);
        }
      } else {
        listener.onDataReloaded();
      }
    }
  }
}

@Component
export struct MissionAdapter {
  dataSource: MissionDataSource = new MissionDataSource();
  /** MissionsFragment.mLinear: LinearLayoutManager when true, GridLayoutManager(2) otherwise. */
  @Prop linear: boolean = false;
  /** onCreateViewHolder(): the row the owning screen renders for this item. */
  @BuilderParam cell: (item: MissionItem) => void = this.defaultCell;

  @Builder
  defaultCell(item: MissionItem) {
    Row()
  }

  build() {
    // updateList(): the SAME recycler, only its layout manager changes.
    Column() {
      if (this.linear) {
        List() {
          LazyForEach(this.dataSource, (item: MissionItem, index: number) => {
            ListItem() {
              this.cell(item)
            }
          }, (item: MissionItem) => missionRowKey(item))
        }
        .id('mission_recycler')
        .width('100%')
        .height('100%')
      } else {
        Grid() {
          LazyForEach(this.dataSource, (item: MissionItem, index: number) => {
            if (isMissionHeader(item)) {
              // MissionsFragment's SpanSizeLookup: a section header takes the full span.
              GridItem() {
                this.cell(item)
              }
              .columnStart(0)
              .columnEnd(1)
            } else {
              GridItem() {
                this.cell(item)
              }
            }
          }, (item: MissionItem) => missionRowKey(item))
        }
        .columnsTemplate('1fr 1fr')
        .id('mission_recycler')
        .width('100%')
        .height('100%')
      }
    }
    .width('100%')
    .height('100%')
  }
}
