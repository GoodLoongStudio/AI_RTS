extends RefCounted


static func echo_extraction() -> Dictionary:
	return {
		"id": "echo_extraction_prologue",
		"chapter": "第一章 · 最后的回声",
		"title": "任务 01 · 回声撤离",
		"subtitle": "北辰失联区 / 单英雄序章",
		"map_path": "res://source/match/maps/EchoExtractionGreybox.tscn",
		"estimated_time": "10～15 分钟",
		"initial_control_mode": "hero",
		"hero_id": "vanguard_01",
		"hero_scene": "res://source/match/units/Tank.tscn",
		"hero_name": "先锋指挥单元",
		"hero_portrait_label": "先锋",
		"hero_role": "primary_combat_hero",
		"hero_is_primary": true,
		"summary": "北辰区域失去联系 72 小时。主力部队尚未完成战区接入，你将先以一个先锋指挥单元进入失联区域，在 AI 副官岚的协助下确认求救信号来源，并带回第一份可靠情报。",
		"briefing": [
			["岚 · AI副官", "指挥官，先锋链路已经建立。主力小队仍在战区外围，你目前只需要控制这个先锋单位。"],
			["岚 · AI副官", "最后一次有效通讯发生在约 72 小时前。当前没有可靠敌情，我不会把未侦察区域的信息当成事实。"],
			["岚 · AI副官", "先前往前方信号门。用 WASD 平移镜头，QE 旋转，滚轮缩放。当前 Demo 默认关闭边缘滚屏。"],
		],
		"objectives": [
			"前往信号门，确认进入失联区域的路线",
			"继续前往外围营地，调查失联现场",
			"推进到废弃车队，寻找求救信号源",
			"在废弃车队原地警戒，读取黑箱信标",
			"携带信标返回外围紧急撤离点",
			"请求撤离",
		],
		"objective_markers": {
			0: "SignalGate",
			1: "PerimeterCamp",
			2: "AbandonedConvoy",
			4: "EmergencyExtraction",
		},
		"objective_radius": 7.5,
		"epilogue": [
			["岚 · AI副官", "撤离链路已确认。我们带回了北辰区域的第一份有效信标数据。"],
			["岚 · AI副官", "求救信号并不是实时发送的。它已经重复播放了至少 63 小时。"],
			["岚 · AI副官", "下一次进入北辰区域时，正式战术小队将接入你的指挥链。"],
		],
	}
