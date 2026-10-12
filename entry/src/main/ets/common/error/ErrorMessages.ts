/*
 * The user-facing text for an extractor failure.
 *
 * The source never shows a raw exception message: ExceptionUtils maps the type to a string, so a
 * parse failure reads "Could not parse website" wherever it happens. The port was handing
 * `error.message` straight to the screens, which is why a kiosk that failed to parse showed
 * "Could not get channel name" - the literal a YoutubeChannelHelper throw carries.
 *
 * Only the base ParsingException is mapped. Its subclasses - content not available, not supported,
 * age restricted, paid, geo-blocked - carry a meaning of their own and their messages are what the
 * user should read, so they fall through untouched.
 */

import {
  ExtractionException,
  IOException,
  ParsingException
} from '../extractor/exceptions/Exceptions';
import { Localization } from '../i18n/Localization';

/** How far down a cause chain to look before giving up; also the guard against a cycle. */
const MAX_CAUSE_DEPTH: number = 8;

/**
 * Port of ExceptionUtils.isNetworkRelated(throwable): the transport failure is rarely the
 * exception the screen is handed. An extractor that cannot reach the service catches the
 * IOException and rethrows its own ParsingException - "Could not resolve id with embedded
 * player" and the like - keeping the original as the cause. Reading only the top of the chain
 * therefore reports a parse failure for what is plainly a dead network.
 */
function isNetworkRelated(err: Error): boolean {
  let walk: Error | null = err;
  let depth: number = 0;
  while (walk !== null && depth < MAX_CAUSE_DEPTH) {
    if (walk instanceof IOException) {
      return true;
    }
    walk = walk instanceof ExtractionException ? walk.getCause() : null;
    depth = depth + 1;
  }
  return false;
}

export function userMessageFor(err: Error): string {
  // Anything the transport could not complete: no route, no DNS, timeout, reset. The stack's own
  // wording is accurate and useless to a reader, so the source shows one string for all of them.
  // Checked FIRST and through the whole cause chain: a page that did not parse because the
  // network was down is a network failure, not a parse failure.
  if (isNetworkRelated(err)) {
    return Localization.getString('network_error');
  }
  // constructor identity, not instanceof: every meaningful failure extends ParsingException, and
  // only the bare one means "the page did not parse".
  if (err instanceof ParsingException && (err as object).constructor === ParsingException) {
    return Localization.getString('parsing_error');
  }
  return err.message;
}
