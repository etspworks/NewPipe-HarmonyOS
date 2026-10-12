/*
 * The MP4 post-processing algorithms of us.shandian.giga.postprocessing:
 * Mp4FromDashMuxer ("mp4D-mp4") and M4aNoDash ("mp4D-m4a").
 */

import { Mp4DashReader } from './Mp4DashReader';
import { Mp4FromDashWriter } from './Mp4FromDashWriter';
import { SharpStream } from './SharpStream';

/** Mp4FromDashMuxer.process(): the video and audio DASH sources muxed into one MP4. */
export function muxMp4FromDash(out: SharpStream, sources: SharpStream[]): void {
  const muxer: Mp4FromDashWriter = new Mp4FromDashWriter(sources);
  muxer.parseSources();
  muxer.selectTracks(0, 0);
  muxer.build(out);
}

/**
 * M4aNoDash.test(): true when the m4a is a DASH container that needs rewriting. As in the source,
 * parse() itself throws for any other major brand, so this never actually answers false. The
 * caller rewinds the source before process(), as Postprocessing.run() does.
 */
export function m4aNoDashTest(source: SharpStream): boolean {
  // check if the mp4 file is DASH (youtube)
  const reader: Mp4DashReader = new Mp4DashReader(source);
  reader.parse();

  const majorBrand: number = reader.getBrands()[0];
  return majorBrand === 0x64617368 || majorBrand === 0x69736F35; // DASH, ISO5
}

/** M4aNoDash.process(): the DASH m4a rewritten as a regular one, branded "M4A ". */
export function m4aNoDash(out: SharpStream, source: SharpStream): void {
  const muxer: Mp4FromDashWriter = new Mp4FromDashWriter([source]);
  muxer.setMainBrand(0x4D344120); // binary string "M4A "
  muxer.parseSources();
  muxer.selectTracks(0);
  muxer.build(out);
}
