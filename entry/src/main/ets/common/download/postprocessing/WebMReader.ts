/*
 * Port of org.schabi.newpipe.streams.WebMReader (by kapodamy): a forward-only EBML reader that
 * walks Segment -> Cluster -> SimpleBlock / BlockGroup of one selected track.
 *
 * Java's nested types are top-level classes here. Segment and Cluster were inner (non-static)
 * classes, so they keep their WebMReader and reach its state through it - and, as in the source,
 * Segment.getNextCluster() works on the reader's CURRENT segment, not on `this`.
 *
 * Java longs (offsets, sizes, timecodes) are plain numbers combined with arithmetic only, never
 * with bitwise operators, so they stay exact up to 2^53. A Java (int) cast of a long is
 * DataReader's toInt32(); the other narrowing helpers are below, and the writers import them too.
 */

import { DataReader, DataReaderView, toInt32 } from './DataReader';
import { SharpStream, StreamError } from './SharpStream';

const ID_EMBL: number = 0x0A45DFA3;
const ID_EMBL_READ_VERSION: number = 0x02F7;
const ID_EMBL_DOC_TYPE: number = 0x0282;
const ID_EMBL_DOC_TYPE_READ_VERSION: number = 0x0285;

const ID_SEGMENT: number = 0x08538067;

const ID_INFO: number = 0x0549A966;
const ID_TIMECODE_SCALE: number = 0x0AD7B1;
const ID_DURATION: number = 0x489;

const ID_TRACKS: number = 0x0654AE6B;
const ID_TRACK_ENTRY: number = 0x2E;
const ID_TRACK_NUMBER: number = 0x57;
const ID_TRACK_TYPE: number = 0x03;
const ID_CODEC_ID: number = 0x06;
const ID_CODEC_PRIVATE: number = 0x23A2;
const ID_VIDEO: number = 0x60;
const ID_AUDIO: number = 0x61;
const ID_DEFAULT_DURATION: number = 0x3E383;
const ID_FLAG_LACING: number = 0x1C;
const ID_CODEC_DELAY: number = 0x16AA;
const ID_SEEK_PRE_ROLL: number = 0x16BB;

const ID_CLUSTER: number = 0x0F43B675;
const ID_TIMECODE: number = 0x67;
const ID_SIMPLE_BLOCK: number = 0x23;
const ID_BLOCK: number = 0x21;
const ID_GROUP_BLOCK: number = 0x20;

/** Java's (short) cast of an int. */
export function toShort(value: number): number {
  return ((value & 0xFFFF) ^ 0x8000) - 0x8000;
}

/** Java's (byte) cast of an int. */
export function toByte(value: number): number {
  return ((value & 0xFF) ^ 0x80) - 0x80;
}

/** ByteBuffer.putLong(offset, value) without BigInt: two's complement, exact for |value| < 2^53. */
export function setLong(view: DataView, offset: number, value: number,
  littleEndian: boolean): void {
  const high: number = Math.floor(value / 4294967296);
  const low: number = value - high * 4294967296;
  view.setInt32(littleEndian ? offset + 4 : offset, high, littleEndian);
  view.setUint32(littleEndian ? offset : offset + 4, low, littleEndian);
}

/** String.getBytes(UTF_8): a lone surrogate becomes '?', as Java's encoder replaces it. */
export function utf8Encode(value: string): Uint8Array {
  const out: number[] = [];
  let i: number = 0;
  while (i < value.length) {
    const c: number = value.charCodeAt(i);
    i++;
    if (c < 0x80) {
      out.push(c);
    } else if (c < 0x800) {
      out.push(0xC0 | (c >> 6), 0x80 | (c & 0x3F));
    } else if (c < 0xD800 || c > 0xDFFF) {
      out.push(0xE0 | (c >> 12), 0x80 | ((c >> 6) & 0x3F), 0x80 | (c & 0x3F));
    } else {
      const low: number = c <= 0xDBFF && i < value.length ? value.charCodeAt(i) : 0;
      if (low >= 0xDC00 && low <= 0xDFFF) {
        i++;
        const cp: number = 0x10000 + ((c - 0xD800) << 10) + (low - 0xDC00);
        out.push(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F), 0x80 | ((cp >> 6) & 0x3F),
          0x80 | (cp & 0x3F));
      } else {
        out.push(0x3F);
      }
    }
  }
  return new Uint8Array(out);
}

