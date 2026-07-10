/**
 * scene.ts — Three.js scene lifecycle for ImmersiveRT desktop game view.
 *
 * initScene(canvas, container): Set up renderer, camera, lights, grid, CSS2DRenderer.
 *   Guarded by sceneInitialized — safe to call on every player-ready event (Pitfall 2).
 *   CSS2DRenderer domElement appended into `container` (#game-container), NOT document.body
 *   (Pitfall 5: must share the same positioned container as the WebGL canvas).
 *
 * addPlayerToScene(phoneId, slot, username): Create box mesh with per-slot HSL color,
 *   CSS2DObject name label (textContent only — XSS guard, T-06-10), AxesHelper child,
 *   and motion trail ring buffer (plan 05). All allocated once; no per-frame alloc (Pitfall 6).
 *
 * removePlayerFromScene(phoneId): Dispose and remove the mesh (+ label + axes + trail)
 *   from the scene and release GPU resources.
 *
 * updateScene() [private, called from rAF]: SLERP each player's mesh quaternion at
 *   SLERP_ALPHA = 0.3 (D-12). Also: touch flash (100ms emissive burst — D-14), motion
 *   trail ring buffer update, and numeric HUD textContent update — all inside the single
 *   rAF loop, no new loop, no per-frame THREE allocation (T-06-12, Pitfall 6).
 *
 * Toggle setters: toggleGrid / toggleAxes / toggleTrail / toggleNumericHud — all use
 *   .visible (never add/remove, per Pitfall 4).
 * getToggleStates(): returns current booleans + positionModeLabel for HUD key-hint line.
 * cyclePositionMode(): toggles gesture/deadReckoning, returns user-facing mode label.
 */

import * as THREE from 'three';
import { CSS2DRenderer, CSS2DObject } from 'three/examples/jsm/renderers/CSS2DRenderer.js';
import { targetStateStore } from './playerStore';

// ──────────────────────────────────────────────────────────────────────────────
// Trail constants (Pattern 8 ring buffer — PATTERNS.md)
// ──────────────────────────────────────────────────────────────────────────────
const TRAIL_POINTS = 30;

// ──────────────────────────────────────────────────────────────────────────────
// TrailHandle — allocated ONCE per player in addPlayerToScene (Pitfall 6)
// ──────────────────────────────────────────────────────────────────────────────
interface TrailHandle {
  line: THREE.Line;
  positions: Float32Array; // ring buffer: TRAIL_POINTS * 3 floats (x, y, z interleaved)
  head: number;            // write index (0 … TRAIL_POINTS-1), advances modulo TRAIL_POINTS
}

// ──────────────────────────────────────────────────────────────────────────────
// PlayerObject interface
//   plan 03: mesh only
//   plan 04: adds label, axes, flashing
//   plan 05: adds trail, slot, username
// ──────────────────────────────────────────────────────────────────────────────
export interface PlayerObject {
  mesh: THREE.Mesh;
  label: CSS2DObject;
  axes: THREE.AxesHelper;
  flashing: boolean;
  trail: TrailHandle;
  slot: number;
  username: string;
}

// ──────────────────────────────────────────────────────────────────────────────
// Module-level renderer singletons — allocated ONCE (Pitfall 6)
// ──────────────────────────────────────────────────────────────────────────────
let renderer: THREE.WebGLRenderer;
let labelRenderer: CSS2DRenderer;
let scene: THREE.Scene;
let camera: THREE.PerspectiveCamera;

// Grid floor reference — saved in initScene so toggleGrid() can flip .visible
// Never re-add to scene (Pitfall 4: toggle-via-visible pattern)
let gridRef: THREE.GridHelper | null = null;

// Guards: player-ready fires once per phone — must init only once (Pitfall 2, T-06-08)
let sceneInitialized = false;
let animRunning = false;

// Per-player 3D objects — populated by addPlayerToScene()
const playerObjects = new Map<string, PlayerObject>();

