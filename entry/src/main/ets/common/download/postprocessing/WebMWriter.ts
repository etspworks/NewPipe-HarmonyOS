/*
 * Port of org.schabi.newpipe.streams.WebMWriter (by kapodamy): muxes the selected track of every
 * WebM source into one WebM. Segment size, duration, Cues and cluster sizes are written as
 * placeholders and patched at the end, so the output must seek (or at least rewind).
 *
 * Java's ArrayList<byte[]> with a null "size goes here" slot is a Uint8Array[] with an empty
 * placeholder that lengthFor()/writeBlock() replace before anything is written.
 */

import { DataReader, DataReaderView, toInt32 } from './DataReader';
import {
  Cluster,
  Segment,
  SimpleBlock,
  WebMReader,
  WebMTrack,
  setLong,
  toShort,
  utf8Encode
} from './WebMReader';
import { SharpStream, StreamError } from './SharpStream';

const BUFFER_SIZE: number = 8 * 1024;
const DEFAULT_TIMECODE_SCALE: number = 1000000;
const INTERV: number = 100; // 100ms on 1000000us timecode scale
const DEFAULT_CUES_EACH_MS: number = 5000; // 5000ms on 1000000us timecode scale
const CLUSTER_HEADER_SIZE: number = 8;
const CUE_RESERVE_SIZE: number = 65535;
const MINIMUM_EBML_VOID_SIZE: number = 4;

const SIZE_PLACEHOLDER: Uint8Array = new Uint8Array(0);

/** Java long division: truncates toward zero, exact for |a| < 2^53. */
function longDiv(a: number, b: number): number {
  return (a - a % b) / b;
}

/** The low byte of Java's `number >>> shift` on a long (shift <= 56), as 0..255. */
function byteAt(value: number, shift: number): number {
  const shifted: number = Math.floor(value / Math.pow(2, shift));
  return ((shifted % 256) + 256) % 256;
}

class KeyFrame {
  readonly clusterPosition: number;
  readonly relativePosition: number;
  readonly duration: number;

  constructor(segment: number, cluster: number, block: number, timecode: number) {
    this.clusterPosition = cluster - segment;
    this.relativePosition = toInt32(block - cluster - CLUSTER_HEADER_SIZE);
    this.duration = timecode;
  }
}

class Block {
  data: DataReaderView | null = null;
  trackNumber: number = 0;
  /** A Java (signed) byte. */
  flags: number = 0;
  dataSize: number = 0;
  absoluteTimecode: number = 0;

  isKeyframe(): boolean {
    return (this.flags & 0x80) === 0x80;
  }

  toString(): string {
    return 'trackNumber=' + this.trackNumber + '  isKeyFrame='
      + (this.isKeyframe() ? 'TRUE' : 'FALSE') + '  absoluteTimecode=' + this.absoluteTimecode;
  }
}

class ClusterInfo {
  offset: number = 0;
  size: number = 0;
}

export class WebMWriter {
  private infoTracks: WebMTrack[] = [];
  private sourceTracks: SharpStream[];

  private readers: WebMReader[] = [];

  private done: boolean = false;
  private parsed: boolean = false;

  private written: number = 0;

  private readersSegment: (Segment | null)[] = [];
  private readersCluster: (Cluster | null)[] = [];

  private clustersOffsetsSizes: ClusterInfo[] = [];

  private readonly outBuffer: Uint8Array;
  private readonly outByteBuffer: DataView;

  constructor(source: SharpStream[]) {
    this.sourceTracks = source;
    this.outBuffer = new Uint8Array(BUFFER_SIZE);
    this.outByteBuffer = new DataView(this.outBuffer.buffer);
  }

  getTracksFromSource(sourceIndex: number): WebMTrack[] {
    if (this.done) {
      throw new Error('already done');
    }
    if (!this.parsed) {
      throw new Error('All sources must be parsed first');
    }

    return this.readers[sourceIndex].getAvailableTracks();
  }

  parseSources(): void {
    if (this.done) {
      throw new Error('already done');
    }
    if (this.parsed) {
      throw new Error('already parsed');
    }

    try {
      for (let i: number = 0; i < this.sourceTracks.length; i++) {
        const reader: WebMReader = new WebMReader(this.sourceTracks[i]);
        this.readers.push(reader);
        reader.parse();
      }
    } finally {
      this.parsed = true;
    }
  }

