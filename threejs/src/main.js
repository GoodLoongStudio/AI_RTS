import * as THREE from 'three';
import { EffectComposer } from 'three/addons/postprocessing/EffectComposer.js';
import { RenderPass } from 'three/addons/postprocessing/RenderPass.js';
import { UnrealBloomPass } from 'three/addons/postprocessing/UnrealBloomPass.js';
import { OutputPass } from 'three/addons/postprocessing/OutputPass.js';
import { ShaderPass } from 'three/addons/postprocessing/ShaderPass.js';
import { RoomEnvironment } from 'three/addons/environments/RoomEnvironment.js';
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
camera.position.set(900, 620, 1350);

const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, powerPreference: 'high-performance', logarithmicDepthBuffer: true });
renderer.setSize(innerWidth, innerHeight);
renderer.setPixelRatio(Math.min(devicePixelRatio, 1.75));
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.toneMappingExposure = 1.08;
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFSoftShadowMap;

// Low-intensity image based lighting gives metal hulls coherent specular response without replacing the space backdrop.
const pmremGenerator = new THREE.PMREMGenerator(renderer);
const roomEnvironment = new RoomEnvironment();
scene.environment = pmremGenerator.fromScene(roomEnvironment, 0.04).texture;
scene.environmentIntensity = 0.24;
roomEnvironment.dispose();
pmremGenerator.dispose();

