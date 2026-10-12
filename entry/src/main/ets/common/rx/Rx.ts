/*
 * Port of io.reactivex.rxjava3 (RxJava 3.1.12, vendored at input/source/RxJava) — the reactive
 * types NewPipe actually uses. Semantics are taken from that vendored source:
 *   core/Observer.java, core/Observable.java (operator contracts),
 *   disposables/Disposable.java, disposables/CompositeDisposable.java,
 *   subjects/PublishSubject.java, subjects/BehaviorSubject.java.
 *
 * Per the Phase-2 logic contract section 1, the one-shot reactive types are NOT ported as
 * classes — they collapse onto the platform's own async primitive:
 *
 *   Single<T>       -> Promise<T>
 *   Maybe<T>        -> Promise<T | null>
 *   Completable     -> Promise<void>
 *   Observable<T> / Flowable<T> -> the Observable in this file
 *   PublishSubject / BehaviorSubject -> Subject / BehaviorSubject in this file
 *
 * Rule: one-shot loads are Promises; event streams (download-mission progress, player state,
 * search-suggestion keystrokes, the feed ticker) are Observables.
 *
 * Backpressure: HarmonyOS has no Flowable analogue and no request(n) protocol. A Flowable with
 * an explicit BUFFER/LATEST strategy gets an explicit bounded queue at its own call site;
 * everywhere else a Flowable is a plain Observable here.
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { Scheduler } from './Schedulers';
/*
 * The extractor's narrowing, aliased - NOT a second copy of it. A HarmonyOS BusinessError is a
 * plain object: it fails `instanceof Error` and `${it}` renders the literal "[object Object]",
 * which is what every error routed through an Rx pipeline used to carry.
 */
import { toError as asError } from '../extractor/core/Errors';

const RX_DOMAIN: number = 0x0100;
const RX_TAG: string = 'Rx';

/**
 * Where an error goes when the flow has no onError handler. RxJava routes these to
 * RxJavaPlugins.onError(); here they are logged rather than silently dropped.
 */
export class RxPlugins {
  static onUnhandledError(error: Error): void {
    hilog.error(RX_DOMAIN, RX_TAG, 'unhandled Rx error: %{public}s', error.message);
  }
}

/** Signalled by timeout(). Mirrors java.util.concurrent.TimeoutException. */
export class TimeoutError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'TimeoutError';
  }
}

/* ////////////////////////////////////////////////////////////////////////////
// Disposables
//////////////////////////////////////////////////////////////////////////// */

export interface Disposable {
  dispose(): void;

  isDisposed(): boolean;
}

/**
 * Port of disposables/CompositeDisposable.java.
 * add() after dispose() disposes the argument immediately and returns false;
 * remove() disposes the removed resource, delete() does not; clear() disposes the
 * contents but leaves the container usable, dispose() also marks it disposed.
 */
export class CompositeDisposable implements Disposable {
  private resources: Disposable[] = [];
  private disposedFlag: boolean = false;

  add(disposable: Disposable): boolean {
    if (!this.disposedFlag) {
      this.resources.push(disposable);
      return true;
    }
    disposable.dispose();
    return false;
  }

  addAll(disposables: Disposable[]): boolean {
    let allAdded: boolean = true;
    for (const d of disposables) {
      if (!this.add(d)) {
        allAdded = false;
      }
    }
    return allAdded;
  }

  /** Removes and disposes. */
  remove(disposable: Disposable): boolean {
    if (this.delete(disposable)) {
      disposable.dispose();
      return true;
    }
    return false;
  }

  /** Removes without disposing. */
  delete(disposable: Disposable): boolean {
    const index: number = this.resources.indexOf(disposable);
    if (index < 0) {
      return false;
    }
    this.resources.splice(index, 1);
    return true;
  }

  /** Disposes the contents; the container stays usable. */
  clear(): void {
    const current: Disposable[] = this.resources;
    this.resources = [];
    for (const d of current) {
      d.dispose();
    }
  }

  dispose(): void {
    if (this.disposedFlag) {
      return;
    }
    this.disposedFlag = true;
    this.clear();
  }

  isDisposed(): boolean {
    return this.disposedFlag;
  }

  size(): number {
    return this.resources.length;
  }
}

/** A Disposable that runs a single action once. Port of Disposable.fromRunnable(). */
export class ActionDisposable implements Disposable {
  private action: (() => void) | null;

  constructor(action: () => void) {
    this.action = action;
  }

  dispose(): void {
    const a: (() => void) | null = this.action;
    this.action = null;
    if (a !== null) {
      a();
    }
  }

  isDisposed(): boolean {
    return this.action === null;
  }
}

/* ////////////////////////////////////////////////////////////////////////////
// Observer / Emitter
//////////////////////////////////////////////////////////////////////////// */

