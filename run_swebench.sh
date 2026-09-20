#!/usr/bin/env bash
#
# SWE-bench Verified 测试脚本主入口 (Jenkins 触发用)
#
# - 通过环境变量接收运行期参数(由 run_swebench_main.py 设置)
# - 所有输出 tee 到统一日志文件,便于 Jenkins 邮件解析
# - 失败不中断(单次评测调用,catchError 在 Jenkinsfile 层处理)
#
# 与 run_swebench_verified_local.sh 的区别:
#   - 本脚本不解析命令行参数,全部从环境变量读取
#   - 日志 tee 到 ${OUTPUT_BASE}/swebench.log
#   - 结果 JSON 输出到 ${OUTPUT_BASE}/swebench-results.json
#
# 环境变量:
#   MODEL_NAME       模型名称(需与 vLLM --served-model-name 一致)
#   BASE_URL         OpenAI 兼容端点 URL(带 /v1)
#   API_KEY          API key,默认 EMPTY
#   OUTPUT_BASE      结果输出根目录
#   DATASET          数据集(verified|lite|full|multimodal|multilingual),默认 verified
#   INFER_WORKERS    推理并发数,默认 2
#   EVAL_WORKERS     评测并发数,默认 2
#   TEMPERATURE      采样温度,默认 1.0
#   TOP_P            Top-p 核采样,默认 0.95
#   MAX_TOKENS       单次生成最大 token 数,默认 32768
#   EVAL_TIMEOUT     每个实例超时秒数,默认 3600
#   BUILD_LOCAL      true=本地构建镜像(Docker Hub 不可达时用),默认 false
#   SKIP_INSTALL      true=跳过安装步骤,默认 false
#   SKIP_BUILD        true=跳过镜像构建/拉取,默认 false
#   INFER_ONLY        true=仅运行推理,默认 false
#   EVAL_ONLY         true=仅运行评测,默认 false
#   INSTANCE_IDS      指定实例 ID(逗号分隔),默认空=全量
#   EXTRA_BODY        注入每个请求体的 JSON(max_tokens/temperature 等),留空则不注入
#   PROXY_URL         HTTP/HTTPS 代理地址(用于 git clone、HuggingFace、docker pull),留空则不使用

set -o pipefail

ROOT_PATH=$(cd "$(dirname "$0")"; pwd)
cd "${ROOT_PATH}"

# ---------- 从环境变量读取配置(带默认值)----------
MODEL_NAME="${MODEL_NAME:-glm-5.2}"
BASE_URL="${BASE_URL:-http://127.0.0.1:8080/v1}"
API_KEY="${API_KEY:-EMPTY}"
OUTPUT_BASE="${OUTPUT_BASE:-./output}"
DATASET="${DATASET:-verified}"
INFER_WORKERS="${INFER_WORKERS:-2}"
EVAL_WORKERS="${EVAL_WORKERS:-2}"
TEMPERATURE="${TEMPERATURE:-1.0}"
TOP_P="${TOP_P:-0.95}"
MAX_TOKENS="${MAX_TOKENS:-32768}"
EVAL_TIMEOUT="${EVAL_TIMEOUT:-3600}"
BUILD_LOCAL="${BUILD_LOCAL:-false}"
SKIP_INSTALL="${SKIP_INSTALL:-false}"
SKIP_BUILD="${SKIP_BUILD:-false}"
INFER_ONLY="${INFER_ONLY:-false}"
EVAL_ONLY="${EVAL_ONLY:-false}"
INSTANCE_IDS="${INSTANCE_IDS:-}"
EXTRA_BODY="${EXTRA_BODY:-}"
PROXY_URL="${PROXY_URL:-}"

# ---------- 派生路径 ----------
TASK_REPO_DIR="${ROOT_PATH}/swe-bench-tasks"
OUTPUT_DIR="${OUTPUT_BASE}/outputs"
LOGS_DIR="${OUTPUT_BASE}/logs"
MODEL_CONFIG="${OUTPUT_BASE}/model_config.yaml"
RESULTS_SUMMARY="${OUTPUT_BASE}/swebench-results.json"

# ---------- 日志文件 ----------
LOG_FILE="${OUTPUT_BASE}/swebench.log"
mkdir -p "${OUTPUT_BASE}" "${OUTPUT_DIR}" "${LOGS_DIR}"

# ---------- 依赖检查 ----------
if ! command -v uv >/dev/null 2>&1; then
    echo "ERROR: 未找到 uv, 请先安装: https://docs.astral.sh/uv/" | tee -a "$LOG_FILE"
    exit 1
