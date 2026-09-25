# -*- coding: utf-8 -*-
"""Laya（System 1）接入的守门测试（提示词 §P3，四类缺一不可）。

1. `frame_to_questions`：ref 表 → questions 的**结构完备**（每个 actor/target/可行技能
   都出现在某个选项里；每问 ≤20；超限自动分两级）；
2. `answers_to_rows`：越界 ref / 缺项 / 非法 skill / 粗级未解析 **必须被丢弃而不是崩溃**
   （复用既有校验链的拒绝语义）；
3. 开关测试：`AIRTS_S1_BACKEND=model`（默认）时**不碰 Laya**、走原模型链路；
   `off` 时两层都关（返回 None，规则中台继续）；
4. 降级测试：模拟 Laya 抛异常 / 返回 None / 超时 → 链路回退且**日志有记录**。

这些测试不依赖 laya/torch 是否安装（用假 provider 注入）——未装 laya 的机器上
同样能守门"回退路径不炸"。
"""

import os
import sys
import time
import unittest
from typing import Any, Dict, List, Optional

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", ".."))   # source/

from adjutant_coordinator.graph import campaign as cm  # noqa: E402
from adjutant_coordinator.graph import pydantic_agents as pa  # noqa: E402
from adjutant_coordinator.graph import laya_provider as lp  # noqa: E402
from adjutant_coordinator.graph.task_patch import (  # noqa: E402
    DecisionFrame, SKILL_ALLOWED_TARGETS, SKILL_HOLD, answers_to_decode,
    answers_to_rows, feasible_skills, frame_to_questions,
)


def make_frame(actors: Optional[Dict[str, Dict[str, Any]]] = None,
               targets: Optional[Dict[str, Dict[str, Any]]] = None,
               params: Optional[Dict[str, Any]] = None,
               **kwargs: Any) -> DecisionFrame:
    """测试用最小 DecisionFrame（ref 表是唯一输入，元数据取缺省）。"""
    return DecisionFrame(
        match_id="m1", player_id="Player_0", rules_version="r1",
        snapshot_id=1, server_tick=100, mode="fast",
        actors=dict(actors or {
            "W1": {"ref": "W1", "kind": "worker", "count": 2, "pos": [5.0, 5.0],
                   "types": ["worker"], "units": ["Unit_2", "Unit_3"],
                   "buildings": ["barracks"]},
            "S1": {"ref": "S1", "kind": "squad", "count": 3, "pos": [8.0, 8.0],
                   "types": ["tank"], "units": ["Unit_4", "Unit_5", "Unit_6"]},
            "F1": {"ref": "F1", "kind": "facility", "count": 1, "pos": [10.0, 7.0],
                   "types": ["command_center"], "units": ["Unit_0"],
                   "products": ["worker"]},
        }),
        targets=dict(targets or {
            "R1": {"ref": "R1", "kind": "resource", "entity_id": "ResourceA",
                   "pos": [12.0, 12.0]},
            "R2": {"ref": "R2", "kind": "resource", "entity_id": "ResourceB",
                   "pos": [14.0, 12.0]},
            "E1": {"ref": "E1", "kind": "enemy", "entity_id": "Enemy_1",
                   "pos": [20.0, 20.0]},
            "B1": {"ref": "B1", "kind": "anchor", "pos": [10.0, 7.0]},
            "L1": {"ref": "L1", "kind": "location", "cn": "前线集结点",
                   "pos": [16.0, 16.0]},
            "U1": {"ref": "U1", "kind": "product", "scene": "worker",
                   "category": "unit", "cost": 200},
            "V1": {"ref": "V1", "kind": "product", "scene": "barracks",
                   "category": "building", "cost": 600},
        }),
        params=params if params is not None else {
            "P1": {"ref": "P1", "cn": "直线推进·纵队·常速"},
            "P2": {"ref": "P2", "cn": "正面压上·横队·快速"}},
        **kwargs)


class _RecordingLogger:
    """结构化日志替身：记录全部事件（断言"降级有日志"用）。"""

    def __init__(self) -> None:
        self.events: List[Dict[str, Any]] = []

    def log(self, event: str, **fields: Any) -> None:
        self.events.append(dict(event=event, **fields))

    def find(self, event: str) -> List[Dict[str, Any]]:
        return [e for e in self.events if e.get("event") == event]


class _FakeProvider:
    """LayaProvider 替身：脚本化 available/predict 行为（含故障注入）。"""

    def __init__(self, *, available: bool = True, answers: Any = None,
                 raises: Optional[Exception] = None, sleep: float = 0.0,
                 none: bool = False) -> None:
        self._available = available
        self._answers = answers
        self._raises = raises
        self._sleep = sleep
        self._none = none
        self.calls: List[Dict[str, Any]] = []
        self.outcomes: List[str] = []
        self.last_error = ""
        self.last_event = ""

    def available(self) -> bool:
        return self._available

    def note_decision(self, outcome: str) -> None:
        """健康熔断接口（测试替身：只记录，不动作）。"""
        self.outcomes.append(str(outcome))

    def predict(self, state: Any, questions: Dict[str, Any]) -> Any:
        self.calls.append({"state": state, "questions": questions})
        if self._sleep:
            time.sleep(self._sleep)
        if self._raises is not None:
            raise self._raises
        if self._none:
            return None
        return self._answers


def choice(key: str, value: str) -> Dict[str, Any]:
    return {"type": "choice", "choice": value, "confidence": 0.8,
            "probabilities": {value: 0.8}}


