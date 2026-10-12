/*
 * The WebM post-processing algorithms: process() of us.shandian.giga.postprocessing.WebMMuxer and
 * test() / process() of OggFromWebmDemuxer. As in Postprocessing.run(), the caller rewinds the
 * sources between oggFromWebmTest() and oggFromWebm(), and closes them afterwards.
 */

import { OggFromWebMWriter, OggStreamInfo } from './OggFromWebMWriter';
import { SharpStream } from './SharpStream';
import { TrackKind, WebMTrack } from './WebMReader';
import { WebMWriter } from './WebMWriter';

/** WebMMuxer.process. */
export function muxWebM(out: SharpStream, sources: SharpStream[]): void {
  const muxer: WebMWriter = new WebMWriter(sources);
  muxer.parseSources();

  // youtube uses a webm with a fake video track that acts as a "cover image"
  const indexes: number[] = new Array<number>(sources.length).fill(0);

  // As in the source, the search stops at the first source with an audio track: every other
  // source keeps track 0.
  for (let i: number = 0; i < sources.length; i++) {
    const tracks: WebMTrack[] = muxer.getTracksFromSource(i);
    for (let j: number = 0; j < tracks.length; j++) {
      if (tracks[j].kind === TrackKind.Audio) {
        indexes[i] = j;
        i = sources.length;
        break;
      }
    }
  }

  muxer.selectTracks(indexes);
  muxer.build(out);
}

/** OggFromWebmDemuxer.test: true when the file is a WebM to demux, false when it is Ogg already. */
export function oggFromWebmTest(source: SharpStream): boolean {
  const buffer: Uint8Array = new Uint8Array(4);
  source.read1(buffer);

  // youtube uses WebM as container, but the file extension (format suffix) is "*.opus"
  // check if the file is a webm/mkv file before proceed

  switch (new DataView(buffer.buffer).getInt32(0)) {
    case 0x1a45dfa3:
      return true;// webm/mkv
    case 0x4F676753:
      return false;// ogg
  }

  throw new Error('file not recognized, failed to demux the audio stream');
}

/**
 * OggFromWebmDemuxer.process. The source passes the mission's StreamInfo for the Opus tags;
 * without one (null) the OpusTags header carries no tags.
 */
export function oggFromWebm(out: SharpStream, source: SharpStream,
  streamInfo: OggStreamInfo | null = null): void {
  const demuxer: OggFromWebMWriter = new OggFromWebMWriter(source, out, streamInfo);
  demuxer.parseSource();
  demuxer.selectTrack(0);
  demuxer.build();
}
