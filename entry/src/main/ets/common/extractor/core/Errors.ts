/*
 * ArkTS forbids a type annotation on a catch binding, and anything can be thrown, while the
 * ported extractor collects `List<Throwable>`. This is the one narrowing every collector and
 * every Info mapper uses.
 */

import { BusinessError } from '@kit.BasicServicesKit';

/** What `${plainObject}` renders as, and what every caller was showing the user. */
const OPAQUE: string = '[object Object]';

export function toError(thrown: Object): Error {
  if (thrown instanceof Error) {
    return thrown as Error;
  }
  /*
   * A HarmonyOS BusinessError is a PLAIN OBJECT, not an Error: it fails `instanceof`, and
   * template-stringifying it yields "[object Object]" - which is what this function used to hand
   * to its callers, and what they then put in front of the user. Its own fields are the message.
   */
  const business: BusinessError = thrown as BusinessError;
  const message: string | undefined = business.message;
  const code: number | undefined = business.code;
  let text: string = message === undefined || message === null || message.length === 0
    ? `${thrown}` : message;
  if (text === OPAQUE) {
    // Not a BusinessError either. Its fields are still a better description than the tag is.
    try {
      text = JSON.stringify(thrown);
    } catch (err) {
      text = OPAQUE;
    }
  }
  return new Error(code === undefined || code === null ? text : `${text} (${code})`);
}
