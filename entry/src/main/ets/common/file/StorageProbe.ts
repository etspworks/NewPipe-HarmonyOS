/*
 * svc_storage_probe - answers "what of the user's storage can this app actually reach", once,
 * from measurement rather than assumption.
 *
 * It exists because the T-0183 probe (docs/qa/evidence/fix-T-0183/probe.txt) concluded "there is
 * no wider tree to offer" from calls made with NO file permission declared. 13900001 is E_PERM:
 * it is exactly what a missing ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY produces, so that
 * measurement could not support the conclusion drawn from it.
 *
 * Rule 8: every descriptor opened here is closed in finally. This one opens none.
 */

import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { PermissionHelper } from '../perm/PermissionHelper';

/** What one probe run found. Everything here is measured; nothing is inferred. */
export class ProbeResult {
  /** Whether FILE_ACCESS_PERSIST is held at the time of the run. */
  permissionGranted: boolean = false;
  /** The public Download directory as a plain path, or '' when it could not be derived. */
  publicRoot: string = '';
  /** Whether fileIo can list publicRoot. */
  rootListable: boolean = false;
  /** Whether fileIo can create a directory under publicRoot. */
  rootWritable: boolean = false;
  /** Whether the app's own Download/<bundle> subtree is listable - the status quo. */
  bundleDirListable: boolean = false;
  /** One line per call, with its error code. This is what gets pasted into probe2.txt. */
  notes: string[] = [];
}

const PROBE_DIR: string = 't0183b_probe';

function errCode(err: BusinessError): string {
  return err.code === undefined ? err.message : String(err.code);
}

/**
 * The app's directory inside the public Download folder, as a plain path.
 * DocumentViewPicker.save() in DOWNLOAD mode shows no screen and needs no permission; it returns
 * file://docs/storage/Users/<user>/Download/<bundle>. The uri is unusable with fileIo (13900002),
 * the path behind it is not - see docs/qa/evidence/fix-T-0183/probe.txt.
 */
async function bundleDownloadDir(ctx: common.UIAbilityContext): Promise<string> {
  const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
  options.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
  const uris: string[] = await new picker.DocumentViewPicker(ctx).save(options);
  if (uris.length === 0) {
    return '';
  }
  const prefix: string = 'file://docs';
  const uri: string = uris[0];
  const path: string = uri.startsWith(prefix) ? uri.substring(prefix.length) : uri;
  return path.startsWith('/') ? path : '';
}

/** The parent of Download/<bundle>, i.e. the public Download directory itself. */
export function publicRootOf(bundleDir: string): string {
  const cleaned: string = bundleDir.endsWith('/')
    ? bundleDir.substring(0, bundleDir.length - 1) : bundleDir;
  const slash: number = cleaned.lastIndexOf('/');
  return slash <= 0 ? '' : cleaned.substring(0, slash);
}

export async function probeStorage(ctx: common.UIAbilityContext,
  permissions: PermissionHelper): Promise<ProbeResult> {
  const result: ProbeResult = new ProbeResult();
  const notes: string[] = result.notes;
  // READ_WRITE_DOWNLOAD_DIRECTORY is no longer declared - requesting it answered
  // authResults=2 ("the request is invalid") and widened nothing. See probe2.txt. The probe
  // reports the state it runs in rather than trying to change it.
  result.permissionGranted =
    await permissions.isPermissionGranted('ohos.permission.FILE_ACCESS_PERSIST');
  notes.push('FILE_ACCESS_PERSIST granted = ' + result.permissionGranted);

  let bundleDir: string = '';
  try {
    bundleDir = await bundleDownloadDir(ctx);
    notes.push('DocumentViewPicker.save(DOWNLOAD) -> ' + bundleDir);
  } catch (err) {
    notes.push('DocumentViewPicker.save(DOWNLOAD) -> THREW ' + errCode(err as BusinessError));
  }

  if (bundleDir.length > 0) {
    try {
      const entries: string[] = fileIo.listFileSync(bundleDir);
      result.bundleDirListable = true;
      notes.push('list ' + bundleDir + ' -> ' + entries.length + ' entries');
    } catch (err) {
      notes.push('list ' + bundleDir + ' -> THREW ' + errCode(err as BusinessError));
    }
  }

  const root: string = publicRootOf(bundleDir);
  result.publicRoot = root;
  if (root.length > 0) {
    try {
      const entries: string[] = fileIo.listFileSync(root);
      result.rootListable = true;
      notes.push('list ' + root + ' -> ' + entries.length + ' entries: ' + entries.join(', '));
    } catch (err) {
      notes.push('list ' + root + ' -> THREW ' + errCode(err as BusinessError));
    }
    const probeDir: string = root + '/' + PROBE_DIR;
    try {
      fileIo.mkdirSync(probeDir);
      result.rootWritable = true;
      notes.push('mkdir ' + probeDir + ' -> OK');
      fileIo.rmdirSync(probeDir);
      notes.push('rmdir ' + probeDir + ' -> OK (probe left no trace)');
    } catch (err) {
      notes.push('mkdir ' + probeDir + ' -> THREW ' + errCode(err as BusinessError));
    }
    // One level higher still, so the answer is not only about Download.
    const above: string = publicRootOf(root);
    if (above.length > 0) {
      try {
        const entries: string[] = fileIo.listFileSync(above);
        notes.push('list ' + above + ' -> ' + entries.length + ' entries: ' + entries.join(', '));
      } catch (err) {
        notes.push('list ' + above + ' -> THREW ' + errCode(err as BusinessError));
      }
    }
  }
  return result;
}