fi

# ---------- 颜色输出(日志里无颜色,终端有) ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*" | tee -a "$LOG_FILE"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" | tee -a "$LOG_FILE"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"; }
log_step()  { echo -e "\n${BLUE}========== $* ==========${NC}" | tee -a "$LOG_FILE"; }

# ---------- Run ID ----------
RUN_ID_INFER="${MODEL_NAME}-$(date +%Y%m%d_%H%M%S)"
RUN_ID_EVAL="${MODEL_NAME}-eval-$(date +%Y%m%d_%H%M%S)"

# ---------- 解析 INSTANCE_IDS ----------
INSTANCE_ARGS=()
if [[ -n "$INSTANCE_IDS" ]]; then
    IFS=',' read -ra ID_ARRAY <<< "$INSTANCE_IDS"
    for id in "${ID_ARRAY[@]}"; do
        [[ -n "$id" ]] && INSTANCE_ARGS+=("-i" "$id")
    done
fi

# BASE_URL 确保带 /v1
BASE_URL="${BASE_URL%/}"
if [[ "$BASE_URL" != */v1 ]]; then
    BASE_URL="${BASE_URL}/v1"
fi
API_BASE="${BASE_URL}"

# ---------- 打印配置 ----------
{
    echo "========================================"
    echo "SWE-bench Test Start"
    echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "========================================"
    echo "Config:"
    echo "  MODEL_NAME       : $MODEL_NAME"
    echo "  BASE_URL         : $BASE_URL"
    echo "  API_KEY          : $API_KEY"
    echo "  DATASET          : $DATASET"
    echo "  INFER_WORKERS    : $INFER_WORKERS"
    echo "  EVAL_WORKERS     : $EVAL_WORKERS"
    echo "  TEMPERATURE      : $TEMPERATURE"
    echo "  TOP_P            : $TOP_P"
    echo "  MAX_TOKENS       : $MAX_TOKENS"
    echo "  EVAL_TIMEOUT     : ${EVAL_TIMEOUT}s"
    echo "  BUILD_LOCAL      : $BUILD_LOCAL"
    echo "  SKIP_INSTALL     : $SKIP_INSTALL"
    echo "  SKIP_BUILD       : $SKIP_BUILD"
    echo "  INFER_ONLY       : $INFER_ONLY"
    echo "  EVAL_ONLY        : $EVAL_ONLY"
    echo "  INSTANCE_IDS     : ${INSTANCE_IDS:-<none, full dataset>}"
    echo "  EXTRA_BODY       : ${EXTRA_BODY:-<none>}"
    echo "  PROXY_URL        : ${PROXY_URL:-<none>}"
    echo "  OUTPUT_BASE      : $OUTPUT_BASE"
    echo "  LOG_FILE         : $LOG_FILE"
    echo "  RESULTS_SUMMARY  : $RESULTS_SUMMARY"
    echo "========================================"
} | tee "$LOG_FILE"

# ---------- 设置代理(整个评测流程使用,包括 git clone、HuggingFace、docker pull)----------
if [[ -n "$PROXY_URL" ]]; then
    export http_proxy="$PROXY_URL"
    export https_proxy="$PROXY_URL"
    export HTTP_PROXY="$PROXY_URL"
    export HTTPS_PROXY="$PROXY_URL"
    log_info "代理已设置: $PROXY_URL"
else
    log_info "未设置代理"
fi

# 初始化结果 JSON(无论成功失败都写出,供 Jenkins 邮件解析)
write_results_json() {
    local resolved="$1"
    local total="$2"
    local score="$3"
    local status="$4"
    local run_id_eval="$5"
    local results_file="$6"
    cat > "$RESULTS_SUMMARY" <<ENDJSON
{
  "status": "$status",
  "model": "$MODEL_NAME",
  "dataset": "$DATASET",
  "run_id_infer": "$RUN_ID_INFER",
  "run_id_eval": "$run_id_eval",
  "resolved_instances": $resolved,
  "total_instances": $total,
  "score": "$score",
  "results_file": "$results_file"
}
ENDJSON
    echo "[results] Written to $RESULTS_SUMMARY" | tee -a "$LOG_FILE"
}

#==============================================================================
# Step 0: 环境检查
#==============================================================================
log_step "Step 0: 环境检查"

if ! command -v uv &>/dev/null; then
    log_error "uv 未安装！"
    write_results_json 0 0 "N/A" "failed: uv not found" "$RUN_ID_EVAL" ""
    exit 1
