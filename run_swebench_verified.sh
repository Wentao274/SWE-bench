#!/usr/bin/env bash
set -euo pipefail

#==============================================================================
# SWE-bench Verified 一键评测脚本（uv 版）
#
# 架构：
#   GPU 机器：本地部署模型，通过 vLLM 暴露 OpenAI 兼容 API
#   CPU 机器：运行本脚本，调用模型 API 生成预测，再用 Docker 跑测试验证
#
# 前置条件：
#   - 已安装 uv（https://docs.astral.sh/uv/getting-started/installation/）
#   - 已安装 Docker 且 daemon 正在运行
#
# 用法：
#   1. 直接修改下方配置区的默认值，然后: ./run_swebench_verified.sh
#   2. 或通过命令行参数覆盖（无需改脚本），如:
#      ./run_swebench_verified.sh \
#        --api-url http://10.201.149.90/sp-sglang-agg-dsv4-flash-h1-49ee53b6 \
#        --model-name my-model \
#        --instance sympy__sympy-20590
#
#   可选参数：
#   --skip-install      跳过安装步骤（已安装过时使用）
#   --skip-build        跳过 Docker 镜像预构建
#   --infer-only        仅运行推理，不评测
#   --eval-only         仅运行评测（已有预测文件时使用）
#   --instance <id>     仅测试指定实例（如 --instance sympy__sympy-20590，可重复）
#   --api-url <url>     模型 API 地址（不带 /v1），覆盖配置区默认值
#   --model-name <name> 模型名称，覆盖配置区默认值
#   --api-key <key>     API Key，覆盖配置区默认值
#   --dataset <name>    数据集（verified|lite|full|multimodal|multilingual）
#   --infer-workers <n> 推理并发数
#   --eval-workers <n>  评测并发数
#==============================================================================

# ============================ 配置区（按需修改） ===============================

# 模型 API 地址（不带 /v1，脚本会自动拼接）
# 示例：
#   有端口：    http://10.0.0.100:8000
#   无端口：    http://10.201.149.90/sp-sglang-agg-dsv4-flash-h1-49ee53b6
API_URL="http://127.0.0.1:8080"  # <-- 改成你的 API 地址

# 模型名称（需与 vLLM 启动时 --served-model-name 一致）
MODEL_NAME="glm-5.2"                # <-- 改成你的模型名

# API Key（vLLM 默认不校验，设占位即可；若设了 token 鉴权则填真实 key）
API_KEY="EMPTY"                    # <-- 如有鉴权则改

# 模型采样参数
TEMPERATURE=1.0                    # 采样温度
TOP_P=0.95                         # Top-p 核采样
MAX_TOKENS=32768                    # 单次生成最大 token 数（补丁可能较长，建议 >= 4096）

# 并发数
INFER_WORKERS=2                    # 推理并发数（取决于 GPU 显存和吞吐）
EVAL_WORKERS=2                     # 评测并发数（建议 <= 0.75 * CPU 核数）

# 路径
WORK_DIR="$(cd "$(dirname "$0")" && pwd)"
TASK_REPO_DIR="${WORK_DIR}/swe-bench-tasks"
OUTPUT_DIR="${WORK_DIR}/outputs"
PRED_FILE="${OUTPUT_DIR}/preds.jsonl"

# Run ID（同一 run_id 的已完成实例会跳过，重测需改名字）
RUN_ID_INFER="${MODEL_NAME}-$(date +%Y%m%d_%H%M%S)"
RUN_ID_EVAL="${MODEL_NAME}-eval-$(date +%Y%m%d_%H%M%S)"

# 数据集
DATASET="verified"                 # verified | lite | full | multimodal | multilingual
SPLIT="test"

# 每个实例超时（秒）
EVAL_TIMEOUT=3600

# ============================ 配置区结束 =====================================

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "\n${BLUE}========== $* ==========${NC}"; }

