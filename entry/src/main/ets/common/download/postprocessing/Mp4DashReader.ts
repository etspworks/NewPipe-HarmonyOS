/*
 * Port of org.schabi.newpipe.streams.Mp4DashReader (author kapodamy): walks the fragments
 * (moof + mdat) of a DASH fMP4 file for one track. The source's nested classes are top-level
 * exports here, declared before the reader that uses them.
 *
 * Java ints keep their 32-bit wrap (toInt32 / Math.imul); Java longs are plain numbers. Fields the
 * source leaves null until a box shows up are `| null`, and the places the source dereferences
 * them unchecked go through requireNonNull(), throwing where it would throw a
 * NullPointerException.
 */

import { DataReader, DataReaderView, toInt32 } from './DataReader';
import { SharpStream, StreamError } from './SharpStream';

const ATOM_MOOF: number = 0x6D6F6F66;
const ATOM_MFHD: number = 0x6D666864;
const ATOM_TRAF: number = 0x74726166;
const ATOM_TFHD: number = 0x74666864;
const ATOM_TFDT: number = 0x74666474;
const ATOM_TRUN: number = 0x7472756E;
const ATOM_MDIA: number = 0x6D646961;
const ATOM_FTYP: number = 0x66747970;
const ATOM_MOOV: number = 0x6D6F6F76;
const ATOM_MDAT: number = 0x6D646174;
const ATOM_MVHD: number = 0x6D766864;
const ATOM_TRAK: number = 0x7472616B;
const ATOM_MVEX: number = 0x6D766578;
const ATOM_TREX: number = 0x74726578;
const ATOM_TKHD: number = 0x746B6864;
const ATOM_MDHD: number = 0x6D646864;
const ATOM_EDTS: number = 0x65647473;
const ATOM_ELST: number = 0x656C7374;
const ATOM_HDLR: number = 0x68646C72;
const ATOM_MINF: number = 0x6D696E66;
const ATOM_DINF: number = 0x64696E66;
const ATOM_STBL: number = 0x7374626C;
const ATOM_STSD: number = 0x73747364;
const ATOM_VMHD: number = 0x766D6864;
const ATOM_SMHD: number = 0x736D6864;

const BRAND_DASH: number = 0x64617368;
const BRAND_ISO5: number = 0x69736F35;

const HANDLER_VIDE: number = 0x76696465;
const HANDLER_SOUN: number = 0x736F756E;
const HANDLER_SUBT: number = 0x73756274;

export enum TrackKind {
  Audio, Video, Subtitles, Other
}

/** Mp4DashReader.hasFlag() in the source. */
export function hasFlag(flags: number, mask: number): boolean {
  return (flags & mask) === mask;
}

/** A value the source dereferences without a check: missing, it throws as Java would. */
export function requireNonNull<T>(value: T | null, what: string): T {
  if (value === null) {
    throw new Error('NullPointerException: no ' + what);
  }
  return value;
}

export class Box {
  type: number = 0;
  offset: number = 0;
  size: number = 0;
}

export class Tfhd {
  bFlags: number = 0;
  trackId: number = 0;
  defaultSampleDuration: number = 0;
  defaultSampleSize: number = 0;
  defaultSampleFlags: number = 0;
}

export class TrunEntry {
  sampleDuration: number = 0;
  sampleSize: number = 0;
  sampleFlags: number = 0;
  sampleCompositionTimeOffset: number = 0;

  hasCompositionTimeOffset: boolean = false;
  isKeyframe: boolean = false;
}

export class Trun {
  chunkDuration: number = 0;
  chunkSize: number = 0;

  bFlags: number = 0;
  bFirstSampleFlags: number = 0;
  dataOffset: number = 0;

  entryCount: number = 0;
  bEntries: Uint8Array = new Uint8Array(0);
  entriesRowSize: number = 0;