class FrameToQuestionsTest(unittest.TestCase):
    """① 结构完备：每个 ref 都出现在某个选项里；每问 ≤20；超限分两级。"""

    def test_every_actor_and_skill_appears_in_menu(self) -> None:
        frame = make_frame()
        state, questions = frame_to_questions(frame)
        actor_menu = questions["actor"]["criteria"]
        for ref in frame.actors:
            self.assertIn(ref, actor_menu, "%s 必须出现在执行者选项里" % ref)
        task_menu = questions["task"]["criteria"]
        for skill in feasible_skills(frame):
            self.assertIn(skill, task_menu)
        # 无目标的设施技能（PROD）要求本帧有 product 目标 —— 这里 U1/V1 都在。
        self.assertIn("PROD", task_menu)
        self.assertIn("GAT", task_menu)
        self.assertTrue(state.strip(), "state 文本不能为空")
        self.assertIn("W1", state)

    def test_every_target_kind_appears(self) -> None:
        frame = make_frame()
        _, questions = frame_to_questions(frame)
        kinds = questions["target_kind"]["criteria"]
        for kind in {str(t.get("kind")) for t in frame.targets.values()}:
            self.assertIn(kind, kinds)

    def test_no_question_exceeds_twenty_options(self) -> None:
        frame = make_frame()
        _, questions = frame_to_questions(frame)
        for qid, qdef in questions.items():
            if qdef.get("type") == "choice":
                self.assertLessEqual(len(qdef["criteria"]), 20,
                                     "%s 超过 20 项（模型卡：明显退化）" % qid)

    def test_actors_over_twenty_split_into_two_levels(self) -> None:
        actors = {}
        for index in range(25):
            ref = "W%d" % index
            actors[ref] = {"ref": ref, "kind": "worker", "count": 1,
                           "pos": [float(index), 1.0], "types": ["worker"],
                           "units": ["Unit_%d" % index], "buildings": ["barracks"]}
        frame = make_frame(actors=actors)
        _, questions = frame_to_questions(frame)
        # 粗级：按类别问（≤20 项）；ref 不出现在粗级选项里。
        self.assertIn("actor_group", questions)
        self.assertNotIn("actor", questions)
        self.assertLessEqual(len(questions["actor_group"]["criteria"]), 20)
        # 细级：类别内的执行者（仍 ≤20，按距离截断）。
        from adjutant_coordinator.graph.task_patch import actor_fine_options
        fine = actor_fine_options(frame, "worker")
        self.assertTrue(fine)
        self.assertLessEqual(len(fine), 20)

    def test_target_fine_options_respect_limit(self) -> None:
        targets = {}
        for index in range(30):
            ref = "R%d" % index
            targets[ref] = {"ref": ref, "kind": "resource",
                            "entity_id": "Resource%d" % index,
                            "pos": [float(index), 2.0]}
        frame = make_frame(targets=targets)
        from adjutant_coordinator.graph.task_patch import target_fine_options
        fine = target_fine_options(frame, "resource")
        self.assertLessEqual(len(fine), 20)

    def test_params_menu_only_offers_frame_presets(self) -> None:
        # 参数菜单必须与帧参数档同源：帧只有 P1 时不能摆 P2~P6（选了会被拒）。
        frame = make_frame(params={"P1": {"ref": "P1", "cn": "直线推进·纵队·常速"}})
        _, questions = frame_to_questions(frame)
        menu = questions["params"]["criteria"]
        self.assertIn("P0", menu)          # 维持现状恒可选
        self.assertIn("P1", menu)
        self.assertNotIn("P2", menu)
        self.assertNotIn("P6", menu)
        # 空参数档 = 全部预设（不猜帧意图）。
        _, all_menu = frame_to_questions(make_frame(params={}))
        self.assertEqual(len(all_menu["params"]["criteria"]), 7)   # P0 + 6 预设

    def test_demos_prepend_to_state(self) -> None:
        # 少样本：样例以"状态 ⇒ 决策"前缀进 state（P0：零样本一致率 0%，必须带）。
        frame = make_frame()
        plain, _ = frame_to_questions(frame)
        demos = [{"state": "执行者: W1(worker·2)", "rows": [["W1", "GAT", "R1", "P0"]]}]
        with_demos, questions = frame_to_questions(frame, demos=demos)
        self.assertIn("参考样例", with_demos)
        self.assertIn("W1→GAT", with_demos)
        self.assertTrue(with_demos.startswith("参考样例"))
        self.assertIn(plain, with_demos)
        # 问题集不受 demos 影响（同一套四问）。
        self.assertEqual(sorted(questions), sorted(frame_to_questions(frame)[1]))


class DemoLibraryTest(unittest.TestCase):
    """少样本库加载（坏行/缺文件不炸；空路径=零样本）。"""

    def setUp(self) -> None:
        self._saved = os.environ.get(lp.ENV_LAYA_DEMOS)
        lp.reset_demos_cache()

    def tearDown(self) -> None:
        if self._saved is None:
            os.environ.pop(lp.ENV_LAYA_DEMOS, None)
        else:
            os.environ[lp.ENV_LAYA_DEMOS] = self._saved
        lp.reset_demos_cache()

    def test_missing_file_returns_empty(self) -> None:
        self.assertEqual(lp.load_demos("Z:\\no\\such\\file.jsonl"), [])

    def test_env_path_used_and_cached(self) -> None:
        import tempfile

        with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False,
                                         encoding="utf-8") as handle:
            handle.write('{"state": "s", "rows": [["W1", "GAT", "R1", "P0"]]}\n')
            handle.write("not json\n")            # 坏行必须跳过
            handle.write('{"state": "s2"}\n')     # 无 rows 必须跳过
            path = handle.name
        try:
            os.environ[lp.ENV_LAYA_DEMOS] = path
            demos = lp.load_demos()
            self.assertEqual(len(demos), 1)
            self.assertEqual(demos[0]["rows"], [["W1", "GAT", "R1", "P0"]])
            # 缓存命中（同路径不重复读文件）。
            self.assertIs(lp.load_demos(), demos)
        finally:
            os.unlink(path)

    def test_empty_env_means_zero_shot(self) -> None:
        os.environ.pop(lp.ENV_LAYA_DEMOS, None)
        self.assertEqual(lp.load_demos(), [])

    def test_shipped_library_loads(self) -> None:
        # 交付的示例库（真实日志生成）必须可加载且带 rows。
        path = os.path.join(HERE, "..", "graph", "laya_demos.jsonl")
        demos = lp.load_demos(os.path.abspath(path))
        self.assertTrue(demos, "交付的 laya_demos.jsonl 应为空或不存在时跳过")
        for demo in demos:
            self.assertTrue(demo.get("state"))
            self.assertTrue(demo.get("rows"))


