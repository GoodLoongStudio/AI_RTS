import * as THREE from 'three';

export class SelectionController {
  constructor(renderer, camera, fleetSystem, hud) {
    this.renderer=renderer;this.camera=camera;this.fleetSystem=fleetSystem;this.hud=hud;
    this.raycaster=new THREE.Raycaster();this.pointer=new THREE.Vector2();
    this.selectedUnits=[];this.dragging=false;this.dragStart={x:0,y:0};this.dragNow={x:0,y:0};
    this.attackMode=false;this.moveMode=false;this.altitude=0;
    this.moveMarker=this.createMoveMarker();this.fleetSystem.scene.add(this.moveMarker);
    this.box=document.createElement('div');this.box.className='selection-box';document.body.appendChild(this.box);
    const el=renderer.domElement;
    el.addEventListener('pointerdown',e=>this.onDown(e));
    el.addEventListener('pointermove',e=>this.onMove(e));
    el.addEventListener('pointerup',e=>this.onUp(e));
    el.addEventListener('dblclick',e=>this.onDoubleClick(e));
  }
  setDefaultFocus(unit){this.selectOnly([unit]);}
  createMoveMarker(){
    const g=new THREE.Group();g.visible=false;
    const mat=new THREE.MeshBasicMaterial({color:0x67eaff,transparent:true,opacity:.7,side:THREE.DoubleSide,depthWrite:false});
    const r=new THREE.Mesh(new THREE.RingGeometry(25,31,48),mat);r.rotateX(-Math.PI/2);g.add(r);
    const lineGeo=new THREE.BufferGeometry().setFromPoints([new THREE.Vector3(0,-180,0),new THREE.Vector3(0,180,0)]);
    g.add(new THREE.Line(lineGeo,new THREE.LineBasicMaterial({color:0x67eaff,transparent:true,opacity:.45})));return g;
  }
  pointerNdc(e){const rect=this.renderer.domElement.getBoundingClientRect();this.pointer.x=((e.clientX-rect.left)/rect.width)*2-1;this.pointer.y=-((e.clientY-rect.top)/rect.height)*2+1;}
  intersections(e){this.pointerNdc(e);this.raycaster.setFromCamera(this.pointer,this.camera);const objects=this.fleetSystem.getAlive().map(u=>u.object);return this.raycaster.intersectObjects(objects,true);}
  unitFromObject(obj){let o=obj;while(o&&!o.userData.unit)o=o.parent;return o?.userData?.unit||null;}
  onDown(e){if(e.button!==0)return;this.dragging=true;this.dragStart={x:e.clientX,y:e.clientY};this.dragNow={...this.dragStart};this.box.style.display='none';}
  onMove(e){
    if(!this.dragging)return;this.dragNow={x:e.clientX,y:e.clientY};const dx=Math.abs(this.dragNow.x-this.dragStart.x),dy=Math.abs(this.dragNow.y-this.dragStart.y);
    if(dx+dy>8){const x=Math.min(this.dragStart.x,this.dragNow.x),y=Math.min(this.dragStart.y,this.dragNow.y);this.box.style.display='block';this.box.style.left=x+'px';this.box.style.top=y+'px';this.box.style.width=dx+'px';this.box.style.height=dy+'px';}
  }
  onUp(e){
    if(e.button===2){
      const hits=this.intersections(e); const unit=hits.length?this.unitFromObject(hits[0].object):null;
      if(unit&&unit.team==='enemy'&&this.selectedUnits.length){this.fleetSystem.issueAttack(this.selectedUnits,unit);this.hud.flash(`攻击目标：${unit.label}`);return;}
      if(this.selectedUnits.length){const p=this.worldPointFromPointer(e);if(p){this.fleetSystem.issueMove(this.selectedUnits,p);this.moveMarker.position.copy(p);this.moveMarker.visible=true;this.hud.flash(`编队移动：${Math.round(p.x)}, ${Math.round(p.y)}, ${Math.round(p.z)}`);}}
      return;
    }
    if(e.button!==0||!this.dragging)return;this.dragging=false;this.box.style.display='none';
    const dx=Math.abs(e.clientX-this.dragStart.x),dy=Math.abs(e.clientY-this.dragStart.y);
    if(dx+dy>10){this.boxSelect(this.dragStart,{x:e.clientX,y:e.clientY},e.shiftKey);return;}
    const hits=this.intersections(e);const unit=hits.length?this.unitFromObject(hits[0].object):null;
    if(this.attackMode){if(unit&&unit.team==='enemy'&&this.selectedUnits.length){this.fleetSystem.issueAttack(this.selectedUnits,unit);this.hud.flash(`攻击目标：${unit.label}`);}this.attackMode=false;return;}
    if(unit){if(unit.team==='player')this.selectOnly(e.shiftKey?[...this.selectedUnits,unit]:[unit]);else if(this.selectedUnits.length){this.fleetSystem.issueAttack(this.selectedUnits,unit);this.hud.flash(`交战：${unit.label}`);}return;}
    if(this.moveMode||this.selectedUnits.length){const p=this.worldPointFromPointer(e);if(p){this.fleetSystem.issueMove(this.selectedUnits,p);this.moveMarker.position.copy(p);this.moveMarker.visible=true;this.hud.flash(`移动至 ${Math.round(p.x)}, ${Math.round(p.y)}, ${Math.round(p.z)}`);}this.moveMode=false;}
  }
  onDoubleClick(e){const hits=this.intersections(e);if(!hits.length)return;const unit=this.unitFromObject(hits[0].object);if(!unit||unit.team!=='player')return;this.selectOnly(this.fleetSystem.getAlive('player').filter(u=>u.type===unit.type));}
  boxSelect(a,b,additive){
    const minX=Math.min(a.x,b.x),maxX=Math.max(a.x,b.x),minY=Math.min(a.y,b.y),maxY=Math.max(a.y,b.y);const chosen=additive?[...this.selectedUnits]:[];
    for(const u of this.fleetSystem.getAlive('player')){const v=u.object.position.clone().project(this.camera);const sx=(v.x*.5+.5)*innerWidth,sy=(-v.y*.5+.5)*innerHeight;if(v.z>-1&&v.z<1&&sx>=minX&&sx<=maxX&&sy>=minY&&sy<=maxY)chosen.push(u);}this.selectOnly(chosen);
  }
  worldPointFromPointer(e){
    this.pointerNdc(e);this.raycaster.setFromCamera(this.pointer,this.camera);const origin=this.raycaster.ray.origin,dir=this.raycaster.ray.direction;
    const baseY=this.selectedUnits.length?this.selectedUnits.reduce((s,u)=>s+u.object.position.y,0)/this.selectedUnits.length:0;
    const y=baseY+(e.shiftKey?600:e.altKey?-600:0);
    const t=(y-origin.y)/dir.y;if(!Number.isFinite(t)||t<0)return origin.clone().addScaledVector(dir,1800);return origin.clone().addScaledVector(dir,t);
  }
  selectOnly(units){
    const unique=[...new Map(units.filter(Boolean).map(u=>[u.id,u])).values()];this.selectedUnits.forEach(u=>this.fleetSystem.setSelected(u,false));this.selectedUnits=unique;this.selectedUnits.forEach(u=>this.fleetSystem.setSelected(u,true));this.hud.setSelection(this.selectedUnits);
  }
  update(dt){if(this.moveMarker.visible){this.moveMarker.rotation.y+=dt*.7;this.moveMarker.children[0].material.opacity=.48+Math.sin(performance.now()*.006)*.18;}}
}