/**
 * Port of core/Observer.java. onSubscribe(Disposable) is dropped: subscribe() hands the
 * Disposable back synchronously, which is what RxJava's subscribe(Consumer...) overloads do.
 * All three handlers are optional so a call site can supply only the ones it needs.
 */
export interface Observer<T> {
  onNext?: (value: T) => void;
  onError?: (error: Error) => void;
  onComplete?: () => void;
}

/**
 * The downstream end of one subscription: guards the RxJava contract that onError/onComplete
 * fire at most once and that nothing is delivered after disposal, and owns the cancellation
 * action the source registers.
 */
export class Emitter<T> implements Disposable {
  private readonly observer: Observer<T>;
  private disposedFlag: boolean = false;
  private terminated: boolean = false;
  private cancel: (() => void) | null = null;

  constructor(observer: Observer<T>) {
    this.observer = observer;
  }

  /** Registers the action that tears the source down when this subscription is disposed. */
  setCancellable(action: () => void): void {
    if (this.disposedFlag || this.terminated) {
      action();
      return;
    }
    this.cancel = action;
  }

  isDisposed(): boolean {
    return this.disposedFlag;
  }

  dispose(): void {
    if (this.disposedFlag) {
      return;
    }
    this.disposedFlag = true;
    this.runCancel();
  }

  onNext(value: T): void {
    if (this.disposedFlag || this.terminated) {
      return;
    }
    const f: ((value: T) => void) | undefined = this.observer.onNext;
    if (f !== undefined) {
      f(value);
    }
  }

  onError(error: Error): void {
    if (this.disposedFlag || this.terminated) {
      RxPlugins.onUnhandledError(error);
      return;
    }
    this.terminated = true;
    const f: ((error: Error) => void) | undefined = this.observer.onError;
    try {
      if (f !== undefined) {
        f(error);
      } else {
        RxPlugins.onUnhandledError(error);
      }
    } finally {
      this.disposedFlag = true;
      this.runCancel();
    }
  }

  onComplete(): void {
    if (this.disposedFlag || this.terminated) {
      return;
    }
    this.terminated = true;
    const f: (() => void) | undefined = this.observer.onComplete;
    try {
      if (f !== undefined) {
        f();
      }
    } finally {
      this.disposedFlag = true;
      this.runCancel();
    }
  }

  private runCancel(): void {
    const c: (() => void) | null = this.cancel;
    this.cancel = null;
    if (c !== null) {
      c();
    }
  }
}

export type ObservableOnSubscribe<T> = (emitter: Emitter<T>) => void;

/** Per-subscription operator handlers used by Observable.lift(). */
interface Lifted<T, R> {
  next: (value: T, down: Emitter<R>) => void;
  error?: (error: Error, down: Emitter<R>) => void;
  complete?: (down: Emitter<R>) => void;
}

/* ////////////////////////////////////////////////////////////////////////////
// Observable
//////////////////////////////////////////////////////////////////////////// */

export class Observable<T> {
  private readonly source: ObservableOnSubscribe<T>;

  constructor(source: ObservableOnSubscribe<T>) {
    this.source = source;
  }

  static create<T>(source: ObservableOnSubscribe<T>): Observable<T> {
    return new Observable<T>(source);
  }

  /** Port of just(T). */
  static just<T>(value: T): Observable<T> {
    return Observable.create<T>((down: Emitter<T>): void => {
      down.onNext(value);
      down.onComplete();
    });
  }

  /** Port of fromArray(T...) / fromIterable(Iterable). */
  static fromArray<T>(values: T[]): Observable<T> {
    return Observable.create<T>((down: Emitter<T>): void => {
      for (const v of values) {
        if (down.isDisposed()) {
          return;
        }
        down.onNext(v);
      }
      down.onComplete();
    });
  }

  /** Port of empty(). */
  static empty<T>(): Observable<T> {
    return Observable.create<T>((down: Emitter<T>): void => {
      down.onComplete();
    });
  }

  /** Port of error(Throwable). */
  static error<T>(error: Error): Observable<T> {
    return Observable.create<T>((down: Emitter<T>): void => {
      down.onError(error);
    });
  }

  /** Port of defer(Supplier): the factory runs once per subscriber. */
  static defer<T>(factory: () => Observable<T>): Observable<T> {
    return Observable.create<T>((down: Emitter<T>): void => {
      let inner: Observable<T>;
      try {
        inner = factory();
      } catch (err) {
        down.onError(asError(err));
        return;
      }
      const sub: Disposable = inner.subscribe(Observable.forward<T>(down));
      down.setCancellable((): void => {
        sub.dispose();
      });
    });
  }

