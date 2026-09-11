import json, io, re

# ---------- balance：移除 5 单位与 5 生产（保留 apc / rocket_artillery / splash_damage） ----------
p = 'config/balance/demo.balance.v1.json'
d = json.load(open(p, encoding='utf-8'))
removed = {'heavy_tank', 'hover_bike', 'drop_ship', 'supply_truck', 'ambulance'}
d['unitTypes'] = [u for u in d['unitTypes'] if u['id'] not in removed]
d['productions'] = [x for x in d['productions'] if x['id'] not in removed]
io.open(p, 'w', encoding='utf-8').write(json.dumps(d, ensure_ascii=False, indent=1))

# ---------- assets 清单 ----------
p2 = 'config/godot/demo.assets.v1.json'
d2 = json.load(open(p2, encoding='utf-8'))
d2['unitAssets'] = [u for u in d2['unitAssets'] if u['unitTypeId'] not in removed]
io.open(p2, 'w', encoding='utf-8').write(json.dumps(d2, ensure_ascii=False, indent=1))

# ---------- contracts 白名单 ----------
p3 = 'source/csharp/Application/Configuration/BalanceCatalogContracts.cs'
s = io.open(p3, encoding='utf-8').read()
for rid in removed:
    s = s.replace('            new("%s"),\n' % rid, '')
io.open(p3, 'w', encoding='utf-8', newline='').write(s)

# ---------- 侧栏：删 5 项 + 5 常量 ----------
p4 = 'source/match/hud/ra3/Ra3Sidebar.gd'
s = io.open(p4, encoding='utf-8').read()
for const in ['HeavyTankUnit', 'HoverBikeUnit', 'ArmyTruckUnit', 'AmbulanceUnit', 'DropShipUnit']:
    s = re.sub(r'const %s := "res://source/match/units/[A-Za-z]+\.tscn"\n' % const, '', s)
for line in [
    '			{"scene": HeavyTankUnit, "caption": "重型坦克", "icon": "heavy_tank"},\n',
    '			{"scene": HoverBikeUnit, "caption": "悬浮摩托", "icon": "hover_bike"},\n',
    '			{"scene": ArmyTruckUnit, "caption": "运输卡车", "icon": "army_truck"},\n',
    '			{"scene": AmbulanceUnit, "caption": "救护车", "icon": "ambulance"},\n',
    '			{"scene": DropShipUnit, "caption": "运输机", "icon": "drop_ship"},\n',
]:
    s = s.replace(line, '')
# 生产网格吃满侧栏剩余空间（下面明明有位置）——滚动区改为 EXPAND_FILL
s = s.replace('''	grid_scroll.custom_minimum_size = Vector2(0, CELL_SIZE * 3 + 16)
	grid_scroll.size_flags_vertical = Control.SIZE_SHRINK_BEGIN''',
'''	grid_scroll.custom_minimum_size = Vector2(0, CELL_SIZE * 3 + 16)
	grid_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL''')
io.open(p4, 'w', encoding='utf-8', newline='').write(s)

# ---------- 直升机武器改机炮（火箭特效音效替换） ----------
p5 = 'config/balance/demo.balance.v1.json'
d5 = json.load(open(p5, encoding='utf-8'))
for u in d5['unitTypes']:
    if u['id'] == 'helicopter':
        u['weaponIds'] = ['apc_autocannon']
io.open(p5, 'w', encoding='utf-8').write(json.dumps(d5, ensure_ascii=False, indent=1))
print('cleanup ok')