fi
log_info "uv 版本: $(uv --version)"

if ! command -v docker &>/dev/null; then
    log_error "Docker 未安装！"
    write_results_json 0 0 "N/A" "failed: docker not found" "$RUN_ID_EVAL" ""
    exit 1
fi
if ! docker info &>/dev/null; then
    log_error "Docker daemon 未运行！"
    write_results_json 0 0 "N/A" "failed: docker daemon not running" "$RUN_ID_EVAL" ""
    exit 1
fi
log_info "Docker 正常: $(docker --version)"

HAS_BUILDX=false
if docker buildx version &>/dev/null; then
    HAS_BUILDX=true
    log_info "Docker buildx 可用"
else
    log_warn "Docker buildx 不可用，将改为从 Docker Hub 拉取预构建镜像"
fi

log_info "检查 Python 环境..."
if ! timeout 30 uv python find &>/dev/null; then
    log_warn "uv 未找到可用 Python，尝试安装..."
    timeout 120 uv python install 3.12 || {
        log_error "无法安装 Python"
        write_results_json 0 0 "N/A" "failed: python not available" "$RUN_ID_EVAL" ""
        exit 1
    }
fi
log_info "探测 Python 版本（首次执行可能触发 uv sync，请耐心等待）..."
PY_VERSION=$(timeout 300 uv run python -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "0")
log_info "Python 版本: ${PY_VERSION}"
if [[ "$PY_VERSION" == "0" ]]; then
    log_error "无法运行 uv run python"
    write_results_json 0 0 "N/A" "failed: python cannot run" "$RUN_ID_EVAL" ""
    exit 1
fi

# API 可达性检查
log_info "检查模型 API (${API_BASE}/models) ..."
if curl -sf --max-time 10 "${API_BASE}/models" -H "Authorization: Bearer ${API_KEY}" >/dev/null 2>&1; then
    log_info "模型 API 可达"
else
    log_warn "无法连接到模型 API (${API_BASE}/models)"
    log_warn "继续执行（推理步骤会失败报错）..."
fi

# 磁盘空间检查
AVAILABLE_GB=$(df -BG "${ROOT_PATH}" 2>/dev/null | awk 'NR==2{print $4}' | tr -d 'G' || echo "0")
if [[ "$AVAILABLE_GB" -lt 120 ]] 2>/dev/null; then
    log_warn "可用磁盘空间约 ${AVAILABLE_GB}GB，建议至少 120GB（Docker 镜像较大）"
else
    log_info "可用磁盘空间: ${AVAILABLE_GB}GB"
fi

#==============================================================================
# Step 1: 安装依赖
#==============================================================================
if [[ "$SKIP_INSTALL" == "false" ]]; then
    log_step "Step 1: 安装依赖（uv sync）"
    uv lock --extra datasets 2>/dev/null || true
    uv sync --extra datasets || {
        log_error "uv sync 失败！尝试 --no-lockfile"
        uv sync --extra datasets --no-lockfile || {
            log_error "安装失败"
            write_results_json 0 0 "N/A" "failed: uv sync failed" "$RUN_ID_EVAL" ""
            exit 1
        }
    }
    log_info "验证安装..."
    uv run swebench --version 2>/dev/null || true
    uv run python -c "import minisweagent; print('mini-SWE-agent OK')" 2>/dev/null || log_warn "mini-SWE-agent 导入失败"
    uv run python -c "import litellm; assert hasattr(litellm, 'exceptions'), 'litellm 缺少 exceptions'; print('litellm OK')" 2>/dev/null || log_warn "litellm 版本可能不兼容"
else
    log_step "Step 1: 跳过安装（SKIP_INSTALL=true）"
fi

# 切换到输出目录 — swebench 的 logs/ 是相对 CWD 的硬编码路径
# (见 swebench/harness/constants/__init__.py:26-27)
# 必须在 OUTPUT_BASE 下执行，否则 logs/ 会写到 WORK_DIR 而非输出目录
cd "${OUTPUT_BASE}"
log_info "工作目录切换到: ${OUTPUT_BASE}"

#==============================================================================
# Step 2: 准备 Task Repo
#==============================================================================
log_step "Step 2: 准备 Task Repo"

if [[ -d "${TASK_REPO_DIR}" ]] && [[ -f "${TASK_REPO_DIR}/sweb.yaml" ]]; then
    log_info "Task Repo 已存在: ${TASK_REPO_DIR}"
    git -C "${TASK_REPO_DIR}" pull --ff-only || log_warn "Task Repo 更新失败，使用本地版本"
