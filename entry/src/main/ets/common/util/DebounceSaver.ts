/*
 * Port of org.schabi.newpipe.util.debounce.DebounceSaver — the shared util behind every
 * reorderable list in the source (BookmarkFragment and LocalPlaylistFragment both own one,
 * and every screen that persists a drag order goes through it).
 *
 * The source debounces a PublishSubject and hands the subscription to the fragment's
 * CompositeDisposable; ArkTS needs no stream for it — one restarting timer is the same
 * behaviour — but it keeps the Disposable contract so a page can register it the same way
 * (`disposables.add(debounceSaver.getDebouncedSaver())`) and have teardown cancel it.
 */
import { Disposable } from '../rx/Rx';

export class DebounceSaver implements Disposable {
  private readonly saveDebounceMillis: number;
  private readonly savable: () => void;
  private isModified: boolean = false;
  private timerId: number = -1;
  private disposedFlag: boolean = false;

  constructor(saveDebounceMillis: number, savable: () => void) {
    this.saveDebounceMillis = saveDebounceMillis;
    this.savable = savable;
  }

  getIsModified(): boolean {
    return this.isModified;
  }

  setNoChangesToSave(): void {
    this.isModified = false;
  }

  /** setHasChangesToSave(): flag it, then re-arm the debounce window. */
  setHasChangesToSave(): void {
    if (this.disposedFlag) {
      return;
    }
    this.isModified = true;
    this.cancel();
    this.timerId = setTimeout((): void => {
      this.timerId = -1;
      this.savable();
    }, this.saveDebounceMillis);
  }

  /** Drops the pending timer without ending the saver's life (the source's disposables.clear()). */
  cancel(): void {
    if (this.timerId !== -1) {
      clearTimeout(this.timerId);
      this.timerId = -1;
    }
  }

  /** onDestroy(): debouncedSaveSignal.onComplete() + disposables.dispose(). */
  dispose(): void {
    this.disposedFlag = true;
    this.cancel();
  }

  isDisposed(): boolean {
    return this.disposedFlag;
  }
}
