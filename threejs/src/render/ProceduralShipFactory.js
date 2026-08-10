import * as THREE from 'three';

const SHIP_STATS = {
  mothership:    { label:'母舰',      scale:10.0, hp:9000, speed:34,  range:1300, damage:90,  cooldown:1.45, radius:230, value:9 },
  battlecruiser: { label:'战列巡洋舰', scale:6.4,  hp:4200, speed:48,  range:1200, damage:160, cooldown:1.15, radius:150, value:7 },
  destroyer:     { label:'驱逐舰',    scale:4.0,  hp:2100, speed:65,  range:940,  damage:105, cooldown:1.0,  radius:98,  value:5 },
  frigate:       { label:'护卫舰',    scale:2.45, hp:980,  speed:88,  range:720,  damage:58,  cooldown:.78,  radius:62,  value:3 },
  corvette:      { label:'轻型舰',    scale:1.35, hp:420,  speed:142, range:520,  damage:28,  cooldown:.45,  radius:34,  value:2 },
  fighter:       { label:'攻击机',    scale:.64,  hp:125,  speed:230, range:360,  damage:11,  cooldown:.24,  radius:15,  value:1 },
  harvester:     { label:'资源采集舰', scale:1.85, hp:560,  speed:82,  range:0,    damage:0,   cooldown:2,    radius:42,  value:2 }
};

export class ProceduralShipFactory {
  constructor(renderer) {
    this.renderer = renderer;
    this.textures = this.makeProceduralTextures();
    this.geometryCache = new Map();
    this.materialCache = new Map();
  }

  static stats(type) { return { ...SHIP_STATS[type] }; }

  makeProceduralTextures() {
    const make = (w,h,paint) => {
      const c=document.createElement('canvas');c.width=w;c.height=h;const x=c.getContext('2d');paint(x,w,h);
      const t=new THREE.CanvasTexture(c); t.wrapS=t.wrapT=THREE.RepeatWrapping; t.anisotropy=Math.min(8,this.renderer.capabilities.getMaxAnisotropy?.()||1); t.colorSpace=THREE.SRGBColorSpace; return t;
    };
    const hull = make(1024,1024,(x,w,h)=>{
      x.fillStyle='#9ca7ac';x.fillRect(0,0,w,h);
      // Large modular armor panels with restrained tonal variation: readable up close without looking tiled.
      const pw=96, ph=72;
      for(let yy=0;yy<h;yy+=ph)for(let xx=0;xx<w;xx+=pw){
        const shade=145+Math.floor(Math.random()*24);
        x.fillStyle=`rgb(${shade},${shade+7},${shade+10})`;x.fillRect(xx+2,yy+2,pw-4,ph-4);
        x.strokeStyle='rgba(10,20,25,.42)';x.lineWidth=1.25;x.strokeRect(xx+.6,yy+.6,pw-1.2,ph-1.2);
        x.strokeStyle='rgba(230,242,244,.09)';x.strokeRect(xx+4.5,yy+4.5,pw-9,ph-9);
        if(Math.random()>.63){
          x.fillStyle='rgba(9,19,24,.42)';const vw=18+Math.random()*28;x.fillRect(xx+10,yy+12,vw,4);
          x.fillStyle='rgba(79,189,207,.10)';x.fillRect(xx+10,yy+17,vw*.72,1);
        }
        if(Math.random()>.78){x.fillStyle='rgba(20,28,31,.26)';x.fillRect(xx+pw-15,yy+9,4,4);x.fillRect(xx+pw-24,yy+9,4,4);}
      }
      // Directional wear, seams and maintenance markings.
      for(let i=0;i<42;i++){
        const y=Math.random()*h, x0=Math.random()*w*.72, len=70+Math.random()*260;
        x.strokeStyle=`rgba(18,35,40,${.05+Math.random()*.12})`;x.lineWidth=.7+Math.random()*1.1;
        x.beginPath();x.moveTo(x0,y);x.lineTo(Math.min(w,x0+len),y+(Math.random()-.5)*6);x.stroke();
      }
      for(let i=0;i<120;i++){
        const px=Math.random()*w,py=Math.random()*h,r=.6+Math.random()*1.8;
        x.fillStyle='rgba(15,23,26,.22)';x.beginPath();x.arc(px,py,r,0,Math.PI*2);x.fill();
      }
    });
    hull.repeat.set(1.35,1.35);
    const roughness = make(256,256,(x,w,h)=>{
      const d=x.createImageData(w,h);for(let i=0;i<d.data.length;i+=4){const v=130+Math.random()*110;d.data[i]=d.data[i+1]=d.data[i+2]=v;d.data[i+3]=255;}x.putImageData(d,0,0);
    }); roughness.colorSpace = THREE.NoColorSpace; roughness.repeat.set(2.1,2.1);
    const stripe = make(512,64,(x,w,h)=>{
      x.fillStyle='#02070a';x.fillRect(0,0,w,h);x.fillStyle='#7cecff';
      for(let i=0;i<w;i+=22)x.fillRect(i+2,19,13,3);
      x.fillStyle='rgba(88,210,255,.35)';x.fillRect(0,27,w,1);
    }); stripe.repeat.set(3,1);
    return { hull, roughness, stripe };
  }