# 解析命令行参数
SKIP_INSTALL=false
SKIP_BUILD=false
INFER_ONLY=false
EVAL_ONLY=false
INSTANCE_IDS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-install)    SKIP_INSTALL=true;    shift;;
        --skip-build)      SKIP_BUILD=true;      shift;;
        --infer-only)      INFER_ONLY=true;      shift;;
        --eval-only)       EVAL_ONLY=true;       shift;;
        --instance)        INSTANCE_IDS+=("$2"); shift 2;;
        --api-url)         API_URL="$2";         shift 2;;
        --model-name)      MODEL_NAME="$2";      shift 2;;
        --api-key)         API_KEY="$2";         shift 2;;
        --dataset)         DATASET="$2";         shift 2;;
        --infer-workers)   INFER_WORKERS="$2";   shift 2;;
        --eval-workers)    EVAL_WORKERS="$2";    shift 2;;
        --help|-h)
            echo "用法: ./run_swebench_verified.sh [选项]"
            echo ""
            echo "选项:"
            echo "  --api-url <url>      模型 API 地址（不带 /v1），覆盖默认值"
            echo "  --model-name <name>  模型名称，覆盖默认值"
            echo "  --api-key <key>      API Key，覆盖默认值"
            echo "  --dataset <name>     数据集（verified|lite|full|multimodal|multilingual）"
            echo "  --infer-workers <n>  推理并发数"
            echo "  --eval-workers <n>   评测并发数"
            echo "  --skip-install       跳过安装步骤"
            echo "  --skip-build         跳过 Docker 镜像预构建"
            echo "  --infer-only         仅运行推理"
            echo "  --eval-only          仅运行评测（使用已有预测文件）"
            echo "  --instance <id>      仅测试指定实例（可重复）"
            echo "  --help               显示帮助"
            echo ""
            echo "示例:"
            echo "  # 用命令行参数覆盖默认配置"
            echo "  ./run_swebench_verified.sh \\"
            echo "    --api-url http://10.201.149.90/sp-sglang-agg-dsv4-flash-h1-49ee53b6 \\"
            echo "    --model-name my-model \\"
            echo "    --instance sympy__sympy-20590"
            echo ""
            echo "  # 后台运行单实例验证"
            echo "  nohup ./run_swebench_verified.sh --api-url http://10.0.0.100:8000 \\"
            echo "    --model-name my-model --instance sympy__sympy-20590 > run.log 2>&1 &"
            exit 0;;
        *)
            log_error "未知参数: $1"; exit 1;;
    esac
done

# 构造 --instance 参数
INSTANCE_ARGS=()
for id in "${INSTANCE_IDS[@]:-}"; do
    [[ -n "$id" ]] && INSTANCE_ARGS+=("-i" "$id")
done

API_URL="${API_URL%/}"  # 去掉末尾斜杠，避免拼接时出现 //
API_BASE="${API_URL}/v1"  # 完整 API 地址（带 /v1）

# 打印最终生效的配置
log_step "配置信息"
log_info "  API_URL:      ${API_URL}"
log_info "  API_BASE:     ${API_BASE}"
log_info "  MODEL_NAME:   ${MODEL_NAME}"
log_info "  DATASET:      ${DATASET}"
log_info "  INFER_WORKERS:${INFER_WORKERS}"
log_info "  EVAL_WORKERS: ${EVAL_WORKERS}"

#==============================================================================
# Step 0: 环境检查
#==============================================================================
log_step "Step 0: 环境检查"

# 检查 uv
if ! command -v uv &>/dev/null; then
    log_error "uv 未安装！请先安装："
    log_error "  curl -LsSf https://astral.sh/uv/install.sh | sh"
    log_error "  或: pip install uv"
    exit 1
fi
log_info "uv 版本: $(uv --version)"

# 检查 Docker
if ! command -v docker &>/dev/null; then
    log_error "Docker 未安装！请先安装 Docker：https://docs.docker.com/engine/install/"
    exit 1