// Module-scope scratch quaternion — allocated ONCE here, mutated in updateScene() each frame.
// Never allocate a Quaternion inside animate() or updateScene() (Pitfall 6: no per-frame GC).
const scratchQuat = new THREE.Quaternion();

// SLERP alpha: 0.3 per frame (D-12 — smooth but responsive)
const SLERP_ALPHA = 0.3;

// Active position display mode (D-13 default: gestureDisplacement)
let positionMode: 'gesture' | 'deadReckoning' = 'gesture';

// ──────────────────────────────────────────────────────────────────────────────
// Toggle states (D-15 defaults: grid on, axes on, numeric HUD on, trail off)
// ──────────────────────────────────────────────────────────────────────────────
let gridVisible = true;
let axesVisible = true;
let numericHudVisible = true;
let trailVisible = false;

// Cached reference to numeric HUD element — set once in initScene to avoid
// per-frame getElementById lookups inside updateScene (performance guard)
let hudPlayersEl: HTMLElement | null = null;

// ──────────────────────────────────────────────────────────────────────────────
// Private: per-slot HSL color (Pattern 7 / UI-SPEC slot color formula)
// ──────────────────────────────────────────────────────────────────────────────
function slotColor(slot: number): THREE.Color {
  // Slot 1→8 maps to hue range [0, 7/8) with fixed saturation + lightness
  return new THREE.Color().setHSL((slot - 1) / 8, 0.7, 0.55);
}

// ──────────────────────────────────────────────────────────────────────────────
// Private: trail factory — allocate ring buffer + BufferGeometry ONCE per player
//   (Pattern 8 from PATTERNS.md / RESEARCH.md)
// ──────────────────────────────────────────────────────────────────────────────
function createTrail(color: THREE.Color): TrailHandle {
  const positions = new Float32Array(TRAIL_POINTS * 3); // pre-allocated ring buffer
  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute('position', new THREE.BufferAttribute(positions, 3));
  const material = new THREE.LineBasicMaterial({ color, transparent: true, opacity: 0.5 });
  const line = new THREE.Line(geometry, material);
  line.visible = false; // off by default (D-15: trail starts hidden)
  return { line, positions, head: 0 };
}

// Private: push one position into the trail ring buffer — no allocation (Pitfall 6)
function updateTrail(trail: TrailHandle, x: number, y: number, z: number): void {
  trail.positions[trail.head * 3]     = x;
  trail.positions[trail.head * 3 + 1] = y;
  trail.positions[trail.head * 3 + 2] = z;
  trail.head = (trail.head + 1) % TRAIL_POINTS;
  // Mark BufferAttribute dirty so WebGL re-uploads the positions this frame
  (trail.line.geometry.attributes['position'] as THREE.BufferAttribute).needsUpdate = true;
}

