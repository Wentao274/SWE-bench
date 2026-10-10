# SWE-bench Verified 本地 CI/CD 使用说明

本文件补足 [`README.md`](README.md) 中**未覆盖**的本地脚本编排、Jenkins 流水线
与远程执行约定。SWE-bench 上游 README 讲的是单机命令跑评测;本文件讲的是
**如何在 Jenkins 上参数化触发、远程 ssh 到测试机跑、把结果/mail 发回**。

特点:
- **需要 Docker 镜像** — SWE-bench Verified 的 500 个实例各有对应的 Docker 镜像
  (约 3-7GB/个)，评测时在容器中运行测试验证补丁
- **两阶段执行** — 先推理(模型生成补丁)，再评测(Docker 容器验证补丁)
- **镜像来源** — 默认优先使用本地镜像,未找到时才从 Docker Hub 拉取;
  也可本地构建(`--build-local`,仅在镜像不存在时才构建)
- **结果为 JSON** — `swebench-results.json` 包含 resolved/total/score，
  邮件 stage 直接解析该文件

---

## 1. 文件清单

| 文件 | 角色 |
|------|------|
| `run_swebench.sh` | shell 主入口,通过环境变量接收配置(Jenkins 路径) |
| `run_swebench_main.py` | Python 编排器,Jenkins → shell 的桥 |
| `Jenkinsfile` | Jenkins 声明式流水线 |
| `run_swebench_verified_local.sh` | 本地手动执行脚本(命令行参数,功能最全) |

`run_swebench.sh` 不会自己读 Jenkins 参数;它通过环境变量接收所有配置,
由 `run_swebench_main.py` 统一注入。`run_swebench_verified_local.sh` 是
本地手动使用的版本,支持命令行参数,每次运行独立目录互不覆盖。

---

## 2. 目录与日志层级

### 本地脚本输出目录

```
<WORK_DIR>/local_results/<model_name>/<timestamp>/
├── model_config.yaml                  # mini-SWE-agent 模型配置
├── outputs/                           # 推理输出
│   ├── preds.jsonl                    # 预测文件(补丁)
│   └── minisweagent.log               # mini-SWE-agent 日志
└── logs/                              # 评测输出
    ├── inference/<run_id_infer>/      # 推理详细日志
    └── evaluation/<run_id_eval>/      # 评测详细日志
        ├── results.json                # 完整结果(含所有实例状态)
        └── <model_name>/<instance_id>/ # 每个实例的详细结果
            ├── report.json             # 单实例结果
            ├── test_output.txt         # 测试输出
            ├── run_instance.log        # 运行日志
            ├── eval.sh                 # 测试脚本
            └── patch.diff              # 应用的补丁
```

每次运行创建独立的 `<timestamp>` 目录(格式 `YYYYMMDD_HHMMSS`),互不覆盖。

### Jenkins 输出目录

```
<WORK_DIR>/jenkins_output/<tester>/<build_number>/<chip>/<model>/<timestamp>/
├── swebench.log                      # 全程 tee 出来的总日志(邮件附件)
├── swebench-results.json             # 评测结果摘要(邮件解析该文件)
├── model_config.yaml                  # mini-SWE-agent 模型配置
├── outputs/                           # 推理输出
│   ├── preds.jsonl                    # 预测文件(补丁)
│   ├── minisweagent.log               # mini-SWE-agent 日志
│   └── backup_*                       # 旧预测文件备份
└── logs/                              # 评测输出
    ├── inference/<run_id_infer>/      # 推理详细日志
    └── evaluation/<run_id_eval>/      # 评测详细日志
        ├── results.json                # 完整结果(含所有实例状态)
        └── <model_name>/<instance_id>/ # 每个实例的详细结果
            ├── report.json             # 单实例结果
            ├── test_output.txt         # 测试输出
            ├── run_instance.log        # 运行日志
            ├── eval.sh                 # 测试脚本
            └── patch.diff              # 应用的补丁
```

`<tester>` / `<build_number>` / `<chip>` / `<model>` / `<timestamp>` 五层目录层级。
`swebench-results.json` 由 `run_swebench.sh` 写入,邮件 stage 通过 `readJSON`
直接读取,不靠正则提 stdout。

### swebench-results.json 格式