  selectTracks(trackIndex: number[]): void {
    try {
      this.readersSegment = [];
      this.readersCluster = [];
      this.infoTracks = [];

      for (let i: number = 0; i < this.readers.length; i++) {
        this.infoTracks.push(this.readers[i].selectTrack(trackIndex[i]));
        this.readersSegment.push(this.readers[i].getNextSegment());
        this.readersCluster.push(null);
      }
    } finally {
      this.parsed = true;
    }
  }

  isDone(): boolean {
    return this.done;
  }

  close(): void {
    this.done = true;
    this.parsed = true;

    for (const src of this.sourceTracks) {
      src.close();
    }

    this.sourceTracks = [];
    this.readers = [];
    this.infoTracks = [];
    this.readersSegment = [];
    this.readersCluster = [];
    this.clustersOffsetsSizes = [];
  }

  build(out: SharpStream): void {
    if (!out.canRewind()) {
      throw new StreamError('The output stream must be allow seek');
    }

    this.makeEBML(out);

    const offsetSegmentSizeSet: number = this.written + 5;
    const offsetInfoDurationSet: number = this.written + 94;
    const offsetClusterSet: number = this.written + 58;
    const offsetCuesSet: number = this.written + 75;

    const listBuffer: Uint8Array[] = [];

    /* segment */
    listBuffer.push(new Uint8Array([
      0x18, 0x53, 0x80, 0x67, 0x01,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00// segment content size
    ]));

    const segmentOffset: number = this.written + listBuffer[0].length;

    /* seek head */
    listBuffer.push(new Uint8Array([
      0x11, 0x4d, 0x9b, 0x74, 0xbe,
      0x4d, 0xbb, 0x8b,
      0x53, 0xab, 0x84, 0x15, 0x49, 0xa9, 0x66, 0x53,
      0xac, 0x81,
      /*info offset*/ 0x43,
      0x4d, 0xbb, 0x8b, 0x53, 0xab,
      0x84, 0x16, 0x54, 0xae, 0x6b, 0x53, 0xac, 0x81,
      /*tracks offset*/ 0x56,
      0x4d, 0xbb, 0x8e, 0x53, 0xab, 0x84, 0x1f,
      0x43, 0xb6, 0x75, 0x53, 0xac, 0x84,
      /*cluster offset [2]*/ 0x00, 0x00, 0x00, 0x00,
      0x4d, 0xbb, 0x8e, 0x53, 0xab, 0x84, 0x1c, 0x53,
      0xbb, 0x6b, 0x53, 0xac, 0x84,
      /*cues offset [7]*/ 0x00, 0x00, 0x00, 0x00
    ]));

    /* info */
    listBuffer.push(new Uint8Array([
      0x15, 0x49, 0xa9, 0x66, 0x8e, 0x2a, 0xd7, 0xb1
    ]));
    // the segment duration MUST NOT exceed 4 bytes
    listBuffer.push(this.encode(DEFAULT_TIMECODE_SCALE, true));
    listBuffer.push(new Uint8Array([0x44, 0x89, 0x84,
      0x00, 0x00, 0x00, 0x00, // info.duration
    ]));

    /* tracks */
    for (const part of this.makeTracks()) {
      listBuffer.push(part);
    }

    this.dumpList(listBuffer, out);

    // reserve space for Cues element
    const cueOffset: number = this.written;
    this.makeEbmlVoid(out, CUE_RESERVE_SIZE, true);

    const defaultSampleDuration: number[] = [];
    const duration: number[] = [];

    for (let i: number = 0; i < this.infoTracks.length; i++) {
      if (this.infoTracks[i].defaultDuration < 0) {
        defaultSampleDuration.push(-1); // not available
      } else {
        // (int) Math.ceil(defaultDuration / (float) DEFAULT_TIMECODE_SCALE): float division
        defaultSampleDuration.push(Math.ceil(
          Math.fround(Math.fround(this.infoTracks[i].defaultDuration) / DEFAULT_TIMECODE_SCALE)));
      }
      duration.push(-1);
    }

    // Select a track for the cue
    const cuesForTrackId: number = this.selectTrackForCue();
    let nextCueTime: number = this.infoTracks[cuesForTrackId].trackType === 1 ? -1 : 0;
    const keyFrames: KeyFrame[] = [];

    let firstClusterOffset: number = toInt32(this.written);
    let currentClusterOffset: number = this.makeCluster(out, 0, 0, true);

    let baseTimecode: number = 0;
    let limitTimecode: number = -1;
    let limitTimecodeByTrackId: number = cuesForTrackId;

    let blockWritten: number = 2147483647; // Integer.MAX_VALUE

    let newClusterByTrackId: number = -1;

    while (blockWritten > 0) {
      blockWritten = 0;
      let i: number = 0;
      while (i < this.readers.length) {
        const bloq: Block | null = this.getNextBlockFrom(i);
        if (bloq === null) {
          i++;
          continue;
        }

        if (bloq.data === null) {
          blockWritten = 1; // fake block
          newClusterByTrackId = i;
          i++;
          continue;
        }

        if (newClusterByTrackId === i) {
          limitTimecodeByTrackId = i;
          newClusterByTrackId = -1;
          baseTimecode = bloq.absoluteTimecode;
          limitTimecode = baseTimecode + INTERV;
          currentClusterOffset = this.makeCluster(out, baseTimecode, currentClusterOffset, true);
        }

        if (cuesForTrackId === i) {
          if ((nextCueTime > -1 && bloq.absoluteTimecode >= nextCueTime)
            || (nextCueTime < 0 && bloq.isKeyframe())) {
            if (nextCueTime > -1) {
              nextCueTime += DEFAULT_CUES_EACH_MS;
            }
            keyFrames.push(new KeyFrame(segmentOffset, currentClusterOffset, this.written,
              bloq.absoluteTimecode));
          }
        }

        this.writeBlock(out, bloq, baseTimecode);
        blockWritten++;

        if (defaultSampleDuration[i] < 0 && duration[i] >= 0) {
          // if the sample duration in unknown,
          // calculate using current_duration - previous_duration
          defaultSampleDuration[i] = toInt32(bloq.absoluteTimecode - duration[i]);
        }
        duration[i] = bloq.absoluteTimecode;

        if (limitTimecode < 0) {
          limitTimecode = bloq.absoluteTimecode + INTERV;
          continue;
        }

        if (bloq.absoluteTimecode >= limitTimecode) {
          if (limitTimecodeByTrackId !== i) {
            limitTimecode += INTERV - (bloq.absoluteTimecode - limitTimecode);
          }
          i++;
        }
      }
    }

    this.makeCluster(out, -1, currentClusterOffset, false);

    const segmentSize: number = this.written - offsetSegmentSizeSet - 7;

    /* Segment size */
    this.seekTo(out, offsetSegmentSizeSet);
    setLong(this.outByteBuffer, 0, segmentSize, false);
    out.writeFrom(this.outBuffer, 1, DataReader.LONG_SIZE - 1); // not dump(): `written` stays

    /* Segment duration */
    let longestDuration: number = 0;
    for (let i: number = 0; i < duration.length; i++) {
      if (defaultSampleDuration[i] > 0) {
        duration[i] += defaultSampleDuration[i];
      }
      if (duration[i] > longestDuration) {
        longestDuration = duration[i];
      }
    }
    this.seekTo(out, offsetInfoDurationSet);
    this.outByteBuffer.setFloat32(0, longestDuration); // putFloat(long): nearest float
    this.dumpCount(this.outBuffer, DataReader.FLOAT_SIZE, out);

    /* first Cluster offset */
    firstClusterOffset = toInt32(firstClusterOffset - segmentOffset);
    this.writeInt(out, offsetClusterSet, firstClusterOffset);

    this.seekTo(out, cueOffset);

    /* Cue */
    // A Java short, kept as such for identical output: past 32767 it wraps negative, so the "no
    // space left" check below never fires. Up to 65524 bytes of CuePoints the 16-bit sizes still
    // come out right; beyond that the Cues run past the reservation into the first Cluster.
    let cueSize: number = 0;
    this.dump(new Uint8Array([0x1c, 0x53, 0xbb, 0x6b, 0x20, 0x00, 0x00]), out); // header size is 7

    for (const keyFrame of keyFrames) {
      const size: number = this.makeCuePoint(cuesForTrackId, keyFrame, this.outBuffer);

      if ((cueSize + size + 7 + MINIMUM_EBML_VOID_SIZE) > CUE_RESERVE_SIZE) {
        break; // no space left
      }

      cueSize = toShort(cueSize + size);
      this.dumpCount(this.outBuffer, size, out);
    }

    this.makeEbmlVoid(out, CUE_RESERVE_SIZE - cueSize - 7, false);

    this.seekTo(out, cueOffset + 5);
    this.outByteBuffer.setInt16(0, cueSize);
    this.dumpCount(this.outBuffer, DataReader.SHORT_SIZE, out);

    /* seek head, seek for cues element */
    this.writeInt(out, offsetCuesSet, toInt32(cueOffset - segmentOffset));

    for (const cluster of this.clustersOffsetsSizes) {
      this.writeInt(out, cluster.offset, cluster.size | 0x10000000);
    }
  }

