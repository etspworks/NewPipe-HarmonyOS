/**
 * TC-KIOSK-179: what the popup shows when the stream carries NO VIDEO.
 *
 * A PiP window mirrors the XComponent's SURFACE, not the ArkUI tree composed above it - measured on
 * this board: after the in-app cover fix the player drew the artwork and the PiP window's mean
 * luminance was still 0.0. So the cover cannot be painted into the page and expected to appear in
 * the popup.
 *
 * PiPConfiguration.customUIController is the one lever that reaches inside the window - "a custom
 * layout above pip content". This is that layout: the stream's own artwork over the black surface.
 * PlayerService decides WHETHER to use it (only an audio-only stream needs it) and this decides
 * what it looks like, because a NodeController wraps a @Builder and a .ts file cannot declare one.
 */
import { BuilderNode, FrameNode, NodeController, UIContext } from '@kit.ArkUI';
import { PlayerService } from '../common/player/PlayerService';

@Builder
function pipCover(url: string) {
  Image(url)
    .width('100%')
    .height('100%')
    .objectFit(ImageFit.Contain)
    .backgroundColor($r('app.color.background'))
}

export class PipCoverNode extends NodeController {
  private node: BuilderNode<[string]> | null = null;

  makeNode(context: UIContext): FrameNode | null {
    const url: string = PlayerService.getInstance().pipCoverUrl();
    const node: BuilderNode<[string]> = new BuilderNode(context);
    node.build(wrapBuilder(pipCover), url);
    this.node = node;
    return node.getFrameNode();
  }
}
