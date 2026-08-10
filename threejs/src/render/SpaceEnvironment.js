import * as THREE from 'three';

export class SpaceEnvironment {
  constructor(scene, renderer) {
    this.scene = scene;
    this.renderer = renderer;
    this.time = 0;
    this.nebula = null;
    this.stars = [];
    this.asteroidBelts = [];
    this.sunGlow = null;
  }

  build() {
    this.buildNebula();
    this.buildStarLayers();
    this.buildPlanet();
    this.buildAsteroids();
    this.buildDust();
  }

  buildNebula() {
    const geo = new THREE.SphereGeometry(90000, 48, 32);
    const mat = new THREE.ShaderMaterial({
      side: THREE.BackSide,
      depthWrite: false,
      uniforms: { uTime: { value: 0 }, uTint: { value: new THREE.Color(0x162248) } },
      vertexShader: `varying vec3 vDir; void main(){ vDir=normalize(position); gl_Position=projectionMatrix*modelViewMatrix*vec4(position,1.0); }`,
      fragmentShader: `
        precision highp float;
        varying vec3 vDir; uniform float uTime; uniform vec3 uTint;
        float hash(vec3 p){p=fract(p*.1031);p+=dot(p,p.yzx+33.33);return fract((p.x+p.y)*p.z);}
        float n3(vec3 p){vec3 i=floor(p),f=fract(p);f=f*f*(3.-2.*f);return mix(mix(mix(hash(i),hash(i+vec3(1,0,0)),f.x),mix(hash(i+vec3(0,1,0)),hash(i+vec3(1,1,0)),f.x),f.y),mix(mix(hash(i+vec3(0,0,1)),hash(i+vec3(1,0,1)),f.x),mix(hash(i+vec3(0,1,1)),hash(i+vec3(1,1,1)),f.x),f.y),f.z);}
        float fbm(vec3 p){float a=.5,s=0.;for(int i=0;i<5;i++){s+=a*n3(p);p=p*2.03+vec3(1.7,-1.2,.8);a*=.5;}return s;}
        void main(){
          vec3 d=normalize(vDir); float band=pow(max(0.,1.-abs(d.y*.78+d.x*.12)),2.6);
          float f=fbm(d*5.3+vec3(.0,uTime*.001,.0)); float wisps=smoothstep(.42,.86,f)*band;
          vec3 base=mix(vec3(.004,.007,.018),uTint*.21,band*.7);
          vec3 purple=vec3(.18,.06,.28)*wisps*.46; vec3 cyan=vec3(.02,.12,.18)*pow(wisps,1.7)*.55;
          gl_FragColor=vec4(base+purple+cyan,1.0);
        }`
    });
    this.nebula = new THREE.Mesh(geo, mat);
    this.scene.add(this.nebula);
  }

  makeStarTexture() {
    const size = 64;
    const c = document.createElement('canvas'); c.width = c.height = size;
    const x = c.getContext('2d');
    const g = x.createRadialGradient(size/2,size/2,0,size/2,size/2,size/2);
    g.addColorStop(0,'rgba(255,255,255,1)');
    g.addColorStop(.08,'rgba(210,240,255,.95)');
    g.addColorStop(.32,'rgba(120,190,255,.3)');
    g.addColorStop(1,'rgba(0,0,0,0)');
    x.fillStyle=g;x.fillRect(0,0,size,size);
    const tex = new THREE.CanvasTexture(c); tex.colorSpace = THREE.SRGBColorSpace;
    return tex;
  }