  private getNextBlockFrom(internalTrackId: number): Block | null {
    let segment: Segment | null = this.readersSegment[internalTrackId];
    if (segment === null) {
      segment = this.readers[internalTrackId].getNextSegment();
      this.readersSegment[internalTrackId] = segment;
      if (segment === null) {
        return null; // no more blocks in the selected track
      }
    }

    let cluster: Cluster | null = this.readersCluster[internalTrackId];
    if (cluster === null) {
      cluster = segment.getNextCluster();
      this.readersCluster[internalTrackId] = cluster;
      if (cluster === null) {
        this.readersSegment[internalTrackId] = null;
        return this.getNextBlockFrom(internalTrackId);
      }
    }

    const res: SimpleBlock | null = cluster.getNextSimpleBlock();
    if (res === null) {
      this.readersCluster[internalTrackId] = null;
      return new Block(); // fake block to indicate the end of the cluster
    }

    const bloq: Block = new Block();
    bloq.data = res.data;
    bloq.dataSize = res.dataSize;
    bloq.trackNumber = internalTrackId;
    bloq.flags = res.flags;
    bloq.absoluteTimecode = longDiv(res.absoluteTimeCodeNs, DEFAULT_TIMECODE_SCALE);

    return bloq;
  }

  private seekTo(stream: SharpStream, offset: number): void {
    if (stream.canSeek()) {
      stream.seek(offset);
    } else {
      if (offset > this.written) {
        stream.skip(offset - this.written);
      } else {
        stream.rewind();
        stream.skip(offset);
      }
    }

    this.written = offset;
  }

