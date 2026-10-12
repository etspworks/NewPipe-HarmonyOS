/*
 * Port of org.schabi.newpipe.streams.io.SharpStream: the byte stream every post-processing
 * reader and writer works on. Synchronous on purpose - the muxers run inside a taskpool worker,
 * where blocking file I/O is what the source's own worker thread did.
 *
 * Java's `long` positions are plain numbers here (exact up to 2^53 bytes). `read()` returns the
 * byte (0..255) or -1 at the end, as InputStream.read() does.
 */

export class StreamError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'IOException';
  }
}

export abstract class SharpStream {
  abstract read(): number;

  /** Reads up to `count` bytes into buffer[offset..]; returns how many, or -1 at the end. */
  abstract readInto(buffer: Uint8Array, offset: number, count: number): number;

  read1(buffer: Uint8Array): number {
    return this.readInto(buffer, 0, buffer.length);
  }

  abstract skip(amount: number): number;

  abstract available(): number;

  abstract rewind(): void;

  abstract isClosed(): boolean;

  abstract close(): void;

  abstract canRewind(): boolean;

  abstract canRead(): boolean;

  abstract canWrite(): boolean;

  canSetLength(): boolean {
    return false;
  }

  canSeek(): boolean {
    return false;
  }

  abstract writeByte(value: number): void;

  abstract writeFrom(buffer: Uint8Array, offset: number, count: number): void;

  write(buffer: Uint8Array): void {
    this.writeFrom(buffer, 0, buffer.length);
  }

  flush(): void {
    // STUB, as in the source
  }

  setLength(length: number): void {
    throw new StreamError('Not implemented');
  }

  seek(offset: number): void {
    throw new StreamError('Not implemented');
  }

  length(): number {
    throw new StreamError('Unsupported operation');
  }
}

/** us.shandian.giga.io.ProgressReport. */
export type ProgressReport = (position: number) => void;