  getEntry(i: number): TrunEntry {
    // ByteBuffer.wrap(bEntries, i * entriesRowSize, entriesRowSize)
    const buffer: DataView = new DataView(this.bEntries.buffer,
      this.bEntries.byteOffset + i * this.entriesRowSize, this.entriesRowSize);
    let position: number = 0;
    const entry: TrunEntry = new TrunEntry();

    if (hasFlag(this.bFlags, 0x0100)) {
      entry.sampleDuration = buffer.getInt32(position);
      position += 4;
    }
    if (hasFlag(this.bFlags, 0x0200)) {
      entry.sampleSize = buffer.getInt32(position);
      position += 4;
    }
    if (hasFlag(this.bFlags, 0x0400)) {
      entry.sampleFlags = buffer.getInt32(position);
      position += 4;
    }
    if (hasFlag(this.bFlags, 0x0800)) {
      entry.sampleCompositionTimeOffset = buffer.getInt32(position);
    }

    entry.hasCompositionTimeOffset = hasFlag(this.bFlags, 0x0800);
    entry.isKeyframe = !hasFlag(entry.sampleFlags, 0x10000);

    return entry;
  }

  getAbsoluteEntry(i: number, header: Tfhd): TrunEntry {
    const entry: TrunEntry = this.getEntry(i);

    if (!hasFlag(this.bFlags, 0x0100) && hasFlag(header.bFlags, 0x20)) {
      entry.sampleFlags = header.defaultSampleFlags;
    }

    if (!hasFlag(this.bFlags, 0x0200) && hasFlag(header.bFlags, 0x10)) {
      entry.sampleSize = header.defaultSampleSize;
    }

    if (!hasFlag(this.bFlags, 0x0100) && hasFlag(header.bFlags, 0x08)) {
      entry.sampleDuration = header.defaultSampleDuration;
    }

    if (i === 0 && hasFlag(this.bFlags, 0x0004)) {
      entry.sampleFlags = this.bFirstSampleFlags;
    }

    return entry;
  }
}

export class Traf {
  tfhd: Tfhd = new Tfhd();
  tfdt: number = 0;
  trun: Trun = new Trun();
}

export class Moof {
  mfhdSequenceNumber: number = 0;
  traf: Traf | null = null;
}

export class Tkhd {
  trackId: number = 0;
  duration: number = 0;
  bVolume: number = 0;
  bWidth: number = 0;
  bHeight: number = 0;
  matrix: Uint8Array = new Uint8Array(0);
  bLayer: number = 0;
  bAlternateGroup: number = 0;
}

export class Elst {
  mediaTime: number = 0;
  bMediaRate: number = 0;
}

export class Hdlr {
  type: number = 0;
  subType: number = 0;
  bReserved: Uint8Array = new Uint8Array(0);
}

export class Minf {
  dinf: Uint8Array | null = null;
  stblStsd: Uint8Array | null = null;
  mhd: Uint8Array | null = null;
}

export class Mdia {
  mdhdTimeScale: number = 0;
  mdhd: Uint8Array | null = null;
  hdlr: Hdlr | null = null;
  minf: Minf | null = null;
}

export class Trak {
  tkhd: Tkhd = new Tkhd();
  edstElst: Elst | null = null;
  mdia: Mdia | null = null;
}

export class Mvhd {
  timeScale: number = 0;
  nextTrackId: number = 0;
}

export class Trex {
  trackId: number = 0;
  defaultSampleDescriptionIndex: number = 0;
  defaultSampleDuration: number = 0;
  defaultSampleSize: number = 0;
  defaultSampleFlags: number = 0;
}

export class Moov {
  mvhd: Mvhd = new Mvhd();
  trak: Trak[] = [];
  mvexTrex: Trex[] | null = null;
}

export class Mp4Track {
  kind: TrackKind = TrackKind.Other;
  trak: Trak = new Trak();
  trex: Trex | null = null;
}

export class Mp4DashSample {
  info: TrunEntry = new TrunEntry();
  data: Uint8Array = new Uint8Array(0);
}

export class Mp4DashChunk {
  data: DataReaderView | null = null;
  moof: Moof = new Moof();
  private i: number = 0;

  getNextSampleInfo(): TrunEntry | null {
    const traf: Traf = requireNonNull<Traf>(this.moof.traf, 'traf');
    if (this.i >= traf.trun.entryCount) {
      return null;
    }
    const index: number = this.i;
    this.i++;
    return traf.trun.getAbsoluteEntry(index, traf.tfhd);
  }

