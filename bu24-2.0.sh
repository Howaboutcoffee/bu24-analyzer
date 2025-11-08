#!/usr/bin/env bash
# ======================================================
# BU-24 带宽利用率分析器 (APT 自动安装版) — 仅模式1显示预测今日流量
# 适用: Debian / Ubuntu / Deepin / Kali 等系统
# ======================================================

# --- 环境检查 ---
echo -e "\033[1;34m[INFO]\033[0m 检查 Python 环境..."

if ! command -v python3 &>/dev/null; then
    echo -e "\033[1;31m[ERROR]\033[0m 未检测到 Python3，正在安装..."
    apt update && apt install -y python3 || { echo "安装 Python3 失败"; exit 1; }
else
    echo -e "\033[1;32m[OK]\033[0m Python3 已安装。"
fi

# --- 检查 numpy ---
if ! python3 -c "import numpy" &>/dev/null; then
    echo -e "\033[1;33m[WARN]\033[0m 检测到未安装 numpy，尝试使用 apt 安装..."
    apt update && apt install -y python3-numpy || { echo "安装 numpy 失败"; exit 1; }
    echo -e "\033[1;32m[OK]\033[0m numpy 已安装。"
else
    echo -e "\033[1;32m[OK]\033[0m numpy 已存在。"
fi

# --- 用户输入（模式选择） ---
echo
echo -e "\033[1;36m=== BU-24 模型交互模式 ===\033[0m"
stty erase ^H 2>/dev/null
echo "请选择分析模式："
echo "  1. 当前实时流量"
echo "  2. 昨日总流量"
read -e -p "请输入选项编号 [默认 1]: " mode
mode=${mode:-1}

read -e -p "请输入最大带宽（Mbps，例如 1500）: " max_bw
max_bw=${max_bw:-1500}

if [ "$mode" == "1" ]; then
    echo -e "\033[1;34m[INFO]\033[0m 将系统时区设置为上海时间（仅尝试）..."
    timedatectl set-timezone Asia/Shanghai 2>/dev/null || true
    read -e -p "请输入当前已用流量（TB，例如 3.2）: " used_tb
    # 模式1会基于 used_tb 推算今日总流量（预测）
else
    read -e -p "请输入昨日总流量（TB，例如 6.5）: " total_tb
    # 模式2不需要预测今日流量
fi

# 导出环境变量给 Python（安全处理空值）
export MAX_BW="${max_bw}"
export MODE="${mode}"
export USED_TB="${used_tb:-}"
export TOTAL_TB="${total_tb:-}"

# --- 执行 Python 分析 ---
python3 - <<'PYCODE'
import os
import numpy as np
from datetime import datetime, timezone, timedelta

# 读取环境变量（已经由 Bash 设置）
max_bw = float(os.environ.get('MAX_BW', '1500'))
mode = int(os.environ.get('MODE', '1'))

used_tb_env = os.environ.get('USED_TB', '').strip()
total_tb_env = os.environ.get('TOTAL_TB', '').strip()

used_tb = float(used_tb_env) if used_tb_env != '' else None
total_tb_provided = float(total_tb_env) if total_tb_env != '' else None

# 小时比例模型（保持你现有的分布）
ratios = np.array([
    0.074152, 0.055637, 0.053687, 0.038074, 0.029172, 0.020483,
    0.019464, 0.022966, 0.034680, 0.042502, 0.049233, 0.051580,
    0.030123, 0.043075, 0.036586, 0.036523, 0.038748, 0.035540,
    0.035948, 0.034567, 0.041408, 0.044338, 0.055401, 0.076114
])
ratios = ratios / np.sum(ratios)

# 预测逻辑
predicted_today_tb = None

if mode == 1:
    # 实时模式：需要 used_tb（当前已用量），按已过小时比例外推全天
    now = datetime.now(timezone(timedelta(hours=8)))  # 上海时间
    now_hour = now.hour
    if used_tb is None:
        raise SystemExit("实时模式需要输入当前已用流量（TB）。")
    # 如果当前时间正好是整点，包含当前小时的比例用于估算
    current_ratio = float(np.sum(ratios[: now_hour + 1 ]))
    if current_ratio <= 0:
        predicted_today_tb = used_tb  # 兜底
    else:
        predicted_today_tb = used_tb / current_ratio
    total_tb = predicted_today_tb
else:
    # 模式2：直接使用用户输入的昨日值作为计算基准（不做今日预测）
    if total_tb_provided is None:
        raise SystemExit("模式2需要输入昨日总流量（TB）。")
    total_tb = total_tb_provided

# 计算带宽指标（保持既有换算方式）
# avg_bw 单位：Mbps
avg_bw = (total_tb * 8e6) / (3600 * 24)
util = avg_bw / max_bw * 100.0
# hourly_bw 近似各小时带宽（Mbps）
hourly_bw = avg_bw * (ratios / (1.0/24.0))
peak_bw = float(np.max(hourly_bw))
peak_util = peak_bw / max_bw * 100.0

expand_bw_threshold = 0.95 * max_bw
# 估算达到 95% 时对应的日流量（粗略）
expand_traffic_tb = total_tb * (expand_bw_threshold / peak_bw) if peak_bw > 0 else float('nan')

# 输出颜色
PURPLE = "\033[1;35m"
GREEN = "\033[1;32m"
YELLOW = "\033[1;33m"
RED = "\033[1;31m"
RESET = "\033[0m"

# 扩容建议
if peak_util >= 95:
    suggestion = f"{RED}[ALERT]{RESET} 峰值利用率 {peak_util:.1f}% → 长期超95%请考虑扩容。"
elif peak_util >= 90:
    suggestion = f"{YELLOW}[WARN]{RESET} 峰值利用率 {peak_util:.1f}% → 利用率较高，建议持续观察。"
else:
    suggestion = f"{GREEN}[OK]{RESET} 峰值利用率 {peak_util:.1f}% → 正常范围。"

# 打印报告（若为模式1，额外打印“预测今日流量”）
print(f"{PURPLE}╔══════════════════════════════════════════════╗{RESET}")
print(f"{PURPLE}║              BU-24 模型分析报告              ║{RESET}")
print(f"{PURPLE}╚══════════════════════════════════════════════╝{RESET}")
print(f"最大带宽：{max_bw:.0f} Mbps")

# 每日流量（对模式1来说这是预测值；模式2为昨日值）
mode_label = '实时预测' if mode == 1 else '完整分析'
print(f"每日流量：{total_tb:.2f} TB（模式：{mode_label}）")

# 仅模式1显示“预测今日流量”这一额外行（即用户要求）
if mode == 1 and predicted_today_tb is not None:
    print(f"预测今日流量（基于当前已用量与时段分布）：{predicted_today_tb:.2f} TB")

print(f"平均带宽：{avg_bw:.1f} Mbps（{util:.1f}% 利用率）")
print(f"峰值带宽：{peak_bw:.1f} Mbps（{peak_util:.1f}% 利用率）")
print("\n—— 每小时带宽估算（Mbps）——")
print(", ".join(f"{v:.0f}" for v in hourly_bw))
print(f"\n扩容建议： {suggestion}")
print(f"\n{PURPLE}扩容参考阈值：{RESET}")
print(f"   ▪ 当峰值 ≥ {expand_bw_threshold:.0f} Mbps（≈95%） 或")
print(f"   ▪ 日流量 ≥ {expand_traffic_tb:.2f} TB/天")
print(f"     → 达到任一条件应考虑扩容 500M。")
print(f"{PURPLE}═══════════════════════════════════════════════{RESET}")
PYCODE
