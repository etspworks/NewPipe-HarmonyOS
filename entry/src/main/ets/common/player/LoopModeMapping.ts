/*
 * svc_loop_mode - the player's repeat mode and shuffle flag, as AVSession's single LoopMode.
 *
 * AVSession carries ONE field (@ohos.multimedia.avsession.d.ts: AVPlaybackState.loopMode, @since
 * 12) whose values include LOOP_MODE_SHUFFLE. So repeat and shuffle are not two independent
 * things to the system card: shuffle is a mode. The folding decision is here, in one place, with
 * a test - not spread across the two call sites.
 *
 * The numeric values mirror avSession.LoopMode. They are NOT imported, so the host test runner -
 * which has no device kits - can pin this mapping. MediaSessionService asserts they still match
 * at startup; if the SDK ever renumbers them, that assert is what catches it.
 */

import { RepeatMode } from './PlayerService';

/** avSession.LoopMode.LOOP_MODE_SEQUENCE .. LOOP_MODE_SHUFFLE, mirrored. */
export const AV_LOOP_SEQUENCE: number = 0;
export const AV_LOOP_SINGLE: number = 1;
export const AV_LOOP_LIST: number = 2;
export const AV_LOOP_SHUFFLE: number = 3;

/** What the player's state looks like to the system card. */
export function toLoopMode(repeat: RepeatMode, shuffled: boolean): number {
  if (shuffled) {
    return AV_LOOP_SHUFFLE;
  }
  if (repeat === RepeatMode.ONE) {
    return AV_LOOP_SINGLE;
  }
  if (repeat === RepeatMode.ALL) {
    return AV_LOOP_LIST;
  }
  return AV_LOOP_SEQUENCE;
}

/** The two halves a LoopMode means to this app. */
export class PlayerLoopState {
  readonly repeat: RepeatMode;
  readonly shuffled: boolean;

  constructor(repeat: RepeatMode, shuffled: boolean) {
    this.repeat = repeat;
    this.shuffled = shuffled;
  }
}

/** What a setLoopMode command from the system card means to the player. */
export function fromLoopMode(mode: number): PlayerLoopState {
  if (mode === AV_LOOP_SHUFFLE) {
    // Shuffle says nothing about repeat. The caller applies only the shuffle half for this one,
    // so the user's repeat choice is not silently cleared by a shuffle tap - see
    // MediaSessionService.applyLoopState.
    return new PlayerLoopState(RepeatMode.OFF, true);
  }
  if (mode === AV_LOOP_SINGLE) {
    return new PlayerLoopState(RepeatMode.ONE, false);
  }
  if (mode === AV_LOOP_LIST) {
    return new PlayerLoopState(RepeatMode.ALL, false);
  }
  // LOOP_MODE_SEQUENCE and anything unknown: no repeat, no shuffle.
  return new PlayerLoopState(RepeatMode.OFF, false);
}