// ──────────────────────────────────────────────────────────────────────────────
// Private: update scene from player state each rAF tick
//   (a) SLERP orientation     — always
//   (b) Position update       — always
//   (c) Touch flash           — when state.touchActive && !obj.flashing (D-14, T-06-12)
//   (d) Trail ring buffer     — when trailVisible (Pattern 8, no alloc)
//   (e) Numeric HUD text      — when numericHudVisible (textContent only, T-06-10b)
// ──────────────────────────────────────────────────────────────────────────────
function updateScene(): void {
  let hudText = '';

  for (const [phoneId, obj] of playerObjects) {
    const state = targetStateStore.get(phoneId);
    if (!state) { continue; }

    // (a) SLERP toward latest decoded orientation (D-12, DESK-05).
    // scratchQuat.set(x, y, z, w) — THREE.Quaternion uses (x, y, z, w) where w is scalar.
    // SensorPacket stores (qw, qx, qy, qz) so we pass (qx, qy, qz, qw) here (plan 04 fix).
    obj.mesh.quaternion.slerp(
      scratchQuat.set(state.qx, state.qy, state.qz, state.qw),
      SLERP_ALPHA
    );

    // (b) Update position from active mode (D-13)
    if (positionMode === 'gesture') {
      obj.mesh.position.set(state.dx, state.dy, state.dz);
    } else {
      obj.mesh.position.set(state.px, state.py, state.pz);
    }

    // (c) Touch flash — D-14: instant 100ms white emissive burst when phone touch is active.
    // Guard with obj.flashing to prevent re-triggering while flash is still in progress.
    // setHex on the emissive Color mutates the existing material — no new allocation.
    if (state.touchActive && !obj.flashing) {
      obj.flashing = true;
      (obj.mesh.material as THREE.MeshStandardMaterial).emissive.setHex(0xffffff);
      setTimeout(function () {
        (obj.mesh.material as THREE.MeshStandardMaterial).emissive.setHex(0x000000);
        obj.flashing = false;
      }, 100);
    }

    // (d) Motion trail — push current mesh position into the preallocated ring buffer.
    // updateTrail() mutates existing Float32Array; sets needsUpdate — no per-frame alloc.
    if (trailVisible) {
      updateTrail(obj.trail, obj.mesh.position.x, obj.mesh.position.y, obj.mesh.position.z);
    }

    // (e) Numeric HUD — accumulate per-player diagnostic text (written once after loop)
    if (numericHudVisible) {
      const px = positionMode === 'gesture' ? state.dx : state.px;
      const py = positionMode === 'gesture' ? state.dy : state.py;
      const pz = positionMode === 'gesture' ? state.dz : state.pz;
      const modeLabel = positionMode === 'gesture' ? 'gesture' : 'dead-reckoning';
      // Format per UI-SPEC D-15: [Slot N — username], q:, pos:, drift: lines
      hudText +=
        '[Slot ' + obj.slot + ' — ' + obj.username + ']\n' +
        '  q: w=' + state.qw.toFixed(3) + ' x=' + state.qx.toFixed(3) +
               ' y=' + state.qy.toFixed(3) + ' z=' + state.qz.toFixed(3) + '\n' +
        '  pos: x=' + px.toFixed(2) + ' y=' + py.toFixed(2) + ' z=' + pz.toFixed(2) +
               '   [' + modeLabel + ']\n' +
        '  drift: ' + state.driftConfidence.toFixed(2) + '\n\n';
    }
  }

  // Write numeric HUD in ONE textContent assignment (T-06-10b: textContent-only guard)
  if (hudPlayersEl && numericHudVisible) {
    hudPlayersEl.textContent = hudText;
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Private: rAF loop
// ──────────────────────────────────────────────────────────────────────────────
function animate(): void {
  requestAnimationFrame(animate);
  updateScene();
  renderer.render(scene, camera);
  labelRenderer.render(scene, camera);
}

// ──────────────────────────────────────────────────────────────────────────────
// Private: resize handler — keep both renderers in sync with viewport
// ──────────────────────────────────────────────────────────────────────────────
function onWindowResize(): void {
  const w = window.innerWidth;
  const h = window.innerHeight;
  camera.aspect = w / h;
  camera.updateProjectionMatrix();
  renderer.setSize(w, h);
  labelRenderer.setSize(w, h);
}

// ──────────────────────────────────────────────────────────────────────────────
// Public API
// ──────────────────────────────────────────────────────────────────────────────

/**
 * Initialise the Three.js scene, renderer, camera, lights, and grid floor.
 * Starts the rAF loop once. Safe to call on every player-ready event —
 * guarded by sceneInitialized (Pitfall 2: player-ready fires once per phone).
 *
 * @param canvas     #game-canvas element (inside #game-container)
 * @param container  #game-container element (shared positioned wrapper for WebGL
 *                   canvas and CSS2DRenderer domElement — Pitfall 5)
 */
export function initScene(canvas: HTMLCanvasElement, container: HTMLElement): void {
  if (sceneInitialized) {
    console.info('[scene] already initialized — skipping duplicate player-ready init');
    return;
  }
  sceneInitialized = true;

  // Scene — background matches --color-bg (#111111)
  scene = new THREE.Scene();
  scene.background = new THREE.Color(0x111111);

  // Fixed perspective camera at (0, 1.5, 4) looking at origin (D-11: no orbit controls)
  const w = window.innerWidth;
  const h = window.innerHeight;
  camera = new THREE.PerspectiveCamera(60, w / h, 0.1, 1000);
  camera.position.set(0, 1.5, 4);
  camera.lookAt(0, 0, 0);

  // WebGL renderer
  renderer = new THREE.WebGLRenderer({ canvas, antialias: true });
  renderer.setSize(w, h);
  renderer.setPixelRatio(window.devicePixelRatio);

  // CSS2DRenderer for player name labels (D-11)
  // Appended into container (#game-container), NOT document.body — Pitfall 5
  labelRenderer = new CSS2DRenderer();
  labelRenderer.setSize(w, h);
  labelRenderer.domElement.style.position = 'absolute';
  labelRenderer.domElement.style.top = '0';
  labelRenderer.domElement.style.left = '0';
  labelRenderer.domElement.style.pointerEvents = 'none'; // labels must not intercept mouse
  container.appendChild(labelRenderer.domElement);

  // Lights
  scene.add(new THREE.AmbientLight(0xffffff, 0.6));
  const dirLight = new THREE.DirectionalLight(0xffffff, 0.8);
  dirLight.position.set(5, 10, 5);
  scene.add(dirLight);

  // Grid floor — save reference for toggleGrid() to flip .visible (Pitfall 4: never re-add)
  gridRef = new THREE.GridHelper(10, 10, 0x444444, 0x333333);
  scene.add(gridRef);

  // Cache numeric HUD element reference — avoids per-frame getElementById in updateScene
  hudPlayersEl = document.getElementById('game-hud-players');

  // Resize handler — keeps both renderers in sync with viewport
  window.addEventListener('resize', onWindowResize);

  // Start rAF loop once (animRunning guard prevents double-start — T-06-08)
  if (!animRunning) {
    animRunning = true;
    animate();
  }
}

/**
 * Add a player's 3D object to the scene.
 *
 * Creates a BoxGeometry(1,1,1) mesh with a per-slot HSL MeshStandardMaterial,
 * attaches a CSS2DObject name label (textContent only — T-06-10 XSS guard),
 * adds an AxesHelper(0.5) child (visible per current axesVisible state), and
 * creates a motion trail ring buffer (Line, hidden per current trailVisible state).
 *
 * All objects allocated once and stored in playerObjects map (no per-frame alloc — Pitfall 6).
 * Idempotent: if phoneId already has a scene object, returns immediately.
 *
 * @param phoneId  Unique identifier for this phone's peer connection
 * @param slot     Display slot (1–8) — determines HSL color (UI-SPEC slot color formula)
 * @param username Player name shown in the floating CSS2D label and numeric HUD
 */
export function addPlayerToScene(phoneId: string, slot: number, username: string): void {
  // Idempotency: do not re-add a player already in the scene
  if (playerObjects.has(phoneId)) { return; }

  const color = slotColor(slot);

  // Box mesh with per-slot HSL color (Pattern 7 / UI-SPEC)
  const geometry = new THREE.BoxGeometry(1, 1, 1);
  const material = new THREE.MeshStandardMaterial({ color });
  const mesh = new THREE.Mesh(geometry, material);
  scene.add(mesh);

  // Floating name label — CSS2DObject positioned above the box (D-11)
  // textContent (not direct HTML) prevents script injection via player name (T-06-10)
  const labelDiv = document.createElement('div');
  labelDiv.className = 'player-label';
  labelDiv.textContent = username;
  const label = new CSS2DObject(labelDiv);
  label.position.set(0, 1.2, 0); // 1.2 units above box center (UI-SPEC)
  mesh.add(label); // label is a child of mesh — follows it automatically

  // Axes helper to visualise orientation axes per player.
  // Apply current axesVisible state so late-joining players match existing toggle state.
  const axes = new THREE.AxesHelper(0.5);
  axes.visible = axesVisible; // Pitfall 4: set .visible, never re-add
  mesh.add(axes);

  // Motion trail ring buffer — pre-allocated Float32Array, default hidden (D-15: trail off)
  // Apply current trailVisible state so late-joining players match existing toggle state.
  const trail = createTrail(color);
  trail.line.visible = trailVisible; // Pitfall 4: .visible matches current state
  scene.add(trail.line); // trail is a sibling of mesh in the scene (not a child)

  playerObjects.set(phoneId, { mesh, label, axes, flashing: false, trail, slot, username });
}

/**
 * Remove a player's 3D object from the scene and dispose GPU resources.
 *
 * The label (CSS2DObject) and axes (AxesHelper) are children of the mesh and
 * are removed automatically when the mesh is removed from the scene.
 * The trail line is a scene sibling and must be removed separately.
 * Geometry and material are disposed to release GPU memory.
 */
export function removePlayerFromScene(phoneId: string): void {
  const obj = playerObjects.get(phoneId);
  if (!obj) { return; }

  scene.remove(obj.mesh);
  obj.mesh.geometry.dispose();
  (obj.mesh.material as THREE.MeshStandardMaterial).dispose();

  // Trail is a scene-level sibling, not a mesh child — must remove and dispose separately
  scene.remove(obj.trail.line);
  obj.trail.line.geometry.dispose();
  (obj.trail.line.material as THREE.LineBasicMaterial).dispose();

  playerObjects.delete(phoneId);
}

/**
 * Toggle the position display mode between gesture displacement and dead-reckoning.
 * Returns the user-facing mode label (consumed by plan 05 keyboard handler / HUD update).
 * Does NOT add keyboard listeners — plan 05 owns key binding in room.ts.
 */
export function cyclePositionMode(): string {
  positionMode = positionMode === 'gesture' ? 'deadReckoning' : 'gesture';
  return positionMode === 'gesture' ? 'gesture' : 'dead-reckoning';
}

/**
 * Toggle the grid floor visibility (G key — D-15).
 * Flips gridRef.visible — never removes/re-adds the GridHelper (Pitfall 4).
 */
export function toggleGrid(): void {
  gridVisible = !gridVisible;
  if (gridRef) { gridRef.visible = gridVisible; }
}

/**
 * Toggle per-player axes gizmo visibility (A key — D-15).
 * Iterates playerObjects and flips each axes.visible (Pitfall 4 — never re-add).
 */
export function toggleAxes(): void {
  axesVisible = !axesVisible;
  for (const obj of playerObjects.values()) {
    obj.axes.visible = axesVisible;
  }
}

/**
 * Toggle per-player motion trail visibility (T/D key — D-15).
 * Flips trailVisible and every trail line's .visible (Pitfall 4 — never re-add).
 */
export function toggleTrail(): void {
  trailVisible = !trailVisible;
  for (const obj of playerObjects.values()) {
    obj.trail.line.visible = trailVisible;
  }
}

/**
 * Toggle per-player numeric HUD panel visibility (H key — D-15).
 * Flips numericHudVisible and the #game-hud-players element's CSS display.
 * When hidden: skips hudText accumulation in updateScene() (T-06-12 perf guard).
 */
export function toggleNumericHud(): void {
  numericHudVisible = !numericHudVisible;
  const el = document.getElementById('game-hud-players');
  if (el) { el.style.display = numericHudVisible ? '' : 'none'; }
}

/**
 * Return current toggle states and user-facing position-mode label.
 * Consumed by room.ts updateHud() to render the persistent HUD key-hint line
 * and the pos: mode line.
 */
export function getToggleStates(): {
  gridVisible: boolean;
  axesVisible: boolean;
  numericHudVisible: boolean;
  trailVisible: boolean;
  positionModeLabel: string;
} {
  return {
    gridVisible,
    axesVisible,
    numericHudVisible,
    trailVisible,
    positionModeLabel: positionMode === 'gesture' ? 'gesture' : 'dead-reckoning',
  };
}
