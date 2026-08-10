import * as THREE from 'three';

export class CombatSystem {
  constructor(scene, fleetSystem) {
    this.scene = scene;
    this.fleetSystem = fleetSystem;
    this.projectiles = [];
    this.explosions = [];
    this.time = 0;
    this.paused = false;
    this.aiTimer = 0;
    this.tmp = new THREE.Vector3();
  }

  spawnBeam(from, to, color, width=1) {
    const start=from.clone(), end=to.clone();
    const mid=start.clone().add(end).multiplyScalar(.5);
    const len=start.distanceTo(end);
    const geo=new THREE.CylinderGeometry(width,width*.45,len,6,1,true);
    const mat=new THREE.MeshBasicMaterial({color,transparent:true,opacity:.92,blending:THREE.AdditiveBlending,depthWrite:false,toneMapped:false});
    const beam=new THREE.Mesh(geo,mat);
    beam.position.copy(mid);
    beam.quaternion.setFromUnitVectors(new THREE.Vector3(0,1,0),end.clone().sub(start).normalize());
    this.scene.add(beam);
    this.projectiles.push({mesh:beam,life:.10,max:.10});
  }

  spawnTracer(from,to,color,size=3) {
    const geo=new THREE.SphereGeometry(size,8,6);
    const mat=new THREE.MeshBasicMaterial({color,transparent:true,opacity:1,blending:THREE.AdditiveBlending,depthWrite:false,toneMapped:false});
    const mesh=new THREE.Mesh(geo,mat);mesh.position.copy(from);this.scene.add(mesh);
    this.projectiles.push({mesh,life:.38,max:.38,start:from.clone(),end:to.clone(),tracer:true});
  }

  spawnExplosion(position, radius, color=0xffc06a) {
    const geo=new THREE.IcosahedronGeometry(1,2);
    const mat=new THREE.MeshBasicMaterial({color,transparent:true,opacity:1,blending:THREE.AdditiveBlending,depthWrite:false,toneMapped:false});
    const mesh=new THREE.Mesh(geo,mat);mesh.position.copy(position);mesh.scale.setScalar(radius*.08);this.scene.add(mesh);
    const shockMat=new THREE.MeshBasicMaterial({color:0x79d9ff,transparent:true,opacity:.7,side:THREE.DoubleSide,blending:THREE.AdditiveBlending,depthWrite:false});
    const shock=new THREE.Mesh(new THREE.RingGeometry(.7,1,48),shockMat);shock.position.copy(position);shock.quaternion.random();shock.scale.setScalar(radius*.1);this.scene.add(shock);
    this.explosions.push({mesh,shock,life:.78,max:.78,radius});
  }

  destroyUnit(unit) {
    const p=unit.object.position.clone();
    this.spawnExplosion(p,Math.max(40,unit.radius*.95), unit.type==='mothership'?0xffd39a:0xff9f63);
    unit.object.traverse(o=>{if(o.material && 'opacity'in o.material){o.material=o.material.clone();o.material.transparent=true;}});
    unit.object.userData.dying=1.2;
  }

  fire(attacker,target) {
    const a=attacker.object.position, b=target.object.position;
    const spread=Math.max(4,target.radius*.18);
    const hit=b.clone().add(new THREE.Vector3((Math.random()-.5)*spread,(Math.random()-.5)*spread,(Math.random()-.5)*spread));
    const color=attacker.team==='player'?0x65ebff:0xff6b6e;
    if(attacker.type==='fighter'||attacker.type==='corvette') this.spawnTracer(a,hit,color,attacker.type==='fighter'?2.2:3.8);
    else this.spawnBeam(a,hit,color,attacker.type==='mothership'?3.8:attacker.type==='battlecruiser'?3:1.7);
    const jitter=.84+Math.random()*.32;
    if(this.fleetSystem.applyDamage(target,attacker.damage*jitter)) this.destroyUnit(target);
    attacker.cooldownLeft=attacker.cooldown*(.88+Math.random()*.25);
  }

  updateAI(dt) {
    this.aiTimer-=dt;
    if(this.aiTimer>0)return;
    this.aiTimer=.55;
    for(const unit of this.fleetSystem.getAlive('enemy')){
      if(unit.damage<=0)continue;
      if(!unit.target||unit.target.dead||Math.random()<.15) unit.target=this.fleetSystem.findNearestEnemy(unit,5000);
    }
    // player idle auto-defense at local range
    for(const unit of this.fleetSystem.getAlive('player')){
      if(unit.damage<=0||unit.target||unit.moveTarget)continue;
      const t=this.fleetSystem.findNearestEnemy(unit,unit.range*1.3);
      if(t)unit.target=t;
    }
  }

  update(dt) {
    if(this.paused) return;
    this.time+=dt;
    this.updateAI(dt);
    for(const u of this.fleetSystem.units){
      if(u.dead||u.damage<=0||u.cooldownLeft>0||!u.target||u.target.dead)continue;
      const d=u.object.position.distanceTo(u.target.object.position);
      if(d<=u.range+u.target.radius*.25)this.fire(u,u.target);
    }

    for(let i=this.projectiles.length-1;i>=0;i--){
      const p=this.projectiles[i];p.life-=dt;
      if(p.tracer){const t=1-p.life/p.max;p.mesh.position.lerpVectors(p.start,p.end,THREE.MathUtils.smootherstep(t,0,1));}
      p.mesh.material.opacity=Math.max(0,p.life/p.max);
      if(p.life<=0){this.scene.remove(p.mesh);p.mesh.geometry.dispose();p.mesh.material.dispose();this.projectiles.splice(i,1);}
    }
    for(let i=this.explosions.length-1;i>=0;i--){
      const e=this.explosions[i];e.life-=dt;const t=1-e.life/e.max;
      const s=e.radius*(.08+t*1.25);e.mesh.scale.setScalar(s);e.mesh.material.opacity=(1-t)*(1-t);
      e.shock.scale.setScalar(e.radius*(.08+t*1.65));e.shock.material.opacity=(1-t)*.52;
      if(e.life<=0){for(const m of[e.mesh,e.shock]){this.scene.remove(m);m.geometry.dispose();m.material.dispose();}this.explosions.splice(i,1);}
    }

    for(const u of this.fleetSystem.units){
      if(!u.dead||!u.object.parent)continue;
      u.object.userData.dying-=dt;
      u.object.rotation.x+=dt*.55;u.object.rotation.z+=dt*.38;u.object.position.y-=dt*18;
      u.object.traverse(o=>{if(o.material?.transparent)o.material.opacity=Math.max(0,(u.object.userData.dying||0)/1.2);});
      if(u.object.userData.dying<=0)this.scene.remove(u.object);
    }
  }
}