```json
{
  "status": "completed",
  "model": "glm-5.2",
  "dataset": "verified",
  "run_id_infer": "glm-5.2-20260920_120000",
  "run_id_eval": "glm-5.2-eval-20260920_130000",
  "resolved_instances": 368,
  "total_instances": 500,
  "score": "73.6%",
  "results_file": "logs/evaluation/glm-5.2-eval-20260920_130000/results.json"
}
```

---

## 3. 三种使用方式

### 3.1 直接调 shell(本地 smoke)

```bash
# 单实例测试(默认 127.0.0.1:8080)
bash run_swebench_verified_local.sh --instance sympy__sympy-20590

# 通过命令行参数覆盖
bash run_swebench_verified_local.sh \
    --api-url http://10.201.149.47:8080 \
    --model-name glm-5.2 \
    --instance sympy__sympy-20590

# 全量评测(优先使用本地镜像)
bash run_swebench_verified_local.sh \
    --api-url http://10.201.149.47:8080 \
    --model-name glm-5.2

# 全量评测 + 本地构建镜像(镜像不存在时才构建;已存在则直接使用)
bash run_swebench_verified_local.sh \
    --api-url http://10.201.149.47:8080 \
    --model-name glm-5.2 \
    --build-local

# 使用代理(git clone、HuggingFace、docker pull 等网络操作)
bash run_swebench_verified_local.sh \
    --api-url http://10.201.149.47:8080 \
    --model-name glm-5.2 \
    --proxy http://10.201.136.68:1080

# 仅评测(使用已有预测文件)
bash run_swebench_verified_local.sh \
    --api-url http://10.201.149.47:8080 \
    --model-name glm-5.2 \
    --eval-only \
    --pred-file local_results/glm-5.2/20260920_120000/outputs/preds.jsonl
```

### 3.2 通过 run_swebench_main.py 编排(本地复现 Jenkins 行为)

```bash
python3 run_swebench_main.py \
    --tester liwt \
    --build-number manual001 \
    --chip nvidia-h100 \
    --model glm-5.2 \
    --base-url http://10.201.149.47:8080/v1 \
    --dataset verified \
    --infer-workers 2 \
    --eval-workers 2 \
    --temperature 1.0 \
    --top-p 0.95 \
    --max-tokens 32768 \
    --eval-timeout 3600
```

`run_swebench_main.py` 会:
1. 创建 `./jenkins_output/liwt/manual001/nvidia-h100/glm-5.2/<timestamp>/`
2. 设置环境变量(`MODEL_NAME` / `BASE_URL` / `OUTPUT_BASE` / ...)
3. 调 `bash run_swebench.sh`,透传退出码

单实例测试:
```bash
python3 run_swebench_main.py \
    --tester liwt \
    --build-number smoke001 \
    --chip nvidia-h100 \
    --model glm-5.2 \
    --base-url http://10.201.149.47:8080/v1 \
    --instance-ids sympy__sympy-20590
```

### 3.3 通过 Jenkins 触发(生产路径)

打开 Jenkins job → Build with Parameters → 填端点、选数据集 → 构建。
Jenkins 通过 ssh 远程到 `REMOTE_HOST`(默认 `10.201.132.50`)在 `WORK_DIR` 下
跑 `run_swebench_main.py`,完成后 scp 拉回结果、归档、发邮件。

流水线共 6 个 stage(`Jenkinsfile`):

| stage | 作用 |
|-------|------|
| 打印测试参数 | 回显所有入参到控制台 |
| API 连通性预检 | curl `/v1/models` + `/v1/chat/completions`,任一非 200 则置 `CONNECTIVITY_FAILED`,后续运行 stage 跳过、构建置 UNSTABLE |
| 环境检查 | 清理 `swebench` / `run_swebench_main` / Docker 容器残留进程;运行 `uv sync --extra datasets` 安装/更新依赖 |
| 运行SWE-bench测试 | 远程执行 `python3 run_swebench_main.py ...`;`catchError` 包裹,失败置 FAILURE 但不阻塞后续 stage |
| 拉取测试结果 | scp 远程 `jenkins_output/...` 到本地 `reports/<tester>/<build>/<chip>/`;连通性失败时只拉预检日志 |
| 发送邮件 | 解析 `swebench-results.json` 渲染 HTML 报告,附 `swebench.log` + 预检日志;`catchError` 包裹,永远执行 |

连通性预检失败时:运行/结果拉取 stage 被跳过,邮件照常发出,内含红色告警框与失败 curl 响应片段。

---

## 4. Jenkins 参数清单

