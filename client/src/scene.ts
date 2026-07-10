/**
 * scene.ts — Three.js scene lifecycle for ImmersiveRT desktop game view.
 *
 * initScene(canvas, container): Set up renderer, camera, lights, grid, CSS2DRenderer.
 *   Guarded by sceneInitialized — safe to call on every player-ready event (Pitfall 2).
 *   CSS2DRenderer domElement appended into `container` (#game-container), NOT document.body
 *   (Pitfall 5: must share the same positioned container as the WebGL canvas).
 *
 * addPlayerToScene / removePlayerFromScene: stubs — bodies filled in plan 04.
 * playerObjects is iterated (empty) by updateScene() each rAF frame — filled in plan 04.
 */

import * as THREE from 'three';
import { CSS2DRenderer } from 'three/examples/jsm/renderers/CSS2DRenderer.js';

// ──────────────────────────────────────────────────────────────────────────────
// Minimal PlayerObject interface
// Extended in plan 04 with label, flashing, axes, trail fields.
// ──────────────────────────────────────────────────────────────────────────────
export interface PlayerObject {
  mesh: THREE.Mesh;
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

// Per-player 3D objects — populated by addPlayerToScene() in plan 04
const playerObjects = new Map<string, PlayerObject>();

// ──────────────────────────────────────────────────────────────────────────────
// Private: update scene from player state each rAF tick
// No-op for now — bodies filled in plan 04 when playerObjects is populated.
// ──────────────────────────────────────────────────────────────────────────────
function updateScene(): void {
  for (const [, obj] of playerObjects) {
    // plan 04: SLERP quaternion, update position, touch flash, trail
    void obj;
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

  // Grid floor (G key toggle in plan 04; default on — D-15)
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
 * Stub — full implementation in plan 04 (box mesh, HSL color, CSS2DLabel, axes, trail).
 */
export function addPlayerToScene(phoneId: string, slot: number, username: string): void {
  // plan 04: create box mesh with slotColor(slot), CSS2DObject label, AxesHelper, trail line
  void phoneId; void slot; void username;
}

/**
 * Remove a player's 3D object from the scene.
 * Stub — full implementation in plan 04.
 */
export function removePlayerFromScene(phoneId: string): void {
  // plan 04: remove mesh + label + axes + trail from scene, delete from playerObjects
  void phoneId;
}
