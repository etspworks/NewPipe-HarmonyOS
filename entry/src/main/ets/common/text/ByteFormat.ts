/*
 * Port of org.schabi.newpipe.util.Utility.formatBytes(): the size string the Downloads list and
 * the Download dialog both show.
 *
 * It lived as a private static on MissionsFragmentPage, so the Download dialog grew its own
 * one-decimal MB-only version and reported "3905.3 MB" where the reference reads "3.81 GB"
 * (TC-LIBRARY-006). One implementation, two call sites.
 */

const KB: number = 1024;
const MB: number = 1048576;
const GB: number = 1073741824;

/** B under 1 kB, then kB / MB / GB with two decimals, exactly as the source steps them. */
export function formatBytes(bytes: number): string {
  if (bytes < KB) {
    return `${bytes} B`;
  }
  if (bytes < MB) {
    return `${(bytes / KB).toFixed(2)} kB`;
  }
  if (bytes < GB) {
    return `${(bytes / MB).toFixed(2)} MB`;
  }
  return `${(bytes / GB).toFixed(2)} GB`;
}