const composer = new EffectComposer(renderer);
composer.addPass(new RenderPass(scene, camera));
const bloom = new UnrealBloomPass(new THREE.Vector2(innerWidth, innerHeight), 0.60, 0.58, 0.90);
composer.addPass(bloom);
composer.addPass(new ShaderPass({
  uniforms: {
    tDiffuse: { value: null },
    resolution: { value: new THREE.Vector2(innerWidth, innerHeight) },
    strength: { value: 0.14 },
  },
  vertexShader: `varying vec2 vUv; void main(){vUv=uv;gl_Position=projectionMatrix*modelViewMatrix*vec4(position,1.0);}`,
  fragmentShader: `
    uniform sampler2D tDiffuse; uniform vec2 resolution; uniform float strength; varying vec2 vUv;
    float hash(vec2 p){return fract(sin(dot(p,vec2(12.9898,78.233)))*43758.5453);}
    void main(){
      vec2 d=vUv-.5; float vig=1.0-smoothstep(.28,.78,dot(d,d));
      vec3 c=texture2D(tDiffuse,vUv).rgb;
      float grain=(hash(vUv*resolution+fract(sin(vUv.yx*91.7)))-.5)*.007;
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
// Cinematic composition pass: keep the asteroid belt as a distant arc and bring the
// procedural planet into the same visual plane as the fleet, instead of letting debris
// dominate the first frame.
if (environment.planetGroup) {
  environment.planetGroup.position.set(7500, -150, -3500);
  environment.planetGroup.scale.setScalar(0.30);
  // The generated ring is useful for alternate random systems but is hidden in this
  // Earth-like hero composition so the planet reads as a clean backdrop, not a HUD-sized disc.
  if (environment.planetGroup.children[2]) environment.planetGroup.children[2].visible = false;
}
if (environment.asteroidBelts[0]) {
  environment.asteroidBelts[0].count = 160;
  environment.asteroidBelts[0].scale.setScalar(0.10);
  environment.asteroidBelts[0].position.set(5000, 80, -3300);
}

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

const heroOffsets = [
  [0,0,0], [-420,-120,-360], [390,90,-390], [640,-100,-180],
  [-610,120,20], [-470,-170,210], [360,160,150], [610,-150,260], [180,-210,420], [-250,210,440]
];
player.units.forEach((u, i) => {
  const o = heroOffsets[i] || [((i%7)-3)*145, ((i%5)-2)*65, 520+Math.floor(i/7)*120+(i%3)*45];
  u.object.position.set(-180+o[0], 70+o[1], 240+o[2]);
});
enemy.units.forEach((u, i) => {
  u.object.position.add(new THREE.Vector3((i % 8) * 100, Math.floor(i / 9) * 65, (i % 5) * 120));
  u.object.rotation.y = Math.PI;
});

// Hero ships are deliberately oversized relative to simulation radii for a readable,
// cinematic Homeworld-like silhouette at gameplay zoom. Smaller craft retain hierarchy.
const greebleBox = new THREE.BoxGeometry(1, 1, 1);
const greebleMat = new THREE.MeshStandardMaterial({ color: 0x717a7f, roughness: .62, metalness: .58 });
const trenchMat = new THREE.MeshStandardMaterial({ color: 0x11181d, roughness: .44, metalness: .76 });
const cyanMat = new THREE.MeshBasicMaterial({ color: 0x66e9ff, toneMapped: false });
const decorateCapital = (unit, visual) => {
  if (!visual || !['mothership','battlecruiser','destroyer'].includes(unit.type)) return;
  const cfg = unit.type === 'mothership' ? { halfX:5.7, z0:-6.8, z1:7.2, step:1.15, y:1.18, topX:4.0 }
    : unit.type === 'battlecruiser' ? { halfX:3.85, z0:-5.4, z1:5.5, step:1.05, y:1.02, topX:2.7 }
    : { halfX:2.78, z0:-3.6, z1:3.7, step:.9, y:.86, topX:1.9 };
  const details = [];
  for (let z=cfg.z0; z<=cfg.z1; z+=cfg.step) {
    details.push({ p:[-cfg.halfX,cfg.y,z], s:[.24,.19,.52] }, { p:[cfg.halfX,cfg.y,z], s:[.24,.19,.52] });
  }
  for (let z=cfg.z0+.5; z<=cfg.z1-.5; z+=cfg.step*1.7) {
    for (const x of [-cfg.topX, -cfg.topX*.33, cfg.topX*.33, cfg.topX]) details.push({ p:[x,cfg.y+.52,z], s:[.40,.095,.58] });
  }
  const inst = new THREE.InstancedMesh(greebleBox, greebleMat, details.length);
  const dummy = new THREE.Object3D();
  details.forEach((d,i)=>{ dummy.position.set(...d.p); dummy.scale.set(...d.s); dummy.rotation.y=(i%3-1)*.05; dummy.updateMatrix(); inst.setMatrixAt(i,dummy.matrix); });
  inst.instanceMatrix.needsUpdate = true; visual.add(inst);
  const trench = new THREE.Mesh(greebleBox, trenchMat); trench.position.set(0, -.22, .1); trench.scale.set(cfg.halfX*.92,.13,(cfg.z1-cfg.z0)*.43); trench.position.z=1.15; visual.add(trench);
  if (unit.type === 'mothership') {
    const bay = new THREE.Mesh(greebleBox, trenchMat); bay.position.set(0, 1.22, 3.25); bay.scale.set(2.15, .10, 2.55); visual.add(bay);
    for (const side of [-1,1]) { const rail = new THREE.Mesh(greebleBox, greebleMat); rail.position.set(side*2.35, 1.38, 3.25); rail.scale.set(.18,.28,2.8); visual.add(rail); }
  }
  for (const side of [-1,1]) {
    const light = new THREE.Mesh(greebleBox, cyanMat); light.position.set(side*cfg.halfX*.82,-.48,0); light.scale.set(.06,.045,(cfg.z1-cfg.z0)*.52); visual.add(light);
  }
};

for (const u of fleetSystem.units) {
  const heroScale = u.type === 'mothership' ? 2.0 : u.type === 'battlecruiser' ? 1.85 : u.type === 'destroyer' ? 1.65 : u.type === 'frigate' ? 1.5 : 1.28;
  const visual = u.object.children[0];
  if (visual) visual.scale.multiplyScalar(heroScale);
  decorateCapital(u, visual);
  if (u.object.userData.selectionRing) u.object.userData.selectionRing.scale.setScalar(0.26);
  if (u.object.userData.marker) u.object.userData.marker.visible = false;
}

selection.setDefaultFocus(player.units[0]);
hud.bindSelection(selection);

const tacticalGrid = new THREE.GridHelper(16000, 80, 0x1d8097, 0x0c3340);
tacticalGrid.material.transparent = true;
tacticalGrid.material.opacity = 0.018;
tacticalGrid.position.y = -220;
scene.add(tacticalGrid);

let cameraTarget = new THREE.Vector3(-90, 70, 40);
let azimuth = -0.62;
let elevation = 0.34;
let distance = 880;
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