  /** Port of fromCallable(Callable): the function runs once per subscriber. */
  static fromCallable<T>(callable: () => T): Observable<T> {
    return Observable.create<T>((down: Emitter<T>): void => {
      let value: T;
      try {
        value = callable();
      } catch (err) {
        down.onError(asError(err));
        return;
      }
      down.onNext(value);
      down.onComplete();
    });
  }

  /**
   * Bridge for the Promise half of the contract (the ArkTS stand-in for RxJava's fromFuture /
   * Single.toObservable): lifts a one-shot load into a stream so it can feed switchMap etc.
   */
  static fromPromise<T>(promise: Promise<T>): Observable<T> {
    return Observable.create<T>((down: Emitter<T>): void => {
      promise.then((value: T): void => {
        down.onNext(value);
        down.onComplete();
      }).catch((err: Object): void => {
        down.onError(asError(err));
      });
    });
  }

  /**
   * Port of interval(initialDelay, period, unit): emits 0 after initialDelayMs and an
   * ever-increasing number every periodMs thereafter. Never completes on its own.
   */
  static interval(periodMs: number, initialDelayMs: number = periodMs): Observable<number> {
    return Observable.create<number>((down: Emitter<number>): void => {
      let counter: number = 0;
      let repeatHandle: number = -1;
      const tick = (): void => {
        down.onNext(counter);
        counter = counter + 1;
      };
      const startHandle: number = setTimeout((): void => {
        if (down.isDisposed()) {
          return;
        }
        tick();
        repeatHandle = setInterval(tick, periodMs);
      }, initialDelayMs);
      down.setCancellable((): void => {
        clearTimeout(startHandle);
        if (repeatHandle >= 0) {
          clearInterval(repeatHandle);
        }
      });
    });
  }

  /** Port of merge(Iterable): runs every source at once, completes when all have completed. */
  static merge<T>(sources: Observable<T>[]): Observable<T> {
    return Observable.create<T>((down: Emitter<T>): void => {
      const group: CompositeDisposable = new CompositeDisposable();
      down.setCancellable((): void => {
        group.dispose();
      });
      let active: number = sources.length;
      if (active === 0) {
        down.onComplete();
        return;
      }
      for (const s of sources) {
        const obs: Observer<T> = {
          onNext: (v: T): void => {
            down.onNext(v);
          },
          onError: (e: Error): void => {
            down.onError(e);
          },
          onComplete: (): void => {
            active = active - 1;
            if (active === 0) {
              down.onComplete();
            }
          }
        };
        group.add(s.subscribe(obs));
      }
    });
  }

  /** Port of concat(Iterable): runs the sources strictly one after another. */
  static concat<T>(sources: Observable<T>[]): Observable<T> {
    return Observable.create<T>((down: Emitter<T>): void => {
      const group: CompositeDisposable = new CompositeDisposable();
      down.setCancellable((): void => {
        group.dispose();
      });
      let index: number = 0;
      const subscribeNext = (): void => {
        if (down.isDisposed()) {
          return;
        }
        if (index >= sources.length) {
          down.onComplete();
          return;
        }
        const src: Observable<T> = sources[index];
        index = index + 1;
        const obs: Observer<T> = {
          onNext: (v: T): void => {
            down.onNext(v);
          },
          onError: (e: Error): void => {
            down.onError(e);
          },
          onComplete: (): void => {
            subscribeNext();
          }
        };
        group.add(src.subscribe(obs));
      };
      subscribeNext();
    });
  }

  /**
   * Port of combineLatest(Iterable, Function): emits the combination of the latest value of
   * every source, each time any source emits, once every source has emitted at least once.
   */
  static combineLatest<T, R>(sources: Observable<T>[], combiner: (values: T[]) => R):
    Observable<R> {
    return Observable.create<R>((down: Emitter<R>): void => {
      const count: number = sources.length;
      if (count === 0) {
        down.onComplete();
        return;
      }
      const group: CompositeDisposable = new CompositeDisposable();
      down.setCancellable((): void => {
        group.dispose();
      });
      const latest: Array<T | null> = [];
      const hasValue: boolean[] = [];
      for (let i: number = 0; i < count; i++) {
        latest.push(null);
        hasValue.push(false);
      }
      let ready: number = 0;
      let active: number = count;

      for (let i: number = 0; i < count; i++) {
        const slot: number = i;
        const obs: Observer<T> = {
          onNext: (v: T): void => {
            if (!hasValue[slot]) {
              hasValue[slot] = true;
              ready = ready + 1;
            }
            latest[slot] = v;
            if (ready === count) {
              const snapshot: T[] = [];
              for (const item of latest) {
                snapshot.push(item as T);
              }
              down.onNext(combiner(snapshot));
            }
          },
          onError: (e: Error): void => {
            down.onError(e);
          },
          onComplete: (): void => {
            if (!hasValue[slot]) {
              // a source that completes without ever emitting can never contribute a value
              down.onComplete();
              return;
            }
            active = active - 1;
            if (active === 0) {
              down.onComplete();
            }
          }
        };
        group.add(sources[i].subscribe(obs));
      }
    });
  }

