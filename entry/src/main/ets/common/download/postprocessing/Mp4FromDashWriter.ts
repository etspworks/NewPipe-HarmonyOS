/*
 * Port of org.schabi.newpipe.streams.Mp4FromDashWriter (author kapodamy): muxes the selected
 * track of each DASH fMP4 source into one regular (non-fragmented) MP4.
 *
 * Java int arrays are Int32Array (same 32-bit wrap on store), (int) casts of longs go through
 * toInt32(), and longs are plain numbers written as two 32-bit halves, never through bitwise
 * operators.
 */

import { toInt32 } from './DataReader';
import {
  Elst, Hdlr, Mdia, Minf, Mp4DashChunk, Mp4DashReader, Mp4DashSample, Mp4Track, requireNonNull,
  TrackKind, Traf, TrunEntry
} from './Mp4DashReader';
import { SharpStream, StreamError } from './SharpStream';

const EPOCH_OFFSET: number = 2082844800;
const DEFAULT_TIMESCALE: number = 1000;
const SAMPLES_PER_CHUNK_INIT: number = 2;
// ffmpeg uses 2, basic uses 1 (with 60fps uses 21 or 22). NewPipe will use 6
const SAMPLES_PER_CHUNK: number = 6;
// near 3.999 GiB
const THRESHOLD_FOR_CO64: number = 0xFFFEFFFF;
// 2.2 MiB enough for: 1080p 60fps 00h35m00s
const THRESHOLD_MOOV_LENGTH: number = (256 * 1024) + (2048 * 1024);

/** The part of java.nio.ByteBuffer the writer uses: big-endian relative puts over a byte array. */
class ByteBuffer {
  private readonly bytes: Uint8Array;
  private readonly view: DataView;
  private cursor: number = 0;

  constructor(bytes: Uint8Array) {
    this.bytes = bytes;
    this.view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  }

  static allocate(capacity: number): ByteBuffer {
    return new ByteBuffer(new Uint8Array(capacity));
  }

  static wrap(bytes: Uint8Array): ByteBuffer {
    return new ByteBuffer(bytes);
  }

  putShort(value: number): ByteBuffer {
    this.view.setInt16(this.cursor, value);
    this.cursor += 2;
    return this;
  }

  putInt(value: number): ByteBuffer {
    this.view.setInt32(this.cursor, value);
    this.cursor += 4;
    return this;
  }

  /** Two's complement, exact while |value| < 2^53. */
  putLong(value: number): ByteBuffer {
    const high: number = Math.floor(value / 4294967296);
    this.view.setInt32(this.cursor, high);
    this.view.setUint32(this.cursor + 4, value - high * 4294967296);
    this.cursor += 8;
    return this;
  }

  put(src: Uint8Array): ByteBuffer {
    this.bytes.set(src, this.cursor);
    this.cursor += src.length;
    return this;
  }

  position(): number {
    return this.cursor;
  }

  /** position(int) of the source. */
  setPosition(newPosition: number): ByteBuffer {
    if (newPosition < 0 || newPosition > this.bytes.length) {
      throw new Error('IllegalArgumentException: bad position ' + newPosition);
    }
    this.cursor = newPosition;
    return this;
  }

  array(): Uint8Array {
    return this.bytes;
  }

  capacity(): number {
    return this.bytes.length;
  }
}

export class TablesInfo {
  stts: number = 0;
  stsc: number = 0;
  stscBEntries: Int32Array | null = null;
  ctts: number = 0;
  stsz: number = 0;
  stszDefault: number = 0;
  stss: number = 0;
  stco: number = 0;
  sbgp: number = 0;
}

export class Mp4FromDashWriter {
  private readonly time: number = Math.floor(Date.now() / 1000) + EPOCH_OFFSET;

  private auxBuffer: ByteBuffer | null = null;
  private outStream: SharpStream | null = null;

  private lastWriteOffset: number = -1;
  private writeOffset: number = 0;

  private moovSimulation: boolean = true;

  private done: boolean = false;
  private parsed: boolean = false;

  private tracks: Mp4Track[] | null = null;
  private sourceTracks: SharpStream[] = [];

  private readers: Array<Mp4DashReader | null> = [];
  private readersChunks: Array<Mp4DashChunk | null> = [];

