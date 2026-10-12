/*
 * Port of org.schabi.newpipe.extractor.services.youtube.DeliveryType (NewPipeExtractor v0.26.5).
 *
 * YouTube's own streaming format type. NOT the same thing as model/enums/DeliveryMethod.
 */
export enum DeliveryType {
  /** Progressive delivery, driven by HTTP range headers. */
  PROGRESSIVE,
  /**
   * OTF: segments fetched with a `&sq=` sequence parameter, the first sequence carrying all the
   * metadata needed to build the source. Videos only.
   */
  OTF,
  /** Livestream delivery: every sequence carries its own metadata, so no init segment. */
  LIVE
}
