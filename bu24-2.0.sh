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
python3 - <<'PYCODE'
import os
import numpy as np
from datetime import datetime, timezone, timedelta

# === 环境变量 ===
max_bw = float(os.environ.get('MAX_BW', '1500'))
mode = int(os.environ.get('MODE', '1'))

used_tb_env = os.environ.get('USED_TB', '').strip()
total_tb_env = os.environ.get('TOTAL_TB', '').strip()

used_tb = float(used_tb_env) if used_tb_env else None
total_tb_provided = float(total_tb_env) if total_tb_env else None

# === 每小时流量分布（固定模型） ===
ratios = np.array([
    0.074152, 0.055637, 0.053687, 0.038074, 0.029172, 0.020483,
    0.019464, 0.022966, 0.034680, 0.042502, 0.049233, 0.051580,
    0.030123, 0.043075, 0.036586, 0.036523, 0.038748, 0.035540,
    0.035948, 0.034567, 0.041408, 0.044338, 0.055401, 0.076114
])
ratios = ratios / np.sum(ratios)

# === 模型核心逻辑 ===
predicted_today_tb = None
now = datetime.now(timezone(timedelta(hours=8)))  # 上海时区
now_hour = now.hour

if mode == 1:
    if used_tb is None:
        raise SystemExit("实时模式需要输入当前已用流量（TB）。")

    current_ratio = float(np.sum(ratios[: now_hour + 1 ]))
    future_ratio = float(np.sum(ratios[now_hour + 1:]))

    if current_ratio <= 0:
        predicted_today_tb = used_tb
    else:
        # --- 改进预测：考虑未来夜间加权 ---
        avg_rate_so_far = used_tb / current_ratio
        # 夜间比例较大时，未来部分稍放大预测 (夜间未来部分加权 0.3系数)
        weighted_future = future_ratio * (1 + 0.3 * (future_ratio / (current_ratio + 1e-6)))
        predicted_today_tb = used_tb + avg_rate_so_far * weighted_future

    total_tb = predicted_today_tb
else:
    if total_tb_provided is None:
        raise SystemExit("模式2需要输入昨日总流量（TB）。")
    total_tb = total_tb_provided

# === 计算带宽指标 ===
avg_bw = (total_tb * 8e6) / (3600 * 24)
util = avg_bw / max_bw * 100.0
hourly_bw = avg_bw * (ratios / (1.0 / 24.0))
peak_bw = float(np.max(hourly_bw))
peak_util = peak_bw / max_bw * 100.0

expand_bw_threshold = 0.95 * max_bw
expand_traffic_tb = total_tb * (expand_bw_threshold / peak_bw) if peak_bw > 0 else float('nan')

# === 输出格式 ===
PURPLE = "\033[1;35m"
GREEN = "\033[1;32m"
YELLOW = "\033[1;33m"
RED = "\033[1;31m"
RESET = "\033[0m"

# 建议
if peak_util >= 95:
    suggestion = f"{RED}[ALERT]{RESET} 峰值利用率 {peak_util:.1f}% → 长期超95%请考虑扩容。"
elif peak_util >= 90:
    suggestion = f"{YELLOW}[WARN]{RESET} 峰值利用率 {peak_util:.1f}% → 利用率较高，建议持续观察。"
else:
    suggestion = f"{GREEN}[OK]{RESET} 峰值利用率 {peak_util:.1f}% → 正常范围。"

# === 打印报告 ===
print(f"{PURPLE}╔══════════════════════════════════════════════╗{RESET}")
print(f"{PURPLE}║              BU-24 模型分析报告              ║{RESET}")
print(f"{PURPLE}╚══════════════════════════════════════════════╝{RESET}")
print(f"最大带宽：{max_bw:.0f} Mbps")

mode_label = '实时预测' if mode == 1 else '完整分析'
if mode == 1:
    print(f"当前已用：{used_tb:.2f} TB（模式：{mode_label}）")
else:
    print(f"每日流量：{total_tb:.2f} TB（模式：{mode_label}）")


if mode == 1 and predicted_today_tb is not None:
    print(f"预测今日流量：{predicted_today_tb:.2f} TB")

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