  private overrideMainBrand: number = 0x00;

  private readonly compatibleBrands: number[] = [];

  constructor(sources: SharpStream[]) {
    for (const src of sources) {
      if (!src.canRewind() && !src.canRead()) {
        throw new StreamError('All sources must be readable and allow rewind');
      }
    }

    this.sourceTracks = sources;
    for (let i: number = 0; i < sources.length; i++) {
      this.readers.push(null);
      this.readersChunks.push(null);
    }

    this.compatibleBrands.push(0x6D703431); // mp41
    this.compatibleBrands.push(0x69736F6D); // isom
    this.compatibleBrands.push(0x69736F32); // iso2
  }

  getTracksFromSource(sourceIndex: number): Mp4Track[] | null {
    if (!this.parsed) {
      throw new Error('All sources must be parsed first');
    }

    return this.reader(sourceIndex).getAvailableTracks();
  }

  parseSources(): void {
    if (this.done) {
      throw new Error('already done');
    }
    if (this.parsed) {
      throw new Error('already parsed');
    }

    try {
      for (let i: number = 0; i < this.readers.length; i++) {
        const reader: Mp4DashReader = new Mp4DashReader(this.sourceTracks[i]);
        this.readers[i] = reader;
        reader.parse();
      }
    } finally {
      this.parsed = true;
    }
  }

  selectTracks(...trackIndex: number[]): void {
    if (this.done) {
      throw new StreamError('already done');
    }
    if (this.tracks !== null) {
      throw new StreamError('tracks already selected');
    }

    try {
      const tracks: Mp4Track[] = [];
      this.tracks = tracks;
      for (let i: number = 0; i < this.readers.length; i++) {
        tracks.push(this.reader(i).selectTrack(trackIndex[i]));
      }
    } finally {
      this.parsed = true;
    }
  }

  setMainBrand(brand: number): void {
    this.overrideMainBrand = brand;
  }

  isDone(): boolean {
    return this.done;
  }

  isParsed(): boolean {
    return this.parsed;
  }

  close(): void {
    this.done = true;
    this.parsed = true;

    for (const src of this.sourceTracks) {
      src.close();
    }

    this.tracks = null;
    this.sourceTracks = [];

    this.readers = [];
    this.readersChunks = [];

    this.auxBuffer = null;
    this.outStream = null;
  }

