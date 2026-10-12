/*
 * Port of app/src/main/java/org/schabi/newpipe/local/feed/FeedState.kt - the three states the
 * feed screen renders.
 *
 * Kotlin's `sealed class` becomes a base class plus the three subclasses, discriminated with
 * `instanceof` (ArkTS has no sealed classes and no exhaustive `when`). `FeedStateKind` is
 * carried alongside so a render body can branch on a field rather than a type test, which is
 * what the ArkUI `if` chain in the feed screen needs.
 */

import { StreamItem } from './StreamItem';

export enum FeedStateKind {
  PROGRESS,
  LOADED,
  ERROR
}

export abstract class FeedState {
  abstract readonly kind: FeedStateKind;
}

/** Port of FeedState.ProgressState. */
export class ProgressState extends FeedState {
  readonly kind: FeedStateKind = FeedStateKind.PROGRESS;
  currentProgress: number = -1;
  maxProgress: number = -1;
  /** The name of the migrated progress string resource, '' when there is none. */
  progressMessage: string = '';

  constructor(currentProgress: number = -1, maxProgress: number = -1,
    progressMessage: string = '') {
    super();
    this.currentProgress = currentProgress;
    this.maxProgress = maxProgress;
    this.progressMessage = progressMessage;
  }
}

/** Port of FeedState.LoadedState. */
export class LoadedState extends FeedState {
  readonly kind: FeedStateKind = FeedStateKind.LOADED;
  items: StreamItem[] = [];
  /** Epoch milliseconds of the oldest subscription update, or null when nothing was updated. */
  oldestUpdate: number | null = null;
  notLoadedCount: number = 0;
  itemsErrors: Error[] = [];

  constructor(items: StreamItem[], oldestUpdate: number | null, notLoadedCount: number,
    itemsErrors: Error[]) {
    super();
    this.items = items;
    this.oldestUpdate = oldestUpdate;
    this.notLoadedCount = notLoadedCount;
    this.itemsErrors = itemsErrors;
  }
}

/** Port of FeedState.ErrorState. */
export class ErrorState extends FeedState {
  readonly kind: FeedStateKind = FeedStateKind.ERROR;
  error: Error | null = null;

  constructor(error: Error | null = null) {
    super();
    this.error = error;
  }
}
