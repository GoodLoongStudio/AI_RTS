export class HUD {
  constructor(root, fleetSystem, combatSystem){
    this.root=root;this.fleetSystem=fleetSystem;this.combatSystem=combatSystem;this.selection=null;this.selected=[];this.elapsed=0;this.flashTime=0;this.listRefresh=0;
    root.innerHTML=`
      <div class="topbar glass">
        <div class="brand"><span class="glyph">△</span><div><b>神盾远征军</b><small>ARES EXPEDITIONARY COMMAND</small></div></div>
        <div class="mission"><small>随机遭遇战 · NGC 7293 外缘</small><b>夺取制宙权并摧毁敌方母舰</b></div>
        <div class="metrics"><div><small>资源</small><b id="ru">1,200</b></div><div><small>单位</small><b id="unit-count">0</b></div><div><small>舰队强度</small><b id="fleet-strength">0</b></div><div><small>时间</small><b id="elapsed">00:00</b></div><div><small>FPS</small><b id="fps">60</b></div></div>
      </div>
      <aside class="fleet-panel glass">
        <header><div><small>战术编队</small><b>神盾指挥群</b></div><span class="status-dot">战斗就绪</span></header>
        <div id="ship-list" class="ship-list"></div>
        <footer><span>舰体 <b id="fleet-hull">100%</b></span><span>护盾 <b>100%</b></span></footer>
      </aside>
      <section class="sensor-panel glass">
        <header><small>战术星图</small><b>局部空域</b><span id="zoom-readout">1.0x</span></header>
        <canvas id="sensor" width="320" height="170"></canvas>
        <div class="commands"><button data-cmd="move">⌖<small>移动 M</small></button><button data-cmd="attack">✦<small>攻击 X</small></button><button data-cmd="focus">◎<small>聚焦 F</small></button><button data-cmd="pause">Ⅱ<small>战术暂停</small></button></div>
      </section>
      <div class="selection-info glass" id="selection-info"><small>当前选择</small><b>未选择单位</b><span>拖框选择 · 右键空域移动 · 点击敌舰攻击</span></div>
      <div class="order-toast" id="order-toast"></div>
      <div class="reticle"><i></i><i></i><i></i><i></i></div>
      <div class="help">WASD 平移 · Q/E 升降 · 中键环绕 · 滚轮缩放 · 右键下令 · Shift/Alt 改变目标高度 · X 攻击</div>`;
    this.bindButtons();this.resize();this.refreshFleetList();
  }
  bindSelection(selection){this.selection=selection;}
  bindButtons(){
    this.root.querySelector('[data-cmd="move"]').onclick=()=>{if(this.selection){this.selection.moveMode=true;this.flash('移动指令：点击目标空域');}};
    this.root.querySelector('[data-cmd="attack"]').onclick=()=>{if(this.selection){this.selection.attackMode=true;this.flash('攻击指令：点击敌方单位');}};
    this.root.querySelector('[data-cmd="focus"]').onclick=()=>{const u=this.selection?.selectedUnits?.[0];if(u){this.flash(`聚焦 ${u.label}`);window.dispatchEvent(new KeyboardEvent('keydown',{code:'KeyF'}));}};
    this.root.querySelector('[data-cmd="pause"]').onclick=()=>{this.combatSystem.paused=!this.combatSystem.paused;this.flash(this.combatSystem.paused?'战术时间暂停':'战术时间恢复');};
  }
  resize(){this.sensor=this.root.querySelector('#sensor');if(this.sensor)this.sensorCtx=this.sensor.getContext('2d');}
  refreshFleetList(){
    const el=this.root.querySelector('#ship-list');if(!el)return;const units=this.fleetSystem.getAlive('player');const groups=new Map();units.forEach(u=>groups.set(u.type,{label:u.label,count:(groups.get(u.type)?.count||0)+1}));
    el.innerHTML=[...groups.entries()].map(([type,g],i)=>`<div class="ship-row" data-type="${type}"><span class="index">${String(i+1).padStart(2,'0')}</span><span class="ship-icon">◆</span><div><b>${g.label}</b><small>${type.toUpperCase()}</small></div><strong>${String(g.count).padStart(2,'0')}</strong></div>`).join('');
    [...el.querySelectorAll('.ship-row')].forEach(row=>row.onclick=()=>{if(!this.selection)return;const list=this.fleetSystem.getAlive('player').filter(u=>u.type===row.dataset.type);this.selection.selectOnly(list);});
  }
  setSelection(units){this.selected=units;const el=this.root.querySelector('#selection-info');if(!units.length){el.innerHTML='<small>当前选择</small><b>未选择单位</b><span>拖框选择 · 点击舰船 · 双击选择同型舰</span>';return;}const hp=units.reduce((s,u)=>s+u.hp,0),max=units.reduce((s,u)=>s+u.maxHp,0);const names=new Map();units.forEach(u=>names.set(u.label,(names.get(u.label)||0)+1));el.innerHTML=`<small>当前选择 · ${units.length} 艘</small><b>${[...names].map(([n,c])=>`${n} ×${c}`).join(' · ')}</b><span>舰体完整度 ${Math.round(hp/max*100)}% · M 移动 · X 攻击 · F 聚焦</span>`;}
  flash(text){const el=this.root.querySelector('#order-toast');el.textContent=text;el.classList.add('show');this.flashTime=2.2;}
  drawSensor(camera){
    const c=this.sensorCtx,cv=this.sensor;if(!c)return;c.clearRect(0,0,cv.width,cv.height);c.fillStyle='rgba(3,10,15,.86)';c.fillRect(0,0,cv.width,cv.height);
    c.strokeStyle='rgba(89,232,255,.13)';c.lineWidth=1;for(let r=22;r<180;r+=28){c.beginPath();c.ellipse(cv.width/2,cv.height/2,r,r*.47,0,0,Math.PI*2);c.stroke();}
    c.beginPath();c.moveTo(0,cv.height/2);c.lineTo(cv.width,cv.height/2);c.moveTo(cv.width/2,0);c.lineTo(cv.width/2,cv.height);c.stroke();
    const player=this.fleetSystem.getAlive('player'),enemy=this.fleetSystem.getAlive('enemy');const all=[...player,...enemy];if(!all.length)return;const center=this.selected[0]?.object.position||player[0]?.object.position||{x:0,z:0};let span=1;all.forEach(u=>span=Math.max(span,Math.abs(u.object.position.x-center.x),Math.abs(u.object.position.z-center.z)));span=Math.max(2200,span*1.1);
    for(const u of all){const x=cv.width/2+(u.object.position.x-center.x)/span*cv.width*.42;const y=cv.height/2+(u.object.position.z-center.z)/span*cv.height*.42;c.fillStyle=u.team==='player'?'#63e9ff':'#ff5b65';const s=u.type==='mothership'?5:u.type==='battlecruiser'?4:2.2;c.beginPath();c.arc(x,y,s,0,Math.PI*2);c.fill();}
  }
  update(dt,camera,fps){
    this.elapsed+=dt;this.flashTime-=dt;if(this.flashTime<=0)this.root.querySelector('#order-toast')?.classList.remove('show');
    const p=this.fleetSystem.fleets.get('player'),alive=this.fleetSystem.getAlive('player'),enemy=this.fleetSystem.getAlive('enemy');this.root.querySelector('#ru').textContent=Math.floor(p?.resources||0).toLocaleString();this.root.querySelector('#unit-count').textContent=`${alive.length} / 120`;this.root.querySelector('#fleet-strength').textContent=Math.round(p?.strength||0);this.root.querySelector('#fps').textContent=Math.round(fps);
    const m=Math.floor(this.elapsed/60),s=Math.floor(this.elapsed%60);this.root.querySelector('#elapsed').textContent=`${String(m).padStart(2,'0')}:${String(s).padStart(2,'0')}`;
    const hull=alive.reduce((a,u)=>a+u.hp,0),max=alive.reduce((a,u)=>a+u.maxHp,0);this.root.querySelector('#fleet-hull').textContent=max?`${Math.round(hull/max*100)}%`:'0%';
    this.listRefresh-=dt;if(this.listRefresh<=0){this.listRefresh=.75;this.refreshFleetList();}this.drawSensor(camera);
    if(!enemy.length)this.flash('空域肃清完成 · 神盾远征军取得制宙权');
  }
}