  build(output: SharpStream): void {
    if (this.done) {
      throw new Error('already done');
    }
    if (!output.canWrite()) {
      throw new StreamError('the provided output is not writable');
    }

    //
    // WARNING: the muxer requires at least 8 samples of every track
    //          not allowed for very short tracks (less than 0.5 seconds)
    //
    this.outStream = output;
    const readerCount: number = this.readers.length;
    let read: number = 8; // mdat box header size
    let totalSampleSize: number = 0;
    const sampleExtra: Int32Array = new Int32Array(readerCount);
    const defaultMediaTime: Int32Array = new Int32Array(readerCount);
    const defaultSampleDuration: Int32Array = new Int32Array(readerCount);
    const sampleCount: Int32Array = new Int32Array(readerCount);

    const tracks: Mp4Track[] = this.requireTracks();
    const tablesInfo: TablesInfo[] = [];
    for (let i: number = 0; i < tracks.length; i++) {
      tablesInfo.push(new TablesInfo());
    }

    // near 1 second of audio data per chunk, avoid split the audio stream in large chunks
    const singleSampleBuffer: number = tracks.length === 1 && tracks[0].kind === TrackKind.Audio
      ? Math.trunc(requireNonNull<Mdia>(tracks[0].trak.mdia, 'mdia').mdhdTimeScale / 1000)
      : -1;

    for (let i: number = 0; i < readerCount; i++) {
      let samplesSize: number = 0;
      let sampleSizeChanges: number = 0;
      let compositionOffsetLast: number = -1;

      let chunk: Mp4DashChunk | null = this.reader(i).getNextChunk(true);
      while (chunk !== null) {
        const traf: Traf = requireNonNull<Traf>(chunk.moof.traf, 'traf');

        if (defaultMediaTime[i] < 1 && traf.tfhd.defaultSampleDuration > 0) {
          defaultMediaTime[i] = traf.tfhd.defaultSampleDuration;
        }

        read += traf.trun.chunkSize;
        sampleExtra[i] += traf.trun.chunkDuration; // calculate track duration

        let info: TrunEntry | null = chunk.getNextSampleInfo();
        while (info !== null) {
          if (info.isKeyframe) {
            tablesInfo[i].stss++;
          }

          if (info.sampleDuration > defaultSampleDuration[i]) {
            defaultSampleDuration[i] = info.sampleDuration;
          }

          tablesInfo[i].stsz++;
          if (samplesSize !== info.sampleSize) {
            samplesSize = info.sampleSize;
            sampleSizeChanges++;
          }

          if (info.hasCompositionTimeOffset) {
            if (info.sampleCompositionTimeOffset !== compositionOffsetLast) {
              tablesInfo[i].ctts++;
              compositionOffsetLast = info.sampleCompositionTimeOffset;
            }
          }

          totalSampleSize += info.sampleSize;

          info = chunk.getNextSampleInfo();
        }

        chunk = this.reader(i).getNextChunk(true);
      }

      if (defaultMediaTime[i] < 1) {
        defaultMediaTime[i] = defaultSampleDuration[i];
      }

      this.reader(i).rewind();

      if (singleSampleBuffer > 0) {
        this.initChunkTables(tablesInfo[i], singleSampleBuffer, singleSampleBuffer);
      } else {
        this.initChunkTables(tablesInfo[i], SAMPLES_PER_CHUNK_INIT, SAMPLES_PER_CHUNK);
      }

      sampleCount[i] = tablesInfo[i].stsz;

      if (sampleSizeChanges === 1) {
        tablesInfo[i].stsz = 0;
        tablesInfo[i].stszDefault = samplesSize;
      } else {
        tablesInfo[i].stszDefault = 0;
      }

      if (tablesInfo[i].stss === tablesInfo[i].stsz) {
        tablesInfo[i].stss = -1; // for audio tracks (all samples are keyframes)
      }

      // ensure track duration
      if (tracks[i].trak.tkhd.duration < 1) {
        tracks[i].trak.tkhd.duration = sampleExtra[i]; // this never should happen
      }
    }


    const is64: boolean = read > THRESHOLD_FOR_CO64;

    // calculate the moov size
    const auxSize: number = this.makeMoov(defaultMediaTime, tablesInfo, is64);

    if (auxSize < THRESHOLD_MOOV_LENGTH) {
      this.auxBuffer = ByteBuffer.allocate(auxSize); // cache moov in the memory
    }

    this.moovSimulation = false;
    this.writeOffset = 0;

    const ftypSize: number = this.makeFtyp();

    // reserve moov space in the output stream
    if (auxSize > 0) {
      let length: number = auxSize;
      const buffer: Uint8Array = new Uint8Array(64 * 1024); // 64 KiB
      while (length > 0) {
        const count: number = Math.min(length, buffer.length);
        this.outWrite(buffer, count);
        length -= count;
      }
    }

    if (this.auxBuffer === null) {
      this.outSeek(ftypSize);
    }

    // tablesInfo contains row counts
    // and after returning from makeMoov() will contain those table offsets
    this.makeMoov(defaultMediaTime, tablesInfo, is64);

    // write tables: stts stsc sbgp
    // reset for ctts table: sampleCount sampleExtra
    for (let i: number = 0; i < readerCount; i++) {
      this.writeEntryArray(tablesInfo[i].stts, 2,
        new Int32Array([sampleCount[i], defaultSampleDuration[i]]));
      const stscBEntries: Int32Array =
        requireNonNull<Int32Array>(tablesInfo[i].stscBEntries, 'stsc entries');
      this.writeEntryArray(tablesInfo[i].stsc, stscBEntries.length, stscBEntries);
      tablesInfo[i].stscBEntries = null;
      if (tablesInfo[i].ctts > 0) {
        sampleCount[i] = 1; // the index is not base zero
        sampleExtra[i] = -1;
      }
      if (tablesInfo[i].sbgp > 0) {
        this.writeEntryArray(tablesInfo[i].sbgp, 1, new Int32Array([sampleCount[i]]));
      }
    }

    if (this.auxBuffer === null) {
      this.outRestore();
    }

    const mdat: Uint8Array = this.makeMdat(totalSampleSize, is64);
    this.outWrite(mdat, mdat.length);

    const sampleIndex: Int32Array = new Int32Array(readerCount);
    const sizes: Int32Array =
      new Int32Array(singleSampleBuffer > 0 ? singleSampleBuffer : SAMPLES_PER_CHUNK);
    const sync: Int32Array =
      new Int32Array(singleSampleBuffer > 0 ? singleSampleBuffer : SAMPLES_PER_CHUNK);

    let written: number = readerCount;
    while (written > 0) {
      written = 0;

      for (let i: number = 0; i < readerCount; i++) {
        if (sampleIndex[i] < 0) {
          continue; // track is done
        }

        const chunkOffset: number = this.writeOffset;
        let syncCount: number = 0;
        const limit: number = singleSampleBuffer > 0
          ? singleSampleBuffer
          : (sampleIndex[i] === 0 ? SAMPLES_PER_CHUNK_INIT : SAMPLES_PER_CHUNK);

        let j: number = 0;
        for (; j < limit; j++) {
          const sample: Mp4DashSample | null = this.getNextSample(i);

          if (sample === null) {
            if (tablesInfo[i].ctts > 0 && sampleExtra[i] >= 0) {
              // count 1: only the sample count of the last entry is written, as in the source
              this.writeEntryArray(tablesInfo[i].ctts, 1,
                new Int32Array([sampleCount[i], sampleExtra[i]])); // flush last entries
              this.outRestore();
            }
            sampleIndex[i] = -1;
            break;
          }

          sampleIndex[i]++;

          if (tablesInfo[i].ctts > 0) {
            if (sample.info.sampleCompositionTimeOffset === sampleExtra[i]) {
              sampleCount[i]++;
            } else {
              if (sampleExtra[i] >= 0) {
                tablesInfo[i].ctts = this.writeEntryArray(tablesInfo[i].ctts, 2,
                  new Int32Array([sampleCount[i], sampleExtra[i]]));
                this.outRestore();
              }
              sampleCount[i] = 1;
              sampleExtra[i] = sample.info.sampleCompositionTimeOffset;
            }
          }

          if (tablesInfo[i].stss > 0 && sample.info.isKeyframe) {
            sync[syncCount] = sampleIndex[i];
            syncCount++;
          }

          if (tablesInfo[i].stsz > 0) {
            sizes[j] = sample.data.length;
          }

          this.outWrite(sample.data, sample.data.length);
        }

        if (j > 0) {
          written++;

          if (tablesInfo[i].stsz > 0) {
            tablesInfo[i].stsz = this.writeEntryArray(tablesInfo[i].stsz, j, sizes);
          }

          if (syncCount > 0) {
            tablesInfo[i].stss = this.writeEntryArray(tablesInfo[i].stss, syncCount, sync);
          }

          if (tablesInfo[i].stco > 0) {
            if (is64) {
              tablesInfo[i].stco = this.writeEntry64(tablesInfo[i].stco, chunkOffset);
            } else {
              tablesInfo[i].stco = this.writeEntryArray(tablesInfo[i].stco, 1,
                new Int32Array([toInt32(chunkOffset)]));
            }
          }

          this.outRestore();
        }
      }
    }

    const aux: ByteBuffer | null = this.auxBuffer;
    if (aux !== null) {
      // dump moov
      this.outSeek(ftypSize);
      this.requireOut().writeFrom(aux.array(), 0, aux.capacity());
      this.auxBuffer = null;
    }
  }