  private writeInt(stream: SharpStream, offset: number, num: number): void {
    this.seekTo(stream, offset);
    this.outByteBuffer.setInt32(0, num);
    this.dumpCount(this.outBuffer, DataReader.INTEGER_SIZE, stream);
  }

  private writeBlock(stream: SharpStream, bloq: Block, clusterTimecode: number): void {
    const relativeTimeCode: number = bloq.absoluteTimecode - clusterTimecode;

    if (relativeTimeCode < -32768 || relativeTimeCode > 32767) {
      throw new Error('SimpleBlock timecode overflow.');
    }

    const timecode: Uint8Array = new Uint8Array(DataReader.SHORT_SIZE);
    new DataView(timecode.buffer).setInt16(0, relativeTimeCode);

    const listBuffer: Uint8Array[] = [];
    listBuffer.push(new Uint8Array([0xa3]));
    listBuffer.push(SIZE_PLACEHOLDER); // block size
    listBuffer.push(this.encode(bloq.trackNumber + 1, false));
    listBuffer.push(timecode);
    listBuffer.push(new Uint8Array([bloq.flags & 0xFF]));

    let blockSize: number = bloq.dataSize;
    for (let i: number = 2; i < listBuffer.length; i++) {
      blockSize += listBuffer[i].length;
    }
    listBuffer[1] = this.encode(blockSize, false);

    this.dumpList(listBuffer, stream);

    const data: DataReaderView | null = bloq.data;
    if (data === null) {
      throw new Error('block without data'); // a NullPointerException in the source
    }
    let read: number = data.read1(this.outBuffer);
    while (read > 0) {
      this.dumpCount(this.outBuffer, read, stream);
      read = data.read1(this.outBuffer);
    }
  }

  private makeCluster(stream: SharpStream, timecode: number, offsetStart: number,
    create: boolean): number {
    let offset: number = offsetStart;

    if (offset > 0) {
      // save the size of the previous cluster (maximum 256 MiB)
      const previous: ClusterInfo = this.clustersOffsetsSizes[this.clustersOffsetsSizes.length - 1];
      previous.size = toInt32(this.written - offset - CLUSTER_HEADER_SIZE);
    }

    offset = this.written;

    if (create) {
      /* cluster */
      this.dump(new Uint8Array([0x1f, 0x43, 0xb6, 0x75]), stream);

      const cluster: ClusterInfo = new ClusterInfo();
      cluster.offset = this.written;
      this.clustersOffsetsSizes.push(cluster);

      this.dump(new Uint8Array([
        0x10, 0x00, 0x00, 0x00,
        /* timestamp */
        0xe7
      ]), stream);

      this.dump(this.encode(timecode, true), stream);
    }

    return offset;
  }

