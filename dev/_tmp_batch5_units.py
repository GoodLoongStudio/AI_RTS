import json, io

# ---------- balance：5 单位 + 5 生产（武器全部复用现有，无新武器/弹头） ----------
p = 'config/balance/demo.balance.v1.json'
d = json.load(open(p, encoding='utf-8'))
have = lambda i: any(x['id'] == i for x in d['unitTypes'])

def ensure_unit(uid, hp, sight, speed, turn, arc, weapons, force_fire, producer, work, cost, domain='terrain'):
    if have(uid):
        return
    d['unitTypes'].append({
        'id': uid, 'maxHp': hp, 'sightRangeMeters': sight,
        'movement': {
            'domain': domain, 'speedMetersPerSecond': speed,
            'maxTurnDegreesPerSecond': turn, 'canReverse': True,
            'reverseSpeedMultiplier': 0.65, 'canFireWhileMoving': arc > 0,
            'movingWeaponArcDegrees': arc,
        },
        'weaponIds': weapons, 'canForceFireGround': force_fire,
    })
    d['productions'].append({
        'id': uid, 'productUnitTypeId': uid, 'requiredWork': work,
        'cost': [{'kind': 'A', 'amount': cost}],
        'allowedProducerUnitTypeIds': [producer],
    })

ensure_unit('heavy_tank', 20.0, 8.0, 2.2, 200, 120, ['tank_cannon'], True, 'vehicle_factory', 420, 1400)
ensure_unit('hover_bike', 6.0, 9.0, 4.5, 360, 90, ['apc_autocannon'], True, 'vehicle_factory', 150, 400)
ensure_unit('drop_ship', 20.0, 8.0, 4.5, 240, 0, [], False, 'aircraft_factory', 400, 1500, domain='air')
ensure_unit('supply_truck', 12.0, 7.0, 3.0, 300, 0, [], False, 'vehicle_factory', 200, 600)
ensure_unit('ambulance', 12.0, 7.0, 3.0, 300, 0, [], False, 'vehicle_factory', 240, 800)
io.open(p, 'w', encoding='utf-8').write(json.dumps(d, ensure_ascii=False, indent=1))

# ---------- assets 清单 ----------
p2 = 'config/godot/demo.assets.v1.json'
d2 = json.load(open(p2, encoding='utf-8'))
pairs = [
    ('heavy_tank', 'res://source/match/units/HeavyTank.tscn'),
    ('hover_bike', 'res://source/match/units/HoverBike.tscn'),
    ('drop_ship', 'res://source/match/units/DropShip.tscn'),
    ('supply_truck', 'res://source/match/units/ArmyTruck.tscn'),
    ('ambulance', 'res://source/match/units/Ambulance.tscn'),
]
have2 = lambda i: any(u['unitTypeId'] == i for u in d2['unitAssets'])
for tid, sp in pairs:
    if not have2(tid):
        d2['unitAssets'].append({'unitTypeId': tid, 'scenePath': sp})
io.open(p2, 'w', encoding='utf-8').write(json.dumps(d2, ensure_ascii=False, indent=1))

# ---------- contracts 白名单 ----------
p3 = 'source/csharp/Application/Configuration/BalanceCatalogContracts.cs'
s = io.open(p3, encoding='utf-8').read()
if 'heavy_tank' not in s:
    s = s.replace(
        '            new("rocket_artillery"),\n            new("command_center"),',
        '            new("rocket_artillery"),\n'
        '            new("heavy_tank"),\n            new("hover_bike"),\n'
        '            new("drop_ship"),\n            new("supply_truck"),\n'
        '            new("ambulance"),\n            new("command_center"),')
    s = s.replace(
        '            new("rocket_artillery"),\n            new("helicopter"),',
        '            new("rocket_artillery"),\n'
        '            new("heavy_tank"),\n            new("hover_bike"),\n'
        '            new("drop_ship"),\n            new("supply_truck"),\n'
        '            new("ambulance"),\n            new("helicopter"),')
    io.open(p3, 'w', encoding='utf-8', newline='').write(s)

# ---------- 侧栏页签 ----------
p4 = 'source/match/hud/ra3/Ra3Sidebar.gd'
s = io.open(p4, encoding='utf-8').read()
if 'HeavyTankUnit' not in s:
    s = s.replace(
        'const RocketArtilleryUnit := "res://source/match/units/RocketArtillery.tscn"',
        'const RocketArtilleryUnit := "res://source/match/units/RocketArtillery.tscn"\n'
        'const HeavyTankUnit := "res://source/match/units/HeavyTank.tscn"\n'
        'const HoverBikeUnit := "res://source/match/units/HoverBike.tscn"\n'
        'const ArmyTruckUnit := "res://source/match/units/ArmyTruck.tscn"\n'
        'const AmbulanceUnit := "res://source/match/units/Ambulance.tscn"\n'
        'const DropShipUnit := "res://source/match/units/DropShip.tscn"')
    s = s.replace(
        '			{"scene": RocketArtilleryUnit, "caption": "火箭炮车", "icon": "rocket"},',
        '			{"scene": RocketArtilleryUnit, "caption": "火箭炮车", "icon": "rocket"},\n'
        '			{"scene": HeavyTankUnit, "caption": "重型坦克", "icon": "heavy_tank"},\n'
        '			{"scene": HoverBikeUnit, "caption": "悬浮摩托", "icon": "hover_bike"},\n'
        '			{"scene": ArmyTruckUnit, "caption": "运输卡车", "icon": "army_truck"},\n'
        '			{"scene": AmbulanceUnit, "caption": "救护车", "icon": "ambulance"},\n'
        '			{"scene": DropShipUnit, "caption": "运输机", "icon": "drop_ship"},')
    io.open(p4, 'w', encoding='utf-8', newline='').write(s)
print('config ok')
