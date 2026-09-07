# -*- coding: utf-8 -*-
"""AI_RTS 副官双层改造第一阶段：可独立测试的协调器核心。

职责边界（对应 docs/ai-adjutant-dual-layer/architecture.md）：
- 协调器是宿主程序：调度战略/战术模型、管理计划与任务、合并事件、
  校验模型输出、记录决策。模型不直接调用游戏命令。
- 权威执行入口是游戏侧 DebugControlServer 的 adjutant_command；
  本模块只负责协议层决策与纪律，绝不绕过游戏权威校验。
- 时钟全部注入（服务器 tick），不依赖墙钟；模型请求有代际，
  超时迟到的返回按代际丢弃，不抢回控制。
"""
