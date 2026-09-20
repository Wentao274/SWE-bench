#!/usr/bin/env python3
"""SWE-bench Verified 测试编排脚本。

由 Jenkinsfile 远程调用,负责:
1. 解析 Jenkins 传入的参数
2. 创建结果目录:
       jenkins_output/<tester>/<build_number>/<chip>/<model>/<timestamp>/
3. 设置环境变量并通过 bash 调用 run_swebench.sh
4. 透传退出码

命名为 run_swebench_main.py 以避免与其他框架脚本混淆。
SWE-bench Verified 需要 Docker 镜像和本地模型 API,脚本负责完整流程:
安装 → Task Repo → 镜像准备 → 模型配置 → 推理 → 评测 → 结果汇总。
"""

import argparse
import os
import subprocess
import sys
from datetime import datetime


def parse_args():
    parser = argparse.ArgumentParser(description="Run SWE-bench Verified test via shell script")
    parser.add_argument("--tester", required=True, help="测试人员名称")
    parser.add_argument("--build-number", required=True, help="Jenkins 构建编号")
    parser.add_argument("--chip", required=True, help="芯片平台名称")
    parser.add_argument("--model", required=True, help="模型服务名称(需与 vLLM --served-model-name 一致)")
    parser.add_argument(
        "--base-url",
        required=True,
        help="OpenAI 兼容端点 URL(如 http://10.201.149.47:8080/v1)",
    )
    parser.add_argument("--api-key", default="EMPTY", help="API Key(无需认证时默认 EMPTY)")
    parser.add_argument(
        "--dataset",
        default="verified",
        choices=["verified", "lite", "full", "multimodal", "multilingual"],
        help="数据集(默认 verified = 500 实例)",
    )
    parser.add_argument("--infer-workers", default="2", help="推理并发数(默认 2)")
    parser.add_argument("--eval-workers", default="2", help="评测并发数(默认 2)")
    parser.add_argument("--temperature", default="1.0", help="采样温度(默认 1.0)")
    parser.add_argument("--top-p", default="0.95", help="Top-p 核采样(默认 0.95)")
    parser.add_argument("--max-tokens", default="32768", help="单次生成最大 token 数(默认 32768)")
    parser.add_argument("--eval-timeout", default="3600", help="每个实例超时秒数(默认 3600)")
    parser.add_argument(
        "--build-local",
        action="store_true",
        default=False,
        help="本地构建 Docker 镜像(Docker Hub 不可达时使用)",
    )
    parser.add_argument("--skip-install", action="store_true", default=False, help="跳过安装步骤")
    parser.add_argument("--skip-build", action="store_true", default=False, help="跳过镜像构建/拉取")
    parser.add_argument("--infer-only", action="store_true", default=False, help="仅运行推理")
    parser.add_argument("--eval-only", action="store_true", default=False, help="仅运行评测(需已有预测文件)")
    parser.add_argument("--instance-ids", default="", help="指定实例 ID(逗号分隔,默认空=全量)")
    parser.add_argument(
        "--extra-body",
        default="",
        help='注入每个请求体的 JSON,例: {"max_tokens": 16384, "temperature": 1.0}',
    )
    parser.add_argument(
        "--proxy",
        default="",
        help="HTTP/HTTPS 代理地址(用于 git clone、HuggingFace、docker pull);留空则不使用",
    )
    parser.add_argument(
        "--description", default="", help="模型服务描述信息(仅用于邮件展示,不影响执行)"
    )
    return parser.parse_args()


def main():
    args = parse_args()

    timestamp = datetime.now().strftime("%Y%m%d%H%M%S")
    model_dir = args.model.split("/")[-1]
    output_dir = os.path.abspath(
        f"./jenkins_output/{args.tester}/{args.build_number}/{args.chip}/{model_dir}/{timestamp}"
    )
    os.makedirs(output_dir, exist_ok=True)

    script_dir = os.path.dirname(os.path.abspath(__file__))
    shell_script = os.path.join(script_dir, "run_swebench.sh")

    if not os.path.exists(shell_script):
        print(f"Error: Shell script not found at {shell_script}")
        sys.exit(1)

    env = os.environ.copy()
    env["MODEL_NAME"] = args.model
    env["BASE_URL"] = args.base_url
    env["API_KEY"] = args.api_key
    env["OUTPUT_BASE"] = output_dir
    env["DATASET"] = args.dataset
    env["INFER_WORKERS"] = args.infer_workers
    env["EVAL_WORKERS"] = args.eval_workers
    env["TEMPERATURE"] = args.temperature
    env["TOP_P"] = args.top_p
    env["MAX_TOKENS"] = args.max_tokens
    env["EVAL_TIMEOUT"] = args.eval_timeout
    if args.build_local:
        env["BUILD_LOCAL"] = "true"
    if args.skip_install:
        env["SKIP_INSTALL"] = "true"
    if args.skip_build:
        env["SKIP_BUILD"] = "true"
    if args.infer_only:
        env["INFER_ONLY"] = "true"
    if args.eval_only:
        env["EVAL_ONLY"] = "true"
    if args.instance_ids:
        env["INSTANCE_IDS"] = args.instance_ids
    if args.extra_body:
        env["EXTRA_BODY"] = args.extra_body
    if args.proxy:
        env["PROXY_URL"] = args.proxy

    cmd = ["bash", shell_script]

    print(f"Output directory: {output_dir}")
    print(f"Command: {' '.join(cmd)}")
    print("Environment overrides:")
    for k in [
        "MODEL_NAME",
        "BASE_URL",
        "API_KEY",
        "OUTPUT_BASE",
        "DATASET",
        "INFER_WORKERS",
        "EVAL_WORKERS",
        "TEMPERATURE",
        "TOP_P",
        "MAX_TOKENS",
        "EVAL_TIMEOUT",
        "BUILD_LOCAL",
        "SKIP_INSTALL",
        "SKIP_BUILD",
        "INFER_ONLY",
        "EVAL_ONLY",
        "INSTANCE_IDS",
        "EXTRA_BODY",
        "PROXY_URL",
    ]:
        if k in env:
            print(f"  {k}={env[k]}")
    print("=" * 60)

    result = subprocess.run(cmd, env=env)

    print(f"Test completed. Output directory: {output_dir}")
    sys.exit(result.returncode)


if __name__ == "__main__":
    main()
