import * as THREE from 'three';
import { EffectComposer } from 'three/addons/postprocessing/EffectComposer.js';
import { RenderPass } from 'three/addons/postprocessing/RenderPass.js';
import { UnrealBloomPass } from 'three/addons/postprocessing/UnrealBloomPass.js';
import { OutputPass } from 'three/addons/postprocessing/OutputPass.js';
import { ShaderPass } from 'three/addons/postprocessing/ShaderPass.js';
import { SpaceEnvironment } from './render/SpaceEnvironment.js';
import { ProceduralShipFactory } from './render/ProceduralShipFactory.js';
import { FleetSystem } from './game/FleetSystem.js';
import { SelectionController } from './game/SelectionController.js';
import { CombatSystem } from './game/CombatSystem.js';
import { HUD } from './ui/HUD.js';
import './styles.css';

const app = document.querySelector('#app');
app.innerHTML = `<canvas id="scene"></canvas><div id="hud-root"></div>`;

const canvas = document.querySelector('#scene');
const scene = new THREE.Scene();
scene.fog = new THREE.FogExp2(0x050912, 0.000012);

const camera = new THREE.PerspectiveCamera(52, innerWidth / innerHeight, 0.5, 220000);
camera.position.set(1600, 1100, 2400);

const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, powerPreference: 'high-performance', logarithmicDepthBuffer: true });
renderer.setSize(innerWidth, innerHeight);
renderer.setPixelRatio(Math.min(devicePixelRatio, 1.75));
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.toneMappingExposure = 1.08;
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFSoftShadowMap;

const composer = new EffectComposer(renderer);
composer.addPass(new RenderPass(scene, camera));
const bloom = new UnrealBloomPass(new THREE.Vector2(innerWidth, innerHeight), 0.72, 0.62, 0.88);
composer.addPass(bloom);
composer.addPass(new ShaderPass({
  uniforms: {
    tDiffuse: { value: null },
    resolution: { value: new THREE.Vector2(innerWidth, innerHeight) },
    strength: { value: 0.19 },
  },
  vertexShader: `varying vec2 vUv; void main(){vUv=uv;gl_Position=projectionMatrix*modelViewMatrix*vec4(position,1.0);}`,
  fragmentShader: `
    uniform sampler2D tDiffuse; uniform vec2 resolution; uniform float strength; varying vec2 vUv;
    float hash(vec2 p){return fract(sin(dot(p,vec2(12.9898,78.233)))*43758.5453);}
    void main(){
      vec2 d=vUv-.5; float vig=1.0-smoothstep(.28,.78,dot(d,d));
      vec3 c=texture2D(tDiffuse,vUv).rgb;
      float grain=(hash(vUv*resolution+fract(sin(vUv.yx*91.7)))-.5)*.018;
      c=(c+grain)*(mix(1.0,vig,strength));
      gl_FragColor=vec4(c,1.0);
    }`
}));
composer.addPass(new OutputPass());

const hemi = new THREE.HemisphereLight(0x9ecfff, 0x0a1018, 0.55);
scene.add(hemi);
const key = new THREE.DirectionalLight(0xfff1d2, 5.5);
key.position.set(-4200, 3200, 5200);
key.castShadow = false;
scene.add(key);
const rim = new THREE.DirectionalLight(0x61cfff, 2.1);
rim.position.set(2500, -1400, -4200);
scene.add(rim);

const environment = new SpaceEnvironment(scene, renderer);
environment.build();

const shipFactory = new ProceduralShipFactory(renderer);
const fleetSystem = new FleetSystem(scene, shipFactory);
const combatSystem = new CombatSystem(scene, fleetSystem);
const hud = new HUD(document.querySelector('#hud-root'), fleetSystem, combatSystem);
const selection = new SelectionController(renderer, camera, fleetSystem, hud);

const player = fleetSystem.createFleet('player', 0x59e8ff, new THREE.Vector3(-420, 80, 540), [
  ['mothership', 1], ['battlecruiser', 1], ['destroyer', 2], ['frigate', 5], ['corvette', 9], ['fighter', 18], ['harvester', 3]
]);
const enemy = fleetSystem.createFleet('enemy', 0xff5a61, new THREE.Vector3(2200, 280, -1700), [
  ['mothership', 1], ['battlecruiser', 1], ['destroyer', 3], ['frigate', 7], ['corvette', 12], ['fighter', 25]
]);

player.units.forEach((u, i) => {
  u.object.position.add(new THREE.Vector3((i % 7) * 90, Math.floor(i / 10) * 55, (i % 4) * 110));
});
enemy.units.forEach((u, i) => {
  u.object.position.add(new THREE.Vector3((i % 8) * 100, Math.floor(i / 9) * 65, (i % 5) * 120));
  u.object.rotation.y = Math.PI;
});

selection.setDefaultFocus(player.units[0]);
hud.bindSelection(selection);