  material(teamColor, type='hull', emissive=false) {
    const key=`${teamColor}-${type}-${emissive}`;
    if(this.materialCache.has(key)) return this.materialCache.get(key);
    let mat;
    if(type==='dark') {
      mat=new THREE.MeshStandardMaterial({color:0x0c1318,roughness:.42,metalness:.80});
    } else if(type==='glass') {
      mat=new THREE.MeshPhysicalMaterial({color:0x102a35,roughness:.24,metalness:.58,transmission:.02,clearcoat:.72,clearcoatRoughness:.16,emissive:new THREE.Color(teamColor).multiplyScalar(.035),emissiveIntensity:.48});
    } else {
      mat=new THREE.MeshPhysicalMaterial({
        map:this.textures.hull,
        bumpMap:this.textures.hull,
        bumpScale:.026,
        roughnessMap:this.textures.roughness,
        color:0xaab3b8,
        roughness:.47,
        metalness:.60,
        clearcoat:.08,
        clearcoatRoughness:.62,
      });
    }
    this.materialCache.set(key,mat); return mat;
  }

  addMesh(group, geometry, material, pos=[0,0,0], scale=[1,1,1], rot=[0,0,0], cast=true) {
    const m=new THREE.Mesh(geometry,material);m.position.set(...pos);m.scale.set(...scale);m.rotation.set(...rot);m.castShadow=cast;m.receiveShadow=true;group.add(m);return m;
  }

  addBox(group, material, pos, scale, rot=[0,0,0], bevel=0) {
    let g;
    if (bevel > 0) {
      // Dependency-free softened hard-surface box. Subdivision plus a tiny corner
      // contraction preserves reliable builds while avoiding razor-sharp silhouettes.
      g = new THREE.BoxGeometry(1,1,1,2,2,2);
      const a = g.attributes.position;
      const amount = Math.min(.085, .035 + bevel * .03);
      for (let i=0;i<a.count;i++) {
        const x=a.getX(i), y=a.getY(i), z=a.getZ(i);
        const corner=(Math.abs(x)+Math.abs(y)+Math.abs(z))/1.5;
        const k=1-amount*Math.max(0,corner-.45);
        a.setXYZ(i,x*k,y*k,z*k);
      }
      a.needsUpdate=true; g.computeVertexNormals();
    } else g = new THREE.BoxGeometry(1,1,1);
    return this.addMesh(group,g,material,pos,scale,rot);
  }

