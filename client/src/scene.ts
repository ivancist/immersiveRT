/**
 * scene.ts — Three.js scene lifecycle for ImmersiveRT desktop game view.
 *
 * initScene(canvas, container): Set up renderer, camera, lights, grid, CSS2DRenderer.
 *   Guarded by sceneInitialized — safe to call on every player-ready event (Pitfall 2).
 *   CSS2DRenderer domElement appended into `container` (#game-container), NOT document.body
 *   (Pitfall 5: must share the same positioned container as the WebGL canvas).
 *
 * addPlayerToScene(phoneId, slot, username): Create box mesh with per-slot HSL color,
 *   CSS2DObject name label (textContent only — XSS guard, T-06-10), and AxesHelper child.
 *   All objects allocated once and stored in playerObjects map (no per-frame alloc — Pitfall 6).
 *
 * removePlayerFromScene(phoneId): Dispose and remove the mesh (+ label + axes children)
 *   from the scene.
 *
 * updateScene() [private, called from rAF]: SLERP each player's mesh quaternion toward the
 *   latest decoded orientation from targetStateStore at SLERP_ALPHA = 0.3 (D-12).
 *   Uses ONE module-scope scratchQuat — never allocates inside the loop (Pitfall 6).
 *   Position updated from positionMode: 'gesture' uses (dx,dy,dz); 'deadReckoning' uses (px,py,pz).
 *
 * cyclePositionMode(): Toggle positionMode and return the new mode label (used by plan 05 keyboard).
 */

import * as THREE from 'three';
import { CSS2DRenderer, CSS2DObject } from 'three/examples/jsm/renderers/CSS2DRenderer.js';
import { targetStateStore } from './playerStore';

// ──────────────────────────────────────────────────────────────────────────────
// PlayerObject interface (plan 03: mesh only; plan 04: adds label, axes, flashing)
// ──────────────────────────────────────────────────────────────────────────────
export interface PlayerObject {
  mesh: THREE.Mesh;
  label: CSS2DObject;
  axes: THREE.AxesHelper;
  flashing: boolean;
}

// ──────────────────────────────────────────────────────────────────────────────
// Module-level singletons — allocated ONCE, NEVER inside the rAF loop (Pitfall 6)
// ──────────────────────────────────────────────────────────────────────────────
let renderer: THREE.WebGLRenderer;
let labelRenderer: CSS2DRenderer;
let scene: THREE.Scene;
let camera: THREE.PerspectiveCamera;

// Guards: player-ready fires once per phone — must init only once (Pitfall 2)
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
// Private: per-slot HSL color (Pattern 7 / UI-SPEC slot color formula)
// ──────────────────────────────────────────────────────────────────────────────
function slotColor(slot: number): THREE.Color {
  // Slot 1→8 maps to hue range [0, 7/8) with fixed saturation + lightness
  return new THREE.Color().setHSL((slot - 1) / 8, 0.7, 0.55);
}

// ──────────────────────────────────────────────────────────────────────────────
// Private: update scene from player state each rAF tick
// ──────────────────────────────────────────────────────────────────────────────
function updateScene(): void {
  for (const [phoneId, obj] of playerObjects) {
    const state = targetStateStore.get(phoneId);
    if (!state) { continue; }

    // SLERP toward latest decoded orientation (D-12, DESK-05).
    // scratchQuat.set(x, y, z, w) — THREE.Quaternion uses (x, y, z, w) order where w is scalar.
    // SensorPacket stores (qw, qx, qy, qz) so we pass (qx, qy, qz, qw) here.
    // NEVER apply orientation via direct assignment — always SLERP (Pitfall/anti-pattern).
    obj.mesh.quaternion.slerp(
      scratchQuat.set(state.qx, state.qy, state.qz, state.qw),
      SLERP_ALPHA
    );

    // Update position from active mode (D-13)
    if (positionMode === 'gesture') {
      // gestureDisplacement: (dx, dy, dz) accumulated since last ZUPT reset
      obj.mesh.position.set(state.dx, state.dy, state.dz);
    } else {
      // deadReckoning: (px, py, pz) Kalman-integrated dead-reckoning position
      obj.mesh.position.set(state.px, state.py, state.pz);
    }
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

  // Grid floor (G key toggle in plan 05; default on — D-15)
  const grid = new THREE.GridHelper(10, 10, 0x444444, 0x333333);
  scene.add(grid);

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
 * and adds an AxesHelper(0.5) child (visible by default — D-15).
 *
 * Idempotent: if phoneId already has a scene object, returns immediately.
 *
 * @param phoneId  Unique identifier for this phone's peer connection
 * @param slot     Display slot (1–8) — determines HSL color (UI-SPEC slot color formula)
 * @param username Player name shown in the floating CSS2D label
 */
export function addPlayerToScene(phoneId: string, slot: number, username: string): void {
  // Idempotency: do not re-add a player already in the scene
  if (playerObjects.has(phoneId)) { return; }

  // Box mesh with per-slot HSL color (Pattern 7 / UI-SPEC)
  const geometry = new THREE.BoxGeometry(1, 1, 1);
  const material = new THREE.MeshStandardMaterial({ color: slotColor(slot) });
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

  // Axes helper to visualise orientation axes per player (D-15: visible by default)
  const axes = new THREE.AxesHelper(0.5);
  mesh.add(axes);

  playerObjects.set(phoneId, { mesh, label, axes, flashing: false });
}

/**
 * Remove a player's 3D object from the scene and dispose GPU resources.
 *
 * The label (CSS2DObject) and axes (AxesHelper) are children of the mesh and
 * are removed automatically when the mesh is removed from the scene.
 * Geometry and material are disposed to release GPU memory.
 */
export function removePlayerFromScene(phoneId: string): void {
  const obj = playerObjects.get(phoneId);
  if (!obj) { return; }

  scene.remove(obj.mesh);
  obj.mesh.geometry.dispose();
  (obj.mesh.material as THREE.MeshStandardMaterial).dispose();
  playerObjects.delete(phoneId);
}

/**
 * Toggle the position display mode between gesture displacement and dead-reckoning.
 * Returns the newly active mode label (consumed by plan 05 keyboard handler for HUD update).
 * Does NOT add keyboard listeners here — plan 05 owns key binding.
 */
export function cyclePositionMode(): string {
  positionMode = positionMode === 'gesture' ? 'deadReckoning' : 'gesture';
  return positionMode;
}