  buildStarLayers() {
    const tex = this.makeStarTexture();
    const layers = [
      { count: 6800, radius: 82000, size: 8, opacity: .52 },
      { count: 1600, radius: 72000, size: 18, opacity: .78 },
      { count: 180, radius: 65000, size: 38, opacity: .95 }
    ];
    for (const l of layers) {
      const pos = new Float32Array(l.count * 3);
      const col = new Float32Array(l.count * 3);
      const tmp = new THREE.Color();
      for (let i=0;i<l.count;i++) {
        const v = new THREE.Vector3().randomDirection().multiplyScalar(l.radius * (0.74 + Math.random()*.26));
        pos.set([v.x,v.y,v.z], i*3);
        const r = Math.random();
        tmp.set(r < .11 ? 0xffd2a8 : r < .28 ? 0x9fd4ff : 0xe9f3ff);
        col.set([tmp.r,tmp.g,tmp.b], i*3);
      }
      const geo = new THREE.BufferGeometry();
      geo.setAttribute('position', new THREE.BufferAttribute(pos, 3));
      geo.setAttribute('color', new THREE.BufferAttribute(col, 3));
      const mat = new THREE.PointsMaterial({ map: tex, size: l.size, vertexColors: true, transparent: true, opacity: l.opacity, blending: THREE.AdditiveBlending, depthWrite: false, sizeAttenuation: true });
      const p = new THREE.Points(geo, mat);
      this.scene.add(p); this.stars.push(p);
    }
  }

  buildPlanet() {
    const group = new THREE.Group();
    group.position.set(-7700, 1800, -11200);
    const radius = 3600;
    const planetMat = new THREE.ShaderMaterial({
      uniforms: {
        lightDir: { value: new THREE.Vector3(-.55,.38,.72).normalize() },
        ocean: { value: new THREE.Color(0x072e4d) },
        land: { value: new THREE.Color(0x47715f) },
        cloud: { value: new THREE.Color(0xe1edf2) }
      },
      vertexShader: `varying vec3 vN;varying vec3 vP;void main(){vN=normalize(normalMatrix*normal);vP=position;gl_Position=projectionMatrix*modelViewMatrix*vec4(position,1.);}`,
      fragmentShader: `
        precision highp float; varying vec3 vN,vP; uniform vec3 lightDir,ocean,land,cloud;
        float h(vec3 p){p=fract(p*.3183099+.1);p*=17.;return fract(p.x*p.y*p.z*(p.x+p.y+p.z));}
        float n(vec3 p){vec3 i=floor(p),f=fract(p);f=f*f*(3.-2.*f);return mix(mix(mix(h(i),h(i+vec3(1,0,0)),f.x),mix(h(i+vec3(0,1,0)),h(i+vec3(1,1,0)),f.x),f.y),mix(mix(h(i+vec3(0,0,1)),h(i+vec3(1,0,1)),f.x),mix(h(i+vec3(0,1,1)),h(i+vec3(1,1,1)),f.x),f.y),f.z);}
        float fbm(vec3 p){float s=0.,a=.5;for(int i=0;i<5;i++){s+=a*n(p);p*=2.07;a*=.5;}return s;}
        void main(){
          vec3 d=normalize(vP); float terrain=fbm(d*5.2)+.22*fbm(d*17.); float landMask=smoothstep(.49,.58,terrain);
          float clouds=smoothstep(.60,.76,fbm(d*13.+vec3(2.,7.,1.)));
          float ndl=max(.0,dot(normalize(vN),normalize(lightDir))); float dusk=smoothstep(-.18,.22,dot(normalize(vN),normalize(lightDir)));
          vec3 base=mix(ocean,land,landMask); base=mix(base,cloud,clouds*.72);
          vec3 night=base*.055 + vec3(.015,.026,.06); vec3 lit=base*(.22+1.25*pow(ndl,.72));
          gl_FragColor=vec4(mix(night,lit,dusk),1.);
        }`
    });
    const planet = new THREE.Mesh(new THREE.SphereGeometry(radius, 96, 64), planetMat);
    group.add(planet);
    const atmos = new THREE.Mesh(new THREE.SphereGeometry(radius*1.035, 72, 48), new THREE.ShaderMaterial({
      transparent:true, side:THREE.BackSide, blending:THREE.AdditiveBlending, depthWrite:false,
      uniforms:{ glowColor:{value:new THREE.Color(0x5ac9ff)} },
      vertexShader:`varying vec3 vN;varying vec3 vV;void main(){vec4 mv=modelViewMatrix*vec4(position,1.);vN=normalize(normalMatrix*normal);vV=normalize(-mv.xyz);gl_Position=projectionMatrix*mv;}`,
      fragmentShader:`varying vec3 vN,vV;uniform vec3 glowColor;void main(){float f=pow(1.-max(0.,dot(vN,vV)),3.2);gl_FragColor=vec4(glowColor*f, f*.42);}`
    }));
    group.add(atmos);
    const ringGeo = new THREE.RingGeometry(radius*1.55, radius*2.35, 192, 1);
    ringGeo.rotateX(-Math.PI/2);
    const ringMat = new THREE.MeshBasicMaterial({ color:0x8e8b78, transparent:true, opacity:.16, side:THREE.DoubleSide, depthWrite:false });
    const ring = new THREE.Mesh(ringGeo, ringMat); ring.rotation.z=.24; ring.rotation.x=.31; group.add(ring);
    this.scene.add(group);
    this.planetGroup = group;

    const sun = new THREE.Sprite(new THREE.SpriteMaterial({ map:this.makeStarTexture(), color:0xffd6a0, transparent:true, blending:THREE.AdditiveBlending, depthWrite:false }));
    sun.position.set(-27000, 15000, 26000); sun.scale.setScalar(4200); this.scene.add(sun); this.sunGlow=sun;
  }

