extends Node

## Automatic construction expands independently of idle miner count.
## Real Match, real map resources and normal AI timers/command boundary.
var _failures := 0

func _ready() -> void:
    get_tree().create_timer(170.0,true).timeout.connect(func():get_tree().quit(3))
    _run.call_deferred()

func _run() -> void:
    var settings=load("res://source/data-model/MatchSettings.gd").new()
    for controller in [Constants.PlayerType.HUMAN,Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI]:
        var p=load("res://source/data-model/PlayerSettings.gd").new()
        p.controller=controller
        p.color=Constants.Player.COLORS[settings.players.size()]
        settings.players.append(p)
    settings.visible_player=0
    var match_instance=load("res://source/match/Match.tscn").instantiate()
    match_instance.settings=settings
    match_instance.map=load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
    var resources: Array=match_instance.map.get_node("Resources").get_children()
    # Nearby economy seed and initially out-of-sight remote mine; real map
    # fixture authored before _ready, rather than forged observation data.
    resources[0].position=Vector3(412,0.6,70)
    resources[1].position=Vector3(332,0.6,70)
    for i in range(2,resources.size()):resources[i].free()
    get_tree().root.add_child(match_instance)
    get_tree().current_scene=match_instance
    await get_tree().create_timer(3.0).timeout
    var players: Array=match_instance.get_node("Players").get_children()
    var ai=players.filter(func(p):return p.has_method("own_forces_scan"))[0]
    ai.max_command_centers=2
    ai.expansion_resource_threshold=2000
    ai.add_resources({"resource_a":40000},"ScriptedAdjustment")
    var deadline:=Time.get_ticks_msec()+130000
    while Time.get_ticks_msec()<deadline:
        var snapshot: Array=ai.own_forces_scan()
        _check(not snapshot.any(func(entity):
            var order=entity.get("order",null)
            return entity.get("type_id","")=="worker" and order!=null and order.get("kind","")=="Construct"),
            "automatic construction must not dispatch miners")
        var centers:=_units(ai,"command_center")
        var refineries:=_units(ai,"ore_refinery")
        if centers.size()==2 and centers[1].is_constructed() and refineries.size()==2 and refineries[1].is_constructed():break
        await get_tree().create_timer(0.5).timeout
    var centers:=_units(ai,"command_center")
    var refineries:=_units(ai,"ore_refinery")
    _check(centers.size()==2,"naturally discovered ore causes one expansion within HQ limit")
    if centers.size()==2:
        _check(centers[0].global_position.distance_to(centers[1].global_position)>=30,"separate HQ rather than duplicate at home")
        _check(centers[1].is_constructed(),"remote construction finishes")
    _check(refineries.size()==2,"completed remote HQ receives local refinery")
    if centers.size()==2 and refineries.size()==2:
        _check(refineries[1].global_position.distance_to(centers[1].global_position)<30,"refinery anchors to expansion")
    # Explicit negative max gate retains its protection, irrespective of
    # idle workers; call with actual own snapshot, not synthetic entities.
    var economy=ai.get_node("EconomyController")
    economy.set("_number_of_pending_cc_resource_requests",0)
    ai.max_command_centers=1
    economy._enforce_number_of_ccs(economy._get_own_entities(),1)
    _check(int(economy.get("_number_of_pending_cc_resource_requests"))==0,"HQ cap still blocks expansion")
    print("Rule AI expansion smoke test completed: %d failure(s)" % _failures)
    MatchSignals.match_aborted.emit()
    get_tree().paused=true
    match_instance.queue_free()
    get_tree().current_scene=null
    await get_tree().process_frame
    await get_tree().process_frame
    get_tree().paused=false
    SmokeTestExit.request(get_tree(),0 if _failures==0 else 1)

func _units(player,type_id: String) -> Array:
    return get_tree().get_nodes_in_group("units").filter(func(u):return u.get_parent()==player and u.unit_type_id==type_id)

func _check(ok: bool,message: String) -> void:
    if not ok:
        _failures+=1
        push_error(message)
