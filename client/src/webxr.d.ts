/**
 * webxr.d.ts — Ambient WebXR type declarations for ImmersiveRT (SENS-V2-03).
 *
 * The project's `tsconfig.json` lib list (`ES2020`, `DOM`, `DOM.Iterable`)
 * does NOT ship WebXR types, so `navigator.xr` is untyped by default. This
 * file hand-writes just-enough ambient declarations for the small subset of
 * the WebXR Device API that `client/src/sensor/webxr.ts` uses — following
 * this project's existing minimal-type-surface style (see `client/src/types.ts`)
 * rather than adding an `@types/webxr` dependency
 * (RESEARCH.md Open Questions #1, option (a)).
 *
 * Only the pose-tracking subset is declared. Raw-camera-pixel WebXR features
 * (e.g. `camera-access`) are intentionally NOT declared here — they are out
 * of scope for this phase (see threat_model T-06.1-01 in 06.1-01-PLAN.md).
 */

interface XRSystem {
  isSessionSupported(mode: string): Promise<boolean>;
  requestSession(mode: string, init?: object): Promise<XRSession>;
}

interface Navigator {
  readonly xr?: XRSystem;
}

interface XRSession {
  requestReferenceSpace(type: string): Promise<XRReferenceSpace>;
  requestAnimationFrame(cb: (time: number, frame: XRFrame) => void): number;
  updateRenderState(state: object): Promise<void>;
  end(): Promise<void>;
  addEventListener(type: string, listener: () => void): void;
  readonly domOverlayState?: { type?: string };
}

interface XRReferenceSpace {}

interface XRFrame {
  getViewerPose(refSpace: XRReferenceSpace): XRViewerPose | null;
  readonly session: XRSession;
}

interface XRRigidTransform {
  readonly position: { x: number; y: number; z: number };
}

interface XRPose {
  readonly transform: XRRigidTransform;
  readonly emulatedPosition: boolean;
}

interface XRViewerPose extends XRPose {}

declare var XRWebGLLayer: {
  new (session: XRSession, ctx: WebGLRenderingContext): object;
};
