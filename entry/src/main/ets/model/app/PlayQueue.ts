/*
 * Port of app/src/main/java/org/schabi/newpipe/player/playqueue/PlayQueue.java plus
 * PlayQueueEvent.kt (the sealed event hierarchy the queue broadcasts).
 *
 * Concurrency (phase2-logic-contract.md section 1): the queue is an event STREAM, so
 * `PublishSubject` -> `Subject<PlayQueueEvent>` from common/rx/Rx.ts. The source's
 * `toFlowable(BUFFER).observeOn(mainThread()).startWithItem(InitEvent())` becomes the Subject
 * plus the InitEvent replayed to each new subscriber - `observeOn(main)` is identity in ArkTS
 * and BUFFER backpressure is moot for a queue-mutation stream.
 *
 * `synchronized` disappears: ArkTS is single-threaded, so the mutual exclusion the source needed
 * between the UI thread and the player thread is already guaranteed.
 */

import { BehaviorSubject, Observable, Subject } from '../../common/rx/Rx';
import { PlayQueueItem, RECOVERY_UNSET } from './PlayQueueItem';

export enum PlayQueueEventType {
  INIT,
  SELECT,
  APPEND,
  REMOVE,
  MOVE,
  REORDER,
  RECOVERY,
  ERROR
}

/** Port of the sealed interface PlayQueueEvent. */
export abstract class PlayQueueEvent {
  abstract type(): PlayQueueEventType;
}

export class InitEvent extends PlayQueueEvent {
  type(): PlayQueueEventType {
    return PlayQueueEventType.INIT;
  }
}

/** Sent when the index is changed. */
export class SelectEvent extends PlayQueueEvent {
  readonly oldIndex: number;
  readonly newIndex: number;

  constructor(oldIndex: number, newIndex: number) {
    super();
    this.oldIndex = oldIndex;
    this.newIndex = newIndex;
  }

  type(): PlayQueueEventType {
    return PlayQueueEventType.SELECT;
  }
}

/** Sent when more streams are added to the play queue. */
export class AppendEvent extends PlayQueueEvent {
  readonly amount: number;

  constructor(amount: number) {
    super();
    this.amount = amount;
  }

  type(): PlayQueueEventType {
    return PlayQueueEventType.APPEND;
  }
}

/** Sent when a pending stream is removed from the play queue. */
export class RemoveEvent extends PlayQueueEvent {
  readonly removeIndex: number;
  readonly queueIndex: number;

  constructor(removeIndex: number, queueIndex: number) {
    super();
    this.removeIndex = removeIndex;
    this.queueIndex = queueIndex;
  }

  type(): PlayQueueEventType {
    return PlayQueueEventType.REMOVE;
  }
}

/** Sent when two streams swap place in the play queue. */
export class MoveEvent extends PlayQueueEvent {
  readonly fromIndex: number;
  readonly toIndex: number;

  constructor(fromIndex: number, toIndex: number) {
    super();
    this.fromIndex = fromIndex;
    this.toIndex = toIndex;
  }

  type(): PlayQueueEventType {
    return PlayQueueEventType.MOVE;
  }
}

/** Sent when the queue is shuffled. */
export class ReorderEvent extends PlayQueueEvent {
  readonly fromSelectedIndex: number;
  readonly toSelectedIndex: number;

  constructor(fromSelectedIndex: number, toSelectedIndex: number) {
    super();
    this.fromSelectedIndex = fromSelectedIndex;
    this.toSelectedIndex = toSelectedIndex;
  }

  type(): PlayQueueEventType {
    return PlayQueueEventType.REORDER;
  }
}

/** Sent when a recovery record is set on a stream. */
export class RecoveryEvent extends PlayQueueEvent {
  readonly index: number;
  readonly position: number;

  constructor(index: number, position: number) {
    super();
    this.index = index;
    this.position = position;
  }

  type(): PlayQueueEventType {
    return PlayQueueEventType.RECOVERY;
  }
}

/** Sent when the item at index has caused an exception. */
export class ErrorEvent extends PlayQueueEvent {
  readonly errorIndex: number;
  readonly queueIndex: number;

  constructor(errorIndex: number, queueIndex: number) {
    super();
    this.errorIndex = errorIndex;
    this.queueIndex = queueIndex;
  }

  type(): PlayQueueEventType {
    return PlayQueueEventType.ERROR;
  }
}

export abstract class PlayQueue {
  private queueIndex: number;
  private readonly history: PlayQueueItem[] = [];

  private backup: PlayQueueItem[] | null = null;
  private streams: PlayQueueItem[];