class AnswersToRowsTest(unittest.TestCase):
    """② 越界 ref / 缺项 / 非法 skill / 粗级未解析 → 丢弃，不崩溃。"""

    def test_valid_answers_expand_to_one_row(self) -> None:
        frame = make_frame()
        answers = {"task": choice("task", "GAT"), "actor": choice("actor", "W1"),
                   "target": choice("target", "R1"),
                   "params": choice("params", "P1")}
        rows = answers_to_rows(answers, frame)
        self.assertEqual(len(rows), 1)
        row = rows[0]
        self.assertEqual(row.actor_ref, "W1")
        self.assertEqual(row.skill, "GAT")
        self.assertEqual(row.target_ref, "R1")
        self.assertEqual(row.action, "gather")

    def test_out_of_table_actor_is_dropped(self) -> None:
        frame = make_frame()
        answers = {"task": choice("task", "GAT"), "actor": choice("actor", "WX"),
                   "target": choice("target", "R1")}
        result = answers_to_decode(answers, frame)
        self.assertEqual(result.modifications, [])
        self.assertEqual([r.reason for r in result.rejections], ["unknown_actor"])

    def test_out_of_table_target_is_dropped(self) -> None:
        frame = make_frame()
        answers = {"task": choice("task", "GAT"), "actor": choice("actor", "W1"),
                   "target": choice("target", "RX")}
        result = answers_to_decode(answers, frame)
        self.assertEqual(result.modifications, [])
        self.assertEqual([r.reason for r in result.rejections], ["unknown_target"])

    def test_illegal_skill_for_actor_is_dropped(self) -> None:
        # F1 是设施，只能 PROD/STOP；选 GAT 必须被拒（能力匹配复用既有校验）。
        frame = make_frame()
        answers = {"task": choice("task", "GAT"), "actor": choice("actor", "F1"),
                   "target": choice("target", "R1")}
        result = answers_to_decode(answers, frame)
        self.assertEqual(result.modifications, [])
        self.assertIn("skill_not_allowed_for_actor",
                      [r.reason for r in result.rejections])

    def test_unknown_skill_is_dropped(self) -> None:
        frame = make_frame()
        answers = {"task": choice("task", "FLY"), "actor": choice("actor", "W1"),
                   "target": choice("target", "R1")}
        result = answers_to_decode(answers, frame)
        self.assertEqual(result.modifications, [])
        self.assertEqual([r.reason for r in result.rejections], ["unknown_skill"])

    def test_missing_target_for_targeted_skill_is_dropped(self) -> None:
        frame = make_frame()
        answers = {"task": choice("task", "GAT"), "actor": choice("actor", "W1")}
        result = answers_to_decode(answers, frame)
        self.assertEqual(result.modifications, [])
        self.assertIn("unknown_target", [r.reason for r in result.rejections])

    def test_target_kind_mismatch_is_dropped(self) -> None:
        # GAT 只能对 resource；给 enemy 必须被拒。
        frame = make_frame()
        answers = {"task": choice("task", "GAT"), "actor": choice("actor", "W1"),
                   "target": choice("target", "E1")}
        result = answers_to_decode(answers, frame)
        self.assertEqual(result.modifications, [])
        self.assertEqual([r.reason for r in result.rejections],
                         ["target_kind_mismatch"])

    def test_coarse_group_answer_is_dropped_not_crashed(self) -> None:
        # 只给了粗级（类别）没给细级 ref：不在权威 ref 表 → 拒绝，不崩。
        frame = make_frame()
        answers = {"task": choice("task", "GAT"),
                   "actor_group": choice("actor_group", "worker"),
                   "target": choice("target", "R1")}
        result = answers_to_decode(answers, frame)
        self.assertEqual(result.modifications, [])
        self.assertEqual([r.reason for r in result.rejections], ["unknown_actor"])

    def test_empty_answers_mean_no_change(self) -> None:
        frame = make_frame()
        result = answers_to_decode({}, frame)
        self.assertEqual(result.modifications, [])
        self.assertEqual(result.rejections, [])
        self.assertEqual(answers_to_rows(None, frame), [])

    def test_hold_needs_no_target(self) -> None:
        frame = make_frame()
        answers = {"task": choice("task", SKILL_HOLD), "actor": choice("actor", "S1")}
        result = answers_to_decode(answers, frame)
        self.assertEqual(len(result.modifications), 1)
        self.assertEqual(result.modifications[0].target_ref, "-")

    def test_no_target_skill_with_target_is_dropped(self) -> None:
        frame = make_frame()
        answers = {"task": choice("task", SKILL_HOLD), "actor": choice("actor", "S1"),
                   "target": choice("target", "R1")}
        result = answers_to_decode(answers, frame)
        self.assertEqual(result.modifications, [])
        self.assertEqual([r.reason for r in result.rejections],
                         ["target_not_applicable"])


class S1SwitchTest(unittest.TestCase):
    """③ 开关：默认 model 不碰 Laya；off 两层都关；laya 走判别式路径。"""

    def setUp(self) -> None:
        self._saved_backend = os.environ.get(lp.ENV_S1_BACKEND)
        os.environ.pop(lp.ENV_S1_BACKEND, None)
        lp.reset_provider()
        self._saved_get_provider = pa.get_provider
        self._saved_propose_model = pa.PydanticAITaskPatchAgent._propose_via_model

    def tearDown(self) -> None:
        pa.get_provider = self._saved_get_provider
        pa.PydanticAITaskPatchAgent._propose_via_model = self._saved_propose_model
        if self._saved_backend is None:
            os.environ.pop(lp.ENV_S1_BACKEND, None)
        else:
            os.environ[lp.ENV_S1_BACKEND] = self._saved_backend
        lp.reset_provider()

    def _agent(self) -> Any:
        """不建真实 Provider 的 agent（patch 掉 pydantic_ai.Agent 的装配）。"""
        import pydantic_ai

        class _FakeAgent:
            def __init__(self, *args: Any, **kwargs: Any) -> None:
                pass

        original = pydantic_ai.Agent
        pydantic_ai.Agent = _FakeAgent  # type: ignore[assignment]
        try:
            settings = pa.GraphModelSettings(base_url="http://127.0.0.1:1/v1",
                                             api_key_env="X", tactics_model="m")
            return pa.PydanticAITaskPatchAgent(settings, model=object())
        finally:
            pydantic_ai.Agent = original  # type: ignore[assignment]

    def test_default_backend_is_model(self) -> None:
        self.assertEqual(lp.s1_backend(), lp.BACKEND_MODEL)

    def test_model_backend_never_touches_laya(self) -> None:
        os.environ[lp.ENV_S1_BACKEND] = "model"
        agent = self._agent()
        called = {"provider": False, "model": False}

        def spy_provider(logger: Any = None) -> Any:
            called["provider"] = True
            raise AssertionError("model 后端不应构造 Laya provider")

        def spy_model(frame: Any) -> Any:
            called["model"] = True
            return "model-path"

        pa.get_provider = spy_provider  # type: ignore[assignment]
        agent._propose_via_model = spy_model  # type: ignore[assignment]
        result = agent.propose_task_patch(make_frame())
        self.assertEqual(result, "model-path")
        self.assertFalse(called["provider"], "默认后端不得触碰 Laya")
        self.assertTrue(called["model"])

    def test_off_backend_returns_none(self) -> None:
        os.environ[lp.ENV_S1_BACKEND] = "off"
        agent = self._agent()
        called = {"model": False}
        agent._propose_via_model = lambda frame: called.__setitem__(  # type: ignore[assignment]
            "model", True) or "model-path"
        self.assertIsNone(agent.propose_task_patch(make_frame()))
        self.assertFalse(called["model"], "off = 两层都关，不得调用模型")

    def test_invalid_backend_falls_back_to_model(self) -> None:
        os.environ[lp.ENV_S1_BACKEND] = "nonsense"
        agent = self._agent()
        agent._propose_via_model = lambda frame: "model-path"  # type: ignore[assignment]
        self.assertEqual(agent.propose_task_patch(make_frame()), "model-path")