| Jenkins 参数 | 对应脚本参数 | 默认 | 说明 |
|--------------|-------------|------|------|
| `TESTER` | — | `liwt` | 测试人员(目录分层用) |
| `CHIP` | — | `nvidia-h100` | 芯片平台(目录分层用) |
| `ENGINE` / `PD` | — | `vllm` / `agg` | 仅邮件展示,不影响执行 |
| `MODEL` | `--model` | `glm-5.2` | 模型服务名(需与 vLLM --served-model-name 一致) |
| `BASE_URL` | `--base-url` | `http://10.201.149.47:8080` | 端点根 URL(流水线自动拼接 /v1) |
| `API_KEY` | `--api-key` | 空 → `EMPTY` | 鉴权(本地推理服务通常忽略) |
| `DATASET` | `--dataset` | `verified` | 数据集(verified=500/lite=300/full=2294) |
| `INSTANCE_IDS` | `--instance-ids` | 空 | 指定实例 ID(逗号分隔);留空=全量 |
| `TEMPERATURE` | `--temperature` | `1.0` | 采样温度 |
| `TOP_P` | `--top-p` | `0.95` | Top-p 核采样 |
| `MAX_TOKENS` | `--max-tokens` | `32768` | 单次生成最大 token 数 |
| `INFER_WORKERS` | `--infer-workers` | `2` | 推理并发数 |
| `EVAL_WORKERS` | `--eval-workers` | `2` | 评测并发数 |
| `EVAL_TIMEOUT` | `--eval-timeout` | `3600` | 每实例超时秒数 |
| `BUILD_LOCAL` | `--build-local` | `false` | 镜像不存在时本地构建;镜像已存在时勾选无效(不会删除已有镜像) |
| `SKIP_INSTALL` | `--skip-install` | `false` | 跳过 uv sync |
| `SKIP_BUILD` | `--skip-build` | `false` | 跳过镜像构建/拉取 |
| `INFER_ONLY` | `--infer-only` | `false` | 仅推理 |
| `EVAL_ONLY` | `--eval-only` | `false` | 仅评测(需已有预测文件) |
| `EXTRA_BODY` | `--extra-body` | 空 | 注入请求体的 JSON |
| `PROXY` | `--proxy` | `http://10.201.136.68:1080` | HTTP/HTTPS 代理(git clone、HuggingFace、docker pull) |
| `DESCRIPTION` | `--description` | 空 | 模型服务描述(仅用于邮件展示) |
| `RECIPIENTS` / `WORK_DIR` | — | — | 邮件收件人/远程目录 |

---

## 5. Docker 镜像说明

### 镜像命名规则 (swebench/image_builder/image_spec.py:37-44)

- **本地构建** (namespace=None)：`sweb.eval.x86_64.<instance_id>:latest` (保留 `__`，小写)
- **Docker Hub** (namespace=swebench)：`swebench/sweb.eval.x86_64.<id_with_1776>:latest` (`__` → `_1776_`，小写)

### 镜像来源策略

| 场景 | 策略 | 说明 |
|------|------|------|
| 全量评测(默认) | 优先本地镜像 | 评测时先查本地,未找到才从 Docker Hub 拉取;已预拉取时无需网络 |
| 全量评测 + `BUILD_LOCAL` | 镜像不存在才构建 | 先抽样检查镜像是否已存在;已存在则不传 `--task-repo`(避免删除);不存在才本地构建 |
| 指定实例 | 本地构建 → Docker Hub 拉取 | 有 buildx 时优先本地构建 |
| `SKIP_BUILD` | 跳过 | 使用已有镜像 |

### 评测时的镜像解析逻辑 (swebench/harness/run_evaluation.py:88-101)

评测 harness 对每个实例按以下顺序查找镜像:
1. `client.images.get(test_spec.image)` — **先查本地** Docker 镜像
2. 如果本地未找到 → `client.images.pull(test_spec.image)` — 从 Docker Hub 拉取
3. 拉取也失败 → 该实例报错

**关键**: 镜像已预拉取到本地时,评测全程不需要 Docker Hub 网络访问。
即使 Docker Hub 不可达,只要 500 个镜像都在本地,评测可以正常完成。

### 注意事项

