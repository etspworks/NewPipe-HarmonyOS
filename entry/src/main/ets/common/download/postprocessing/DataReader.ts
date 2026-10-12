/*
 * Port of org.schabi.newpipe.streams.DataReader (author kapodamy): a buffered big-endian reader
 * over a SharpStream, used by the MP4 DASH demuxer.
 *
 * Java longs (positions, 64-bit fields) are plain numbers, exact below 2^53. Java ints are int32
 * numbers: assembled from bytes with bitwise operators, and wrapped with toInt32() wherever the
 * source narrows a long or lets an int overflow.
 */

import { SharpStream, StreamError } from './SharpStream';

const BUFFER_SIZE: number = 128 * 1024; // 128 KiB

/**
 * Java's (int) cast of a long, or an int sum wrapping around: the low 32 bits as a signed value.
 * Arithmetic rather than `| 0`, so a value wider than 32 bits never meets a bitwise operator.
 */
export function toInt32(value: number): number {
  let low: number = value % 4294967296;
  if (low < 0) {
    low = low + 4294967296;
  }
  return low >= 2147483648 ? low - 4294967296 : low;
}

export class DataReader {
  static readonly SHORT_SIZE: number = 2;
  static readonly LONG_SIZE: number = 8;
  static readonly INTEGER_SIZE: number = 4;
  static readonly FLOAT_SIZE: number = 4;

  /** The source's `position` field (renamed: position() is its accessor). */
  private pos: number = 0;
  private readonly stream: SharpStream;

  private view: DataReaderView | null = null;
  /** Shared with DataReaderView, as the source shares it with its anonymous InputStream. */
  viewSize: number = 0;

  private readonly primitive: Uint8Array = new Uint8Array(DataReader.LONG_SIZE);

  private readonly readBuffer: Uint8Array = new Uint8Array(BUFFER_SIZE);
  private readOffset: number = BUFFER_SIZE;
  private readCount: number = 0;

  constructor(stream: SharpStream) {
    this.stream = stream;
  }

  position(): number {
    return this.pos;
  }

  read(): number {
    if (this.fillBuffer()) {
      return -1;
    }

    this.pos++;
    this.readCount--;

    const value: number = this.readBuffer[this.readOffset];
    this.readOffset++;
    return value;
  }

  skipBytes(byteAmount: number): number {
    let amount: number = byteAmount;
    if (this.readCount < 0) {
      return 0;
    } else if (this.readCount === 0) {
      amount = this.stream.skip(amount);
    } else {
      if (this.readCount > amount) {
        this.readCount -= toInt32(amount);
        this.readOffset += toInt32(amount);
      } else {
        amount = this.readCount + this.stream.skip(amount - this.readCount);
        this.readCount = 0;
        this.readOffset = this.readBuffer.length;
      }
    }

    this.pos += amount;
    return amount;
  }

  readInt(): number {
    this.primitiveRead(DataReader.INTEGER_SIZE);
    const p: Uint8Array = this.primitive;
    return (p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3];
  }

  readUnsignedInt(): number {
    return this.readInt() >>> 0;
  }

  readShort(): number {
    this.primitiveRead(DataReader.SHORT_SIZE);
    const p: Uint8Array = this.primitive;
    return (((p[0] << 8) | p[1]) << 16) >> 16;
  }

  readLong(): number {
    this.primitiveRead(DataReader.LONG_SIZE);
    const p: Uint8Array = this.primitive;
    const high: number = (p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3];
    const low: number = (p[4] << 24) | (p[5] << 16) | (p[6] << 8) | p[7];
    // The source widens both ints to long with sign extension before `high << 32 | low`, so a
    // low word with bit 31 set fills the high word with ones and the result is just `low`.
    if (low < 0) {
      return low;
    }
    return high * 4294967296 + low;
  }

  /** read(byte[]) in the source. */
  read1(buffer: Uint8Array): number {
    return this.readInto(buffer, 0, buffer.length);
  }