  addHullPrism(group, material, length, widthRear, widthFront, height, pos=[0,0,0], bevelTop=.15) {
    const l=length*.5, h=height*.5;
    const wr=widthRear*.5, wf=widthFront*.5;
    const verts=new Float32Array([
      -wf,-h,-l,  wf,-h,-l,  wf,h,-l,  -wf,h,-l,
      -wr,-h, l,  wr,-h, l,  wr,h, l,  -wr,h, l,
    ]);
    const idx=[
      0,1,2, 0,2,3, 4,6,5, 4,7,6,
      0,4,5, 0,5,1, 3,2,6, 3,6,7,
      1,5,6, 1,6,2, 0,3,7, 0,7,4,
    ];
    const geo=new THREE.BufferGeometry();
    geo.setAttribute('position',new THREE.BufferAttribute(verts,3));geo.setIndex(idx);geo.computeVertexNormals();
    const mesh=this.addMesh(group,geo,material,pos);
    // Thin raised spine breaks the monolithic silhouette and catches rim light.
    if(bevelTop>0){
      this.addBox(group,material,[pos[0],pos[1]+h*.82,pos[2]+length*.04],[Math.max(.3,widthFront*.45),Math.max(.12,height*.18),length*.72],[0,0,0],.5);
    }
    return mesh;
  }

  addEngine(group, teamColor, pos, scale=[1,1,1]) {
    const dark=this.material(teamColor,'dark');
    this.addMesh(group,new THREE.CylinderGeometry(.46,.61,1.6,14),dark,pos,scale,[Math.PI/2,0,0]);
    const flameMat=new THREE.MeshBasicMaterial({color:new THREE.Color(teamColor).lerp(new THREE.Color(0xbafaff),.68),transparent:true,opacity:.82,blending:THREE.AdditiveBlending,depthWrite:false});
    const flame=this.addMesh(group,new THREE.ConeGeometry(.42,2.7,18,1,true),flameMat,[pos[0],pos[1],pos[2]+1.65*scale[2]],[scale[0],scale[1],scale[2]],[Math.PI/2,0,0],false);
    flame.userData.engineFlame=true;
  }

  addTurret(group, teamColor, pos, size=1, yaw=0) {
    const hull=this.material(teamColor,'dark');
    const base=this.addMesh(group,new THREE.CylinderGeometry(.55,.72,.3,10),hull,pos,[size,size,size],[0,0,0]);
    base.rotation.y=yaw;
    this.addBox(base,hull,[0,.3,0],[.75,.32,.82]);
    this.addMesh(base,new THREE.CylinderGeometry(.07,.09,1.2,8),hull,[.24,.38,-.72],[1,1,1],[Math.PI/2,0,0]);
    this.addMesh(base,new THREE.CylinderGeometry(.07,.09,1.2,8),hull,[-.24,.38,-.72],[1,1,1],[Math.PI/2,0,0]);
  }

  addLightStrips(group, teamColor, length, y=0, z=0) {
    const mat=new THREE.MeshBasicMaterial({color:teamColor,transparent:true,opacity:.92,blending:THREE.AdditiveBlending,toneMapped:false});
    this.addBox(group,mat,[length*.48,y,z],[length*.68,.035,.035]);
    this.addBox(group,mat,[-length*.48,y,z],[length*.68,.035,.035]);
  }

  create(type, teamColor) {
    const stats=ProceduralShipFactory.stats(type);
    const root=new THREE.Group();
    root.name=`${type}-ship`;
    root.userData.type=type;
    const visual=new THREE.Group();root.add(visual);
    const hull=this.material(teamColor,'hull'), dark=this.material(teamColor,'dark'), glass=this.material(teamColor,'glass');

    switch(type){
      case 'mothership': this.buildMothership(visual,teamColor,hull,dark,glass); break;
      case 'battlecruiser': this.buildBattlecruiser(visual,teamColor,hull,dark,glass); break;
      case 'destroyer': this.buildDestroyer(visual,teamColor,hull,dark,glass); break;
      case 'frigate': this.buildFrigate(visual,teamColor,hull,dark,glass); break;
      case 'corvette': this.buildCorvette(visual,teamColor,hull,dark,glass); break;
      case 'fighter': this.buildFighter(visual,teamColor,hull,dark,glass); break;
      case 'harvester': this.buildHarvester(visual,teamColor,hull,dark,glass); break;
    }

    visual.scale.setScalar(stats.scale);
    visual.rotation.y=Math.PI;
    const ringGeo=new THREE.RingGeometry(stats.radius*.82,stats.radius*.89,64);
    ringGeo.rotateX(-Math.PI/2);
    const ringMat=new THREE.MeshBasicMaterial({color:teamColor,transparent:true,opacity:0,side:THREE.DoubleSide,depthWrite:false});
    const selectionRing=new THREE.Mesh(ringGeo,ringMat);selectionRing.position.y=-stats.radius*.36;root.add(selectionRing);
    root.userData.selectionRing=selectionRing;

    const markerMat=new THREE.SpriteMaterial({color:teamColor,transparent:true,opacity:0,depthTest:false,depthWrite:false});
    const marker=new THREE.Sprite(markerMat);marker.scale.setScalar(stats.radius*.45);marker.position.y=stats.radius*.75;root.add(marker);root.userData.marker=marker;
    return { object:root, stats };
  }

