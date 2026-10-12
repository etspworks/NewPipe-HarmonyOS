/*
 * Port of org.schabi.newpipe.extractor.utils.RandomStringFromAlphabetGenerator
 * (NewPipeExtractor v0.26.5).
 *
 * Java takes a java.util.Random (a SecureRandom at the one call site, YoutubeParsingHelper);
 * ArkTS has no such type, so the source of randomness is the injected function and defaults to
 * Math.random.
 */

/**
 * A random string of `length` characters, made only of characters from `alphabet`.
 */
export function generateRandomStringFromAlphabet(alphabet: string, length: number,
  nextRandom: () => number = Math.random): string {
  let generated: string = '';
  for (let i = 0; i < length; i++) {
    generated += alphabet.charAt(Math.floor(nextRandom() * alphabet.length));
  }
  return generated;
}