- `swebench images build` 即使构建失败也返回退出码 0 — 脚本会重新检查镜像是否存在
- `swebench eval --task-repo` 会用 `force_rebuild=True` **删除并重建**所有镜像
  - 脚本已修复:`BUILD_LOCAL` 时先抽样检查镜像是否已存在,已存在则不传 `--task-repo`,避免删除
  - 仅当镜像确实不存在时才传 `--task-repo` 触发本地构建
- 每个评测容器的 Docker 客户端超时：1800s (`SWEBENCH_DOCKER_TIMEOUT`)
- 全量评测需要约 200-400GB 磁盘空间(500 个镜像 × 3-7GB)

---

## 6. 执行流程

`run_swebench.sh` 执行 8 个步骤:

| Step | 作用 |
|------|------|
| Step 0 | 环境检查(uv / Docker / Python / API / 磁盘空间) |
| Step 1 | 安装依赖(`uv sync --extra datasets`) |
| Step 2 | 准备 Task Repo(克隆/更新 swe-bench-tasks) |
| Step 3 | 准备 Docker 镜像(构建/拉取/检查) |
| Step 4 | 生成模型配置(model_config.yaml) |
| Step 5 | 推理(mini-SWE-agent 调用模型生成补丁) |
| Step 6 | 评测(Docker 容器中运行测试验证补丁) |
| Step 7 | 输出结果(results.json + swebench-results.json) |

---

## 7. extra_body 参数说明

`EXTRA_BODY` 是注入到每个 LLM 请求体的 JSON,通过 model_config.yaml 中的
`extra_body` 字段传入,最终由 mini-SWE-agent 展开到请求体顶层。

**常见配置:**

| 模型族 | 推荐 EXTRA_BODY | 说明 |
|--------|----------------|------|
| glm-5.2/5.3 (推理模型) | `{"max_tokens": 32768, "temperature": 1.0}` | 限制推理长度 |
| 通用 instruct | `{"max_tokens": 8192, "temperature": 0.7}` | 适中上限 |
| 不注入 | 留空 | 使用脚本默认值 |

---

## 8. 代理与网络

### 代理配置

评测流程涉及以下网络操作,可能需要代理:

| 操作 | 网络目标 | 需要代理? | 说明 |
|------|---------|----------|------|
| `uv sync` | PyPI | 视网络而定 | 安装 Python 依赖 |
| `git clone swe-bench-tasks` | GitHub | 视网络而定 | 首次克隆 Task Repo;已克隆则跳过 |
| HuggingFace 数据集加载 | huggingface.co | 视网络而定 | 首次下载;已缓存(~/.cache/huggingface/)则跳过 |
| `docker pull` | Docker Hub | 视网络而定 | 镜像未在本地时拉取;已预拉取则跳过 |
| Docker 容器内测试 | 无 | 不需要 | 测试在容器内本地运行,不需要网络 |

### 代理使用方式

**Jenkins**: 通过 `PROXY` 参数配置,默认 `http://10.201.136.68:1080`。
- 环境检查 stage: 代理仅用于 `uv sync`
- 运行测试 stage: 代理通过 `--proxy` 传给 `run_swebench_main.py`,再传给 `run_swebench.sh`
  - `run_swebench.sh` 将代理导出为 `http_proxy` / `https_proxy` / `HTTP_PROXY` / `HTTPS_PROXY`
  - Step 0-4 环境准备阶段: 代理生效(git clone、HuggingFace 数据集加载、uv sync 等)
  - Step 4 之后: **不 unset 代理**,改为设置 `NO_PROXY` 排除内网模型 API 的 host
    - Step 5(推理): HuggingFace 数据集加载、litellm 模型价格表拉取走代理;模型 API 调用通过 `NO_PROXY` 直连
    - Step 6(评测): Docker 容器不继承宿主 shell 代理环境变量,不受影响

**本地脚本**: 通过 `--proxy` 参数或 `PROXY_URL` 环境变量配置:
```bash
# 命令行参数
bash run_swebench_verified_local.sh --proxy http://10.201.136.68:1080 ...

# 环境变量
PROXY_URL=http://10.201.136.68:1080 bash run_swebench_verified_local.sh ...
```

### Docker 守护进程代理

`docker pull` 由 Docker 守护进程执行,不读取 shell 的 `http_proxy` 环境变量。
如果 Docker Hub 需要代理,需单独配置 Docker 守护进程:

```bash
# 创建 Docker 代理配置
mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/proxy.conf << 'EOF'
[Service]
Environment="HTTP_PROXY=http://10.201.136.68:1080"
Environment="HTTPS_PROXY=http://10.201.136.68:1080"
EOF
systemctl daemon-reload
systemctl restart docker
```

