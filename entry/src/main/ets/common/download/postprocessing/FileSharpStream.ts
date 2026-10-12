/*
 * us.shandian.giga.io.FileStream: a SharpStream over one open file descriptor, with the
 * RandomAccessFile operations (seek / length / setLength) the muxers need.
 *
 * Buffered both ways: the readers pull single bytes by the million, and a syscall per byte would
 * make a muxed 100 MB download take minutes. A write or a seek first drains what is buffered.
 */

import { fileIo } from '@kit.CoreFileKit';
import { SharpStream, StreamError } from './SharpStream';

const BUFFER_SIZE: number = 64 * 1024;

export class FileSharpStream extends SharpStream {
  private fd: number;
  private closed: boolean = false;
  /** Where the NEXT byte is read from or written to, in the file. */
  private position: number = 0;
  /** Read-ahead: readBuffer[readPos..readLen) are the bytes at `position` onwards. */
  private readBuffer: Uint8Array = new Uint8Array(BUFFER_SIZE);
  private readPos: number = 0;
  private readLen: number = 0;
  /** Write-behind: writeBuffer[0..writeLen) belong at writeStart. */
  private writeBuffer: Uint8Array = new Uint8Array(BUFFER_SIZE);
  private writeLen: number = 0;
  private writeStart: number = 0;
  private readonly ownsFd: boolean;

  /** @param ownsFd whether close() also closes the descriptor (false when the caller owns it). */
  constructor(fd: number, ownsFd: boolean = true) {
    super();
    this.fd = fd;
    this.ownsFd = ownsFd;
  }

  static open(path: string, write: boolean): FileSharpStream {
    const mode: number = write
      ? fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
      : fileIo.OpenMode.READ_ONLY;
    const file: fileIo.File = fileIo.openSync(path, mode);
    return new FileSharpStream(file.fd, true);
  }

  private dropReadAhead(): void {
    this.readPos = 0;
    this.readLen = 0;
  }

  private drainWrites(): void {
    if (this.writeLen === 0) {
      return;
    }
    let done: number = 0;
    while (done < this.writeLen) {
      const n: number = fileIo.writeSync(this.fd, this.writeBuffer.buffer.slice(done, this.writeLen),
        { offset: this.writeStart + done });
      if (n <= 0) {
        throw new StreamError('write failed');
      }
      done = done + n;
    }
    this.writeLen = 0;
  }

  private fill(): boolean {
    this.drainWrites();
    const n: number = fileIo.readSync(this.fd, this.readBuffer.buffer,
      { offset: this.position, length: BUFFER_SIZE });
    this.readPos = 0;
    this.readLen = n > 0 ? n : 0;
    return this.readLen > 0;
  }

  read(): number {
    if (this.readPos >= this.readLen && !this.fill()) {
      return -1;
    }
    const value: number = this.readBuffer[this.readPos];
    this.readPos = this.readPos + 1;
    this.position = this.position + 1;
    return value;
  }

  readInto(buffer: Uint8Array, offset: number, count: number): number {
    if (count <= 0) {
      return 0;
    }
    let total: number = 0;
    while (total < count) {
      if (this.readPos >= this.readLen && !this.fill()) {
        break;
      }
      const take: number = Math.min(count - total, this.readLen - this.readPos);
      buffer.set(this.readBuffer.subarray(this.readPos, this.readPos + take), offset + total);
      this.readPos = this.readPos + take;
      this.position = this.position + take;
      total = total + take;
    }
    return total === 0 ? -1 : total;
  }

  skip(amount: number): number {
    if (amount <= 0) {
      return 0;
    }
    const target: number = Math.min(this.position + amount, this.length());
    const skipped: number = target - this.position;
    this.seek(target);
    return skipped;
  }

  available(): number {
    return Math.max(0, this.length() - this.position);
  }

  rewind(): void {
    this.seek(0);
  }

  isClosed(): boolean {
    return this.closed;
  }

  close(): void {
    if (this.closed) {
      return;
    }
    try {
      this.drainWrites();
    } finally {
      this.closed = true;
      if (this.ownsFd) {
        fileIo.closeSync(this.fd);
      }
    }
  }

  canRewind(): boolean {
    return true;
  }

  canRead(): boolean {
    return true;
  }

  canWrite(): boolean {
    return true;
  }

  canSetLength(): boolean {
    return true;
  }

  canSeek(): boolean {
    return true;
  }

  writeByte(value: number): void {
    const one: Uint8Array = new Uint8Array(1);
    one[0] = value & 0xff;
    this.writeFrom(one, 0, 1);
  }

  writeFrom(buffer: Uint8Array, offset: number, count: number): void {
    if (count <= 0) {
      return;
    }
    // A write lands at `position`; read-ahead past it is now stale.
    this.dropReadAhead();
    if (this.writeLen > 0 && this.writeStart + this.writeLen !== this.position) {
      this.drainWrites();
    }
    if (this.writeLen === 0) {
      this.writeStart = this.position;
    }
    let done: number = 0;
    while (done < count) {
      const room: number = BUFFER_SIZE - this.writeLen;
      const take: number = Math.min(room, count - done);
      this.writeBuffer.set(buffer.subarray(offset + done, offset + done + take), this.writeLen);
      this.writeLen = this.writeLen + take;
      done = done + take;
      this.position = this.position + take;
      if (this.writeLen === BUFFER_SIZE) {
        this.drainWrites();
        this.writeStart = this.position;
      }
    }
  }

  flush(): void {
    this.drainWrites();
  }

  setLength(length: number): void {
    this.drainWrites();
    this.dropReadAhead();
    fileIo.truncateSync(this.fd, length);
    if (this.position > length) {
      this.position = length;
    }
  }

  seek(offset: number): void {
    if (offset === this.position) {
      return;
    }
    this.drainWrites();
    // Keep the read-ahead when the target is inside it.
    const bufferStart: number = this.position - this.readPos;
    if (offset >= bufferStart && offset < bufferStart + this.readLen) {
      this.readPos = offset - bufferStart;
    } else {
      this.dropReadAhead();
    }
    this.position = offset;
  }

  length(): number {
    this.drainWrites();
    const size: number = fileIo.statSync(this.fd).size;
    return Math.max(size, this.position);
  }

  getFilePointer(): number {
    return this.position;
  }
}