  buildMothership(g,c,h,d,glass){
    this.addHullPrism(g,h,15.5,11.8,7.4,1.7,[0,0,0],.2);
    this.addBox(g,d,[0,-.4,-.4],[5.3,.48,12.3]);
    this.addBox(g,h,[0,1.05,-2.5],[4.2,1.3,6.8]);
    this.addBox(g,h,[0,2.0,-4.3],[2.7,1.05,3.0]);
    this.addBox(g,glass,[0,2.52,-5.0],[1.48,.24,1.08],[0,0,0],.6);
    for(const side of [-1,1]){
      this.addBox(g,h,[side*5.0,.42,1.4],[2.0,.62,10.7]);
      this.addBox(g,d,[side*6.15,.1,2.4],[.32,.35,8.3]);
      for(let z=-5;z<6;z+=2.2)this.addBox(g,new THREE.MeshBasicMaterial({color:c,toneMapped:false}),[side*6.35,.18,z],[.08,.08,.72]);
      for(let z=4.2;z<9.8;z+=1.75)this.addEngine(g,c,[side*3.5,-.1,z],[1.2,1.1,1.4]);
    }
    this.addBox(g,d,[0,-.2,-8.2],[4.2,.55,.18]);
    this.addLightStrips(g,c,5.2,-.72,-3.1);
    for(const x of [-3.9,-2,0,2,3.9]) for(const z of [-5.5,-1.7,2.2]) this.addTurret(g,c,[x,1.25,z],.42,x*.04);
    for(const x of [-2.8,2.8]){this.addBox(g,h,[x,1.35,5.5],[1.25,.7,3.0]);this.addBox(g,d,[x,1.76,4.7],[.65,.2,1.5]);}
    for(const x of [-4.5,4.5]){this.addMesh(g,new THREE.CylinderGeometry(.1,.12,3.2,8),d,[x,2.1,-5.0],[1,1,1],[0,0,.22*x]);}
  }

  buildBattlecruiser(g,c,h,d,glass){
    this.addHullPrism(g,h,11.8,7.2,4.6,1.4,[0,0,0],.18);
    this.addBox(g,d,[0,-.25,1.0],[3.2,.42,8.8]);
    this.addBox(g,h,[0,.9,-2.7],[2.7,1.0,4.0]);
    this.addBox(g,glass,[0,1.5,-3.7],[1.08,.18,.76],[0,0,0],.6);
    for(const s of [-1,1]){
      this.addBox(g,h,[s*3.3,.2,1.1],[1.1,.65,7.9]);
      this.addBox(g,d,[s*4.05,-.02,1.8],[.28,.27,6.1]);
      for(let z=4.4;z<8.0;z+=1.55)this.addEngine(g,c,[s*2.2,-.2,z],[.92,.92,1.14]);
      this.addTurret(g,c,[s*2.2,.95,-4.5],.48,s*.08);
      this.addTurret(g,c,[s*2.3,.85,.2],.5,s*.05);
    }
    this.addTurret(g,c,[0,1.18,-5.9],.7,0);this.addTurret(g,c,[0,1.12,2.5],.62,0);
    this.addLightStrips(g,c,3.5,-.58,-1.0);
  }

