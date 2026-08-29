import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SKILL_DIR = ROOT / "slave/.opencode/skills/mpi-monitor"


class MpiMonitorSkillFastPathTests(unittest.TestCase):
    def setUp(self):
        self.english = (SKILL_DIR / "SKILL.md").read_text()
        self.chinese = (SKILL_DIR / "SKILL.zh.md").read_text()
        self.english_normalized = " ".join(self.english.replace("**", "").split())
        self.chinese_compact = "".join(self.chinese.replace("**", "").split())

    def test_english_skill_defines_deterministic_fast_path(self):
        self.assertIn("## Deterministic fast path", self.english)
        self.assertIn("Do not inspect the installed package source", self.english_normalized)
        self.assertIn(
            "Invoke `workflow_runner.py run mpi-monitor` exactly once",
            self.english_normalized,
        )
        self.assertIn("Extract typed workflow arguments", self.english_normalized)
        self.assertIn(
            "return its `partition_report` unchanged",
            self.english_normalized,
        )

    def test_chinese_skill_mirrors_deterministic_fast_path(self):
        self.assertIn("## 确定性快速路径", self.chinese)
        self.assertIn("禁止读取已安装包的源码", self.chinese_compact)
        self.assertIn(
            "只调用一次`workflow_runner.pyrunmpi-monitor`",
            self.chinese_compact,
        )
        self.assertIn("提取workflow类型化参数", self.chinese_compact)
        self.assertIn("原样返回其`partition_report`", self.chinese_compact)

    def test_fast_path_precedes_detailed_command_reference(self):
        self.assertLess(
            self.english.index("## Deterministic fast path"),
            self.english.index("## Commands"),
        )
        self.assertLess(
            self.chinese.index("## 确定性快速路径"),
            self.chinese.index("## 命令"),
        )

    def test_english_skill_classifies_failures_without_replaying_success(self):
        self.assertIn("## Deterministic exception handling", self.english)
        self.assertIn(
            "Never rerun a successful wrapped command",
            self.english_normalized,
        )
        for reason_code in (
            "hard_gate_failed",
            "insufficient_hosts",
            "wrapped_command_failed",
            "collection_incomplete",
            "postprocess_failed",
            "report_finalize_failed",
        ):
            self.assertIn(f"`{reason_code}`", self.english)
        self.assertIn("retry only the failed stage once", self.english_normalized)

    def test_chinese_skill_mirrors_exception_handling(self):
        self.assertIn("## 确定性异常处理", self.chinese)
        self.assertIn("禁止重新运行已经成功的被包装命令", self.chinese_compact)
        for reason_code in (
            "hard_gate_failed",
            "insufficient_hosts",
            "wrapped_command_failed",
            "collection_incomplete",
            "postprocess_failed",
            "report_finalize_failed",
        ):
            self.assertIn(f"`{reason_code}`", self.chinese)
        self.assertIn("只允许对失败阶段定向重试一次", self.chinese_compact)

    def test_skill_delegates_artifacts_to_deterministic_workflow(self):
        self.assertIn("## Fixed control plane, flexible task artifacts", self.english)
        self.assertIn(
            "The deterministic workflow owns all happy-path artifacts",
            self.english_normalized,
        )
        self.assertIn(
            "must not generate orchestration or report scripts",
            self.english_normalized,
        )
        self.assertIn(
            "must not replace the selected monitoring backend",
            self.english_normalized,
        )
        self.assertNotIn("driver.sh", self.english)

    def test_chinese_skill_delegates_artifacts_to_workflow(self):
        self.assertIn("## 固定控制层，开放任务产物", self.chinese)
        self.assertIn("确定性workflow拥有正常路径的全部产物", self.chinese_compact)
        self.assertIn(
            "不得生成编排或报告脚本",
            self.chinese_compact,
        )
        self.assertIn("不得替换已经选定的监控后端", self.chinese_compact)
        self.assertNotIn("driver.sh", self.chinese)


if __name__ == "__main__":
    unittest.main()