class LayaDegradeTest(unittest.TestCase):
    """④ 降级：Laya 异常/无答案/超时/全拒 → 回退既有链路且日志有记录。"""

    def setUp(self) -> None:
        self._saved_backend = os.environ.get(lp.ENV_S1_BACKEND)
        os.environ[lp.ENV_S1_BACKEND] = "laya"
        lp.reset_provider()
        self._saved_get_provider = pa.get_provider
        self._saved_propose_model = pa.PydanticAITaskPatchAgent._propose_via_model
        self.logger = _RecordingLogger()

    def tearDown(self) -> None:
        pa.get_provider = self._saved_get_provider
        pa.PydanticAITaskPatchAgent._propose_via_model = self._saved_propose_model
        if self._saved_backend is None:
            os.environ.pop(lp.ENV_S1_BACKEND, None)
        else:
            os.environ[lp.ENV_S1_BACKEND] = self._saved_backend
        lp.reset_provider()

    def _agent(self) -> Any:
        agent = S1SwitchTest._agent(self)
        agent.logger = self.logger
        return agent

    def _fallback_spy(self, agent: Any) -> Dict[str, Any]:
        state = {"called": False}

        def spy(frame: Any) -> Any:
            state["called"] = True
            return "model-path"

        agent._propose_via_model = spy  # type: ignore[assignment]
        return state

    def test_unavailable_provider_degrades_with_log(self) -> None:
        agent = self._agent()
        provider = _FakeProvider(available=False)
        pa.get_provider = lambda logger=None: provider  # type: ignore[assignment]
        spy = self._fallback_spy(agent)
        result = agent.propose_task_patch(make_frame())
        self.assertEqual(result, "model-path")
        self.assertTrue(spy["called"])
        self.assertTrue(agent.logger.find("laya_fallback"),
                        "Laya 不可用必须留 fallback 日志")

    def test_predict_exception_degrades(self) -> None:
        # provider 自吞异常返回 None → 视为这一拍 Laya 没成功 → 回退。
        agent = self._agent()
        provider = _FakeProvider(raises=RuntimeError("gpu on fire"))
        pa.get_provider = lambda logger=None: provider  # type: ignore[assignment]
        spy = self._fallback_spy(agent)
        result = agent.propose_task_patch(make_frame())
        self.assertEqual(result, "model-path")
        self.assertTrue(spy["called"])
        self.assertTrue(agent.logger.find("laya_fallback"))

    def test_predict_none_degrades(self) -> None:
        agent = self._agent()
        provider = _FakeProvider(none=True)
        pa.get_provider = lambda logger=None: provider  # type: ignore[assignment]
        spy = self._fallback_spy(agent)
        self.assertEqual(agent.propose_task_patch(make_frame()), "model-path")
        self.assertTrue(spy["called"])

    def test_timeout_degrades(self) -> None:
        agent = self._agent()
        provider = _FakeProvider(sleep=1.5)
        pa.get_provider = lambda logger=None: provider  # type: ignore[assignment]
        os.environ[lp.ENV_LAYA_TIMEOUT] = "0.2"
        try:
            spy = self._fallback_spy(agent)
            result = agent.propose_task_patch(make_frame())
            self.assertEqual(result, "model-path")
            self.assertTrue(spy["called"])
            events = agent.logger.find("laya_fallback")
            self.assertTrue(events)
            self.assertIn("超时", str(events[0].get("reason", "")))
        finally:
            os.environ.pop(lp.ENV_LAYA_TIMEOUT, None)

    def test_all_rejected_degrades_unless_hold(self) -> None:
        agent = self._agent()
        # Laya 选了合法菜单外的组合（粗级未解析）→ 全拒 → 回退模型链路。
        provider = _FakeProvider(answers={
            "task": choice("task", "GAT"),
            "actor_group": choice("actor_group", "worker"),
            "target": choice("target", "R1")})
        pa.get_provider = lambda logger=None: provider  # type: ignore[assignment]
        spy = self._fallback_spy(agent)
        self.assertEqual(agent.propose_task_patch(make_frame()), "model-path")
        self.assertTrue(spy["called"])
        self.assertTrue(agent.logger.find("laya_all_rejected"))

    def test_hold_answer_is_legitimate_not_a_failure(self) -> None:
        agent = self._agent()
        provider = _FakeProvider(answers={
            "task": choice("task", SKILL_HOLD), "actor": choice("actor", "S1")})
        pa.get_provider = lambda logger=None: provider  # type: ignore[assignment]
        spy = self._fallback_spy(agent)
        result = agent.propose_task_patch(make_frame())
        # HOLD = 合法选择（与 2B 输出 ["S1","HOLD","-","P0"] 同罪同罚）：不回退。
        self.assertFalse(spy["called"], "HOLD 是合法选择，不得回退模型链路")
        self.assertIsNotNone(result)
        intents = list(getattr(result, "intents", []) or [])
        self.assertEqual(len(intents), 1)
        self.assertEqual(intents[0].action, "hold")
        self.assertEqual(agent.last_laya.get("task"), SKILL_HOLD)

    def test_hold_with_rejected_row_is_empty_batch_not_fallback(self) -> None:
        # Laya 说 HOLD 但执行者 ref 越界：这一拍是"没有可执行的维持"，不是失败 → 不回退。
        agent = self._agent()
        provider = _FakeProvider(answers={
            "task": choice("task", SKILL_HOLD), "actor": choice("actor", "SX")})
        pa.get_provider = lambda logger=None: provider  # type: ignore[assignment]
        spy = self._fallback_spy(agent)
        result = agent.propose_task_patch(make_frame())
        self.assertFalse(spy["called"])
        self.assertIsNotNone(result)
        self.assertEqual(list(getattr(result, "intents", []) or []), [])

    def test_target_renarrow_after_actor_fixed(self) -> None:
        """真机回归（2026-09-20）：PROD 选到该设施产不了的单位 → 目标再缩窄一次。

        症状：60/74 个决策因 capability_mismatch 回退（Laya 给 PROD 选建筑类/
        别设施的产品）。修法：product 细选按技能语义过滤类别 + 执行者定了之后
        把目标缩窄到该执行者真能产/造的项目。
        """
        targets = dict(make_frame().targets)
        targets["U2"] = {"ref": "U2", "kind": "product", "scene": "tank",
                         "category": "unit", "cost": 500}
        frame = make_frame(targets=targets)   # F1(products=[worker]) U1=worker U2=tank
        agent = self._agent()
        tc = self   # provider 不是 TestCase：断言必须经由它（写 self. 会 AttributeError，
        # 且该异常会被 _call_laya 归一化吞掉、伪装成"回退"——2026-09-20 实测踩过）

        class _ScriptedProvider(_FakeProvider):
            def predict(self, state: Any, questions: Dict[str, Any]) -> Any:
                call = len(self.calls)
                self.calls.append({"state": state, "questions": questions})
                if call == 0:
                    return {"task": choice("task", "PROD"),
                            "actor": choice("actor", "F1"),
                            "target_kind": choice("target_kind", "product")}
                if call == 1:
                    # 第一趟目标细选选了别设施的产品（tank）→ capability_mismatch。
                    tc.assertEqual(sorted(questions["target"]["criteria"]),
                                   ["U1", "U2"])   # 类别已过滤为 unit
                    return {"target": choice("target", "U2")}
                if call == 2:
                    return {"actor": choice("actor", "F1")}      # 相容执行者（设施）
                # 目标缩窄到 F1 真能生产的项目。
                tc.assertEqual(sorted(questions["target"]["criteria"]), ["U1"])
                return {"target": choice("target", "U1")}

        provider = _ScriptedProvider()
        pa.get_provider = lambda logger=None: provider  # type: ignore[assignment]
        spy = self._fallback_spy(agent)
        result = agent.propose_task_patch(frame)
        self.assertFalse(spy["called"], "目标缩窄后应被接受，不得回退")
        intents = list(getattr(result, "intents", []) or [])
        self.assertEqual(len(intents), 1)
        self.assertEqual(intents[0].action, "produce")
        self.assertEqual(intents[0].target.get("scene"), "worker")

    def test_product_target_menu_filters_category(self) -> None:
        # PROD 的细选菜单只含 unit 类；BLD 只含 building 类（与校验同源）。
        frame = make_frame()
        from adjutant_coordinator.graph.task_patch import target_fine_options
        units = target_fine_options(frame, "product", category="unit")
        buildings = target_fine_options(frame, "product", category="building")
        self.assertEqual(sorted(units), ["U1"])       # worker
        self.assertEqual(sorted(buildings), ["V1"])   # barracks

    def test_narrow_reask_survives_twenty_actor_cap(self) -> None:
        """真机回归（2026-09-20）：>20 执行者时相容执行者不被就近截断吃掉。

        症状：46% 的决策因 (PROD, 小队) 不相客被拒后回退 2B——相容集合先用就近
        20 项截断，基地里的设施离质心远被截掉 → 缩窄重问变空操作。
        """
        actors: Dict[str, Dict[str, Any]] = {}
        # 22 个小队挤在前线（离质心近）+ 3 个设施在基地（离质心远）。
        for index in range(22):
            ref = "S%d" % (index + 1)
            actors[ref] = {"ref": ref, "kind": "squad", "count": 3,
                           "pos": [30.0 + index, 30.0], "types": ["tank"],
                           "units": ["Unit_s%d" % index]}
        for index in range(3):
            ref = "F%d" % (index + 1)
            actors[ref] = {"ref": ref, "kind": "facility", "count": 1,
                           "pos": [2.0, 2.0], "types": "barracks",
                           "units": ["Unit_f%d" % index], "products": ["soldier"]}
        targets = {"U1": {"ref": "U1", "kind": "product", "scene": "soldier",
                          "category": "unit", "cost": 150}}
        frame = make_frame(actors=actors, targets=targets,
                           params={"P1": {"ref": "P1", "cn": "x"}})
        agent = self._agent()

        class _ScriptedProvider(_FakeProvider):
            """按调用序回脚本：主问(PROD+小队组) → 目标细选 → 小队细选 → 缩窄重问。"""

            def __init__(self) -> None:
                super().__init__()
                self.questions_seen: List[List[str]] = []

            def predict(self, state: Any, questions: Dict[str, Any]) -> Any:
                self.questions_seen.append(sorted(questions.keys()))
                call = len(self.calls)
                self.calls.append({"state": state, "questions": questions})
                if call == 0:
                    return {"task": choice("task", "PROD"),
                            "actor_group": choice("actor_group", "squad"),
                            "target_kind": choice("target_kind", "product")}
                if call == 1:
                    return {"target": choice("target", "U1")}
                if call == 2:
                    return {"actor": choice("actor", "S1")}     # 小队：不相客
                return {"actor": choice("actor", "F1")}         # 缩窄后只能选设施

        provider = _ScriptedProvider()
        pa.get_provider = lambda logger=None: provider  # type: ignore[assignment]
        spy = self._fallback_spy(agent)
        result = agent.propose_task_patch(frame)
        # 缩窄重问必须看得到设施（不被 20 项就近截断吃掉），最终行被接受、不回退。
        self.assertFalse(spy["called"], "相容执行者应被找到，不得回退模型链路")
        intents = list(getattr(result, "intents", []) or [])
        self.assertEqual(len(intents), 1)
        self.assertEqual(intents[0].action, "produce")
        narrow_questions = [q for q in provider.questions_seen if "actor" in q]
        self.assertTrue(narrow_questions, "应发生过执行者细选/缩窄追问")

    def test_provider_logger_receives_events(self) -> None:
        # provider 自己也要把"加载失败"写进结构化日志（event=laya_*）。
        # 用注入的加载故障（不依赖本机是否装了 laya）。
        provider = lp.LayaProvider(logger=self.logger)

        def boom() -> Any:
            raise RuntimeError("scripted load failure")

        provider._import_agent = boom  # type: ignore[assignment]
        self.assertFalse(provider.available())
        self.assertTrue(self.logger.find("laya_unavailable"))
        # 失败后不反复重试（不在每拍重载拖死链路），也不再重复打点。
        self.assertFalse(provider.available())
        self.assertEqual(len(self.logger.find("laya_unavailable")), 1)

    def test_real_provider_without_laya_installed(self) -> None:
        # 未装 laya 的环境：available()=False、predict()=None，绝不抛异常。
        # 已装 laya 时跳过（真实加载路径由 P0 实验与端到端覆盖，单测不重复 30s 加载）。
        import importlib.util

        if importlib.util.find_spec("laya") is not None:
            self.skipTest("本环境已安装 laya（跳过未安装路径）")
        provider = lp.get_provider(logger=self.logger)
        self.assertFalse(provider.available())
        self.assertIsNone(provider.predict("state", {
            "task": {"type": "choice", "instructions": "x",
                     "criteria": {"GAT": "采集"}}}))