  /**
   * Port of zip(Iterable, Function): pairs items in strict sequence — the n-th emission is the
   * combination of the n-th item of every source. Completes as soon as one source completes
   * with an empty queue.
   */
  static zip<T, R>(sources: Observable<T>[], zipper: (values: T[]) => R): Observable<R> {
    return Observable.create<R>((down: Emitter<R>): void => {
      const count: number = sources.length;
      if (count === 0) {
        down.onComplete();
        return;
      }
      const group: CompositeDisposable = new CompositeDisposable();
      down.setCancellable((): void => {
        group.dispose();
      });
      const queues: Array<T[]> = [];
      const done: boolean[] = [];
      for (let i: number = 0; i < count; i++) {
        queues.push([]);
        done.push(false);
      }

      // true while every queue holds at least one item, so a full row can be emitted
      const rowReady = (): boolean => {
        for (let i: number = 0; i < count; i++) {
          if (queues[i].length === 0) {
            return false;
          }
        }
        return true;
      };
      // true once a source that has completed has drained its queue: no further row is possible
      const exhausted = (): boolean => {
        for (let i: number = 0; i < count; i++) {
          if (done[i] && queues[i].length === 0) {
            return true;
          }
        }
        return false;
      };

      const drain = (): void => {
        while (!down.isDisposed() && rowReady()) {
          const row: T[] = [];
          for (let i: number = 0; i < count; i++) {
            row.push(queues[i].shift() as T);
          }
          down.onNext(zipper(row));
        }
        if (!down.isDisposed() && exhausted()) {
          down.onComplete();
        }
      };

      for (let i: number = 0; i < count; i++) {
        const slot: number = i;
        const obs: Observer<T> = {
          onNext: (v: T): void => {
            queues[slot].push(v);
            drain();
          },
          onError: (e: Error): void => {
            down.onError(e);
          },
          onComplete: (): void => {
            done[slot] = true;
            drain();
          }
        };
        group.add(sources[i].subscribe(obs));
      }
    });
  }

  /** An Observer that forwards every signal to `down` unchanged. */
  private static forward<T>(down: Emitter<T>): Observer<T> {
    const obs: Observer<T> = {
      onNext: (v: T): void => {
        down.onNext(v);
      },
      onError: (e: Error): void => {
        down.onError(e);
      },
      onComplete: (): void => {
        down.onComplete();
      }
    };
    return obs;
  }

  /* ---------------------------------------------------------------- subscribe */

  subscribe(observer: Observer<T>): Disposable {
    const emitter: Emitter<T> = new Emitter<T>(observer);
    this.subscribeActual(emitter);
    return emitter;
  }

  /** Convenience for RxJava's subscribe(onNext, onError, onComplete) overloads. */
  subscribeCallbacks(onNext: (value: T) => void, onError?: (error: Error) => void,
    onComplete?: () => void): Disposable {
    const obs: Observer<T> = {
      onNext: onNext,
      onError: onError,
      onComplete: onComplete
    };
    return this.subscribe(obs);
  }

  /** Overridden by Subject; the default runs the source function. */
  protected subscribeActual(emitter: Emitter<T>): void {
    try {
      this.source(emitter);
    } catch (err) {
      emitter.onError(asError(err));
    }
  }

  /**
   * IDENTITY (contract section 1): `@ohos.net.http` and `relationalStore` are already async, so
   * there is no thread to move the subscription to. Kept so ported call sites read like the
   * source.
   */
  subscribeOn(scheduler: Scheduler): Observable<T> {
    return this;
  }

  /** IDENTITY: ArkTS callbacks already resolve on the UI thread. */
  observeOn(scheduler: Scheduler): Observable<T> {
    return this;
  }

  /* ---------------------------------------------------------------- operators */

  private lift<R>(factory: () => Lifted<T, R>): Observable<R> {
    const upstream: Observable<T> = this;
    return Observable.create<R>((down: Emitter<R>): void => {
      const h: Lifted<T, R> = factory();
      const obs: Observer<T> = {
        onNext: (v: T): void => {
          try {
            h.next(v, down);
          } catch (err) {
            down.onError(asError(err));
          }
        },
        onError: (e: Error): void => {
          const fe: ((error: Error, down: Emitter<R>) => void) | undefined = h.error;
          if (fe === undefined) {
            down.onError(e);
            return;
          }
          try {
            fe(e, down);
          } catch (err) {
            down.onError(asError(err));
          }
        },
        onComplete: (): void => {
          const fc: ((down: Emitter<R>) => void) | undefined = h.complete;
          if (fc === undefined) {
            down.onComplete();
            return;
          }
          try {
            fc(down);
          } catch (err) {
            down.onError(asError(err));
          }
        }
      };
      const sub: Disposable = upstream.subscribe(obs);
      down.setCancellable((): void => {
        sub.dispose();
      });
    });
  }

