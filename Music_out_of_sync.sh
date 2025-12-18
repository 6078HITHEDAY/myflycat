#!/bin/bash

# 音频重叠播放器 - 简化版
# 需要：yad, mpv, socat

set -u  # 未初始化变量时报错

# 调试用 - 设为true查看详细日志
DEBUG=false

debug_log() {
    [[ "$DEBUG" == "true" ]] && echo "[DEBUG] $@" >&2
}

# 全局变量
AUDIO_FILE=""
DELAY_MS=500
VOLUME=80
declare -a MPV_PIDS=()
CONTROL_DIR="/tmp/audio_overlap_$$"
IS_PLAYING=false
AUDIO_DURATION=0

# 清理函数
cleanup() {
    debug_log "清理中..."
    stop_playback
    [[ -d "$CONTROL_DIR" ]] && rm -rf "$CONTROL_DIR"
    exit 0
}

# 停止播放
stop_playback() {
    debug_log "停止播放..."
    for pid in "${MPV_PIDS[@]}"; do
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            sleep 0.1
            kill -9 "$pid" 2>/dev/null || true
        fi
    done
    
    [[ -d "$CONTROL_DIR" ]] && rm -f "$CONTROL_DIR"/*
    MPV_PIDS=()
    IS_PLAYING=false
}

# 检查依赖
check_dependencies() {
    local missing=()
    for cmd in yad mpv socat bc jq; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        yad --error \
            --text="缺少必要的依赖:\n\n${missing[*]/$'\n'/ }\n\n请运行以下命令安装:\nsudo apt install ${missing[*]}" \
            --width=400
        exit 1
    fi
}

# 获取音频时长
get_audio_duration() {
    local file="$1"
    local duration=0
    
    if [[ -f "$file" ]]; then
        if command -v ffprobe &>/dev/null; then
            duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | cut -d. -f1)
        fi
        
        if [[ -z "$duration" || "$duration" == "0" ]]; then
            duration=$(mpv --term-playing-msg='${=duration}' --no-config --no-video --vo=null --ao=null --frames=1 --quiet "$file" 2>&1 | tail -n1 | cut -d. -f1)
        fi
        
        [[ ! "$duration" =~ ^[0-9]+$ ]] && duration=0
    fi
    
    echo "${duration:-0}"
}

# 发送MPV命令
send_mpv_command() {
    local socket="$1"
    local command="$2"
    
    if [[ -S "$socket" ]]; then
        echo "$command" | socat - UNIX-CONNECT:"$socket" 2>/dev/null || {
            debug_log "发送命令失败: $command"
            return 1
        }
    fi
}

# 播放音频
play_audio() {
    local file="$1"
    local delay_ms="$2"
    local volume="$3"
    
    debug_log "开始播放: $file, 延迟: $delay_ms, 音量: $volume"
    
    mkdir -p "$CONTROL_DIR"
    
    # 获取时长
    AUDIO_DURATION=$(get_audio_duration "$file")
    debug_log "音频时长: $AUDIO_DURATION 秒"
    
    # 启动第一个MPV实例
    local socket1="$CONTROL_DIR/mpv1.socket"
    mpv --no-video \
        --input-ipc-server="$socket1" \
        --volume="$volume" \
        --quiet \
        "$file" >/dev/null 2>&1 &
    local pid1=$!
    MPV_PIDS+=("$pid1")
    echo "$pid1" > "$CONTROL_DIR/mpv1.pid"
    debug_log "启动MPV实例1, PID: $pid1"
    
    # 等待socket
    local wait_count=0
    while [[ ! -S "$socket1" ]] && [[ $wait_count -lt 50 ]]; do
        sleep 0.1
        wait_count=$((wait_count + 1))
    done
    
    if [[ ! -S "$socket1" ]]; then
        yad --error --text="MPV实例1启动超时"
        stop_playback
        return 1
    fi
    
    # 等待延迟
    local delay_sec=$(bc -l <<< "scale=3; $delay_ms / 1000" 2>/dev/null || echo "0.5")
    debug_log "等待 $delay_sec 秒..."
    sleep "$delay_sec"
    
    # 启动第二个MPV实例
    local socket2="$CONTROL_DIR/mpv2.socket"
    mpv --no-video \
        --input-ipc-server="$socket2" \
        --volume="$volume" \
        --quiet \
        "$file" >/dev/null 2>&1 &
    local pid2=$!
    MPV_PIDS+=("$pid2")
    echo "$pid2" > "$CONTROL_DIR/mpv2.pid"
    debug_log "启动MPV实例2, PID: $pid2"
    
    wait_count=0
    while [[ ! -S "$socket2" ]] && [[ $wait_count -lt 50 ]]; do
        sleep 0.1
        wait_count=$((wait_count + 1))
    done
    
    if [[ ! -S "$socket2" ]]; then
        yad --error --text="MPV实例2启动超时"
        stop_playback
        return 1
    fi
    
    IS_PLAYING=true
    
    # 启动简化版控制窗口
    simple_control_window "$socket1" "$socket2"
}

# 简化版控制窗口 (移除音量控制、跳转功能和进度条)
simple_control_window() {
    local socket1="$1"
    local socket2="$2"
    
    debug_log "启动简化控制窗口..."
    
    # 显示状态信息窗口
    yad --info \
        --title="正在播放 - $(basename "$AUDIO_FILE")" \
        --text="音频重叠播放中...\n\n文件: $(basename "$AUDIO_FILE")\n延迟: ${DELAY_MS}ms\n音量: ${VOLUME}%\n\n点击确定停止播放" \
        --width=400 \
        --button="暂停/继续":10 \
        --button="停止播放":20 \
        --no-escape &
    
    local control_yad_pid=$!
    
    # 监听按钮点击
    while [[ "$IS_PLAYING" == "true" ]]; do
        if ! kill -0 "$control_yad_pid" 2>/dev/null; then
            # 窗口被关闭
            stop_playback
            break
        fi
        
        # 检查mpv进程是否还在运行
        local all_alive=true
        for pid in "${MPV_PIDS[@]}"; do
            if ! kill -0 "$pid" 2>/dev/null; then
                all_alive=false
                break
            fi
        done
        
        if [[ "$all_alive" == "false" ]]; then
            debug_log "MPV进程已退出"
            IS_PLAYING=false
            break
        fi
        
        sleep 0.5
    done
    
    # 清理
    kill "$control_yad_pid" 2>/dev/null || true
    
    debug_log "控制窗口关闭"
}

# 主窗口 (使用--button方式)
main_window() {
    debug_log "启动主窗口..."
    
    while true; do
        # 显示主窗口
        response=$(yad --center \
            --title="音频重叠播放器 - 简化版" \
            --form \
            --field="音频文件:SFL" "$AUDIO_FILE" \
            --field="延迟时间 (ms):SCL" "$DELAY_MS!0..2000!10!0" \
            --field="音量 (%):SCL" "$VOLUME!0..100!5!0" \
            --field="效果预设:CB" "自定义!合唱效果(30ms)!加倍效果(50ms)!回声效果(300ms)!大教堂回声(800ms)" \
            --width=500 \
            --height=280 \
            --button="🎵 播放":10 \
            --button="⚙️ 测试":20 \
            --button="ℹ️ 关于":30 \
            --button="🚪 退出":40 \
            --dialog-sep="|" \
            --separator="|" \
            --focus-field=1)
        
        exit_code=$?
        
        # 处理按钮点击
        if [[ $exit_code -eq 40 ]] || [[ $exit_code -eq 252 ]]; then
            cleanup
        elif [[ $exit_code -eq 30 ]]; then
            about_window
            continue
        elif [[ $exit_code -eq 20 ]]; then
            test_window
            continue
        elif [[ $exit_code -eq 10 ]]; then
            # 处理播放
            IFS='|' read -r audio_file delay_ms volume preset <<< "$response"
            
            # 检查文件
            if [[ -z "$audio_file" ]] || [[ ! -f "$audio_file" ]]; then
                yad --error --text="请选择有效的音频文件"
                continue
            fi
            
            # 应用预设
            case "$preset" in
                "合唱效果(30ms)") delay_ms="30" ;;
                "加倍效果(50ms)") delay_ms="50" ;;
                "回声效果(300ms)") delay_ms="300" ;;
                "大教堂回声(800ms)") delay_ms="800" ;;
            esac
            
            # 确认信息
            if yad --info \
                --title="播放信息" \
                --text="文件: $(basename "$audio_file")\n延迟: ${delay_ms}毫秒\n音量: ${volume}%" \
                --width=300 \
                --button="gtk-ok:0" \
                --button="gtk-cancel:1"; then
                
                # 停止当前播放
                stop_playback
                sleep 0.5
                
                # 更新全局变量
                AUDIO_FILE="$audio_file"
                DELAY_MS="$delay_ms"
                VOLUME="$volume"
                
                # 开始播放
                play_audio "$AUDIO_FILE" "$DELAY_MS" "$VOLUME"
            fi
        fi
    done
}

# 测试窗口 (使用--button方式)
test_window() {
    debug_log "启动测试窗口..."
    
    local test_file=$(yad --file-selection \
        --title="选择测试音频" \
        --width=800 \
        --height=600)
    
    if [[ -z "$test_file" ]] || [[ ! -f "$test_file" ]]; then
        return
    fi
    
    yad --info \
        --title="测试说明" \
        --text="将测试不同延迟效果\n点击确定开始" \
        --width=300
    
    local delays=(30 50 100 200 500 1000)
    
    for delay in "${delays[@]}"; do
        local description=$(get_effect_desc "$delay")
        
        local exit_code=$(yad --center \
            --title="测试 ${delay}ms 效果" \
            --form \
            --field="延迟: " "$delay" \
            --field="效果描述:RO" "$description" \
            --width=400 \
            --height=250 \
            --button="播放测试":10 \
            --button="跳过":20 \
            --button="停止测试":30 \
            --dialog-sep="|" \
            --separator="|"; echo $?)
        
        if [[ $exit_code -eq 30 ]]; then
            stop_playback
            return
        elif [[ $exit_code -eq 20 ]]; then
            continue
        elif [[ $exit_code -eq 10 ]]; then
            stop_playback
            sleep 0.5
            
            play_audio "$test_file" "$delay" "80"
            
            # 等待播放完成
            while [[ "$IS_PLAYING" == "true" ]]; do
                sleep 1
                local running=false
                for pid in "${MPV_PIDS[@]}"; do
                    if kill -0 "$pid" 2>/dev/null; then
                        running=true
                        break
                    fi
                done
                [[ "$running" == "false" ]] && IS_PLAYING=false
            done
            
            sleep 1
        fi
    done
    
    yad --info --text="测试完成！" --timeout=2
}

# 获取效果描述 (保持不变)
get_effect_desc() {
    local delay=$1
    
    if [[ $delay -lt 20 ]]; then
        echo "轻微相位效果"
    elif [[ $delay -lt 40 ]]; then
        echo "合唱效果"
    elif [[ $delay -lt 80 ]]; then
        echo "加倍效果"
    elif [[ $delay -lt 150 ]]; then
        echo "厚重效果"
    elif [[ $delay -lt 400 ]]; then
        echo "回声效果"
    else
        echo "长回声效果"
    fi
}

# 关于窗口
about_window() {
    yad --text-info \
        --title="关于音频重叠播放器" \
        --filename=<(echo "🎵 音频重叠播放器 - 简化版 🎵

版本: 4.0 (功能精简版)

✨ 功能特点:
• 使用MPV作为播放引擎，稳定可靠
• 真正的停止播放功能
• 支持暂停/继续控制
• 支持多种音频格式

🎛️ 控制功能:
1. 暂停/继续 - 控制两个音频的播放状态
2. 停止按钮 - 立即停止所有播放

🔧 技术特性:
• 使用MPV的JSON IPC接口控制
• 通过Socket通信实现精确控制
• 支持多种音频格式

⚠️ 注意事项:
• 确保安装了 mpv, yad, socat, bc, jq
• 音量在播放前设置，播放中不可调
• 不能跳转到指定位置

📞 系统要求:
• Ubuntu/Debian: sudo apt install mpv yad socat bc jq
• Fedora: sudo dnf install mpv yad socat bc jq
• Arch: sudo pacman -S mpv yad socat bc jq

作者: myflycat
") \
        --width=600 \
        --height=400 \
        --button="关闭":0
}

# 主程序入口
main() {
    trap cleanup EXIT INT TERM
    
    check_dependencies
    
    mkdir -p "$CONTROL_DIR"
    
    main_window
}

# 启动程序
main "$@"
