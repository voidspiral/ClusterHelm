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
            "Generate fresh job-local orchestration and post-processing scripts",
            self.english_normalized,
        )
        self.assertIn("Do not debate whether to use `mpi-monitor`", self.english_normalized)
        self.assertIn(
            "write `plot_base64_png` to the job JSON only",
            self.english_normalized,
        )

    def test_chinese_skill_mirrors_deterministic_fast_path(self):
        self.assertIn("## 确定性快速路径", self.chinese)
        self.assertIn("禁止读取已安装包的源码", self.chinese_compact)
        self.assertIn(
            "每个作业重新生成作业级编排与后处理脚本",
            self.chinese_compact,
        )
        self.assertIn("禁止讨论是否使用`mpi-monitor`", self.chinese_compact)
        self.assertIn("`plot_base64_png`只写入作业JSON", self.chinese_compact)

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


if __name__ == "__main__":
    unittest.main()