  /** readers[index], which the source dereferences directly. */
  private reader(index: number): Mp4DashReader {
    return requireNonNull<Mp4DashReader>(this.readers[index], 'reader (sources not parsed)');
  }

  private requireTracks(): Mp4Track[] {
    return requireNonNull<Mp4Track[]>(this.tracks, 'tracks (none selected)');
  }

  private requireOut(): SharpStream {
    return requireNonNull<SharpStream>(this.outStream, 'output stream');
  }

  private getNextSample(track: number): Mp4DashSample | null {
    let chunk: Mp4DashChunk | null = this.readersChunks[track];
    if (chunk === null) {
      chunk = this.reader(track).getNextChunk(false);
      this.readersChunks[track] = chunk;
      if (chunk === null) {
        return null; // EOF reached
      }
    }

    const sample: Mp4DashSample | null = chunk.getNextSample();
    if (sample === null) {
      this.readersChunks[track] = null;
      return this.getNextSample(track);
    } else {
      return sample;
    }
  }


  private writeEntry64(offset: number, value: number): number {
    this.outBackup();

    this.auxSeek(offset);
    this.auxWrite(ByteBuffer.allocate(8).putLong(value).array());

    return offset + 8;
  }

  private writeEntryArray(offset: number, count: number, values: Int32Array): number {
    this.outBackup();

    this.auxSeek(offset);

    const size: number = count * 4;
    const buffer: ByteBuffer = ByteBuffer.allocate(size);

    for (let i: number = 0; i < count; i++) {
      buffer.putInt(values[i]);
    }

    this.auxWrite(buffer.array());

    return offset + size;
  }

