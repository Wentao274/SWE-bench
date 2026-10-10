pipeline {
    agent {
        label 'slave-2'
    }
    parameters {
        string(name: 'TESTER', defaultValue: 'liwt', description: '测试人员名称(必填)')
        string(name: 'CHIP', defaultValue: 'nvidia-h100', description: '芯片平台名称(必填)')
        choice(name: 'ENGINE', choices: ['vllm', 'sglang'], description: '推理框架(必填)')
        choice(name: 'PD', choices: ['agg', 'disagg'], description: 'PD分离模式(agg=非PD分离,disagg=PD分离)')
        string(name: 'MODEL', defaultValue: 'glm-5.2', description: '模型服务名称(必填,需与 vLLM --served-model-name 一致)')
        string(name: 'BASE_URL', defaultValue: 'http://10.201.149.47:8080', description: 'OpenAI 兼容端点根 URL(必填,不带 /v1 后缀,流水线会自动拼接)')
        password(name: 'API_KEY', defaultValue: '', description: 'API Key(可选,无需认证时留空,默认 EMPTY)')

        // 数据集选择
        choice(name: 'DATASET', choices: ['verified', 'lite', 'full', 'multimodal', 'multilingual'], description: '数据集(verified=500实例,lite=300实例,full=2294实例)')
        string(name: 'INSTANCE_IDS', defaultValue: '', description: '指定实例 ID(逗号分隔,如 sympy__sympy-20590,django__django-12345);留空=全量评测')

        // 采样参数
        string(name: 'TEMPERATURE', defaultValue: '1.0', description: '采样温度(默认 1.0)')
        string(name: 'TOP_P', defaultValue: '0.95', description: 'Top-p 核采样(默认 0.95)')
        string(name: 'MAX_TOKENS', defaultValue: '32768', description: '单次生成最大 token 数(默认 32768)')

        // 并发与超时
        string(name: 'INFER_WORKERS', defaultValue: '2', description: '推理并发数(取决于 GPU 显存和吞吐)')
        string(name: 'EVAL_WORKERS', defaultValue: '2', description: '评测并发数(建议 <= 0.75 * CPU 核数)')
        string(name: 'EVAL_TIMEOUT', defaultValue: '3600', description: '每个实例超时秒数(默认 3600)')

        // 镜像与流程控制
        booleanParam(name: 'BUILD_LOCAL', defaultValue: false, description: '镜像不存在时本地构建(Docker Hub 不可达且镜像未预拉取时使用);镜像已存在时勾选无效(不会删除已有镜像)')
        booleanParam(name: 'SKIP_INSTALL', defaultValue: false, description: '跳过 uv sync 安装步骤(已安装过时使用)')
        booleanParam(name: 'SKIP_BUILD', defaultValue: false, description: '跳过 Docker 镜像构建/拉取(已有镜像时使用)')
        booleanParam(name: 'INFER_ONLY', defaultValue: false, description: '仅运行推理,不评测')
        booleanParam(name: 'EVAL_ONLY', defaultValue: false, description: '仅运行评测(需已有预测文件)')

        text(name: 'EXTRA_BODY', defaultValue: '', description: '注入每个请求体的 JSON(max_tokens/temperature 等);留空则不注入')

        string(name: 'PROXY', defaultValue: 'http://10.201.136.68:1080', description: 'HTTP/HTTPS 代理地址(用于 git clone、HuggingFace 数据集下载、docker pull 等);留空则不使用代理')

        string(name: 'DESCRIPTION', defaultValue: '', description: '模型服务描述信息(仅用于邮件展示)')
        text(name: 'RECIPIENTS', defaultValue: 'liwt@zetyun.com', description: '报告邮件接收者(逗号分隔)')
        string(name: 'WORK_DIR', defaultValue: '/dingofs/data2/userdata/liwt/maas-image/SWE-bench', description: '远程仓库目录,请不要改动')
    }
    environment {
        SSH_CREDENTIALS = 'HOST_SSH_KEY'
        REMOTE_HOST = '10.201.132.50'
        REMOTE_USER = 'root'
        // 用户在 BASE_URL 填根地址(可不带或带 /v1,可带或不带尾斜杠)。
        // 这里 idempotent 拼接出唯一的 OpenAI 兼容端点:
        //   先剥尾斜杠 → 再剥结尾 /v1(若有)→ 统一补 /v1
        BASE_URL_V1 = "${params.BASE_URL.replaceAll('/+$', '').replaceAll('/?v1$', '')}/v1"
    }

    stages {
        stage('打印测试参数') {
            steps {
                script {
                    println("========================================")
                    println("=== SWE-bench Verified 测试参数信息 ===")
                    println("========================================")
                    println("测试人员:        ${params.TESTER}")
                    println("芯片平台:        ${params.CHIP}")
                    println("推理框架:        ${params.ENGINE}")
                    println("PD分离模式:      ${params.PD}")
                    println("模型名称:        ${params.MODEL}")
                    println("BASE_URL:        ${params.BASE_URL}  (→ ${env.BASE_URL_V1})")
                    println("API_KEY:         ${params.API_KEY ? '******' : '(空, 默认 EMPTY)'}")
                    println("数据集:          ${params.DATASET}")
                    println("指定实例:        ${params.INSTANCE_IDS ?: '无(全量评测)'}")
                    println("采样温度:        ${params.TEMPERATURE}")
                    println("Top-p:           ${params.TOP_P}")
                    println("Max tokens:      ${params.MAX_TOKENS}")
                    println("推理并发:        ${params.INFER_WORKERS}")
                    println("评测并发:        ${params.EVAL_WORKERS}")
                    println("评测超时:        ${params.EVAL_TIMEOUT}s / 实例")
                    println("本地构建镜像:    ${params.BUILD_LOCAL}")
                    println("跳过安装:        ${params.SKIP_INSTALL}")
                    println("跳过镜像构建:    ${params.SKIP_BUILD}")
                    println("仅推理:          ${params.INFER_ONLY}")
                    println("仅评测:          ${params.EVAL_ONLY}")
                    println("extra_body:      ${params.EXTRA_BODY ?: '不注入'}")
                    println("代理地址:        ${params.PROXY ?: '不使用代理'}")
                    println("模型描述:        ${params.DESCRIPTION}")
                    println("邮件接收者:      ${params.RECIPIENTS}")
                    println("工作目录:        ${params.WORK_DIR}")
                    println("构建编号:        #${BUILD_NUMBER}")
                    println("========================================")
                }
            }
        }

        stage('API 连通性预检') {
            steps {
                sshagent(credentials: ["${SSH_CREDENTIALS}"]) {
                    script {
                        try {
                            sh """
ssh -o StrictHostKeyChecking=no ${REMOTE_USER}@${REMOTE_HOST} << 'ENDSSH'
set -o pipefail
{
    echo "=== 检查 API 连通性 (/v1/models) ==="
    HTTP_CODE=\$(curl -s --connect-timeout 10 -m 30 -o /dev/null -w "%{http_code}" ${env.BASE_URL_V1}/models)
    if [ "\${HTTP_CODE}" != "200" ]; then
        echo "ERROR: API 连通性检查失败, HTTP状态码: \${HTTP_CODE}, URL: ${env.BASE_URL_V1}/models"
        exit 1
    fi
    echo "API /models 连通性检查通过, HTTP状态码: \${HTTP_CODE}"

    echo "=== 检查 Chat Completions 接口 ==="
    CHAT_RESP=\$(curl -s --connect-timeout 10 -m 60 -w "\\n%{http_code}" ${env.BASE_URL_V1}/chat/completions \\
        -H "Content-Type: application/json" \\
        -d '{"model":"${params.MODEL}","messages":[{"role":"user","content":"hello"}],"max_tokens":10}')
    CHAT_HTTP_CODE=\$(echo "\${CHAT_RESP}" | tail -1)
    if [ "\${CHAT_HTTP_CODE}" != "200" ]; then
        echo "ERROR: Chat Completions 接口检查失败, HTTP状态码: \${CHAT_HTTP_CODE}"
        echo "响应内容: \$(echo "\${CHAT_RESP}" | head -n -1)"
        exit 1
    fi
    echo "Chat Completions 接口检查通过, HTTP状态码: \${CHAT_HTTP_CODE}"
} 2>&1 | tee /tmp/swebench_connectivity_${BUILD_NUMBER}.log
ENDSSH
"""
                        } catch (Exception e) {
                            env.CONNECTIVITY_FAILED = 'true'
                            currentBuild.result = 'UNSTABLE'
                            println("=== API 连通性预检失败,后续阶段(环境检查、运行测试)将跳过 ===")
                        }
                    }
                }
            }
        }

        stage('环境检查') {
            when {
                expression { env.CONNECTIVITY_FAILED != 'true' }
            }
            steps {
                sshagent(credentials: ["${SSH_CREDENTIALS}"]) {
                    sh """
ssh -o StrictHostKeyChecking=no ${REMOTE_USER}@${REMOTE_HOST} << 'ENDSSH'
set -e
cd ${params.WORK_DIR}
echo "工作目录: \$(pwd)"
ls -la

echo "=== 清理残留进程 (swebench / run_swebench_main) ==="
RESIDUAL=\$(pgrep -af "swebench|run_swebench_main|mini_swe_agent|minisweagent" 2>/dev/null | grep -vE "jenkins|durable|@tmp" || true)
if [ -n "\${RESIDUAL}" ]; then
    echo "发现残留进程:"
    echo "\${RESIDUAL}"
    echo "发送 SIGTERM..."
    echo "\${RESIDUAL}" | awk '{print \$1}' | xargs -r kill -TERM 2>/dev/null || true
    sleep 3
    REMAINING=\$(pgrep -af "swebench|run_swebench_main|mini_swe_agent|minisweagent" 2>/dev/null | grep -vE "jenkins|durable|@tmp" || true)
    if [ -n "\${REMAINING}" ]; then
        echo "残留进程未响应 SIGTERM,发送 SIGKILL..."
        echo "\${REMAINING}" | awk '{print \$1}' | xargs -r kill -KILL 2>/dev/null || true
        sleep 1
    fi
    FINAL=\$(pgrep -af "swebench|run_swebench_main|mini_swe_agent|minisweagent" 2>/dev/null | grep -vE "jenkins|durable|@tmp" || true)
    if [ -n "\${FINAL}" ]; then
        echo "WARN: 以下残留进程仍存在,需人工介入:"
        echo "\${FINAL}"
    else
        echo "残留进程清理完成"
    fi
else
    echo "未发现残留进程"
fi

echo "=== 清理残留 Docker 容器 ==="
# 清理 SWE-bench 评测容器(名称含 sweb.eval)
LEFTOVER_CONTAINERS=\$(docker ps -a --filter "name=sweb.eval" --format '{{.ID}}' 2>/dev/null || true)
if [ -n "\${LEFTOVER_CONTAINERS}" ]; then
    echo "发现残留评测容器,清理中..."
    docker rm -f \${LEFTOVER_CONTAINERS} 2>/dev/null || true
    echo "残留容器清理完成"
else
    echo "未发现残留评测容器"
fi

echo "=== 设置权限 ==="
chmod +x run_swebench.sh
chmod +x run_swebench_main.py

echo "=== 检查并同步 uv 环境 ==="
PROXY_VAL="${params.PROXY}"
if [ ! -d "${params.WORK_DIR}/.venv" ]; then
    if [ -n "\${PROXY_VAL}" ]; then
        export https_proxy="\${PROXY_VAL}"
        export http_proxy="\${PROXY_VAL}"
        echo "首次运行,使用代理 \${PROXY_VAL} 执行 uv sync..."
    else
        echo "首次运行,无代理执行 uv sync..."
    fi
    cd ${params.WORK_DIR}
    uv sync --extra datasets
    unset https_proxy http_proxy 2>/dev/null || true
else
    echo ".venv 已存在,执行 uv sync(增量更新依赖)..."
    cd ${params.WORK_DIR}
    if [ -n "\${PROXY_VAL}" ]; then
        export https_proxy="\${PROXY_VAL}"
        export http_proxy="\${PROXY_VAL}"
    fi
    uv sync --extra datasets
    unset https_proxy http_proxy 2>/dev/null || true
fi

cd ${params.WORK_DIR}
echo "=== uv 环境信息 ==="
uv run python --version
echo "=== Docker 环境信息 ==="
docker --version
docker info --format 'Storage Driver: {{.Driver}}, Containers: {{.Containers}}, Images: {{.Images}}' 2>/dev/null || true
echo "=== 磁盘空间 ==="
df -h ${params.WORK_DIR}
echo "=== 环境准备完成 ==="
ENDSSH
"""
                }
            }
        }

        stage('运行SWE-bench测试') {
            when {
                expression { env.CONNECTIVITY_FAILED != 'true' }
            }
            steps {
                script {
                    def modelDir = params.MODEL.contains("/") ? params.MODEL.split("/").last() : params.MODEL
                    env.MODEL_DIR = modelDir

                    env.API_KEY_STR = params.API_KEY?.toString() ?: ''

                    def extraBodyArg = params.EXTRA_BODY?.trim() ? "--extra-body '${params.EXTRA_BODY}'" : ''

                    sshagent(credentials: ["${SSH_CREDENTIALS}"]) {
                        catchError(buildResult: 'UNSTABLE', stageResult: 'FAILURE') {
                            sh """
ssh -o StrictHostKeyChecking=no ${REMOTE_USER}@${REMOTE_HOST} << ENDSSH
set -e
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
cd ${params.WORK_DIR}
source .venv/bin/activate
echo "=== 执行 SWE-bench 测试脚本 ==="
python3 run_swebench_main.py \\
    --tester ${params.TESTER} \\
    --build-number ${BUILD_NUMBER} \\
    --chip ${params.CHIP} \\
    --model ${params.MODEL} \\
    --base-url ${env.BASE_URL_V1} \\
    --api-key "${env.API_KEY_STR ?: 'EMPTY'}" \\
    --dataset ${params.DATASET} \\
    --infer-workers ${params.INFER_WORKERS} \\
    --eval-workers ${params.EVAL_WORKERS} \\
    --temperature ${params.TEMPERATURE} \\
    --top-p ${params.TOP_P} \\
    --max-tokens ${params.MAX_TOKENS} \\
    --eval-timeout ${params.EVAL_TIMEOUT} \\
    ${params.BUILD_LOCAL ? '--build-local' : ''} \\
    ${params.SKIP_INSTALL ? '--skip-install' : ''} \\
    ${params.SKIP_BUILD ? '--skip-build' : ''} \\
    ${params.INFER_ONLY ? '--infer-only' : ''} \\
    ${params.EVAL_ONLY ? '--eval-only' : ''} \\
    ${params.INSTANCE_IDS ? "--instance-ids ${params.INSTANCE_IDS}" : ''} \\
    ${extraBodyArg} \\
    ${params.PROXY ? "--proxy ${params.PROXY}" : ''} \\
    --description "${params.DESCRIPTION}"
echo "=== 测试脚本执行结束 ==="
echo "=== 输出目录 ==="
find jenkins_output/${params.TESTER}/${BUILD_NUMBER}/${params.CHIP}/${env.MODEL_DIR}/ -type f 2>/dev/null || echo "无输出文件"
ENDSSH
"""
                        }
                    }
                }
            }
        }

        stage('拉取测试结果') {
            steps {
                sshagent(credentials: ["${SSH_CREDENTIALS}"]) {
                    catchError(buildResult: 'UNSTABLE', stageResult: 'FAILURE') {
                        script {
                            def remoteDir = "${params.WORK_DIR}/jenkins_output/${params.TESTER}/${BUILD_NUMBER}/${params.CHIP}/${env.MODEL_DIR}"
                            def localDir = "reports/${params.TESTER}/${BUILD_NUMBER}/${params.CHIP}"
                            def localBuildsDir = "builds/${BUILD_NUMBER}"
                            env.RESULT_DIR = "jenkins_output/${params.TESTER}/${BUILD_NUMBER}/${params.CHIP}/${env.MODEL_DIR}"
                            echo "拉取测试结果目录: ${remoteDir}"

                            if (env.CONNECTIVITY_FAILED == 'true') {
                                echo "=== 连通性检查未通过,跳过测试结果目录拉取,仅拉取连通性预检日志 ==="
                            } else {
                                sh """
mkdir -p ${localDir}
# 先尝试拉取整个目录
scp -o StrictHostKeyChecking=no \
    -r ${REMOTE_USER}@${REMOTE_HOST}:${remoteDir} \
    ${localDir}/ 2>/dev/null || echo "WARN: 完整目录拉取失败,尝试分文件拉取"

echo "=== 拉取结果 ==="
find ${localDir}/ -type f 2>/dev/null | head -50 || echo "未找到结果文件"
"""
                            }

                            sh """
mkdir -p ${localBuildsDir}
scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    ${REMOTE_USER}@${REMOTE_HOST}:/tmp/swebench_connectivity_${BUILD_NUMBER}.log \
    ./${localBuildsDir}/swebench_connectivity_${BUILD_NUMBER}.log 2>/dev/null \
    && echo "连通性预检日志已拉取: ${localBuildsDir}/swebench_connectivity_${BUILD_NUMBER}.log" \
    || echo "WARN: 连通性预检日志拉取失败"
"""
                        }
                    }
                }
            }
        }

        stage('发送邮件') {
            steps {
                catchError(buildResult: 'UNSTABLE', stageResult: 'FAILURE') {
                    script {
                        def logFileBase = "reports/${params.TESTER}/${BUILD_NUMBER}/${params.CHIP}/${env.MODEL_DIR}"

                        // 找到 swebench.log
                        def logFiles = findFiles(glob: "${logFileBase}/**/swebench.log")
                        def logFile = ""
                        def logContent = ""
                        if (logFiles.length > 0) {
                            logFile = logFiles[0].path
                            logContent = readFile(logFile)
                        }

                        // 连通性预检失败检测
                        def connectivityLogPath = "builds/${BUILD_NUMBER}/swebench_connectivity_${BUILD_NUMBER}.log"
                        def connectivityLogContent = ""
                        def failureReason = ""
                        def connectivityFailureReason = ""
                        if (fileExists(connectivityLogPath)) {
                            connectivityLogContent = readFile(connectivityLogPath)
                            if (connectivityLogContent.contains("API 连通性检查失败") ||
                                connectivityLogContent.contains("Chat Completions 接口检查失败")) {
                                failureReason = "连通性检查未通过"
                                def logLines = connectivityLogContent.split('\n')
                                def collected = []
                                def inFailureSection = false
                                for (def ll : logLines) {
                                    if (ll.contains("检查 API 连通性") || ll.contains("Chat Completions 接口检查")) {
                                        inFailureSection = true
                                    }
                                    if (inFailureSection) {
                                        if (!collected.isEmpty() && ll.trim().startsWith("===") &&
                                            !ll.contains("检查 API 连通性") && !ll.contains("Chat Completions 接口检查")) {
                                            break
                                        }
                                        collected.add(ll)
                                    }
                                }
                                connectivityFailureReason = collected.join('\n').trim()
                            }
                        }
                        if (!failureReason && env.CONNECTIVITY_FAILED == 'true') {
                            failureReason = "连通性检查未通过"
                            connectivityFailureReason = "API 连通性或 Chat Completions 接口检查失败,具体日志未拉到,详见 Jenkins 控制台输出。"
                        }

                        // 从 swebench-results.json 提取测试结果
                        def resultJsonPath = ""
                        def resultJson = null
                        def resolvedCount = 0
                        def totalCount = 0
                        def scorePct = "N/A"
                        def evalStatus = "N/A"
                        def resultsFilePath = "N/A"

                        if (!failureReason) {
                            def resultFiles = findFiles(glob: "${logFileBase}/**/swebench-results.json")
                            if (resultFiles.length > 0) {
                                resultJsonPath = resultFiles[0].path
                                try {
                                    resultJson = readJSON(file: resultJsonPath)
                                    resolvedCount = resultJson.resolved_instances ?: 0
                                    totalCount = resultJson.total_instances ?: 0
                                    scorePct = resultJson.score ?: "N/A"
                                    evalStatus = resultJson.status ?: "N/A"
                                    resultsFilePath = resultJson.results_file ?: "N/A"
                                } catch (Exception e) {
                                    println("WARN: 解析 swebench-results.json 失败: ${e.getMessage()}")
                                }
                            }
                        }

                        def hasResult = resultJson != null
                        def resultStatus = hasResult ? evalStatus : "失败/无结果"
                        if (failureReason) {
                            resultStatus = "失败/${failureReason}"
                        }

                        // 从日志中提取仓库级得分(如果日志中有)
                        def repoScoresHtml = ""
                        if (logContent) {
                            def repoScoreLines = []
                            def inRepoSection = false
                            for (def ll : logContent.split('\n')) {
                                if (ll.contains("得分:") && ll.contains("/")) {
                                    inRepoSection = true
                                }
                            }
                        }

                        // 连通性失败 HTML 块
                        def connectivityFailureHtml = ""
                        if (failureReason) {
                            def escapedReason = (connectivityFailureReason ?: '')
                                .replace('&', '&amp;')
                                .replace('<', '&lt;')
                                .replace('>', '&gt;')
                            connectivityFailureHtml = """
            <div style="background-color: #ffebee; color: #000000; border-left: 4px solid #d32f2f; padding: 12px 15px; margin-top: 15px; border-radius: 3px;">
                <h3 style="color: #d32f2f; margin-top: 0; margin-bottom: 8px;">⚠️ 连通性检查未通过</h3>
                <p style="margin-top: 0; margin-bottom: 8px; color: #000000;">本次测试未能正常执行用例,原因是 API 连通性检查失败:</p>
                <pre style="background-color: #ffffff; color: #000000; padding: 10px; border-radius: 3px; overflow-x: auto; white-space: pre-wrap; margin: 0; font-family: Menlo, Consolas, monospace; font-size: 12px;">${escapedReason}</pre>
            </div>"""
                        }

                        def scoreClass = ""
                        if (scorePct != "N/A") {
                            try {
                                def scoreNum = scorePct.replaceAll("[^0-9.]", "").toDouble()
                                if (scoreNum >= 70) scoreClass = "score-high"
                                else if (scoreNum >= 40) scoreClass = "score-mid"
                                else scoreClass = "score-low"
                            } catch (Exception e) {}
                        }

                        def emailBody = """
<html>
<head>
    <style>
        body { font-family: Arial, sans-serif; margin: 0; padding: 20px; background-color: #f5f5f5; }
        .container { max-width: 1200px; margin: 0 auto; background-color: #fff; border-radius: 5px; box-shadow: 0 2px 5px rgba(0,0,0,0.1); }
        .header { background-color: ${hasResult ? '#4CAF50' : '#f44336'}; color: white; padding: 20px; border-radius: 5px 5px 0 0; }
        .content { padding: 20px; }
        table { border-collapse: collapse; width: 100%; margin-top: 15px; font-size: 13px; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        th { background-color: #f2f2f2; }
        .footer { margin-top: 20px; padding: 15px; background-color: #f9f9f9; border-radius: 0 0 5px 5px; color: #666; font-size: 12px; }
        .section-title { background-color: #e3f2fd; padding: 10px; margin-top: 20px; border-radius: 3px; font-weight: bold; }
        .score-highlight { background-color: #c8e6c9; font-weight: bold; }
        .score-high { color: #2e7d32; font-weight: bold; font-size: 16px; }
        .score-mid { color: #f57f17; font-weight: bold; font-size: 16px; }
        .score-low { color: #c62828; font-weight: bold; font-size: 16px; }
        .pass { color: #2e7d32; font-weight: bold; }
        .fail { color: #c62828; font-weight: bold; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h2 style="margin: 0;">SWE-bench Verified 评测报告 - 构建 #${BUILD_NUMBER}</h2>
        </div>
        <div class="content">
            <h3>测试概要</h3>
            <table>
                <tr><th>项目</th><td>值</td></tr>
                <tr><th>构建编号</th><td>#${BUILD_NUMBER}</td></tr>
                <tr><th>模型服务描述</th><td>${params.DESCRIPTION}</td></tr>
                <tr><th>测试人员</th><td>${params.TESTER}</td></tr>
                <tr><th>芯片平台</th><td>${params.CHIP}</td></tr>
                <tr><th>推理框架</th><td>${params.ENGINE}</td></tr>
                <tr><th>PD分离模式</th><td>${params.PD}</td></tr>
                <tr><th>模型名称</th><td>${params.MODEL}</td></tr>
                <tr><th>API地址</th><td>${params.BASE_URL}  (→ ${env.BASE_URL_V1})</td></tr>
                <tr><th>数据集</th><td>${params.DATASET}</td></tr>
                <tr><th>指定实例</th><td>${params.INSTANCE_IDS ?: '无(全量评测)'}</td></tr>
                <tr><th>采样温度</th><td>${params.TEMPERATURE}</td></tr>
                <tr><th>Top-p</th><td>${params.TOP_P}</td></tr>
                <tr><th>Max tokens</th><td>${params.MAX_TOKENS}</td></tr>
                <tr><th>推理并发</th><td>${params.INFER_WORKERS}</td></tr>
                <tr><th>评测并发</th><td>${params.EVAL_WORKERS}</td></tr>
                <tr><th>评测超时</th><td>${params.EVAL_TIMEOUT}s / 实例</td></tr>
                <tr><th>本地构建镜像</th><td>${params.BUILD_LOCAL}</td></tr>
                <tr><th>extra_body</th><td>${params.EXTRA_BODY ?: '不注入'}</td></tr>
                <tr><th>执行时间</th><td>${currentBuild.durationString}</td></tr>
                <tr><th>测试状态</th><td>${resultStatus}</td></tr>
                <tr><th>构建状态</th><td>${currentBuild.currentResult}</td></tr>
            </table>

            ${connectivityFailureHtml}

            <h3>SWE-bench Verified 得分</h3>
            <table>
                <tr style="background-color: #e3f2fd;"><th>Resolved</th><th>Total</th><th>Score</th></tr>
                <tr class="score-highlight"><td>${resolvedCount}</td><td>${totalCount}</td><td class="${scoreClass}">${scorePct}</td></tr>
            </table>

            <h3>输出目录</h3>
            <p>${failureReason ? 'N/A (连通性检查未通过)' : (env.RESULT_DIR ?: 'N/A')}</p>
            <p>结果文件: ${resultsFilePath}</p>

            <p style="margin-top: 20px;">详细日志请查看附件。</p>
            <p>Jenkins 构建地址: <a href="${env.BUILD_URL}">${env.BUILD_URL}</a></p>
        </div>
        <div class="footer">
            此邮件由 Jenkins 自动发送，请勿回复。<br/>
            SWE-bench Verified 数据集包含 500 个实例,来自 SWE-bench 官方。
        </div>
    </div>
</body>
</html>"""

                        echo "=== SWE-bench Verified 测试结果 ==="
                        echo "Build Number: ${BUILD_NUMBER}"
                        echo "结果目录: ${env.RESULT_DIR ?: 'N/A'}"
                        echo "Resolved: ${resolvedCount}/${totalCount}"
                        echo "Score: ${scorePct}"
                        echo "测试状态: ${resultStatus}"

                        def attachPattern = ""
                        def attachPatterns = []
                        if (logFile) {
                            attachPatterns.add(logFile)
                        }
                        if (fileExists("builds/${BUILD_NUMBER}/swebench_connectivity_${BUILD_NUMBER}.log")) {
                            attachPatterns.add("builds/${BUILD_NUMBER}/swebench_connectivity_${BUILD_NUMBER}.log")
                        }
                        attachPattern = attachPatterns.join(',')
                        emailext(
                            subject: "[模型推理 - SWE-bench Verified评测报告] #${BUILD_NUMBER} ${params.CHIP} - ${params.MODEL}",
                            body: emailBody,
                            to: "${params.RECIPIENTS}",
                            mimeType: 'text/html',
                            attachmentsPattern: attachPattern
                        )
                    }
                }
            }
        }
    }

    post {
        always {
            script {
                archiveArtifacts artifacts: "reports/${params.TESTER}/${BUILD_NUMBER}/**,builds/${BUILD_NUMBER}/**", allowEmptyArchive: true, fingerprint: true
                echo "构建完成: ${currentBuild.currentResult}"
            }
        }
        cleanup {
            cleanWs()
        }
    }
}