const tacticalGrid = new THREE.GridHelper(16000, 80, 0x1d8097, 0x0c3340);
tacticalGrid.material.transparent = true;
tacticalGrid.material.opacity = 0.07;
tacticalGrid.position.y = -220;
scene.add(tacticalGrid);

let cameraTarget = player.units[0].object.position.clone();
let azimuth = -0.52;
let elevation = 0.38;
let distance = 3200;
let targetDistance = distance;
const keys = new Set();
let middleDrag = false;
let lastMouse = new THREE.Vector2();

function updateCamera(dt) {
  const forward = new THREE.Vector3(Math.sin(azimuth), 0, Math.cos(azimuth)).normalize();
  const right = new THREE.Vector3(forward.z, 0, -forward.x);
  const panSpeed = (460 + distance * 0.23) * dt;
  if (keys.has('KeyW')) cameraTarget.addScaledVector(forward, -panSpeed);
  if (keys.has('KeyS')) cameraTarget.addScaledVector(forward, panSpeed);
  if (keys.has('KeyA')) cameraTarget.addScaledVector(right, -panSpeed);
  if (keys.has('KeyD')) cameraTarget.addScaledVector(right, panSpeed);
  if (keys.has('KeyQ')) cameraTarget.y += panSpeed * .72;
  if (keys.has('KeyE')) cameraTarget.y -= panSpeed * .72;

  distance += (targetDistance - distance) * Math.min(1, dt * 8);
  elevation = THREE.MathUtils.clamp(elevation, -0.18, 1.24);
  const ce = Math.cos(elevation);
  camera.position.set(
    cameraTarget.x + Math.sin(azimuth) * ce * distance,
    cameraTarget.y + Math.sin(elevation) * distance,
    cameraTarget.z + Math.cos(azimuth) * ce * distance,
  );
  camera.lookAt(cameraTarget);
}

addEventListener('keydown', e => {
  keys.add(e.code);
  if (e.code === 'KeyF') {
    const first = selection.selectedUnits[0];
    if (first) cameraTarget.copy(first.object.position);
  }
  if (e.code === 'Space') {
    e.preventDefault();
    combatSystem.paused = !combatSystem.paused;
    hud.flash(combatSystem.paused ? '战术时间暂停' : '战术时间恢复');
  }
  if (e.code === 'KeyX') selection.attackMode = true;
  if (e.code === 'KeyM') selection.moveMode = true;
});
addEventListener('keyup', e => keys.delete(e.code));
canvas.addEventListener('pointerdown', e => {
  if (e.button === 1) {
    middleDrag = true;
    lastMouse.set(e.clientX, e.clientY);
    canvas.setPointerCapture(e.pointerId);
  }
});
canvas.addEventListener('pointermove', e => {
  if (!middleDrag) return;
  const dx = e.clientX - lastMouse.x;
  const dy = e.clientY - lastMouse.y;
  lastMouse.set(e.clientX, e.clientY);
  azimuth -= dx * 0.0042;
  elevation -= dy * 0.0034;
});
canvas.addEventListener('pointerup', e => {
  if (e.button === 1) middleDrag = false;
});
canvas.addEventListener('wheel', e => {
  targetDistance *= Math.exp(e.deltaY * 0.00075);
  targetDistance = THREE.MathUtils.clamp(targetDistance, 320, 22000);
}, { passive: true });
canvas.addEventListener('contextmenu', e => e.preventDefault());

let dprTimer = 0;
let fpsEma = 60;
const clock = new THREE.Clock();
function animate() {
  const rawDt = Math.min(clock.getDelta(), 0.05);
  const dt = combatSystem.paused ? 0 : rawDt;
  fpsEma += ((1 / Math.max(rawDt, 1e-5)) - fpsEma) * 0.05;
  updateCamera(rawDt);
  environment.update(rawDt, camera);
  fleetSystem.update(dt, camera);
  combatSystem.update(dt);
  selection.update(rawDt);
  hud.update(rawDt, camera, fpsEma);
  composer.render();

  dprTimer += rawDt;
  if (dprTimer > 3.5) {
    dprTimer = 0;
    const current = renderer.getPixelRatio();
    let next = current;
    if (fpsEma < 47 && current > 0.85) next = Math.max(0.85, current - 0.12);
    else if (fpsEma > 58 && current < Math.min(devicePixelRatio, 1.75)) next = Math.min(Math.min(devicePixelRatio, 1.75), current + 0.08);
    if (Math.abs(next - current) > 0.01) renderer.setPixelRatio(next);
  }
}
renderer.setAnimationLoop(animate);

addEventListener('resize', () => {
  camera.aspect = innerWidth / innerHeight;
  camera.updateProjectionMatrix();
  renderer.setSize(innerWidth, innerHeight);
  composer.setSize(innerWidth, innerHeight);
  const pass = composer.passes.find(p => p.uniforms?.resolution);
  pass?.uniforms?.resolution?.value?.set(innerWidth, innerHeight);
  hud.resize();
});