/**
 * new String(bytes, UTF_8). Well-formed input decodes exactly; a malformed sequence becomes one
 * U+FFFD per byte (Java may fold a truncated sequence into one U+FFFD). Only DocType and CodecID go
 * through here, and the Matroska spec makes both ASCII.
 */
export function utf8Decode(bytes: Uint8Array): string {
  let result: string = '';
  let i: number = 0;
  while (i < bytes.length) {
    const lead: number = bytes[i];
    let extra: number = -1; // continuation bytes the lead byte announces; -1: not a lead byte
    let codePoint: number = lead;
    let min: number = 0;
    if (lead < 0x80) {
      extra = 0;
    } else if (lead >= 0xC2 && lead <= 0xDF) {
      extra = 1;
      codePoint = lead & 0x1F;
      min = 0x80;
    } else if (lead >= 0xE0 && lead <= 0xEF) {
      extra = 2;
      codePoint = lead & 0x0F;
      min = 0x800;
    } else if (lead >= 0xF0 && lead <= 0xF4) {
      extra = 3;
      codePoint = lead & 0x07;
      min = 0x10000;
    }
    let length: number = 1;
    while (length <= extra && i + length < bytes.length && (bytes[i + length] & 0xC0) === 0x80) {
      codePoint = codePoint * 64 + (bytes[i + length] & 0x3F);
      length++;
    }
    if (extra >= 0 && length === extra + 1 && codePoint >= min && codePoint <= 0x10FFFF
      && (codePoint < 0xD800 || codePoint > 0xDFFF)) {
      result += String.fromCodePoint(codePoint);
      i += length;
    } else {
      result += String.fromCharCode(0xFFFD);
      i++;
    }
  }
  return result;
}

/** "0x" + Long.toHexString(id): the ids are ints, so a negative one prints as a 64-bit value. */
function elementID(id: number): string {
  return '0x' + (id < 0 ? 'ffffffff' + (id >>> 0).toString(16) : id.toString(16));
}

export enum TrackKind {
  Audio/*2*/, Video/*1*/, Other
}

export class Element {
  type: number = 0;
  offset: number = 0;
  contentSize: number = 0;
  size: number = 0;
}

export class Info {
  timecodeScale: number = 0;
  duration: number = 0;
}

export class WebMTrack {
  trackNumber: number = 0;
  /** protected in the source; WebMWriter (same package) reads it. */
  trackType: number = 0;
  codecId: string | null = null;
  codecPrivate: Uint8Array | null = null;
  bMetadata: Uint8Array | null = null;
  kind: TrackKind | null = null;
  defaultDuration: number = -1;
  codecDelay: number = -1;
  seekPreRoll: number = -1;
}

export class SimpleBlock {
  /** DataReader.getView(dataSize): one view per reader, shared by its blocks as in the source. */
  data: DataReaderView | null = null;
  createdFromBlock: boolean = false;

  trackNumber: number = 0;
  /** A Java short. */
  relativeTimeCode: number = 0;
  absoluteTimeCodeNs: number = 0;
  /** A Java (signed) byte. */
  flags: number = 0;
  dataSize: number = 0;
  readonly ref: Element;

  constructor(ref: Element) {
    this.ref = ref;
  }

  isKeyframe(): boolean {
    return (this.flags & 0x80) === 0x80;
  }
}

export class Segment {
  info: Info | null = null;
  tracks: WebMTrack[] | null = null;
  currentCluster: Element | null = null;
  readonly ref: Element;
  firstClusterInSegment: boolean = true;
  private readonly reader: WebMReader;

  constructor(reader: WebMReader, ref: Element) {
    this.reader = reader;
    this.ref = ref;
  }

  getNextCluster(): Cluster | null {
    const reader: WebMReader = this.reader;
    if (reader.done) {
      return null;
    }
    const segment: Segment = reader.currentSegment();
    const current: Element | null = segment.currentCluster;
    if (this.firstClusterInSegment && current !== null) {
      this.firstClusterInSegment = false;
      return reader.readCluster(current);
    }
    if (current === null) {
      // ensure(null) in the source: a segment without any Cluster
      throw new Error('WebM segment without clusters');
    }
    reader.ensure(current);

    const elem: Element | null = reader.untilElement(segment.ref, ID_CLUSTER);
    if (elem === null) {
      return null;
    }

    segment.currentCluster = elem;

    return reader.readCluster(elem);
  }
}

