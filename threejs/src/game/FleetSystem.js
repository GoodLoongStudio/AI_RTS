import * as THREE from 'three';
import { ProceduralShipFactory } from '../render/ProceduralShipFactory.js';

export class FleetSystem {
  constructor(scene, shipFactory) {
    this.scene = scene;
    this.shipFactory = shipFactory;
    this.fleets = new Map();
    this.units = [];
    this.time = 0;
  }

  createFleet(id, color, origin, composition) {
    const fleet = { id, color, units: [], resources: id === 'player' ? 1200 : 900, strength: 0 };
    let index = 0;
    for (const [type, count] of composition) {
      for (let i=0;i<count;i++) {
        const built = this.shipFactory.create(type, color);
        const stats = built.stats;
        const unit = {
          id: `${id}-${type}-${index++}`,
          team: id,
          type,
          label: stats.label,
          object: built.object,
          maxHp: stats.hp,
          hp: stats.hp,
          speed: stats.speed,
          range: stats.range,
          damage: stats.damage,
          cooldown: stats.cooldown,
          cooldownLeft: Math.random()*stats.cooldown,
          radius: stats.radius,
          value: stats.value,
          target: null,
          moveTarget: null,
          selected: false,
          dead: false,
          velocity: new THREE.Vector3(),
          desiredVelocity: new THREE.Vector3(),
          formationOffset: new THREE.Vector3(),
          wobble: Math.random()*Math.PI*2,
          lastDamageTime: -100,
          enginePulse: Math.random()*10,
        };
        unit.object.position.copy(origin);
        unit.object.position.x += (Math.random()-.5)*220;
        unit.object.position.y += (Math.random()-.5)*160;
        unit.object.position.z += (Math.random()-.5)*260;
        unit.object.userData.unit = unit;
        fleet.units.push(unit);
        this.units.push(unit);
        fleet.strength += stats.value;
        this.scene.add(unit.object);
      }
    }
    this.fleets.set(id, fleet);
    return fleet;
  }

  setSelected(unit, selected) {
    if (!unit || unit.dead) return;
    unit.selected = selected;
    const ring = unit.object.userData.selectionRing;
    if (ring) ring.material.opacity = selected ? .72 : 0;
    const marker = unit.object.userData.marker;
    if (marker) marker.material.opacity = selected ? .35 : 0;
  }

  getAlive(team=null) {
    return this.units.filter(u => !u.dead && (!team || u.team === team));
  }

  findNearestEnemy(unit, maxDistance=Infinity) {
    let best=null, bestD=maxDistance*maxDistance;
    for (const other of this.units) {
      if (other.dead || other.team === unit.team) continue;
      const d = unit.object.position.distanceToSquared(other.object.position);
      if (d < bestD) { best=other; bestD=d; }
    }
    return best;
  }

  issueMove(units, point, formation='wall') {
    if (!units.length) return;
    const sorted = [...units].sort((a,b)=>b.radius-a.radius);
    const cols = Math.ceil(Math.sqrt(sorted.length*1.4));
    const avgRadius = sorted.reduce((s,u)=>s+u.radius,0)/sorted.length;
    const gap = Math.max(55, avgRadius*1.05);
    sorted.forEach((u,i)=>{
      const col = i % cols;
      const row = Math.floor(i / cols);
      const x = (col-(cols-1)/2)*gap*1.65;
      const z = row*gap*1.35;
      const y = formation === 'sphere' ? (Math.sin(i*2.399)*gap*1.4) : ((i%3)-1)*gap*.35;
      u.moveTarget = point.clone().add(new THREE.Vector3(x,y,z));
      u.target = null;
    });
  }

  issueAttack(units, target) {
    for (const u of units) if (!u.dead && u.team !== target.team && u.damage > 0) { u.target = target; u.moveTarget = null; }
  }

  applyDamage(unit, amount) {
    if (!unit || unit.dead) return false;
    unit.hp -= amount;
    unit.lastDamageTime = this.time;
    if (unit.hp <= 0) {
      unit.hp = 0;
      unit.dead = true;
      const fleet = this.fleets.get(unit.team);
      if (fleet) fleet.strength = Math.max(0, fleet.strength - unit.value);
      return true;
    }
    return false;
  }

  update(dt, camera) {
    this.time += dt;
    for (const unit of this.units) {
      if (unit.dead) continue;
      unit.cooldownLeft -= dt;
      const p = unit.object.position;
      let destination = unit.moveTarget;
      if (unit.target && !unit.target.dead) {
        const dist = p.distanceTo(unit.target.object.position);
        if (dist > Math.max(unit.range*.82, unit.radius+unit.target.radius+80)) destination = unit.target.object.position;
        else destination = null;
      } else if (unit.target?.dead) unit.target = null;

      if (destination) {
        const dir = unit.desiredVelocity.copy(destination).sub(p);
        const dist = dir.length();
        if (dist < Math.max(22, unit.radius*.28)) {
          if (unit.moveTarget) unit.moveTarget = null;
          unit.desiredVelocity.set(0,0,0);
        } else {
          dir.normalize();
          const slow = THREE.MathUtils.clamp(dist/(unit.radius*3+80), .2, 1);
          unit.desiredVelocity.copy(dir).multiplyScalar(unit.speed*slow);
        }
      } else unit.desiredVelocity.set(0,0,0);

      // Soft separation keeps the formation readable without expensive full physics.
      const sep = new THREE.Vector3();
      for (let j=0;j<Math.min(14,this.units.length);j++) {
        const other = this.units[(j*17 + unit.id.length*13) % this.units.length];
        if (!other || other===unit || other.dead || other.team!==unit.team) continue;
        const d2=p.distanceToSquared(other.object.position); const min=(unit.radius+other.radius)*.62;
        if(d2>1 && d2<min*min){sep.copy(p).sub(other.object.position).normalize().multiplyScalar((min-Math.sqrt(d2))*1.8);unit.desiredVelocity.add(sep);}
      }

      unit.velocity.lerp(unit.desiredVelocity, 1-Math.exp(-dt*2.4));
      p.addScaledVector(unit.velocity, dt);
      if (unit.velocity.lengthSq() > 4) {
        const look = p.clone().add(unit.velocity);
        const targetQuat = new THREE.Quaternion();
        const m = new THREE.Matrix4().lookAt(p,look,new THREE.Vector3(0,1,0));
        targetQuat.setFromRotationMatrix(m);
        unit.object.quaternion.slerp(targetQuat,1-Math.exp(-dt*1.9));
      }
      unit.object.rotation.z += Math.sin(this.time*.7 + unit.wobble) * dt * .0008;

      unit.object.traverse(o=>{
        if (o.userData.engineFlame) {
          const pulse = .88 + Math.sin(this.time*10 + unit.enginePulse)*.12;
          o.scale.z = pulse;
          o.material.opacity = .69 + pulse*.18;
        }
      });

      const ring=unit.object.userData.selectionRing;
      if(ring?.material.opacity>0){ring.rotation.z += dt*.16; ring.material.opacity = unit.selected ? .58 + Math.sin(this.time*4)*.12 : 0;}
    }
  }
}
