/*
 * Port of us.shandian.giga.postprocessing.Postprocessing: the algorithm table and run().
 *
 * One deliberate change: the source writes the result back into the mission's own file while it
 * is still reading from it (CircularFileWriter), so a SAF tree never needs room for a second
 * copy. Here the result goes to a temp file in the app cache first and is then copied over the
 * download, so a failure while muxing leaves the downloaded parts untouched and Retry can run it
 * again. ponytail: costs the result's size in cache space for the duration; port
 * CircularFileWriter if cache space ever becomes the limit.
 *
 * Runs synchronously: PostprocessingTask.ets calls it inside a taskpool LongTask.
 */

import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ChunkFileInputStream } from './ChunkFileInputStream';
import { FileSharpStream } from './FileSharpStream';
import { ProgressReport, SharpStream } from './SharpStream';
import { m4aNoDash, m4aNoDashTest, muxMp4FromDash } from './Mp4Algorithms';
import { muxWebM, oggFromWebm, oggFromWebmTest } from './WebMAlgorithms';
import { OggStreamInfo } from './OggFromWebMWriter';
import { ttmlToSrt } from './TtmlAlgorithm';

export const ALGORITHM_TTML_CONVERTER: string = 'ttml';
export const ALGORITHM_WEBM_MUXER: string = 'webm';
export const ALGORITHM_MP4_FROM_DASH_MUXER: string = 'mp4D-mp4';
export const ALGORITHM_M4A_NO_DASH: string = 'mp4D-m4a';
export const ALGORITHM_OGG_FROM_WEBM_DEMUXER: string = 'webm-ogg-d';

/** What the taskpool worker needs; plain fields only, it is copied across threads. */
export class PostprocessingJob {
  name: string;
  args: string[];
  /** The mission's file: every url's bytes, back to back from offsets[i]. */
  fileUri: string;
  offsets: number[];
  /** Where the result is built before it replaces the download. */
  tempPath: string;
  /** DownloadMission.psStreamInfo: what the Opus tags carry. */
  streamInfo: string[];

  constructor(name: string, args: string[], fileUri: string, offsets: number[], tempPath: string,
    streamInfo: string[]) {
    this.name = name;
    this.args = args;
    this.fileUri = fileUri;
    this.offsets = offsets;
    this.tempPath = tempPath;
    this.streamInfo = streamInfo;
  }
}

/** The StreamInfo the source hands OggFromWebMWriter, rebuilt from the mission's record. */
function oggStreamInfoOf(fields: string[]): OggStreamInfo | null {
  if (fields.length < 5) {
    return null;
  }
  const info: OggStreamInfo = new OggStreamInfo();
  info.url = fields[0];
  info.category = fields[1];
  info.uploaderName = fields[2];
  info.name = fields[3];
  const date: number = Number(fields[4]);
  info.uploadDate = fields[4].length === 0 || isNaN(date) ? null : date;
  return info;
}

/** The worker's answer: 'ok:<final length or -1>', 'hold:<why>' (retryable) or 'fail:<why>'. */
export const RESULT_OK: string = 'ok:';
export const RESULT_HOLD: string = 'hold:';
export const RESULT_FAIL: string = 'fail:';

function argumentAt(args: string[], index: number, defaultValue: string): string {
  return index < args.length ? args[index] : defaultValue;
}

/** Postprocessing.test(): false means the file is already what the algorithm would make. */
function needsProcessing(name: string, sources: SharpStream[]): boolean {
  if (name === ALGORITHM_M4A_NO_DASH) {
    return m4aNoDashTest(sources[0]);
  }
  if (name === ALGORITHM_OGG_FROM_WEBM_DEMUXER) {
    return oggFromWebmTest(sources[0]);
  }
  return true;
}