  map<R>(mapper: (value: T) => R): Observable<R> {
    return this.lift<R>((): Lifted<T, R> => {
      const h: Lifted<T, R> = {
        next: (v: T, down: Emitter<R>): void => {
          down.onNext(mapper(v));
        }
      };
      return h;
    });
  }

  filter(predicate: (value: T) => boolean): Observable<T> {
    return this.lift<T>((): Lifted<T, T> => {
      const h: Lifted<T, T> = {
        next: (v: T, down: Emitter<T>): void => {
          if (predicate(v)) {
            down.onNext(v);
          }
        }
      };
      return h;
    });
  }

  /** Runs the action before forwarding the item, per doOnNext(Consumer). */
  doOnNext(action: (value: T) => void): Observable<T> {
    return this.lift<T>((): Lifted<T, T> => {
      const h: Lifted<T, T> = {
        next: (v: T, down: Emitter<T>): void => {
          action(v);
          down.onNext(v);
        }
      };
      return h;
    });
  }

  /** Runs the action before forwarding the error, per doOnError(Consumer). */
  doOnError(action: (error: Error) => void): Observable<T> {
    return this.lift<T>((): Lifted<T, T> => {
      const h: Lifted<T, T> = {
        next: (v: T, down: Emitter<T>): void => {
          down.onNext(v);
        },
        error: (e: Error, down: Emitter<T>): void => {
          action(e);
          down.onError(e);
        }
      };
      return h;
    });
  }

  /** Port of take(count). take(0) is empty(), as in RxJava. */
  take(count: number): Observable<T> {
    if (count <= 0) {
      return Observable.empty<T>();
    }
    return this.lift<T>((): Lifted<T, T> => {
      let remaining: number = count;
      const h: Lifted<T, T> = {
        next: (v: T, down: Emitter<T>): void => {
          if (remaining <= 0) {
            return;
          }
          remaining = remaining - 1;
          down.onNext(v);
          if (remaining === 0) {
            down.onComplete();
          }
        }
      };
      return h;
    });
  }

  /** Port of skip(count). */
  skip(count: number): Observable<T> {
    return this.lift<T>((): Lifted<T, T> => {
      let remaining: number = count;
      const h: Lifted<T, T> = {
        next: (v: T, down: Emitter<T>): void => {
          if (remaining > 0) {
            remaining = remaining - 1;
            return;
          }
          down.onNext(v);
        }
      };
      return h;
    });
  }

  /**
   * Port of distinctUntilChanged(): drops an item equal to its immediate predecessor.
   * Without a comparer the check is `===`, which matches RxJava's default Object.equals()
   * behaviour for primitives and reference identity for objects.
   */
  distinctUntilChanged(comparer?: (previous: T, current: T) => boolean): Observable<T> {
    return this.lift<T>((): Lifted<T, T> => {
      let hasPrevious: boolean = false;
      let previous: T | null = null;
      const h: Lifted<T, T> = {
        next: (v: T, down: Emitter<T>): void => {
          let same: boolean = false;
          if (hasPrevious) {
            same = comparer !== undefined ? comparer(previous as T, v) : previous === v;
          }
          if (!same) {
            hasPrevious = true;
            previous = v;
            down.onNext(v);
          }
        }
      };
      return h;
    });
  }

  /**
   * Port of scan(BiFunction): emits the first item unchanged, then the running accumulation.
   */
  scan(accumulator: (accumulated: T, value: T) => T): Observable<T> {
    return this.lift<T>((): Lifted<T, T> => {
      let hasAccumulated: boolean = false;
      let accumulated: T | null = null;
      const h: Lifted<T, T> = {
        next: (v: T, down: Emitter<T>): void => {
          if (!hasAccumulated) {
            hasAccumulated = true;
            accumulated = v;
          } else {
            accumulated = accumulator(accumulated as T, v);
          }
          down.onNext(accumulated as T);
        }
      };
      return h;
    });
  }

  /** Port of scan(R initialValue, BiFunction): emits the seed first, then each accumulation. */
  scanWith<R>(seed: R, accumulator: (accumulated: R, value: T) => R): Observable<R> {
    const upstream: Observable<T> = this;
    return Observable.create<R>((down: Emitter<R>): void => {
      let accumulated: R = seed;
      down.onNext(seed);
      const obs: Observer<T> = {
        onNext: (v: T): void => {
          try {
            accumulated = accumulator(accumulated, v);
          } catch (err) {
            down.onError(asError(err));
            return;
          }
          down.onNext(accumulated);
        },
        onError: (e: Error): void => {
          down.onError(e);
        },
        onComplete: (): void => {
          down.onComplete();
        }
      };
      const sub: Disposable = upstream.subscribe(obs);
      down.setCancellable((): void => {
        sub.dispose();
      });
    });
  }

