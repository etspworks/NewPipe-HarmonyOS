/*
 * Port of org.schabi.newpipe.extractor.stream.Frameset (NewPipeExtractor v0.26.5).
 *
 * A storyboard of seekbar preview frames: N frames laid out framesPerPageX by framesPerPageY on
 * each url. Not declared in the plan's models[] (plan defect, reported); this file is the
 * canonical one the player lane's SeekbarPreview binds to.
 */

/** The five numbers getFrameBoundsAt returns, in the source's own order. */
export class FrameBounds {
  readonly storyboardIndex: number;
  readonly left: number;
  readonly top: number;
  readonly right: number;
  readonly bottom: number;

  constructor(storyboardIndex: number, left: number, top: number, right: number, bottom: number) {
    this.storyboardIndex = storyboardIndex;
    this.left = left;
    this.top = top;
    this.right = right;
    this.bottom = bottom;
  }
}

export class Frameset {
  readonly urls: string[];
  readonly frameWidth: number;
  readonly frameHeight: number;
  readonly totalCount: number;
  readonly durationPerFrame: number;
  readonly framesPerPageX: number;
  readonly framesPerPageY: number;

  constructor(urls: string[], frameWidth: number, frameHeight: number, totalCount: number,
    durationPerFrame: number, framesPerPageX: number, framesPerPageY: number) {
    this.urls = urls;
    this.totalCount = totalCount;
    this.durationPerFrame = durationPerFrame;
    this.frameWidth = frameWidth;
    this.frameHeight = frameHeight;
    this.framesPerPageX = framesPerPageX;
    this.framesPerPageY = framesPerPageY;
  }

  getUrls(): string[] {
    return this.urls;
  }

  getTotalCount(): number {
    return this.totalCount;
  }

  getFramesPerPageX(): number {
    return this.framesPerPageX;
  }

  getFramesPerPageY(): number {
    return this.framesPerPageY;
  }

  getFrameWidth(): number {
    return this.frameWidth;
  }

  getFrameHeight(): number {
    return this.frameHeight;
  }

  getDurationPerFrame(): number {
    return this.durationPerFrame;
  }

  /** Which storyboard, and where inside it, the frame at `position` milliseconds sits. */
  getFrameBoundsAt(position: number): FrameBounds {
    if (position < 0 || position > (this.totalCount + 1) * this.durationPerFrame) {
      // Return the first frame as fallback
      return new FrameBounds(0, 0, 0, this.frameWidth, this.frameHeight);
    }

    const framesPerStoryboard: number = this.framesPerPageX * this.framesPerPageY;
    const absoluteFrameNumber: number =
      Math.min(Math.trunc(position / this.durationPerFrame), this.totalCount);

    const relativeFrameNumber: number = absoluteFrameNumber % framesPerStoryboard;

    const rowIndex: number = Math.floor(relativeFrameNumber / this.framesPerPageX);
    const columnIndex: number = relativeFrameNumber % this.framesPerPageY;

    return new FrameBounds(
      Math.floor(absoluteFrameNumber / framesPerStoryboard),
      columnIndex * this.frameWidth,
      rowIndex * this.frameHeight,
      columnIndex * this.frameWidth + this.frameWidth,
      rowIndex * this.frameHeight + this.frameHeight);
  }
}