/** process(out, sources) of each algorithm. */
function processWith(job: PostprocessingJob, out: SharpStream, sources: SharpStream[]): void {
  const name: string = job.name;
  const args: string[] = job.args;
  if (name === ALGORITHM_MP4_FROM_DASH_MUXER) {
    muxMp4FromDash(out, sources);
  } else if (name === ALGORITHM_WEBM_MUXER) {
    muxWebM(out, sources);
  } else if (name === ALGORITHM_M4A_NO_DASH) {
    m4aNoDash(out, sources[0]);
  } else if (name === ALGORITHM_OGG_FROM_WEBM_DEMUXER) {
    oggFromWebm(out, sources[0], oggStreamInfoOf(job.streamInfo));
  } else if (name === ALGORITHM_TTML_CONVERTER) {
    // TtmlConverter: args = [source format, ignore empty frames]; an srt source is copied as-is.
    const format: string = argumentAt(args, 0, ALGORITHM_TTML_CONVERTER);
    if (format === 'srt') {
      copyAll(sources[0], out);
    } else {
      ttmlToSrt(out, sources[0], argumentAt(args, 1, 'true') === 'true');
    }
  } else {
    throw new Error('Unimplemented post-processing algorithm: ' + name);
  }
}

function copyAll(from: SharpStream, to: SharpStream): void {
  const buffer: Uint8Array = new Uint8Array(64 * 1024);
  let read: number = from.readInto(buffer, 0, buffer.length);
  while (read > 0) {
    to.writeFrom(buffer, 0, read);
    read = from.readInto(buffer, 0, buffer.length);
  }
}

/** A write that failed for want of room is the source's ERROR_POSTPROCESSING_HOLD. */
function isOutOfSpace(err: Error): boolean {
  // 13900033: fileIo's "No space left on device".
  return (err as BusinessError).code === 13900033 || /space|ENOSPC/i.test(err.message);
}

/** Copies the finished result over the download, then trims the download to its length. */
function replaceDownload(fd: number, tempPath: string): number {
  const temp: fileIo.File = fileIo.openSync(tempPath, fileIo.OpenMode.READ_ONLY);
  try {
    const buffer: ArrayBuffer = new ArrayBuffer(1024 * 1024);
    let position: number = 0;
    let read: number = fileIo.readSync(temp.fd, buffer, { offset: position });
    while (read > 0) {
      fileIo.writeSync(fd, read === buffer.byteLength ? buffer : buffer.slice(0, read),
        { offset: position });
      position = position + read;
      read = fileIo.readSync(temp.fd, buffer, { offset: position });
    }
    fileIo.truncateSync(fd, position);
    return position;
  } finally {
    fileIo.closeSync(temp);
  }
}

/** Postprocessing.run(mission): the whole job, on the calling (worker) thread. */
export function runPostprocessingJob(job: PostprocessingJob, onProgress: ProgressReport | null):
  string {
  let file: fileIo.File | null = null;
  const sources: ChunkFileInputStream[] = [];
  let out: FileSharpStream | null = null;
  try {
    file = fileIo.openSync(job.fileUri, fileIo.OpenMode.READ_WRITE);
    const fd: number = file.fd;
    const total: number = fileIo.statSync(fd).size;
    const first: number = job.offsets.length > 0 ? job.offsets[0] : 0;
    const readProgress: ProgressReport = (position: number): void => {
      if (onProgress !== null) {
        onProgress(position - first);
      }
    };
    for (let i: number = 0; i < job.offsets.length; i++) {
      const end: number = i + 1 < job.offsets.length ? job.offsets[i + 1] : total;
      // Every source reads the one descriptor with its own position (pread), so none owns it.
      sources.push(new ChunkFileInputStream(new FileSharpStream(fd, false), job.offsets[i], end,
        readProgress));
    }
    if (!needsProcessing(job.name, sources)) {
      return RESULT_OK + '-1';
    }
    for (const source of sources) {
      source.rewind();
    }
    try {
      out = FileSharpStream.open(job.tempPath, true);
      processWith(job, out, sources);
      out.flush();
      out.close();
      out = null;
    } catch (err) {
      const failure: Error = err as Error;
      return (isOutOfSpace(failure) ? RESULT_HOLD : RESULT_FAIL) + failure.message;
    }
    return RESULT_OK + replaceDownload(fd, job.tempPath).toString();
  } catch (err) {
    return RESULT_FAIL + (err as Error).message;
  } finally {
    for (const source of sources) {
      if (!source.isClosed()) {
        source.close();
      }
    }
    if (out !== null) {
      try {
        out.close();
      } catch (closeErr) {
        // the job already failed; the temp file goes below
      }
    }
    if (file !== null) {
      fileIo.closeSync(file);
    }
    try {
      if (fileIo.accessSync(job.tempPath)) {
        fileIo.unlinkSync(job.tempPath);
      }
    } catch (unlinkErr) {
      // a leftover temp file is cleared by the next job with the same name
    }
  }
}