class StrategyLayerTest(unittest.TestCase):
    """System 2 战略层（2026-09-21 起默认开启）的守门测试。

    真机依据（P5 全栈对照）：战略层是**同步**调用，默认开启后暴露出两个问题——
    ① 带 2 次重试时一次校验失败烧 3 个完整调用（15s 超时 ×3）堵死主循环；
    ② 失败后 60 tick（1s）冷却≈不冷却，5 分钟 5 次 15s 超时堵了 75s。
    对应修复：重试 0 + 满间隔退避（配置门控，runner 显式开启）。
    """

    def test_strategy_agent_uses_zero_retries(self) -> None:
        import pydantic_ai

        captured: Dict[str, Any] = {}

        class _CapturingAgent:
            def __init__(self, *args: Any, **kwargs: Any) -> None:
                captured.update(kwargs)

        original = pydantic_ai.Agent
        pydantic_ai.Agent = _CapturingAgent  # type: ignore[assignment]
        try:
            settings = pa.GraphModelSettings(base_url="http://127.0.0.1:1/v1",
                                             api_key_env="X", tactics_model="m")
            pa.PydanticAIStrategyAgent(settings, model=object())
            self.assertEqual(captured.get("retries"), 0,
                             "战略层（同步）必须 0 重试：失败要便宜地降级")
            self.assertEqual(pa.PydanticAIStrategyAgent.agent_retries, 0)
            # 战术四列是纯文本输出：重试本来就是 0（既有行为未被改动）。
            captured.clear()
            pa.PydanticAITaskPatchAgent(settings, model=object())
            self.assertEqual(captured.get("retries"), 0)
        finally:
            pydantic_ai.Agent = original  # type: ignore[assignment]

    def test_strategy_failure_backs_off_full_interval(self) -> None:
        """失败后退避满一个间隔（默认关闭；runner 显式开启——不破坏历史节流测试）。"""
        from adjutant_coordinator.graph.checkpoint import MemoryCheckpointStore
        from adjutant_coordinator.graph.pydantic_agents import FakeStructuredModel
        from adjutant_coordinator.graph.runtime import AdjutantGraphRuntime, RuntimeConfig

        sys.path.insert(0, HERE)   # graph_test_helpers
        from graph_test_helpers import (  # noqa: E402
            MATCH, PLAYER, RecordingTransport, header, rules_view, strategic, tactical,
        )

        def obs(tick: int) -> Dict[str, Any]:
            return {"header": header(tick, match_id=MATCH,
                                     rules_version="hash-graph-1"),
                    "strategic": strategic(tick),
                    "tactical": tactical(server_tick=tick),
                    "rules": rules_view(), "events": [], "budget": {}}

        config = RuntimeConfig(
            engine="fallback", strategy_interval_ticks=100, tactics_interval_ticks=1,
            emergency_min_interval_ticks=1, intent_ttl_ticks=600,
            emergency_intent_ttl_ticks=300, pending_timeout_ticks=1000,
            pause_on_player_interrupt=True, strategy_backoff_ticks=100)
        strategy = FakeStructuredModel("strategy", [{"behavior": "timeout"}] * 5)
        runtime = AdjutantGraphRuntime(
            MATCH, PLAYER, transport=RecordingTransport(),
            strategy_model=strategy,
            tactics_model=FakeStructuredModel("tactics", []),
            checkpoint_store=MemoryCheckpointStore(), config=config)
        runtime.restore()

        runtime.tick(0, obs(0))
        self.assertEqual(strategy.call_count, 1)
        runtime.tick(1, obs(1))
        # 退避期内：不再调模型，且留下可观测的 skip 原因。
        self.assertEqual(strategy.call_count, 1)
        kinds = [(item["kind"], item.get("reason"))
                 for item in runtime.state.decision_log]
        self.assertIn(("strategy_skipped", "strategy_backoff"), kinds)
        # 退避结束（tick 100 = 0 + 100）：恢复调用，不会永久降级。
        runtime.tick(100, obs(100))
        self.assertEqual(strategy.call_count, 2)

    def test_backoff_default_off_keeps_history_cadence(self) -> None:
        """不配 strategy_backoff_ticks 时行为与历史一致（既有冷却测试的口径）。"""
        from adjutant_coordinator.graph.nodes import GraphConfig

        self.assertEqual(GraphConfig().strategy_backoff_ticks, 0)