  buildDestroyer(g,c,h,d,glass){
    this.addHullPrism(g,h,8.0,5.4,3.35,1.13,[0,0,0],.16);
    this.addBox(g,h,[0,.75,-1.9],[2.0,.72,3.2]);this.addBox(g,glass,[0,1.12,-2.6],[.78,.16,.62],[0,0,0],.55);
    for(const s of [-1,1]){this.addBox(g,h,[s*2.25,.05,.8],[.82,.55,5.4]);this.addEngine(g,c,[s*1.55,-.2,4.6],[.75,.72,.95]);this.addTurret(g,c,[s*1.55,.8,-2.9],.42,s*.08);}
    this.addTurret(g,c,[0,.92,-3.85],.58);this.addTurret(g,c,[0,.9,1.1],.5);
    this.addLightStrips(g,c,2.5,-.49,-.5);
  }

  buildFrigate(g,c,h,d,glass){
    this.addBox(g,h,[0,0,0],[2.0,.72,5.7],[0,0,0],.55);
    this.addBox(g,h,[0,.65,-1.25],[1.45,.55,2.3]);this.addBox(g,glass,[0,1.0,-1.9],[.75,.18,.62]);
    for(const s of [-1,1]){this.addBox(g,d,[s*1.75,-.05,.7],[.32,.32,3.3]);this.addEngine(g,c,[s*.95,-.12,3.45],[.64,.62,.82]);}
    this.addTurret(g,c,[0,.85,-2.7],.5);this.addTurret(g,c,[0,.78,.75],.39);
    this.addLightStrips(g,c,1.9,-.42,-.2);
  }

  buildCorvette(g,c,h,d,glass){
    this.addBox(g,h,[0,0,0],[1.65,.54,3.55],[0,0,0],.68);
    this.addBox(g,glass,[0,.5,-1.15],[.85,.24,.78]);
    this.addBox(g,d,[0,-.28,.45],[1.3,.22,2.0]);
    for(const s of [-1,1]){this.addBox(g,h,[s*1.42,0,.55],[.55,.33,1.9],[0,0,s*.06]);this.addEngine(g,c,[s*.86,-.08,2.25],[.48,.46,.64]);}
    this.addTurret(g,c,[0,.57,-1.65],.36);
    this.addLightStrips(g,c,1.1,-.33,.0);
  }

  buildFighter(g,c,h,d,glass){
    this.addBox(g,h,[0,0,0],[.92,.28,2.45],[0,0,0],.72);
    this.addBox(g,glass,[0,.3,-.65],[.48,.2,.72]);
    for(const s of [-1,1]){this.addBox(g,h,[s*.9,-.02,.2],[1.0,.12,1.25],[0,s*.1,s*.04]);this.addEngine(g,c,[s*.38,-.03,1.35],[.22,.22,.35]);}
    this.addMesh(g,new THREE.CylinderGeometry(.035,.045,1.25,6),d,[.36,-.02,-1.3],[1,1,1],[Math.PI/2,0,0]);
    this.addMesh(g,new THREE.CylinderGeometry(.035,.045,1.25,6),d,[-.36,-.02,-1.3],[1,1,1],[Math.PI/2,0,0]);
  }

  buildHarvester(g,c,h,d,glass){
    this.addBox(g,h,[0,0,0],[2.25,.8,4.4],[0,0,0],.6);
    this.addBox(g,d,[0,-.45,.2],[1.8,.32,2.8]);this.addBox(g,glass,[0,.72,-1.2],[1.1,.25,.9]);
    for(const s of [-1,1]){this.addBox(g,h,[s*1.9,.0,.5],[.62,.54,2.9]);this.addEngine(g,c,[s*1.1,-.12,2.7],[.55,.52,.72]);}
    this.addMesh(g,new THREE.TorusGeometry(1.15,.12,8,32),d,[0,-.65,-2.3],[1,.55,1],[Math.PI/2,0,0]);
    this.addLightStrips(g,c,1.6,-.49,.3);
  }
}