  /** Port of startWith(ObservableSource): runs `other` first, then this. */
  startWith(other: Observable<T>): Observable<T> {
    return Observable.concat<T>([other, this]);
  }

  /** Port of startWithItem(T). */
  startWithItem(value: T): Observable<T> {
    return Observable.concat<T>([Observable.just<T>(value), this]);
  }

  /** Port of startWithArray(T...). */
  startWithArray(values: T[]): Observable<T> {
    return Observable.concat<T>([Observable.fromArray<T>(values), this]);
  }

  /**
   * Port of toList(): RxJava returns Single<List<T>>, which the contract maps onto Promise<T[]>.
   * Only meaningful on a finite Observable.
   */
  toList(): Promise<T[]> {
    return new Promise<T[]>((resolve: (value: T[]) => void,
      reject: (reason: Error) => void): void => {
      const accumulated: T[] = [];
      const obs: Observer<T> = {
        onNext: (v: T): void => {
          accumulated.push(v);
        },
        onError: (e: Error): void => {
          reject(e);
        },
        onComplete: (): void => {
          resolve(accumulated);
        }
      };
      this.subscribe(obs);
    });
  }

  /** Port of onErrorReturn(Function): ends the flow with a last item instead of the error. */
  onErrorReturn(itemSupplier: (error: Error) => T): Observable<T> {
    return this.lift<T>((): Lifted<T, T> => {
      const h: Lifted<T, T> = {
        next: (v: T, down: Emitter<T>): void => {
          down.onNext(v);
        },
        error: (e: Error, down: Emitter<T>): void => {
          down.onNext(itemSupplier(e));
          down.onComplete();
        }
      };
      return h;
    });
  }

  /** Port of onErrorResumeNext(Function): continues with a fallback source on error. */
  onErrorResumeNext(fallbackSupplier: (error: Error) => Observable<T>): Observable<T> {
    const upstream: Observable<T> = this;
    return Observable.create<T>((down: Emitter<T>): void => {
      const group: CompositeDisposable = new CompositeDisposable();
      down.setCancellable((): void => {
        group.dispose();
      });
      const obs: Observer<T> = {
        onNext: (v: T): void => {
          down.onNext(v);
        },
        onError: (e: Error): void => {
          let fallback: Observable<T>;
          try {
            fallback = fallbackSupplier(e);
          } catch (err) {
            down.onError(asError(err));
            return;
          }
          group.add(fallback.subscribe(Observable.forward<T>(down)));
        },
        onComplete: (): void => {
          down.onComplete();
        }
      };
      group.add(upstream.subscribe(obs));
    });
  }

  /**
   * Port of retry() / retry(times): resubscribes on onError instead of propagating it.
   * `times` < 0 retries indefinitely; items already emitted are NOT replayed.
   */
  retry(times: number = -1): Observable<T> {
    const upstream: Observable<T> = this;
    return Observable.create<T>((down: Emitter<T>): void => {
      const group: CompositeDisposable = new CompositeDisposable();
      down.setCancellable((): void => {
        group.dispose();
      });
      let remaining: number = times;
      const attempt = (): void => {
        if (down.isDisposed()) {
          return;
        }
        const obs: Observer<T> = {
          onNext: (v: T): void => {
            down.onNext(v);
          },
          onError: (e: Error): void => {
            if (remaining === 0) {
              down.onError(e);
              return;
            }
            if (remaining > 0) {
              remaining = remaining - 1;
            }
            attempt();
          },
          onComplete: (): void => {
            down.onComplete();
          }
        };
        group.add(upstream.subscribe(obs));
      };
      attempt();
    });
  }

  /**
   * Port of timeout(long, TimeUnit): signals TimeoutError if the next item does not arrive
   * within timeoutMs of its predecessor. The window also covers the first item, starting at
   * subscription.
   */
  timeout(timeoutMs: number): Observable<T> {
    const upstream: Observable<T> = this;
    return Observable.create<T>((down: Emitter<T>): void => {
      let handle: number = -1;
      const arm = (): void => {
        if (handle >= 0) {
          clearTimeout(handle);
        }
        handle = setTimeout((): void => {
          down.onError(new TimeoutError(`timed out after ${timeoutMs} ms`));
        }, timeoutMs);
      };
      const disarm = (): void => {
        if (handle >= 0) {
          clearTimeout(handle);
          handle = -1;
        }
      };
      const obs: Observer<T> = {
        onNext: (v: T): void => {
          arm();
          down.onNext(v);
        },
        onError: (e: Error): void => {
          disarm();
          down.onError(e);
        },
        onComplete: (): void => {
          disarm();
          down.onComplete();
        }
      };
      arm();
      const sub: Disposable = upstream.subscribe(obs);
      down.setCancellable((): void => {
        disarm();
        sub.dispose();
      });
    });
  }