class EngageAttackMoveTest(unittest.TestCase):
    """默认交火从"点兵"改为"移动并攻击"（用户 2026-09-21 要求）。

    开关经环境变量 AIRTS_ENGAGE_ATTACK_MOVE（代码默认关 = 历史口径，既有测试集
    不受影响；`.env.local` 置 1 打开）。军事轨的三个发射点（阶梯骨架出击 /
    并行填充 / 行为树交火）共用同一开关。
    """

    def setUp(self) -> None:
        self._saved = os.environ.get("AIRTS_ENGAGE_ATTACK_MOVE")
        os.environ.pop("AIRTS_ENGAGE_ATTACK_MOVE", None)

    def tearDown(self) -> None:
        if self._saved is None:
            os.environ.pop("AIRTS_ENGAGE_ATTACK_MOVE", None)
        else:
            os.environ["AIRTS_ENGAGE_ATTACK_MOVE"] = self._saved

    def _state(self):
        return {
            "server_tick": 1000, "latest_snapshot_id": 3,
            "ai_controlled_units": ["U_s1", "U_s2"],
            "player_controlled_units": [],
        }

    def _tactical(self):
        def entity(kind, name, unit_type, pos):
            return {"kind": kind, "name": name, "unit_type": unit_type,
                    "pos": list(pos)}
        return {"entities": [
            entity("unit_self", "U_s1", "soldier", (10, 0, 10)),
            entity("unit_self", "U_s2", "soldier", (11, 0, 10)),
            entity("unit_self", "U_cc", "command_center", (0, 0, 0)),
            entity("unit_enemy", "near_enemy", "soldier", (12, 0, 10)),
        ]}

    def test_default_keeps_point_attack(self) -> None:
        """不带开关：历史口径（点攻击）——既有测试集的口径不变。"""
        from adjutant_coordinator.graph import behavior_tree

        intents = behavior_tree.micro_intents(self._state(), tactical=self._tactical())
        attacks = [i for i in intents if i["action"] == "attack"]
        self.assertTrue(attacks, "默认口径应交火：%s" % intents)
        self.assertEqual(attacks[0]["target"]["entity_id"], "near_enemy")
        self.assertFalse([i for i in intents if i["action"] == "attack_move"],
                         "默认口径不应发移动并攻击")

    def test_flag_on_emits_attack_move_to_enemy_position(self) -> None:
        """打开开关：交火改为 attack_move 走向敌人位置（不是点兵）。"""
        from adjutant_coordinator.graph import behavior_tree

        os.environ["AIRTS_ENGAGE_ATTACK_MOVE"] = "1"
        intents = behavior_tree.micro_intents(self._state(), tactical=self._tactical())
        moves = [i for i in intents if i["action"] == "attack_move"]
        self.assertTrue(moves, "开关打开后交火应改为移动并攻击：%s" % intents)
        pos = moves[0]["target"].get("pos") or []
        self.assertEqual([round(float(pos[0]), 1), round(float(pos[1]), 1)],
                         [12.0, 10.0], "移动并攻击的目标点应是敌人位置")
        self.assertFalse([i for i in intents if i["action"] == "attack"],
                         "开关打开后默认交火不应再发点攻击")

    def test_flag_off_via_env_keeps_point_attack(self) -> None:
        """显式关：即使别的调用方开过，环境变量能把它按回点攻击。"""
        from adjutant_coordinator.graph import behavior_tree

        os.environ["AIRTS_ENGAGE_ATTACK_MOVE"] = "0"
        intents = behavior_tree.micro_intents(self._state(), tactical=self._tactical())
        self.assertTrue([i for i in intents if i["action"] == "attack"])
        self.assertFalse([i for i in intents if i["action"] == "attack_move"])


