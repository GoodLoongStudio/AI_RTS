import * as THREE from 'three';
import { RoundedBoxGeometry } from 'three/addons/geometries/RoundedBoxGeometry.js';

const SHIP_STATS = {
  mothership:    { label:'æ¯èˆ°',      scale:10.0, hp:9000, speed:34,  range:1300, damage:90,  cooldown:1.45, radius:230, value:9 },
  battlecruiser: { label:'æˆ˜åˆ—å·¡æ´‹èˆ°', scale:6.4,  hp:4200, speed:48,  range:1200, damage:160, cooldown:1.15, radius:150, value:7 },
  destroyer:     { label:'é©±é€èˆ°',    scale:4.0,  hp:2100, speed:65,  range:940,  damage:105, cooldown:1.0,  radius:98,  value:5 },
  frigate:       { label:'æŠ¤å«èˆ°',    scale:2.45, hp:980,  speed:88,  range:720,  damage:58,  cooldown:.78,  radius:62,  value:3 },
  corvette:      { label:'è½»å‹èˆ°',    scale:1.35, hp:420,  speed:142, range:520,  damage:28,  cooldown:.45,  radius:34,  value:2 },
  fighter:       { label:'æ”»å‡»æœº',    scale:.64,  hp:125,  speed:230, range:360,  damage:11,  cooldown:.24,  radius:15,  value:1 },
  harvester:     { label:'èµ„æºé‡‡é›†èˆ°', scale:1.85, hp:560,  speed:82,  range:0,    damage:0,   cooldown:2,    radius:42,  value:2 }
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
    const g = bevel > 0
      ? new RoundedBoxGeometry(1, 1, 1, bevel > .55 ? 3 : 2, Math.min(.14, .055 + bevel * .055))
      : new THREE.BoxGeometry(1,1,1);
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
      this.addBox(g,d,[side*6.15,.1,2.4],[.32"Âã3RÃ‚ã5Ò“°¢f÷"†ÆWB£ÒÓS·£Ãc·¢³Ó"ã"—F†—2æFD&÷‚†rÆæWrD…$TRäÖW6„&6–4ÖFW&–Â‡¶6öÆ÷#¦2ÇFöæTÖVC¦fÇ6WÒ’Å·6–FR£bã3RÂã‚Ç¥ÒÅ²ã‚Âã‚Âãs%Ò“°¢f÷"†ÆWB£ÓBã#·£Ã’ãƒ·¢³ÓãsR—F†—2æFDVæv–æR†rÆ2Å·6–FR£2ãRÂÒãÇ¥ÒÅ³ã"ÃãÃãEÒ“°¢Ğ¢F†—2æFD&÷‚†rÆBÅ³ÂÒã"ÂÓ‚ã%ÒÅ³Bã"ÂãSRÂã…Ò“°¢F†—2æFDÆ–v‡E7G&—2†rÆ2ÃRã"ÂÒãs"ÂÓ2ã“°¢f÷"†6öç7B‚öb²Ó2ã’ÂÓ"ÃÃ"Ã2ã•Ò’f÷"†6öç7B¢öb²ÓRãRÂÓãrÃ"ã%Ò’F†—2æFEGW'&WB†rÆ2Å·‚Ãã#RÇ¥ÒÂãC"Ç‚¢ãB“°¢f÷"†6öç7B‚öb²Ó"ã‚Ã"ã…Ò—·F†—2æFD&÷‚†rÆ‚Å·‚Ãã3RÃRãUÒÅ³ã#RÂãrÃ2ãÒ“·F†—2æFD&÷‚†rÆBÅ·‚ÃãsbÃBãuÒÅ²ãcRÂã"ÃãUÒ“·Ğ¢f÷"†6öç7B‚öb²ÓBãRÃBãUÒ—·F†—2æFDÖW6‚†rÆæWrD…$TRä7–Æ–æFW$vVöÖWG'’‚ãÂã"Ã2ã"Ã‚’ÆBÅ·‚Ã"ãÂÓRãÒÅ³ÃÃÒÅ³ÃÂã#"§…Ò“·Ğ¢Ğ ¢'V–ÆD&GFÆV7'V—6W"†rÆ2Æ‚ÆBÆvÆ72—°¢F†—2æFD‡VÆÅ&—6Ò†rÆ‚Ãã‚Ãrã"ÃBãbÃãBÅ³ÃÃÒÂã‚“°¢F†—2æFD&÷‚†rÆBÅ³ÂÒã#RÃãÒÅ³2ã"ÂãC"Ã‚ã…Ò“°¢F†—2æFD&÷‚†rÆ‚Å³Âã’ÂÓ"ãuÒÅ³"ãrÃãÃBãÒ“°¢F†—2æFD&÷‚†rÆvÆ72Å³ÃãRÂÓ2ãuÒÅ³ã‚Âã‚ÂãseÒÅ³ÃÃÒÂãb“°¢f÷"†6öç7B2öb²ÓÃÒ—°¢F†—2æFD&÷‚†rÆ‚Å·2£2ã2Âã"ÃãÒÅ³ãÂãcRÃrã•Ò“°¢F†—2æFD&÷‚†rÆBÅ·2£BãRÂÒã"Ãã…ÒÅ²ã#‚Âã#rÃbãÒ“°¢f÷"†ÆWB£ÓBãC·£Ã‚ã·¢³ÓãSR—F†—2æFDVæv–æR†rÆ2Å·2£"ã"ÂÒã"Ç¥ÒÅ²ã“"Âã“"ÃãEÒ“°¢F†—2æFEGW'&WB†rÆ2Å·2£"ã"Âã“RÂÓBãUÒÂãC‚Ç2¢ã‚“°¢F†—2æFEGW'&WB†rÆ2Å·2£"ã2ÂãƒRÂã%ÒÂãRÇ2¢ãR“°¢Ğ¢F†—2æFEGW'&WB†rÆ2Å³Ãã‚ÂÓRã•ÒÂãrÃ“·F†—2æFEGW'&WB†rÆ2Å³Ãã"Ã"ãUÒÂãc"Ã“°¢F†—2æFDÆ–v‡E7G&—2†rÆ2Ã2ãRÂÒãS‚ÂÓã“°¢Ğ ¢'V–ÆDFW7G&÷–W"†rÆ2Æ‚ÆBÆvÆ72—°¢F†—2æFD‡VÆÅ&—6Ò†rÆ‚Ã‚ãÃRãBÃ2ã3RÃã2Å³ÃÃÒÂãb“°¢F†—2æFD&÷‚†rÆ‚Å³ÂãsRÂÓã•ÒÅ³"ãÂãs"Ã2ã%Ò“·F†—2æFD&÷‚†rÆvÆ72Å³Ãã"ÂÓ"ãeÒÅ²ãs‚ÂãbÂãc%ÒÅ³ÃÃÒÂãSR“°¢f÷"†6öç7B2öb²ÓÃÒ—·F†—2æFD&÷‚†rÆ‚Å·2£"ã#RÂãRÂã…ÒÅ²ãƒ"ÂãSRÃRãEÒ“·F†—2æFDVæv–æR†rÆ2Å·2£ãSRÂÒã"ÃBãeÒÅ²ãsRÂãs"Âã“UÒ“·F†—2æFEGW'&WB†rÆ2Å·2£ãSRÂã‚ÂÓ"ã•ÒÂãC"Ç2¢ã‚“·Ğ¢F†—2æFEGW'&WB†rÆ2Å³Âã“"ÂÓ2ãƒUÒÂãS‚“·F†—2æFEGW'&WB†rÆ2Å³Âã’ÃãÒÂãR“°¢F†—2æFDÆ–v‡E7G&—2†rÆ2Ã"ãRÂÒãC’ÂÒãR“°¢Ğ ¢'V–ÆDg&–vFR†rÆ2Æ‚ÆBÆvÆ72—°¢F†—2æFD&÷‚†rÆ‚Å³ÃÃÒÅ³"ãÂãs"ÃRãuÒÅ³ÃÃÒÂãSR“°¢F†—2æFD&÷‚†rÆ‚Å³ÂãcRÂÓã#UÒÅ³ãCRÂãSRÃ"ã5Ò“·F†—2æFD&÷‚†rÆvÆ72Å³ÃãÂÓã•ÒÅ²ãsRÂã‚Âãc%Ò“°¢f÷"†6öç7B2öb²ÓÃÒ—·F†—2æFD&÷‚†rÆBÅ·2£ãsRÂÒãRÂãuÒÅ²ã3"Âã3"Ã2ã5Ò“·F†—2æFDVæv–æR†rÆ2Å·2¢ã“RÂÒã"Ã2ãCUÒÅ²ãcBÂãc"Âãƒ%Ò“·Ğ¢F†—2æFEGW'&WB†rÆ2Å³ÂãƒRÂÓ"ãuÒÂãR“·F†—2æFEGW'&WB†rÆ2Å³Âãs‚ÂãsUÒÂã3’“°¢F†—2æFDÆ–v‡E7G&—2†rÆ2Ãã’ÂÒãC"ÂÒã"“°¢Ğ ¢'V–ÆD6÷'fWGFR†rÆ2Æ‚ÆBÆvÆ72—°¢F†—2æFD&÷‚†rÆ‚Å³ÃÃÒÅ³ãcRÂãSBÃ2ãSUÒÅ³ÃÃÒÂãc‚“°¢F†—2æFD&÷‚†rÆvÆ72Å³ÂãRÂÓãUÒÅ²ãƒRÂã#BÂãs…Ò“°¢F†—2æFD&÷‚†rÆBÅ³ÂÒã#‚ÂãCUÒÅ³ã2Âã#"Ã"ãÒ“°¢f÷"†6öç7B2öb²ÓÃÒ—·F†—2æFD&÷‚†rÆ‚Å·2£ãC"ÃÂãSUÒÅ²ãSRÂã32Ãã•ÒÅ³ÃÇ2¢ãeÒ“·F†—2æFDVæv–æR†rÆ2Å·2¢ãƒbÂÒã‚Ã"ã#UÒÅ²ãC‚ÂãCbÂãcEÒ“·Ğ¢F†—2æFEGW'&WB†rÆ2Å³ÂãSrÂÓãcUÒÂã3b“°¢F†—2æFDÆ–v‡E7G&—2†rÆ2ÃãÂÒã32Âã“°¢Ğ ¢'V–ÆDf–v‡FW"†rÆ2Æ‚ÆBÆvÆ72—°¢F†—2æFD&÷‚†rÆ‚Å³ÃÃÒÅ²ã“"Âã#‚Ã"ãCUÒÅ³ÃÃÒÂãs"“°¢F†—2æFD&÷‚†rÆvÆ72Å³Âã2ÂÒãcUÒÅ²ãC‚Âã"Âãs%Ò“°¢f÷"†6öç7B2öb²ÓÃÒ—·F†—2æFD&÷‚†rÆ‚Å·2¢ã’ÂÒã"Âã%ÒÅ³ãÂã"Ãã#UÒÅ³Ç2¢ãÇ2¢ãEÒ“·F†—2æFDVæv–æR†rÆ2Å·2¢ã3‚ÂÒã2Ãã3UÒÅ²ã#"Âã#"Âã3UÒ“·Ğ¢F†—2æFDÖW6‚†rÆæWrD…$TRä7–Æ–æFW$vVöÖWG'’‚ã3RÂãCRÃã#RÃb’ÆBÅ²ã3bÂÒã"ÂÓã5ÒÅ³ÃÃÒÅ´ÖF‚å’ó"ÃÃÒ“°¢F†—2æFDÖW6‚†rÆæWrD…$TRä7–Æ–æFW$vVöÖWG'’‚ã3RÂãCRÃã#RÃb’ÆBÅ²Òã3bÂÒã"ÂÓã5ÒÅ³ÃÃÒÅ´ÖF‚å’ó"ÃÃÒ“°¢Ğ ¢'V–ÆD†'fW7FW"†rÆ2Æ‚ÆBÆvÆ72—°¢F†—2æFD&÷‚†rÆ‚Å³ÃÃÒÅ³"ã#RÂã‚ÃBãEÒÅ³ÃÃÒÂãb“°¢F†—2æFD&÷‚†rÆBÅ³ÂÒãCRÂã%ÒÅ³ã‚Âã3"Ã"ã…Ò“·F†—2æFD&÷‚†rÆvÆ72Å³Âãs"ÂÓã%ÒÅ³ãÂã#RÂã•Ò“°¢f÷"†6öç7B2öb²ÓÃÒ—·F†—2æFD&÷‚†rÆ‚Å·2£ã’ÂãÂãUÒÅ²ãc"ÂãSBÃ"ã•Ò“·F†—2æFDVæv–æR†rÆ2Å·2£ãÂÒã"Ã"ãuÒÅ²ãSRÂãS"Âãs%Ò“·Ğ¢F†—2æFDÖW6‚†rÆæWrD…$TRåF÷'W4vVöÖWG'’ƒãRÂã"Ã‚Ã3"’ÆBÅ³ÂÒãcRÂÓ"ã5ÒÅ³ÂãSRÃÒÅ´ÖF‚å’ó"ÃÃÒ“°¢F†—2æFDÆ–v‡E7G&—2†rÆ2ÃãbÂÒãC’Âã2“°¢Ğ§Ğ 