  /** `transient` in the source. */
  private eventBroadcast: Subject<PlayQueueEvent> | null = null;
  private broadcastReceiver: Observable<PlayQueueEvent> | null = null;
  private disposed: boolean = false;

  constructor(index: number, startWith: PlayQueueItem[]) {
    this.streams = startWith.slice();
    if (this.streams.length > index && index >= 0) {
      this.history.push(this.streams[index]);
    }
    this.queueIndex = index;
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Playlist actions
  ////////////////////////////////////////////////////////////////////////// */

  /** Port of init(): opens the message bus and replays an InitEvent to each subscriber. */
  init(): void {
    const subject: Subject<PlayQueueEvent> = new Subject<PlayQueueEvent>();
    this.eventBroadcast = subject;
    this.broadcastReceiver = subject.startWithItem(new InitEvent());
  }

  /** Port of dispose(): stops the message bus. */
  dispose(): void {
    const subject: Subject<PlayQueueEvent> | null = this.eventBroadcast;
    if (subject !== null) {
      subject.onComplete();
    }
    this.eventBroadcast = null;
    this.broadcastReceiver = null;
    this.disposed = true;
  }

  /** Whether the queue has loaded all items of an external playlist. */
  abstract isComplete(): boolean;

  /** Loads the partial queue in the background; does nothing if the queue is complete. */
  abstract fetch(): void;

  /* //////////////////////////////////////////////////////////////////////////
  // Readonly ops
  ////////////////////////////////////////////////////////////////////////// */

  getIndex(): number {
    return this.queueIndex;
  }

  /** The current item that should be played, or null if the queue is empty. */
  getItem(): PlayQueueItem | null {
    return this.getItemAt(this.getIndex());
  }

  /** The item at the given index, or null if the index is out of bounds. */
  getItemAt(index: number): PlayQueueItem | null {
    if (index < 0 || index >= this.streams.length) {
      return null;
    }
    return this.streams[index];
  }

  /** Port of indexOf(item): referential equality, as in the source. */
  indexOf(item: PlayQueueItem): number {
    return this.streams.indexOf(item);
  }

  size(): number {
    return this.streams.length;
  }

  isEmpty(): boolean {
    return this.streams.length === 0;
  }

  isShuffled(): boolean {
    return this.backup !== null;
  }

  /** Port of getStreams(): an immutable view of the play queue. */
  getStreams(): PlayQueueItem[] {
    return this.streams.slice();
  }

  /** Port of getBroadcastReceiver(); null while the message bus is not initialized. */
  getBroadcastReceiver(): Observable<PlayQueueEvent> | null {
    return this.broadcastReceiver;
  }

  isDisposed(): boolean {
    return this.disposed;
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Write ops
  ////////////////////////////////////////////////////////////////////////// */

  /**
   * Port of setIndex(): guarded circularly for an index past the queue size, and emits a
   * SelectEvent.
   */
  setIndex(index: number): void {
    const oldIndex: number = this.getIndex();

    let newIndex: number;
    if (index < 0) {
      newIndex = 0;
    } else if (index < this.streams.length) {
      newIndex = index;
    } else if (this.streams.length === 0) {
      newIndex = 0;
    } else if (this.isComplete()) {
      newIndex = index % this.streams.length;
    } else {
      newIndex = this.streams.length - 1;
    }

    this.queueIndex = newIndex;

    if (oldIndex !== newIndex) {
      this.history.push(this.streams[newIndex]);
    }

    this.broadcast(new SelectEvent(oldIndex, newIndex));
  }

  /** Port of offsetIndex(offset). */
  offsetIndex(offset: number): void {
    this.setIndex(this.getIndex() + offset);
  }

  /** Port of notifyChange(). */
  notifyChange(): void {
    this.broadcast(new AppendEvent(0));
  }

  /** Port of append(items). */
  append(items: PlayQueueItem[]): void {
    const itemList: PlayQueueItem[] = items.slice();

    const backup: PlayQueueItem[] | null = this.backup;
    if (backup !== null) {
      for (const item of itemList) {
        backup.push(item);
      }
      PlayQueue.shuffleInPlace(itemList);
    }
    if (this.streams.length > 0 && itemList.length > 0
      && this.streams[this.streams.length - 1].isAutoQueued() && !itemList[0].isAutoQueued()) {
      this.streams.splice(this.streams.length - 1, 1);
    }
    for (const item of itemList) {
      this.streams.push(item);
    }

    this.broadcast(new AppendEvent(itemList.length));
  }

  /** Port of enqueueNext(item, skipIfSame). */
  enqueueNext(item: PlayQueueItem, skipIfSame: boolean): void {
    const currentIndex: number = this.getIndex();
    // if the next item is the same as the one to enqueue, skip when the flag is set
    if (skipIfSame && item.isSameItem(this.getItemAt(currentIndex + 1))) {
      return;
    }
    this.append([item]);
    this.move(this.size() - 1, currentIndex + 1);
  }

  /** Port of remove(index). */
  remove(index: number): void {
    if (index >= this.streams.length || index < 0) {
      return;
    }
    this.removeInternal(index);
    this.broadcast(new RemoveEvent(index, this.getIndex()));
  }

  /**
   * Port of error(): report an exception for the item at the current index and skip to the next.
   */
  error(): void {
    const oldIndex: number = this.getIndex();
    this.queueIndex = this.queueIndex + 1;
    if (this.streams.length > this.queueIndex) {
      this.history.push(this.streams[this.queueIndex]);
    }
    this.broadcast(new ErrorEvent(oldIndex, this.getIndex()));
  }

  /** Port of the private removeInternal(removeIndex). */
  private removeInternal(removeIndex: number): void {
    const currentIndex: number = this.queueIndex;
    const size: number = this.size();

    if (currentIndex > removeIndex) {
      this.queueIndex = this.queueIndex - 1;
    } else if (currentIndex >= size) {
      this.queueIndex = size > 1 ? currentIndex % (size - 1) : 0;
    } else if (currentIndex === removeIndex && currentIndex === size - 1) {
      this.queueIndex = 0;
    }

    const backup: PlayQueueItem[] | null = this.backup;
    if (backup !== null) {
      const target: PlayQueueItem | null = this.getItemAt(removeIndex);
      if (target !== null) {
        const at: number = backup.indexOf(target);
        if (at >= 0) {
          backup.splice(at, 1);
        }
      }
    }

    const removed: PlayQueueItem = this.streams.splice(removeIndex, 1)[0];
    const inHistory: number = this.history.indexOf(removed);
    if (inHistory >= 0) {
      this.history.splice(inHistory, 1);
    }
    if (this.streams.length > this.queueIndex) {
      this.history.push(this.streams[this.queueIndex]);
    }
  }

  /** Port of move(source, target). */
  move(source: number, target: number): void {
    if (source < 0 || target < 0) {
      return;
    }
    if (source >= this.streams.length || target >= this.streams.length) {
      return;
    }

    const current: number = this.getIndex();
    if (source === current) {
      this.queueIndex = target;
    } else if (source < current && target >= current) {
      this.queueIndex = this.queueIndex - 1;
    } else if (source > current && target <= current) {
      this.queueIndex = this.queueIndex + 1;
    }

    const playQueueItem: PlayQueueItem = this.streams.splice(source, 1)[0];
    playQueueItem.setAutoQueued(false);
    this.streams.splice(target, 0, playQueueItem);
    this.broadcast(new MoveEvent(source, target));
  }

  /** Port of setRecovery(index, position). */
  setRecovery(index: number, position: number): void {
    if (index < 0 || index >= this.streams.length) {
      return;
    }
    this.streams[index].setRecoveryPosition(position);
    this.broadcast(new RecoveryEvent(index, position));
  }

  /** Port of unsetRecovery(index). */
  unsetRecovery(index: number): void {
    this.setRecovery(index, RECOVERY_UNSET);
  }

  /**
   * Port of shuffle(). The backup list is created even for a queue of size <= 2, otherwise
   * shuffle-mode cannot be entered at all.
   */
  shuffle(): void {
    if (this.backup === null) {
      this.backup = this.streams.slice();
    }
    if (this.size() <= 2) {
      return;
    }

    const originalIndex: number = this.getIndex();
    const currentItem: PlayQueueItem | null = this.getItem();

    PlayQueue.shuffleInPlace(this.streams);

    if (currentItem !== null) {
      const at: number = this.streams.indexOf(currentItem);
      if (at >= 0) {
        this.streams.splice(at, 1);
      }
      this.streams.splice(0, 0, currentItem);
      this.history.push(currentItem);
    }
    this.queueIndex = 0;

    this.broadcast(new ReorderEvent(originalIndex, 0));
  }

  /** Port of unshuffle(). */
  unshuffle(): void {
    const backup: PlayQueueItem[] | null = this.backup;
    if (backup === null) {
      return;
    }
    const originIndex: number = this.getIndex();
    const current: PlayQueueItem | null = this.getItem();

    this.streams = backup;
    this.backup = null;

    const newIndex: number = current === null ? -1 : this.streams.indexOf(current);
    this.queueIndex = newIndex !== -1 ? newIndex : 0;
    if (this.streams.length > this.queueIndex) {
      this.history.push(this.streams[this.queueIndex]);
    }

    this.broadcast(new ReorderEvent(originIndex, this.queueIndex));
  }

  /**
   * Port of previous(): removes the currently playing item from the history and plays the last
   * item still in it.
   */
  previous(): boolean {
    if (this.history.length <= 1) {
      return false;
    }
    this.history.splice(this.history.length - 1, 1);
    const last: PlayQueueItem = this.history.splice(this.history.length - 1, 1)[0];
    this.setIndex(this.indexOf(last));
    return true;
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Comparison
  ////////////////////////////////////////////////////////////////////////// */

  /** Port of equalStreams(other): same size and same (serviceId, url) at every position. */
  equalStreams(other: PlayQueue | null): boolean {
    if (other === null) {
      return false;
    }
    if (this.size() !== other.size()) {
      return false;
    }
    for (let i: number = 0; i < this.size(); i++) {
      if (!this.streams[i].isSameItem(other.streams[i])) {
        return false;
      }
    }
    return true;
  }

  /** Port of equalStreamsAndIndex(other). */
  equalStreamsAndIndex(other: PlayQueue | null): boolean {
    if (this.equalStreams(other) && other !== null) {
      return other.getIndex() === this.getIndex();
    }
    return false;
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Rx broadcast
  ////////////////////////////////////////////////////////////////////////// */

  private broadcast(event: PlayQueueEvent): void {
    const subject: Subject<PlayQueueEvent> | null = this.eventBroadcast;
    if (subject !== null) {
      subject.onNext(event);
    }
  }

  /** Port of Collections.shuffle(List) - the Fisher-Yates shuffle it performs. */
  private static shuffleInPlace(items: PlayQueueItem[]): void {
    for (let i: number = items.length - 1; i > 0; i--) {
      const j: number = Math.floor(Math.random() * (i + 1));
      const tmp: PlayQueueItem = items[i];
      items[i] = items[j];
      items[j] = tmp;
    }
  }
}

/**
 * The port's ONE concrete PlayQueue, standing in for SinglePlayQueue / PlaylistPlayQueue /
 * ChannelPlayQueue alike: a finite list that is already fully loaded.
 *
 * PlayQueue was abstract with no subclass anywhere, so nothing could construct a queue at all and
 * every surface synthesised a one-element list from the stream the player happened to be on -
 * which is why no producer could hand over more than one item. The two abstract members are the
 * external-playlist pager; nothing in this port pages a queue, so the queue is always complete and
 * fetch() has nothing to load. init() runs here rather than at the hand-over so that a queue is
 * never published with its event bus still shut.
 */
export class SimplePlayQueue extends PlayQueue {
  constructor(index: number, startWith: PlayQueueItem[]) {
    super(index, startWith);
    this.init();
  }

  isComplete(): boolean {
    return true;
  }

  fetch(): void {
    // A complete queue has nothing left to load.
  }
}

/**
 * The app's single live play queue, null while nothing is queued - the handle every producer
 * publishes to and every queue surface reads.
 *
 * It deliberately does NOT live on PlayerService: the queue is a model that outlives any one
 * prepared stream, and the service is the pipeline that plays whatever the queue currently points
 * at. Mutations (append / remove / move / shuffle) are broadcast by the queue itself through
 * getBroadcastReceiver(); this subject only reports the queue being REPLACED, so a reader
 * subscribes to both.
 */
export const currentPlayQueue: BehaviorSubject<PlayQueue | null> =
  new BehaviorSubject<PlayQueue | null>(null);

/** NavigationHelper.playOn*Player(queue): publish a queue, disposing the one it replaces. */
export function setCurrentPlayQueue(queue: PlayQueue | null): void {
  const previous: PlayQueue | null = currentPlayQueue.getValue();
  if (previous !== null && previous !== queue) {
    previous.dispose();
  }
  currentPlayQueue.onNext(queue);
}

/**
 * NavigationHelper.enqueueOnPlayer(queue): APPEND to the live queue, leaving the playing item
 * alone. With no queue yet there is nothing to append to, so the items become the queue - which
 * is the source's behaviour too (enqueueOnPlayer opens the player when none is running).
 */
export function enqueueOnCurrentPlayQueue(items: PlayQueueItem[]): void {
  if (items.length === 0) {
    return;
  }
  const live: PlayQueue | null = currentPlayQueue.getValue();
  if (live === null) {
    setCurrentPlayQueue(new SimplePlayQueue(0, items));
    return;
  }
  live.append(items);
}