  private outBackup(): void {
    if (this.auxBuffer === null && this.lastWriteOffset < 0) {
      this.lastWriteOffset = this.writeOffset;
    }
  }

  /**
   * Restore to the previous position before the first call to writeEntry64()
   * or writeEntryArray() methods.
   */
  private outRestore(): void {
    if (this.lastWriteOffset > 0) {
      this.outSeek(this.lastWriteOffset);
      this.lastWriteOffset = -1;
    }
  }

  private initChunkTables(tables: TablesInfo, firstCount: number, successiveCount: number): void {
    // tables.stsz holds amount of samples of the track (total)
    const totalSamples: number = (tables.stsz - firstCount);
    // the source divides in float: fround reproduces its single-precision rounding
    const chunkAmount: number =
      Math.fround(Math.fround(totalSamples) / Math.fround(successiveCount));
    const remainChunkOffset: number = Math.ceil(chunkAmount);
    const remain: boolean = remainChunkOffset !== Math.trunc(chunkAmount);
    let index: number = 0;

    tables.stsc = 1;
    if (firstCount !== successiveCount) {
      tables.stsc++;
    }
    if (remain) {
      tables.stsc++;
    }

    // stsc_table_entry = [first_chunk, samples_per_chunk, sample_description_index]
    const stscBEntries: Int32Array = new Int32Array(tables.stsc * 3);
    tables.stscBEntries = stscBEntries;
    tables.stco = remainChunkOffset + 1; // total entries in chunk offset box

    stscBEntries[index++] = 1;
    stscBEntries[index++] = firstCount;
    stscBEntries[index++] = 1;

    if (firstCount !== successiveCount) {
      stscBEntries[index++] = 2;
      stscBEntries[index++] = successiveCount;
      stscBEntries[index++] = 1;
    }

    if (remain) {
      stscBEntries[index++] = remainChunkOffset + 1;
      stscBEntries[index++] = totalSamples % successiveCount;
      stscBEntries[index] = 1;
    }
  }

  private outWrite(buffer: Uint8Array, count: number): void {
    this.writeOffset += count;
    this.requireOut().writeFrom(buffer, 0, count);
  }

  private outSeek(offset: number): void {
    const out: SharpStream = this.requireOut();
    if (out.canSeek()) {
      out.seek(offset);
      this.writeOffset = offset;
    } else if (out.canRewind()) {
      out.rewind();
      this.writeOffset = 0;
      this.outSkip(offset);
    } else {
      throw new StreamError('cannot seek or rewind the output stream');
    }
  }

  private outSkip(amount: number): void {
    this.requireOut().skip(amount);
    this.writeOffset += amount;
  }

  private lengthFor(offset: number): number {
    const size: number = this.auxOffset() - offset;

    if (this.moovSimulation) {
      return size;
    }

    this.auxSeek(offset);
    this.auxWriteInt(size);
    this.auxSkip(size - 4);

    return size;
  }

  private make(type: number, extra: number, columns: number, rows: number): number {
    const base: number = 16;
    const size: number = columns * rows * 4;
    let total: number = size + base;
    let offset: number = this.auxOffset();

    if (extra >= 0) {
      total += 4;
    }

    this.auxWrite(ByteBuffer.allocate(12)
      .putInt(total)
      .putInt(type)
      .putInt(0x00)// default version & flags
      .array()
    );

    if (extra >= 0) {
      offset += 4;
      this.auxWriteInt(extra);
    }

    this.auxWriteInt(rows);
    this.auxSkip(size);

    return offset + base;
  }