**注意**: 如果 500 个镜像已预拉取到本地,则 `docker pull` 不会被执行,无需配置 Docker 守护进程代理。

---

## 9. 邮件通知

- **触发条件**:`发送邮件` stage 永远执行(`catchError` 包裹,失败不阻塞 build)
- **数据源**:`swebench-results.json`(由 `run_swebench.sh` 写入),
  用 `readJSON` 步骤直接解析
- **展示内容**:
  - 测试概要:构建编号、模型、数据集、参数、执行时间、状态
  - SWE-bench 得分:resolved/total/score
  - 连通性失败:红色告警框 + 失败 curl 响应片段
- **附件**:`swebench.log` + 连通性预检日志

---

## 10. 环境准备

SWE-bench 需要 uv + Docker 环境:

```bash
# 在仓库根目录执行
uv sync --extra datasets    # 创建 .venv 并安装所有依赖
uv run swebench --version    # 确认安装
docker --version             # 确认 Docker
docker info                  # 确认 daemon 运行
```

Jenkins 环境检查 stage 会自动执行 `uv sync --extra datasets`。
代理通过 `PROXY` 参数配置(默认 `http://10.201.136.68:1080`),仅用于环境准备阶段(Step 0-4)。

### litellm 版本约束

litellm 必须 `>=1.85.0,<1.90.0`(1.98.0 移除了 `litellm.exceptions`,
导致 mini-SWE-agent 2.4.6 崩溃)。已在 `pyproject.toml` 中固定。

---

## 11. 故障排查

| 现象 | 排查路径 |
|------|----------|
| 大量空补丁(317/500) | Docker 镜像拉取超时;预拉取镜像或配置 Docker 守护进程代理 |
| 推理超时 | 模型 API 负载过高;减少 `INFER_WORKERS`,或增大 `MAX_TOKENS` |
| 评测容器超时 | 单实例测试时间过长;增大 `EVAL_TIMEOUT`(默认 3600s) |
| `missing_module` 失败 | 环境问题,非模型问题;Docker 镜像中缺少 Python 依赖 |
| `no_tests_collected` | 环境问题;测试无法收集,通常与镜像版本相关 |
| litellm 版本不兼容 | 检查 `uv run python -c "import litellm; print(litellm.__version__)"`;确认 `<1.90.0` |
| Docker 磁盘不足 | `docker system prune -a` 清理;全量评测需 200-400GB |
| 连通性预检失败 | 确认推理服务已启动,`curl http://<host>:<port>/v1/models` 返回 200 |
| 远程 .venv 缺包 | 删 `.venv` 重跑环境检查 stage |
| 邮件 metrics 全 N/A | `find reports/<tester>/<build> -name swebench-results.json` 看是否拉到本地 |
| git clone 超时 | 配置 `--proxy` 参数;或手动克隆 swe-bench-tasks 到 WORK_DIR |
| HuggingFace 数据集下载失败 | 配置 `--proxy` 参数;或设置 `HF_ENDPOINT=https://hf-mirror.com`;或预缓存数据集 |
| docker pull 失败 | 配置 Docker 守护进程代理(见第 8 节);或预拉取所有镜像 |
| `BUILD_LOCAL` 删除了已拉取的镜像 | 已修复:`BUILD_LOCAL` 时先检查镜像是否已存在,已存在则不传 `--task-repo`;如仍遇到,检查抽样逻辑是否命中正确镜像名 |

---

## 12. 已知结果参考

| 运行日期 | 模型 | 得分 | 说明 |
|---------|------|------|------|
| 2026-09-17 | deepseek-v4-flash | 143/500 = 28.6% | 首次运行(317 空补丁,镜像拉取超时) |
| 2026-09-18 | deepseek-v4-flash | 368/500 = 73.6% | 预拉取镜像后(2 空补丁,0 超时) |

### 各仓库得分(第二次运行)

| 仓库 | 得分 |
|------|------|
| scikit-learn | 93.8% |
| pydata | 86.4% |
| pytest-dev | 78.9% |
| django | 74.9% |
| matplotlib | 73.5% |
| sympy | 72.0% |
| sphinx-doc | 70.5% |
| astropy | 68.2% |
| pylint-dev | 30.0% |
| psf | 12.5% |
