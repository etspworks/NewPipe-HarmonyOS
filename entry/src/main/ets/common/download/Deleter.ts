/*
 * Port of us.shandian.giga.ui.common.Deleter and of the undo half of
 * MissionAdapter.clearFinishedDownloads(true): a delete is held for five seconds behind an Undo
 * snackbar, the rows hidden meanwhile, and only then reaches the DownloadManager.
 *
 * One pending batch at a time, as in the source: a new delete commits the previous one at once,
 * so snackbars never stack. The Downloads toolbar (clear finished) and the rows (delete, delete
 * entry, checksum of a missing file) both feed it, so it is a singleton the two pages share.
 */

import { Mission } from '../../model/app/Mission';
import { Observable, Subject } from '../rx/Rx';
import { ServiceLocator } from '../di/ServiceLocator';

/** Deleter.TIMEOUT. */
const TIMEOUT_MS: number = 5000;

export class PendingDeletion {
  readonly missions: Mission[];
  readonly alsoDeleteFile: boolean;
  /** The snackbar text. */
  readonly message: string;

  constructor(missions: Mission[], alsoDeleteFile: boolean, message: string) {
    this.missions = missions;
    this.alsoDeleteFile = alsoDeleteFile;
    this.message = message;
  }
}

export class Deleter {
  private static shared: Deleter | null = null;

  private pending: PendingDeletion | null = null;
  private timer: number = -1;
  private readonly changes: Subject<number> = new Subject<number>();

  static get(): Deleter {
    let deleter: Deleter | null = Deleter.shared;
    if (deleter === null) {
      deleter = new Deleter();
      Deleter.shared = deleter;
    }
    return deleter;
  }

  /** Fires whenever the pending batch changes: rows hide or come back, the snackbar follows. */
  observe(): Observable<number> {
    return this.changes;
  }

  current(): PendingDeletion | null {
    return this.pending;
  }

  /** mIterator.hide(mission): the row is not drawn while its delete is pending. */
  isHidden(mission: Mission): boolean {
    const pending: PendingDeletion | null = this.pending;
    return pending !== null && pending.missions.indexOf(mission) >= 0;
  }

  /** append(item, alsoDeleteFile) / clearFinishedDownloads(true). */
  append(missions: Mission[], alsoDeleteFile: boolean, message: string): void {
    this.commit();
    if (missions.length === 0) {
      return;
    }
    this.pending = new PendingDeletion(missions, alsoDeleteFile, message);
    this.timer = setTimeout((): void => {
      this.commit();
    }, TIMEOUT_MS);
    this.changes.onNext(Date.now());
  }

  /** The snackbar's Undo: forget(). */
  undo(): void {
    this.clearTimer();
    if (this.pending === null) {
      return;
    }
    this.pending = null;
    this.changes.onNext(Date.now());
  }

  /** commit() - and dispose(), which the source runs when the screen goes. */
  commit(): void {
    this.clearTimer();
    const pending: PendingDeletion | null = this.pending;
    if (pending === null) {
      return;
    }
    this.pending = null;
    for (const mission of pending.missions) {
      ServiceLocator.get().downloadManager.deleteMission(mission, pending.alsoDeleteFile);
    }
    this.changes.onNext(Date.now());
  }

  private clearTimer(): void {
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
  }
}