  /** auxWrite(int) of the source. */
  private auxWriteInt(value: number): void {
    this.auxWrite(ByteBuffer.allocate(4)
      .putInt(value)
      .array()
    );
  }

  private auxWrite(buffer: Uint8Array): void {
    const aux: ByteBuffer | null = this.auxBuffer;
    if (this.moovSimulation) {
      this.writeOffset += buffer.length;
    } else if (aux === null) {
      this.outWrite(buffer, buffer.length);
    } else {
      aux.put(buffer);
    }
  }

  private auxSeek(offset: number): void {
    const aux: ByteBuffer | null = this.auxBuffer;
    if (this.moovSimulation) {
      this.writeOffset = offset;
    } else if (aux === null) {
      this.outSeek(offset);
    } else {
      aux.setPosition(offset);
    }
  }

  private auxSkip(amount: number): void {
    const aux: ByteBuffer | null = this.auxBuffer;
    if (this.moovSimulation) {
      this.writeOffset += amount;
    } else if (aux === null) {
      this.outSkip(amount);
    } else {
      aux.setPosition(aux.position() + amount);
    }
  }

  private auxOffset(): number {
    const aux: ByteBuffer | null = this.auxBuffer;
    return aux === null ? toInt32(this.writeOffset) : aux.position();
  }

  private makeFtyp(): number {
    let size: number = 16 + (this.compatibleBrands.length * 4);
    if (this.overrideMainBrand !== 0) {
      size += 4;
    }

    const buffer: ByteBuffer = ByteBuffer.allocate(size);
    buffer.putInt(size);
    buffer.putInt(0x66747970); // "ftyp"

    if (this.overrideMainBrand === 0) {
      buffer.putInt(0x6D703432); // mayor brand "mp42"
      buffer.putInt(512); // default minor version
    } else {
      buffer.putInt(this.overrideMainBrand);
      buffer.putInt(0);
      buffer.putInt(0x6D703432); // "mp42" compatible brand
    }

    for (const brand of this.compatibleBrands) {
      buffer.putInt(brand); // compatible brand
    }

    const ftyp: Uint8Array = buffer.array();
    this.outWrite(ftyp, ftyp.length);

    return size;
  }

  private makeMdat(refSize: number, is64: boolean): Uint8Array {
    let size: number = refSize;
    if (is64) {
      size += 16;
    } else {
      size += 8;
    }

    const buffer: ByteBuffer = ByteBuffer.allocate(is64 ? 16 : 8)
      .putInt(is64 ? 0x01 : toInt32(size))
      .putInt(0x6D646174); // mdat

    if (is64) {
      buffer.putLong(size);
    }

    return buffer.array();
  }

  private makeMvhd(longestTrack: number): void {
    this.auxWrite(new Uint8Array([
      0x00, 0x00, 0x00, 0x78, 0x6D, 0x76, 0x68, 0x64, 0x01, 0x00, 0x00, 0x00
    ]));
    this.auxWrite(ByteBuffer.allocate(28)
      .putLong(this.time)
      .putLong(this.time)
      .putInt(DEFAULT_TIMESCALE)
      .putLong(longestTrack)
      .array()
    );

    this.auxWrite(new Uint8Array([
      0x00, 0x01, 0x00, 0x00, 0x01, 0x00, // default volume and rate
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // reserved values
      // default matrix
      0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00,
      0x40, 0x00, 0x00, 0x00
    ]));
    this.auxWrite(new Uint8Array(24)); // predefined
    this.auxWrite(ByteBuffer.allocate(4)
      .putInt(this.requireTracks().length + 1)
      .array()
    );
  }