export class Cluster {
  ref: Element;
  currentSimpleBlock: SimpleBlock | null = null;
  currentBlockGroup: Element | null = null;
  timecode: number = 0;
  private readonly reader: WebMReader;

  constructor(reader: WebMReader, ref: Element) {
    this.reader = reader;
    this.ref = ref;
  }

  insideClusterBounds(): boolean {
    return this.reader.stream.position() >= (this.ref.offset + this.ref.size);
  }

  getNextSimpleBlock(): SimpleBlock | null {
    const reader: WebMReader = this.reader;
    if (this.insideClusterBounds()) {
      return null;
    }

    const blockGroup: Element | null = this.currentBlockGroup;
    const simpleBlock: SimpleBlock | null = this.currentSimpleBlock;
    if (blockGroup !== null) {
      reader.ensure(blockGroup);
      this.currentBlockGroup = null;
      this.currentSimpleBlock = null;
    } else if (simpleBlock !== null) {
      reader.ensure(simpleBlock.ref);
    }

    while (!this.insideClusterBounds()) {
      let elem: Element | null = reader.untilElement(this.ref, ID_SIMPLE_BLOCK, ID_GROUP_BLOCK);
      if (elem === null) {
        return null;
      }

      if (elem.type === ID_GROUP_BLOCK) {
        const group: Element = elem;
        this.currentBlockGroup = group;
        elem = reader.untilElement(group, ID_BLOCK);

        if (elem === null) {
          reader.ensure(group);
          this.currentBlockGroup = null;
          continue;
        }
      }

      const block: SimpleBlock = reader.readSimpleBlock(elem);
      this.currentSimpleBlock = block;
      if (block.trackNumber === reader.tracks[reader.selectedTrack].trackNumber) {
        block.data = reader.stream.getView(block.dataSize);

        const info: Info | null = reader.currentSegment().info;
        if (info === null) {
          throw new Error('WebM segment without Info'); // a NullPointerException in the source
        }

        // calculate the timestamp in nanoseconds
        block.absoluteTimeCodeNs = block.relativeTimeCode + this.timecode;
        block.absoluteTimeCodeNs *= info.timecodeScale;

        return block;
      }

      reader.ensure(elem);
    }
    return null;
  }
}

export class WebMReader {
  // Package-private state of the source: Segment and Cluster (inner classes there) use it.
  readonly stream: DataReader;
  segment: Segment | null = null;
  tracks: WebMTrack[] = [];
  selectedTrack: number = 0;
  done: boolean = false;
  private firstSegment: boolean = false;

  constructor(source: SharpStream) {
    this.stream = new DataReader(source);
  }

  parse(): void {
    const ebml: Element = this.readElement(ID_EMBL);
    if (!this.readEbml(ebml, 1, 2)) {
      throw new Error('Unsupported EBML data (WebM)');
    }
    this.ensure(ebml);

    const elem: Element | null = this.untilElement(null, ID_SEGMENT);
    if (elem === null) {
      throw new StreamError('Fragment element not found');
    }
    const segment: Segment = this.readSegment(elem, 0, true);
    this.segment = segment;
    const tracks: WebMTrack[] | null = segment.tracks;
    if (tracks !== null) { // always: readSegment(..., true) throws without a Tracks element
      this.tracks = tracks;
    }
    this.selectedTrack = -1;
    this.done = false;
    this.firstSegment = true;
  }

  getAvailableTracks(): WebMTrack[] {
    return this.tracks;
  }

  selectTrack(index: number): WebMTrack {
    this.selectedTrack = index;
    return this.tracks[index];
  }

  getNextSegment(): Segment | null {
    if (this.done) {
      return null;
    }

    const current: Segment | null = this.segment;
    if (this.firstSegment && current !== null) {
      this.firstSegment = false;
      return current;
    }

    this.ensure(this.currentSegment().ref);
    // WARNING: track cannot be the same or have different index in new segments
    const elem: Element | null = this.untilElement(null, ID_SEGMENT);
    if (elem === null) {
      this.done = true;
      return null;
    }
    const segment: Segment = this.readSegment(elem, 0, false);
    this.segment = segment;

    return segment;
  }