  getNextSample(): Mp4DashSample | null {
    const data: DataReaderView | null = this.data;
    if (data === null) {
      throw new Error('This chunk has info only');
    }
    const traf: Traf = requireNonNull<Traf>(this.moof.traf, 'traf');
    if (this.i >= traf.trun.entryCount) {
      return null;
    }

    const sample: Mp4DashSample = new Mp4DashSample();
    const index: number = this.i;
    this.i++;
    sample.info = traf.trun.getAbsoluteEntry(index, traf.tfhd);
    sample.data = new Uint8Array(sample.info.sampleSize);

    if (data.read1(sample.data) !== sample.info.sampleSize) {
      throw new StreamError('EOF reached while reading a sample');
    }

    return sample;
  }
}

export class Mp4DashReader {
  private readonly stream: DataReader;

  private tracks: Mp4Track[] | null = null;
  private brands: Int32Array | null = null;

  private box: Box | null = null;
  private moof: Moof | null = null;

  private chunkZero: boolean = false;

  private selectedTrack: number = -1;
  private backupBox: Box | null = null;

  constructor(source: SharpStream) {
    this.stream = new DataReader(source);
  }

  parse(): void {
    if (this.selectedTrack > -1) {
      return;
    }

    let box: Box = this.readBox(ATOM_FTYP);
    this.box = box;
    const brands: Int32Array = this.parseFtyp(box);
    this.brands = brands;
    if (brands[0] !== BRAND_DASH && brands[0] !== BRAND_ISO5) { // iso5: ¿why not?
      throw new Error("Not a MPEG-4 DASH container, major brand is not 'dash' or 'iso5' is "
        + this.boxName(brands[0]));
    }

    let moov: Moov | null = null;

    while (box.type !== ATOM_MOOF) {
      this.ensure(box);
      box = this.readBox();
      this.box = box;

      if (box.type === ATOM_MOOV) {
        moov = this.parseMoov(box);
      }
      // sidx and mfra are skipped, as in the source
    }

    if (moov === null) {
      throw new StreamError("The provided Mp4 doesn't have the 'moov' box");
    }

    const tracks: Mp4Track[] = [];
    this.tracks = tracks;

    for (let i: number = 0; i < moov.trak.length; i++) {
      const track: Mp4Track = new Mp4Track();
      tracks.push(track);
      track.trak = moov.trak[i];

      const mvexTrex: Trex[] | null = moov.mvexTrex;
      if (mvexTrex !== null) {
        for (const trex of mvexTrex) {
          if (track.trak.tkhd.trackId === trex.trackId) {
            track.trex = trex;
          }
        }
      }

      const mdia: Mdia = requireNonNull<Mdia>(moov.trak[i].mdia, 'mdia');
      switch (requireNonNull<Hdlr>(mdia.hdlr, 'hdlr').subType) {
        case HANDLER_VIDE:
          track.kind = TrackKind.Video;
          break;
        case HANDLER_SOUN:
          track.kind = TrackKind.Audio;
          break;
        case HANDLER_SUBT:
          track.kind = TrackKind.Subtitles;
          break;
        default:
          track.kind = TrackKind.Other;
          break;
      }
    }

    this.backupBox = box;
  }

  selectTrack(index: number): Mp4Track {
    this.selectedTrack = index;
    return this.trackAt(index);
  }

  getBrands(): Int32Array {
    const brands: Int32Array | null = this.brands;
    if (brands === null) {
      throw new Error('Not parsed');
    }
    return brands;
  }

  rewind(): void {
    if (!this.stream.canRewind()) {
      throw new StreamError("The provided stream doesn't allow seek");
    }
    if (this.box === null) {
      return;
    }

    const backupBox: Box | null = this.backupBox;
    this.box = backupBox;
    this.chunkZero = false;

    this.stream.rewind();
    this.stream.skipBytes(requireNonNull<Box>(backupBox, 'backup box').offset
      + (DataReader.INTEGER_SIZE * 2));
  }

  getAvailableTracks(): Mp4Track[] | null {
    return this.tracks;
  }