class LayaCircuitBreakerTest(unittest.TestCase):
    """Laya 健康熔断（用户 2026-09-21：laya 不 healthy 就用 2B 兜底）。

    单次超时已有 per-call 回退；熔断器解决的是"持续不健康时每拍白等 2s"：
    窗口失败率超限 → 断开（直接走 2B）→ 冷却后半开试探 → 成功即恢复。
    """

    def setUp(self) -> None:
        self._saved_backend = os.environ.get(lp.ENV_S1_BACKEND)
        os.environ[lp.ENV_S1_BACKEND] = "laya"
        for name in (lp.ENV_LAYA_CIRCUIT, lp.ENV_LAYA_CIRCUIT_WINDOW,
                     lp.ENV_LAYA_CIRCUIT_MAX_FAIL_RATE,
                     lp.ENV_LAYA_CIRCUIT_COOLDOWN_S):
            os.environ.pop(name, None)
        lp.reset_provider()

    def tearDown(self) -> None:
        if self._saved_backend is None:
            os.environ.pop(lp.ENV_S1_BACKEND, None)
        else:
            os.environ[lp.ENV_S1_BACKEND] = self._saved_backend
        for name in (lp.ENV_LAYA_CIRCUIT, lp.ENV_LAYA_CIRCUIT_WINDOW,
                     lp.ENV_LAYA_CIRCUIT_MAX_FAIL_RATE,
                     lp.ENV_LAYA_CIRCUIT_COOLDOWN_S):
            os.environ.pop(name, None)
        lp.reset_provider()

    def _provider(self, behavior: str = "ok", sleep: float = 0.0):
        class _FakeAgent:
            def __init__(self) -> None:
                self.calls = 0

            def predict(self, state: Any, questions: Dict[str, Any]) -> Any:
                self.calls += 1
                if behavior == "raise":
                    raise RuntimeError("scripted gpu failure")
                if behavior == "sleep":
                    time.sleep(sleep)
                return {"answers": {"task": {"type": "choice", "choice": "GAT",
                                             "confidence": 0.9}}}

        provider = lp.LayaProvider()
        provider._import_agent = _FakeAgent  # type: ignore[assignment]
        provider._agent = _FakeAgent()
        return provider

    _QUESTIONS = {"task": {"type": "choice", "instructions": "x",
                           "criteria": {"GAT": "采集"}}}

    def test_opens_after_sustained_failures_and_skips_calls(self) -> None:
        provider = self._provider()
        for _ in range(6):
            provider.note_decision("timeout")
        state = provider.circuit_state()
        self.assertEqual(state["state"], "open")
        self.assertEqual(state["failures"], 6)
        # 断开期内 predict 直接 None，且不再调用底层 agent。
        before = provider._agent.calls
        self.assertIsNone(provider.predict("state", self._QUESTIONS))
        self.assertEqual(provider._agent.calls, before)
        self.assertIn("熔断", provider.last_error)

    def test_min_samples_guard_avoids_early_open(self) -> None:
        provider = self._provider()
        for _ in range(4):                      # < DEFAULT_CIRCUIT_MIN_SAMPLES(5)
            provider.note_decision("timeout")
        self.assertEqual(provider.circuit_state()["state"], "closed")

    def test_half_open_probe_recovers(self) -> None:
        provider = self._provider()
        os.environ[lp.ENV_LAYA_CIRCUIT_COOLDOWN_S] = "0.1"
        for _ in range(6):
            provider.note_decision("timeout")
        self.assertEqual(provider.circuit_state()["state"], "open")
        time.sleep(0.15)                        # 冷却到期 → 半开
        self.assertTrue(provider._circuit_allows_call())
        provider.note_decision("ok")            # 试探成功 → 恢复
        state = provider.circuit_state()
        self.assertEqual(state["state"], "closed")
        self.assertEqual(state["consecutive_opens"], 0)
        # 恢复后可以正常预测
        self.assertIsNotNone(provider.predict("state", self._QUESTIONS))

    def test_repeated_opens_escalate_cooldown(self) -> None:
        provider = self._provider()
        os.environ[lp.ENV_LAYA_CIRCUIT_COOLDOWN_S] = "0.1"
        for _ in range(6):
            provider.note_decision("timeout")
        first = provider.circuit_state()["cooldown_s"]
        time.sleep(0.15)
        self.assertTrue(provider._circuit_allows_call())   # 冷却到期 → 半开试探
        provider.note_decision("timeout")       # 试探又失败 → 再断（冷却升级）
        second = provider.circuit_state()["cooldown_s"]
        self.assertGreater(second, first, "连续断开冷却应升级")

    def test_disabled_by_env_never_opens(self) -> None:
        os.environ[lp.ENV_LAYA_CIRCUIT] = "0"
        provider = self._provider()
        for _ in range(30):
            provider.note_decision("timeout")
        self.assertEqual(provider.circuit_state()["state"], "closed")
        self.assertIsNotNone(provider.predict("state", self._QUESTIONS))

    def test_agent_falls_back_and_circuit_eventually_opens(self) -> None:
        """接入级：持续超时 → 每拍回退 2B，且熔断打开后不再调 Laya。"""
        import pydantic_ai

        class _CapturingAgent:
            def __init__(self, *args: Any, **kwargs: Any) -> None:
                pass

        original = pydantic_ai.Agent
        pydantic_ai.Agent = _CapturingAgent  # type: ignore[assignment]
        os.environ[lp.ENV_LAYA_TIMEOUT] = "0.2"
        try:
            provider = self._provider(behavior="sleep", sleep=0.6)
            settings = pa.GraphModelSettings(base_url="http://127.0.0.1:1/v1",
                                             api_key_env="X", tactics_model="m")
            agent = pa.PydanticAITaskPatchAgent(settings, model=object(),
                                                mode="fast")
            agent.logger = _RecordingLogger()

            def _get_provider(logger: Any = None) -> Any:
                # 镜像真实 get_provider：首次带 logger 时挂到 provider 上。
                if logger is not None and provider.logger is None:
                    provider.logger = logger
                return provider

            pa.get_provider = _get_provider  # type: ignore[assignment]
            fallbacks = {"count": 0}

            def spy_model(frame: Any) -> Any:
                fallbacks["count"] += 1
                return "model-path"

            agent._propose_via_model = spy_model  # type: ignore[assignment]
            frame = make_frame()
            for _ in range(6):
                agent.propose_task_patch(frame)
            # 每拍都回退了 2B（Laya 不可用时的正确行为）。
            self.assertEqual(fallbacks["count"], 6)
            self.assertEqual(provider.circuit_state()["state"], "open")
            calls_after_open = provider._agent.calls
            agent.propose_task_patch(frame)
            # 熔断后跳过 Laya：底层 agent 调用次数不再增长。
            self.assertEqual(provider._agent.calls, calls_after_open)
            self.assertEqual(fallbacks["count"], 7)
            events = [e["event"] for e in agent.logger.events]
            self.assertIn("laya_circuit_open", events)
        finally:
            pydantic_ai.Agent = original  # type: ignore[assignment]
            os.environ.pop(lp.ENV_LAYA_TIMEOUT, None)
            pa.get_provider = lp.get_provider  # type: ignore[assignment]