  buildAsteroids() {
    const geometry = new THREE.IcosahedronGeometry(72, 1);
    const material = new THREE.MeshStandardMaterial({ color:0x322f2d, roughness:.95, metalness:.03 });
    const count = 950;
    const mesh = new THREE.InstancedMesh(geometry, material, count);
    mesh.instanceMatrix.setUsage(THREE.StaticDrawUsage);
    const dummy = new THREE.Object3D();
    for (let i=0;i<count;i++) {
      const t = i / count * Math.PI*2 + Math.random()*.16;
      const radius = 4300 + Math.random()*2600;
      const y = (Math.random()-.5)*1250;
      dummy.position.set(Math.cos(t)*radius + 900, y - 400, Math.sin(t)*radius - 950);
      dummy.rotation.set(Math.random()*Math.PI,Math.random()*Math.PI,Math.random()*Math.PI);
      const s = 0.22 + Math.pow(Math.random(),2.2)*3.9;
      dummy.scale.set(s*(.7+Math.random()*.8),s*(.65+Math.random()*.75),s*(.7+Math.random()*.95));
      dummy.updateMatrix(); mesh.setMatrixAt(i,dummy.matrix);
    }
    mesh.instanceMatrix.needsUpdate=true;
    this.scene.add(mesh); this.asteroidBelts.push(mesh);
  }

  buildDust() {
    const count=1800, pos=new Float32Array(count*3);
    for(let i=0;i<count;i++){
      const r=18000*Math.cbrt(Math.random()); const v=new THREE.Vector3().randomDirection().multiplyScalar(r); pos.set([v.x,v.y*.4,v.z],i*3);
    }
    const geo=new THREE.BufferGeometry();geo.setAttribute('position',new THREE.BufferAttribute(pos,3));
    const mat=new THREE.PointsMaterial({color:0x78b6c7,size:3.5,transparent:true,opacity:.11,depthWrite:false,blending:THREE.AdditiveBlending});
    this.dust=new THREE.Points(geo,mat);this.scene.add(this.dust);
  }

  update(dt, camera) {
    this.time += dt;
    if (this.nebula) this.nebula.material.uniforms.uTime.value = this.time;
    this.stars.forEach((s,i)=>s.rotation.y += dt * (0.00025 + i*0.0001));
    if (this.planetGroup) this.planetGroup.rotation.y += dt * .004;
    if (this.dust) { this.dust.rotation.y += dt*.003; this.dust.position.copy(camera.position).multiplyScalar(.03); }
  }
}