fi
if ! docker info &>/dev/null; then
    log_error "Docker daemon 未运行！请先启动 Docker 服务"
    exit 1
fi
log_info "Docker 正常: $(docker --version)"

# 检查 Python（uv 会管理，但确认 uv 能找到 Python）
log_info "检查 Python 环境..."
if ! timeout 30 uv python find &>/dev/null; then
    log_warn "uv 未找到可用 Python，尝试安装..."
    timeout 120 uv python install 3.12 || {
        log_error "无法安装 Python，请手动安装 Python >= 3.10"
        exit 1
    }
fi
# uv run 首次会自动触发 uv sync（下载依赖），可能耗时较长
log_info "探测 Python 版本（首次执行可能触发 uv sync，请耐心等待）..."
PY_VERSION=$(timeout 300 uv run python -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "0")
log_info "Python 版本: ${PY_VERSION}"
if [[ "$PY_VERSION" == "0" ]]; then
    log_error "无法运行 uv run python，请手动执行 'uv sync --extra datasets' 检查依赖安装"
    exit 1
fi
if timeout 30 uv run python -c "import sys; exit(0 if sys.version_info >= (3,10) else 1)" 2>/dev/null; then
    log_info "Python 版本满足要求 (>= 3.10)"
else
    log_error "Python 版本过低！需要 >= 3.10，当前 ${PY_VERSION}"
    exit 1
fi

# 检查 GPU 机器 API 是否可达
log_info "检查 GPU 机器 API (${API_BASE}) ..."
if curl -sf --max-time 10 "${API_BASE}/models" -H "Authorization: Bearer ${API_KEY}" >/dev/null 2>&1; then
    log_info "GPU 机器 API 可达"
    curl -sf --max-time 10 "${API_BASE}/models" -H "Authorization: Bearer ${API_KEY}" 2>/dev/null | uv run python -m json.tool 2>/dev/null | head -20 || true
else
    log_warn "无法连接到 GPU 机器 API (${API_BASE})"
    log_warn "请确认：1) vLLM 已启动  2) IP/端口正确  3) 网络可达  4) 防火墙放行"
    log_warn "继续执行（推理步骤会失败报错）..."
fi

# 磁盘空间检查
AVAILABLE_GB=$(df -BG "${WORK_DIR}" 2>/dev/null | awk 'NR==2{print $4}' | tr -d 'G' || echo "0")
if [[ "$AVAILABLE_GB" -lt 120 ]] 2>/dev/null; then
    log_warn "可用磁盘空间约 ${AVAILABLE_GB}GB，建议至少 120GB（Docker 镜像较大）"
else
    log_info "可用磁盘空间: ${AVAILABLE_GB}GB"
fi

#==============================================================================
# Step 1: 安装 SWE-bench 和 mini-SWE-agent（通过 uv sync）
#==============================================================================
if [[ "$SKIP_INSTALL" == "false" ]]; then
    log_step "Step 1: 安装依赖（uv sync）"

    log_info "uv sync --extra datasets ..."
    log_info "  - base 依赖: swebench 核心 + docker + huggingface 等"
    log_info "  - dev 组（默认安装）: mini-swe-agent + pytest"
    log_info "  --extra datasets: openai + anthropic + litellm + tiktoken 等"

    uv sync --extra datasets || {
        log_error "uv sync 失败！"
        log_error "尝试: uv sync --extra datasets --no-lockfile"
        uv sync --extra datasets --no-lockfile || {
            log_error "安装失败，请手动排查"
            exit 1
        }
    }

    log_info "验证安装..."
    uv run swebench --version 2>/dev/null || uv run python -c "import swebench; print(swebench.__version__)" || true
    uv run python -c "import minisweagent; print('mini-SWE-agent OK')" || log_warn "mini-SWE-agent 导入失败，推理步骤可能出错"