  getNextChunk(infoOnly: boolean): Mp4DashChunk | null {
    const track: Mp4Track = this.trackAt(this.selectedTrack);

    while (this.stream.available()) {
      let box: Box = requireNonNull<Box>(this.box, 'box');

      if (this.chunkZero) {
        this.ensure(box);
        if (!this.stream.available()) {
          break;
        }
        box = this.readBox();
        this.box = box;
      } else {
        this.chunkZero = true;
      }

      if (box.type === ATOM_MOOF) {
        if (this.moof !== null) {
          throw new StreamError('moof found without mdat');
        }

        const moof: Moof = this.parseMoof(box, track.trak.tkhd.trackId);
        this.moof = moof;

        const traf: Traf | null = moof.traf;
        if (traf !== null) {

          if (hasFlag(traf.trun.bFlags, 0x0001)) {
            traf.trun.dataOffset = toInt32(traf.trun.dataOffset - (box.size + 8));
            if (traf.trun.dataOffset < 0) {
              throw new StreamError('trun box has wrong data offset, '
                + 'points outside of concurrent mdat box');
            }
          }

          if (traf.trun.chunkSize < 1) {
            if (hasFlag(traf.tfhd.bFlags, 0x10)) {
              traf.trun.chunkSize = Math.imul(traf.tfhd.defaultSampleSize, traf.trun.entryCount);
            } else {
              traf.trun.chunkSize = toInt32(box.size - 8);
            }
          }
          if (!hasFlag(traf.trun.bFlags, 0x900) && traf.trun.chunkDuration === 0) {
            if (hasFlag(traf.tfhd.bFlags, 0x20)) {
              traf.trun.chunkDuration =
                Math.imul(traf.tfhd.defaultSampleDuration, traf.trun.entryCount);
            }
          }
        }
      } else if (box.type === ATOM_MDAT) {
        const moof: Moof | null = this.moof;
        if (moof === null) {
          throw new StreamError('mdat found without moof');
        }

        const traf: Traf | null = moof.traf;
        if (traf === null) {
          this.moof = null;
          continue; // find another chunk
        }

        const chunk: Mp4DashChunk = new Mp4DashChunk();
        chunk.moof = moof;
        if (!infoOnly) {
          chunk.data = this.stream.getView(traf.trun.chunkSize);
        }

        this.moof = null;

        this.stream.skipBytes(traf.trun.dataOffset);
        return chunk;
      }
    }

    return null;
  }

  /** tracks[index], throwing where the source's array access would. */
  private trackAt(index: number): Mp4Track {
    const tracks: Mp4Track[] = requireNonNull<Mp4Track[]>(this.tracks, 'tracks (not parsed)');
    const track: Mp4Track | undefined = tracks[index];
    if (track === undefined) {
      throw new Error('track index out of bounds: ' + index);
    }
    return track;
  }

  private boxName(type: number): string {
    // the source decodes the 4 bytes as UTF-8; box types are ASCII
    return String.fromCharCode((type >>> 24) & 0xFF, (type >>> 16) & 0xFF, (type >>> 8) & 0xFF,
      type & 0xFF);
  }

  /** readBox() and readBox(int expected) of the source. */
  private readBox(expected?: number): Box {
    const b: Box = new Box();
    b.offset = this.stream.position();
    b.size = this.stream.readUnsignedInt();
    b.type = this.stream.readInt();

    if (b.size === 1) {
      b.size = this.stream.readLong();
    }

    if (expected !== undefined && b.type !== expected) {
      throw new Error('expected ' + this.boxName(expected) + ' found ' + this.boxName(b.type));
    }
    return b;
  }

  private readFullBox(ref: Box): Uint8Array {
    // full box reading is limited to 2 GiB, and should be enough
    const size: number = toInt32(ref.size);

    const buffer: Uint8Array = new Uint8Array(size);
    const header: DataView = new DataView(buffer.buffer);
    header.setInt32(0, size);
    header.setInt32(4, ref.type);

    const read: number = size - 8;

    if (this.stream.readInto(buffer, 8, read) !== read) {
      throw new StreamError('EOF reached in box: type=' + this.boxName(ref.type)
        + ' offset=' + ref.offset + ' size=' + ref.size);
    }

    return buffer;
  }

  private ensure(ref: Box): void {
    const skip: number = ref.offset + ref.size - this.stream.position();

    if (skip === 0) {
      return;
    } else if (skip < 0) {
      throw new StreamError('parser go beyond limits of the box. type=' + this.boxName(ref.type)
        + ' offset=' + ref.offset + ' size=' + ref.size + ' position=' + this.stream.position());
    }

    this.stream.skipBytes(toInt32(skip));
  }

  private untilBox(ref: Box, ...expected: number[]): Box | null {
    while (this.stream.position() < (ref.offset + ref.size)) {
      const b: Box = this.readBox();
      for (const type of expected) {
        if (b.type === type) {
          return b;
        }
      }
      this.ensure(b);
    }

    return null;
  }