  /**
   * Port of debounce(long, TimeUnit): drops an item that is followed by another within
   * timeoutMs. A pending item is emitted when the source completes, as in RxJava.
   */
  debounce(timeoutMs: number): Observable<T> {
    const upstream: Observable<T> = this;
    return Observable.create<T>((down: Emitter<T>): void => {
      let handle: number = -1;
      let hasPending: boolean = false;
      let pending: T | null = null;
      const cancelPendingTimer = (): void => {
        if (handle >= 0) {
          clearTimeout(handle);
          handle = -1;
        }
      };
      const obs: Observer<T> = {
        onNext: (v: T): void => {
          cancelPendingTimer();
          hasPending = true;
          pending = v;
          handle = setTimeout((): void => {
            handle = -1;
            hasPending = false;
            down.onNext(pending as T);
          }, timeoutMs);
        },
        onError: (e: Error): void => {
          cancelPendingTimer();
          hasPending = false;
          down.onError(e);
        },
        onComplete: (): void => {
          cancelPendingTimer();
          if (hasPending) {
            hasPending = false;
            down.onNext(pending as T);
          }
          down.onComplete();
        }
      };
      const sub: Disposable = upstream.subscribe(obs);
      down.setCancellable((): void => {
        cancelPendingTimer();
        sub.dispose();
      });
    });
  }

  /**
   * Port of flatMap(Function): maps each item to an inner source and merges them, so inner
   * results can interleave. Completes when the source and every inner source have completed.
   */
  flatMap<R>(mapper: (value: T) => Observable<R>): Observable<R> {
    const upstream: Observable<T> = this;
    return Observable.create<R>((down: Emitter<R>): void => {
      const group: CompositeDisposable = new CompositeDisposable();
      down.setCancellable((): void => {
        group.dispose();
      });
      let active: number = 1; // the source itself counts as one active producer
      const finishOne = (): void => {
        active = active - 1;
        if (active === 0) {
          down.onComplete();
        }
      };
      const obs: Observer<T> = {
        onNext: (v: T): void => {
          let inner: Observable<R>;
          try {
            inner = mapper(v);
          } catch (err) {
            down.onError(asError(err));
            return;
          }
          active = active + 1;
          const innerObs: Observer<R> = {
            onNext: (r: R): void => {
              down.onNext(r);
            },
            onError: (e: Error): void => {
              down.onError(e);
            },
            onComplete: (): void => {
              finishOne();
            }
          };
          group.add(inner.subscribe(innerObs));
        },
        onError: (e: Error): void => {
          down.onError(e);
        },
        onComplete: (): void => {
          finishOne();
        }
      };
      group.add(upstream.subscribe(obs));
    });
  }

  /**
   * Port of concatMap(Function): the inner sources run strictly in order — the next item is not
   * mapped until the previous inner source has completed.
   */
  concatMap<R>(mapper: (value: T) => Observable<R>): Observable<R> {
    const upstream: Observable<T> = this;
    return Observable.create<R>((down: Emitter<R>): void => {
      const group: CompositeDisposable = new CompositeDisposable();
      down.setCancellable((): void => {
        group.dispose();
      });
      const queue: T[] = [];
      let running: boolean = false;
      let outerDone: boolean = false;

      const drain = (): void => {
        if (running || down.isDisposed()) {
          return;
        }
        if (queue.length === 0) {
          if (outerDone) {
            down.onComplete();
          }
          return;
        }
        const value: T = queue.shift() as T;
        let inner: Observable<R>;
        try {
          inner = mapper(value);
        } catch (err) {
          down.onError(asError(err));
          return;
        }
        running = true;
        const innerObs: Observer<R> = {
          onNext: (r: R): void => {
            down.onNext(r);
          },
          onError: (e: Error): void => {
            down.onError(e);
          },
          onComplete: (): void => {
            running = false;
            drain();
          }
        };
        group.add(inner.subscribe(innerObs));
      };

      const obs: Observer<T> = {
        onNext: (v: T): void => {
          queue.push(v);
          drain();
        },
        onError: (e: Error): void => {
          down.onError(e);
        },
        onComplete: (): void => {
          outerDone = true;
          drain();
        }
      };
      group.add(upstream.subscribe(obs));
    });
  }