  private makeEBML(stream: SharpStream): void {
    // default values
    this.dump(new Uint8Array([
      0x1A, 0x45, 0xDF, 0xA3, 0x01, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x1F, 0x42, 0x86, 0x81, 0x01,
      0x42, 0xF7, 0x81, 0x01, 0x42, 0xF2, 0x81, 0x04,
      0x42, 0xF3, 0x81, 0x08, 0x42, 0x82, 0x84, 0x77,
      0x65, 0x62, 0x6D, 0x42, 0x87, 0x81, 0x02,
      0x42, 0x85, 0x81, 0x02
    ]), stream);
  }

  private makeTracks(): Uint8Array[] {
    const buffer: Uint8Array[] = [];
    buffer.push(new Uint8Array([0x16, 0x54, 0xae, 0x6b]));
    buffer.push(SIZE_PLACEHOLDER);

    for (let i: number = 0; i < this.infoTracks.length; i++) {
      for (const part of this.makeTrackEntry(i, this.infoTracks[i])) {
        buffer.push(part);
      }
    }

    return this.lengthFor(buffer);
  }

  private makeTrackEntry(internalTrackId: number, track: WebMTrack): Uint8Array[] {
    const id: Uint8Array = this.encode(internalTrackId + 1, true);
    const buffer: Uint8Array[] = [];

    /* track */
    buffer.push(new Uint8Array([0xae]));
    buffer.push(SIZE_PLACEHOLDER);

    /* track number */
    buffer.push(new Uint8Array([0xd7]));
    buffer.push(id);

    /* track uid */
    buffer.push(new Uint8Array([0x73, 0xc5]));
    buffer.push(id);

    /* flag lacing */
    buffer.push(new Uint8Array([0x9c, 0x81, 0x00]));

    /* lang */
    buffer.push(new Uint8Array([0x22, 0xb5, 0x9c, 0x83, 0x75, 0x6e, 0x64]));

    /* codec id */
    const codecId: string | null = track.codecId;
    if (codecId === null) {
      throw new Error('track without CodecID'); // a NullPointerException in the source
    }
    buffer.push(new Uint8Array([0x86]));
    for (const part of this.encodeString(codecId)) {
      buffer.push(part);
    }

    /* codec delay*/
    if (track.codecDelay >= 0) {
      buffer.push(new Uint8Array([0x56, 0xAA]));
      buffer.push(this.encode(track.codecDelay, true));
    }

    /* codec seek pre-roll*/
    if (track.seekPreRoll >= 0) {
      buffer.push(new Uint8Array([0x56, 0xBB]));
      buffer.push(this.encode(track.seekPreRoll, true));
    }

    /* type */
    buffer.push(new Uint8Array([0x83]));
    buffer.push(this.encode(track.trackType, true));

    /* default duration */
    if (track.defaultDuration >= 0) {
      buffer.push(new Uint8Array([0x23, 0xe3, 0x83]));
      buffer.push(this.encode(track.defaultDuration, true));
    }

    /* audio/video */
    const bMetadata: Uint8Array | null = track.bMetadata;
    if ((track.trackType === 1 || track.trackType === 2) && bMetadata !== null
      && bMetadata.length > 0) { // valid(track.bMetadata)
      buffer.push(new Uint8Array([track.trackType === 1 ? 0xe0 : 0xe1]));
      buffer.push(this.encode(bMetadata.length, false));
      buffer.push(bMetadata);
    }

    /* codec private*/
    const codecPrivate: Uint8Array | null = track.codecPrivate;
    if (codecPrivate !== null && codecPrivate.length > 0) { // valid(track.codecPrivate)
      buffer.push(new Uint8Array([0x63, 0xa2]));
      buffer.push(this.encode(codecPrivate.length, false));
      buffer.push(codecPrivate);
    }

    return this.lengthFor(buffer);
  }

  private makeCuePoint(internalTrackId: number, keyFrame: KeyFrame, buffer: Uint8Array): number {
    const cue: Uint8Array[] = [];

    /* CuePoint */
    cue.push(new Uint8Array([0xbb]));
    cue.push(SIZE_PLACEHOLDER);

    /* CueTime */
    cue.push(new Uint8Array([0xb3]));
    cue.push(this.encode(keyFrame.duration, true));

    /* CueTrackPosition */
    for (const part of this.makeCueTrackPosition(internalTrackId, keyFrame)) {
      cue.push(part);
    }

    let size: number = 0;
    this.lengthFor(cue);

    for (const buff of cue) {
      buffer.set(buff, size);
      size += buff.length;
    }

    return size;
  }