else
    log_step "Step 1: 跳过安装（--skip-install）"
fi

#==============================================================================
# Step 2: 准备 Task Repo（Docker 镜像源）
#==============================================================================
log_step "Step 2: 准备 Task Repo"

if [[ -d "${TASK_REPO_DIR}" ]] && [[ -f "${TASK_REPO_DIR}/sweb.yaml" ]]; then
    log_info "Task Repo 已存在: ${TASK_REPO_DIR}"
    log_info "更新 Task Repo..."
    git -C "${TASK_REPO_DIR}" pull --ff-only || log_warn "Task Repo 更新失败，使用本地版本"
else
    log_info "克隆 Task Repo..."
    git clone --depth 1 https://github.com/SWE-bench/swe-bench-tasks.git "${TASK_REPO_DIR}" || {
        log_error "Task Repo 克隆失败"
        exit 1
    }
fi

log_info "检查 Task Repo 完整性..."
uv run swebench dataset check "${TASK_REPO_DIR}" --fix 2>&1 || true
log_info "Task Repo 校验完成（个别坏实例不影响指定实例的评测）"

#==============================================================================
# Step 3: 预构建 Docker 镜像（可选，避免评测时等待）
#==============================================================================
if [[ "$SKIP_BUILD" == "false" ]] && [[ "$INFER_ONLY" == "false" ]]; then
    log_step "Step 3: 预构建 Docker 镜像"

    log_info "从 Task Repo 构建 Docker 镜像（可能需要较长时间）..."
    log_info "构建参数: -j ${EVAL_WORKERS}"
    if [[ ${#INSTANCE_IDS[@]} -gt 0 ]]; then
        BUILD_INSTANCE_ARGS=()
        for id in "${INSTANCE_IDS[@]}"; do
            BUILD_INSTANCE_ARGS+=("-i" "$id")
        done
        uv run swebench images build "${TASK_REPO_DIR}" -j "${EVAL_WORKERS}" "${BUILD_INSTANCE_ARGS[@]}" || {
            log_warn "部分镜像构建失败，评测时会尝试从 registry 拉取"
        }
    else
        uv run swebench images build "${TASK_REPO_DIR}" -j "${EVAL_WORKERS}" || {
            log_warn "部分镜像构建失败，评测时会尝试从 registry 拉取"
        }
    fi
    log_info "Docker 镜像构建完成"
else
    log_step "Step 3: 跳过镜像预构建（--skip-build 或 --infer-only）"
fi

#==============================================================================
# Step 4: 生成 mini-SWE-agent 模型配置文件
#==============================================================================
log_step "Step 4: 生成模型配置"

MODEL_CONFIG="${WORK_DIR}/model_config.yaml"

cat > "${MODEL_CONFIG}" <<EOF
# mini-SWE-agent 模型配置（自动生成）
# model 为 dict，mini-SWE-agent 的 get_model() 期望字典格式
# model_name 通过 -m 参数传递，此处只配置连接和采样参数
model:
  api_base: ${API_BASE}
  api_key: ${API_KEY}
  temperature: ${TEMPERATURE}
  top_p: ${TOP_P}
  max_tokens: ${MAX_TOKENS}
EOF

log_info "模型配置已写入: ${MODEL_CONFIG}"
cat "${MODEL_CONFIG}"

# 同时设置环境变量（litellm 也会读取）
export OPENAI_API_KEY="${API_KEY}"
export OPENAI_BASE_URL="${API_BASE}"

#==============================================================================
# Step 5: 推理 - 调用本地模型生成补丁
#==============================================================================
if [[ "$EVAL_ONLY" == "false" ]]; then
    log_step "Step 5: 推理（mini-SWE-agent 调用本地模型）"

    mkdir -p "${OUTPUT_DIR}"

    log_info "数据集: ${DATASET} (split: ${SPLIT})"
    log_info "模型 API: ${API_BASE}"
    log_info "模型名: ${MODEL_NAME}"
    log_info "推理并发: ${INFER_WORKERS}"
    log_info "Run ID: ${RUN_ID_INFER}"
    log_info "输出目录: ${OUTPUT_DIR}"

    if [[ ${#INSTANCE_IDS[@]} -gt 0 ]]; then
        log_info "指定实例: ${INSTANCE_IDS[*]}"
    fi

    # 预览命令
    echo ""
    echo "  将执行:"
    echo "    uv run swebench infer ${DATASET} \\"
    echo "      -m openai/${MODEL_NAME} \\"
    echo "      -c ${MODEL_CONFIG} \\"
    echo "      --run-id ${RUN_ID_INFER} \\"
    echo "      -w ${INFER_WORKERS} \\"
    echo "      -o ${OUTPUT_DIR}"
    if [[ ${#INSTANCE_IDS[@]} -gt 0 ]]; then
        echo "      -- --filter \"${INSTANCE_IDS[*]}\""
    fi
    echo ""

    # 执行推理
    # 注意：swebench infer 的额外参数（如 --filter）通过 -- 传递
    EXTRA_ARGS=()
    if [[ ${#INSTANCE_IDS[@]} -gt 0 ]]; then
        # mini-SWE-agent 支持 --filter 过滤实例
        FILTER_PATTERN=$(IFS='|'; echo "${INSTANCE_IDS[*]}")
        EXTRA_ARGS+=("--" "--filter" "${FILTER_PATTERN}")
    fi

    uv run swebench infer "${DATASET}" \
        -m "openai/${MODEL_NAME}" \
        -c "${MODEL_CONFIG}" \
        --run-id "${RUN_ID_INFER}" \
        -w "${INFER_WORKERS}" \
        -o "${OUTPUT_DIR}" \
        "${EXTRA_ARGS[@]}" || {
            log_error "推理失败！"
            log_error "请检查："
            log_error "  1. GPU 机器 vLLM 服务是否正常"
            log_error "  2. 模型名 '${MODEL_NAME}' 是否与 vLLM --served-model-name 一致"
            log_error "  3. 网络是否可达 ${API_BASE}"
            log_error "  4. 推理日志: logs/inference/${RUN_ID_INFER}/"
            exit 1
        }

    log_info "推理完成！"

    # 查找生成的预测文件（mini-SWE-agent 输出 preds.json 或 preds.jsonl）
    if [[ -f "${OUTPUT_DIR}/preds.json" ]]; then
        PRED_FILE="${OUTPUT_DIR}/preds.json"
    elif [[ -f "${OUTPUT_DIR}/preds.jsonl" ]]; then
        PRED_FILE="${OUTPUT_DIR}/preds.jsonl"
    fi

    # 检查预测文件是否存在且非空
    if [[ ! -f "${PRED_FILE}" ]] || [[ ! -s "${PRED_FILE}" ]]; then
        log_error "推理未生成有效预测文件！"
        log_error "  预测文件路径: ${PRED_FILE}"
        log_error "  推理日志: logs/inference/${RUN_ID_INFER}/"
        log_error "  mini-SWE-agent 日志: ${OUTPUT_DIR}/minisweagent.log"
        exit 1
    fi

    log_info "预测文件: ${PRED_FILE}"

    # 统计预测数量
    PRED_COUNT=$(wc -l < "${PRED_FILE}" 2>/dev/null || wc -l "${PRED_FILE}" | awk '{print $1}')
    log_info "生成预测数量: ${PRED_COUNT} 条"

    # 打印一条预测示例
    log_info "预测示例（第一条）:"
    head -1 "${PRED_FILE}" 2>/dev/null | uv run python -m json.tool 2>/dev/null | head -10 || true
else
    log_step "Step 5: 跳过推理（--eval-only）"
    log_info "使用已有预测文件: ${PRED_FILE}"

    if [[ ! -f "${PRED_FILE}" ]]; then
        log_error "预测文件不存在: ${PRED_FILE}"
        log_error "请先运行推理，或通过环境变量 PRED_FILE 指定路径"
        exit 1
    fi
fi

#==============================================================================
# Step 6: 评测 - 在 Docker 容器中运行测试验证补丁
#==============================================================================
if [[ "$INFER_ONLY" == "true" ]]; then
    log_step "Step 6: 跳过评测（--infer-only）"
    log_info "推理结果保存在: ${PRED_FILE}"
    log_info "稍后可单独评测: bash run_swebench_verified.sh --eval-only"
    exit 0
fi

log_step "Step 6: 评测（Docker 容器中运行测试）"

log_info "预测文件: ${PRED_FILE}"
log_info "数据集: ${DATASET} (split: ${SPLIT})"
log_info "评测并发: ${EVAL_WORKERS}"
log_info "超时设置: ${EVAL_TIMEOUT}s / 实例"
log_info "Run ID: ${RUN_ID_EVAL}"
log_info "Task Repo: ${TASK_REPO_DIR}"
if [[ ${#INSTANCE_IDS[@]} -gt 0 ]]; then
    log_info "指定实例: ${INSTANCE_IDS[*]}"
fi

echo ""
echo "  将执行:"
echo "    uv run swebench eval ${DATASET} \\"
echo "      -p ${PRED_FILE} \\"
echo "      --run-id ${RUN_ID_EVAL} \\"
echo "      -j ${EVAL_WORKERS} \\"
echo "      -t ${EVAL_TIMEOUT} \\"
echo "      --task-repo ${TASK_REPO_DIR}"
if [[ ${#INSTANCE_IDS[@]} -gt 0 ]]; then
    for id in "${INSTANCE_IDS[@]}"; do
        echo "      -i ${id}"
    done
fi
echo ""

uv run swebench eval "${DATASET}" \
    -p "${PRED_FILE}" \
    --run-id "${RUN_ID_EVAL}" \
    -j "${EVAL_WORKERS}" \
    -t "${EVAL_TIMEOUT}" \
    --task-repo "${TASK_REPO_DIR}" \
    "${INSTANCE_ARGS[@]}" || {
        log_error "评测失败！"
        log_error "请检查："
        log_error "  1. Docker 是否正常运行"
        log_error "  2. 磁盘空间是否充足"
        log_error "  3. 评测日志: logs/evaluation/${RUN_ID_EVAL}/"
        exit 1
    }

#==============================================================================
# Step 7: 输出结果
#==============================================================================
log_step "Step 7: 评测结果"

RESULTS_FILE="logs/evaluation/${RUN_ID_EVAL}/results.json"

if [[ -f "${RESULTS_FILE}" ]]; then
    log_info "结果文件: ${RESULTS_FILE}"
    echo ""
    echo "----------------------------------------"
    uv run python -m json.tool "${RESULTS_FILE}" 2>/dev/null || cat "${RESULTS_FILE}"
    echo "----------------------------------------"
else
    log_warn "结果文件未找到: ${RESULTS_FILE}"
    log_info "请手动查看 logs/evaluation/${RUN_ID_EVAL}/ 目录"
fi

echo ""
log_info "评测完成！"
log_info "  推理日志: logs/inference/${RUN_ID_INFER}/"
log_info "  评测日志: logs/evaluation/${RUN_ID_EVAL}/"
log_info "  汇总结果: ${RESULTS_FILE}"
echo ""
log_info "每个实例的详细结果在:"
log_info "  logs/evaluation/${RUN_ID_EVAL}/<model_name>/<instance_id>/"
log_info "    ├── report.json       单实例结果"
log_info "    ├── test_output.txt    测试输出"
log_info "    ├── run_instance.log   运行日志"
log_info "    ├── eval.sh            测试脚本"
log_info "    └── patch.diff         应用的补丁"
