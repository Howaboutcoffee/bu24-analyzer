#!/usr/bin/env bash
# ======================================================
# BU-24 带宽利用率分析器 (APT 自动安装版)
# 适用: Debian / Ubuntu / Deepin / Kali 等系统
# 增强功能：可选择“当前实时流量预测”或“昨日总流量分析”
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
read -e -p "请输入选项编号: " mode
mode=${mode:-1}

read -e -p "请输入最大带宽（Mbps，例如 1000）: " max_bw

if [ "$mode" == "1" ]; then
    echo -e "\033[1;34m[INFO]\033[0m 将系统时区设置为上海时间..."
    timedatectl set-timezone Asia/Shanghai 2>/dev/null
    read -e -p "请输入当前已用流量（TB，例如 3.2）: " used_tb
    echo -e "\033[1;33m[WARN]\033[0m 实时模式：系统将自动推算全天流量。\n"
else
    read -e -p "请输入昨日总流量（TB，例如 6.5）: " total_tb
    echo
    echo "使用默认的流量分布模型（可自行修改脚本）。"
    echo
fi

# --- 执行 Python 分析 ---
python3 - <<PYCODE
import numpy as np
from datetime import datetime, timezone, timedelta

max_bw = float(${max_bw})
mode = ${mode}

ratios = np.array([
    0.074152, 0.055637, 0.053687, 0.038074, 0.029172, 0.020483,
    0.019464, 0.022966, 0.034680, 0.042502, 0.049233, 0.051580,
    0.030123, 0.043075, 0.036586, 0.036523, 0.038748, 0.035540,
    0.035948, 0.034567, 0.041408, 0.044338, 0.055401, 0.076114
])
ratios /= np.sum(ratios)

# --- 模式判断 ---
if mode == 1:
    now = datetime.now(timezone(timedelta(hours=8)))  # 上海时间
    now_hour = now.hour
    used_tb = float(${used_tb})
    current_ratio = np.sum(ratios[:now_hour + 1])
    total_tb = used_tb / current_ratio
else:
    total_tb = float(${total_tb})

# --- 计算逻辑 ---
avg_bw = (total_tb * 8e6) / (3600 * 24)
util = avg_bw / max_bw * 100
hourly_bw = avg_bw * (ratios / (1/24))
peak_bw = np.max(hourly_bw)
peak_util = peak_bw / max_bw * 100

expand_bw_threshold = 0.85 * max_bw
expand_traffic_tb = total_tb * (expand_bw_threshold / peak_bw)

# --- 输出格式定义 ---
PURPLE = "\033[1;35m"
GREEN = "\033[1;32m"
YELLOW = "\033[1;33m"
RED = "\033[1;31m"
RESET = "\033[0m"

# --- 扩容判断（包月优化逻辑） ---
if peak_util >= 95:
    suggestion = f"{RED}[ALERT]{RESET} 峰值利用率 {peak_util:.1f}% → 长期超95%请考虑扩容。"
elif peak_util >= 90:
    suggestion = f"{YELLOW}[WARN]{RESET} 峰值利用率 {peak_util:.1f}% → 利用率较高，建议持续观察。"
else:
    suggestion = f"{GREEN}[OK]{RESET} 峰值利用率 {peak_util:.1f}% → 正常范围。"

# --- 输出结果 ---
print(f"{PURPLE}╔══════════════════════════════════════════════╗{RESET}")
print(f"{PURPLE}║              BU-24 模型分析报告              ║{RESET}")
print(f"{PURPLE}╚══════════════════════════════════════════════╝{RESET}")
print(f"最大带宽：{max_bw:.0f} Mbps")
print(f"每日流量：{total_tb:.2f} TB（模式：{'实时预测' if mode==1 else '完整分析'}）")
print(f"平均带宽：{avg_bw:.1f} Mbps（{util:.1f}% 利用率）")
print(f"峰值带宽：{peak_bw:.1f} Mbps（{peak_util:.1f}% 利用率）")
print("\n—— 每小时带宽估算（Mbps）——")
print(", ".join(f"{v:.0f}" for v in hourly_bw))
print(f"\n扩容建议： {suggestion}")
print(f"\n{PURPLE}扩容参考阈值：{RESET}")
print(f"   ▪ 当峰值 ≥ {expand_bw_threshold:.0f} Mbps（≈85%） 或")
print(f"   ▪ 日流量 ≥ {expand_traffic_tb:.2f} TB/天")
print(f"     → 达到任一条件应考虑扩容 500M。")
print(f"{PURPLE}═══════════════════════════════════════════════{RESET}")
PYCODE