  private makeCueTrackPosition(internalTrackId: number, keyFrame: KeyFrame): Uint8Array[] {
    const buffer: Uint8Array[] = [];

    /* CueTrackPositions */
    buffer.push(new Uint8Array([0xb7]));
    buffer.push(SIZE_PLACEHOLDER);

    /* CueTrack */
    buffer.push(new Uint8Array([0xf7]));
    buffer.push(this.encode(internalTrackId + 1, true));

    /* CueClusterPosition */
    buffer.push(new Uint8Array([0xf1]));
    buffer.push(this.encode(keyFrame.clusterPosition, true));

    /* CueRelativePosition */
    if (keyFrame.relativePosition > 0) {
      buffer.push(new Uint8Array([0xf0]));
      buffer.push(this.encode(keyFrame.relativePosition, true));
    }

    return this.lengthFor(buffer);
  }

  /** With `wipe` the body is outBuffer's current bytes, exactly as the source writes it. */
  private makeEbmlVoid(out: SharpStream, amount: number, wipe: boolean): void {
    let size: number = amount;

    /* ebml void */
    this.outByteBuffer.setInt16(0, toShort(0xec20));
    this.outByteBuffer.setInt16(2, toShort(size - 4));

    this.dumpCount(this.outBuffer, 4, out);

    if (wipe) {
      size -= 4;
      while (size > 0) {
        const write: number = Math.min(size, this.outBuffer.length);
        this.dumpCount(this.outBuffer, write, out);
        size -= write;
      }
    }
  }

  private dump(buffer: Uint8Array, stream: SharpStream): void {
    this.dumpCount(buffer, buffer.length, stream);
  }

  private dumpCount(buffer: Uint8Array, count: number, stream: SharpStream): void {
    stream.writeFrom(buffer, 0, count);
    this.written += count;
  }

  private dumpList(buffers: Uint8Array[], stream: SharpStream): void {
    for (const buffer of buffers) {
      stream.write(buffer);
      this.written += buffer.length;
    }
  }

  private lengthFor(buffer: Uint8Array[]): Uint8Array[] {
    let size: number = 0;
    for (let i: number = 2; i < buffer.length; i++) {
      size += buffer[i].length;
    }
    buffer[1] = this.encode(size, false);
    return buffer;
  }

  private encode(num: number, withLength: boolean): Uint8Array {
    let length: number = -1;
    for (let i: number = 1; i <= 7; i++) {
      if (num < Math.pow(2, 7 * i)) {
        length = i;
        break;
      }
    }

    if (length < 1) {
      throw new Error('Can\'t encode a number of bigger than 7 bytes');
    }

    if (num === (Math.pow(2, 7 * length)) - 1) {
      length++;
    }

    const offset: number = withLength ? 1 : 0;
    const buffer: Uint8Array = new Uint8Array(offset + length);
    const marker: number = Math.floor((length - 1) / 8);

    let shift: number = 0;
    for (let i: number = length - 1; i >= 0; i--) {
      let b: number = byteAt(num, shift);
      if (!withLength && i === marker) {
        b = b | (0x80 >>> (length - 1));
      }
      buffer[offset + i] = b;
      shift += 8;
    }

    if (withLength) {
      buffer[0] = 0x80 | length;
    }

    return buffer;
  }

  private encodeString(value: string): Uint8Array[] {
    const str: Uint8Array = utf8Encode(value); // or use "utf-8"

    const buffer: Uint8Array[] = [];
    buffer.push(this.encode(str.length, false));
    buffer.push(str);

    return buffer;
  }

  private selectTrackForCue(): number {
    let videoTracks: number = 0;
    let audioTracks: number = 0;

    for (let i: number = 0; i < this.infoTracks.length; i++) {
      switch (this.infoTracks[i].trackType) {
        case 1:
          videoTracks++;
          break;
        case 2:
          audioTracks++;
          break;
      }
    }

    let kind: number = 0;
    if (audioTracks === this.infoTracks.length) {
      kind = 2;
    } else if (videoTracks === this.infoTracks.length) {
      kind = 1;
    } else if (videoTracks > 0) {
      kind = 1;
    } else if (audioTracks > 0) {
      kind = 2;
    } else {
      return 0;
    }

    // TODO: in the above code, find and select the shortest track for the desired kind
    for (let i: number = 0; i < this.infoTracks.length; i++) {
      if (kind === this.infoTracks[i].trackType) {
        return i;
      }
    }

    return 0;
  }
}