  private untilAnyBox(ref: Box): Box | null {
    if (this.stream.position() >= (ref.offset + ref.size)) {
      return null;
    }

    return this.readBox();
  }

  private parseMoof(ref: Box, trackId: number): Moof {
    const obj: Moof = new Moof();

    const mfhd: Box = this.readBox(ATOM_MFHD);
    obj.mfhdSequenceNumber = this.parseMfhd();
    this.ensure(mfhd);

    let b: Box | null = this.untilBox(ref, ATOM_TRAF);
    while (b !== null) {
      obj.traf = this.parseTraf(b, trackId);
      this.ensure(b);

      if (obj.traf !== null) {
        return obj;
      }
      b = this.untilBox(ref, ATOM_TRAF);
    }

    return obj;
  }

  private parseMfhd(): number {
    // version
    // flags
    this.stream.skipBytes(4);

    return this.stream.readInt();
  }

  private parseTraf(ref: Box, trackId: number): Traf | null {
    const traf: Traf = new Traf();

    let b: Box = this.readBox(ATOM_TFHD);
    const tfhd: Tfhd | null = this.parseTfhd(trackId);
    this.ensure(b);

    if (tfhd === null) {
      return null;
    }
    traf.tfhd = tfhd;

    b = requireNonNull<Box>(this.untilBox(ref, ATOM_TRUN, ATOM_TFDT), 'trun box in traf');

    if (b.type === ATOM_TFDT) {
      traf.tfdt = this.parseTfdt();
      this.ensure(b);
      b = this.readBox(ATOM_TRUN);
    }

    traf.trun = this.parseTrun();
    this.ensure(b);

    return traf;
  }

  private parseTfhd(trackId: number): Tfhd | null {
    const obj: Tfhd = new Tfhd();

    obj.bFlags = this.stream.readInt();
    obj.trackId = this.stream.readInt();

    if (trackId !== -1 && obj.trackId !== trackId) {
      return null;
    }

    if (hasFlag(obj.bFlags, 0x01)) {
      this.stream.skipBytes(8);
    }
    if (hasFlag(obj.bFlags, 0x02)) {
      this.stream.skipBytes(4);
    }
    if (hasFlag(obj.bFlags, 0x08)) {
      obj.defaultSampleDuration = this.stream.readInt();
    }
    if (hasFlag(obj.bFlags, 0x10)) {
      obj.defaultSampleSize = this.stream.readInt();
    }
    if (hasFlag(obj.bFlags, 0x20)) {
      obj.defaultSampleFlags = this.stream.readInt();
    }

    return obj;
  }

  private parseTfdt(): number {
    const version: number = this.stream.read();
    this.stream.skipBytes(3); // flags
    return version === 0 ? this.stream.readUnsignedInt() : this.stream.readLong();
  }

  private parseTrun(): Trun {
    const obj: Trun = new Trun();
    obj.bFlags = this.stream.readInt();
    obj.entryCount = this.stream.readInt(); // unsigned int

    obj.entriesRowSize = 0;
    if (hasFlag(obj.bFlags, 0x0100)) {
      obj.entriesRowSize += 4;
    }
    if (hasFlag(obj.bFlags, 0x0200)) {
      obj.entriesRowSize += 4;
    }
    if (hasFlag(obj.bFlags, 0x0400)) {
      obj.entriesRowSize += 4;
    }
    if (hasFlag(obj.bFlags, 0x0800)) {
      obj.entriesRowSize += 4;
    }
    obj.bEntries = new Uint8Array(Math.imul(obj.entriesRowSize, obj.entryCount));

    if (hasFlag(obj.bFlags, 0x0001)) {
      obj.dataOffset = this.stream.readInt();
    }
    if (hasFlag(obj.bFlags, 0x0004)) {
      obj.bFirstSampleFlags = this.stream.readInt();
    }

    this.stream.read1(obj.bEntries);

    for (let i: number = 0; i < obj.entryCount; i++) {
      const entry: TrunEntry = obj.getEntry(i);
      if (hasFlag(obj.bFlags, 0x0100)) {
        obj.chunkDuration = toInt32(obj.chunkDuration + entry.sampleDuration);
      }
      if (hasFlag(obj.bFlags, 0x0200)) {
        obj.chunkSize = toInt32(obj.chunkSize + entry.sampleSize);
      }
      if (hasFlag(obj.bFlags, 0x0800)) {
        if (!hasFlag(obj.bFlags, 0x0100)) {
          obj.chunkDuration = toInt32(obj.chunkDuration + entry.sampleCompositionTimeOffset);
        }
      }
    }

    return obj;
  }

