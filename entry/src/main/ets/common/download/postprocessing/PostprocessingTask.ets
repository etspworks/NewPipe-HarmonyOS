/*
 * DownloadMission.doPostprocessing()'s worker thread: the muxers block on file I/O for the length
 * of the download, so they run in a taskpool LongTask (no 3-minute cap) and report the read
 * position back for the row's percentage. An .ets module because @Concurrent is ArkTS-only;
 * EntryAbility hands runPostprocessingInTaskpool to the .ts DownloadManager.
 */

import { taskpool } from '@kit.ArkTS';
import { PostprocessingJob, runPostprocessingJob } from './Postprocessing';

@Concurrent
function postprocess(job: PostprocessingJob): string {
  return runPostprocessingJob(job, (position: number): void => {
    taskpool.Task.sendData(position);
  });
}

export async function runPostprocessingInTaskpool(job: PostprocessingJob,
  onProgress: (done: number) => void): Promise<string> {
  const task: taskpool.LongTask = new taskpool.LongTask(postprocess, job);
  task.onReceiveData((position: number): void => {
    onProgress(position);
  });
  try {
    return await taskpool.execute(task) as string;
  } finally {
    taskpool.terminateTask(task);
  }
}
