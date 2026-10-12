/*
 * Port of us.shandian.giga.io.ChunkFileInputStream: one downloaded resource inside the mission's
 * file. A mission with several urls writes them back to back, so each source of the muxer is the
 * [start, end) slice of that one file.
 */

import { ProgressReport, SharpStream, StreamError } from './SharpStream';

const REPORT_INTERVAL: number = 256 * 1024;

export class ChunkFileInputStream extends SharpStream {
  private source: SharpStream | null;
  private readonly offset: number;
  private readonly chunkLength: number;
  private position: number = 0;
  private progressReport: number = REPORT_INTERVAL;
  private readonly onProgress: ProgressReport | null;

  constructor(target: SharpStream, start: number, end: number, callback: ProgressReport | null) {
    super();
    this.source = target;
    this.offset = start;
    this.chunkLength = end - start;
    this.onProgress = callback;
    if (this.chunkLength < 1) {
      target.close();
      throw new StreamError('The chunk is empty or invalid');
    }
    if (target.length() < end) {
      const found: number = target.length();
      target.close();
      throw new StreamError(`invalid file length. expected = ${end}  found = ${found}`);
    }
    target.seek(this.offset);
  }

  private src(): SharpStream {
    const source: SharpStream | null = this.source;
    if (source === null) {
      throw new StreamError('closed');
    }
    return source;
  }

  getFilePointer(): number {
    return this.offset + this.position;
  }

  read(): number {
    if (this.position + 1 > this.chunkLength) {
      return 0;
    }
    const res: number = this.src().read();
    if (res >= 0) {
      this.position = this.position + 1;
    }
    return res;
  }

  readInto(buffer: Uint8Array, off: number, len: number): number {
    let count: number = len;
    if (this.position + count > this.chunkLength) {
      count = this.chunkLength - this.position;
    }
    if (count === 0) {
      return 0;
    }
    const res: number = this.src().readInto(buffer, off, count);
    this.position = this.position + res;
    const report: ProgressReport | null = this.onProgress;
    if (report !== null && this.position > this.progressReport) {
      report(this.position);
      this.progressReport = this.position + REPORT_INTERVAL;
    }
    return res;
  }

  skip(amount: number): number {
    const pos: number = Math.min(amount + this.position, this.chunkLength);
    if (pos === 0) {
      return 0;
    }
    this.src().seek(this.offset + pos);
    const oldPos: number = this.position;
    this.position = pos;
    return pos - oldPos;
  }

  available(): number {
    return this.chunkLength - this.position;
  }

  close(): void {
    const source: SharpStream | null = this.source;
    if (source !== null) {
      source.close();
    }
    this.source = null;
  }

  isClosed(): boolean {
    return this.source === null;
  }

  rewind(): void {
    this.position = 0;
    this.src().seek(this.offset);
  }

  canRewind(): boolean {
    return true;
  }

  canRead(): boolean {
    return true;
  }

  canWrite(): boolean {
    return false;
  }

  writeByte(value: number): void {
  }

  writeFrom(buffer: Uint8Array, offset: number, count: number): void {
  }
}