  private parseFtyp(ref: Box): Int32Array {
    let i: number = 0;
    const list: Int32Array = new Int32Array(
      toInt32(Math.trunc((ref.offset + ref.size - this.stream.position() - 4) / 4)));

    list[i] = this.stream.readInt(); // major brand
    i++;

    this.stream.skipBytes(4); // minor version

    for (; i < list.length; i++) {
      list[i] = this.stream.readInt(); // compatible brands
    }

    return list;
  }

  private parseMvhd(): Mvhd {
    const version: number = this.stream.read();
    this.stream.skipBytes(3); // flags

    // creation entries_time
    // modification entries_time
    this.stream.skipBytes(2 * (version === 0 ? 4 : 8));

    const obj: Mvhd = new Mvhd();
    obj.timeScale = this.stream.readUnsignedInt();

    // chunkDuration
    this.stream.skipBytes(version === 0 ? 4 : 8);

    // rate
    // volume
    // reserved
    // matrix array
    // predefined
    this.stream.skipBytes(76);

    obj.nextTrackId = this.stream.readUnsignedInt();

    return obj;
  }

  private parseTkhd(): Tkhd {
    const version: number = this.stream.read();

    const obj: Tkhd = new Tkhd();

    // flags
    // creation entries_time
    // modification entries_time
    this.stream.skipBytes(3 + (2 * (version === 0 ? 4 : 8)));

    obj.trackId = this.stream.readInt();

    this.stream.skipBytes(4); // reserved

    obj.duration = version === 0 ? this.stream.readUnsignedInt() : this.stream.readLong();

    this.stream.skipBytes(2 * 4); // reserved

    obj.bLayer = this.stream.readShort();
    obj.bAlternateGroup = this.stream.readShort();
    obj.bVolume = this.stream.readShort();

    this.stream.skipBytes(2); // reserved

    obj.matrix = new Uint8Array(9 * 4);
    this.stream.read1(obj.matrix);

    obj.bWidth = this.stream.readInt();
    obj.bHeight = this.stream.readInt();

    return obj;
  }

  private parseTrak(ref: Box): Trak {
    const trak: Trak = new Trak();

    const tkhd: Box = this.readBox(ATOM_TKHD);
    trak.tkhd = this.parseTkhd();
    this.ensure(tkhd);

    let b: Box | null = this.untilBox(ref, ATOM_MDIA, ATOM_EDTS);
    while (b !== null) {
      if (b.type === ATOM_MDIA) {
        trak.mdia = this.parseMdia(b);
      } else if (b.type === ATOM_EDTS) {
        trak.edstElst = this.parseEdts(b);
      }

      this.ensure(b);
      b = this.untilBox(ref, ATOM_MDIA, ATOM_EDTS);
    }

    return trak;
  }

  private parseMdia(ref: Box): Mdia {
    const obj: Mdia = new Mdia();

    let b: Box | null = this.untilBox(ref, ATOM_MDHD, ATOM_HDLR, ATOM_MINF);
    while (b !== null) {
      if (b.type === ATOM_MDHD) {
        const mdhd: Uint8Array = this.readFullBox(b);
        obj.mdhd = mdhd;

        // read time scale
        const buffer: DataView = new DataView(mdhd.buffer, mdhd.byteOffset, mdhd.byteLength);
        const version: number = buffer.getInt8(8);
        obj.mdhdTimeScale = buffer.getInt32(12 + ((version === 0 ? 4 : 8) * 2));
      } else if (b.type === ATOM_HDLR) {
        obj.hdlr = this.parseHdlr(b);
      } else if (b.type === ATOM_MINF) {
        obj.minf = this.parseMinf(b);
      }
      this.ensure(b);
      b = this.untilBox(ref, ATOM_MDHD, ATOM_HDLR, ATOM_MINF);
    }

    return obj;
  }