  /** The `segment` field the source dereferences unchecked (a NullPointerException there). */
  currentSegment(): Segment {
    const segment: Segment | null = this.segment;
    if (segment === null) {
      throw new Error('no WebM segment parsed');
    }
    return segment;
  }

  private readNumber(parent: Element): number {
    const length: number = toInt32(parent.contentSize);
    let value: number = 0;
    for (let n: number = length; n > 0; n--) {
      const read: number = this.stream.read();
      if (read === -1) {
        throw new StreamError('EOF');
      }
      value = value * 256 + read; // (value << 8) | read, on a Java long
    }
    return value;
  }

  private readString(parent: Element): string {
    return utf8Decode(this.readBlob(parent)); // or use "utf-8"
  }

  private readBlob(parent: Element): Uint8Array {
    const length: number = parent.contentSize;
    const buffer: Uint8Array = new Uint8Array(toInt32(length));
    const read: number = this.stream.read1(buffer);
    if (read < length) {
      throw new StreamError('EOF');
    }
    return buffer;
  }

  private readEncodedNumber(): number {
    let value: number = this.stream.read();

    if (value > 0) {
      let size: number = 1;
      let mask: number = 0x80;

      while (size < 9) {
        if ((value & mask) === mask) {
          mask = 0xFF;
          mask >>= size;

          let num: number = value & mask;

          for (let i: number = 1; i < size; i++) {
            value = this.stream.read();
            // `number <<= 8; number |= value;` on a Java long: a -1 (EOF) ORed in sets every bit
            num = value < 0 ? -1 : num * 256 + value;
          }

          return num;
        }

        mask >>= 1;
        size++;
      }
    }

    throw new StreamError('Invalid encoded length');
  }

  /** Both readElement() overloads of the source: `expected` 0 accepts any element. */
  private readElement(expected: number = 0): Element {
    const elem: Element = new Element();
    elem.offset = this.stream.position();
    elem.type = toInt32(this.readEncodedNumber());
    elem.contentSize = this.readEncodedNumber();
    elem.size = elem.contentSize + this.stream.position() - elem.offset;

    if (expected !== 0 && elem.type !== expected) {
      throw new Error('expected ' + elementID(expected) + ' found ' + elementID(elem.type));
    }

    return elem;
  }

  untilElement(ref: Element | null, ...expected: number[]): Element | null {
    while (ref === null ? this.stream.available()
      : (this.stream.position() < (ref.offset + ref.size))) {
      const elem: Element = this.readElement();
      if (expected.length < 1) {
        return elem;
      }
      for (const id of expected) {
        if (elem.type === id) {
          return elem;
        }
      }

      this.ensure(elem);
    }

    return null;
  }

  ensure(ref: Element): void {
    const skip: number = (ref.offset + ref.size) - this.stream.position();

    if (skip === 0) {
      return;
    } else if (skip < 0) {
      throw new StreamError('parser go beyond limits of the Element. type=' + elementID(ref.type)
        + ' offset=' + ref.offset + ' size=' + ref.size + ' position=' + this.stream.position());
    }

    this.stream.skipBytes(skip);
  }

  private readEbml(ref: Element, minReadVersion: number, minDocTypeVersion: number): boolean {
    let elem: Element | null = this.untilElement(ref, ID_EMBL_READ_VERSION);
    if (elem === null) {
      return false;
    }
    if (this.readNumber(elem) > minReadVersion) {
      return false;
    }

    elem = this.untilElement(ref, ID_EMBL_DOC_TYPE);
    if (elem === null) {
      return false;
    }
    if (this.readString(elem) !== 'webm') {
      return false;
    }
    elem = this.untilElement(ref, ID_EMBL_DOC_TYPE_READ_VERSION);

    return elem !== null && this.readNumber(elem) <= minDocTypeVersion;
  }

  private readInfo(ref: Element): Info {
    const info: Info = new Info();

    let elem: Element | null = this.untilElement(ref, ID_TIMECODE_SCALE, ID_DURATION);
    while (elem !== null) {
      switch (elem.type) {
        case ID_TIMECODE_SCALE:
          info.timecodeScale = this.readNumber(elem);
          break;
        case ID_DURATION:
          info.duration = this.readNumber(elem);
          break;
      }
      this.ensure(elem);
      elem = this.untilElement(ref, ID_TIMECODE_SCALE, ID_DURATION);
    }

    if (info.timecodeScale === 0) {
      throw new Error('Element Timecode not found');
    }

    return info;
  }

