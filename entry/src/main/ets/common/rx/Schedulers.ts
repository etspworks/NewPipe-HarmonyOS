/*
 * Port of io.reactivex.rxjava3.schedulers.Schedulers (RxJava 3.1.12) and
 * io.reactivex.rxjava3.android.schedulers.AndroidSchedulers (RxAndroid 3.0.2),
 * vendored at input/source/RxJava and input/source/RxAndroid.
 *
 * Ported semantics, per the Phase-2 logic contract section 1:
 *
 *  - Schedulers.io()                    -> IDENTITY. `@ohos.net.http` and `relationalStore`
 *                                          are already asynchronous on HarmonyOS, so there is
 *                                          no blocking I/O to move off the caller's thread.
 *  - AndroidSchedulers.mainThread()     -> IDENTITY. ArkTS callbacks already resolve on the
 *                                          UI thread, so `observeOn(mainThread())` is a no-op.
 *  - Schedulers.computation()           -> the marker for genuinely CPU-bound work, which is
 *                                          moved off-thread with `@ohos.taskpool`
 *                                          (see runOnTaskPool below).
 *
 * ArkTS has no shared-memory threads: a taskpool payload must be serializable and the
 * function must be a top-level `@Concurrent` function. That is why the CPU-bound path is a
 * `taskpool.Task` handed to `runOnTaskPool`, not a `Scheduler` the operator chain hops onto.
 * The RxJava scheduler machinery (Worker, trampoline queues, drift correction) is deliberately
 * NOT ported - there is nothing for it to schedule.
 */

import { taskpool } from '@kit.ArkTS';

/**
 * A place where work runs. On HarmonyOS every scheduler the app uses is `inline` (identity);
 * `computation` is a marker whose real off-thread execution goes through `runOnTaskPool`.
 */
export class Scheduler {
  readonly name: string;

  constructor(name: string) {
    this.name = name;
  }

  /**
   * Runs `task`, optionally after `delayMs`. Returns a handle that `cancel` accepts.
   * A zero delay runs inline, which is what makes io()/mainThread() identity.
   */
  schedule(task: () => void, delayMs: number = 0): number {
    if (delayMs <= 0) {
      task();
      return -1;
    }
    return setTimeout(task, delayMs);
  }

  cancel(handle: number): void {
    if (handle >= 0) {
      clearTimeout(handle);
    }
  }
}

const IO_SCHEDULER: Scheduler = new Scheduler('io');
const COMPUTATION_SCHEDULER: Scheduler = new Scheduler('computation');
const SINGLE_SCHEDULER: Scheduler = new Scheduler('single');
const NEW_THREAD_SCHEDULER: Scheduler = new Scheduler('newThread');
const TRAMPOLINE_SCHEDULER: Scheduler = new Scheduler('trampoline');
const MAIN_THREAD_SCHEDULER: Scheduler = new Scheduler('mainThread');

export class Schedulers {
  static io(): Scheduler {
    return IO_SCHEDULER;
  }

  static computation(): Scheduler {
    return COMPUTATION_SCHEDULER;
  }

  static single(): Scheduler {
    return SINGLE_SCHEDULER;
  }

  static newThread(): Scheduler {
    return NEW_THREAD_SCHEDULER;
  }

  static trampoline(): Scheduler {
    return TRAMPOLINE_SCHEDULER;
  }
}

export class AndroidSchedulers {
  static mainThread(): Scheduler {
    return MAIN_THREAD_SCHEDULER;
  }
}

/**
 * The real `Schedulers.computation()` substitution: run one CPU-bound step off the UI thread.
 *
 * The caller declares its own top-level `@Concurrent` function and passes a
 * `new taskpool.Task(fn, ...serializableArgs)`. Nothing stateful can cross the boundary.
 */
export async function runOnTaskPool<T>(task: taskpool.Task): Promise<T> {
  const result: Object = await taskpool.execute(task);
  return result as T;
}