  private parseHdlr(ref: Box): Hdlr {
    // version
    // flags
    this.stream.skipBytes(4);

    const obj: Hdlr = new Hdlr();
    obj.bReserved = new Uint8Array(12);

    obj.type = this.stream.readInt();
    obj.subType = this.stream.readInt();
    this.stream.read1(obj.bReserved);

    // component name (is a ansi/ascii string)
    this.stream.skipBytes((ref.offset + ref.size) - this.stream.position());

    return obj;
  }

  private parseMoov(ref: Box): Moov {
    const mvhd: Box = this.readBox(ATOM_MVHD);
    const moov: Moov = new Moov();
    moov.mvhd = this.parseMvhd();
    this.ensure(mvhd);

    // The source sizes an ArrayList with (int) nextTrackId, and that throws when the cast comes
    // out negative (a next_track_ID of 2^31 or more, like the "unknown" 0xFFFFFFFF).
    const capacity: number = toInt32(moov.mvhd.nextTrackId);
    if (capacity < 0) {
      throw new Error('Illegal Capacity: ' + capacity);
    }

    const tmp: Trak[] = [];
    let b: Box | null = this.untilBox(ref, ATOM_TRAK, ATOM_MVEX);
    while (b !== null) {
      if (b.type === ATOM_TRAK) {
        tmp.push(this.parseTrak(b));
      } else if (b.type === ATOM_MVEX) {
        moov.mvexTrex = this.parseMvex(b);
      }

      this.ensure(b);
      b = this.untilBox(ref, ATOM_TRAK, ATOM_MVEX);
    }

    moov.trak = tmp;

    return moov;
  }

  private parseMvex(ref: Box): Trex[] {
    const tmp: Trex[] = [];

    let b: Box | null = this.untilBox(ref, ATOM_TREX);
    while (b !== null) {
      tmp.push(this.parseTrex());
      this.ensure(b);
      b = this.untilBox(ref, ATOM_TREX);
    }

    return tmp;
  }

  private parseTrex(): Trex {
    // version
    // flags
    this.stream.skipBytes(4);

    const obj: Trex = new Trex();
    obj.trackId = this.stream.readInt();
    obj.defaultSampleDescriptionIndex = this.stream.readInt();
    obj.defaultSampleDuration = this.stream.readInt();
    obj.defaultSampleSize = this.stream.readInt();
    obj.defaultSampleFlags = this.stream.readInt();

    return obj;
  }

  private parseEdts(ref: Box): Elst | null {
    const b: Box | null = this.untilBox(ref, ATOM_ELST);
    if (b === null) {
      return null;
    }

    const obj: Elst = new Elst();

    const v1: boolean = this.stream.read() === 1;
    this.stream.skipBytes(3); // flags

    const entryCount: number = this.stream.readInt();
    if (entryCount < 1) {
      obj.bMediaRate = 0x00010000; // default media rate (1.0)
      return obj;
    }

    if (v1) {
      this.stream.skipBytes(DataReader.LONG_SIZE); // segment duration
      obj.mediaTime = this.stream.readLong();
      // ignore all remain entries
      this.stream.skipBytes(Math.imul(entryCount - 1, DataReader.LONG_SIZE * 2));
    } else {
      this.stream.skipBytes(DataReader.INTEGER_SIZE); // segment duration
      obj.mediaTime = this.stream.readInt();
    }

    obj.bMediaRate = this.stream.readInt();

    return obj;
  }

  private parseMinf(ref: Box): Minf {
    const obj: Minf = new Minf();

    let b: Box | null = this.untilAnyBox(ref);
    while (b !== null) {
      if (b.type === ATOM_DINF) {
        obj.dinf = this.readFullBox(b);
      } else if (b.type === ATOM_STBL) {
        obj.stblStsd = this.parseStbl(b);
      } else if (b.type === ATOM_VMHD || b.type === ATOM_SMHD) {
        obj.mhd = this.readFullBox(b);
      }
      this.ensure(b);
      b = this.untilAnyBox(ref);
    }

    return obj;
  }

  /**
   * This only reads the "stsd" box inside.
   *
   * @param ref stbl box
   * @return stsd box inside
   */
  private parseStbl(ref: Box): Uint8Array {
    const b: Box | null = this.untilBox(ref, ATOM_STSD);

    if (b === null) {
      return new Uint8Array(0); // this never should happens (missing codec startup data)
    }

    return this.readFullBox(b);
  }
}