else
    log_info "克隆 Task Repo..."
    git clone --depth 1 https://github.com/SWE-bench/swe-bench-tasks.git "${TASK_REPO_DIR}" || {
        log_error "Task Repo 克隆失败"
        write_results_json 0 0 "N/A" "failed: task repo clone failed" "$RUN_ID_EVAL" ""
        exit 1
    }
fi

uv run swebench dataset check "${TASK_REPO_DIR}" --fix 2>&1 || true
log_info "Task Repo 校验完成"

#==============================================================================
# Step 3: 准备 Docker 镜像
#==============================================================================
IMAGES_SOURCE="missing"
if [[ "$SKIP_BUILD" == "false" ]] && [[ "$INFER_ONLY" == "false" ]]; then
    log_step "Step 3: 准备 Docker 镜像"

    if [[ -n "$INSTANCE_IDS" ]]; then
        # 指定实例：检查并构建/拉取
        IMAGES_READY=true
        IFS=',' read -ra ID_ARRAY <<< "$INSTANCE_IDS"
        for id in "${ID_ARRAY[@]}"; do
            ID_LOWER=$(echo "${id}" | tr '[:upper:]' '[:lower:]')
            ID_1776=$(echo "${id}" | sed 's/__/_1776_/g' | tr '[:upper:]' '[:lower:]')
            LOCAL_IMAGE="sweb.eval.x86_64.${ID_LOWER}:latest"
            HUB_IMAGE="swebench/sweb.eval.x86_64.${ID_1776}:latest"
            if docker images --format '{{.Repository}}:{{.Tag}}' | grep -q "^${LOCAL_IMAGE}$"; then
                log_info "镜像已存在(本地): ${LOCAL_IMAGE}"
                [[ "$IMAGES_SOURCE" == "missing" ]] && IMAGES_SOURCE="local"
            elif docker images --format '{{.Repository}}:{{.Tag}}' | grep -q "^${HUB_IMAGE}$"; then
                log_info "镜像已存在(Docker Hub): ${HUB_IMAGE}"
                [[ "$IMAGES_SOURCE" == "missing" ]] && IMAGES_SOURCE="hub"
            else
                IMAGES_READY=false
            fi
        done

        if [[ "$IMAGES_READY" == "false" ]] && [[ "$HAS_BUILDX" == "true" ]]; then
            log_info "从 Task Repo 构建 Docker 镜像..."
            BUILD_ARGS=()
            for id in "${ID_ARRAY[@]}"; do
                BUILD_ARGS+=("-i" "$id")
            done
            uv run swebench images build "${TASK_REPO_DIR}" -j "${EVAL_WORKERS}" "${BUILD_ARGS[@]}"
            IMAGES_SOURCE="local"
            for id in "${ID_ARRAY[@]}"; do
                ID_LOWER=$(echo "${id}" | tr '[:upper:]' '[:lower:]')
                LOCAL_IMAGE="sweb.eval.x86_64.${ID_LOWER}:latest"
                if ! docker images --format '{{.Repository}}:{{.Tag}}' | grep -q "^${LOCAL_IMAGE}$"; then
                    log_warn "本地构建失败: ${LOCAL_IMAGE}"
                fi
            done
        fi
    else
        # 全量评测
        if [[ "$BUILD_LOCAL" == "true" ]] && [[ "$HAS_BUILDX" == "true" ]]; then
            log_info "全量评测 + BUILD_LOCAL：Step 6 将用 --task-repo 本地构建镜像"
            IMAGES_SOURCE="local"
        else
            log_info "全量评测：评测时从 Docker Hub 按需拉取镜像"
            IMAGES_SOURCE="hub"
        fi
    fi
else
    log_step "Step 3: 跳过镜像准备"
fi

#==============================================================================
# Step 4: 生成模型配置
#==============================================================================
log_step "Step 4: 生成模型配置"