  /**
   * Port of switchMap(Function): only the most recently mapped inner source is kept — a new
   * item disposes the previous inner subscription. Completes when the source and the last
   * inner source have completed.
   */
  switchMap<R>(mapper: (value: T) => Observable<R>): Observable<R> {
    const upstream: Observable<T> = this;
    return Observable.create<R>((down: Emitter<R>): void => {
      let current: Disposable | null = null;
      let outerDone: boolean = false;
      let innerActive: boolean = false;
      let outerSub: Disposable | null = null;

      const obs: Observer<T> = {
        onNext: (v: T): void => {
          if (current !== null) {
            current.dispose();
            current = null;
          }
          let inner: Observable<R>;
          try {
            inner = mapper(v);
          } catch (err) {
            down.onError(asError(err));
            return;
          }
          innerActive = true;
          const innerObs: Observer<R> = {
            onNext: (r: R): void => {
              down.onNext(r);
            },
            onError: (e: Error): void => {
              down.onError(e);
            },
            onComplete: (): void => {
              innerActive = false;
              if (outerDone) {
                down.onComplete();
              }
            }
          };
          current = inner.subscribe(innerObs);
        },
        onError: (e: Error): void => {
          down.onError(e);
        },
        onComplete: (): void => {
          outerDone = true;
          if (!innerActive) {
            down.onComplete();
          }
        }
      };
      outerSub = upstream.subscribe(obs);
      down.setCancellable((): void => {
        if (current !== null) {
          current.dispose();
          current = null;
        }
        if (outerSub !== null) {
          outerSub.dispose();
        }
      });
    });
  }
}

/* ////////////////////////////////////////////////////////////////////////////
// Subjects
//////////////////////////////////////////////////////////////////////////// */

/**
 * Port of subjects/PublishSubject.java: a hot Observable that is also an Observer. Items
 * emitted before an observer subscribes are NOT replayed to it; a terminal event IS replayed,
 * so a late subscriber to a terminated Subject is immediately terminated the same way.
 */
export class Subject<T> extends Observable<T> {
  private downstreams: Emitter<T>[] = [];
  private terminalError: Error | null = null;
  private completed: boolean = false;

  constructor() {
    super((emitter: Emitter<T>): void => {
      // never used: subscribeActual is overridden below
    });
  }

  protected subscribeActual(emitter: Emitter<T>): void {
    if (this.terminalError !== null) {
      emitter.onError(this.terminalError);
      return;
    }
    if (this.completed) {
      emitter.onComplete();
      return;
    }
    this.downstreams.push(emitter);
    emitter.setCancellable((): void => {
      const index: number = this.downstreams.indexOf(emitter);
      if (index >= 0) {
        this.downstreams.splice(index, 1);
      }
    });
    this.onSubscribed(emitter);
  }

  /** Hook for BehaviorSubject, which emits its current value on subscribe. */
  protected onSubscribed(emitter: Emitter<T>): void {
  }

  protected isTerminated(): boolean {
    return this.completed || this.terminalError !== null;
  }

  onNext(value: T): void {
    if (this.isTerminated()) {
      return;
    }
    for (const d of this.downstreams.slice()) {
      d.onNext(value);
    }
  }

  onError(error: Error): void {
    if (this.isTerminated()) {
      RxPlugins.onUnhandledError(error);
      return;
    }
    this.terminalError = error;
    const current: Emitter<T>[] = this.downstreams;
    this.downstreams = [];
    for (const d of current) {
      d.onError(error);
    }
  }

  onComplete(): void {
    if (this.isTerminated()) {
      return;
    }
    this.completed = true;
    const current: Emitter<T>[] = this.downstreams;
    this.downstreams = [];
    for (const d of current) {
      d.onComplete();
    }
  }

  hasObservers(): boolean {
    return this.downstreams.length > 0;
  }
}

/**
 * Port of subjects/BehaviorSubject.java: a Subject that remembers the latest item and emits it
 * to every new subscriber before the subsequent items. `new BehaviorSubject<T>(initial)` is
 * createDefault(initial); `new BehaviorSubject<T>()` is create().
 */
export class BehaviorSubject<T> extends Subject<T> {
  private current: T | null;
  private hasValue: boolean;

  constructor(initialValue: T | null = null) {
    super();
    this.current = initialValue;
    this.hasValue = initialValue !== null;
  }

  /** Null while no item has been emitted and after a terminal event, as in RxJava. */
  getValue(): T | null {
    return this.isTerminated() ? null : this.current;
  }

  onNext(value: T): void {
    if (this.isTerminated()) {
      return;
    }
    this.current = value;
    this.hasValue = true;
    super.onNext(value);
  }

  protected onSubscribed(emitter: Emitter<T>): void {
    if (this.hasValue) {
      emitter.onNext(this.current as T);
    }
  }
}