  private readSegment(ref: Element, trackLacingExpected: number,
    metadataExpected: boolean): Segment {
    const obj: Segment = new Segment(this, ref);
    let elem: Element | null = this.untilElement(ref, ID_INFO, ID_TRACKS, ID_CLUSTER);
    while (elem !== null) {
      if (elem.type === ID_CLUSTER) {
        obj.currentCluster = elem;
        break;
      }
      switch (elem.type) {
        case ID_INFO:
          obj.info = this.readInfo(elem);
          break;
        case ID_TRACKS:
          obj.tracks = this.readTracks(elem, trackLacingExpected);
          break;
      }
      this.ensure(elem);
      elem = this.untilElement(ref, ID_INFO, ID_TRACKS, ID_CLUSTER);
    }

    if (metadataExpected && (obj.info === null || obj.tracks === null)) {
      throw new Error('Cluster element found without Info and/or Tracks element at position '
        + ref.offset);
    }

    return obj;
  }

  private readTracks(ref: Element, lacingExpected: number): WebMTrack[] {
    const entries: WebMTrack[] = [];

    let next: Element | null = this.untilElement(ref, ID_TRACK_ENTRY);
    while (next !== null) {
      const elemTrackEntry: Element = next;
      const entry: WebMTrack = new WebMTrack();
      let drop: boolean = false;
      let elem: Element | null = this.untilElement(elemTrackEntry);
      while (elem !== null) {
        switch (elem.type) {
          case ID_TRACK_NUMBER:
            entry.trackNumber = this.readNumber(elem);
            break;
          case ID_TRACK_TYPE:
            entry.trackType = toInt32(this.readNumber(elem));
            break;
          case ID_CODEC_ID:
            entry.codecId = this.readString(elem);
            break;
          case ID_CODEC_PRIVATE:
            entry.codecPrivate = this.readBlob(elem);
            break;
          case ID_AUDIO:
          case ID_VIDEO:
            entry.bMetadata = this.readBlob(elem);
            break;
          case ID_DEFAULT_DURATION:
            entry.defaultDuration = this.readNumber(elem);
            break;
          case ID_FLAG_LACING:
            drop = this.readNumber(elem) !== lacingExpected;
            break;
          case ID_CODEC_DELAY:
            entry.codecDelay = this.readNumber(elem);
            break;
          case ID_SEEK_PRE_ROLL:
            entry.seekPreRoll = this.readNumber(elem);
            break;
          default:
            break;
        }
        this.ensure(elem);
        elem = this.untilElement(elemTrackEntry);
      }
      if (!drop) {
        entries.push(entry);
      }
      this.ensure(elemTrackEntry);
      next = this.untilElement(ref, ID_TRACK_ENTRY);
    }

    for (const entry of entries) {
      switch (entry.trackType) {
        case 1:
          entry.kind = TrackKind.Video;
          break;
        case 2:
          entry.kind = TrackKind.Audio;
          break;
        default:
          entry.kind = TrackKind.Other;
          break;
      }
    }

    return entries;
  }

  readSimpleBlock(ref: Element): SimpleBlock {
    const obj: SimpleBlock = new SimpleBlock(ref);
    obj.trackNumber = this.readEncodedNumber();
    obj.relativeTimeCode = this.stream.readShort();
    obj.flags = toByte(this.stream.read());
    obj.dataSize = toInt32((ref.offset + ref.size) - this.stream.position());
    obj.createdFromBlock = ref.type === ID_BLOCK;

    // NOTE: lacing is not implemented, and will be mixed with the stream data
    if (obj.dataSize < 0) {
      throw new StreamError('Unexpected SimpleBlock element size, missing ' + (-obj.dataSize)
        + ' bytes');
    }
    return obj;
  }

  readCluster(ref: Element): Cluster {
    const obj: Cluster = new Cluster(this, ref);

    const elem: Element | null = this.untilElement(ref, ID_TIMECODE);
    if (elem === null) {
      throw new Error('Cluster at ' + ref.offset + ' without Timecode element');
    }
    obj.timecode = this.readNumber(elem);

    return obj;
  }
}