  /** read(byte[], int, int) in the source. */
  readInto(buffer: Uint8Array, off: number, c: number): number {
    let offset: number = off;
    let count: number = c;

    if (this.readCount < 0) {
      return -1;
    }
    let total: number = 0;

    if (count >= this.readBuffer.length) {
      if (this.readCount > 0) {
        buffer.set(this.readBuffer.subarray(this.readOffset, this.readOffset + this.readCount),
          offset);
        this.readOffset += this.readCount;

        offset += this.readCount;
        count -= this.readCount;

        total = this.readCount;
        this.readCount = 0;
      }
      total += Math.max(this.stream.readInto(buffer, offset, count), 0);
    } else {
      while (count > 0 && !this.fillBuffer()) {
        const read: number = Math.min(this.readCount, count);
        buffer.set(this.readBuffer.subarray(this.readOffset, this.readOffset + read), offset);

        this.readOffset += read;
        this.readCount -= read;

        offset += read;
        count -= read;

        total += read;
      }
    }

    this.pos += total;
    return total;
  }

  available(): boolean {
    return this.readCount > 0 || this.stream.available() > 0;
  }

  rewind(): void {
    this.stream.rewind();

    if ((this.pos - this.viewSize) > 0) {
      this.viewSize = 0; // drop view
    } else {
      this.viewSize = toInt32(this.viewSize + this.pos);
    }

    this.pos = 0;
    this.readOffset = this.readBuffer.length;
    this.readCount = 0;
  }

  canRewind(): boolean {
    return this.stream.canRewind();
  }

  /**
   * Wraps this instance of DataReader into an InputStream-like view. Note: Any read in the
   * DataReader will not modify (decrease) the view size.
   *
   * @param size the size of the view
   * @return the view
   */
  getView(size: number): DataReaderView {
    let view: DataReaderView | null = this.view;
    if (view === null) {
      view = new DataReaderView(this);
      this.view = view;
    }
    this.viewSize = size;

    return view;
  }

  private primitiveRead(amount: number): void {
    // Straight into `primitive`: on a short read it throws, and every reader of `primitive`
    // first overwrites the bytes it uses, so the source's temporary array changes nothing.
    const read: number = this.readInto(this.primitive, 0, amount);

    if (read !== amount) {
      throw new StreamError('Truncated stream, missing ' + (amount - read) + ' bytes');
    }
  }

  private fillBuffer(): boolean {
    if (this.readCount < 0) {
      return true;
    }
    if (this.readOffset >= this.readBuffer.length) {
      this.readCount = this.stream.read1(this.readBuffer);
      if (this.readCount < 1) {
        this.readCount = -1;
        return true;
      }
      this.readOffset = 0;
    }

    return this.readCount < 1;
  }
}

/** The InputStream that DataReader.getView() returns (an anonymous class in the source). */
export class DataReaderView {
  private readonly reader: DataReader;

  constructor(reader: DataReader) {
    this.reader = reader;
  }

  read(): number {
    if (this.reader.viewSize < 1) {
      return -1;
    }
    const res: number = this.reader.read();
    if (res > 0) {
      this.reader.viewSize--;
    }
    return res;
  }

  read1(buffer: Uint8Array): number {
    return this.readInto(buffer, 0, buffer.length);
  }

  readInto(buffer: Uint8Array, offset: number, count: number): number {
    if (this.reader.viewSize < 1) {
      return -1;
    }

    const res: number = this.reader.readInto(buffer, offset, Math.min(this.reader.viewSize, count));
    this.reader.viewSize -= res;

    return res;
  }

  skip(amount: number): number {
    if (this.reader.viewSize < 1) {
      return 0;
    }
    const res: number = toInt32(this.reader.skipBytes(Math.min(amount, this.reader.viewSize)));
    this.reader.viewSize -= res;

    return res;
  }

  available(): number {
    return this.reader.viewSize;
  }

  close(): void {
    this.reader.viewSize = 0;
  }
}