class DecisionMapBranchTest(unittest.TestCase):
    """决策地图接入 Laya（2026-09-21）：分支问题 + goal_ref 落地 + 标签。

    链：`frame.campaign["available_routes"]`（decision_map.retrieve 的唯一出口）
    → branch 问题 → Laya 选择 → `DecodeResult.goal_ref` → 既有
    `note_model_branch`（前置条件校验）→ campaign 主线。
    """

    def _frame_with_routes(self, routes, names=None):
        frame = make_frame()
        campaign = dict(getattr(frame, "campaign", None) or {})
        campaign["available_routes"] = list(routes)
        campaign["available_route_names"] = dict(names or {})
        campaign["model_branch"] = "D1"
        object.__setattr__(frame, "campaign", campaign)
        return frame

    def test_branch_question_lists_available_routes_plus_keep(self) -> None:
        frame = self._frame_with_routes(["D1", "D3", "D9"],
                                        {"D1": "开工摸底", "D3": "推进发展阶梯",
                                         "D9": "补兵"})
        _, questions = frame_to_questions(frame)
        branch = questions["branch"]
        self.assertEqual(branch["type"], "choice")
        self.assertEqual(sorted(branch["criteria"]),
                         ["D1", "D3", "D9", "KEEP"])
        self.assertEqual(branch["criteria"]["D3"], "推进发展阶梯")
        self.assertEqual(branch["criteria"]["KEEP"], "维持当前主线")

    def test_no_routes_still_offers_keep(self) -> None:
        frame = self._frame_with_routes([])
        _, questions = frame_to_questions(frame)
        self.assertEqual(list(questions["branch"]["criteria"]), ["KEEP"])

    def test_branch_answer_becomes_goal_ref(self) -> None:
        from adjutant_coordinator.graph.task_patch import (
            BRANCH_KEEP, answers_to_decode,
        )

        frame = self._frame_with_routes(["D1", "D3"])
        answers = {"task": choice("task", "GAT"), "actor": choice("actor", "W1"),
                   "target": choice("target", "R1"),
                   "branch": choice("branch", "D3")}
        result = answers_to_decode(answers, frame)
        self.assertEqual(result.goal_ref, "D3")
        self.assertEqual(result.branch_source, "laya")

    def test_keep_branch_leaves_goal_ref_empty(self) -> None:
        from adjutant_coordinator.graph.task_patch import (
            BRANCH_KEEP, answers_to_decode,
        )

        frame = self._frame_with_routes(["D1", "D3"])
        answers = {"task": choice("task", "GAT"), "actor": choice("actor", "W1"),
                   "target": choice("target", "R1"),
                   "branch": choice("branch", BRANCH_KEEP)}
        result = answers_to_decode(answers, frame)
        self.assertEqual(result.goal_ref, "")
        self.assertEqual(result.branch_source, "")

    def test_summarize_keeps_goal_ref_for_async_path(self) -> None:
        from adjutant_coordinator.graph.task_patch import (
            DecodeResult, RowRejection,
        )
        from adjutant_coordinator.graph.task_patch_bridge import summarize_decode

        result = DecodeResult(goal_ref="D9", branch_source="laya")
        summary = summarize_decode(result)
        self.assertEqual(summary["goal_ref"], "D9")
        self.assertEqual(summary["branch_source"], "laya")


class MainlineLabelTest(unittest.TestCase):
    """分支教师标签（`_mainline_node_id`）必须指向**未完成**的主线节点。

    v10 实测（2026-09-21）：标签 101/186 条指向已完成里程碑的节点（D12←M06
    已完成），laya 采纳后全被 `note_model_branch` 以 `branch_done` 驳回——
    教模型做一个必然无效的选择。根因：① 前沿 key 读成 `frontier`（派生视图
    专用），战役状态里叫 `next_frontier`；② 回退分支取"最近已完成"里程碑。
    """

    def _campaign(self, *, frontier, statuses):
        campaign = cm.ensure_campaign({}, 0)
        campaign["next_frontier"] = frontier
        for milestone, status in statuses.items():
            entry = campaign["milestones"].get(milestone)
            if entry is not None:
                entry["status"] = status
        return campaign

    def test_label_follows_live_frontier(self) -> None:
        # 前沿 M04（绑定 D6）时标签必须是 D6——不是已完成 M03 的 D9。
        campaign = self._campaign(
            frontier="M04",
            statuses={"M01": "done", "M02": "done", "M03": "done", "M04": "pending"})
        self.assertEqual(cm._mainline_node_id(campaign), "D6")

    def test_label_skips_done_milestone_when_frontier_has_no_node(self) -> None:
        # 前沿 M05（不绑定节点）→ 回退到**未完成**的 M06（绑定 D12）；
        # 而不是已完成的 M04（D6）/M03（D9）——那些是陈旧标签。
        campaign = self._campaign(
            frontier="M05",
            statuses={"M01": "done", "M02": "done", "M03": "done",
                      "M04": "done", "M05": "pending", "M06": "pending"})
        self.assertEqual(cm._mainline_node_id(campaign), "D12")

    def test_label_empty_when_no_live_node_bound(self) -> None:
        # 全部绑定节点的里程碑都已完成：不给标签（该拍不产生分支监督），
        # 远好过给一个必然被驳回的陈旧标签。
        campaign = self._campaign(
            frontier="M07",
            statuses={"M01": "done", "M02": "done", "M03": "done",
                      "M04": "done", "M06": "done", "M07": "pending"})
        self.assertEqual(cm._mainline_node_id(campaign), "")

    def test_label_node_passes_note_model_branch_precondition(self) -> None:
        # 闭环：标签给出的节点必须能被 note_model_branch 真的采纳
        # （前置条件满足且里程碑未完成）——否则标签就是空头支票。
        campaign = self._campaign(
            frontier="M05",
            statuses={"M01": "done", "M02": "done", "M03": "done",
                      "M04": "done", "M05": "pending", "M06": "pending"})
        label = cm._mainline_node_id(campaign)
        result = cm.note_model_branch({"campaign_state": campaign}, label, tick=10)
        self.assertTrue(result.get("accepted"), msg=str(result))
        self.assertEqual(result.get("node"), label)


if __name__ == "__main__":
    unittest.main()