# 如果提供了 EXTRA_BODY, 解析 JSON 并生成正确的 YAML 嵌套块
EXTRA_BODY_SECTION=""
if [[ -n "$EXTRA_BODY" ]]; then
    EXTRA_BODY_SECTION=$(uv run python -c "
import json
try:
    d = json.loads('''$EXTRA_BODY''')
    lines = ['  extra_body:']
    for k, v in d.items():
        lines.append(f'    {k}: {v}')
    print('\n'.join(lines))
except:
    pass
" 2>/dev/null || echo "")
fi

cat > "${MODEL_CONFIG}" <<EOF
# mini-SWE-agent 模型配置（自动生成 - Jenkins）
model:
  api_base: ${API_BASE}
  api_key: ${API_KEY}
  temperature: ${TEMPERATURE}
  top_p: ${TOP_P}
  max_tokens: ${MAX_TOKENS}
${EXTRA_BODY_SECTION}
cost_tracking: ignore_errors
EOF

log_info "模型配置已写入: ${MODEL_CONFIG}"
cat "${MODEL_CONFIG}" | tee -a "$LOG_FILE"

export OPENAI_API_KEY="${API_KEY}"
export OPENAI_BASE_URL="${API_BASE}"
export MSWEA_COST_TRACKING='ignore_errors'

#==============================================================================
# Step 5: 推理
#==============================================================================
PRED_FILE="${OUTPUT_DIR}/preds.jsonl"

if [[ "$EVAL_ONLY" == "false" ]]; then
    log_step "Step 5: 推理（mini-SWE-agent 调用模型）"

    if [[ -f "${OUTPUT_DIR}/preds.json" ]] || [[ -f "${OUTPUT_DIR}/preds.jsonl" ]]; then
        log_warn "发现上次的预测文件，备份后清理"
        BACKUP_DIR="${OUTPUT_DIR}/backup_$(date +%Y%m%d_%H%M%S)"
        mkdir -p "${BACKUP_DIR}"
        cp "${OUTPUT_DIR}"/preds.json* "${BACKUP_DIR}/" 2>/dev/null || true
        rm -f "${OUTPUT_DIR}/preds.json" "${OUTPUT_DIR}/preds.jsonl"
    fi

    log_info "数据集: ${DATASET}"
    log_info "模型 API: ${API_BASE}"
    log_info "模型名: ${MODEL_NAME}"
    log_info "推理并发: ${INFER_WORKERS}"
    log_info "Run ID: ${RUN_ID_INFER}"
    log_info "输出目录: ${OUTPUT_DIR}"

    EXTRA_ARGS=()
    if [[ -n "$INSTANCE_IDS" ]]; then
        IFS=',' read -ra ID_ARRAY <<< "$INSTANCE_IDS"
        FILTER_PATTERN=$(IFS='|'; echo "${ID_ARRAY[*]}")
        EXTRA_ARGS+=("--" "--filter" "${FILTER_PATTERN}")
    fi

    uv run swebench infer "${DATASET}" \
        -m "openai/${MODEL_NAME}" \
        -c "${MODEL_CONFIG}" \
        --run-id "${RUN_ID_INFER}" \
        -w "${INFER_WORKERS}" \
        -o "${OUTPUT_DIR}" \
        "${EXTRA_ARGS[@]}" 2>&1 | tee -a "$LOG_FILE" || {
            log_error "推理失败！"
            write_results_json 0 0 "N/A" "failed: inference failed" "$RUN_ID_EVAL" ""
            exit 1
        }

    log_info "推理完成！"

    if [[ -f "${OUTPUT_DIR}/preds.json" ]]; then
        PRED_FILE="${OUTPUT_DIR}/preds.json"
    elif [[ -f "${OUTPUT_DIR}/preds.jsonl" ]]; then
        PRED_FILE="${OUTPUT_DIR}/preds.jsonl"
    fi

    if [[ ! -f "${PRED_FILE}" ]] || [[ ! -s "${PRED_FILE}" ]]; then
        log_error "推理未生成有效预测文件！"
        write_results_json 0 0 "N/A" "failed: no predictions" "$RUN_ID_EVAL" ""
        exit 1
    fi

    PRED_COUNT=$(wc -l < "${PRED_FILE}" 2>/dev/null || echo "0")
    log_info "生成预测数量: ${PRED_COUNT} 条"
else
    log_step "Step 5: 跳过推理（EVAL_ONLY=true）"
    if [[ ! -f "${PRED_FILE}" ]]; then
        log_error "预测文件不存在: ${PRED_FILE}"
        write_results_json 0 0 "N/A" "failed: no prediction file" "$RUN_ID_EVAL" ""
        exit 1
    fi
fi

#==============================================================================
# Step 6: 评测
#==============================================================================
if [[ "$INFER_ONLY" == "true" ]]; then
    log_step "Step 6: 跳过评测（INFER_ONLY=true）"
    write_results_json 0 0 "N/A" "inference_only" "$RUN_ID_EVAL" ""
    exit 0
fi

log_step "Step 6: 评测（Docker 容器中运行测试）"

log_info "预测文件: ${PRED_FILE}"
log_info "数据集: ${DATASET}"
log_info "评测并发: ${EVAL_WORKERS}"
log_info "超时: ${EVAL_TIMEOUT}s / 实例"
log_info "Run ID: ${RUN_ID_EVAL}"

EVAL_TASK_REPO_ARGS=()
if [[ "$IMAGES_SOURCE" == "local" ]]; then
    log_info "Task Repo: ${TASK_REPO_DIR}（本地构建，传 --task-repo）"
    EVAL_TASK_REPO_ARGS+=(--task-repo "${TASK_REPO_DIR}")
else
    log_info "镜像来源: ${IMAGES_SOURCE}（不传 --task-repo）"
fi

uv run swebench eval "${DATASET}" \
    -p "${PRED_FILE}" \
    --run-id "${RUN_ID_EVAL}" \
    -j "${EVAL_WORKERS}" \
    -t "${EVAL_TIMEOUT}" \
    "${EVAL_TASK_REPO_ARGS[@]}" \
    "${INSTANCE_ARGS[@]}" 2>&1 | tee -a "$LOG_FILE" || {
        log_error "评测失败！"
        write_results_json 0 0 "N/A" "failed: evaluation failed" "$RUN_ID_EVAL" ""
        exit 1
    }

#==============================================================================
# Step 7: 输出结果
#==============================================================================
log_step "Step 7: 评测结果"

RESULTS_FILE="${OUTPUT_BASE}/logs/evaluation/${RUN_ID_EVAL}/results.json"

if [[ -f "${RESULTS_FILE}" ]]; then
    log_info "结果文件: ${RESULTS_FILE}"
    echo "----------------------------------------" | tee -a "$LOG_FILE"
    uv run python -m json.tool "${RESULTS_FILE}" 2>/dev/null | tee -a "$LOG_FILE" || cat "${RESULTS_FILE}" | tee -a "$LOG_FILE"
    echo "----------------------------------------" | tee -a "$LOG_FILE"

    RESOLVED=$(uv run python -c "import json; print(json.load(open('${RESULTS_FILE}')).get('resolved_instances', 0))" 2>/dev/null || echo "0")
    TOTAL=$(uv run python -c "import json; print(json.load(open('${RESULTS_FILE}')).get('total_instances', 0))" 2>/dev/null || echo "0")
    if [[ -n "$RESOLVED" ]] && [[ -n "$TOTAL" ]] && [[ "$TOTAL" -gt 0 ]] 2>/dev/null; then
        SCORE=$(uv run python -c "print(f'{$RESOLVED/$TOTAL*100:.1f}')" 2>/dev/null || echo "N/A")
        echo "" | tee -a "$LOG_FILE"
        log_info "==========================================" | tee -a "$LOG_FILE"
        log_info "  得分: ${RESOLVED}/${TOTAL} = ${SCORE}%" | tee -a "$LOG_FILE"
        log_info "==========================================" | tee -a "$LOG_FILE"
        write_results_json "$RESOLVED" "$TOTAL" "${SCORE}%" "completed" "$RUN_ID_EVAL" "${RESULTS_FILE}"
    else
        write_results_json 0 0 "N/A" "completed: no score" "$RUN_ID_EVAL" "${RESULTS_FILE}"
    fi
else
    log_warn "结果文件未找到: ${RESULTS_FILE}"
    log_info "请手动查看 ${OUTPUT_BASE}/logs/evaluation/${RUN_ID_EVAL}/ 目录"
    write_results_json 0 0 "N/A" "completed: results file not found" "$RUN_ID_EVAL" "${RESULTS_FILE}"
fi

echo "" | tee -a "$LOG_FILE"
log_info "评测完成！" | tee -a "$LOG_FILE"
log_info "  推理输出: ${OUTPUT_DIR}/" | tee -a "$LOG_FILE"
log_info "  评测日志: ${OUTPUT_BASE}/logs/evaluation/${RUN_ID_EVAL}/" | tee -a "$LOG_FILE"
log_info "  汇总结果: ${RESULTS_FILE}" | tee -a "$LOG_FILE"
log_info "  结果摘要: ${RESULTS_SUMMARY}" | tee -a "$LOG_FILE"
echo "========================================" | tee -a "$LOG_FILE"
echo "SWE-bench Test Complete" | tee -a "$LOG_FILE"
echo "Time: $(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$LOG_FILE"
echo "========================================" | tee -a "$LOG_FILE"