  private makeMoov(defaultMediaTime: Int32Array, tablesInfo: TablesInfo[], is64: boolean): number {
    const tracks: Mp4Track[] = this.requireTracks();
    const start: number = this.auxOffset();

    this.auxWrite(new Uint8Array([
      0x00, 0x00, 0x00, 0x00, 0x6D, 0x6F, 0x6F, 0x76
    ]));

    let longestTrack: number = 0;
    const durations: number[] = [];

    for (let i: number = 0; i < tracks.length; i++) {
      const timeScale: number = requireNonNull<Mdia>(tracks[i].trak.mdia, 'mdia').mdhdTimeScale;
      durations.push(Math.ceil((tracks[i].trak.tkhd.duration / timeScale) * DEFAULT_TIMESCALE));

      if (durations[i] > longestTrack) {
        longestTrack = durations[i];
      }
    }

    this.makeMvhd(longestTrack);

    for (let i: number = 0; i < tracks.length; i++) {
      if (tracks[i].trak.tkhd.matrix.length !== 36) {
        throw new Error('bad track matrix length (expected 36) in track n°' + i);
      }
      this.makeTrak(i, durations[i], defaultMediaTime[i], tablesInfo[i], is64);
    }

    return this.lengthFor(start);
  }

  private makeTrak(index: number, duration: number, defaultMediaTime: number,
    tables: TablesInfo, is64: boolean): void {
    const track: Mp4Track = this.requireTracks()[index];
    const start: number = this.auxOffset();

    this.auxWrite(new Uint8Array([
      // trak header
      0x00, 0x00, 0x00, 0x00, 0x74, 0x72, 0x61, 0x6B,
      // tkhd header
      0x00, 0x00, 0x00, 0x68, 0x74, 0x6B, 0x68, 0x64, 0x01, 0x00, 0x00, 0x03
    ]));

    const buffer: ByteBuffer = ByteBuffer.allocate(48);
    buffer.putLong(this.time);
    buffer.putLong(this.time);
    buffer.putInt(index + 1);
    buffer.setPosition(24);
    buffer.putLong(duration);
    buffer.setPosition(40);
    buffer.putShort(track.trak.tkhd.bLayer);
    buffer.putShort(track.trak.tkhd.bAlternateGroup);
    buffer.putShort(track.trak.tkhd.bVolume);
    this.auxWrite(buffer.array());

    this.auxWrite(track.trak.tkhd.matrix);
    this.auxWrite(ByteBuffer.allocate(8)
      .putInt(track.trak.tkhd.bWidth)
      .putInt(track.trak.tkhd.bHeight)
      .array()
    );

    this.auxWrite(new Uint8Array([
      0x00, 0x00, 0x00, 0x24, 0x65, 0x64, 0x74, 0x73, // edts header
      0x00, 0x00, 0x00, 0x1C, 0x65, 0x6C, 0x73, 0x74,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01 // elst header
    ]));

    // without elst: is a audio track ¿is edst/elst optional for audio tracks?
    let mediaTime: number = 0x00; // ffmpeg set this value as zero, instead of defaultMediaTime
    let bMediaRate: number = 0x00010000;

    const elst: Elst | null = track.trak.edstElst;
    if (elst !== null) {
      mediaTime = toInt32(elst.mediaTime);
      bMediaRate = elst.bMediaRate;
    }

    this.auxWrite(ByteBuffer
      .allocate(12)
      .putInt(toInt32(duration))
      .putInt(mediaTime)
      .putInt(bMediaRate)
      .array()
    );

    this.makeMdia(requireNonNull<Mdia>(track.trak.mdia, 'mdia'), tables, is64,
      track.kind === TrackKind.Audio);

    this.lengthFor(start);
  }

