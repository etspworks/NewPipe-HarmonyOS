/*
 * Port of us.shandian.giga.postprocessing.TtmlConverter.process() for a TTML source. The switch
 * on the source format around it (an "srt" source is copied as-is) is in Postprocessing.ts.
 */

import { SharpStream, StreamError } from './SharpStream';
import { SrtFromTtmlWriter } from './SrtFromTtmlWriter';

export function ttmlToSrt(out: SharpStream, source: SharpStream, ignoreEmptyFrames: boolean): void {
  const writer: SrtFromTtmlWriter = new SrtFromTtmlWriter(out, ignoreEmptyFrames);
  try {
    writer.build(source);
  } catch (err) {
    const failure: Error = err as Error;
    // The source rethrows an IOException as it is and wraps anything else in one. Here an I/O
    // error - a StreamError, or fileIo's coded error that Postprocessing.ts tells a full disk
    // by - goes up untouched; a fault of the conversion itself is wrapped. Log.e is not ported.
    if (failure instanceof TypeError || failure instanceof RangeError) {
      throw new StreamError('TTML to SRT conversion failed: ' + failure.message);
    }
    throw failure;
  }
}
