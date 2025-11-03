#!/usr/bin/env bash
# ======================================================
# BU-24 带宽利用率分析器 (APT 自动安装版)
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

# --- 用户输入 ---
echo
echo -e "\033[1;36m=== BU-24 模型交互模式 ===\033[0m"
read -p "请输入最大带宽（Mbps，例如 1000）: " max_bw
read -p "请输入每日流量（TB，例如 6.5）: " total_tb
echo
echo "使用默认的流量分布模型（可自行修改脚本）。"
echo

# --- 执行 Python 分析 ---
python3 - <<PYCODE
import numpy as np

max_bw = float(${max_bw})
total_tb = float(${total_tb})

ratios = np.array([
    0.02,0.02,0.03,0.03,0.03,0.04,0.05,0.05,0.06,0.06,0.06,0.05,
    0.05,0.05,0.06,0.06,0.07,0.07,0.08,0.07,0.06,0.05,0.04,0.03
])
ratios /= np.sum(ratios)

avg_bw = (total_tb * 8e6) / (3600 * 24)
util = avg_bw / max_bw * 100
hourly_bw = avg_bw * (ratios / (1/24))
peak_bw = np.max(hourly_bw)
peak_util = peak_bw / max_bw * 100

expand_bw_threshold = 0.85 * max_bw
expand_traffic_tb = total_tb * (expand_bw_threshold / peak_bw)

PURPLE = "\033[1;35m"
GREEN = "\033[1;32m"
YELLOW = "\033[1;33m"
RED = "\033[1;31m"
RESET = "\033[0m"

if peak_util >= 90:
    suggestion = f"{RED}[ALERT]{RESET} 峰值利用率 {peak_util:.1f}% → 建议立即扩容 500M。"
elif peak_util >= 85:
    suggestion = f"{YELLOW}[WARN]{RESET} 峰值利用率 {peak_util:.1f}% → 可观察或适度扩容。"
else:
    suggestion = f"{GREEN}[OK]{RESET} 峰值利用率 {peak_util:.1f}% → 暂无需扩容。"

print(f"{PURPLE}╔══════════════════════════════════════════════╗{RESET}")
print(f"{PURPLE}║              BU-24 模型分析报告              ║{RESET}")
print(f"{PURPLE}╚══════════════════════════════════════════════╝{RESET}")
print(f"最大带宽：{max_bw:.0f} Mbps")
print(f"每日流量：{total_tb:.2f} TB")
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