  private makeMdia(mdia: Mdia, tablesInfo: TablesInfo, is64: boolean, isAudio: boolean): void {
    const startMdia: number = this.auxOffset();
    this.auxWrite(new Uint8Array([0x00, 0x00, 0x00, 0x00, 0x6D, 0x64, 0x69, 0x61])); // mdia
    this.auxWrite(requireNonNull<Uint8Array>(mdia.mdhd, 'mdhd'));
    this.auxWrite(this.makeHdlr(requireNonNull<Hdlr>(mdia.hdlr, 'hdlr')));

    const minf: Minf = requireNonNull<Minf>(mdia.minf, 'minf');
    const startMinf: number = this.auxOffset();
    this.auxWrite(new Uint8Array([0x00, 0x00, 0x00, 0x00, 0x6D, 0x69, 0x6E, 0x66])); // minf
    this.auxWrite(requireNonNull<Uint8Array>(minf.mhd, 'vmhd/smhd'));
    this.auxWrite(requireNonNull<Uint8Array>(minf.dinf, 'dinf'));

    const startStbl: number = this.auxOffset();
    this.auxWrite(new Uint8Array([0x00, 0x00, 0x00, 0x00, 0x73, 0x74, 0x62, 0x6C])); // stbl
    this.auxWrite(requireNonNull<Uint8Array>(minf.stblStsd, 'stbl'));

    //
    // In audio tracks the following tables is not required: ssts ctts
    // And stsz can be empty if has a default sample size
    //
    if (this.moovSimulation) {
      this.make(0x73747473, -1, 2, 1); // stts
      if (tablesInfo.stss > 0) {
        this.make(0x73747373, -1, 1, tablesInfo.stss);
      }
      if (tablesInfo.ctts > 0) {
        this.make(0x63747473, -1, 2, tablesInfo.ctts);
      }
      this.make(0x73747363, -1, 3, tablesInfo.stsc);
      this.make(0x7374737A, tablesInfo.stszDefault, 1, tablesInfo.stsz);
      this.make(is64 ? 0x636F3634 : 0x7374636F, -1, is64 ? 2 : 1, tablesInfo.stco);
    } else {
      tablesInfo.stts = this.make(0x73747473, -1, 2, 1);
      if (tablesInfo.stss > 0) {
        tablesInfo.stss = this.make(0x73747373, -1, 1, tablesInfo.stss);
      }
      if (tablesInfo.ctts > 0) {
        tablesInfo.ctts = this.make(0x63747473, -1, 2, tablesInfo.ctts);
      }
      tablesInfo.stsc = this.make(0x73747363, -1, 3, tablesInfo.stsc);
      tablesInfo.stsz = this.make(0x7374737A, tablesInfo.stszDefault, 1, tablesInfo.stsz);
      tablesInfo.stco = this.make(is64 ? 0x636F3634 : 0x7374636F, -1, is64 ? 2 : 1,
        tablesInfo.stco);
    }

    if (isAudio) {
      this.auxWrite(this.makeSgpd());
      tablesInfo.sbgp = this.makeSbgp(); // during simulation the returned offset is ignored
    }

    this.lengthFor(startStbl);
    this.lengthFor(startMinf);
    this.lengthFor(startMdia);
  }

  private makeHdlr(hdlr: Hdlr): Uint8Array {
    const buffer: ByteBuffer = ByteBuffer.wrap(new Uint8Array([
      0x00, 0x00, 0x00, 0x21, 0x68, 0x64, 0x6C, 0x72, // hdlr
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00// null string character
    ]));

    buffer.setPosition(12);
    buffer.putInt(hdlr.type);
    buffer.putInt(hdlr.subType);
    buffer.put(hdlr.bReserved); // always is a zero array

    return buffer.array();
  }

  private makeSbgp(): number {
    const offset: number = this.auxOffset();

    this.auxWrite(new Uint8Array([
      0x00, 0x00, 0x00, 0x1C, // box size
      0x73, 0x62, 0x67, 0x70, // "sbpg"
      0x00, 0x00, 0x00, 0x00, // default box flags
      0x72, 0x6F, 0x6C, 0x6C, // group type "roll"
      0x00, 0x00, 0x00, 0x01, // group table size
      0x00, 0x00, 0x00, 0x00, // group[0] total samples (to be set later)
      0x00, 0x00, 0x00, 0x01 // group[0] description index
    ]));

    return offset + 0x14;
  }

  private makeSgpd(): Uint8Array {
    /*
     * Sample Group Description Box
     *
     * ¿whats does?
     * the table inside of this box gives information about the
     * characteristics of sample groups. The descriptive information is any other
     * information needed to define or characterize the sample group.
     *
     * ¿is replicable this box?
     * NO due lacks of documentation about this box but...
     * most of m4a encoders and ffmpeg uses this box with dummy values (same values)
     */

    return new Uint8Array([
      0x00, 0x00, 0x00, 0x1A, // box size
      0x73, 0x67, 0x70, 0x64, // "sgpd"
      0x01, 0x00, 0x00, 0x00, // box flags (unknown flag sets)
      0x72, 0x6F, 0x6C, 0x6C, // ¿¿group type??
      0x00, 0x00, 0x00, 0x02, // ¿¿??
      0x00, 0x00, 0x00, 0x01, // ¿¿??
      0xFF, 0xFF // ¿¿??
    ]);
  }
}
